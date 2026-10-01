"""Voucher Engine — number generation, JE creation, and SafeBox sub-ledger."""
from __future__ import annotations

import json
from datetime import datetime

from models import (
    db,
    Account,
    Customer,
    JournalEntry,
    JournalEntryLine,
    PaymentMethod,
    SafeBox,
    SafeBoxTransaction,
    Supplier,
    Voucher,
    VoucherAccountLine,
)
from accounting.reference_number_service import generate_journal_entry_number as _gen_je_number
from core.settings import _get_settings_singleton
from accounting.balances import _recalculate_account_balances_for_accounts


def _generate_journal_entry_number(prefix='JE', entry_date=None):
    return _gen_je_number(prefix, entry_date)


def generate_voucher_number(voucher_type, year=None, voucher_date=None):
    """
    توليد رقم سند تلقائي
    RV-2025-00001 (Receipt Voucher)
    PV-2025-00001 (Payment Voucher)
    AV-2025-00001 (Adjustment Voucher)
    """
    if voucher_date is not None:
        try:
            year = int(getattr(voucher_date, 'year', datetime.now().year))
        except Exception:
            year = datetime.now().year
    if year is None:
        year = datetime.now().year

    prefix_map = {
        'receipt': 'RV',
        'payment': 'PV',
        'adjustment': 'AV'
    }
    prefix = prefix_map.get(voucher_type, 'V')

    try:
        cache = db.session.info.setdefault('_voucher_number_seq_cache', {})
    except Exception:
        cache = {}

    cache_key = (prefix, int(year))
    last_seq = cache.get(cache_key)

    if last_seq is None:
        pattern = f'{prefix}-{year}-%'
        last_voucher = (
            Voucher.query
            .filter(Voucher.voucher_number.like(pattern))
            .order_by(Voucher.voucher_number.desc())
            .first()
        )

        if last_voucher and last_voucher.voucher_number:
            try:
                last_seq = int(str(last_voucher.voucher_number).split('-')[-1])
            except Exception:
                last_seq = 0
        else:
            last_seq = 0

    next_seq = int(last_seq) + 1
    while True:
        candidate = f'{prefix}-{year}-{next_seq:05d}'
        if not Voucher.query.filter_by(voucher_number=candidate).first():
            cache[cache_key] = next_seq
            return candidate
        next_seq += 1


def _update_account_balances_from_journal_lines(journal_entry_lines):
    """Update stored Account balances for accounts referenced by given journal lines."""
    affected_accounts = {line.account_id for line in (journal_entry_lines or []) if getattr(line, 'account_id', None)}
    _recalculate_account_balances_for_accounts(affected_accounts)


