"""Employee domain routes — employees_bp registered under /api in app.py."""
from __future__ import annotations

import io
import os
from datetime import date, datetime, timedelta

from flask import Blueprint, g, jsonify, request
from services.record_ownership import refuse_unless_self
from sqlalchemy import and_, func, or_
from sqlalchemy.exc import IntegrityError

from models import (
    db,
    Account,
    Attendance,
    BonusRule,
    Employee,
    EmployeeBonus,
    GoalAchievement,
    JournalEntry,
    JournalEntryLine,
    Payroll,
    SafeBox,
    Voucher,
    VoucherAccountLine,
)

from core.dates import _parse_iso_date, _parse_iso_time
from auth_decorators import get_current_user, require_auth, require_permission

from core.settings import _get_settings_singleton
from accounting.voucher_engine import post_entry_of_approved_voucher, _append_safe_transactions_for_voucher
from dual_system_helpers import create_dual_journal_entry, verify_dual_balance
from routes import (
    _generate_employee_code,
)

employees_bp = Blueprint('employees', __name__)

# ============================================================================
# Employees API Routes (نظام الموظفين)
# ============================================================================

@employees_bp.route('/employees', methods=['GET'])
def list_employees():
    """إرجاع قائمة الموظفين مع دعم التصفية والبحث"""
    query = Employee.query

    is_active = request.args.get('is_active')
    if is_active is not None:
        if is_active.lower() in ['1', 'true', 'yes']:
            query = query.filter_by(is_active=True)
        elif is_active.lower() in ['0', 'false', 'no']:
            query = query.filter_by(is_active=False)
        # 'all' → no filter (for management screens)
    else:
        query = query.filter_by(is_active=True)

    department = request.args.get('department')
    if department:
        query = query.filter(Employee.department.ilike(f'%{department}%'))

    search = request.args.get('search')
    if search:
        search_term = f'%{search}%'
        query = query.filter(
            or_(
                Employee.name.ilike(search_term),
                Employee.employee_code.ilike(search_term),
                Employee.phone.ilike(search_term),
                Employee.email.ilike(search_term),
            )
        )

    page = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 20, type=int)

    pagination = query.order_by(Employee.name.asc()).paginate(page=page, per_page=per_page, error_out=False)

    # Without employees.view: names only -- the invoice list filters by seller (ADR-036 R3).
    from services.read_scope import holds
    full = holds('employees.view')
    return jsonify({
        'employees': [employee.to_dict(include_details=True) if full else {'id': employee.id, 'name': employee.name}
                      for employee in pagination.items],
        'total': pagination.total,
        'pages': pagination.pages,
        'current_page': pagination.page,
        'per_page': pagination.per_page,
    })

@employees_bp.route('/employees', methods=['POST'])
@require_permission('employees.create')
def create_employee():
    """إنشاء موظف جديد مع حساب تلقائي"""
    from employee_account_helpers import (
        create_employee_account,
        create_employee_payables_accounts,
        get_employee_department_from_code,
        ensure_employee_group_accounts,
        ensure_memo_for_account,
    )
    from employee_gold_safe_helpers import create_employee_gold_safe, ensure_employee_gold_group_account
    from employee_cash_safe_helpers import create_employee_cash_safe, ensure_employee_cash_group_account
    
    data = request.get_json() or {}

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

    name = data.get('name')
    if not name:
        return jsonify({'error': 'اسم الموظف مطلوب'}), 400

    employee_code = data.get('employee_code') or _generate_employee_code()

    if Employee.query.filter_by(employee_code=employee_code).first():
        return jsonify({'error': 'كود الموظف مستخدم بالفعل'}), 400

    # Ensure required employee/group accounts exist (defensive on fresh DBs).
    try:
        ensure_employee_group_accounts(created_by=data.get('created_by', 'system'))
        ensure_employee_cash_group_account(created_by=data.get('created_by', 'system'))
        ensure_employee_gold_group_account(created_by=data.get('created_by', 'system'))
    except Exception:
        # Non-fatal: some charts might not have the expected parents.
        pass

    # إنشاء حساب تلقائي للموظف إذا لم يُحدد account_id
    account_id = data.get('account_id')
    auto_created_account = None

    # Defensive: some clients may accidentally send the *group* account (e.g. 1700) or a
    # weight/memo account (7xxxx) as account_id. In those cases we still want a dedicated
    # personal account under 1700.
    try:
        if account_id not in (None, '', False):
            linked = Account.query.get(int(account_id))
            if linked:
                linked_num = str(getattr(linked, 'account_number', '') or '')
                linked_tt = (getattr(linked, 'transaction_type', '') or '').strip().lower()

                if linked_num in ('170', '1700', '7170', '71700') or linked_tt == 'gold' or bool(getattr(linked, 'tracks_weight', False)):
                    account_id = None
    except Exception:
        # If parsing fails, fall back to auto-creation path.
        account_id = None
    
    if not account_id:
        try:
            # Group accounts are already ensured above; proceed with creating the employee account.

            # تحديد القسم من البيانات المُدخلة أو استخدام الافتراضي
            department_input = data.get('department', '').lower()
            
            # تحويل اسم القسم العربي إلى الإنجليزي
            department_mapping = {
                'إدارة': 'administration',
                'مبيعات': 'sales',
                'صيانة': 'maintenance',
                'محاسبة': 'accounting',
                'مستودعات': 'warehouse',
                'administration': 'administration',
                'sales': 'sales',
                'maintenance': 'maintenance',
                'accounting': 'accounting',
                'warehouse': 'warehouse',
            }
            
            department = department_mapping.get(department_input, 'administration')
            
            # إنشاء الحساب
            auto_created_account = create_employee_account(
                employee_name=name,
                department=department,
                created_by=data.get('created_by', 'system')
            )
            account_id = auto_created_account.id
            
        except Exception as e:
            return jsonify({
                'error': f'فشل إنشاء الحساب التلقائي: {str(e)}',
                'hint': 'تأكد من تشغيل seed_employee_accounts.py لإنشاء الحسابات التجميعية'
            }), 500

    # Ensure the linked/selected personal account has a memo/weight parallel.
    try:
        if account_id:
            acc = Account.query.get(int(account_id))
            if acc:
                ensure_memo_for_account(acc)
    except Exception:
        pass

    employee = Employee(
        employee_code=employee_code,
        name=name,
        job_title=data.get('job_title'),
        department=data.get('department'),
        phone=data.get('phone'),
        email=data.get('email'),
        national_id=data.get('national_id'),
        salary=data.get('salary') or 0.0,
        hire_date=_parse_iso_date(data.get('hire_date'), 'hire_date'),
        termination_date=_parse_iso_date(data.get('termination_date'), 'termination_date'),
        account_id=account_id,
        is_active=data.get('is_active', True),
        notes=data.get('notes'),
        created_by=data.get('created_by'),
    )

    created_gold_safe = None
    created_gold_safe_account = None
    created_cash_safe = None
    created_cash_safe_account = None
    created_payables_accounts = []

    # Optional: assign employee gold safe box (NULL/0 => main gold safe)
    if 'gold_safe_box_id' in data:
        raw_gold_safe_id = data.get('gold_safe_box_id')
        gold_safe_id = None
        if raw_gold_safe_id not in (None, '', False):
            try:
                gold_safe_id = int(raw_gold_safe_id)
            except Exception:
                return jsonify({'error': 'gold_safe_box_id must be numeric'}), 400
            if gold_safe_id == 0:
                gold_safe_id = None

        if gold_safe_id is not None:
            sb = SafeBox.query.get(gold_safe_id)
            if not sb:
                return jsonify({'error': f'Gold safe box with ID {gold_safe_id} not found'}), 404
            if (sb.safe_type or '').lower() != 'gold':
                return jsonify({'error': 'Selected safe box is not a gold safe'}), 400
            if not bool(getattr(sb, 'is_active', True)):
                return jsonify({'error': 'Selected gold safe box is not active'}), 400

        employee.gold_safe_box_id = gold_safe_id

    # Optional: assign employee cash safe box (NULL/0 => main cash safe)
    if 'cash_safe_box_id' in data:
        raw_cash_safe_id = data.get('cash_safe_box_id')
        cash_safe_id = None
        if raw_cash_safe_id not in (None, '', False):
            try:
                cash_safe_id = int(raw_cash_safe_id)
            except Exception:
                return jsonify({'error': 'cash_safe_box_id must be numeric'}), 400
            if cash_safe_id == 0:
                cash_safe_id = None

        if cash_safe_id is not None:
            sb = SafeBox.query.get(cash_safe_id)
            if not sb:
                return jsonify({'error': f'Cash safe box with ID {cash_safe_id} not found'}), 404
            if (sb.safe_type or '').lower() != 'cash':
                return jsonify({'error': 'Selected safe box is not a cash safe'}), 400
            if not bool(getattr(sb, 'is_active', True)):
                return jsonify({'error': 'Selected cash safe box is not active'}), 400

        employee.cash_safe_box_id = cash_safe_id

    # Optional: auto-create a dedicated employee gold safe if not explicitly provided.
    # This creates: Account (tracks_weight=True) + SafeBox (gold, karat=None) and links it to employee.
    auto_create_gold_safe = bool(data.get('auto_create_gold_safe_box', False))
    if auto_create_gold_safe and (employee.gold_safe_box_id in (None, 0)):
        try:
            created_by = data.get('created_by', 'system')
            created_gold_safe_account, created_gold_safe = create_employee_gold_safe(
                employee_name=name,
                employee_code=employee_code,
                created_by=created_by,
            )
            employee.gold_safe_box_id = created_gold_safe.id
        except Exception as e:
            return jsonify({'error': f'فشل إنشاء خزينة ذهب للموظف: {str(e)}'}), 500

    # Optional: auto-create a dedicated employee cash safe if not explicitly provided.
    auto_create_cash_safe = bool(data.get('auto_create_cash_safe_box', False))
    if auto_create_cash_safe and (getattr(employee, 'cash_safe_box_id', None) in (None, 0)):
        try:
            created_by = data.get('created_by', 'system')
            created_cash_safe_account, created_cash_safe = create_employee_cash_safe(
                employee_name=name,
                employee_code=employee_code,
                created_by=created_by,
            )
            employee.cash_safe_box_id = created_cash_safe.id
        except Exception as e:
            return jsonify({'error': f'فشل إنشاء خزينة نقدية للموظف: {str(e)}'}), 500

    try:
        db.session.add(employee)
        db.session.flush()  # ensure employee.id is available

        # Auto-create employee-specific payables accounts under 230/240/250 (detail 2300/2400/2500).
        # Default: enabled (can be disabled by sending auto_create_payables_accounts=false)
        if _boolish(data.get('auto_create_payables_accounts'), default=True):
            try:
                created_by = data.get('created_by', 'system')
                created_payables_accounts = create_employee_payables_accounts(name, created_by=created_by)
            except Exception as exc:
                return jsonify({'error': f'فشل إنشاء حسابات مستحقات الموظف: {str(exc)}'}), 500

        # Employee advance accounts were removed by request (legacy 1400 and related logic).
        created_advance_account = None
        db.session.commit()
        
        result = employee.to_dict(include_details=True)
        if auto_created_account:
            result['auto_created_account'] = {
                'account_number': auto_created_account.account_number,
                'account_name': auto_created_account.name
            }

        if created_gold_safe and created_gold_safe_account:
            result['auto_created_gold_safe_box'] = {
                'safe_box_id': int(created_gold_safe.id),
                'safe_box_name': created_gold_safe.name,
                'account_id': int(created_gold_safe_account.id),
                'account_number': created_gold_safe_account.account_number,
                'account_name': created_gold_safe_account.name,
            }

        if created_cash_safe:
            result['auto_created_cash_safe_box'] = {
                'safe_box_id': int(created_cash_safe.id),
                'safe_box_name': created_cash_safe.name,
                'account_id': int(created_cash_safe.account_id),
                'account_number': created_cash_safe_account.account_number if created_cash_safe_account else None,
                'account_name': created_cash_safe_account.name if created_cash_safe_account else None,
            }

        # (advance accounts removed)

        if created_payables_accounts:
            result['auto_created_payables_accounts'] = [
                {
                    'account_id': int(acc.id),
                    'account_number': acc.account_number,
                    'account_name': acc.name,
                }
                for acc in created_payables_accounts
            ]
        
        return jsonify(result), 201
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to create employee: {str(e)}'}), 500

