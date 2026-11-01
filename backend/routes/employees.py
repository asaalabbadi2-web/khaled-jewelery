"""Employee domain routes — employees_bp registered under /api in app.py."""
from __future__ import annotations

import io
import json
import os
from datetime import date, datetime, timedelta

from flask import Blueprint, abort, g, jsonify, request
from services.record_ownership import refuse_unless_self
from sqlalchemy import and_, func, or_
from sqlalchemy.exc import IntegrityError

from models import (
    db,
    Account,
    Attendance,
    BonusRule,
    Employee,
    EmployeeAdvancePlan,
    EmployeeBonus,
    EmployeeContract,
    EmployeeDocument,
    EmployeeDocumentType,
    EmployeeLeave,
    EmployeeTermination,
    LeaveType,
    GoalAchievement,
    Invoice,
    JournalEntry,
    JournalEntryLine,
    ContributionComponent,
    ContributionScheme,
    Payroll,
    PayrollRun,
    SafeBox,
    SalaryStructure,
    Settings,
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

    from services.employee_access import refuse_owned_elsewhere
    from services.payroll_laws import PayrollRefused
    try:
        refuse_owned_elsewhere(data)                          # HR-UX ط1: the structure's, the settlement's
    except PayrollRefused as refused:
        return _payroll_refusal(refused)

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
                linked_tt = (getattr(linked, 'transaction_type', '') or '').strip().lower()

                # A group (an account with children) or a weight account is no
                # employee's personal account -- known by what it is, not its number.
                is_group = Account.query.filter_by(parent_id=linked.id).first() is not None
                if is_group or linked_tt == 'gold' or bool(getattr(linked, 'tracks_weight', False)):
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
                'hint': 'تأكد من ربط حسابات الموظفين التجميعية في «الربط المحاسبي» (employee_personal_parent…)'
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
        salary=0.0,                                          # his structure's, when he has one
        hire_date=_parse_iso_date(data.get('hire_date'), 'hire_date'),
        account_id=account_id,
        is_active=data.get('is_active', True),
        notes=data.get('notes'),
        created_by=data.get('created_by'),
    )

    # PAYROLL-2: his contribution scheme, payment method and IBAN, each checked.
    from services.payroll_laws import PayrollRefused
    from services.payroll_policy import apply_payment_fields
    try:
        apply_payment_fields(employee, data)
    except PayrollRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.message}), 400

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
        from services.approval_policy import actor
        from services.employee_access import record
        record(employee, action='create_employee', before=None, by=actor(), now=datetime.now())  # EMP-1

        # Auto-create employee-specific payables accounts under 230/240/250 (detail 2300/2400/2500).
        # Default: enabled (can be disabled by sending auto_create_payables_accounts=false)
        if _boolish(data.get('auto_create_payables_accounts'), default=True):
            try:
                created_by = data.get('created_by', 'system')
                created_payables_accounts = create_employee_payables_accounts(employee, created_by=created_by)
            except Exception as exc:
                # Nothing of the employee is kept half-made (CHART-002).
                db.session.rollback()
                from accounting.mappings import AccountNotMapped
                status = 400 if isinstance(exc, AccountNotMapped) else 500
                return jsonify({'error': f'فشل إنشاء حسابات مستحقات الموظف: {str(exc)}'}), status

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
    from services.employee_access import refuse_owned_elsewhere, snapshot
    from services.payroll_laws import PayrollRefused
    try:
        refuse_owned_elsewhere(data, employee)                # HR-UX ط1: the structure's, the settlement's
    except PayrollRefused as refused:
        return _payroll_refusal(refused)
    before = snapshot(employee)                              # EMP-1: the change is recorded
    was_active = bool(employee.is_active)

    for field in ['name', 'job_title', 'department', 'phone', 'email', 'national_id', 'notes', 'created_by']:
        if field in data:
            setattr(employee, field, data[field])

    if 'hire_date' in data:
        employee.hire_date = _parse_iso_date(data['hire_date'], 'hire_date')

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

    from services.payroll_laws import PayrollRefused
    from services.payroll_policy import apply_payment_fields
    try:
        apply_payment_fields(employee, data)                   # PAYROLL-2
    except PayrollRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.message}), 400

    from services.approval_policy import actor
    from services.employee_access import record, stop
    stopped = None
    if was_active and not employee.is_active:
        stopped = stop(employee, by=actor(), now=datetime.now(), before=before)
    else:
        record(employee, action='update_employee', before=before, by=actor(), now=datetime.now())

    try:
        db.session.commit()
        body = employee.to_dict(include_details=True)
        if stopped:
            body.update(stopped)
        return jsonify(body)
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

        from services.approval_policy import actor
        from services.employee_access import record, snapshot, stop
        if has_attendance or has_payroll or has_invoices or has_bonuses or has_linked_user:
            stopped = stop(employee, by=actor(), now=datetime.now()) if employee.is_active else {}
            db.session.commit()
            return jsonify({
                'success': True,
                'deleted': False,
                'deactivated': True,
                'is_active': False,
                'message': 'لا يمكن حذف الموظف لوجود عمليات/سجلات مرتبطة. تم إلغاء تفعيله بدلاً من الحذف',
                **stopped,
            }), 200

        record(employee, action='delete_employee', before=snapshot(employee), by=actor(), now=datetime.now())
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

