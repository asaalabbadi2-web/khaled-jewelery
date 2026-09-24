"""Supplier domain routes — suppliers_bp registered under /api in app.py."""
from __future__ import annotations

from datetime import datetime, date, time, timedelta

from flask import Blueprint, request, jsonify
from sqlalchemy import func, or_, and_
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    Invoice,
    JournalEntry,
    JournalEntryLine,
    Office,
    OfficeReservation,
    SafeBox,
    Supplier,
    SupplierGoldTransaction,
)
from accounting.reference_number_service import generate_journal_entry_number
from core.database import _db_has_column
from core.dates import _parse_iso_date
from core.responses import _wrap_api_exceptions
from auth_decorators import require_permission
from party_account_service import ensure_supplier_accounts
from pricing.gold_price_service import get_current_gold_price
from services.party_live_balances import compute_live_supplier_balances
from pricing.karat_service import convert_to_main_karat, get_main_karat
from accounting.statement_verification import (
    _build_statement_qr_signed_payload,
    _sign_qr_payload,
    _build_qr_verify_token,
    _build_statement_verify_url,
)
from accounting.mappings import get_account_id_by_number

suppliers_bp = Blueprint('suppliers', __name__)

@suppliers_bp.route('/suppliers/next-code', methods=['GET'])
def get_next_supplier_code():
    """الحصول على الكود التالي المتاح للمورد"""
    from code_generator import generate_supplier_code, get_supplier_statistics

    stats = get_supplier_statistics()
    return jsonify({
        'next_code': generate_supplier_code(),
        'total_suppliers': stats['total_suppliers'],
        'remaining_capacity': stats['remaining_capacity']
    })

BALANCE_KEYS_BY_KARAT = (
    ('balance_cash', 'cash', 2),
    ('balance_gold_18k', '18k', 3),
    ('balance_gold_21k', '21k', 3),
    ('balance_gold_22k', '22k', 3),
    ('balance_gold_24k', '24k', 3),
)


def _live_balance_payload(supplier, *, prefetched=None) -> dict:
    """The supplier's cash/gold balance, derived from the ledger.

    The ONE place that produces these five JSON keys. They used to be columns
    on Supplier, incremented by create_dual_journal_entry(); that cache drifted
    from the ledger by 21,121.06 g across 24 suppliers in real production, so
    the columns are gone and every consumer reads this instead. The key names
    are unchanged on purpose — frontend/lib/screens/suppliers_screen.dart reads
    them as-is.

    Pass *prefetched* (the dict returned by compute_live_supplier_balances for
    a batch) to avoid one query per supplier in list endpoints.
    """
    if prefetched is None:
        prefetched = compute_live_supplier_balances([supplier])
    bal = prefetched.get(int(supplier.id)) or {}
    return {
        key: round(float(bal.get(source, 0.0) or 0.0), digits)
        for key, source, digits in BALANCE_KEYS_BY_KARAT
    }


def _current_balance_payload(supplier) -> dict:
    """The same derived balance under the ledger endpoint's key names
    ('cash', 'gold_18k', ...). Same single source, one query — it exists so a
    statement response can carry the authoritative balance next to the
    period-scoped movement without the two being confused.
    """
    live = _live_balance_payload(supplier)
    return {
        'cash': live['balance_cash'],
        'gold_18k': live['balance_gold_18k'],
        'gold_21k': live['balance_gold_21k'],
        'gold_22k': live['balance_gold_22k'],
        'gold_24k': live['balance_gold_24k'],
    }


@suppliers_bp.route('/suppliers', methods=['GET'])
def get_suppliers():
    suppliers = Supplier.query.all()

    office_by_supplier_id = {}
    try:
        office_rows = (
            db.session.query(Office.id, Office.office_code, Office.supplier_id)
            .filter(Office.supplier_id.isnot(None))
            .all()
        )
        for oid, ocode, sid in office_rows:
            if sid is None:
                continue
            try:
                office_by_supplier_id[int(sid)] = {
                    'office_id': int(oid) if oid is not None else None,
                    'office_code': str(ocode) if ocode is not None else None,
                }
            except Exception:
                continue
    except Exception:
        office_by_supplier_id = {}

    results = []
    balances_by_supplier = compute_live_supplier_balances(suppliers)

    for s in suppliers:
        data = s.to_dict()

        try:
            office_info = office_by_supplier_id.get(int(s.id))
            if office_info:
                data['is_closing_office'] = True
                data['closing_office_id'] = office_info.get('office_id')
                data['closing_office_code'] = office_info.get('office_code')
            else:
                data['is_closing_office'] = False
                data['closing_office_id'] = None
                data['closing_office_code'] = None
        except Exception:
            data['is_closing_office'] = False
            data['closing_office_id'] = None
            data['closing_office_code'] = None
        data.update(_live_balance_payload(s, prefetched=balances_by_supplier))

        results.append(data)

    return jsonify(results)