@employees_bp.route('/employees/<int:employee_id>', methods=['GET'])
@require_permission('employees.view')
def get_employee(employee_id):
    employee = Employee.query.get_or_404(employee_id)
    return jsonify(employee.to_dict(include_details=True))

@employees_bp.route('/employees/<int:employee_id>', methods=['PUT'])
@require_permission('employees.edit')
def update_employee(employee_id):
    employee = Employee.query.get_or_404(employee_id)
    data = request.get_json() or {}

    for field in ['name', 'job_title', 'department', 'phone', 'email', 'national_id', 'notes', 'created_by']:
        if field in data:
            setattr(employee, field, data[field])

    if 'salary' in data and data['salary'] is not None:
        employee.salary = float(data['salary'])

    if 'hire_date' in data:
        employee.hire_date = _parse_iso_date(data['hire_date'], 'hire_date')
    if 'termination_date' in data:
        employee.termination_date = _parse_iso_date(data['termination_date'], 'termination_date')

    if 'account_id' in data:
        employee.account_id = data['account_id']

    if 'gold_safe_box_id' in data:
        raw_gold_safe_id = data.get('gold_safe_box_id')
        gold_safe_id = None
        if raw_gold_safe_id not in (None, '', False):
            try:
                gold_safe_id = int(raw_gold_safe_id)
            except Exception:
                return jsonify({'error': 'gold_safe_box_id must be numeric'}), 400
            if gold_safe_id == 0:
                gold_safe_id = None

        if gold_safe_id is not None:
            sb = SafeBox.query.get(gold_safe_id)
            if not sb:
                return jsonify({'error': f'Gold safe box with ID {gold_safe_id} not found'}), 404
            if (sb.safe_type or '').lower() != 'gold':
                return jsonify({'error': 'Selected safe box is not a gold safe'}), 400
            if not bool(getattr(sb, 'is_active', True)):
                return jsonify({'error': 'Selected gold safe box is not active'}), 400

        employee.gold_safe_box_id = gold_safe_id

    if 'cash_safe_box_id' in data:
        raw_cash_safe_id = data.get('cash_safe_box_id')
        cash_safe_id = None
        if raw_cash_safe_id not in (None, '', False):
            try:
                cash_safe_id = int(raw_cash_safe_id)
            except Exception:
                return jsonify({'error': 'cash_safe_box_id must be numeric'}), 400
            if cash_safe_id == 0:
                cash_safe_id = None

        if cash_safe_id is not None:
            sb = SafeBox.query.get(cash_safe_id)
            if not sb:
                return jsonify({'error': f'Cash safe box with ID {cash_safe_id} not found'}), 404
            if (sb.safe_type or '').lower() != 'cash':
                return jsonify({'error': 'Selected safe box is not a cash safe'}), 400
            if not bool(getattr(sb, 'is_active', True)):
                return jsonify({'error': 'Selected cash safe box is not active'}), 400

        employee.cash_safe_box_id = cash_safe_id

    if 'is_active' in data:
        employee.is_active = bool(data['is_active'])

    try:
        db.session.commit()
        return jsonify(employee.to_dict(include_details=True))
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update employee: {str(e)}'}), 500

@employees_bp.route('/employees/<int:employee_id>', methods=['DELETE'])
@require_permission('employees.delete')
def delete_employee(employee_id):
    employee = Employee.query.get_or_404(employee_id)

    try:
        # Policy: لا نحذف موظفاً لديه عمليات/سجلات مرتبطة؛ نقوم بإلغاء تفعيله بدلاً من الحذف.
        has_attendance = Attendance.query.filter_by(employee_id=employee.id).first() is not None
        has_payroll = Payroll.query.filter_by(employee_id=employee.id).first() is not None
        has_invoices = Invoice.query.filter_by(employee_id=employee.id).first() is not None
        has_bonuses = EmployeeBonus.query.filter_by(employee_id=employee.id).first() is not None

        # Also treat linked user-account as operational linkage (avoid breaking logins).
        has_linked_user = getattr(employee, 'user_account', None) is not None

        if has_attendance or has_payroll or has_invoices or has_bonuses or has_linked_user:
            employee.is_active = False
            db.session.commit()
            return jsonify({
                'success': True,
                'deleted': False,
                'deactivated': True,
                'is_active': False,
                'message': 'لا يمكن حذف الموظف لوجود عمليات/سجلات مرتبطة. تم إلغاء تفعيله بدلاً من الحذف',
            }), 200

        db.session.delete(employee)
        db.session.commit()

        return jsonify({
            'success': True,
            'deleted': True,
            'deactivated': False,
            'message': 'تم حذف الموظف بنجاح',
        }), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to delete employee: {str(e)}'}), 500

@employees_bp.route('/employees/<int:employee_id>/photo', methods=['PATCH'])
@require_permission('employees.edit')
def update_employee_photo(employee_id):
    """رفع أو حذف صورة الموظف. الجسم: {'photo': '<base64 data URI>'} أو {'photo': null}."""
    employee = Employee.query.get_or_404(employee_id)
    data = request.get_json(silent=True) or {}
    photo = data.get('photo')  # None = حذف الصورة
    if photo is not None and not isinstance(photo, str):
        return jsonify({'error': 'invalid_photo_format'}), 400
    employee.photo = photo or None
    employee.updated_at = datetime.utcnow()
    db.session.commit()
    return jsonify({'success': True, 'photo': employee.photo})

@employees_bp.route('/employees/<int:employee_id>/toggle-active', methods=['POST'])
@require_permission('employees.edit')
def toggle_employee_active(employee_id):
    employee = Employee.query.get_or_404(employee_id)
    employee.is_active = not employee.is_active

    try:
        db.session.commit()
        return jsonify({'id': employee.id, 'is_active': employee.is_active})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update employee status: {str(e)}'}), 500

@employees_bp.route('/employees/<int:employee_id>/payroll', methods=['GET'])
@require_permission('employees.payroll')
def list_employee_payroll(employee_id):
    employee = Employee.query.get_or_404(employee_id)
    payroll_entries = (
        Payroll.query.filter_by(employee_id=employee.id)
        .order_by(Payroll.year.desc(), Payroll.month.desc())
        .all()
    )
    return jsonify([entry.to_dict(include_voucher=True) for entry in payroll_entries])