@employees_bp.route('/employees/<int:employee_id>/file', methods=['GET'])
@require_permission('employees.payroll')
def get_employee_file(employee_id):
    """EMP-2: his file in one place, each part from its owner (services/employee_file)."""
    from services.employee_file import file_of
    return jsonify(file_of(Employee.query.get_or_404(employee_id), today=datetime.now().date()))


@employees_bp.route('/hr/overview', methods=['GET'])
@require_permission('employees.payroll')
def get_hr_overview():
    """HR-UX ر1: the hub's indicators, employees and what needs doing (services/hr_overview)."""
    from services.hr_overview import overview
    return jsonify(overview(today=datetime.now().date()))


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
    # EMP-1: stopped, his users are stopped and his open custody said; started
    # again, his users stay stopped -- each is started on its own.
    from services.approval_policy import actor
    from services.employee_access import record, snapshot, stop
    stopped = {}
    if employee.is_active:
        stopped = stop(employee, by=actor(), now=datetime.now())
    else:
        before = snapshot(employee)
        employee.is_active = True
        record(employee, action='start_employee', before=before, by=actor(), now=datetime.now())

    try:
        db.session.commit()
        return jsonify({'id': employee.id, 'is_active': employee.is_active, **stopped})
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
            # An unlinked personal account already made for this employee, under
            # the mapped personal parent -- never a same-named account elsewhere.
            from services.employee_accounts import PERSONAL_PARENT, parent_account
            parent_acc = parent_account(PERSONAL_PARENT)
            expected_name = employee_personal_account_name(employee.name)
            existing = Account.query.filter_by(parent_id=parent_acc.id, name=expected_name).first()

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
            payables = get_or_create_employee_payables_accounts(employee, created_by=created_by)
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
            payables = get_or_create_employee_payables_accounts(emp, created_by='bulk-ensure')
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

# ── PAYROLL-2: the payroll's data and policy (services/payroll_policy) ─────────

def _payroll_refusal(refused, status=400):
    body = {'error': refused.message}
    if getattr(refused, 'code', None):
        body['code'] = refused.code
    return jsonify(body), status


@employees_bp.route('/payroll/policy', methods=['GET'])
@require_permission('employees.payroll')
def get_payroll_policy():
    from services.payroll_policy import KEYS, policy
    return jsonify({'policy': policy(), 'keys': list(KEYS)})


@employees_bp.route('/payroll/policy', methods=['PUT'])
@require_permission('employees.payroll')
def update_payroll_policy():
    from services.payroll_laws import PayrollRefused
    from services.payroll_policy import set_policy
    try:
        saved = set_policy(request.get_json() or {})
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused)
    db.session.commit()
    return jsonify({'policy': saved})


@employees_bp.route('/payroll/structure-suggestion', methods=['GET'])
@require_permission('employees.payroll')
def suggest_salary_structure():
    from services.payroll_laws import PayrollRefused
    from services.payroll_policy import suggest_structure
    try:
        return jsonify(suggest_structure(request.args.get('gross')))
    except PayrollRefused as refused:
        return _payroll_refusal(refused)


@employees_bp.route('/employees/<int:employee_id>/salary-structures', methods=['GET'])
@require_permission('employees.payroll')
def list_salary_structures(employee_id):
    from services.payroll_policy import structure_on, suggested_from
    employee = Employee.query.get_or_404(employee_id)
    rows = (SalaryStructure.query.filter_by(employee_id=employee_id)
            .order_by(SalaryStructure.effective_from.desc()).all())
    today = datetime.now().date()
    current = structure_on(employee_id, today)
    return jsonify({'structures': [row.to_dict() for row in rows],
                    'current_id': current.id if current is not None else None,
                    'suggested_from': suggested_from(employee, today).isoformat()})


@employees_bp.route('/employees/<int:employee_id>/salary-structures', methods=['POST'])
@require_permission('employees.payroll')
def create_salary_structure(employee_id):
    from services.payroll_laws import PayrollRefused
    from services.payroll_policy import save_structure
    data = request.get_json() or {}
    try:
        structure = save_structure(employee_id, data, by=data.get('created_by') or 'system',
                                   today=datetime.now().date())
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused)
    db.session.commit()
    return jsonify(structure.to_dict()), 201


@employees_bp.route('/salary-structures/<int:structure_id>', methods=['PUT'])
@require_permission('employees.payroll')
def update_salary_structure(structure_id):
    from services.payroll_laws import PayrollRefused
    from services.payroll_policy import save_structure
    structure = SalaryStructure.query.get_or_404(structure_id)
    data = request.get_json() or {}
    try:
        save_structure(structure.employee_id, data, by=data.get('created_by') or 'system',
                       today=datetime.now().date(), structure=structure)
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused, 409)
    db.session.commit()
    return jsonify(structure.to_dict())


