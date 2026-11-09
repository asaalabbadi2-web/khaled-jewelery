from __future__ import annotations

from models import db, JournalEntry, JournalEntryLine, PaymentMethod, SafeBox, SafeBoxTransaction


def row_safes_by_account(account_ids) -> dict:
    """{account id: its safe}, for the statement rows a posting writes: the
    active safes only. A stopped safe takes no new row -- ADR-052 stopped each
    office's old gold safe on its supplier's weight account, which stays the
    supplier's, live: matched by account, each gold payment to the office
    wrote a row on it (the Dewan's: 465.5 g, 26 Oct and 7 Nov 2026). The
    invoice's gold rows already read the active safes (posting_routes)."""
    ids = [int(i) for i in (account_ids or []) if i is not None]
    if not ids:
        return {}
    return {int(sb.account_id): sb
            for sb in SafeBox.query.filter(SafeBox.account_id.in_(ids), SafeBox.is_active.is_(True)).all()
            if sb.account_id is not None}

def _is_manual_like_journal_entry(entry: 'JournalEntry') -> bool:
    """Return True when a JournalEntry is manually created/edited (not system-generated).

    Manual entries (reference_type in '', 'manual', 'journal_entry') must NOT create
    SafeBoxTransaction rows — they are internal accounting transfers, not physical
    cash/gold movements.  Only system-generated entries (invoice, voucher, shift, etc.)
    should produce SBTs.
    """
    try:
        rt = (getattr(entry, 'reference_type', None) or '').strip().lower()
    except Exception:
        rt = ''
    return rt in ('', 'manual', 'journal_entry')


def _rebuild_safe_box_transactions_for_journal_entry(
    entry: 'JournalEntry',
    lines: list['JournalEntryLine'],
    created_by: str = None,
) -> None:
    """Rebuild SafeBoxTransaction rows for a JournalEntry (idempotent).

    - Deletes existing ref_type='journal_entry' rows for this entry.
    - Only creates movements for SafeBox-linked accounts.
    - Mirrors journal semantics: debit => in, credit => out.
    """
    if not entry or not getattr(entry, 'id', None):
        return

    try:
        existing = SafeBoxTransaction.query.filter_by(ref_type='journal_entry', ref_id=int(entry.id)).all()
        for tx in existing:
            db.session.delete(tx)
        db.session.flush()
    except Exception:
        pass

    try:
        if bool(getattr(entry, 'is_draft', False)):
            return
    except Exception:
        pass

    try:
        if hasattr(entry, 'is_posted') and (bool(getattr(entry, 'is_posted', False)) is not True):
            return
    except Exception:
        pass

    if _is_manual_like_journal_entry(entry):
        return

    j_lines = [l for l in (lines or []) if getattr(l, 'account_id', None) is not None]
    if not j_lines:
        return

    account_ids = list({int(l.account_id) for l in j_lines if l.account_id is not None})
    if not account_ids:
        return

    safe_by_account_id = row_safes_by_account(account_ids)

    if not safe_by_account_id:
        return

    notes = None
    try:
        notes = f"Journal entry {getattr(entry, 'entry_number', None) or entry.id}"
    except Exception:
        notes = None

    eps_cash = 0.005
    eps_w = 0.0005

    def _add_tx(*, sb_id: int, direction: str, amount_cash: float = 0.0, w18: float = 0.0, w21: float = 0.0, w22: float = 0.0, w24: float = 0.0):
        tx = SafeBoxTransaction(
            safe_box_id=int(sb_id),
            ref_type='journal_entry',
            ref_id=int(entry.id),
            direction=direction,
            amount_cash=float(amount_cash or 0.0),
            weight_18k=float(w18 or 0.0),
            weight_21k=float(w21 or 0.0),
            weight_22k=float(w22 or 0.0),
            weight_24k=float(w24 or 0.0),
            notes=notes,
            created_by=created_by,
        )
        db.session.add(tx)

    for line in j_lines:
        sb = safe_by_account_id.get(int(line.account_id))
        if not sb:
            continue

        try:
            cash_net = float(getattr(line, 'cash_debit', 0.0) or 0.0) - float(getattr(line, 'cash_credit', 0.0) or 0.0)
        except Exception:
            cash_net = 0.0

        if abs(cash_net) > eps_cash:
            _add_tx(
                sb_id=sb.id,
                direction='in' if cash_net > 0 else 'out',
                amount_cash=abs(float(cash_net)),
            )

        def _net(field_debit: str, field_credit: str) -> float:
            try:
                return float(getattr(line, field_debit, 0.0) or 0.0) - float(getattr(line, field_credit, 0.0) or 0.0)
            except Exception:
                return 0.0

        nets = {
            '18k': _net('debit_18k', 'credit_18k'),
            '21k': _net('debit_21k', 'credit_21k'),
            '22k': _net('debit_22k', 'credit_22k'),
            '24k': _net('debit_24k', 'credit_24k'),
        }
        pos = {k: v for k, v in nets.items() if v > eps_w}
        neg = {k: v for k, v in nets.items() if v < -eps_w}

        if pos:
            _add_tx(
                sb_id=sb.id,
                direction='in',
                w18=float(pos.get('18k') or 0.0),
                w21=float(pos.get('21k') or 0.0),
                w22=float(pos.get('22k') or 0.0),
                w24=float(pos.get('24k') or 0.0),
            )
        if neg:
            _add_tx(
                sb_id=sb.id,
                direction='out',
                w18=abs(float(neg.get('18k') or 0.0)),
                w21=abs(float(neg.get('21k') or 0.0)),
                w22=abs(float(neg.get('22k') or 0.0)),
                w24=abs(float(neg.get('24k') or 0.0)),
            )