@employees_bp.route('/employees/<int:employee_id>/attendance', methods=['GET'])
@require_permission('employees.view')
def list_employee_attendance(employee_id):
    employee = Employee.query.get_or_404(employee_id)

    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')

    query = Attendance.query.filter_by(employee_id=employee.id)

    if start_date:
        query = query.filter(Attendance.attendance_date >= _parse_iso_date(start_date, 'start_date'))
    if end_date:
        query = query.filter(Attendance.attendance_date <= _parse_iso_date(end_date, 'end_date'))

    attendance_records = query.order_by(Attendance.attendance_date.desc()).all()
    return jsonify([record.to_dict() for record in attendance_records])

@employees_bp.route('/employees/departments/summary', methods=['GET'])
@require_permission('employees.view')
def get_employee_departments_summary():
    """الحصول على ملخص أقسام الموظفين وعدد الموظفين في كل قسم"""
    from employee_account_helpers import get_department_summary
    
    try:
        summary = get_department_summary()
        return jsonify(summary)
    except Exception as e:
        return jsonify({'error': f'Failed to get departments summary: {str(e)}'}), 500

@employees_bp.route('/employees/<int:employee_id>/advance-account', methods=['GET'])
@require_permission('employees.payroll')
def get_employee_advance_account(employee_id):
    """حسابات السلف تم إلغاؤها نهائياً."""
    return jsonify({'error': 'Advance accounts feature has been removed'}), 410

@employees_bp.route('/employees/<int:employee_id>/advance-account', methods=['POST'])
@require_permission('employees.payroll')
def create_employee_advance_account(employee_id):
    """حسابات السلف تم إلغاؤها نهائياً."""
    return jsonify({'error': 'Advance accounts feature has been removed'}), 410

@employees_bp.route('/employees/<int:employee_id>/ensure-setup', methods=['POST'])
@require_permission('employees.edit')
def ensure_employee_setup(employee_id):
    """Ensure missing employee artifacts exist (accounts + optional safes).

    Useful for employees created before auto-linking/auto-safe options existed.
    Idempotent: does not duplicate payables accounts or safes if already linked.

    Payload (all optional):
      - ensure_personal_account: bool (default true)
      - ensure_payables_accounts: bool (default true)
      - ensure_cash_safe: bool (default true)
      - ensure_gold_safe: bool (default true)
      - created_by: str
    """

    from employee_account_helpers import (
        create_employee_account,
        ensure_employee_group_accounts,
        get_or_create_employee_payables_accounts,
        EMPLOYEE_PERSONAL_PARENT_NUMBER,
        ensure_memo_for_account,
    )
    from employee_account_naming import employee_personal_account_name
    from employee_gold_safe_helpers import create_employee_gold_safe, ensure_employee_gold_group_account
    from employee_cash_safe_helpers import create_employee_cash_safe, ensure_employee_cash_group_account

    data = request.get_json() or {}

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

    created_by = data.get('created_by', 'system')
    ensure_personal = _boolish(data.get('ensure_personal_account'), default=True)
    ensure_payables = _boolish(data.get('ensure_payables_accounts'), default=True)
    ensure_cash_safe = _boolish(data.get('ensure_cash_safe'), default=True)
    ensure_gold_safe = _boolish(data.get('ensure_gold_safe'), default=True)

    employee = Employee.query.get_or_404(employee_id)

    created = {
        'linked_personal_account': None,
        'created_personal_account': None,
        'created_cash_safe_box': None,
        'created_gold_safe_box': None,
        'ensured_payables_accounts': [],
    }

    try:
        # Ensure group structure exists when possible.
        try:
            ensure_employee_group_accounts(created_by=created_by)
            ensure_employee_cash_group_account(created_by=created_by)
            ensure_employee_gold_group_account(created_by=created_by)
        except Exception:
            pass

        # 1) Ensure personal account is linked.
        if ensure_personal and not getattr(employee, 'account_id', None):
            parent_acc = Account.query.filter_by(account_number=str(EMPLOYEE_PERSONAL_PARENT_NUMBER)).first()
            expected_name = employee_personal_account_name(employee.name)
            existing = None
            if parent_acc:
                existing = Account.query.filter_by(parent_id=parent_acc.id, name=expected_name).first()
            if not existing:
                # Fallback lookup by name only (in case parent linkage differs in older DBs)
                existing = Account.query.filter_by(name=expected_name).order_by(Account.id.desc()).first()

            if existing:
                try:
                    ensure_memo_for_account(existing)
                except Exception:
                    pass
                employee.account_id = existing.id
                created['linked_personal_account'] = {
                    'account_id': int(existing.id),
                    'account_number': existing.account_number,
                    'account_name': existing.name,
                }
            else:
                acc = create_employee_account(employee_name=employee.name, created_by=created_by)
                employee.account_id = acc.id
                created['created_personal_account'] = {
                    'account_id': int(acc.id),
                    'account_number': acc.account_number,
                    'account_name': acc.name,
                }

        # 2) Ensure payables accounts exist (idempotent).
        if ensure_payables:
            payables = get_or_create_employee_payables_accounts(employee.name, created_by=created_by)
            created['ensured_payables_accounts'] = [
                {
                    'account_id': int(a.id),
                    'account_number': a.account_number,
                    'account_name': a.name,
                }
                for a in payables
            ]

        # 3) Ensure gold/cash safes (create + link if missing).
        if ensure_gold_safe and (getattr(employee, 'gold_safe_box_id', None) in (None, 0)):
            acc, sb = create_employee_gold_safe(
                employee_name=employee.name,
                employee_code=getattr(employee, 'employee_code', None),
                created_by=created_by,
            )
            employee.gold_safe_box_id = sb.id
            created['created_gold_safe_box'] = {
                'safe_box_id': int(sb.id),
                'safe_box_name': sb.name,
                'account_id': int(acc.id),
                'account_number': acc.account_number,
                'account_name': acc.name,
            }

        if ensure_cash_safe and (getattr(employee, 'cash_safe_box_id', None) in (None, 0)):
            acc, sb = create_employee_cash_safe(
                employee_name=employee.name,
                employee_code=getattr(employee, 'employee_code', None),
                created_by=created_by,
            )
            employee.cash_safe_box_id = sb.id
            created['created_cash_safe_box'] = {
                'safe_box_id': int(sb.id),
                'safe_box_name': sb.name,
                'account_id': int(acc.id),
                'account_number': acc.account_number,
                'account_name': acc.name,
            }

        db.session.commit()

        result = employee.to_dict(include_details=True)
        result['ensure_setup'] = created
        return jsonify(result), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to ensure employee setup: {str(e)}'}), 500

@employees_bp.route('/employees/bulk-ensure-setup', methods=['POST'])
@require_permission('employees.edit')
def bulk_ensure_employees_setup():
    """Run ensure-setup (accounts + safes) for every active employee at once.

    Safe creation is gated by the global Settings flags:
      - employee_cash_safes_enabled → create cash safe only if True
      - employee_gold_safes_enabled → create gold safe only if True
    Payables accounts (2400/2410/2420/2310) are always ensured.
    """
    from employee_account_helpers import (
        get_or_create_employee_payables_accounts,
        ensure_employee_group_accounts,
        create_employee_account,
        EMPLOYEE_PERSONAL_PARENT_NUMBER,
        ensure_memo_for_account,
    )
    from employee_account_naming import employee_personal_account_name
    from employee_gold_safe_helpers import create_employee_gold_safe, ensure_employee_gold_group_account
    from employee_cash_safe_helpers import create_employee_cash_safe, ensure_employee_cash_group_account

    # Read global safe-feature flags from Settings
    settings_row = Settings.query.first()
    cash_safes_enabled = bool(getattr(settings_row, 'employee_cash_safes_enabled', False))
    gold_safes_enabled = bool(getattr(settings_row, 'employee_gold_safes_enabled', False))

    employees = Employee.query.filter_by(is_active=True).all()
    summary = {
        'total': len(employees),
        'cash_safes_enabled': cash_safes_enabled,
        'gold_safes_enabled': gold_safes_enabled,
        'updated': [],
        'errors': [],
    }

    # Ensure group structure once before the loop
    try:
        ensure_employee_group_accounts(created_by='bulk-ensure')
        if cash_safes_enabled:
            ensure_employee_cash_group_account(created_by='bulk-ensure')
        if gold_safes_enabled:
            ensure_employee_gold_group_account(created_by='bulk-ensure')
    except Exception:
        pass

    for emp in employees:
        try:
            created: dict = {}

            # personal account
            if not getattr(emp, 'account_id', None):
                acct = create_employee_account(emp.name, created_by='bulk-ensure')
                emp.account_id = acct.id
                created['personal_account'] = acct.account_number

            # payables accounts (2400/2410/2420/2310) — always
            payables = get_or_create_employee_payables_accounts(emp.name, created_by='bulk-ensure')
            if payables:
                created['payables'] = [a.account_number for a in payables]

            # gold safe — only when globally enabled
            if gold_safes_enabled and (getattr(emp, 'gold_safe_box_id', None) in (None, 0)):
                try:
                    acc, sb = create_employee_gold_safe(
                        employee_name=emp.name,
                        employee_code=getattr(emp, 'employee_code', None),
                        created_by='bulk-ensure',
                    )
                    emp.gold_safe_box_id = sb.id
                    created['gold_safe'] = sb.name
                except Exception:
                    pass

            # cash safe — only when globally enabled
            if cash_safes_enabled and (getattr(emp, 'cash_safe_box_id', None) in (None, 0)):
                try:
                    acc, sb = create_employee_cash_safe(
                        employee_name=emp.name,
                        employee_code=getattr(emp, 'employee_code', None),
                        created_by='bulk-ensure',
                    )
                    emp.cash_safe_box_id = sb.id
                    created['cash_safe'] = sb.name
                except Exception:
                    pass

            db.session.flush()
            summary['updated'].append({'id': emp.id, 'name': emp.name, 'created': created})

        except Exception as e:
            summary['errors'].append({'id': emp.id, 'name': emp.name, 'error': str(e)})

    try:
        db.session.commit()
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

    return jsonify(summary), 200