def create_journal_entry_from_voucher(voucher):
    """
    إنشاء قيد محاسبي تلقائي من السند - نسخة محدّثة

    يدعم قيود متعددة الأطراف:
    - نقد + عدة عيارات ذهب في نفس السند
    - يقرأ سطور الحسابات من VoucherAccountLine

    سند القبض (Receipt):
    - مدين: حسابات متعددة (صندوق، ذهب عيار 24، ذهب عيار 21، إلخ)
    - دائن: حساب العميل (مجموع المبالغ)

    سند الصرف (Payment):
    - مدين: حساب المورد (مجموع المبالغ)
    - دائن: حسابات متعددة (صندوق، ذهب عيار 24، ذهب عيار 21، إلخ)
    """
    from routes import (
        _resolve_account_id_for_amount_type,
        ensure_supplier_accounts,
        ensure_customer_accounts,
    )

    try:
        entry_number_str = _generate_journal_entry_number(entry_date=voucher.date)

        journal_entry = JournalEntry(
            entry_number=entry_number_str,
            date=voucher.date,
            description=f'{voucher.voucher_type.upper()} - {voucher.voucher_number}: {voucher.description or ""}',
            reference_type='voucher',
            reference_id=voucher.id,
            created_by=voucher.created_by
        )

        db.session.add(journal_entry)
        db.session.flush()

        account_lines = VoucherAccountLine.query.filter_by(voucher_id=voucher.id).all()

        if not account_lines:
            print(f"Warning: No account lines found for voucher {voucher.id}")
            return None

        safe_account_ids = set()
        _account_cache: dict = {}
        try:
            line_account_ids = list({l.account_id for l in account_lines if getattr(l, 'account_id', None) is not None})
            if line_account_ids:
                for sb in SafeBox.query.filter(SafeBox.account_id.in_(line_account_ids)).all():
                    if getattr(sb, 'account_id', None) is not None:
                        safe_account_ids.add(int(sb.account_id))
                for _a in Account.query.filter(Account.id.in_(line_account_ids)).all():
                    _account_cache[int(_a.id)] = _a
        except Exception:
            safe_account_ids = set()

        expected_party_account_id = None
        _party_sp = db.session.begin_nested()
        try:
            if getattr(voucher, 'party_type', None) == 'supplier' and getattr(voucher, 'supplier_id', None):
                supplier = Supplier.query.get(int(voucher.supplier_id))
                if supplier:
                    expected_party_account_id = int(ensure_supplier_accounts(supplier).financial.id)
            elif getattr(voucher, 'party_type', None) == 'customer' and getattr(voucher, 'customer_id', None):
                customer = Customer.query.get(int(voucher.customer_id))
                if customer:
                    expected_party_account_id = int(ensure_customer_accounts(customer).financial.id)
            _party_sp.commit()
        except Exception:
            _party_sp.rollback()
            expected_party_account_id = None

        for account_line in account_lines:
            cash_debit = 0
            cash_credit = 0
            debit_18k = 0
            credit_18k = 0
            debit_21k = 0
            credit_21k = 0
            debit_22k = 0
            credit_22k = 0
            debit_24k = 0
            credit_24k = 0

            if account_line.amount_type == 'cash':
                if account_line.line_type == 'debit':
                    cash_debit = account_line.amount
                else:
                    cash_credit = account_line.amount
            elif account_line.amount_type == 'gold':
                karat = int(account_line.karat) if account_line.karat else 21
                amount = account_line.amount
                is_debit = account_line.line_type == 'debit'

                if karat == 18:
                    if is_debit:
                        debit_18k = amount
                    else:
                        credit_18k = amount
                elif karat == 21:
                    if is_debit:
                        debit_21k = amount
                    else:
                        credit_21k = amount
                elif karat == 22:
                    if is_debit:
                        debit_22k = amount
                    else:
                        credit_22k = amount
                elif karat == 24:
                    if is_debit:
                        debit_24k = amount
                    else:
                        credit_24k = amount
                else:
                    print(f"Warning: Unsupported karat {karat}, defaulting to 21k")
                    if is_debit:
                        debit_21k = amount
                    else:
                        credit_21k = amount

            should_tag_party = True
            try:
                if expected_party_account_id and int(account_line.account_id) == int(expected_party_account_id):
                    should_tag_party = True
                elif int(account_line.account_id) in safe_account_ids:
                    should_tag_party = False
            except Exception:
                should_tag_party = True

            customer_id = None
            supplier_id = None
            if should_tag_party:
                if getattr(voucher, 'party_type', None) == 'customer' and getattr(voucher, 'customer_id', None):
                    customer_id = voucher.customer_id
                if getattr(voucher, 'party_type', None) == 'supplier' and getattr(voucher, 'supplier_id', None):
                    supplier_id = voucher.supplier_id

            target_account_id = _resolve_account_id_for_amount_type(
                int(account_line.account_id),
                str(account_line.amount_type or ''),
                safe_account_ids=safe_account_ids,
                account_cache=_account_cache,
            )

            journal_line = JournalEntryLine(
                journal_entry_id=journal_entry.id,
                account_id=target_account_id,
                customer_id=customer_id,
                supplier_id=supplier_id,
                cash_debit=cash_debit,
                cash_credit=cash_credit,
                debit_18k=debit_18k,
                credit_18k=credit_18k,
                debit_21k=debit_21k,
                credit_21k=credit_21k,
                debit_22k=debit_22k,
                credit_22k=credit_22k,
                debit_24k=debit_24k,
                credit_24k=credit_24k,
                description=(account_line.description or voucher.description),
            )

            db.session.add(journal_line)

        db.session.flush()

        try:
            _post_settings = _get_settings_singleton(create_if_missing=False)
            _should_auto_post = False
            if _post_settings:
                _should_auto_post = (
                    bool(getattr(_post_settings, 'voucher_auto_post', False))
                    or bool(getattr(_post_settings, 'auto_post_entries', False))
                )
            if _should_auto_post and not journal_entry.is_posted:
                journal_entry.is_posted = True
                journal_entry.is_draft = False
                journal_entry.posted_at = datetime.now()
                journal_entry.posted_by = voucher.created_by or 'system'
        except Exception:
            pass

        # NOTE: do NOT also call _rebuild_safe_box_transactions_for_journal_entry
        # here. Every voucher-creation call site already calls
        # _append_safe_transactions_for_voucher(voucher, ...) right after this
        # function returns (it has its own ref_type='voucher' idempotency
        # guard) -- adding a second, parallel mechanism here just creates a
        # duplicate ref_type='journal_entry' SafeBoxTransaction row for every
        # voucher going forward.

        return journal_entry

    except Exception as e:
        import traceback
        traceback.print_exc()
        raise Exception(f'فشل إنشاء القيد المحاسبي من السند: {str(e)}') from e


