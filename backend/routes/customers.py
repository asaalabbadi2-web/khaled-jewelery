"""Customer domain routes — customers_bp registered under /api in app.py."""
from __future__ import annotations

from datetime import datetime, date, time

from flask import Blueprint, request, jsonify
from auth_decorators import require_permission
from sqlalchemy.exc import IntegrityError

from models import db, Customer, Account, Invoice, JournalEntry, JournalEntryLine
from party_account_service import ensure_customer_accounts
from pricing.gold_price_service import get_current_gold_price
from pricing.karat_service import convert_to_main_karat, get_main_karat
from core.database import _db_has_column
from accounting.statement_verification import (
    _build_statement_qr_signed_payload,
    _sign_qr_payload,
    _build_qr_verify_token,
    _build_statement_verify_url,
)

customers_bp = Blueprint('customers', __name__)

@customers_bp.route('/customers/<int:id>', methods=['DELETE'])
@require_permission('customers.delete')
def delete_customer(id):
    customer = Customer.query.get_or_404(id)
    try:
        has_invoices = Invoice.query.filter_by(customer_id=id).first()
        if has_invoices:
            return jsonify({'error': 'لا يمكن حذف عميل نشط'}), 400

        has_journal_entries = JournalEntryLine.query.filter_by(customer_id=id).first()
        if has_journal_entries:
            return jsonify({'error': 'لا يمكن حذف عميل لديه قيود يومية'}), 400

        db.session.delete(customer)
        db.session.commit()
        return jsonify({'result': 'success'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to delete customer: {str(e)}'}), 500

@customers_bp.route('/customers/<int:id>/statement', methods=['GET'])
@require_permission('reports.customers')
def get_customer_statement(id):
    """كشف حساب العميل (صيغة موحدة لشاشة كشف الحساب في Flutter).

    IMPORTANT:
    The Flutter screen expects the same schema as `/accounts/<id>/statement`:
      - opening_balance_cash/opening_balance_gold_normalized/opening_balance_gold_details
      - lines[] with cash_debit/cash_credit/gold_debit/gold_credit + karat breakdown
      - totals + closing balances

    We keep the older shape under legacy_* keys for backward compatibility.
    """

    customer = Customer.query.get_or_404(id)
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

    from services.party_live_balances import all_customer_own_account_ids, customer_line_clause
    _own_all = all_customer_own_account_ids()
    # A customer's lines: its own account's, tagged or not, plus those tagged to
    # it on shared customer accounts -- one rule with the list (BALANCE-001 B1).
    opening_filters = [
        customer_line_clause(id, customer.account_id, _own_all),
        JournalEntry.entry_type == 'افتتاحي',
        JournalEntry.is_deleted == False,
        JournalEntryLine.is_deleted == False,
    ]
    if _db_has_column('journal_entry', 'is_posted'):
        opening_filters.append(JournalEntry.is_posted == True)
    if _db_has_column('journal_entry', 'is_draft'):
        opening_filters.append(JournalEntry.is_draft == False)

    opening_journal_lines = (
        JournalEntryLine.query
        .join(JournalEntry)
        .join(Account, JournalEntryLine.account_id == Account.id)
        .filter(*opening_filters)
        .filter(Account.type == 'Asset')
        .filter(Account.account_number.like('12%'))
        .all()
    )

    for line in opening_journal_lines:
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

    journal_filters = [
        customer_line_clause(id, customer.account_id, _own_all),
        JournalEntry.entry_type != 'افتتاحي',
        JournalEntry.is_deleted == False,
        JournalEntryLine.is_deleted == False,
    ]
    if _db_has_column('journal_entry', 'is_posted'):
        journal_filters.append(JournalEntry.is_posted == True)
    if _db_has_column('journal_entry', 'is_draft'):
        journal_filters.append(JournalEntry.is_draft == False)

    # IMPORTANT:
    # The DB may tag `customer_id` on multiple lines within the same journal entry
    # (inventory/tax/etc). For a customer statement we only want the line(s)
    # affecting receivable accounts, otherwise debits/credits cancel out.
    journal_lines = (
        JournalEntryLine.query
        .join(JournalEntry)
        .join(Account, JournalEntryLine.account_id == Account.id)
        .filter(*journal_filters)
        .filter(Account.type == 'Asset')
        .filter(Account.account_number.like('12%'))
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

    legacy_lines = []

    for line in journal_lines:
        je = getattr(line, 'journal_entry', None)
        if not je:
            continue

        running_balances_gold['18k'] += float(line.debit_18k or 0.0) - float(line.credit_18k or 0.0)
        running_balances_gold['21k'] += float(line.debit_21k or 0.0) - float(line.credit_21k or 0.0)
        running_balances_gold['22k'] += float(line.debit_22k or 0.0) - float(line.credit_22k or 0.0)
        running_balances_gold['24k'] += float(line.debit_24k or 0.0) - float(line.credit_24k or 0.0)
        running_balance_cash += float(line.cash_debit or 0.0) - float(line.cash_credit or 0.0)

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
            'date': _iso_or_none(_effective_entry_dt(je)),
            'description': (line.description or je.description or ''),
            'journal_entry_id': line.journal_entry_id,
            'entry_number': je.entry_number,
            'reference_type': je.reference_type,
            'reference_id': je.reference_id,
            'reference_number': je.reference_number,
            'cash_debit': float(line.cash_debit or 0.0),
            'cash_credit': float(line.cash_credit or 0.0),
            'gold_debit': float(gold_debit_normalized or 0.0),
            'gold_credit': float(gold_credit_normalized or 0.0),
            'debit_18k': float(line.debit_18k or 0.0),
            'credit_18k': float(line.credit_18k or 0.0),
            'debit_21k': float(line.debit_21k or 0.0),
            'credit_21k': float(line.credit_21k or 0.0),
            'debit_22k': float(line.debit_22k or 0.0),
            'credit_22k': float(line.credit_22k or 0.0),
            'debit_24k': float(line.debit_24k or 0.0),
            'credit_24k': float(line.credit_24k or 0.0),
        })

        total_cash_debit += float(line.cash_debit or 0.0)
        total_cash_credit += float(line.cash_credit or 0.0)
        total_gold_debit_normalized += float(gold_debit_normalized or 0.0)
        total_gold_credit_normalized += float(gold_credit_normalized or 0.0)

        legacy_lines.append({
            'id': line.id,
            'date': _iso_or_none(_effective_entry_dt(je)),
            'entry_number': je.entry_number,
            'description': je.description,
            'account_number': line.account.account_number if line.account else None,
            'account_name': line.account.name if line.account else None,
            'debit_cash': float(line.cash_debit or 0.0),
            'credit_cash': float(line.cash_credit or 0.0),
            'debit_gold_18k': float(line.debit_18k or 0.0),
            'credit_gold_18k': float(line.credit_18k or 0.0),
            'debit_gold_21k': float(line.debit_21k or 0.0),
            'credit_gold_21k': float(line.credit_21k or 0.0),
            'debit_gold_22k': float(line.debit_22k or 0.0),
            'credit_gold_22k': float(line.credit_22k or 0.0),
            'debit_gold_24k': float(line.debit_24k or 0.0),
            'credit_gold_24k': float(line.credit_24k or 0.0),
        })

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
        raw_acc_id = getattr(customer, 'account_id', None)
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
            is_merged=False,
        )
        qr_signature = _sign_qr_payload(qr_signed_payload)
        qr_verify_token = _build_qr_verify_token(signed_payload=qr_signed_payload, signature=qr_signature)
        qr_verify_url = _build_statement_verify_url(qr_verify_token)

    return jsonify({
        'account_name': customer.name,
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
            'cash_debit': float(total_cash_debit or 0.0),
            'cash_credit': float(total_cash_credit or 0.0),
            'gold_debit_normalized': float(total_gold_debit_normalized or 0.0),
            'gold_credit_normalized': float(total_gold_credit_normalized or 0.0),
        },
        'closing_balance_cash': float(running_balance_cash or 0.0),
        'closing_balance_gold_normalized': float(closing_balance_gold_normalized or 0.0),
        'closing_balance_gold_details': running_balances_gold,

        # Backward compatible fields
        'legacy_customer': customer.to_dict(),
        'legacy_statement': legacy_lines,
    })