@employees_bp.route('/advances/summary', methods=['GET'])
@require_permission('employees.payroll')
def get_all_advances_summary():
    """حسابات السلف تم إلغاؤها نهائياً."""
    return jsonify({'error': 'Advance accounts feature has been removed'}), 410

# ============================================================================
# Payroll Routes (إدارة الرواتب)
# ============================================================================

@employees_bp.route('/payroll', methods=['GET'])
@require_permission('employees.payroll')
def list_payroll():
    query = Payroll.query

    employee_id = request.args.get('employee_id', type=int)
    if employee_id:
        query = query.filter_by(employee_id=employee_id)

    year = request.args.get('year', type=int)
    if year:
        query = query.filter_by(year=year)

    month = request.args.get('month', type=int)
    if month:
        query = query.filter_by(month=month)

    status = request.args.get('status')
    if status:
        query = query.filter_by(status=status)

    payroll_entries = query.order_by(Payroll.year.desc(), Payroll.month.desc()).all()
    return jsonify([entry.to_dict(include_employee=True, include_voucher=True) for entry in payroll_entries])

@employees_bp.route('/payroll', methods=['POST'])
@require_permission('employees.payroll')
def create_payroll():
    data = request.get_json() or {}

    employee_id = data.get('employee_id')
    if not employee_id:
        return jsonify({'error': 'رمز الموظف مطلوب'}), 400

    employee = Employee.query.get(employee_id)
    if not employee:
        return jsonify({'error': 'الموظف غير موجود'}), 400

    try:
        paid_date = _parse_iso_date(data.get('paid_date'), 'paid_date')
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    basic_salary = float(data.get('basic_salary', employee.salary or 0.0))
    allowances = float(data.get('allowances', 0.0))
    deductions = float(data.get('deductions', 0.0))
    net_salary = float(data.get('net_salary', basic_salary + allowances - deductions))

    payroll_entry = Payroll(
        employee_id=employee.id,
        month=int(data.get('month', datetime.now().month)),
        year=int(data.get('year', datetime.now().year)),
        basic_salary=basic_salary,
        allowances=allowances,
        deductions=deductions,
        net_salary=net_salary,
        voucher_id=data.get('voucher_id'),
        paid_date=paid_date,
        status=data.get('status', 'pending'),
        notes=data.get('notes'),
        created_by=data.get('created_by'),
    )

    try:
        db.session.add(payroll_entry)
        db.session.commit()
        return jsonify(payroll_entry.to_dict(include_employee=True, include_voucher=True)), 201
    except IntegrityError as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء سجل الراتب: {str(exc)}'}), 400
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء سجل الراتب: {str(exc)}'}), 500

@employees_bp.route('/payroll/<int:payroll_id>', methods=['GET'])
@require_permission('employees.payroll')
def get_payroll(payroll_id):
    payroll_entry = Payroll.query.get_or_404(payroll_id)
    return jsonify(payroll_entry.to_dict(include_employee=True, include_voucher=True))

@employees_bp.route('/payroll/<int:payroll_id>', methods=['PUT'])
@require_permission('employees.payroll')
def update_payroll(payroll_id):
    payroll_entry = Payroll.query.get_or_404(payroll_id)
    data = request.get_json() or {}

    old_status = (payroll_entry.status or '').strip().lower()

    if 'employee_id' in data:
        employee_id = data['employee_id']
        if employee_id:
            employee = Employee.query.get(employee_id)
            if not employee:
                return jsonify({'error': 'الموظف غير موجود'}), 400
            payroll_entry.employee_id = employee.id

    if 'month' in data and data['month'] is not None:
        payroll_entry.month = int(data['month'])
    if 'year' in data and data['year'] is not None:
        payroll_entry.year = int(data['year'])

    if 'basic_salary' in data and data['basic_salary'] is not None:
        payroll_entry.basic_salary = float(data['basic_salary'])
    if 'allowances' in data and data['allowances'] is not None:
        payroll_entry.allowances = float(data['allowances'])
    if 'deductions' in data and data['deductions'] is not None:
        payroll_entry.deductions = float(data['deductions'])
    if 'net_salary' in data and data['net_salary'] is not None:
        payroll_entry.net_salary = float(data['net_salary'])

    if 'status' in data and data['status']:
        payroll_entry.status = data['status']

    if 'voucher_id' in data:
        payroll_entry.voucher_id = data['voucher_id']

    if 'notes' in data:
        payroll_entry.notes = data['notes']

    if 'paid_date' in data:
        try:
            payroll_entry.paid_date = _parse_iso_date(data['paid_date'], 'paid_date')
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    # ── قيد الاستحقاق التلقائي ────────────────────────────────────────
    # عند التغيير إلى approved أو paid ينشأ القيد تلقائياً داخل نفس
    # الـ transaction — إذا فشل الحفظ يُرجع خطأ واضح للمستخدم.
    new_status = (payroll_entry.status or '').strip().lower()
    accrual_result = None
    if new_status in ('approved', 'paid') and old_status not in ('approved', 'paid'):
        try:
            ok, err, je = _post_payroll_accrual_internal(
                payroll_entry,
                created_by=data.get('created_by', 'system'),
            )
            if ok:
                accrual_result = {'accrual_posted': True, 'accrual_already_existed': je is not None and not hasattr(je, '_sa_instance_state')}
            else:
                accrual_result = {'accrual_posted': False, 'accrual_warning': err}
        except Exception as exc:
            accrual_result = {'accrual_posted': False, 'accrual_warning': str(exc)}

    try:
        db.session.commit()
        result = payroll_entry.to_dict(include_employee=True, include_voucher=True)
        if accrual_result:
            result.update(accrual_result)
        return jsonify(result)
    except IntegrityError as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث سجل الراتب: {str(exc)}'}), 400
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث سجل الراتب: {str(exc)}'}), 500

@employees_bp.route('/payroll/<int:payroll_id>', methods=['DELETE'])
@require_permission('employees.payroll')
def delete_payroll(payroll_id):
    payroll_entry = Payroll.query.get_or_404(payroll_id)

    if payroll_entry.voucher_id:
        return jsonify({'error': 'لا يمكن حذف سجل الراتب المرتبط بسند'}), 400

    try:
        db.session.delete(payroll_entry)
        db.session.commit()
        return jsonify({'message': 'تم حذف سجل الراتب بنجاح'})
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل حذف سجل الراتب: {str(exc)}'}), 500

@employees_bp.route('/payroll/<int:payroll_id>/clone', methods=['POST'])
@require_permission('employees.payroll')
def clone_payroll(payroll_id):
    """
    استنساخ سجل راتب إلى شهر/سنة جديدة.
    يُنشئ سجلاً جديداً بنفس بيانات الراتب (أساسي، بدلات، خصومات) بحالة pending.
    """
    source = Payroll.query.get_or_404(payroll_id)
    data = request.get_json() or {}

    target_month = int(data.get('month', source.month))
    target_year  = int(data.get('year',  source.year))

    # التحقق من أن السجل غير موجود مسبقاً لنفس الموظف/الشهر/السنة
    existing = Payroll.query.filter_by(
        employee_id=source.employee_id,
        month=target_month,
        year=target_year,
    ).first()
    if existing:
        return jsonify({
            'error': 'payroll_already_exists',
            'message': f'يوجد سجل راتب بالفعل للموظف في {target_month}/{target_year}.',
        }), 409

    new_entry = Payroll(
        employee_id  = source.employee_id,
        month        = target_month,
        year         = target_year,
        basic_salary = source.basic_salary,
        allowances   = source.allowances,
        deductions   = source.deductions,
        net_salary   = source.net_salary,
        status       = 'pending',
        notes        = source.notes,
        created_by   = data.get('created_by'),
    )

    try:
        db.session.add(new_entry)
        db.session.commit()
        return jsonify(new_entry.to_dict(include_employee=True)), 201
    except IntegrityError:
        db.session.rollback()
        return jsonify({
            'error': 'payroll_already_exists',
            'message': f'يوجد سجل راتب بالفعل للموظف في {target_month}/{target_year}.',
        }), 409
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل استنساخ سجل الراتب: {str(exc)}'}), 500

@employees_bp.route('/payroll/bulk-approve', methods=['POST'])
@require_permission('employees.payroll')
def bulk_approve_payroll():
    """اعتماد مجموعة سجلات رواتب (pending → approved) مع إنشاء قيود الاستحقاق."""
    data = request.get_json() or {}
    ids = data.get('ids')  # قائمة بـ IDs أو None لاعتماد كل الـ pending للشهر/السنة
    year  = data.get('year',  type(0) and None) or data.get('year')
    month = data.get('month', type(0) and None) or data.get('month')
    created_by = data.get('created_by', 'system')

    query = Payroll.query.filter(Payroll.status == 'pending')
    if ids:
        query = query.filter(Payroll.id.in_(ids))
    else:
        if year:
            query = query.filter_by(year=int(year))
        if month:
            query = query.filter_by(month=int(month))

    entries = query.all()
    if not entries:
        return jsonify({'approved': 0, 'skipped': 0, 'message': 'لا توجد سجلات معلقة'}), 200

    approved_count = 0
    skipped = []
    for entry in entries:
        entry.status = 'approved'
        ok, err, _ = _post_payroll_accrual_internal(entry, created_by=created_by)
        if ok:
            approved_count += 1
        else:
            skipped.append({'id': entry.id, 'reason': err})

    try:
        db.session.commit()
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل الاعتماد الجماعي: {str(exc)}'}), 500

    return jsonify({
        'approved': approved_count,
        'skipped': len(skipped),
        'skipped_details': skipped,
    }), 200