@suppliers_bp.route('/suppliers', methods=['POST'])
def add_supplier():
    """إضافة مورد جديد (النظام الهجين)"""
    from code_generator import generate_supplier_code, validate_supplier_code

    data = request.get_json() or {}

    def _boolish(value, default: bool = True) -> bool:
        if value is None:
            return default
        if isinstance(value, bool):
            return value
        if isinstance(value, (int, float)):
            return bool(value)
        if isinstance(value, str):
            return value.strip().lower() in ('1', 'true', 'yes', 'y', 'on')
        return bool(value)

    if 'name' not in data or not str(data.get('name') or '').strip():
        return jsonify({'error': 'الاسم مطلوب'}), 400

    if not data.get('force', False):
        _new_name = ' '.join(str(data['name']).strip().split())
        _new_name_no_spaces = _new_name.replace(' ', '').lower()
        _existing = Supplier.query.filter(
            db.func.lower(Supplier.name) == _new_name.lower()
        ).first()
        if _existing:
            return jsonify({
                'error': f'يوجد مورد بنفس الاسم بالفعل: "{_existing.name}" (كود: {_existing.supplier_code})',
                'existing_supplier_id': _existing.id,
                'existing_supplier_code': _existing.supplier_code,
            }), 409
        for _s in Supplier.query.with_entities(Supplier.id, Supplier.name, Supplier.supplier_code).all():
            if _s.name and _s.name.replace(' ', '').lower() == _new_name_no_spaces:
                return jsonify({
                    'error': f'يوجد مورد بأسم مشابه جداً: "{_s.name}" (كود: {_s.supplier_code}). أرسل "force": true للتجاوز.',
                    'similar_supplier_id': _s.id,
                    'similar_supplier_code': _s.supplier_code,
                }), 409

    try:
        supplier_code = data.get('supplier_code')
        if not supplier_code:
            supplier_code = generate_supplier_code()
        else:
            validation = validate_supplier_code(supplier_code)
            if not validation['is_valid']:
                return jsonify({'error': validation['message']}), 400

        requested_category_number = data.get('account_category_number')
        account_category = None
        if requested_category_number:
            requested_str = str(requested_category_number)
            if requested_str == '210':
                account_category = Account.query.filter_by(account_number='2100').first()
            if not account_category:
                account_category = Account.query.filter_by(account_number=requested_str).first()

        if not account_category:
            for fallback_number in ('2100', '220', '210', '21', '21100', '211'):
                account_category = Account.query.filter_by(account_number=fallback_number).first()
                if account_category:
                    break

        raw_wage_type = data.get('default_wage_type')
        wage_type = (raw_wage_type or 'cash')
        if not isinstance(wage_type, str):
            wage_type = str(wage_type)
        wage_type = wage_type.strip().lower()
        if wage_type not in ('cash', 'gold'):
            wage_type = 'cash'

        new_supplier = Supplier(
            supplier_code=supplier_code,
            name=data['name'],
            phone=data.get('phone'),
            email=data.get('email'),
            address_line_1=data.get('address_line_1'),
            address_line_2=data.get('address_line_2'),
            city=data.get('city'),
            state=data.get('state'),
            postal_code=data.get('postal_code'),
            country=data.get('country'),
            tax_number=data.get('tax_number'),
            classification=data.get('classification'),
            default_wage_type=wage_type,
            default_safe_box_id=None,
            account_category_id=account_category.id if account_category else None,
            balance_cash=0.0,
            balance_gold_18k=0.0,
            balance_gold_21k=0.0,
            balance_gold_22k=0.0,
            balance_gold_24k=0.0
        )
        db.session.add(new_supplier)
        db.session.flush()

        if 'default_safe_box_id' in data:
            raw_safe_box_id = data.get('default_safe_box_id')
            if raw_safe_box_id in (None, '', False):
                new_supplier.default_safe_box_id = None
            else:
                try:
                    safe_box_id = int(str(raw_safe_box_id).strip())
                except Exception:
                    safe_box_id = None
                safe_box = SafeBox.query.get(safe_box_id) if safe_box_id else None
                safe_type = (safe_box.safe_type or '').strip().lower() if safe_box else ''
                if not safe_box or not safe_box.is_active or safe_type not in ('cash', 'bank', 'gold'):
                    db.session.rollback()
                    return jsonify({'error': 'default_safe_box_id غير صالح'}), 400
                new_supplier.default_safe_box_id = safe_box.id

        ensure_accounts = _boolish(data.get('ensure_accounts'), True)
        if ensure_accounts:
            ensure_supplier_accounts(new_supplier)

        db.session.commit()

        return jsonify(new_supplier.to_dict_with_account()), 201

    except IntegrityError as e:
        db.session.rollback()
        if 'supplier_code' in str(e):
            return jsonify({'error': f'كود المورد {supplier_code} مستخدم بالفعل'}), 409
        return jsonify({'error': 'مورد بنفس البيانات موجود بالفعل'}), 409
    except Exception as e:
        db.session.rollback()
        import traceback
        traceback.print_exc()
        return jsonify({'error': 'حدث خطأ داخلي'}), 500

@suppliers_bp.route('/suppliers/<int:id>', methods=['PUT'])
def update_supplier(id):
    """تحديث بيانات المورد (النظام الهجين)"""
    supplier = Supplier.query.get_or_404(id)
    data = request.json

    supplier.name = data.get('name', supplier.name)
    supplier.phone = data.get('phone', supplier.phone)
    supplier.email = data.get('email', supplier.email)
    supplier.address_line_1 = data.get('address_line_1', supplier.address_line_1)
    supplier.address_line_2 = data.get('address_line_2', supplier.address_line_2)
    supplier.city = data.get('city', supplier.city)
    supplier.state = data.get('state', supplier.state)
    supplier.postal_code = data.get('postal_code', supplier.postal_code)
    supplier.country = data.get('country', supplier.country)

    supplier.tax_number = data.get('tax_number', supplier.tax_number)
    supplier.classification = data.get('classification', supplier.classification)

    if 'default_wage_type' in data:
        raw_wage_type = data.get('default_wage_type')
        wage_type = (raw_wage_type or 'cash')
        if not isinstance(wage_type, str):
            wage_type = str(wage_type)
        wage_type = wage_type.strip().lower()
        if wage_type in ('cash', 'gold'):
            supplier.default_wage_type = wage_type
        else:
            supplier.default_wage_type = 'cash'

    if 'default_safe_box_id' in data:
        raw_safe_box_id = data.get('default_safe_box_id')
        if raw_safe_box_id in (None, '', False):
            supplier.default_safe_box_id = None
        else:
            try:
                safe_box_id = int(str(raw_safe_box_id).strip())
            except Exception:
                safe_box_id = None
            safe_box = SafeBox.query.get(safe_box_id) if safe_box_id else None
            safe_type = (safe_box.safe_type or '').strip().lower() if safe_box else ''
            if not safe_box or not safe_box.is_active or safe_type not in ('cash', 'bank', 'gold'):
                return jsonify({'error': 'default_safe_box_id غير صالح'}), 400
            supplier.default_safe_box_id = safe_box.id

    if 'account_category_number' in data:
        account_category = Account.query.filter_by(account_number=data['account_category_number']).first()
        if account_category:
            supplier.account_category_id = account_category.id

    try:
        ensure_accounts = data.get('ensure_accounts')
        if ensure_accounts is None:
            ensure_accounts_bool = False
        elif isinstance(ensure_accounts, bool):
            ensure_accounts_bool = ensure_accounts
        elif isinstance(ensure_accounts, (int, float)):
            ensure_accounts_bool = bool(ensure_accounts)
        else:
            ensure_accounts_bool = str(ensure_accounts).strip().lower() in ('1', 'true', 'yes', 'y', 'on')

        if ensure_accounts_bool:
            ensure_supplier_accounts(supplier)
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'Failed to ensure supplier accounts: {str(exc)}'}), 500

    try:
        db.session.commit()
        payload = supplier.to_dict()
        payload.update(_live_balance_payload(supplier))
        return jsonify(payload)
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update supplier: {str(e)}'}), 500

