#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""API Routes لإدارة مكاتب تسكير الذهب."""

from flask import Blueprint, request, jsonify
from auth_decorators import require_permission
from models import (
    db,
    Office,
    OfficeReservation,
    Account,
    SafeBox,
    Supplier,
    JournalEntry,
    JournalEntryLine,
    _configured_main_karat_f,
)
from office_supplier_service import ensure_office_supplier
from office_account_service import ensure_office_account
from party_account_service import ensure_supplier_accounts
from services.live_balances import live_balances_by_account_ids

from datetime import datetime

# إنشاء Blueprint
offices_bp = Blueprint('offices', __name__, url_prefix='/api/offices')


def _boolish(value, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        return value.strip().lower() in ('1', 'true', 'yes', 'y', 'on')
    return bool(value)


def _to_int_or_none(value):
    if value in (None, '', False):
        return None
    try:
        return int(str(value).strip())
    except Exception:
        return None


def _to_float_or_zero(value) -> float:
    if value in (None, '', False):
        return 0.0
    try:
        return float(value)
    except Exception:
        try:
            return float(str(value).strip())
        except Exception:
            return 0.0


def _weight_kwargs_for_main_karat(amount: float, side: str) -> dict:
    """Build {debit_XXk|credit_XXk: amount} based on configured main karat."""
    try:
        main = int(round(float(_configured_main_karat_f() or 21)))
    except Exception:
        main = 21
    if main not in (18, 21, 22, 24):
        main = 21

    side_key = (side or '').strip().lower()
    if side_key not in ('debit', 'credit'):
        side_key = 'debit'

    suffix = f'{main}k'
    return {f'{side_key}_{suffix}': round(float(amount), 3)}


def _ensure_office_gold_safe(office: Office, *, created_by: str = 'system') -> SafeBox:
    """Ensure the office has a dedicated gold SafeBox (multi-karat) linked to its office account."""
    if not office:
        raise ValueError('office is required')

    if not office.account_category_id:
        ensure_office_account(office)
        db.session.flush()

    office_account_id = int(office.account_category_id)
    office_account = Account.query.get(office_account_id)
    if not office_account:
        raise ValueError('office account not found')

    # ✅ Office gold safe must be linked to the memo (weight) account,
    # not the office bridge/cash-equivalent account.
    memo_account_id = getattr(office_account, 'memo_account_id', None)
    if not memo_account_id:
        # ensure_office_account() best-effort creates the memo, but guard anyway.
        ensure_office_account(office)
        db.session.flush()
        office_account = Account.query.get(office_account_id)
        memo_account_id = getattr(office_account, 'memo_account_id', None)
    if not memo_account_id:
        raise ValueError('office memo account missing; cannot link gold safe')

    memo_account_id = int(memo_account_id)

    # First: if a correct gold safe already exists on memo, reuse it.
    existing = SafeBox.query.filter_by(
        safe_type='gold',
        karat=None,
        account_id=memo_account_id,
    ).first()
    if existing:
        return existing

    # Legacy: office gold safe mistakenly linked to office_account_id.
    legacy = SafeBox.query.filter_by(
        safe_type='gold',
        karat=None,
        account_id=office_account_id,
    ).first()
    if legacy:
        legacy.account_id = memo_account_id
        db.session.add(legacy)
        db.session.flush()
        return legacy

    name = f'خزنة مكتب {office.name} - ذهب'
    safe = SafeBox(
        name=name,
        name_en=None,
        safe_type='gold',
        account_id=memo_account_id,
        karat=None,
        is_active=True,
        is_default=False,
        notes='خزنة ذهب خاصة بمكتب التسكير (متعددة العيارات)',
        created_by=created_by,
    )
    db.session.add(safe)
    db.session.flush()
    return safe


def _create_opening_entry_for_supplier(
    supplier: Supplier,
    opening_cash: float,
    opening_gold_main: float,
    *,
    created_by: str = 'system',
) -> None:
    """Create an افتتاحي JournalEntry for supplier opening balances (cash + main-karat weight)."""

    opening_cash = float(opening_cash or 0.0)
    opening_gold_main = float(opening_gold_main or 0.0)

    if abs(opening_cash) <= 0.0001 and abs(opening_gold_main) <= 0.0001:
        return

    accounts = ensure_supplier_accounts(supplier)
    supplier_fin_id = int(accounts.financial.id)
    supplier_memo_id = int(accounts.memo.id)

    # Equity offset account (varies by COA version).
    # Legacy used 31/32. Current system may use 3600 (with memo 7600).
    equity_fin = (
        Account.query.filter_by(account_number='32').first()
        or Account.query.filter_by(account_number='31').first()
        or Account.query.filter_by(account_number='3600').first()
        or Account.query.filter_by(type='Equity', tracks_weight=False).first()
        or Account.query.filter_by(type='Equity').first()
    )
    if not equity_fin:
        raise ValueError('تعذر العثور على حساب حقوق الملكية لتسجيل الرصيد الافتتاحي')

    equity_memo_id = getattr(equity_fin, 'memo_account_id', None)
    if not equity_memo_id:
        try:
            equity_fin.create_parallel_account()
            db.session.flush()
        except Exception:
            pass
        equity_memo_id = getattr(equity_fin, 'memo_account_id', None)

    now = datetime.now()
    entry = JournalEntry(
        date=now,
        description=f'رصيد افتتاحي للمورد: {supplier.name}',
        entry_type='افتتاحي',
        reference_type='supplier',
        reference_id=int(supplier.id),
        created_by=created_by,
        is_draft=False,
        is_posted=True,
        posted_at=now,
        posted_by=created_by,
    )
    db.session.add(entry)
    db.session.flush()

    if abs(opening_cash) > 0.0001:
        cash_amt = round(abs(opening_cash), 2)
        supplier_side = 'debit' if opening_cash >= 0 else 'credit'
        equity_side = 'credit' if supplier_side == 'debit' else 'debit'
        supplier_cash_kwargs = {'cash_debit': cash_amt} if supplier_side == 'debit' else {'cash_credit': cash_amt}
        equity_cash_kwargs = {'cash_credit': cash_amt} if equity_side == 'credit' else {'cash_debit': cash_amt}

        db.session.add(
            JournalEntryLine(
                journal_entry_id=entry.id,
                account_id=supplier_fin_id,
                supplier_id=int(supplier.id),
                description='رصيد افتتاحي نقدي للمورد',
                **supplier_cash_kwargs,
            )
        )
        db.session.add(
            JournalEntryLine(
                journal_entry_id=entry.id,
                account_id=int(equity_fin.id),
                description='رصيد افتتاحي (مقابل) - حقوق الملكية',
                **equity_cash_kwargs,
            )
        )

    if abs(opening_gold_main) > 0.0001:
        gold_amt = round(abs(opening_gold_main), 3)
        supplier_side = 'debit' if opening_gold_main >= 0 else 'credit'
        equity_side = 'credit' if supplier_side == 'debit' else 'debit'
        supplier_weight_kwargs = _weight_kwargs_for_main_karat(gold_amt, supplier_side)

        db.session.add(
            JournalEntryLine(
                journal_entry_id=entry.id,
                account_id=supplier_memo_id,
                supplier_id=int(supplier.id),
                description='رصيد افتتاحي ذهب للمورد (مكافئ العيار الرئيسي)',
                **supplier_weight_kwargs,
            )
        )

        if equity_memo_id:
            equity_weight_kwargs = _weight_kwargs_for_main_karat(gold_amt, equity_side)
            db.session.add(
                JournalEntryLine(
                    journal_entry_id=entry.id,
                    account_id=int(equity_memo_id),
                    description='رصيد افتتاحي ذهب (مقابل) - حقوق الملكية',
                    **equity_weight_kwargs,
                )
            )


@offices_bp.route('', methods=['GET'])
def get_offices():
    """
    الحصول على قائمة المكاتب
    """
    try:
        active_param = request.args.get('active')
        query = db.session.query(Office)
        if active_param is not None:
            normalized = str(active_param).strip().lower()
            if normalized in ('1', 'true', 'yes', 'active'):
                query = query.filter(Office.active.is_(True))
            elif normalized in ('0', 'false', 'no', 'inactive'):
                query = query.filter(Office.active.is_(False))

        offices = query.all()

        from services.party_live_balances import compute_live_supplier_balances

        supplier_ids = []
        account_ids = []
        for office in offices:
            if getattr(office, 'supplier_id', None):
                try:
                    supplier_ids.append(int(office.supplier_id))
                except Exception:
                    pass
            if getattr(office, 'account_category_id', None):
                try:
                    account_ids.append(int(office.account_category_id))
                except Exception:
                    pass

        supplier_rows = Supplier.query.filter(Supplier.id.in_(list({int(x) for x in supplier_ids if x}))).all() if supplier_ids else []
        balances_by_supplier = compute_live_supplier_balances(supplier_rows) if supplier_rows else {}
        live_map = live_balances_by_account_ids(account_ids) if account_ids else {}

        results = []
        for office in offices:
            data = office.to_dict()

            bal = None
            try:
                sid = data.get('supplier_id')
                if sid not in (None, '', 0, '0', False):
                    bal = balances_by_supplier.get(int(sid))
            except Exception:
                bal = None

            if isinstance(bal, dict):
                data['balance_cash'] = round(float(bal.get('cash', 0.0) or 0.0), 2)
                data['balance_gold_18k'] = round(float(bal.get('18k', 0.0) or 0.0), 3)
                data['balance_gold_21k'] = round(float(bal.get('21k', 0.0) or 0.0), 3)
                data['balance_gold_22k'] = round(float(bal.get('22k', 0.0) or 0.0), 3)
                data['balance_gold_24k'] = round(float(bal.get('24k', 0.0) or 0.0), 3)
            else:
                account_id = data.get('account_category_id')
                live = None
                try:
                    if account_id not in (None, '', 0, '0', False):
                        live = live_map.get(int(account_id))
                except Exception:
                    live = None

                if isinstance(live, dict):
                    data['balance_cash'] = float(live.get('cash') or 0.0)
                    data['balance_gold_18k'] = float(live.get('18k') or 0.0)
                    data['balance_gold_21k'] = float(live.get('21k') or 0.0)
                    data['balance_gold_22k'] = float(live.get('22k') or 0.0)
                    data['balance_gold_24k'] = float(live.get('24k') or 0.0)

            results.append(data)

        return jsonify(results), 200
    except Exception as e:
        print(f"❌ خطأ في جلب المكاتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>', methods=['GET'])
def get_office(office_id):
    """الحصول على تفاصيل مكتب معين"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404
        
        data = office.to_dict()

        from services.party_live_balances import compute_live_supplier_balances

        bal = None
        try:
            sid = data.get('supplier_id')
            if sid not in (None, '', 0, '0', False):
                supplier = Supplier.query.get(int(sid))
                balances_by_supplier = compute_live_supplier_balances([supplier]) if supplier else {}
                bal = balances_by_supplier.get(int(sid))
        except Exception:
            bal = None

        if isinstance(bal, dict):
            data['balance_cash'] = round(float(bal.get('cash', 0.0) or 0.0), 2)
            data['balance_gold_18k'] = round(float(bal.get('18k', 0.0) or 0.0), 3)
            data['balance_gold_21k'] = round(float(bal.get('21k', 0.0) or 0.0), 3)
            data['balance_gold_22k'] = round(float(bal.get('22k', 0.0) or 0.0), 3)
            data['balance_gold_24k'] = round(float(bal.get('24k', 0.0) or 0.0), 3)
        else:
            account_id = data.get('account_category_id')
            live = None
            try:
                if account_id not in (None, '', 0, '0', False):
                    live = live_balances_by_account_ids([int(account_id)]).get(int(account_id))
            except Exception:
                live = None

            if isinstance(live, dict):
                data['balance_cash'] = float(live.get('cash') or 0.0)
                data['balance_gold_18k'] = float(live.get('18k') or 0.0)
                data['balance_gold_21k'] = float(live.get('21k') or 0.0)
                data['balance_gold_22k'] = float(live.get('22k') or 0.0)
                data['balance_gold_24k'] = float(live.get('24k') or 0.0)

        return jsonify(data), 200
    
    except Exception as e:
        print(f"❌ خطأ في جلب المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('', methods=['POST'])
def create_office():
    """إنشاء مكتب جديد"""
    try:
        data = request.get_json()
        
        # التحقق من البيانات المطلوبة
        if not data.get('name'):
            return jsonify({'error': 'اسم المكتب مطلوب'}), 400
        
        # توليد كود المكتب
        from code_generator import generate_office_code
        office_code = generate_office_code()
        
        # إنشاء المكتب
        office = Office(
            office_code=office_code,
            name=data['name'],
            phone=data.get('phone'),
            email=data.get('email'),
            contact_person=data.get('contact_person'),
            address_line_1=data.get('address_line_1'),
            address_line_2=data.get('address_line_2'),
            city=data.get('city'),
            state=data.get('state'),
            postal_code=data.get('postal_code'),
            country=data.get('country', 'Saudi Arabia'),
            notes=data.get('notes'),
            license_number=data.get('license_number'),
            tax_number=data.get('tax_number'),
            active=data.get('active', True)
        )
        
        db.session.add(office)
        db.session.flush()

        # ربط حساب الخزينة/المكتب بالحساب المستهدف (يُستخدم لاحقاً في الصرف)
        # يمكن تحديده صراحةً من الواجهة لتجنب الربط التلقائي بحسابات أخرى.
        explicit_account_set = False
        if data.get('account_category_id') is not None:
            office.account_category_id = int(data['account_category_id'])
            explicit_account_set = True
        elif data.get('account_category_number'):
            requested_number = str(data['account_category_number']).strip()
            account_category = Account.query.filter_by(account_number=requested_number).first()
            if not account_category and requested_number == '21110':
                # Legacy default used by older office screens; map to current office parent.
                account_category = Account.query.filter_by(account_number='2200').first()
            if not account_category:
                return jsonify({'error': f"الحساب غير موجود: {data['account_category_number']}"}), 400
            office.account_category_id = account_category.id
            explicit_account_set = True

        # إذا لم يتم تحديد حساب صراحةً، يمكن إنشاء الحساب الافتراضي/التلقائي حسب النظام الحالي
        if data.get('create_account', True) and not explicit_account_set:
            ensure_office_account(office)

        # Auto-detect link mode: if supplier_id is provided without explicit mode, default to 'existing'
        _provided_supplier_id = _to_int_or_none(data.get('supplier_id') or data.get('existing_supplier_id'))
        supplier_link_mode = str(
            data.get('supplier_link_mode') or data.get('supplier_mode') or
            ('existing' if _provided_supplier_id else 'new')
        ).strip().lower()
        supplier = None

        if supplier_link_mode in ('existing', 'link', 'existing_supplier'):
            supplier_id = _to_int_or_none(data.get('supplier_id') or data.get('existing_supplier_id'))
            if not supplier_id:
                return jsonify({'error': 'يجب اختيار مورد موجود'}), 400
            supplier = Supplier.query.get(int(supplier_id))
            if not supplier:
                return jsonify({'error': 'المورد غير موجود'}), 404

            # Block re-link if supplier already belongs to another office
            try:
                existing_office = getattr(supplier, 'office', None)
                if existing_office and int(getattr(existing_office, 'id', 0) or 0) != int(office.id):
                    return jsonify({'error': 'هذا المورد مرتبط بمكتب آخر بالفعل'}), 400
            except Exception:
                pass

            office.supplier_id = supplier.id
            db.session.add(office)
        else:
            # Validation: prevent accidental duplicate supplier creation.
            # In "new supplier" mode the supplier name is derived from office.name.
            existing_same_name = Supplier.query.filter(Supplier.name == office.name).first()
            if existing_same_name is not None:
                return jsonify({'error': 'يوجد مورد بنفس اسم المكتب بالفعل. استخدم خيار (ربط بمورد موجود) بدلاً من إنشاء جديد.'}), 400
            supplier = ensure_office_supplier(office)

        # Default True to match ensure_customer_accounts/ensure_supplier_accounts'
        # own default at the direct /customers and /suppliers creation routes --
        # an office's supplier should never end up with an unlinked memo account
        # (see the مكاتب تسكير فورية واشخاص incident: its weight postings used
        # supplier.default_safe_box.account_id instead of memo_account_id
        # because this call was skipped at creation time).
        if _boolish(data.get('ensure_supplier_accounts'), default=True):
            ensure_supplier_accounts(supplier)

        gold_safe_link_mode = str(data.get('gold_safe_link_mode') or data.get('office_gold_safe_mode') or 'new').strip().lower()
        if gold_safe_link_mode in ('existing', 'link', 'existing_safe'):
            gold_safe_box_id = _to_int_or_none(
                data.get('gold_safe_box_id')
                or data.get('office_gold_safe_box_id')
                or data.get('supplier_default_safe_box_id')
            )
            if not gold_safe_box_id:
                return jsonify({'error': 'يجب اختيار خزنة ذهب موجودة'}), 400
            sb = SafeBox.query.get(int(gold_safe_box_id))
            if not sb or not sb.is_active or str(getattr(sb, 'safe_type', '') or '').strip().lower() != 'gold':
                return jsonify({'error': 'خزنة الذهب غير صالحة'}), 400
            supplier.default_safe_box_id = sb.id
            db.session.add(supplier)
        else:
            gold_safe = _ensure_office_gold_safe(office)
            supplier.default_safe_box_id = gold_safe.id
            db.session.add(supplier)

        opening_cash = _to_float_or_zero(data.get('opening_balance_cash'))
        opening_gold_main = _to_float_or_zero(data.get('opening_balance_gold_main_karat'))
        try:
            _create_opening_entry_for_supplier(
                supplier,
                opening_cash=opening_cash,
                opening_gold_main=opening_gold_main,
                created_by='system',
            )
        except Exception as exc:
            db.session.rollback()
            return jsonify({'error': f'فشل تسجيل الرصيد الافتتاحي: {str(exc)}'}), 400

        db.session.commit()
        
        print(f"✅ تم إنشاء المكتب: {office.office_code} - {office.name}")
        return jsonify(office.to_dict()), 201
    
    except Exception as e:
        db.session.rollback()
        print(f"❌ خطأ في إنشاء المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>', methods=['PUT'])
@require_permission('business.setup')
def update_office(office_id):
    """تحديث بيانات مكتب"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404
        
        data = request.get_json()
        
        # تحديث البيانات
        if 'name' in data:
            office.name = data['name']

        # تحديث الحساب المستهدف للخزينة/المكتب (من شجرة الحسابات)
        if 'account_category_id' in data and data['account_category_id'] is not None:
            office.account_category_id = int(data['account_category_id'])
        elif 'account_category_number' in data and data['account_category_number']:
            requested_number = str(data['account_category_number']).strip()
            account_category = Account.query.filter_by(account_number=requested_number).first()
            if not account_category and requested_number == '21110':
                account_category = Account.query.filter_by(account_number='2200').first()
            if not account_category:
                return jsonify({'error': f"الحساب غير موجود: {data['account_category_number']}"}), 400
            office.account_category_id = account_category.id
        
        if 'phone' in data:
            office.phone = data['phone']
        if 'email' in data:
            office.email = data['email']
        if 'contact_person' in data:
            office.contact_person = data['contact_person']
        if 'address_line_1' in data:
            office.address_line_1 = data['address_line_1']
        if 'address_line_2' in data:
            office.address_line_2 = data['address_line_2']
        if 'city' in data:
            office.city = data['city']
        if 'state' in data:
            office.state = data['state']
        if 'postal_code' in data:
            office.postal_code = data['postal_code']
        if 'country' in data:
            office.country = data['country']
        if 'notes' in data:
            office.notes = data['notes']
        if 'license_number' in data:
            office.license_number = data['license_number']
        if 'tax_number' in data:
            office.tax_number = data['tax_number']
        if 'active' in data:
            office.active = data['active']
        
        # Optional: link to an existing supplier (block if supplier already linked elsewhere)
        if data.get('supplier_link_mode') in ('existing', 'link', 'existing_supplier') or data.get('supplier_id'):
            supplier_id = _to_int_or_none(data.get('supplier_id') or data.get('existing_supplier_id'))
            if not supplier_id:
                return jsonify({'error': 'يجب اختيار مورد موجود'}), 400
            supplier = Supplier.query.get(int(supplier_id))
            if not supplier:
                return jsonify({'error': 'المورد غير موجود'}), 404
            try:
                existing_office = getattr(supplier, 'office', None)
                if existing_office and int(getattr(existing_office, 'id', 0) or 0) != int(office.id):
                    return jsonify({'error': 'هذا المورد مرتبط بمكتب آخر بالفعل'}), 400
            except Exception:
                pass
            office.supplier_id = supplier.id
            db.session.add(office)

        # Optional: gold safe strategy for supplier default safe
        if office.supplier:
            gold_safe_link_mode = str(data.get('gold_safe_link_mode') or '').strip().lower()
            if gold_safe_link_mode in ('existing', 'link', 'existing_safe') or 'gold_safe_box_id' in data:
                gold_safe_box_id = _to_int_or_none(data.get('gold_safe_box_id') or data.get('office_gold_safe_box_id'))
                if not gold_safe_box_id:
                    return jsonify({'error': 'يجب اختيار خزنة ذهب موجودة'}), 400
                sb = SafeBox.query.get(int(gold_safe_box_id))
                if not sb or not sb.is_active or str(getattr(sb, 'safe_type', '') or '').strip().lower() != 'gold':
                    return jsonify({'error': 'خزنة الذهب غير صالحة'}), 400
                office.supplier.default_safe_box_id = sb.id
                db.session.add(office.supplier)
            elif gold_safe_link_mode in ('new', 'create', 'create_new'):
                gold_safe = _ensure_office_gold_safe(office)
                office.supplier.default_safe_box_id = gold_safe.id
                db.session.add(office.supplier)

        # Optional: ensure supplier accounts (same default as creation -- see NOTE above)
        if office.supplier and _boolish(data.get('ensure_supplier_accounts'), default=True):
            ensure_supplier_accounts(office.supplier)

        db.session.commit()
        
        print(f"✅ تم تحديث المكتب: {office.office_code} - {office.name}")
        return jsonify(office.to_dict()), 200
    
    except Exception as e:
        db.session.rollback()
        print(f"❌ خطأ في تحديث المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>', methods=['DELETE'])
@require_permission('business.setup')
def delete_office(office_id):
    """حذف مكتب (soft delete)"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404
        
        # Soft delete - تعطيل المكتب بدلاً من حذفه
        office.active = False
        db.session.commit()
        
        print(f"✅ تم تعطيل المكتب: {office.office_code} - {office.name}")
        return jsonify({'message': 'تم تعطيل المكتب بنجاح'}), 200
    
    except Exception as e:
        db.session.rollback()
        print(f"❌ خطأ في حذف المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>/activate', methods=['POST'])
@require_permission('business.setup')
def activate_office(office_id):
    """تفعيل مكتب"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404
        
        office.active = True
        db.session.commit()
        
        print(f"✅ تم تفعيل المكتب: {office.office_code} - {office.name}")
        return jsonify(office.to_dict()), 200
    
    except Exception as e:
        db.session.rollback()
        print(f"❌ خطأ في تفعيل المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>/balance', methods=['GET'])
def get_office_balance(office_id):
    """الحصول على رصيد المكتب"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404

        from services.party_live_balances import compute_live_supplier_balances

        supplier_bal = None
        try:
            if getattr(office, 'supplier_id', None) not in (None, '', 0, '0', False):
                supplier = Supplier.query.get(int(office.supplier_id))
                if supplier is not None:
                    supplier_bal = compute_live_supplier_balances([supplier]).get(int(supplier.id))
        except Exception:
            supplier_bal = None

        linked_account = None
        if office.account_category_id:
            linked_account = Account.query.get(office.account_category_id)

        # Canonical source of truth: supplier-ledger balance when the office is linked to a supplier.
        if isinstance(supplier_bal, dict):
            balance_cash = float(supplier_bal.get('cash') or 0.0)
            bal_18k = float(supplier_bal.get('18k') or 0.0)
            bal_21k = float(supplier_bal.get('21k') or 0.0)
            bal_22k = float(supplier_bal.get('22k') or 0.0)
            bal_24k = float(supplier_bal.get('24k') or 0.0)
            balance_source = 'supplier'
        # Fallback: journal-derived aggregation for linked accounts.
        elif linked_account is not None:
            live = live_balances_by_account_ids([linked_account.id]).get(int(linked_account.id))
            live = live if isinstance(live, dict) else {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
            balance_cash = float(live.get('cash') or 0.0)
            bal_18k = float(live.get('18k') or 0.0)
            bal_21k = float(live.get('21k') or 0.0)
            bal_22k = float(live.get('22k') or 0.0)
            bal_24k = float(live.get('24k') or 0.0)
            balance_source = 'account'
        else:
            balance_cash = float(office.balance_cash or 0.0)
            bal_18k = float(office.balance_gold_18k or 0.0)
            bal_21k = float(office.balance_gold_21k or 0.0)
            bal_22k = float(office.balance_gold_22k or 0.0)
            bal_24k = float(office.balance_gold_24k or 0.0)
            balance_source = 'office'

        # KPIs
        outstanding_weight = (
            db.session.query(db.func.sum(OfficeReservation.weight_remaining_main_karat))
            .filter(OfficeReservation.office_id == office.id)
            .filter(OfficeReservation.weight_remaining_main_karat > 0)
            .filter(OfficeReservation.status.notin_(['cancelled', 'rejected']))
            .scalar()
            or 0.0
        )

        avg_weight = (
            db.session.query(
                db.func.sum(OfficeReservation.weight_main_karat),
                db.func.sum(
                    OfficeReservation.weight_main_karat
                    * OfficeReservation.execution_price_per_gram
                ),
            )
            .filter(OfficeReservation.office_id == office.id)
            .filter(OfficeReservation.weight_main_karat > 0)
            .filter(OfficeReservation.execution_price_per_gram > 0)
            .filter(OfficeReservation.status.notin_(['cancelled', 'rejected']))
            .first()
        )
        total_w = float((avg_weight[0] or 0.0) if avg_weight else 0.0)
        total_w_cost = float((avg_weight[1] or 0.0) if avg_weight else 0.0)
        avg_closing_price = (total_w_cost / total_w) if total_w > 0 else 0.0
        
        balance_data = {
            'office_id': office.id,
            'office_code': office.office_code,
            'office_name': office.name,
            'balance_cash': round(float(balance_cash), 2),
            'balance_source': balance_source,
            'kpis': {
                'outstanding_weight_main_karat': round(float(outstanding_weight), 3),
                'avg_closing_price_per_gram': round(float(avg_closing_price), 2),
            },
            'balance_gold': {
                '18k': round(float(bal_18k), 3),
                '21k': round(float(bal_21k), 3),
                '22k': round(float(bal_22k), 3),
                '24k': round(float(bal_24k), 3),
                'total': round(
                    float(bal_18k) + float(bal_21k) + float(bal_22k) + float(bal_24k),
                    3,
                )
            },
            'statistics': {
                'total_reservations': office.total_reservations,
                'total_weight_purchased': round(office.total_weight_purchased, 3),
                'total_amount_paid': round(office.total_amount_paid, 2)
            }
        }
        
        return jsonify(balance_data), 200
    
    except Exception as e:
        print(f"❌ خطأ في جلب رصيد المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/statistics', methods=['GET'])
def get_offices_statistics():
    """إحصائيات عامة عن المكاتب"""
    try:
        total_offices = db.session.query(Office).count()
        active_offices = db.session.query(Office).filter_by(active=True).count()
        inactive_offices = total_offices - active_offices
        
        total_reservations = db.session.query(
            db.func.sum(Office.total_reservations)
        ).scalar() or 0
        
        total_weight = db.session.query(
            db.func.sum(Office.total_weight_purchased)
        ).scalar() or 0
        
        total_paid = db.session.query(
            db.func.sum(Office.total_amount_paid)
        ).scalar() or 0
        
        statistics = {
            'total_offices': total_offices,
            'active_offices': active_offices,
            'inactive_offices': inactive_offices,
            'total_reservations': int(total_reservations),
            'total_weight_purchased': round(float(total_weight), 3),
            'total_amount_paid': round(float(total_paid), 2)
        }
        
        return jsonify(statistics), 200
    
    except Exception as e:
        print(f"❌ خطأ في جلب إحصائيات المكاتب: {e}")
        return jsonify({'error': str(e)}), 500