@employees_bp.route('/payroll/bulk-cancel', methods=['POST'])
@require_permission('employees.payroll')
def bulk_cancel_payroll():
    """إلغاء مجموعة سجلات رواتب (لا يُلغي السندات المدفوعة)."""
    data = request.get_json() or {}
    ids   = data.get('ids')
    year  = data.get('year')
    month = data.get('month')

    query = Payroll.query.filter(Payroll.status.in_(['pending', 'approved']))
    if ids:
        query = query.filter(Payroll.id.in_(ids))
    else:
        if year:
            query = query.filter_by(year=int(year))
        if month:
            query = query.filter_by(month=int(month))

    entries = query.all()
    if not entries:
        return jsonify({'cancelled': 0, 'message': 'لا توجد سجلات قابلة للإلغاء'}), 200

    cancelled_count = 0
    skipped = []
    for entry in entries:
        if entry.voucher_id:
            skipped.append({'id': entry.id, 'reason': 'مرتبط بسند دفع'})
            continue
        entry.status = 'cancelled'
        cancelled_count += 1

    try:
        db.session.commit()
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل الإلغاء الجماعي: {str(exc)}'}), 500

    return jsonify({
        'cancelled': cancelled_count,
        'skipped': len(skipped),
        'skipped_details': skipped,
    }), 200

@employees_bp.route('/payroll/payment-accounts', methods=['GET'])
@require_permission('employees.payroll')
def get_payment_accounts():
    """
    الحصول على حسابات الدفع المتاحة (نقدية، بنوك، شيكات)
    ✨ محدّث: يستخدم نظام الخزائن الجديد
    """
    # الحصول على جميع الخزائن النقدية والبنكية النشطة
    safe_boxes = SafeBox.query.filter(
        SafeBox.safe_type.in_(['cash', 'bank', 'check']),
        SafeBox.is_active == True
    ).order_by(SafeBox.is_default.desc(), SafeBox.safe_type, SafeBox.name).all()
    
    return jsonify([{
        'id': sb.account_id,  # نرسل account_id لأن الكود الحالي يتوقعه
        'safe_box_id': sb.id,  # معرف الخزينة للمرجع
        'account_number': sb.account.account_number if sb.account else None,
        'name': sb.name,  # اسم الخزينة (أفضل من اسم الحساب)
        'type': sb.safe_type,  # cash, bank, check
        'bank_name': sb.bank_name,
        'is_default': sb.is_default
    } for sb in safe_boxes])

def _post_payroll_accrual_internal(payroll_entry, created_by='system'):
    """Core accrual logic — works within the current db.session (no commit).

    Returns a tuple: (ok: bool, error: str | None, journal_entry | None)
    The caller is responsible for committing or rolling back.

    Debit:  5410 — مصروف الرواتب
    Credit: 2400xxxx — ذمم رواتب الموظف
    """
    # ── idempotency ──────────────────────────────────────────────────
    existing = (
        JournalEntry.query
        .filter_by(reference_type='payroll_accrual', reference_id=int(payroll_entry.id), is_deleted=False)
        .order_by(JournalEntry.id.desc())
        .first()
    )
    if existing:
        return True, None, existing  # already posted — nothing to do

    # ── validations ───────────────────────────────────────────────────
    status = (payroll_entry.status or '').strip().lower()
    if status == 'cancelled':
        return False, 'لا يمكن ترحيل استحقاق سجل راتب ملغي', None
    if status not in ('approved', 'paid'):
        return False, 'يجب اعتماد سجل الراتب قبل ترحيل الاستحقاق', None

    try:
        net_salary = float(payroll_entry.net_salary or 0.0)
    except Exception:
        net_salary = 0.0
    if net_salary <= 0:
        return False, 'صافي الراتب غير صالح للترحيل', None

    employee = Employee.query.get(payroll_entry.employee_id)
    if not employee:
        return False, 'الموظف غير موجود', None

    # ── حساب مصروف الرواتب (5410) ────────────────────────────────────
    salary_expense_account = Account.query.filter_by(account_number='5410').first()
    if not salary_expense_account:
        return False, 'حساب مصروف الرواتب (5410) غير موجود في شجرة الحسابات', None

    # ── حساب ذمم رواتب الموظف (2400xxxx) ──────────────────────────────
    salary_payable_account_id = None
    try:
        from employee_account_helpers import get_or_create_employee_payables_accounts
        from employee_account_naming import employee_payable_account_name
        expected_name = employee_payable_account_name(employee.name, category_ar='رواتب')
        payables = get_or_create_employee_payables_accounts(
            employee.name,
            created_by=created_by,
        )
        salary_acc = next((a for a in payables if (a.name or '').strip() == expected_name), None)
        salary_payable_account_id = int(salary_acc.id) if salary_acc else None
    except Exception:
        salary_payable_account_id = None

    if not salary_payable_account_id:
        return False, 'لا يوجد حساب ذمم رواتب (2400xxxx) لهذا الموظف. يرجى تشغيل Ensure setup للموظف.', None

    # ── إنشاء القيد ───────────────────────────────────────────────────
    now = datetime.now()
    description = f"إثبات استحقاق راتب {employee.name} - {payroll_entry.month}/{payroll_entry.year}"

    journal_entry = JournalEntry(
        date=now,
        description=description,
        entry_type='استحقاق رواتب',
        reference_type='payroll_accrual',
        reference_id=int(payroll_entry.id),
        reference_number=f"{payroll_entry.year}-{int(payroll_entry.month):02d}",
        created_by=created_by,
        is_posted=True,
        posted_at=now,
        posted_by=created_by,
    )
    db.session.add(journal_entry)
    db.session.flush()

    create_dual_journal_entry(
        journal_entry_id=journal_entry.id,
        account_id=salary_expense_account.id,
        cash_debit=net_salary,
        description=description,
    )
    create_dual_journal_entry(
        journal_entry_id=journal_entry.id,
        account_id=salary_payable_account_id,
        cash_credit=net_salary,
        description=description,
    )

    balance_state = verify_dual_balance(journal_entry.id)
    if not balance_state.get('balanced', True):
        return False, 'فشل ترحيل قيد الاستحقاق بسبب عدم توازن القيد', None

    # Recompute stored Account.balance_* — the payroll JE is created with
    # is_posted=True directly so the normal approve flow never fires.
    try:
        from accounting.balances import _recalculate_account_balances_for_accounts
        _payroll_affected = {
            l.account_id
            for l in JournalEntryLine.query.filter_by(journal_entry_id=journal_entry.id).all()
            if l.account_id
        }
        if _payroll_affected:
            _recalculate_account_balances_for_accounts(_payroll_affected)
    except Exception as _rc_exc:
        print(f"⚠️ recalculate balances after payroll accrual skipped: {_rc_exc}")

    return True, None, journal_entry

@employees_bp.route('/payroll/<int:payroll_id>/post-accrual', methods=['POST'])
@require_permission('employees.payroll')
def post_payroll_accrual(payroll_id):
    """Post payroll accrual journal entry (manual trigger — kept for backward compatibility).

    Debit: Salary expense (5410)
    Credit: Employee salary payable (2400xxxx)

    Idempotent: returns existing entry if already posted.
    """
    payroll_entry = Payroll.query.get_or_404(payroll_id)
    data = request.get_json() or {}
    created_by = data.get('created_by', 'system')

    try:
        ok, err, je = _post_payroll_accrual_internal(payroll_entry, created_by=created_by)
    except Exception as exc:
        db.session.rollback()
        expose = (os.getenv('EXPOSE_API_ERRORS') or '').strip() == '1'
        payload = {'error': 'فشل ترحيل استحقاق الرواتب'}
        if expose:
            payload['details'] = str(exc)
        return jsonify(payload), 500

    if not ok:
        db.session.rollback()
        return jsonify({'error': err}), 400

    already = je and (
        JournalEntry.query
        .filter_by(reference_type='payroll_accrual', reference_id=int(payroll_entry.id), is_deleted=False)
        .count()
    ) > 1  # existing was returned without adding a new one
    # Simpler: check if je was already in session before flush
    # Just commit and return
    try:
        db.session.commit()
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل الحفظ: {str(exc)}'}), 500

    return jsonify({
        'message': 'تم ترحيل استحقاق الرواتب بنجاح',
        'journal_entry': je.to_dict(),
    }), 200