def post_entry_of_approved_voucher(voucher, posted_by: str):
    """The posted entry of a voucher born approved, in the same transaction.

    For writers that create a voucher already 'approved' -- the bonus approval,
    payment and reversal. Its entry is posted with it whatever the auto-post
    settings say: an approved voucher's entry stands posted (V0, owner 1 Oct
    2026, journal_entry_guard). Raises when no entry can be made, so the
    caller's whole operation fails -- never an approved voucher without one.
    """
    entry = create_journal_entry_from_voucher(voucher)
    if entry is None:
        raise RuntimeError(f'no journal entry could be made for voucher {voucher.voucher_number}')
    if not entry.is_posted:
        entry.is_posted = True
        entry.is_draft = False
        entry.posted_at = datetime.now()
        entry.posted_by = posted_by
    voucher.journal_entry_id = entry.id
    return entry


def _append_safe_transactions_for_voucher(voucher: 'Voucher', created_by=None):
    """Append SafeBoxTransaction rows for voucher lines that target a SafeBox account.

    We derive SafeBox by matching VoucherAccountLine.account_id to SafeBox.account_id.
    Direction is derived from voucher line_type:
      - debit  => safe in
      - credit => safe out

    Notes:
    - We write only for approved vouchers (called by approve endpoint).
    - We best-effort link to a PaymentMethod if one exists whose default safe is this SafeBox.
    - Idempotent: if SafeBoxTransaction rows already exist for this voucher, skip to prevent duplication.
    """
    if not voucher or not getattr(voucher, 'id', None):
        return []

    # ── Idempotency guard: prevent double-posting ──────────────────────────
    # We always store SBTs with ref_id=voucher.id.  However, legacy rows created
    # by an older code version used ref_id=invoice_payment.id (≠ voucher.id).
    # A later invoice_payment row can coincidentally share the same numeric id as
    # this voucher, causing a false-positive match and silently skipping SBT creation.
    # Fix: when this voucher is linked to an invoice, require the SBT's invoice_id
    # to also match so we don't confuse unrelated records.
    # Fix 2: for standalone vouchers (not linked to any invoice), only look for
    # ref_type='voucher' SBTs — never 'invoice_payment', because old-code SBTs used
    # invoice_payment.id as ref_id which can collide with the new voucher.id numerically.
    linked_invoice_id_pre = None
    try:
        if (getattr(voucher, 'reference_type', None) == 'invoice') and getattr(voucher, 'reference_id', None):
            linked_invoice_id_pre = int(voucher.reference_id)
    except Exception:
        linked_invoice_id_pre = None

    if linked_invoice_id_pre is not None:
        _guard_q = SafeBoxTransaction.query.filter(
            SafeBoxTransaction.ref_id == voucher.id,
            SafeBoxTransaction.ref_type.in_(['voucher', 'invoice_payment']),
            SafeBoxTransaction.invoice_id == linked_invoice_id_pre,
        )
    else:
        _guard_q = SafeBoxTransaction.query.filter(
            SafeBoxTransaction.ref_id == voucher.id,
            SafeBoxTransaction.ref_type == 'voucher',
        )

    existing_count = _guard_q.count()
    if existing_count > 0:
        return []
    # ───────────────────────────────────────────────────────────────────────

    je = None
    try:
        je_id = getattr(voucher, 'journal_entry_id', None)
        if je_id not in (None, '', False, 0):
            je = JournalEntry.query.get(int(je_id))
    except Exception:
        je = None

    if je is not None:
        je_lines = JournalEntryLine.query.filter_by(journal_entry_id=je.id).all()
        je_lines = [l for l in je_lines if not getattr(l, 'is_deleted', False)]
        if not je_lines:
            return []

        linked_invoice_id = None
        linked_invoice_payment_id = None
        linked_payment_method_id = None

        try:
            if (getattr(voucher, 'reference_type', None) == 'invoice') and getattr(voucher, 'reference_id', None):
                linked_invoice_id = int(voucher.reference_id)
        except Exception:
            linked_invoice_id = None

        try:
            raw_notes = getattr(voucher, 'notes', None)
            if raw_notes:
                parsed = json.loads(raw_notes)
                if isinstance(parsed, dict):
                    if parsed.get('invoice_payment_id') not in (None, '', False):
                        linked_invoice_payment_id = int(parsed.get('invoice_payment_id'))
                    if parsed.get('payment_method_id') not in (None, '', False):
                        linked_payment_method_id = int(parsed.get('payment_method_id'))
        except Exception:
            linked_invoice_payment_id = None
            linked_payment_method_id = None

        _vnum = getattr(voucher, 'voucher_number', None)
        if _vnum and linked_invoice_payment_id is not None and len(je_lines) > 2:
            _filtered = [l for l in je_lines if _vnum in (getattr(l, 'description', '') or '')]
            if _filtered:
                je_lines = _filtered

        account_ids = list({int(l.account_id) for l in je_lines if getattr(l, 'account_id', None) is not None})
        safe_by_account_id = {}
        if account_ids:
            for sb in SafeBox.query.filter(SafeBox.account_id.in_(account_ids)).all():
                safe_by_account_id[int(sb.account_id)] = sb

        if not safe_by_account_id:
            return []

        pm_by_safe_id = {}
        safe_ids = list({sb.id for sb in safe_by_account_id.values()})
        if safe_ids:
            for pm in PaymentMethod.query.filter(PaymentMethod.default_safe_box_id.in_(safe_ids)).all():
                if pm.default_safe_box_id and pm.default_safe_box_id not in pm_by_safe_id:
                    pm_by_safe_id[pm.default_safe_box_id] = pm.id

        effective_ref_type = 'invoice_payment' if linked_invoice_payment_id else 'voucher'
        eps_cash = 0.005
        eps_w = 0.0005

        created = []

        def _add_tx(*, sb: SafeBox, direction: str, amount_cash: float = 0.0, w18: float = 0.0, w21: float = 0.0, w22: float = 0.0, w24: float = 0.0):
            tx = SafeBoxTransaction(
                safe_box_id=sb.id,
                ref_type=effective_ref_type,
                ref_id=voucher.id,
                invoice_id=linked_invoice_id,
                invoice_payment_id=linked_invoice_payment_id,
                payment_method_id=linked_payment_method_id or pm_by_safe_id.get(sb.id),
                direction=direction,
                amount_cash=float(amount_cash or 0.0),
                weight_18k=float(w18 or 0.0),
                weight_21k=float(w21 or 0.0),
                weight_22k=float(w22 or 0.0),
                weight_24k=float(w24 or 0.0),
                notes=f"Voucher {voucher.voucher_number} - {voucher.voucher_type}",
                created_by=created_by or voucher.created_by,
            )
            db.session.add(tx)
            created.append(tx)

        for line in je_lines:
            sb = safe_by_account_id.get(int(line.account_id))
            if not sb:
                continue

            try:
                cash_debit = float(getattr(line, 'cash_debit', 0.0) or 0.0)
            except Exception:
                cash_debit = 0.0
            try:
                cash_credit = float(getattr(line, 'cash_credit', 0.0) or 0.0)
            except Exception:
                cash_credit = 0.0

            if cash_debit > eps_cash:
                _add_tx(sb=sb, direction='in', amount_cash=cash_debit)
            if cash_credit > eps_cash:
                _add_tx(sb=sb, direction='out', amount_cash=cash_credit)

            def _w(field: str) -> float:
                try:
                    return float(getattr(line, field, 0.0) or 0.0)
                except Exception:
                    return 0.0

            w_deb = {
                '18k': _w('debit_18k'),
                '21k': _w('debit_21k'),
                '22k': _w('debit_22k'),
                '24k': _w('debit_24k'),
            }
            w_cred = {
                '18k': _w('credit_18k'),
                '21k': _w('credit_21k'),
                '22k': _w('credit_22k'),
                '24k': _w('credit_24k'),
            }

            safe_karat = None
            try:
                if (getattr(sb, 'safe_type', None) == 'gold') and getattr(sb, 'karat', None):
                    safe_karat = int(getattr(sb, 'karat'))
            except Exception:
                safe_karat = None

            if safe_karat:
                allowed_key = f"{safe_karat}k"
                if allowed_key not in ('18k', '21k', '22k', '24k'):
                    allowed_key = None
                if allowed_key:
                    other_keys = [k for k in ('18k', '21k', '22k', '24k') if k != allowed_key]
                    if any(abs(w_deb.get(k, 0.0)) > eps_w or abs(w_cred.get(k, 0.0)) > eps_w for k in other_keys):
                        raise ValueError(
                            f"karat_mismatch_for_safe_box: safe_box_id={sb.id}, allowed={safe_karat}"
                        )

            if w_deb['18k'] > eps_w or w_deb['21k'] > eps_w or w_deb['22k'] > eps_w or w_deb['24k'] > eps_w:
                _add_tx(sb=sb, direction='in', w18=w_deb['18k'], w21=w_deb['21k'], w22=w_deb['22k'], w24=w_deb['24k'])
            if w_cred['18k'] > eps_w or w_cred['21k'] > eps_w or w_cred['22k'] > eps_w or w_cred['24k'] > eps_w:
                _add_tx(sb=sb, direction='out', w18=w_cred['18k'], w21=w_cred['21k'], w22=w_cred['22k'], w24=w_cred['24k'])

        return created

    # Fallback: derive from voucher account lines.
    lines = VoucherAccountLine.query.filter_by(voucher_id=voucher.id).all()
    if not lines:
        return []

    account_ids = list({l.account_id for l in lines if getattr(l, 'account_id', None) is not None})
    safe_by_account_id = {}
    if account_ids:
        for sb in SafeBox.query.filter(SafeBox.account_id.in_(account_ids)).all():
            safe_by_account_id[sb.account_id] = sb

    pm_by_safe_id = {}
    safe_ids = list({sb.id for sb in safe_by_account_id.values()})
    if safe_ids:
        for pm in PaymentMethod.query.filter(PaymentMethod.default_safe_box_id.in_(safe_ids)).all():
            if pm.default_safe_box_id and pm.default_safe_box_id not in pm_by_safe_id:
                pm_by_safe_id[pm.default_safe_box_id] = pm.id

    linked_invoice_id = None
    linked_invoice_payment_id = None
    linked_payment_method_id = None

    try:
        if (getattr(voucher, 'reference_type', None) == 'invoice') and getattr(voucher, 'reference_id', None):
            linked_invoice_id = int(voucher.reference_id)
    except Exception:
        linked_invoice_id = None

    try:
        raw_notes = getattr(voucher, 'notes', None)
        if raw_notes:
            parsed = json.loads(raw_notes)
            if isinstance(parsed, dict):
                if parsed.get('invoice_payment_id') not in (None, '', False):
                    linked_invoice_payment_id = int(parsed.get('invoice_payment_id'))
                if parsed.get('payment_method_id') not in (None, '', False):
                    linked_payment_method_id = int(parsed.get('payment_method_id'))
    except Exception:
        linked_invoice_payment_id = None
        linked_payment_method_id = None

    created = []
    for line in lines:
        sb = safe_by_account_id.get(line.account_id)
        if not sb:
            continue

        if (getattr(sb, 'safe_type', None) == 'gold') and getattr(sb, 'karat', None) and (line.amount_type == 'gold'):
            try:
                safe_karat = int(getattr(sb, 'karat'))
            except Exception:
                safe_karat = None
            try:
                line_karat = int(line.karat) if line.karat is not None else None
            except Exception:
                line_karat = None

            if safe_karat and line_karat != safe_karat:
                raise ValueError(
                    f"karat_mismatch_for_safe_box: safe_box_id={sb.id}, allowed={safe_karat}, got={line_karat}"
                )

        direction = 'in' if (line.line_type == 'debit') else 'out'
        effective_ref_type = 'invoice_payment' if linked_invoice_payment_id else 'voucher'
        tx = SafeBoxTransaction(
            safe_box_id=sb.id,
            ref_type=effective_ref_type,
            ref_id=voucher.id,
            invoice_id=linked_invoice_id,
            invoice_payment_id=linked_invoice_payment_id,
            payment_method_id=linked_payment_method_id or pm_by_safe_id.get(sb.id),
            direction=direction,
            notes=f"Voucher {voucher.voucher_number} - {voucher.voucher_type}",
            created_by=created_by or voucher.created_by,
        )

        if line.amount_type == 'cash':
            tx.amount_cash = float(line.amount or 0.0)
        elif line.amount_type == 'gold':
            karat = int(line.karat) if line.karat else None
            weight = float(line.amount or 0.0)
            if karat == 18:
                tx.weight_18k = weight
            elif karat == 22:
                tx.weight_22k = weight
            elif karat == 24:
                tx.weight_24k = weight
            else:
                tx.weight_21k = weight

        db.session.add(tx)
        created.append(tx)

    return created