@customers_bp.route('/customers/next-code', methods=['GET'])
@require_permission('customers.create')
def get_next_customer_code():
    """الحصول على الكود التالي المتاح للعميل"""
    from code_generator import generate_customer_code, get_customer_statistics

    stats = get_customer_statistics()
    return jsonify({
        'next_code': generate_customer_code(),
        'total_customers': stats['total_customers'],
        'remaining_capacity': stats['remaining_capacity']
    })

@customers_bp.route('/customers/gold-balances', methods=['GET'])
@require_permission('reports.customers')
def get_customers_gold_balances():
    """Official customer gold balances (memo ledger).

    Returns balances from the customer's linked memo account (Account.memo_account_id).
    Query params:
      - ensure_accounts=1: best-effort auto-create missing accounts.
    """

    ensure_flag = (request.args.get('ensure_accounts') or '').strip().lower()
    ensure_accounts = ensure_flag in ('1', 'true', 'yes', 'y', 'on')

    customers = Customer.query.order_by(Customer.name.asc()).all()
    results = []

    for c in customers:
        financial = Account.query.get(c.account_id) if c.account_id else None

        if ensure_accounts and (not financial or not getattr(financial, 'memo_account_id', None)):
            try:
                party = ensure_customer_accounts(c)
                financial = party.financial
            except Exception:
                pass

        memo = None
        if financial and getattr(financial, 'memo_account_id', None):
            memo = Account.query.get(financial.memo_account_id)

        balances = {
            '18k': round(float(getattr(memo, 'balance_18k', 0.0) or 0.0), 3) if memo else 0.0,
            '21k': round(float(getattr(memo, 'balance_21k', 0.0) or 0.0), 3) if memo else 0.0,
            '22k': round(float(getattr(memo, 'balance_22k', 0.0) or 0.0), 3) if memo else 0.0,
            '24k': round(float(getattr(memo, 'balance_24k', 0.0) or 0.0), 3) if memo else 0.0,
        }

        results.append({
            'customer_id': c.id,
            'customer_code': c.customer_code,
            'customer_name': c.name,
            'financial_account_id': financial.id if financial else None,
            'financial_account_number': financial.account_number if financial else None,
            'memo_account_id': memo.id if memo else None,
            'memo_account_number': memo.account_number if memo else None,
            'balances': balances,
        })

    return jsonify(results)