@employees_bp.route('/payroll/<int:payroll_id>/mark-paid', methods=['POST'])
@require_permission('employees.payroll')
def mark_payroll_paid(payroll_id):
    """
    تعيين راتب كمدفوع مع إنشاء سند صرف تلقائي
    
    Body Parameters:
        - paid_date: تاريخ الدفع (اختياري)
        - payment_account_id: معرف حساب الدفع (نقدية/بنك/شيك) (اختياري - افتراضي: حساب النقدية)
        - advance_deduction_amount: مبلغ خصم من سلفة الموظف داخل نفس سند الصرف (اختياري)
        - created_by: اسم المستخدم (اختياري)
    """
    payroll_entry = Payroll.query.get_or_404(payroll_id)
    data = request.get_json() or {}

    try:
        paid_date = _parse_iso_date(data.get('paid_date') or datetime.now().date(), 'paid_date')
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    # Optional: deduct an advance from the salary payment voucher.
    try:
        advance_deduction_amount = float(data.get('advance_deduction_amount') or 0.0)
    except Exception:
        return jsonify({'error': 'advance_deduction_amount_invalid'}), 400

    if advance_deduction_amount < 0:
        return jsonify({'error': 'advance_deduction_amount_negative'}), 400

    net_salary = float(payroll_entry.net_salary or 0.0)
    if advance_deduction_amount > net_salary + 1e-9:
        return jsonify({'error': 'advance_deduction_exceeds_net_salary'}), 400

    # ✅ إنشاء سند صرف تلقائي + ترحيله (سند + قيد يومية) إذا لم يكن موجوداً
    if not payroll_entry.voucher_id:
        try:
            # البحث عن حساب الموظف
            employee = Employee.query.get(payroll_entry.employee_id)
            if not employee:
                return jsonify({'error': 'الموظف غير موجود'}), 404

            # إنشاء رقم سند فريد
            voucher_prefix = f"PAY-{payroll_entry.year}-{payroll_entry.month:02d}"
            latest_voucher = (
                Voucher.query.filter(Voucher.voucher_number.like(f"{voucher_prefix}%"))
                .order_by(Voucher.voucher_number.desc())
                .first()
            )
            
            if latest_voucher:
                try:
                    last_seq = int(latest_voucher.voucher_number.split('-')[-1])
                    voucher_number = f"{voucher_prefix}-{last_seq + 1:04d}"
                except (ValueError, IndexError):
                    voucher_number = f"{voucher_prefix}-0001"
            else:
                voucher_number = f"{voucher_prefix}-0001"

            # إنشاء السند (pending ثم يتم ترحيله مباشرة مثل سندات الدفعات)
            voucher = Voucher(
                voucher_number=voucher_number,
                voucher_type='payment',
                date=paid_date,
                description=f"صرف راتب {employee.name} - {payroll_entry.month}/{payroll_entry.year}",
                status='pending',
                created_by=data.get('created_by', 'system'),
                party_type='other',
                party_name=employee.name,
                reference_type='payroll',
                reference_id=int(payroll_entry.id),
                reference_number=f"{payroll_entry.year}-{payroll_entry.month:02d}",
            )
            db.session.add(voucher)
            db.session.flush()  # للحصول على voucher.id

            # ✅ تحديد حساب طرف الرواتب: ذمم الموظف - رواتب (2400xxxx)
            salary_account_id = None
            try:
                from employee_account_helpers import get_or_create_employee_payables_accounts
                from employee_account_naming import employee_payable_account_name

                expected_name = employee_payable_account_name(employee.name, category_ar='رواتب')
                payables = get_or_create_employee_payables_accounts(
                    employee.name,
                    created_by=data.get('created_by', 'system'),
                )
                salary_acc = next((a for a in payables if (a.name or '').strip() == expected_name), None)
                salary_account_id = int(salary_acc.id) if salary_acc else None
            except Exception:
                salary_account_id = None

            if not salary_account_id:
                db.session.rollback()
                return jsonify({'error': 'لا يوجد حساب ذمم رواتب (2400xxxx) لهذا الموظف. يرجى تشغيل Ensure setup للموظف.'}), 400

            # ✅ تحديد حساب الدفع (نقدية/بنك/شيك)
            payment_account_id = data.get('payment_account_id')
            
            if payment_account_id:
                # التحقق من وجود الحساب المحدد
                payment_account = Account.query.get(payment_account_id)
                if not payment_account:
                    db.session.rollback()
                    return jsonify({'error': f'حساب الدفع غير موجود (ID: {payment_account_id})'}), 400
            else:
                # البحث عن حساب النقدية الافتراضي
                payment_account = Account.query.filter(
                    or_(
                        Account.account_number.like('100%'),
                        Account.name.like('%صندوق%'),
                        Account.name.like('%نقدية%'),
                        Account.name.like('%cash%')
                    )
                ).first()

                if not payment_account:
                    db.session.rollback()
                    return jsonify({'error': 'لا يوجد حساب دفع (نقدية/بنك) في النظام'}), 400

            cash_paid = max(0.0, net_salary - advance_deduction_amount)

            # اتجاه الصرف:
            # - debit: ذمم الرواتب (2400xxxx) بقيمة صافي الراتب
            # - credits: الخزنة (نقد/بنك/شيك) بمبلغ المدفوع فعليًا + سلفة الموظف (170/171) بمبلغ الخصم
            if cash_paid > 1e-9:
                safe_line = VoucherAccountLine(
                    voucher_id=voucher.id,
                    account_id=payment_account.id,
                    line_type='credit',
                    amount_type='cash',
                    description=f"صرف راتب {employee.name} - {payment_account.name}",
                    amount=cash_paid,
                )
                db.session.add(safe_line)

            party_line = VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=salary_account_id,
                line_type='debit',
                amount_type='cash',
                description=f"راتب {payroll_entry.month}/{payroll_entry.year}",
                amount=net_salary,
            )
            db.session.add(party_line)

            if advance_deduction_amount > 1e-9:
                if not employee.account_id:
                    db.session.rollback()
                    return jsonify({
                        'error': 'employee_missing_account_for_advance_deduction',
                        'message': (
                            f'لا يمكن خصم السلفة: الموظف "{employee.name}" ليس لديه حساب سلف مرتبط. '
                            'يرجى تعيين حساب سلفة للموظف من صفحة الموظفين أولاً، '
                            'أو اترك حقل "خصم السلفة" بالقيمة صفر.'
                        ),
                    }), 400

                advance_line = VoucherAccountLine(
                    voucher_id=voucher.id,
                    account_id=int(employee.account_id),
                    line_type='credit',
                    amount_type='cash',
                    description=f"خصم سلفة من راتب {employee.name}",
                    amount=float(advance_deduction_amount),
                )
                db.session.add(advance_line)

            # ترحيل السند تلقائياً (إنشاء قيد + ربط + SafeBoxTransaction)
            # Born approved, born posted (APPROVED-ENTRY-001): raises if no entry.
            journal_entry = post_entry_of_approved_voucher(voucher, posted_by=data.get('created_by', 'system'))

            voucher.status = 'approved'
            voucher.approved_at = datetime.now()
            voucher.approved_by = data.get('created_by', 'system')
            voucher.journal_entry_id = journal_entry.id

            _append_safe_transactions_for_voucher(voucher, created_by=voucher.approved_by)

            payroll_entry.voucher_id = voucher.id

        except Exception as e:
            db.session.rollback()
            return jsonify({'error': f'فشل إنشاء سند الصرف: {str(e)}'}), 500

    payroll_entry.paid_date = paid_date
    payroll_entry.status = 'paid'

    try:
        db.session.commit()
        return jsonify(payroll_entry.to_dict(include_employee=True, include_voucher=True))
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث حالة السجل: {str(exc)}'}), 500

# ============================================================================
# Attendance Routes (إدارة الحضور)
# ============================================================================

@employees_bp.route('/attendance', methods=['GET'])
@require_permission('employees.view')
def list_attendance():
    query = Attendance.query

    employee_id = request.args.get('employee_id', type=int)
    if employee_id:
        query = query.filter_by(employee_id=employee_id)

    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')

    if start_date:
        try:
            query = query.filter(Attendance.attendance_date >= _parse_iso_date(start_date, 'start_date'))
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400
    if end_date:
        try:
            query = query.filter(Attendance.attendance_date <= _parse_iso_date(end_date, 'end_date'))
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    status = request.args.get('status')
    if status:
        query = query.filter_by(status=status)

    attendance_records = query.order_by(Attendance.attendance_date.desc()).all()
    return jsonify([record.to_dict(include_employee=True) for record in attendance_records])

@employees_bp.route('/attendance', methods=['POST'])
@require_permission('employees.edit')
def create_attendance():
    data = request.get_json() or {}

    employee_id = data.get('employee_id')
    if not employee_id:
        return jsonify({'error': 'رمز الموظف مطلوب'}), 400

    employee = Employee.query.get(employee_id)
    if not employee:
        return jsonify({'error': 'الموظف غير موجود'}), 400

    try:
        attendance_date = _parse_iso_date(data.get('attendance_date'), 'attendance_date')
        if not attendance_date:
            raise ValueError('تاريخ الحضور مطلوب')
        check_in_time = _parse_iso_time(data.get('check_in_time'), 'check_in_time')
        check_out_time = _parse_iso_time(data.get('check_out_time'), 'check_out_time')
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    attendance_record = Attendance(
        employee_id=employee.id,
        attendance_date=attendance_date,
        check_in_time=check_in_time,
        check_out_time=check_out_time,
        status=data.get('status', 'present'),
        notes=data.get('notes'),
        created_by=data.get('created_by'),
    )

    try:
        db.session.add(attendance_record)
        db.session.commit()
        return jsonify(attendance_record.to_dict(include_employee=True)), 201
    except IntegrityError as exc:
        db.session.rollback()
        return jsonify({'error': f'سجل الحضور موجود بالفعل: {str(exc)}'}), 400
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء سجل الحضور: {str(exc)}'}), 500

@employees_bp.route('/attendance/<int:attendance_id>', methods=['GET'])
@require_permission('employees.view')
def get_attendance(attendance_id):
    attendance_record = Attendance.query.get_or_404(attendance_id)
    return jsonify(attendance_record.to_dict(include_employee=True))