def _ensure_safe_box_transactions_for_invoice_je(
    invoice_id: int,
    journal_entry_id: int,
    created_by: str = 'system',
):
    """Create missing SafeBoxTransactions for invoice JE lines that hit safe-box accounts.

    Idempotent: skips safe boxes that already have SBT rows from a voucher.
    """
    je = JournalEntry.query.get(journal_entry_id)
    if not je:
        return []

    je_lines = [l for l in (getattr(je, 'lines', None) or []) if not getattr(l, 'is_deleted', False)]
    if not je_lines:
        return []

    account_ids = list({int(l.account_id) for l in je_lines if getattr(l, 'account_id', None) is not None})
    safe_by_account_id: dict = row_safes_by_account(account_ids)

    if not safe_by_account_id:
        return []

    existing_sbt = SafeBoxTransaction.query.filter(
        SafeBoxTransaction.invoice_id == invoice_id,
    ).all()
    existing_sb_ids_with_cash = set()
    for sbt in existing_sbt:
        if abs(float(getattr(sbt, 'amount_cash', 0) or 0)) > 0.005:
            existing_sb_ids_with_cash.add(int(sbt.safe_box_id))

    linked_payment_method_id = None
    pm_by_safe_id = {}
    safe_ids = list({sb.id for sb in safe_by_account_id.values()})
    if safe_ids:
        for pm in PaymentMethod.query.filter(PaymentMethod.default_safe_box_id.in_(safe_ids)).all():
            if pm.default_safe_box_id and pm.default_safe_box_id not in pm_by_safe_id:
                pm_by_safe_id[pm.default_safe_box_id] = pm.id

    eps = 0.005
    created = []

    for line in je_lines:
        sb = safe_by_account_id.get(int(line.account_id))
        if not sb:
            continue

        if sb.id in existing_sb_ids_with_cash:
            continue

        cash_debit = float(getattr(line, 'cash_debit', 0) or 0)
        cash_credit = float(getattr(line, 'cash_credit', 0) or 0)

        if cash_debit > eps:
            tx = SafeBoxTransaction(
                safe_box_id=sb.id,
                ref_type='invoice',
                ref_id=invoice_id,
                invoice_id=invoice_id,
                payment_method_id=linked_payment_method_id or pm_by_safe_id.get(sb.id),
                direction='in',
                amount_cash=cash_debit,
                notes=f"Invoice #{invoice_id} - direct safe-box debit",
                created_by=created_by,
            )
            db.session.add(tx)
            created.append(tx)
            existing_sb_ids_with_cash.add(sb.id)

        if cash_credit > eps:
            tx = SafeBoxTransaction(
                safe_box_id=sb.id,
                ref_type='invoice',
                ref_id=invoice_id,
                invoice_id=invoice_id,
                payment_method_id=linked_payment_method_id or pm_by_safe_id.get(sb.id),
                direction='out',
                amount_cash=cash_credit,
                notes=f"Invoice #{invoice_id} - direct safe-box credit",
                created_by=created_by,
            )
            db.session.add(tx)
            created.append(tx)
            existing_sb_ids_with_cash.add(sb.id)

    return created