@customers_bp.route('/customers', methods=['GET'])
@require_permission('customers.view')
def get_customers():
    customers = Customer.query.all()
    # The balance is the ledger's, read one way (BALANCE-001 B1) -- not the
    # cached columns, which update_balance() moved in nine places only.
    from services.party_live_balances import compute_live_customer_balances
    live = compute_live_customer_balances(customers)
    rows = []
    for c in customers:
        d = c.to_dict()
        bal = live.get(int(c.id)) or {}
        d['balance_cash'] = round(bal.get('cash', 0.0), 2)
        for k in ('18k', '21k', '22k', '24k'):
            d[f'balance_gold_{k}'] = round(bal.get(k, 0.0), 3)
        d['balance_source'] = 'ledger'
        rows.append(d)
    return jsonify(rows)

@customers_bp.route('/customers', methods=['POST'])
@require_permission('customers.create')
def add_customer():
    """إضافة عميل جديد (النظام الهجين)"""
    from code_generator import generate_customer_code

    data = request.json or {}

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

    # ✅ Prevent duplicate "cash customer" records created by invoices/screens.
    def _norm_name(value: str) -> str:
        try:
            return ' '.join(str(value or '').strip().split())
        except Exception:
            return str(value or '').strip()

    requested_name = _norm_name(data.get('name'))
    from models import CASH_CUSTOMER_NAMES as cash_customer_aliases
    if requested_name in cash_customer_aliases:
        try:
            from sqlalchemy import func

            existing_cash = (
                Customer.query
                .filter(func.trim(Customer.name) == requested_name)
                .order_by(
                    Customer.active.desc(),
                    Customer.id.asc(),
                )
                .first()
            )
            if existing_cash is not None:
                if not existing_cash.active:
                    existing_cash.active = True
                ensure_accounts = _boolish(data.get('ensure_accounts'), True)
                if ensure_accounts:
                    try:
                        ensure_customer_accounts(existing_cash)
                    except Exception:
                        pass

                try:
                    db.session.commit()
                except Exception:
                    db.session.rollback()

                return jsonify(existing_cash.to_dict_with_account()), 201
        except Exception:
            pass

    birth_date_str = data.get('birth_date')
    birth_date = None
    if birth_date_str:
        try:
            birth_date = datetime.strptime(birth_date_str, '%Y-%m-%d').date()
        except (ValueError, TypeError):
            pass

    try:
        customer_code = data.get('customer_code')
        if not customer_code:
            customer_code = generate_customer_code()

        account_category_number = data.get('account_category_number')
        account_category = None

        if account_category_number:
            account_category = Account.query.filter_by(account_number=str(account_category_number)).first()

        if not account_category:
            for fallback_number in ('1200', '1100', '120', '110'):
                account_category = Account.query.filter_by(account_number=fallback_number).first()
                if account_category:
                    break

        ensure_accounts = _boolish(data.get('ensure_accounts'), True)

        customer = Customer(
            customer_code=customer_code,
            name=data.get('name'),
            phone=data.get('phone'),
            email=data.get('email'),
            address_line_1=data.get('address_line_1'),
            address_line_2=data.get('address_line_2'),
            city=data.get('city'),
            state=data.get('state'),
            postal_code=data.get('postal_code'),
            country=data.get('country'),
            id_number=data.get('id_number'),
            birth_date=birth_date,
            id_version_number=data.get('id_version_number'),
            notes=data.get('notes'),
            active=data.get('active', True),
            account_category_id=account_category.id if account_category else None,
            balance_cash=0.0,
            balance_gold_18k=0.0,
            balance_gold_21k=0.0,
            balance_gold_22k=0.0,
            balance_gold_24k=0.0
        )
        db.session.add(customer)
        db.session.flush()

        if ensure_accounts:
            ensure_customer_accounts(customer)

        db.session.commit()

        return jsonify(customer.to_dict_with_account()), 201

    except IntegrityError as e:
        db.session.rollback()
        if 'customer_code' in str(e):
            return jsonify({'error': f'كود العميل {customer_code} مستخدم بالفعل'}), 409
        return jsonify({'error': 'عميل بنفس البيانات موجود بالفعل'}), 409
    except Exception as e:
        db.session.rollback()
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'An unexpected error occurred: {str(e)}'}), 500