@employees_bp.route('/attendance/<int:attendance_id>', methods=['PUT'])
@require_permission('employees.edit')
def update_attendance(attendance_id):
    attendance_record = Attendance.query.get_or_404(attendance_id)
    data = request.get_json() or {}

    if 'employee_id' in data:
        employee_id = data['employee_id']
        if employee_id:
            employee = Employee.query.get(employee_id)
            if not employee:
                return jsonify({'error': 'الموظف غير موجود'}), 400
            attendance_record.employee_id = employee.id

    if 'attendance_date' in data:
        try:
            attendance_record.attendance_date = _parse_iso_date(data['attendance_date'], 'attendance_date')
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    if 'check_in_time' in data:
        try:
            attendance_record.check_in_time = _parse_iso_time(data['check_in_time'], 'check_in_time')
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    if 'check_out_time' in data:
        try:
            attendance_record.check_out_time = _parse_iso_time(data['check_out_time'], 'check_out_time')
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    if 'status' in data and data['status']:
        attendance_record.status = data['status']

    if 'notes' in data:
        attendance_record.notes = data['notes']

    try:
        db.session.commit()
        return jsonify(attendance_record.to_dict(include_employee=True))
    except IntegrityError as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث سجل الحضور: {str(exc)}'}), 400
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث سجل الحضور: {str(exc)}'}), 500

@employees_bp.route('/attendance/<int:attendance_id>', methods=['DELETE'])
@require_permission('employees.delete')
def delete_attendance(attendance_id):
    attendance_record = Attendance.query.get_or_404(attendance_id)

    try:
        db.session.delete(attendance_record)
        db.session.commit()
        return jsonify({'message': 'تم حذف سجل الحضور بنجاح'})
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل حذف سجل الحضور: {str(exc)}'}), 500

# ──────────────────────────────────────────────────────────────────────────────
# Goal Achievements — إنجازات الأهداف
# ──────────────────────────────────────────────────────────────────────────────

@employees_bp.route('/achievements/unseen', methods=['GET'])
@require_auth
def get_unseen_achievements():
    """
    GET /api/achievements/unseen
    يرجع قائمة الإنجازات التي لم يشاهدها المستخدم بعد.
    """
    try:
        current_user = getattr(g, 'current_user', None)
        employee_id = getattr(current_user, 'employee_id', None) if current_user else None

        # Only show achievements for the current employee — never expose other employees' data.
        if not employee_id:
            return jsonify({'achievements': []}), 200

        achievements = (
            GoalAchievement.query
            .filter_by(seen_by_user=False, employee_id=employee_id)
            .order_by(GoalAchievement.achieved_at.desc())
            .limit(10)
            .all()
        )
        return jsonify({'achievements': [a.to_dict() for a in achievements]}), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@employees_bp.route('/achievements/<int:achievement_id>/mark-seen', methods=['POST'])
@require_auth
def mark_achievement_seen(achievement_id):
    """
    POST /api/achievements/<id>/mark-seen
    يضع علامة "تمت المشاهدة" على الإنجاز حتى لا يظهر مرة أخرى.
    """
    try:
        achievement = GoalAchievement.query.get_or_404(achievement_id)
        refused = refuse_unless_self(achievement.employee_id)
        if refused:
            return refused
        achievement.mark_seen()
        db.session.commit()
        return jsonify({'success': True}), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@employees_bp.route('/achievements', methods=['POST'])