@employees_bp.route('/salary-structures/<int:structure_id>', methods=['DELETE'])
@require_permission('employees.payroll')
def delete_salary_structure(structure_id):
    from services.payroll_laws import PayrollRefused
    from services.payroll_policy import delete_structure
    structure = SalaryStructure.query.get_or_404(structure_id)
    try:
        delete_structure(structure, today=datetime.now().date())
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused, 409)
    db.session.commit()
    return jsonify({'message': 'حُذف هيكل الراتب'})


@employees_bp.route('/contribution-schemes', methods=['GET'])
@require_permission('employees.payroll')
def list_contribution_schemes():
    return jsonify([scheme.to_dict() for scheme in ContributionScheme.query.order_by(ContributionScheme.id)])


@employees_bp.route('/contribution-schemes', methods=['POST'])
@require_permission('employees.payroll')
def create_contribution_scheme():
    data = request.get_json() or {}
    name = (data.get('name') or '').strip()
    if not name:
        return jsonify({'error': 'اسم الخطة مطلوب'}), 400
    if ContributionScheme.query.filter_by(name=name).first() is not None:
        return jsonify({'error': 'توجد خطة بهذا الاسم'}), 409
    scheme = ContributionScheme(name=name, is_active=True, notes=data.get('notes'))
    db.session.add(scheme)
    db.session.commit()
    return jsonify(scheme.to_dict()), 201


@employees_bp.route('/contribution-schemes/<int:scheme_id>', methods=['PUT'])
@require_permission('employees.payroll')
def update_contribution_scheme(scheme_id):
    scheme = ContributionScheme.query.get_or_404(scheme_id)
    data = request.get_json() or {}
    if 'name' in data:
        name = (data.get('name') or '').strip()
        clash = ContributionScheme.query.filter_by(name=name).first()
        if not name or (clash is not None and clash.id != scheme.id):
            return jsonify({'error': 'اسم الخطة مطلوب ولا يتكرر'}), 400
        scheme.name = name
    if 'is_active' in data:
        scheme.is_active = bool(data['is_active'])
    if 'notes' in data:
        scheme.notes = data.get('notes')
    db.session.commit()
    return jsonify(scheme.to_dict())


@employees_bp.route('/contribution-schemes/<int:scheme_id>/components', methods=['POST'])
@require_permission('employees.payroll')
def create_contribution_component(scheme_id):
    from services.payroll_laws import PayrollRefused
    from services.payroll_policy import save_component
    scheme = ContributionScheme.query.get_or_404(scheme_id)
    try:
        component = save_component(scheme, request.get_json() or {})
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused)
    except IntegrityError:
        db.session.rollback()
        return jsonify({'error': 'لهذا البند نسبة من هذا اليوم: عدّلها أو اختر يومًا آخر'}), 409
    db.session.commit()
    return jsonify(component.to_dict()), 201


@employees_bp.route('/contribution-components/<int:component_id>', methods=['PUT'])
@require_permission('employees.payroll')
def update_contribution_component(component_id):
    from services.payroll_laws import PayrollRefused
    from services.payroll_policy import save_component
    component = ContributionComponent.query.get_or_404(component_id)
    try:
        save_component(component.scheme, request.get_json() or {}, component=component)
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused)
    except IntegrityError:
        db.session.rollback()
        return jsonify({'error': 'لهذا البند نسبة من هذا اليوم'}), 409
    db.session.commit()
    return jsonify(component.to_dict())


@employees_bp.route('/employees/<int:employee_id>/contributions', methods=['GET'])
@require_permission('employees.payroll')
def preview_employee_contributions(employee_id):
    """His contributions on a day (today by default), from his scheme and structure."""
    from services.payroll_policy import contributions, structure_on
    employee = Employee.query.get_or_404(employee_id)
    try:
        day = date.fromisoformat(request.args['day']) if request.args.get('day') else datetime.now().date()
    except ValueError:
        return jsonify({'error': 'اليوم YYYY-MM-DD'}), 400
    structure = structure_on(employee_id, day)
    return jsonify({'day': day.isoformat(), 'structure': structure.to_dict() if structure else None,
                    'contributions': contributions(employee, structure, day)})


# ── PAYROLL-2 (M2b): a month's run (services/payroll_run) ───────────────────────

def _run_view(run, status=200, left_out=None):
    from services.payroll_run import left_out as run_left_out
    body = run.to_dict(include_entries=True)
    body['left_out'] = left_out if left_out is not None else run_left_out(run)
    return jsonify(body), status


def _run_action(run, action):
    """The action, committed -- or refused with the run as it was."""
    from services.payroll_laws import PayrollRefused
    try:
        action()
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused, 409)
    db.session.commit()
    return _run_view(run)