@customers_bp.route('/customers/<int:id>', methods=['PUT'])
@require_permission('customers.edit')
def update_customer(id):
    """تحديث بيانات العميل (النظام الهجين)"""
    customer = Customer.query.get_or_404(id)
    data = request.json

    customer.name = data.get('name', customer.name)
    customer.phone = data.get('phone', customer.phone)
    customer.email = data.get('email', customer.email)
    customer.address_line_1 = data.get('address_line_1', customer.address_line_1)
    customer.address_line_2 = data.get('address_line_2', customer.address_line_2)
    customer.city = data.get('city', customer.city)
    customer.state = data.get('state', customer.state)
    customer.postal_code = data.get('postal_code', customer.postal_code)
    customer.country = data.get('country', customer.country)
    customer.id_number = data.get('id_number', customer.id_number)

    birth_date_str = data.get('birth_date')
    if birth_date_str:
        try:
            customer.birth_date = datetime.strptime(birth_date_str, '%Y-%m-%d').date()
        except (ValueError, TypeError):
            pass

    customer.id_version_number = data.get('id_version_number', customer.id_version_number)
    customer.notes = data.get('notes', customer.notes)
    customer.active = data.get('active', customer.active)

    if 'account_category_number' in data:
        account_category = Account.query.filter_by(account_number=data['account_category_number']).first()
        if account_category:
            customer.account_category_id = account_category.id

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
            ensure_customer_accounts(customer)
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'Failed to ensure customer accounts: {str(exc)}'}), 500

    try:
        db.session.commit()
        return jsonify(customer.to_dict_with_account())
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update customer: {str(e)}'}), 500