@require_permission('employees.bonuses')
@require_auth
def create_achievement():
    """
    POST /api/achievements
    ينشئ سجل إنجاز جديد (يستخدم من الـ backend أو admin).
    
    Body (JSON):
        employee_id, goal_name, bonus_amount,
        goal_description?, bonus_rule_id?, bonus_id?,
        currency?, metrics?, achieved_at?
    """
    try:
        data = request.get_json(force=True) or {}

        employee_id = data.get('employee_id')
        goal_name = data.get('goal_name', '').strip()
        bonus_amount = float(data.get('bonus_amount', 0.0))

        if not employee_id or not goal_name:
            return jsonify({'error': 'employee_id و goal_name مطلوبان'}), 400

        from datetime import datetime as _dt
        achieved_at_raw = data.get('achieved_at')
        achieved_at = (
            _dt.fromisoformat(achieved_at_raw)
            if achieved_at_raw
            else _dt.now()
        )

        achievement = GoalAchievement(
            employee_id=int(employee_id),
            bonus_rule_id=data.get('bonus_rule_id'),
            bonus_id=data.get('bonus_id'),
            goal_name=goal_name,
            goal_description=data.get('goal_description'),
            bonus_amount=bonus_amount,
            currency=data.get('currency', 'ر.س'),
            metrics=data.get('metrics') or {},
            achieved_at=achieved_at,
        )
        db.session.add(achievement)
        db.session.commit()
        return jsonify(achievement.to_dict()), 201
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@employees_bp.route('/achievements/check-progress', methods=['POST'])
@require_auth
def check_goal_progress():
    """
    POST /api/achievements/check-progress

    يفحص الأهداف الشخصية للموظف (weight/points/invoices) للفترات المفعلة
    ويُنشئ GoalAchievement عند تحقق الهدف مع احتساب المكافأة المستحقة.
    يدعم نوع المكافأة الثابتة أو المرتبطة بقاعدة BonusRule.
    """
    from datetime import datetime as _dt, timedelta as _td

    try:
        current_user = getattr(g, 'current_user', None)
        if not current_user:
            return jsonify({'achievements': []}), 200

        employee_id = getattr(current_user, 'employee_id', None)
        if not employee_id:
            return jsonify({'achievements': []}), 200

        employee = Employee.query.get(employee_id)
        if not employee or not employee.is_active:
            return jsonify({'achievements': []}), 200

        # ── قراءة الأهداف: شخصية أولاً، ثم هدف الفريق (وزن شهري/أسبوعي) كاحتياط ──
        settings_row = _get_settings_singleton(create_if_missing=False)

        # إعدادات النقاط: نفس مصدر الحقيقة الوحيد لسباق الأداء
        from models import get_race_points_config
        _race_cfg = get_race_points_config()
        points_per_gram     = max(0.001, float(_race_cfg.get('points_per_gram') or 10.0))
        _race_points_source = str(_race_cfg.get('points_source') or 'gold_weight')
        _race_cpp           = max(0.01,  float(_race_cfg.get('cash_amount_per_point') or 100.0))
        _race_point_rules   = _race_cfg.get('point_rules') or []

        metric = (getattr(employee, 'goal_metric', None) or 'weight').strip().lower()
        if metric not in ('weight', 'points', 'invoices'):
            metric = 'weight'

        def _target_for(period_name: str):
            if period_name == 'daily':
                mapping = {
                    'weight': getattr(employee, 'goal_weight_daily', None),
                    'points': getattr(employee, 'goal_points_daily', None),
                    'invoices': getattr(employee, 'goal_invoices_daily', None),
                }
            elif period_name == 'weekly':
                mapping = {
                    'weight': getattr(employee, 'goal_weight_weekly', None),
                    'points': getattr(employee, 'goal_points_weekly', None),
                    'invoices': getattr(employee, 'goal_invoices_weekly', None),
                }
            else:
                mapping = {
                    'weight': getattr(employee, 'goal_weight_monthly', None),
                    'points': getattr(employee, 'goal_points_monthly', None),
                    'invoices': getattr(employee, 'goal_invoices_monthly', None),
                }

            target = mapping.get(metric)
            if target is not None:
                return target

            # fallback legacy settings only for weight weekly/monthly
            if metric == 'weight' and settings_row is not None:
                if period_name == 'weekly':
                    return getattr(settings_row, 'weekly_sales_target_weight', None)
                if period_name == 'monthly':
                    return getattr(settings_row, 'monthly_sales_target_weight', None)
            return None

        def _calc_bonus_for(period_name: str, actual: float = 0.0):
            reward_type = (getattr(employee, f'goal_reward_type_{period_name}', None) or 'fixed').strip().lower()
            if reward_type == 'rule':
                rule_id = getattr(employee, f'goal_bonus_rule_id_{period_name}', None)
                if rule_id:
                    rule = BonusRule.query.get(rule_id)
                    if rule and bool(getattr(rule, 'is_active', True)) and rule.is_valid_for_employee(employee):
                        bonus_type = (getattr(rule, 'bonus_type', None) or 'fixed').strip().lower()
                        bonus_val  = float(getattr(rule, 'bonus_value', None) or 0.0)
                        # points_per_unit / percentage_of_sales / per_gram → مضروب في الأداء
                        if bonus_type in ('points_per_unit', 'percentage_of_sales', 'per_gram', 'per_invoice'):
                            amount = actual * bonus_val
                        else:
                            amount = bonus_val
                        min_bonus = getattr(rule, 'min_bonus', None)
                        max_bonus = getattr(rule, 'max_bonus', None)
                        if min_bonus is not None:
                            amount = max(amount, float(min_bonus))
                        if max_bonus is not None:
                            amount = min(amount, float(max_bonus))
                        return amount, int(rule.id)
                return 0.0, None
            return float(getattr(employee, f'goal_bonus_{period_name}', None) or 0.0), None

        # None means the column existed before the boolean was introduced — treat as the
        # intended default (True for weekly/monthly, False for daily).
        def _goal_enabled(val, default: bool) -> bool:
            if val is None:
                return default
            return bool(val)

        if not any([
            _goal_enabled(getattr(employee, 'goal_daily_enabled',   None), False),
            _goal_enabled(getattr(employee, 'goal_weekly_enabled',  None), True),
            _goal_enabled(getattr(employee, 'goal_monthly_enabled', None), True),
        ]):
            return jsonify({'achievements': []}), 200

        now = _dt.now()
        new_achievements = []

        # ── جلب اسم المستخدم للموظف مرة واحدة (للبحث بـ posted_by أيضاً) ──
        _goal_username = None
        try:
            ua = getattr(employee, 'user_account', None)
            if ua and getattr(ua, 'username', None):
                _goal_username = str(ua.username).strip() or None
        except Exception:
            pass

        # ── دالة: حساب الأداء الفعلي لفترة معينة ──
        def _sold_weight(start_dt, end_dt):
            # للنقاط: نشمل "شراء من عميل" تطابقاً مع لوحة المبيعات
            if metric == 'points':
                inv_types = ['بيع', 'sell', 'sale', 'شراء من عميل']
            else:
                inv_types = ['بيع', 'sell', 'sale']
            # نجمع بين employee_id و posted_by بـ OR تطابقاً مع لوحة المبيعات
            if _goal_username:
                _attr = or_(Invoice.employee_id == employee_id, Invoice.posted_by == _goal_username)
            else:
                _attr = Invoice.employee_id == employee_id
            invoices = Invoice.query.filter(
                or_(Invoice.is_posted.is_(True), Invoice.status == 'posted'),
                Invoice.date >= start_dt,
                Invoice.date < end_dt,
                Invoice.invoice_type.in_(inv_types),
                _attr,
            ).all()
            if metric == 'invoices':
                return float(len(invoices))
            if metric == 'points':
                # نستدعي المحرك المشترك بنفس إعدادات سباق الأداء — Single Source of Truth
                # يضمن تطابق نقاط الهدف مع نقاط اللوحة تماماً
                # ومرتجع بيعٍ له في الفترة يسترد نقاط بيعه (قرار المالك 10 أكتوبر 2026)
                from points.engine import compute_invoices_points, sale_returns_against

                def _sold_by(original):
                    if _goal_username:
                        return or_(original.employee_id == employee_id, original.posted_by == _goal_username)
                    return original.employee_id == employee_id

                invoices = invoices + sale_returns_against(_sold_by, start_dt, end_dt)
                return compute_invoices_points(
                    invoices,
                    points_source=_race_points_source,
                    cash_amount_per_point=_race_cpp,
                    points_per_gram=points_per_gram,
                    point_rules=_race_point_rules,
                )

            total_w = 0.0
            for inv in invoices:
                # نفضّل وزن الفاتورة الكلي؛ ثم نجمع من البنود كاحتياط
                inv_weight = getattr(inv, 'total_weight', None)
                if inv_weight is not None:
                    try:
                        total_w += float(inv_weight or 0.0)
                        continue
                    except Exception:
                        pass
                for item in (inv.items or []):
                    try:
                        total_w += float(getattr(item, 'weight', None) or 0.0)
                    except Exception:
                        pass
            return float(total_w)

        # ── جلب جميع إنجازات الموظف مرة واحدة + مساعد بحث حسب period_key ──
        employee_achievements = GoalAchievement.query.filter_by(employee_id=employee_id).all()

        def _metrics_dict(value):
            if isinstance(value, dict):
                return value
            if isinstance(value, str):
                try:
                    parsed = json.loads(value)
                    return parsed if isinstance(parsed, dict) else {}
                except Exception:
                    return {}
            return {}

        def _find_existing(pk: str):
            for ach in employee_achievements:
                if ach.period_key == pk:
                    return ach
                m = _metrics_dict(ach.metrics)
                if m.get('period_key') == pk:
                    return ach
            return None

        unit_label = {'weight': 'جم', 'points': 'نقطة', 'invoices': 'فاتورة'}.get(metric, 'جم')

        # ─── الفترات: يومي / أسبوعي / شهري ────────────────────────────────
        today_start = _dt.combine(now.date(), _dt.min.time())
        tomorrow_start = today_start + _td(days=1)
        week_start_date = now.date() - _td(days=now.weekday())
        week_start = _dt.combine(week_start_date, _dt.min.time())
        week_end = week_start + _td(days=7)
        month_start = _dt(now.year, now.month, 1)
        month_end = _dt(now.year + 1, 1, 1) if now.month == 12 else _dt(now.year, now.month + 1, 1)

        periods = [
            ('daily',   _goal_enabled(getattr(employee, 'goal_daily_enabled',   None), False), today_start,  tomorrow_start, f'{now.year}/{now.month:02d}/{now.day:02d}'),
            ('weekly',  _goal_enabled(getattr(employee, 'goal_weekly_enabled',  None), True),  week_start,   week_end,       f'W{now.isocalendar()[1]:02d}/{now.year}'),
            ('monthly', _goal_enabled(getattr(employee, 'goal_monthly_enabled', None), True),  month_start,  month_end,      f'{now.year}/{now.month:02d}'),
        ]

        for period_name, enabled, start_dt, end_dt, period_label in periods:
            if not enabled:
                continue

            raw_target = _target_for(period_name)
            try:
                target = float(raw_target or 0.0)
            except Exception:
                target = 0.0
            if target <= 0:
                continue

            if period_name == 'daily':
                period_key = f'daily-{now.year}-{now.month:02d}-{now.day:02d}'
            elif period_name == 'weekly':
                period_key = f'weekly-{now.year}-W{now.isocalendar()[1]:02d}'
            else:
                period_key = f'monthly-{now.year}-{now.month:02d}'

            actual = _sold_weight(start_dt, end_dt)
            if actual < target:
                continue

            bonus_amount, bonus_rule_id = _calc_bonus_for(period_name, actual)

            existing = _find_existing(period_key)
            if existing is not None:
                # إعادة عرض الاحتفالية إذا:
                # 1) تغيّرت المكافأة من صفر إلى قيمة
                # 2) تغيّر الهدف مقارنةً بما هو مخزون في الإنجاز
                existing_bonus = float(existing.bonus_amount or 0.0)
                existing_target = float((_metrics_dict(existing.metrics)).get('target', -1) or -1)
                bonus_changed = existing_bonus <= 0.0 and float(bonus_amount or 0.0) > 0.0
                target_changed = existing_target >= 0 and abs(existing_target - target) > 0.001
                should_refresh_seen = bonus_changed or target_changed
                if should_refresh_seen:
                    existing.bonus_amount = float(bonus_amount)
                    existing.bonus_rule_id = bonus_rule_id
                    existing.goal_description = f'تحققت {actual:.1f} {unit_label} من أصل {target:.1f} {unit_label}'
                    m = dict(_metrics_dict(existing.metrics))
                    m.update({
                        metric: round(actual, 2),
                        'actual': round(actual, 2),
                        'target': round(target, 2),
                        'metric': metric,
                        'period': period_label,
                        'period_key': period_key,
                    })
                    existing.metrics = m
                    existing.seen_by_user = False
                    existing.seen_at = None
                    new_achievements.append(existing)
                elif not bool(existing.seen_by_user):
                    new_achievements.append(existing)
                continue

            a = GoalAchievement(
                employee_id=employee_id,
                bonus_rule_id=bonus_rule_id,
                period_key=period_key,
                goal_period=period_name,
                goal_name=getattr(employee, 'goal_name', None) or (
                    f'هدف اليوم {period_label}' if period_name == 'daily' else
                    f'هدف الأسبوع {period_label}' if period_name == 'weekly' else
                    f'هدف الشهر {period_label}'
                ),
                goal_description=f'تحققت {actual:.1f} {unit_label} من أصل {target:.1f} {unit_label}',
                bonus_amount=float(bonus_amount or 0.0),
                metrics={
                    'period_key': period_key,
                    metric: round(actual, 2),
                    'actual': round(actual, 2),
                    'target': round(target, 2),
                    'metric': metric,
                    'period': period_label,
                },
                achieved_at=now,
            )
            db.session.add(a)
            new_achievements.append(a)

        if new_achievements:
            db.session.commit()

        return jsonify({'achievements': [a.to_dict() for a in new_achievements]}), 200

    except Exception as e:
        db.session.rollback()
        return jsonify({'achievements': [], 'error': str(e)}), 200

# ─── تعديل أهداف الأداء الشخصية للموظف ─────────────────────────────────────
@employees_bp.route('/employees/<int:employee_id>/goals', methods=['PATCH'])
@require_permission('employees.bonuses')
@require_auth
def update_employee_goals(employee_id):
    """تحديث أهداف الأداء الشخصية للموظف (مستقلة عن أهداف الفريق في الإعدادات)."""
    employee = Employee.query.get_or_404(employee_id)
    data = request.get_json(force=True) or {}
    _GOAL_FIELDS = [
        'goal_metric', 'goal_name',
        'goal_weight_monthly', 'goal_weight_weekly',
        'goal_points_monthly', 'goal_points_weekly',
        'goal_invoices_monthly', 'goal_invoices_weekly',
    ]
    for field in _GOAL_FIELDS:
        if field not in data:
            continue
        val = data[field]
        if field not in ('goal_metric', 'goal_name') and val is not None:
            try:
                val = int(val) if 'invoices' in field else float(val)
            except (TypeError, ValueError):
                val = None
        setattr(employee, field, val)
    db.session.commit()
    return jsonify({'success': True, 'employee': employee.to_dict()}), 200