@employees_bp.route('/payroll/runs', methods=['GET'])
@require_permission('employees.payroll')
def list_payroll_runs():
    query = PayrollRun.query
    if request.args.get('year'):
        query = query.filter(PayrollRun.year == int(request.args['year']))
    runs = query.order_by(PayrollRun.year.desc(), PayrollRun.month.desc(), PayrollRun.id.desc()).all()
    return jsonify([run.to_dict() for run in runs])


@employees_bp.route('/payroll/runs', methods=['POST'])
@require_permission('employees.payroll')
def create_payroll_run():
    from services.payroll_laws import PayrollRefused
    from services.payroll_run import generate
    data = request.get_json(silent=True) or {}
    try:
        run, left_out = generate(data.get('month'), data.get('year'), by=data.get('created_by') or 'system')
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused, 409 if refused.code == 'payroll_run_exists' else 400)
    db.session.commit()
    return _run_view(run, 201, left_out)


@employees_bp.route('/payroll/runs/<int:run_id>', methods=['GET'])
@require_permission('employees.payroll')
def get_payroll_run(run_id):
    return _run_view(PayrollRun.query.get_or_404(run_id))


def _run_line(run_id, payroll_id):
    line = Payroll.query.get_or_404(payroll_id)
    if line.payroll_run_id != run_id:
        abort(404)
    return line


@employees_bp.route('/payroll/runs/<int:run_id>/lines', methods=['POST'])
@require_permission('employees.payroll')
def add_payroll_run_line(run_id):
    from services.payroll_run import add_line
    run = PayrollRun.query.get_or_404(run_id)
    data = request.get_json(silent=True) or {}
    try:
        employee = Employee.query.get_or_404(int(data.get('employee_id') or 0))
    except (TypeError, ValueError):
        abort(404)
    by = data.get('created_by') or 'system'
    return _run_action(run, lambda: add_line(run, employee, by=by))


@employees_bp.route('/payroll/runs/<int:run_id>/lines/<int:payroll_id>', methods=['PUT'])
@require_permission('employees.payroll')
def update_payroll_run_line(run_id, payroll_id):
    from services.payroll_run import edit_line
    line = _run_line(run_id, payroll_id)
    return _run_action(line.run, lambda: edit_line(line, request.get_json(silent=True) or {}))


@employees_bp.route('/payroll/runs/<int:run_id>/lines/<int:payroll_id>', methods=['DELETE'])
@require_permission('employees.payroll')
def delete_payroll_run_line(run_id, payroll_id):
    from services.payroll_run import remove_line
    line = _run_line(run_id, payroll_id)
    return _run_action(line.run, lambda: remove_line(line))


@employees_bp.route('/payroll/runs/<int:run_id>/approve', methods=['POST'])
@require_permission('employees.payroll')
def approve_payroll_run(run_id):
    from services.payroll_run import approve
    run = PayrollRun.query.get_or_404(run_id)
    by = (request.get_json(silent=True) or {}).get('created_by') or 'system'
    return _run_action(run, lambda: approve(run, by=by, now=datetime.now()))


@employees_bp.route('/payroll/runs/<int:run_id>/cancel', methods=['POST'])
@require_permission('employees.payroll')
def cancel_payroll_run(run_id):
    from services.payroll_run import cancel
    run = PayrollRun.query.get_or_404(run_id)
    by = (request.get_json(silent=True) or {}).get('created_by') or 'system'
    return _run_action(run, lambda: cancel(run, by=by, now=datetime.now()))


@employees_bp.route('/payroll/runs/<int:run_id>/pay', methods=['POST'])
@require_permission('employees.payroll')
def pay_payroll_run(run_id):
    """Body: bank_account_id, cash_account_id (by how each employee is paid),
    paid_date, and lines [{payroll_id, payment_account_id, advance_deduction_amount}]."""
    from services.payroll_run import pay_run
    run = PayrollRun.query.get_or_404(run_id)
    data = request.get_json(silent=True) or {}
    return _run_action(run, lambda: pay_run(run, data, by=data.get('created_by') or 'system', now=datetime.now()))


@employees_bp.route('/payroll/<int:payroll_id>/payslip', methods=['GET'])
@require_permission('employees.payroll')
def get_payslip(payroll_id):
    from services.payroll_run import payslip
    return jsonify(payslip(Payroll.query.get_or_404(payroll_id)))


# ── PAYROLL-3 (M3): advances repaid from the salary (services/payroll_advances) ─

@employees_bp.route('/employees/<int:employee_id>/advance-plans', methods=['GET'])
@require_permission('employees.payroll')
def list_advance_plans(employee_id):
    from services.payroll_advances import account_balance, remaining, to_dict
    employee = Employee.query.get_or_404(employee_id)
    plans = employee.advance_plans.order_by(EmployeeAdvancePlan.id.desc()).all()
    balance = account_balance(employee)
    planned = round(sum(remaining(p) for p in plans if p.status == 'active'), 2)
    return jsonify({'plans': [to_dict(p) for p in plans], 'account_balance': balance,
                    'unplanned': round(balance - planned, 2)})