@suppliers_bp.route('/suppliers/<int:id>', methods=['DELETE'])
def delete_supplier(id):
    supplier = Supplier.query.get_or_404(id)
    try:
        # Eligibility is decided on the ledger, never on a cached column. This
        # deliberately changes which suppliers can be deleted: one whose stored
        # balance read 0 while the ledger disagreed is now correctly blocked,
        # and one whose stale column was non-zero while the ledger is settled
        # is now correctly deletable.
        live = _live_balance_payload(supplier)
        cash_balance = float(live['balance_cash'])
        gold_balances = [
            float(live['balance_gold_18k']),
            float(live['balance_gold_21k']),
            float(live['balance_gold_22k']),
            float(live['balance_gold_24k']),
        ]

        has_cash_balance = abs(cash_balance) > 0.01
        has_gold_balance = any(abs(v) > 0.0005 for v in gold_balances)

        if has_cash_balance or has_gold_balance:
            return jsonify({
                'error': 'لا يمكن حذف/تعطيل المورد لوجود أرصدة (نقد/وزن). قم بتصفير الرصيد أولاً.',
                'code': 'supplier_has_balance',
            }), 400

        has_unposted_invoices = (
            Invoice.query
            .filter(Invoice.supplier_id == id)
            .filter(Invoice.is_posted.is_(False))
            .first()
            is not None
        )
        if has_unposted_invoices:
            return jsonify({
                'error': 'لا يمكن حذف المورد لوجود فواتير غير مُرحّلة/مسودات مرتبطة به.',
                'code': 'supplier_has_unposted_invoices',
            }), 400

        has_posted_invoices = (
            Invoice.query
            .filter(Invoice.supplier_id == id)
            .filter(Invoice.is_posted.is_(True))
            .first()
            is not None
        )

        has_journal_history = (
            JournalEntryLine.query
            .filter(JournalEntryLine.supplier_id == id)
            .filter(JournalEntryLine.is_deleted.is_(False))
            .first()
            is not None
        )

        if has_posted_invoices or has_journal_history:
            supplier.active = False
            db.session.commit()
            return jsonify({'result': 'success', 'action': 'deactivated'})

        if supplier.account_id:
            account = Account.query.get(supplier.account_id)
            if account:
                db.session.delete(account)

        db.session.delete(supplier)
        db.session.commit()
        return jsonify({'result': 'success', 'action': 'deleted'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to delete supplier: {str(e)}'}), 500

@suppliers_bp.route('/suppliers/<int:supplier_id>/ledger', methods=['GET'])
def get_supplier_ledger(supplier_id):
    """Return cash/weight ledger summary and movements for a supplier."""
    supplier = Supplier.query.get_or_404(supplier_id)

    def _parse_positive_int(param_name, default_value):
        raw_value = request.args.get(param_name, default_value)
        if raw_value in (None, ''):
            return default_value
        try:
            parsed = int(raw_value)
        except (TypeError, ValueError):
            raise ValueError(f'Invalid {param_name} parameter')
        return max(1, parsed)

    try:
        page = _parse_positive_int('page', 1)
        per_page = min(_parse_positive_int('per_page', 20), 100)
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    date_from_param = request.args.get('date_from')
    date_to_param = request.args.get('date_to')

    try:
        date_from_value = _parse_iso_date(date_from_param, 'date_from') if date_from_param else None
        date_to_value = _parse_iso_date(date_to_param, 'date_to') if date_to_param else None
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    date_from_dt = datetime.combine(date_from_value, datetime.min.time()) if date_from_value else None
    date_to_dt = datetime.combine(date_to_value, datetime.min.time()) + timedelta(days=1) if date_to_value else None

    supplier_fin_account_id = getattr(supplier, 'account_id', None)
    supplier_memo_account_id = None
    try:
        fin_acc = Account.query.get(int(supplier_fin_account_id)) if supplier_fin_account_id else None
        supplier_memo_account_id = getattr(fin_acc, 'memo_account_id', None) if fin_acc else None
    except Exception:
        supplier_memo_account_id = None

    payable_filter = and_(Account.type == 'Liability', Account.account_number.like('21%'))

    allowed_ids = []
    fallback_ids = []
    try:
        if supplier_fin_account_id not in (None, '', 0, '0', False):
            allowed_ids.append(int(supplier_fin_account_id))
            fallback_ids.append(int(supplier_fin_account_id))
    except Exception:
        pass
    try:
        if supplier_memo_account_id not in (None, '', 0, '0', False):
            allowed_ids.append(int(supplier_memo_account_id))
            fallback_ids.append(int(supplier_memo_account_id))
    except Exception:
        pass

    try:
        office_posting_acc = None
        raw_office_acc_id = None
        try:
            office_obj = getattr(supplier, 'office', None)
            raw_office_acc_id = getattr(office_obj, 'account_category_id', None) if office_obj else None
        except Exception:
            raw_office_acc_id = None
        if raw_office_acc_id not in (None, '', 0, '0', False):
            office_posting_acc = Account.query.get(int(raw_office_acc_id))
        if (
            office_posting_acc
            and bool(getattr(office_posting_acc, 'tracks_weight', False))
            and str(getattr(office_posting_acc, 'transaction_type', '') or '').lower() == 'both'
        ):
            allowed_ids.append(int(office_posting_acc.id))
            fallback_ids.append(int(office_posting_acc.id))
    except Exception:
        pass

    account_filter = payable_filter
    if allowed_ids:
        account_filter = or_(Account.id.in_(allowed_ids), payable_filter)

    supplier_line_filter = (JournalEntryLine.supplier_id == supplier_id)
    if fallback_ids:
        supplier_line_filter = or_(
            supplier_line_filter,
            and_(
                JournalEntryLine.account_id.in_(fallback_ids),
                JournalEntryLine.customer_id.is_(None),
            ),
        )

    # Exclude genuine unposted drafts (is_draft=True AND is_posted=False).
    # Posted entries must always appear even if is_draft was accidentally left True.
    _draft_posted_filter = or_(
        func.coalesce(JournalEntry.is_posted, False) == True,
        func.coalesce(JournalEntry.is_draft, False) == False,
    )
    base_query_relaxed = (
        JournalEntryLine.query
        .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
        .join(Account, JournalEntryLine.account_id == Account.id)
        .filter(supplier_line_filter)
        .filter(JournalEntryLine.is_deleted.is_(False))
        .filter(JournalEntry.is_deleted.is_(False))
        .filter(_draft_posted_filter)
    )

    base_query = base_query_relaxed.filter(account_filter)

    try:
        relaxed_count = base_query_relaxed.count()
        strict_count = base_query.count()
        if relaxed_count > strict_count:
            def _nets(q):
                row = (
                    q.with_entities(
                        func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.debit_18k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.credit_18k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.debit_21k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.credit_21k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.debit_22k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.credit_22k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.debit_24k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.credit_24k), 0.0),
                    ).first()
                )
                cd, cc, d18, c18, d21, c21, d22, c22, d24, c24 = row or (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                return (
                    float(cd or 0.0) - float(cc or 0.0),
                    float(d18 or 0.0) - float(c18 or 0.0),
                    float(d21 or 0.0) - float(c21 or 0.0),
                    float(d22 or 0.0) - float(c22 or 0.0),
                    float(d24 or 0.0) - float(c24 or 0.0),
                )

            strict_nets = _nets(base_query)
            relaxed_nets = _nets(base_query_relaxed)
            eps_cash = 0.01
            eps_gold = 0.0005
            if (
                abs(strict_nets[0] - relaxed_nets[0]) > eps_cash
                or any(abs(a - b) > eps_gold for a, b in zip(strict_nets[1:], relaxed_nets[1:]))
            ):
                base_query = base_query_relaxed
    except Exception:
        pass

    try:
        _cancelled_res_je_ids_ledger = (
            db.session.query(JournalEntry.id)
            .join(
                OfficeReservation,
                and_(
                    JournalEntry.reference_type == 'office_reservation',
                    JournalEntry.reference_id == OfficeReservation.id,
                ),
            )
            .filter(OfficeReservation.status.in_(['cancelled', 'rejected']))
            .subquery()
        )
        base_query = base_query.filter(JournalEntry.id.notin_(_cancelled_res_je_ids_ledger))
        base_query_relaxed = base_query_relaxed.filter(JournalEntry.id.notin_(_cancelled_res_je_ids_ledger))
    except Exception:
        pass

    if date_from_dt:
        base_query = base_query.filter(JournalEntry.date >= date_from_dt)
    if date_to_dt:
        base_query = base_query.filter(JournalEntry.date < date_to_dt)

    totals_row = (
        base_query
        .with_entities(
            func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0),
            func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0),
            func.coalesce(func.sum(JournalEntryLine.debit_18k), 0.0),
            func.coalesce(func.sum(JournalEntryLine.credit_18k), 0.0),
            func.coalesce(func.sum(JournalEntryLine.debit_21k), 0.0),
            func.coalesce(func.sum(JournalEntryLine.credit_21k), 0.0),
            func.coalesce(func.sum(JournalEntryLine.debit_22k), 0.0),
            func.coalesce(func.sum(JournalEntryLine.credit_22k), 0.0),
            func.coalesce(func.sum(JournalEntryLine.debit_24k), 0.0),
            func.coalesce(func.sum(JournalEntryLine.credit_24k), 0.0),
        )
        .first()
    )

    cash_debit_total, cash_credit_total, d18, c18, d21, c21, d22, c22, d24, c24 = totals_row or (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    total_items = base_query.count()
    total_pages = ((total_items + per_page - 1) // per_page) if total_items else 0

    lines = (
        base_query
        .options(joinedload(JournalEntryLine.account), joinedload(JournalEntryLine.journal_entry))
        .order_by(JournalEntry.date.desc(), JournalEntryLine.id.desc())
        .offset((page - 1) * per_page)
        .limit(per_page)
        .all()
    )

    movements = []
    for line in lines:
        journal_entry = line.journal_entry
        account = line.account
        movements.append({
            'journal_entry_id': line.journal_entry_id,
            'entry_number': journal_entry.entry_number if journal_entry else None,
            'date': journal_entry.date.isoformat() if journal_entry and journal_entry.date else None,
            'account_id': line.account_id,
            'account_name': account.name if account else None,
            'description': line.description or (journal_entry.description if journal_entry else None),
            'reference_type': journal_entry.reference_type if journal_entry else None,
            'reference_id': journal_entry.reference_id if journal_entry else None,
            'cash_debit': round(line.cash_debit or 0.0, 2),
            'cash_credit': round(line.cash_credit or 0.0, 2),
            'gold_18k_debit': round(line.debit_18k or 0.0, 3),
            'gold_18k_credit': round(line.credit_18k or 0.0, 3),
            'gold_21k_debit': round(line.debit_21k or 0.0, 3),
            'gold_21k_credit': round(line.credit_21k or 0.0, 3),
            'gold_22k_debit': round(line.debit_22k or 0.0, 3),
            'gold_22k_credit': round(line.credit_22k or 0.0, 3),
            'gold_24k_debit': round(line.debit_24k or 0.0, 3),
            'gold_24k_credit': round(line.credit_24k or 0.0, 3),
        })

    latest_entry_row = (
        base_query
        .order_by(JournalEntry.date.desc())
        .with_entities(JournalEntry.date)
        .first()
    )
    last_transaction_date = latest_entry_row[0].isoformat() if latest_entry_row and latest_entry_row[0] else None

    summary = {
        'supplier': {
            'id': supplier.id,
            'name': supplier.name,
            'code': supplier.supplier_code,
        },
        'total_entries': total_items,
        'total_debits': {
            'cash': round(cash_debit_total, 2),
            'gold_18k': round(d18, 3),
            'gold_21k': round(d21, 3),
            'gold_22k': round(d22, 3),
            'gold_24k': round(d24, 3),
        },
        'total_credits': {
            'cash': round(cash_credit_total, 2),
            'gold_18k': round(c18, 3),
            'gold_21k': round(c21, 3),
            'gold_22k': round(c22, 3),
            'gold_24k': round(c24, 3),
        },
        'net': {
            'cash': round((cash_debit_total or 0.0) - (cash_credit_total or 0.0), 2),
            'gold_18k': round((d18 or 0.0) - (c18 or 0.0), 3),
            'gold_21k': round((d21 or 0.0) - (c21 or 0.0), 3),
            'gold_22k': round((d22 or 0.0) - (c22 or 0.0), 3),
            'gold_24k': round((d24 or 0.0) - (c24 or 0.0), 3),
        },
        # The period's movement above ('total_debits'/'total_credits'/'net') is a
        # different question from the supplier's balance: it is scoped to the
        # requested date range. 'current_balance' is the authoritative answer,
        # from the same canonical function the suppliers list and
        # gold-reconciliation use — never a third query. Do not present 'net'
        # as the supplier's balance.
        'current_balance': _current_balance_payload(supplier),
        'last_transaction_date': last_transaction_date,
        'filters': {
            'date_from': date_from_value.isoformat() if date_from_value else None,
            'date_to': date_to_value.isoformat() if date_to_value else None,
        },
    }

    pagination = {
        'page': page,
        'per_page': per_page,
        'total_pages': total_pages,
        'total_items': total_items,
    }

    return jsonify({
        'summary': summary,
        'movements': movements,
        'pagination': pagination,
    })

@suppliers_bp.route('/suppliers/<int:supplier_id>/statement', methods=['GET'])
def get_supplier_weight_statement(supplier_id):
    """كشف حساب المورد (صيغة موحدة لشاشة كشف الحساب في Flutter)."""
    supplier = Supplier.query.get_or_404(supplier_id)
    main_karat = get_main_karat()

    def _safe_dt(value, fallback=None):
        if value is None:
            return fallback
        if isinstance(value, datetime):
            return value
        if isinstance(value, date):
            return datetime.combine(value, time.min)
        try:
            return datetime.fromisoformat(str(value))
        except Exception:
            return fallback

    def _iso_or_none(value):
        dt = _safe_dt(value)
        return dt.isoformat() if dt else None

    def _effective_entry_dt(je: 'JournalEntry'):
        if not je:
            return datetime.min
        primary = _safe_dt(getattr(je, 'date', None))
        posted = _safe_dt(getattr(je, 'posted_at', None))
        created = _safe_dt(getattr(je, 'created_at', None))
        if primary and getattr(primary, 'time', None) and primary.time() != time.min:
            return primary
        return posted or created or primary or datetime.min

    running_balance_cash = 0.0
    running_balances_gold = {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}

    opening_balance_cash = 0.0
    opening_balances_gold = {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}

    # IMPORTANT:
    # For a supplier statement we only want:
    # - Supplier payable cash lines (legacy filter: liability 21%)
    # - Supplier memo (weight) lines (gold payables + gold settlements)
    supplier_fin_account_id = getattr(supplier, 'account_id', None)
    supplier_memo_account_id = None
    try:
        fin_acc = Account.query.get(int(supplier_fin_account_id)) if supplier_fin_account_id else None
        supplier_memo_account_id = getattr(fin_acc, 'memo_account_id', None) if fin_acc else None
    except Exception:
        supplier_memo_account_id = None

    payable_filter = and_(Account.type == 'Liability', Account.account_number.like('21%'))
    allowed_ids = []
    fallback_ids = []
    try:
        if supplier_fin_account_id not in (None, '', 0, '0', False):
            allowed_ids.append(int(supplier_fin_account_id))
            fallback_ids.append(int(supplier_fin_account_id))
    except Exception:
        pass
    try:
        if supplier_memo_account_id not in (None, '', 0, '0', False):
            allowed_ids.append(int(supplier_memo_account_id))
            fallback_ids.append(int(supplier_memo_account_id))
    except Exception:
        pass

    try:
        office_posting_acc = None
        raw_office_acc_id = None
        try:
            office_obj = getattr(supplier, 'office', None)
            raw_office_acc_id = getattr(office_obj, 'account_category_id', None) if office_obj else None
        except Exception:
            raw_office_acc_id = None
        if raw_office_acc_id not in (None, '', 0, '0', False):
            office_posting_acc = Account.query.get(int(raw_office_acc_id))
        if (
            office_posting_acc
            and bool(getattr(office_posting_acc, 'tracks_weight', False))
            and str(getattr(office_posting_acc, 'transaction_type', '') or '').lower() == 'both'
        ):
            allowed_ids.append(int(office_posting_acc.id))
            fallback_ids.append(int(office_posting_acc.id))
    except Exception:
        pass

    account_filter = payable_filter
    if allowed_ids:
        account_filter = or_(Account.id.in_(allowed_ids), payable_filter)

    supplier_line_filter = (JournalEntryLine.supplier_id == supplier_id)
    if fallback_ids:
        supplier_line_filter = or_(
            supplier_line_filter,
            and_(
                JournalEntryLine.account_id.in_(fallback_ids),
                JournalEntryLine.customer_id == None,  # noqa: E711
            ),
        )

    # Exclude genuine unposted drafts (is_draft=True AND is_posted=False).
    # Posted entries must always appear even if is_draft was accidentally left True.
    _draft_posted_filter = or_(
        func.coalesce(JournalEntry.is_posted, False) == True,
        func.coalesce(JournalEntry.is_draft, False) == False,
    )
    base_query_relaxed = (
        JournalEntryLine.query
        .join(JournalEntry)
        .join(Account, JournalEntryLine.account_id == Account.id)
        .filter(supplier_line_filter)
        .filter(JournalEntryLine.is_deleted.is_(False))
        .filter(JournalEntry.is_deleted.is_(False))
        .filter(_draft_posted_filter)
    )

    base_query = base_query_relaxed.filter(account_filter)

    try:
        relaxed_count = base_query_relaxed.count()
        strict_count = base_query.count()
        if relaxed_count > strict_count:
            def _nets(q):
                row = (
                    q.with_entities(
                        func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.debit_18k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.credit_18k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.debit_21k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.credit_21k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.debit_22k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.credit_22k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.debit_24k), 0.0),
                        func.coalesce(func.sum(JournalEntryLine.credit_24k), 0.0),
                    ).first()
                )
                cd, cc, d18, c18, d21, c21, d22, c22, d24, c24 = row or (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                return (
                    float(cd or 0.0) - float(cc or 0.0),
                    float(d18 or 0.0) - float(c18 or 0.0),
                    float(d21 or 0.0) - float(c21 or 0.0),
                    float(d22 or 0.0) - float(c22 or 0.0),
                    float(d24 or 0.0) - float(c24 or 0.0),
                )

            strict_nets = _nets(base_query)
            relaxed_nets = _nets(base_query_relaxed)
            eps_cash = 0.01
            eps_gold = 0.0005
            if (
                abs(strict_nets[0] - relaxed_nets[0]) > eps_cash
                or any(abs(a - b) > eps_gold for a, b in zip(strict_nets[1:], relaxed_nets[1:]))
            ):
                base_query = base_query_relaxed
    except Exception:
        pass

    try:
        _cancelled_res_je_ids = (
            db.session.query(JournalEntry.id)
            .join(
                OfficeReservation,
                and_(
                    JournalEntry.reference_type == 'office_reservation',
                    JournalEntry.reference_id == OfficeReservation.id,
                ),
            )
            .filter(OfficeReservation.status.in_(['cancelled', 'rejected']))
            .subquery()
        )
        base_query = base_query.filter(JournalEntry.id.notin_(_cancelled_res_je_ids))
        base_query_relaxed = base_query_relaxed.filter(JournalEntry.id.notin_(_cancelled_res_je_ids))
    except Exception:
        pass

    opening_lines = (
        base_query
        .filter(JournalEntry.entry_type == 'افتتاحي')
        .order_by(JournalEntry.date.asc(), JournalEntry.id.asc(), JournalEntryLine.id.asc())
        .all()
    )

    for line in opening_lines:
        opening_balance_cash += float(line.cash_debit or 0.0) - float(line.cash_credit or 0.0)
        opening_balances_gold['18k'] += float(line.debit_18k or 0.0) - float(line.credit_18k or 0.0)
        opening_balances_gold['21k'] += float(line.debit_21k or 0.0) - float(line.credit_21k or 0.0)
        opening_balances_gold['22k'] += float(line.debit_22k or 0.0) - float(line.credit_22k or 0.0)
        opening_balances_gold['24k'] += float(line.debit_24k or 0.0) - float(line.credit_24k or 0.0)

    opening_balance_gold_normalized = (
        convert_to_main_karat(opening_balances_gold['18k'], 18) +
        convert_to_main_karat(opening_balances_gold['21k'], 21) +
        convert_to_main_karat(opening_balances_gold['22k'], 22) +
        convert_to_main_karat(opening_balances_gold['24k'], 24)
    )

    running_balance_cash = float(opening_balance_cash or 0.0)
    running_balances_gold = opening_balances_gold.copy()

    journal_lines = (
        base_query
        .filter(JournalEntry.entry_type != 'افتتاحي')
        .order_by(JournalEntry.date.asc(), JournalEntry.id.asc(), JournalEntryLine.id.asc())
        .all()
    )

    try:
        journal_lines.sort(
            key=lambda l: (
                _effective_entry_dt(getattr(l, 'journal_entry', None)),
                int(getattr(getattr(l, 'journal_entry', None), 'id', 0) or 0),
                int(getattr(l, 'id', 0) or 0),
            )
        )
    except Exception:
        pass

    statement_lines = []
    total_cash_debit = 0.0
    total_cash_credit = 0.0
    total_gold_debit_normalized = 0.0
    total_gold_credit_normalized = 0.0

    for line in journal_lines:
        running_balances_gold['18k'] += (line.debit_18k or 0.0) - (line.credit_18k or 0.0)
        running_balances_gold['21k'] += (line.debit_21k or 0.0) - (line.credit_21k or 0.0)
        running_balances_gold['22k'] += (line.debit_22k or 0.0) - (line.credit_22k or 0.0)
        running_balances_gold['24k'] += (line.debit_24k or 0.0) - (line.credit_24k or 0.0)
        running_balance_cash += (line.cash_debit or 0.0) - (line.cash_credit or 0.0)

        gold_debit_normalized = (
            convert_to_main_karat(line.debit_18k or 0.0, 18) +
            convert_to_main_karat(line.debit_21k or 0.0, 21) +
            convert_to_main_karat(line.debit_22k or 0.0, 22) +
            convert_to_main_karat(line.debit_24k or 0.0, 24)
        )
        gold_credit_normalized = (
            convert_to_main_karat(line.credit_18k or 0.0, 18) +
            convert_to_main_karat(line.credit_21k or 0.0, 21) +
            convert_to_main_karat(line.credit_22k or 0.0, 22) +
            convert_to_main_karat(line.credit_24k or 0.0, 24)
        )

        statement_lines.append({
            'id': line.id,
            'date': _iso_or_none(_effective_entry_dt(getattr(line, 'journal_entry', None))),
            'description': (line.description or line.journal_entry.description or ''),
            'journal_entry_id': line.journal_entry_id,
            'entry_number': line.journal_entry.entry_number if line.journal_entry else None,
            'reference_type': line.journal_entry.reference_type if line.journal_entry else None,
            'reference_id': line.journal_entry.reference_id if line.journal_entry else None,
            'reference_number': line.journal_entry.reference_number if line.journal_entry else None,
            'cash_debit': line.cash_debit or 0.0,
            'cash_credit': line.cash_credit or 0.0,
            'gold_debit': gold_debit_normalized,
            'gold_credit': gold_credit_normalized,
            'debit_18k': line.debit_18k or 0.0,
            'credit_18k': line.credit_18k or 0.0,
            'debit_21k': line.debit_21k or 0.0,
            'credit_21k': line.credit_21k or 0.0,
            'debit_22k': line.debit_22k or 0.0,
            'credit_22k': line.credit_22k or 0.0,
            'debit_24k': line.debit_24k or 0.0,
            'credit_24k': line.credit_24k or 0.0,
        })

        total_cash_debit += float(line.cash_debit or 0.0)
        total_cash_credit += float(line.cash_credit or 0.0)
        total_gold_debit_normalized += float(gold_debit_normalized or 0.0)
        total_gold_credit_normalized += float(gold_credit_normalized or 0.0)

    closing_balance_gold_normalized = (
        convert_to_main_karat(running_balances_gold['18k'], 18) +
        convert_to_main_karat(running_balances_gold['21k'], 21) +
        convert_to_main_karat(running_balances_gold['22k'], 22) +
        convert_to_main_karat(running_balances_gold['24k'], 24)
    )

    price_snapshot = get_current_gold_price()
    price_main = float(price_snapshot.get('price_per_gram_main_karat', 0.0) or 0.0)
    closing_cash_value = float(running_balance_cash or 0.0)
    closing_gold_value = float(closing_balance_gold_normalized or 0.0)
    estimated_gold_value = closing_gold_value * price_main
    estimated_total_value = estimated_gold_value + closing_cash_value

    qr_account = None
    try:
        raw_acc_id = getattr(supplier, 'account_id', None)
        if raw_acc_id not in (None, '', 0, '0', False):
            qr_account = Account.query.get(int(raw_acc_id))
    except Exception:
        qr_account = None

    qr_issued_at = datetime.now().replace(microsecond=0).isoformat() + 'Z'
    qr_signed_payload = None
    qr_signature = None
    qr_verify_token = None
    qr_verify_url = None
    if qr_account is not None:
        qr_signed_payload = _build_statement_qr_signed_payload(
            account=qr_account,
            main_karat=main_karat,
            closing_gold_g=closing_gold_value,
            closing_cash=closing_cash_value,
            issued_at=qr_issued_at,
            is_merged=bool(supplier_memo_account_id),
        )
        qr_signature = _sign_qr_payload(qr_signed_payload)
        qr_verify_token = _build_qr_verify_token(signed_payload=qr_signed_payload, signature=qr_signature)
        qr_verify_url = _build_statement_verify_url(qr_verify_token)

    return jsonify({
        'account_name': supplier.name,
        'main_karat': main_karat,
        'qr_issued_at': qr_issued_at,
        'qr_signed_payload': qr_signed_payload,
        'qr_signature': qr_signature,
        'qr_verify_token': qr_verify_token,
        'qr_verify_url': qr_verify_url,
        'gold_price_snapshot': price_snapshot,
        'valuation': {
            'price_per_gram_main_karat': round(price_main, 4),
            'gold_value_estimate': round(estimated_gold_value, 2),
            'total_value_estimate': round(estimated_total_value, 2),
        },
        'opening_balance_cash': float(opening_balance_cash or 0.0),
        'opening_balance_gold_normalized': float(opening_balance_gold_normalized or 0.0),
        'opening_balance_gold_details': opening_balances_gold,
        'lines': statement_lines,
        'totals': {
            'cash_debit': total_cash_debit,
            'cash_credit': total_cash_credit,
            'gold_debit_normalized': total_gold_debit_normalized,
            'gold_credit_normalized': total_gold_credit_normalized,
        },
        'closing_balance_cash': running_balance_cash,
        'closing_balance_gold_normalized': closing_balance_gold_normalized,
        'closing_balance_gold_details': running_balances_gold,
    })

@suppliers_bp.route('/suppliers/<int:supplier_id>/weight-summary', methods=['GET'])
def get_supplier_weight_summary(supplier_id):
    """ملخص أرصدة المورد بالوزن + قيمة تقييمية (للإظهار فقط)."""
    supplier = Supplier.query.get_or_404(supplier_id)

    gold_price_data = get_current_gold_price()
    price_24k = gold_price_data.get('price_per_gram_24k', 0) or 0

    prices_by_karat = {
        '18': round(price_24k * 18 / 24, 2),
        '21': round(price_24k * 21 / 24, 2),
        '22': round(price_24k * 22 / 24, 2),
        '24': round(price_24k, 2),
    }

    # Derived, not cached: this endpoint multiplies these weights by live gold
    # prices to produce monetary valuations, so a stale weight became a wrong
    # money figure on screen.
    live = _live_balance_payload(supplier)
    balances = {
        'weight_18k': live['balance_gold_18k'],
        'weight_21k': live['balance_gold_21k'],
        'weight_22k': live['balance_gold_22k'],
        'weight_24k': live['balance_gold_24k'],
    }

    valuations = {
        '18k': round(balances['weight_18k'] * prices_by_karat['18'], 2),
        '21k': round(balances['weight_21k'] * prices_by_karat['21'], 2),
        '22k': round(balances['weight_22k'] * prices_by_karat['22'], 2),
        '24k': round(balances['weight_24k'] * prices_by_karat['24'], 2),
    }

    main_karat = gold_price_data.get('main_karat', 21)
    total_weight_main_karat = round(
        (balances['weight_18k'] * 18 / main_karat) +
        (balances['weight_21k'] * 21 / main_karat) +
        (balances['weight_22k'] * 22 / main_karat) +
        (balances['weight_24k'] * 24 / main_karat),
        3
    )

    total_valuation = round(sum(valuations.values()), 2)

    return jsonify({
        'supplier': {
            'id': supplier.id,
            'name': supplier.name,
            'code': supplier.supplier_code,
        },
        'balances': {
            'weights': balances,
            'valuations': valuations,
            'total_weight_main_karat': total_weight_main_karat,
            'total_valuation': total_valuation,
        },
        'pricing': {
            'prices_per_gram': prices_by_karat,
            'price_24k': price_24k,
            'main_karat': main_karat,
            'price_source': gold_price_data.get('source'),
            'price_updated_at': gold_price_data.get('updated_at'),
        },
        'notes': [
            '⚠️ الوزن المعروض هو الرصيد الفعلي للمورد',
            '💰 القيمة المعروضة هي تقييمية فقط (بسعر اليوم)',
            '📌 المورد دائن بالوزن وليس بالنقد',
            f'📊 السعر المستخدم: {price_24k:.2f} ريال/جرام عيار 24',
        ]
    })

@suppliers_bp.route('/suppliers/<int:supplier_id>/send-gold', methods=['POST'])
@require_permission('suppliers.edit')
def supplier_send_gold(supplier_id):
    """
    إرسال ذهب من المخزون للمورد (للتصنيع).

    Body:
    {
        "weights": {"21": 10.5},      // أوزان مقسّمة بالعيار
        "inventory_account_id": 71310, // حساب المخزون الوزني المصدر
        "date": "2026-04-03",          // تاريخ الإرسال (اختياري)
        "notes": "إرسال للمصنع"        // ملاحظات (اختياري)
    }
    """
    from je_adapter import send_to_supplier_je

    supplier = Supplier.query.get_or_404(supplier_id)

    data = request.get_json(force=True, silent=True) or {}

    weights_raw = data.get('weights') or {}
    if not weights_raw or not any(float(v or 0) > 0 for v in weights_raw.values()):
        return jsonify({'error': 'يجب تحديد أوزان صحيحة (weights)'}), 400

    inventory_account_id = data.get('inventory_account_id')
    if not inventory_account_id:
        inventory_account_id = get_account_id_by_number('71310')
    if not inventory_account_id:
        return jsonify({'error': 'لم يُحدَّد حساب المخزون الوزني المصدر'}), 400

    supplier_financial_account = Account.query.get(supplier.account_id) if supplier.account_id else None
    if not supplier_financial_account:
        return jsonify({'error': 'لا يوجد حساب محاسبي مرتبط بالمورد'}), 400

    raw_date = data.get('date')
    try:
        entry_date = datetime.strptime(raw_date, '%Y-%m-%d') if raw_date else datetime.now()
    except ValueError:
        entry_date = datetime.now()

    notes = str(data.get('notes') or 'إرسال ذهب للمصنع')
    entry_number = generate_journal_entry_number(entry_date=entry_date)

    try:
        journal_entry = JournalEntry(
            entry_number=entry_number,
            date=entry_date,
            description=f"{notes} - {supplier.name}",
            entry_type='عادي',
            reference_type='supplier_send_gold',
            reference_id=supplier_id,
            created_by='system',
        )
        db.session.add(journal_entry)
        db.session.flush()

        send_to_supplier_je(
            journal_entry_id=journal_entry.id,
            supplier_account_obj=supplier_financial_account,
            gold_by_karat=weights_raw,
            inventory_account_id=int(inventory_account_id),
            supplier_id=supplier_id,
        )

        total_weight = sum(float(v or 0) for v in weights_raw.values())
        txn = SupplierGoldTransaction(
            supplier_id=supplier_id,
            journal_entry_id=journal_entry.id,
            transaction_type='إرسال للمصنع',
            gold_weight=round(total_weight, 3),
            price_per_gram=0.0,
            cash_amount=0.0,
            notes=notes,
            transaction_date=entry_date,
        )
        db.session.add(txn)
        db.session.commit()

        return jsonify({
            'success': True,
            'journal_entry_id': journal_entry.id,
            'entry_number': entry_number,
            'total_weight': round(total_weight, 3),
            'weights': weights_raw,
        }), 201

    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500