@employees_bp.route('/employees/<int:employee_id>/advance-plans', methods=['POST'])
@require_permission('employees.payroll')
def create_advance_plan(employee_id):
    from services.payroll_advances import create_plan, to_dict
    from services.payroll_laws import PayrollRefused
    data = request.get_json(silent=True) or {}
    try:
        plan = create_plan(employee_id, data, by=data.get('created_by') or 'system', today=datetime.now().date())
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused)
    db.session.commit()
    return jsonify(to_dict(plan)), 201


@employees_bp.route('/advance-plans/<int:plan_id>/cancel', methods=['POST'])
@require_permission('employees.payroll')
def cancel_advance_plan(plan_id):
    from services.payroll_advances import cancel_plan, to_dict
    plan = EmployeeAdvancePlan.query.get_or_404(plan_id)
    cancel_plan(plan)
    db.session.commit()
    return jsonify(to_dict(plan))


# ── EMP-3: contracts and documents (services/employee_documents) ─────────────────

def _documents_action(action, status=200):
    from services.payroll_laws import PayrollRefused
    try:
        result = action()
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused)
    db.session.commit()
    return jsonify(result.to_dict()), status


@employees_bp.route('/employees/<int:employee_id>/contracts', methods=['GET'])
@require_permission('employees.view')
def list_employee_contracts(employee_id):
    Employee.query.get_or_404(employee_id)
    rows = EmployeeContract.query.filter_by(employee_id=employee_id).order_by(EmployeeContract.start_date.desc())
    return jsonify([row.to_dict() for row in rows])


@employees_bp.route('/employees/<int:employee_id>/contracts', methods=['POST'])
@require_permission('employees.edit')
def create_employee_contract(employee_id):
    from services.approval_policy import actor
    from services.employee_documents import save_contract
    data = request.get_json(silent=True) or {}
    return _documents_action(lambda: save_contract(employee_id, data, by=actor()), 201)


@employees_bp.route('/employee-contracts/<int:contract_id>', methods=['PUT'])
@require_permission('employees.edit')
def update_employee_contract(contract_id):
    from services.approval_policy import actor
    from services.employee_documents import save_contract
    contract = EmployeeContract.query.get_or_404(contract_id)
    data = request.get_json(silent=True) or {}
    return _documents_action(lambda: save_contract(contract.employee_id, data, by=actor(), contract=contract))


@employees_bp.route('/employee-document-types', methods=['GET'])
@require_permission('employees.view')
def list_employee_document_types():
    return jsonify([row.to_dict() for row in EmployeeDocumentType.query.order_by(EmployeeDocumentType.id)])


@employees_bp.route('/employee-document-types', methods=['POST'])
@require_permission('employees.edit')
def create_employee_document_type():
    from services.employee_documents import save_type
    data = request.get_json(silent=True) or {}
    return _documents_action(lambda: save_type(data), 201)


@employees_bp.route('/employee-document-types/<int:type_id>', methods=['PUT'])
@require_permission('employees.edit')
def update_employee_document_type(type_id):
    from services.employee_documents import save_type
    kind = EmployeeDocumentType.query.get_or_404(type_id)
    data = request.get_json(silent=True) or {}
    return _documents_action(lambda: save_type(data, kind))


@employees_bp.route('/employees/<int:employee_id>/documents', methods=['GET'])
@require_permission('employees.view')
def list_employee_documents(employee_id):
    Employee.query.get_or_404(employee_id)
    rows = EmployeeDocument.query.filter_by(employee_id=employee_id).order_by(EmployeeDocument.id.desc())
    return jsonify([row.to_dict() for row in rows])


@employees_bp.route('/employees/<int:employee_id>/documents', methods=['POST'])
@require_permission('employees.edit')
def create_employee_document(employee_id):
    from services.approval_policy import actor
    from services.employee_documents import save_document
    data = request.get_json(silent=True) or {}
    return _documents_action(lambda: save_document(employee_id, data, by=actor()), 201)


@employees_bp.route('/employee-documents/<int:document_id>', methods=['PUT'])
@require_permission('employees.edit')
def update_employee_document(document_id):
    from services.approval_policy import actor
    from services.employee_documents import save_document
    document = EmployeeDocument.query.get_or_404(document_id)
    data = request.get_json(silent=True) or {}
    return _documents_action(lambda: save_document(document.employee_id, data, by=actor(), document=document))


@employees_bp.route('/employee-documents/expiring', methods=['GET'])
@require_permission('employees.view')
def list_expiring_employee_documents():
    from services.employee_documents import expiring
    return jsonify(expiring(datetime.now().date()))


# ── EMP-4: leave (services/employee_leave) ──────────────────────────────────────

@employees_bp.route('/leave-types', methods=['GET'])
@require_permission('employees.view')
def list_leave_types():
    return jsonify([row.to_dict() for row in LeaveType.query.order_by(LeaveType.id)])


@employees_bp.route('/leave-types', methods=['POST'])
@require_permission('employees.payroll')
def create_leave_type():
    from services.employee_leave import save_type
    data = request.get_json(silent=True) or {}
    return _documents_action(lambda: save_type(data), 201)


@employees_bp.route('/leave-types/<int:type_id>', methods=['PUT'])
@require_permission('employees.payroll')
def update_leave_type(type_id):
    from services.employee_leave import save_type
    kind = LeaveType.query.get_or_404(type_id)
    data = request.get_json(silent=True) or {}
    return _documents_action(lambda: save_type(data, kind))


@employees_bp.route('/employees/<int:employee_id>/leaves', methods=['GET'])
@require_permission('employees.view')
def list_employee_leaves(employee_id):
    from services.employee_leave import balances
    employee = Employee.query.get_or_404(employee_id)
    rows = employee.leaves.order_by(EmployeeLeave.start_date.desc()).all()
    return jsonify({'leaves': [row.to_dict() for row in rows],
                    'balances': balances(employee, datetime.now().date())})


@employees_bp.route('/employees/<int:employee_id>/leaves', methods=['POST'])
@require_permission('employees.payroll')
def record_employee_leave(employee_id):
    from services.approval_policy import actor
    from services.employee_leave import record
    data = request.get_json(silent=True) or {}
    return _documents_action(lambda: record(employee_id, data, by=actor(), now=datetime.now()), 201)


def _leave_action(leave_id, action):
    from services.approval_policy import actor
    leave = EmployeeLeave.query.get_or_404(leave_id)

    def run():
        action(leave, by=actor(), now=datetime.now())
        return leave
    return _documents_action(run)


@employees_bp.route('/employee-leaves/<int:leave_id>/approve', methods=['POST'])
@require_permission('employees.payroll')
def approve_employee_leave(leave_id):
    from services.employee_leave import approve
    return _leave_action(leave_id, approve)


@employees_bp.route('/employee-leaves/<int:leave_id>/reject', methods=['POST'])
@require_permission('employees.payroll')
def reject_employee_leave(leave_id):
    from services.employee_leave import reject
    return _leave_action(leave_id, reject)


@employees_bp.route('/employee-leaves/<int:leave_id>/cancel', methods=['POST'])
@require_permission('employees.payroll')
def cancel_employee_leave(leave_id):
    from services.employee_leave import cancel
    return _leave_action(leave_id, cancel)


# ── EMP-5: end of service and its final settlement (services/employee_termination) ─

@employees_bp.route('/employees/<int:employee_id>/termination/preview', methods=['POST'])
@require_permission('employees.payroll')
def preview_employee_termination(employee_id):
    from services.employee_termination import preview
    from services.payroll_laws import PayrollRefused
    employee = Employee.query.get_or_404(employee_id)
    try:
        return jsonify(preview(employee, request.get_json(silent=True) or {}))
    except PayrollRefused as refused:
        return _payroll_refusal(refused)


@employees_bp.route('/employees/<int:employee_id>/termination', methods=['POST'])
@require_permission('employees.payroll')
def approve_employee_termination(employee_id):
    from services.approval_policy import actor
    from services.employee_termination import approve
    from services.payroll_laws import PayrollRefused
    try:
        termination, stopped = approve(employee_id, request.get_json(silent=True) or {}, by=actor(),
                                       now=datetime.now())
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused)
    db.session.commit()
    return jsonify({**termination.to_dict(), **stopped}), 201


@employees_bp.route('/employees/<int:employee_id>/terminations', methods=['GET'])
@require_permission('employees.payroll')
def list_employee_terminations(employee_id):
    employee = Employee.query.get_or_404(employee_id)
    return jsonify([t.to_dict() for t in employee.terminations.order_by(EmployeeTermination.id.desc())])


@employees_bp.route('/employee-terminations/<int:termination_id>/pay', methods=['POST'])
@require_permission('employees.payroll')
def pay_employee_termination(termination_id):
    from services.approval_policy import actor
    from services.employee_termination import pay
    termination = EmployeeTermination.query.get_or_404(termination_id)
    data = request.get_json(silent=True) or {}

    def run():
        pay(termination, data, by=actor(), now=datetime.now())
        return termination
    return _documents_action(run)


@employees_bp.route('/employee-terminations/<int:termination_id>/cancel', methods=['POST'])
@require_permission('employees.payroll')
def cancel_employee_termination(termination_id):
    from services.approval_policy import actor
    from services.employee_termination import cancel
    termination = EmployeeTermination.query.get_or_404(termination_id)

    def run():
        cancel(termination, by=actor(), now=datetime.now())
        return termination
    return _documents_action(run)


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

    # PAYROLL-1: a new entry is pending -- or approved with its accrual; «paid»
    # is the payment's (mark-paid), the voucher and its day too; the net is
    # the server's (services/payroll_laws).
    from services.payroll_laws import PayrollRefused, approve, net_of, refuse_bad_period
    requested = (data.get('status') or 'pending').strip().lower()
    try:
        refuse_bad_period(data.get('month', datetime.now().month), data.get('year', datetime.now().year))
    except PayrollRefused as refused:
        return jsonify({'error': refused.message}), 400
    if requested not in ('pending', 'approved'):
        return jsonify({'error': 'يُنشأ سجل الراتب معلّقًا أو معتمدًا؛ «مدفوع» يُضبط بزر الصرف الذي يكتب سنده'}), 400
    from services.payroll_run import open_run
    if open_run(int(data.get('month', datetime.now().month)), int(data.get('year', datetime.now().year))):
        return jsonify({'error': 'لهذا الشهر مسير رواتب: يُضاف الموظف من شاشة المسير'}), 409

    basic_salary = float(data.get('basic_salary', employee.salary or 0.0))
    allowances = float(data.get('allowances', 0.0))
    deductions = float(data.get('deductions', 0.0))

    payroll_entry = Payroll(
        employee_id=employee.id,
        month=int(data.get('month', datetime.now().month)),
        year=int(data.get('year', datetime.now().year)),
        basic_salary=basic_salary,
        allowances=allowances,
        deductions=deductions,
        net_salary=net_of(basic_salary, allowances, deductions),
        status='pending',
        notes=data.get('notes'),
        created_by=data.get('created_by'),
    )

    try:
        db.session.add(payroll_entry)
        db.session.flush()
        if requested == 'approved':
            try:
                approve(payroll_entry, by=data.get('created_by') or 'system')
            except PayrollRefused as refused:
                db.session.rollback()
                return jsonify({'error': refused.message}), 409
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

    # PAYROLL-1 (services/payroll_laws): amounts while pending alone; «paid» is
    # the payment's; approving is its accrual; cancelling reverses it.
    from services.payroll_laws import PayrollRefused, approve, cancel, net_of, refuse_amount_edit, refuse_bad_period
    try:
        refuse_amount_edit(payroll_entry, data)
        refuse_bad_period(data.get('month', payroll_entry.month), data.get('year', payroll_entry.year))
    except PayrollRefused as refused:
        return jsonify({'error': refused.message}), 409
    new_status = (data.get('status') or old_status).strip().lower()
    if new_status != old_status:
        if new_status == 'paid' or old_status == 'paid':
            return jsonify({'error': '«مدفوع» يُضبط بزر الصرف الذي يكتب سنده، ولا يُغيَّر الراتب المصروف'}), 409
        if new_status == 'pending':
            return jsonify({'error': 'لا يُعاد سجل معتمد إلى «معلّق»: يُلغى فيُعكس قيده، ويُنشأ سجل صحيح'}), 409
        if old_status == 'cancelled':
            return jsonify({'error': 'السجل الملغى لا يُعاد: أنشئ سجلًا جديدًا'}), 409

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
    # The net is the server's (PAYROLL-1, law 3); the voucher and the paid day
    # are the payment's (law 2) -- neither is taken from the form.
    payroll_entry.net_salary = net_of(payroll_entry.basic_salary, payroll_entry.allowances,
                                      payroll_entry.deductions)

    if 'notes' in data:
        payroll_entry.notes = data['notes']

    accrual_result = None
    by = data.get('created_by', 'system')
    try:
        if new_status == 'approved' and old_status == 'pending':
            approve(payroll_entry, by=by)                     # law 4
            accrual_result = {'accrual_posted': True}
        elif new_status == 'cancelled' and old_status != 'cancelled':
            cancel(payroll_entry, by=by, now=datetime.now())  # law 6
    except PayrollRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.message}), 409

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

    from services.payroll_laws import PayrollRefused, refuse_delete
    try:
        refuse_delete(payroll_entry)                           # PAYROLL-1, law 6
    except PayrollRefused as refused:
        return jsonify({'error': refused.message}), 409

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

    # Approving is its accrual (PAYROLL-1, law 4): one that cannot be written
    # stays pending -- it was left «approved» with none.
    from services.payroll_laws import PayrollRefused, approve
    approved_count = 0
    skipped = []
    for entry in entries:
        try:
            approve(entry, by=created_by)
            approved_count += 1
        except PayrollRefused as refused:
            skipped.append({'id': entry.id, 'reason': refused.message})

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

    # Cancelling an approved entry reverses its accrual (PAYROLL-1, law 6): it
    # was left posted, an expense for a salary that was not.
    from services.payroll_laws import PayrollRefused, cancel
    cancelled_count = 0
    skipped = []
    for entry in entries:
        try:
            cancel(entry, by=data.get('created_by', 'system'), now=datetime.now())
            cancelled_count += 1
        except PayrollRefused as refused:
            skipped.append({'id': entry.id, 'reason': refused.message})

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

    # ── حساب مصروف الرواتب: بدوره (5410 على الإنتاج، CHART-002) ──────────
    from accounting.mappings import AccountNotMapped
    from services.employee_accounts import SALARY_EXPENSE, ensure_payable_account, parent_account
    try:
        salary_expense_account = parent_account(SALARY_EXPENSE)
        # ── ذمم رواتب الموظف: حسابه المربوط، أو يُنشأ تحت أبيه المربوط ─────
        salary_payable_account_id = int(ensure_payable_account(employee, 'salary_payable', by=created_by).id)
    except AccountNotMapped as missing:
        return False, str(missing), None

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

    # Only an approved entry is paid, by its voucher, its accrual first
    # (PAYROLL-1, law 5) -- services/payroll_payment, the run's batch too.
    from services.payroll_laws import PayrollRefused
    from services.payroll_payment import pay
    try:
        pay(payroll_entry, payment_account_id=data.get('payment_account_id'), paid_date=paid_date,
            advance_deduction=data.get('advance_deduction_amount'), by=data.get('created_by', 'system'),
            now=datetime.now())
    except PayrollRefused as refused:
        db.session.rollback()
        return jsonify({'error': refused.message, 'message': refused.message}), 409
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء سند الصرف: {str(exc)}'}), 500

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

@employees_bp.route('/achievements/progress', methods=['GET'])
@require_auth
def my_goal_progress():
    """GET /api/achievements/progress -- «هدفي»: the signed-in employee's goals
    so far, as they will be paid (services/goal_achievements.goal_progress)."""
    from datetime import date as _date
    from services.goal_achievements import goal_progress
    current_user = getattr(g, 'current_user', None)
    employee_id = getattr(current_user, 'employee_id', None) if current_user else None
    employee = Employee.query.get(employee_id) if employee_id else None
    if employee is None or not employee.is_active:
        return jsonify({'goals': []}), 200
    return jsonify({'employee_id': employee.id, 'goals': goal_progress(employee, _date.today())}), 200


# ── EMP-PORTAL-1: the employee's portal, his own (services/employee_portal) ─────
# The employee is the session's, never an id from the request (§5 Law 5).

def _portal_employee():
    from services.employee_portal import mine
    return mine(getattr(g, 'current_user', None))


@employees_bp.route('/me/portal', methods=['GET'])
@require_auth
def my_portal():
    from services.employee_portal import portal
    employee = _portal_employee()
    if employee is None:
        return jsonify({'error': 'لا موظف مرتبط بهذا الحساب', 'code': 'no_employee'}), 404
    return jsonify(portal(employee, today=datetime.now().date()))


@employees_bp.route('/me/payslips/<int:payroll_id>', methods=['GET'])
@require_auth
def my_payslip(payroll_id):
    from services.employee_portal import payslip
    employee = _portal_employee()
    slip = payslip(employee, payroll_id) if employee is not None else None
    if slip is None:
        return jsonify({'error': 'غير موجود'}), 404
    return jsonify(slip)


@employees_bp.route('/me/leaves', methods=['POST'])
@require_auth
def request_my_leave():
    from services.approval_policy import actor
    from services.employee_portal import request_leave
    from services.payroll_laws import PayrollRefused
    employee = _portal_employee()
    if employee is None:
        return jsonify({'error': 'لا موظف مرتبط بهذا الحساب', 'code': 'no_employee'}), 404
    try:
        leave = request_leave(employee, request.get_json(silent=True) or {}, by=actor(), now=datetime.now())
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused)
    db.session.commit()
    return jsonify(leave.to_dict()), 201


@employees_bp.route('/me/leaves/<int:leave_id>/cancel', methods=['POST'])
@require_auth
def cancel_my_leave(leave_id):
    from services.approval_policy import actor
    from services.employee_portal import cancel_request
    from services.payroll_laws import PayrollRefused
    employee = _portal_employee()
    try:
        leave = cancel_request(employee, leave_id, by=actor(), now=datetime.now()) if employee else None
    except PayrollRefused as refused:
        db.session.rollback()
        return _payroll_refusal(refused, 409)
    if leave is None:
        return jsonify({'error': 'غير موجود'}), 404
    db.session.commit()
    return jsonify(leave.to_dict())


@employees_bp.route('/achievements/check-progress', methods=['POST'])
@require_auth
def check_goal_progress():
    """
    POST /api/achievements/check-progress -- what the home screen calls on
    every return: the signed-in employee's goals reached so far, recorded,
    and what they have not been shown.

    It counted a fourth way (the seller or the poster, the employee's own
    target beside the rule's threshold, actual × the rule's value): the
    goals are the one service's now (services/goal_achievements, ADR-058) --
    the one measure, the rule's threshold, what the rule pays.
    """
    from datetime import date as _date, datetime as _dt
    from services.goal_achievements import record_goal_achievements
    current_user = getattr(g, 'current_user', None)
    employee_id = getattr(current_user, 'employee_id', None) if current_user else None
    employee = Employee.query.get(employee_id) if employee_id else None
    if employee is None or not employee.is_active:
        return jsonify({'achievements': []}), 200
    try:
        record_goal_achievements(_date.today(), _dt.utcnow(), employee=employee)
        db.session.commit()
    except Exception as e:
        db.session.rollback()
        return jsonify({'achievements': [], 'error': str(e)}), 200
    unseen = (GoalAchievement.query.filter_by(employee_id=employee.id, seen_by_user=False)
              .order_by(GoalAchievement.achieved_at.desc()).all())
    return jsonify({'achievements': [a.to_dict() for a in unseen]}), 200


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
