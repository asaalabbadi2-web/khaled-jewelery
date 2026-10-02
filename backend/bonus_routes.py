"""
Routes لنظام المكافآت للموظفين
====================================

Endpoints:
- GET/POST /api/employees - إدارة الموظفين (النظام الأساسي)
- GET/PUT /api/bonus/employees - إدارة الموظفين (نظام المكافآت)
- GET/POST/PUT/DELETE /api/bonus-rules - إدارة قواعد المكافآت
- GET /api/invoice-types - الحصول على قائمة أنواع الفواتير المتاحة
- GET/POST /api/bonuses - إدارة المكافآت
- POST /api/bonuses/calculate - حساب المكافآت لفترة محددة
- POST /api/bonuses/<id>/approve - اعتماد مكافأة
- POST /api/bonuses/<id>/reject - رفض مكافأة
- POST /api/bonuses/<id>/pay - تسجيل دفع مكافأة
"""

from flask import Blueprint, request, jsonify, g
from services.record_ownership import refuse_unless_self
from models import db, Employee, BonusRule, EmployeeBonus, Voucher, VoucherAccountLine, Account, Office, SafeBox, GoalAchievement, Invoice, BonusInvoiceLink
from bonus_calculator import BonusCalculator
from datetime import datetime, date, timedelta
from auth_decorators import require_auth, require_permission, require_any_permission
from sqlalchemy import or_, func
from sqlalchemy.exc import IntegrityError
from werkzeug.exceptions import HTTPException
from services.live_balances import live_balances_by_account_ids

bonus_bp = Blueprint('bonuses', __name__)


# ══════════════════════════════════════════════════════════════════════════════
# Feature Flag Helper
# ══════════════════════════════════════════════════════════════════════════════

_FLAGGED_TYPES = {
    'attendance':  ('bonus_attendance_enabled',  'Attendance'),
    'performance': ('bonus_performance_enabled', 'Performance'),
}

def _check_bonus_type_flag(rule_type: str):
    """
    يتحقق من أن نوع المكافأة مُفعَّل في إعدادات النظام.

    Returns:
        None          — النوع مسموح (لا قيد عليه، أو مُفعَّل)
        (False, str)  — النوع محظور؛ الـ str هو رسالة الخطأ للـ route
    """
    if rule_type not in _FLAGGED_TYPES:
        return None

    setting_attr, display_name = _FLAGGED_TYPES[rule_type]
    try:
        from models import Settings
        from core.settings import _get_settings_singleton
        settings = _get_settings_singleton(create_if_missing=False)
        if settings and bool(getattr(settings, setting_attr, False)):
            return None  # مُفعَّل
    except Exception:
        pass  # في حالة الخطأ نُطبَّق الرفض الآمن (safe-deny)

    return False, (
        f'نوع المكافأة "{display_name}" غير مفعّل في إعدادات النظام. '
        f'فعّله من الإعدادات → المكافآت → {display_name} لتتمكن من استخدامه.'
    )


# ══════════════════════════════════════════════════════════════════════════════
# points_source Validation
# ══════════════════════════════════════════════════════════════════════════════

_VALID_POINTS_SOURCES = frozenset({'gold', 'cash'})


def _validate_points_source(points_source, rule_type: str, conditions):
    """
    يتحقق من صحة points_source وتوافر إعدادات المسار المختار.

    Returns:
        None  — صالح (أو لا شيء لفحصه)
        str   — رسالة الخطأ
    """
    if points_source is None:
        return None
    if rule_type != 'points_based':
        return 'points_source لا ينطبق إلا على القواعد من نوع points_based'
    if points_source not in _VALID_POINTS_SOURCES:
        return f'قيمة points_source غير صالحة: "{points_source}" — القيم المقبولة: gold, cash'
    # cash_amount_per_point is read from Settings.sales_race_settings (not from conditions)
    return None


# ══════════════════════════════════════════════════════════════════════════════
# دوال البحث المرنة عن حسابات المكافآت
# ──────────────────────────────────────────────────────────────────────────────
# تتجنب الأرقام الصلبة حتى تعمل في أي بيئة إنتاج بمخططات حسابات مختلفة.
# ترتيب البحث:
#   1. الإعدادات (bonus_expense_account / bonus_payable_account)
#   2. بحث بالاسم تحت الحساب الأب المناسب
#   3. قائمة أرقام احتياطية معروفة
# ══════════════════════════════════════════════════════════════════════════════

def _find_bonus_expense_account():  # Optional[Account]
    """حساب مصروف المكافآت (مدين عند الاعتماد)."""
    # 1) من الإعدادات إن وُجد
    try:
        from models import Settings
        s = Settings.query.first()
        cfg_num = getattr(s, 'bonus_expense_account_number', None) if s else None
        if cfg_num:
            acc = Account.query.filter_by(account_number=str(cfg_num)).first()
            if acc:
                return acc
    except Exception:
        pass

    # 2) بحث بالاسم: "مصروف" + "مكافأ" تحت أي حساب مصروفات (type=Expense)
    name_match = (
        Account.query
        .filter(
            Account.type.in_(['Expense', 'expense']),
            or_(
                Account.name.ilike('%مصروف%مكافأ%'),
                Account.name.ilike('%مكافأ%مصروف%'),
                Account.name.ilike('%مصروف%مكافئ%'),
                Account.name.ilike('%مكافئ%مصروف%'),
                Account.name.ilike('%bonus%expense%'),
                Account.name.ilike('%expense%bonus%'),
            ),
        )
        .order_by(Account.id)
        .first()
    )
    if name_match:
        return name_match

    # 3) أرقام احتياطية مرتبة حسب الأولوية
    # 5401 = المكافآت والعمولات (الحساب المعتمد في دليل الحسابات)
    for num in ('5401', '5450', '5451', '5452', '5455', '5491', '5492'):
        acc = Account.query.filter_by(account_number=num).first()
        if acc and acc.type in ('Expense', 'expense'):
            return acc

    return None


def _find_bonus_payable_account():  # Optional[Account]
    """حساب مكافآت مستحقة العام (دائن عند الاعتماد / مدين عند الصرف)."""
    # 1) من الإعدادات إن وُجد
    try:
        from models import Settings
        s = Settings.query.first()
        cfg_num = getattr(s, 'bonus_payable_account_number', None) if s else None
        if cfg_num:
            acc = Account.query.filter_by(account_number=str(cfg_num)).first()
            if acc:
                return acc
    except Exception:
        pass

    # 2) بحث بالاسم: "مكافأ" + "مستحق" تحت الخصوم
    name_match = (
        Account.query
        .filter(
            Account.type.in_(['Liability', 'liability']),
            or_(
                Account.name.ilike('%مكافأ%مستحق%'),
                Account.name.ilike('%مستحق%مكافأ%'),
                Account.name.ilike('%مكافئ%مستحق%'),
                Account.name.ilike('%مستحق%مكافئ%'),
                Account.name.ilike('%accrued%bonus%'),
                Account.name.ilike('%bonus%payable%'),
            ),
        )
        .order_by(Account.id)
        .first()
    )
    if name_match:
        return name_match

    # 3) أرقام احتياطية معروفة
    for num in ('2310', '2311', '2312'):
        acc = Account.query.filter_by(account_number=num).first()
        if acc:
            return acc

    return None


# ══════════════════════════════════════════════════════════════════════════════


# ==========================================
# 👥 إدارة الموظفين (Employees)
# ==========================================

@bonus_bp.route('/bonus/employees', methods=['GET'])
@require_any_permission('bonus.calculate', 'bonus.approve', 'bonus.pay')
@require_auth
def get_employees():
    """عرض جميع الموظفين"""
    try:
        include_bonuses = request.args.get('include_bonuses') == 'true'
        is_active = request.args.get('is_active')
        
        query = Employee.query
        
        if is_active is not None:
            query = query.filter_by(is_active=(is_active == 'true'))
        
        employees = query.order_by(Employee.employee_code).all()
        
        return jsonify({
            'success': True,
            'employees': [emp.to_dict(include_bonuses=include_bonuses) for emp in employees],
            'count': len(employees)
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonus/employees/<int:employee_id>', methods=['GET'])
@require_any_permission('bonus.calculate', 'bonus.approve', 'bonus.pay')
@require_auth
def get_employee(employee_id):
    """عرض موظف محدد"""
    try:
        employee = Employee.query.get_or_404(employee_id)
        
        include_bonuses = request.args.get('include_bonuses') == 'true'
        
        return jsonify({
            'success': True,
            'employee': employee.to_dict(include_bonuses=include_bonuses)
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 404


# ❌ تم حذف create_employee() من هنا لأنه مكرر
# ✅ استخدم الدالة الأصلية في routes.py التي تولّد employee_code تلقائياً
# وتنشئ حساب محاسبي تلقائياً للموظف


@bonus_bp.route('/bonus/employees/<int:employee_id>', methods=['PUT'])
@require_auth
@require_permission('employees.edit')
def update_employee(employee_id):
    """تحديث بيانات موظف"""
    try:
        employee = Employee.query.get_or_404(employee_id)
        data = request.get_json()
        
        # تحديث البيانات
        if 'full_name' in data:
            employee.name = data['full_name']  # استخدام name
        if 'position' in data:
            employee.job_title = data['position']  # استخدام job_title
        if 'department' in data:
            employee.department = data['department']
        if 'base_salary' in data:
            employee.salary = data['base_salary']  # استخدام salary
        if 'phone' in data:
            employee.phone = data['phone']
        if 'email' in data:
            employee.email = data['email']
        if 'national_id' in data:
            employee.national_id = data['national_id']
        if 'is_active' in data:
            employee.is_active = data['is_active']
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم تحديث بيانات الموظف بنجاح',
            'employee': employee.to_dict()
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 📋 إدارة قواعد المكافآت (Bonus Rules)
# ==========================================

@bonus_bp.route('/bonus-rules', methods=['GET'])
@require_permission('bonus_rule.view')
@require_auth
def get_bonus_rules():
    """عرض جميع قواعد المكافآت"""
    try:
        is_active = request.args.get('is_active')
        rule_type = request.args.get('rule_type')
        
        query = BonusRule.query
        
        if is_active is not None:
            query = query.filter_by(is_active=(is_active == 'true'))
        
        if rule_type:
            query = query.filter_by(rule_type=rule_type)
        
        rules = query.order_by(BonusRule.created_at.desc()).all()
        
        return jsonify({
            'success': True,
            'rules': [rule.to_dict() for rule in rules],
            'count': len(rules)
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonus-rules/<int:rule_id>', methods=['GET'])
@require_permission('bonus_rule.view')
@require_auth
def get_bonus_rule(rule_id):
    """عرض قاعدة مكافأة محددة"""
    try:
        rule = BonusRule.query.get_or_404(rule_id)
        
        return jsonify({
            'success': True,
            'rule': rule.to_dict()
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 404


@bonus_bp.route('/bonus-rules', methods=['POST'])
@require_auth
@require_any_permission('bonus_rule.create', 'bonus.calculate', 'bonus.approve')
def create_bonus_rule():
    """إنشاء قاعدة مكافأة جديدة"""
    try:
        data = request.get_json()
        
        # التحقق من البيانات المطلوبة
        required_fields = ['name', 'rule_type', 'bonus_type', 'bonus_value']
        for field in required_fields:
            if field not in data:
                return jsonify({
                    'success': False,
                    'message': f'الحقل {field} مطلوب'
                }), 400
        
        # Feature Flag: attendance و performance محظوران ما لم يُفعَّلا من الإعدادات
        flag_check = _check_bonus_type_flag(data.get('rule_type', ''))
        if flag_check is not None:
            _, msg = flag_check
            return jsonify({'success': False, 'message': msg, 'code': 'bonus_type_disabled'}), 422

        # points_source: يُقبل فقط على points_based مع اكتمال إعدادات المسار
        ps_error = _validate_points_source(
            data.get('points_source'),
            data.get('rule_type', ''),
            data.get('conditions'),
        )
        if ps_error:
            return jsonify({'success': False, 'message': ps_error, 'code': 'points_source_not_applicable'}), 422

        # تحويل التواريخ
        valid_from = None
        valid_to = None
        if data.get('valid_from'):
            valid_from = datetime.strptime(data['valid_from'], '%Y-%m-%d').date()
        if data.get('valid_to'):
            valid_to = datetime.strptime(data['valid_to'], '%Y-%m-%d').date()

        # 🔍 التحقق من صحة أنواع الفواتير المحددة
        valid_invoice_types = ['بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء', 'مرتجع شراء (مورد)']
        applicable_invoice_types = data.get('applicable_invoice_types')
        
        if applicable_invoice_types:
            invalid_types = [t for t in applicable_invoice_types if t not in valid_invoice_types]
            if invalid_types:
                return jsonify({
                    'success': False,
                    'message': f'أنواع فواتير غير صالحة: {", ".join(invalid_types)}',
                    'valid_types': valid_invoice_types
                }), 400
        
        # إنشاء القاعدة
        rule = BonusRule(
            name=data['name'],
            description=data.get('description'),
            rule_type=data['rule_type'],
            conditions=data.get('conditions'),
            bonus_type=data['bonus_type'],
            bonus_value=data['bonus_value'],
            min_bonus=data.get('min_bonus', 0.0),
            max_bonus=data.get('max_bonus'),
            target_departments=data.get('target_departments'),
            target_positions=data.get('target_positions'),
            target_employee_ids=data.get('target_employee_ids'),
            applicable_invoice_types=data.get('applicable_invoice_types'),
            points_source=data.get('points_source'),
            is_active=data.get('is_active', True),
            valid_from=valid_from,
            valid_to=valid_to,
            created_by=data.get('created_by')
        )
        
        db.session.add(rule)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم إنشاء قاعدة المكافأة بنجاح',
            'rule': rule.to_dict()
        }), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonus-rules/<int:rule_id>', methods=['PUT'])
@require_auth
@require_any_permission('bonus_rule.update', 'bonus.calculate', 'bonus.approve')
def update_bonus_rule(rule_id):
    """تحديث قاعدة مكافأة"""
    try:
        rule = BonusRule.query.get_or_404(rule_id)
        data = request.get_json()

        # Feature Flag: الـ rule_type الفعلي بعد التحديث يجب أن يكون مُفعَّلاً
        effective_type = data.get('rule_type', rule.rule_type)
        flag_check = _check_bonus_type_flag(effective_type)
        if flag_check is not None:
            _, msg = flag_check
            return jsonify({'success': False, 'message': msg, 'code': 'bonus_type_disabled'}), 422

        # points_source: إذا تم تغييره، تحقق من المسار الفعلي بعد التحديث
        if 'points_source' in data:
            effective_conditions = data.get('conditions', rule.conditions)
            ps_error = _validate_points_source(
                data['points_source'],
                effective_type,
                effective_conditions,
            )
            if ps_error:
                return jsonify({'success': False, 'message': ps_error, 'code': 'points_source_not_applicable'}), 422

        # 🔍 التحقق من صحة أنواع الفواتير إذا تم تحديثها
        valid_invoice_types = ['بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء', 'مرتجع شراء (مورد)']
        if 'applicable_invoice_types' in data and data['applicable_invoice_types']:
            invalid_types = [t for t in data['applicable_invoice_types'] if t not in valid_invoice_types]
            if invalid_types:
                return jsonify({
                    'success': False,
                    'message': f'أنواع فواتير غير صالحة: {", ".join(invalid_types)}',
                    'valid_types': valid_invoice_types
                }), 400
        
        # تحديث البيانات
        if 'name' in data:
            rule.name = data['name']
        if 'description' in data:
            rule.description = data['description']
        if 'rule_type' in data:
            rule.rule_type = data['rule_type']
        if 'conditions' in data:
            rule.conditions = data['conditions']
        if 'bonus_type' in data:
            rule.bonus_type = data['bonus_type']
        if 'bonus_value' in data:
            rule.bonus_value = data['bonus_value']
        if 'min_bonus' in data:
            rule.min_bonus = data['min_bonus']
        if 'max_bonus' in data:
            rule.max_bonus = data['max_bonus']
        if 'target_departments' in data:
            rule.target_departments = data['target_departments']
        if 'target_positions' in data:
            rule.target_positions = data['target_positions']
        if 'target_employee_ids' in data:  # 🆕
            rule.target_employee_ids = data['target_employee_ids']
        if 'applicable_invoice_types' in data:
            rule.applicable_invoice_types = data['applicable_invoice_types']
        if 'points_source' in data:
            rule.points_source = data['points_source'] or None
        if 'is_active' in data:
            rule.is_active = data['is_active']
        
        if data.get('valid_from'):
            rule.valid_from = datetime.strptime(data['valid_from'], '%Y-%m-%d').date()
        if data.get('valid_to'):
            rule.valid_to = datetime.strptime(data['valid_to'], '%Y-%m-%d').date()
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم تحديث قاعدة المكافأة بنجاح',
            'rule': rule.to_dict()
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonus-rules/<int:rule_id>', methods=['DELETE'])
@require_auth
@require_any_permission('bonus_rule.delete', 'bonus.calculate', 'bonus.approve')
def delete_bonus_rule(rule_id):
    """حذف قاعدة مكافأة"""
    try:
        rule = BonusRule.query.get_or_404(rule_id)
        
        db.session.delete(rule)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم حذف قاعدة المكافأة بنجاح'
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 💰 إدارة المكافآت (Bonuses)
# ==========================================

@bonus_bp.route('/bonuses', methods=['GET'])
@require_any_permission('bonus.calculate', 'bonus.approve', 'bonus.pay')
@require_auth
def get_bonuses():
    """عرض جميع المكافآت"""
    try:
        employee_id = request.args.get('employee_id', type=int)
        status = request.args.get('status')
        # date_from / date_to filter by created_at (inclusive, null-safe)
        date_from = request.args.get('date_from') or request.args.get('period_start')
        date_to   = request.args.get('date_to')   or request.args.get('period_end')

        query = EmployeeBonus.query

        if employee_id:
            query = query.filter_by(employee_id=employee_id)

        if status:
            query = query.filter_by(status=status)

        if date_from:
            try:
                df = datetime.strptime(date_from, '%Y-%m-%d')
                query = query.filter(EmployeeBonus.created_at >= df)
            except ValueError:
                pass

        if date_to:
            try:
                dt = datetime.strptime(date_to, '%Y-%m-%d') + timedelta(days=1)
                query = query.filter(EmployeeBonus.created_at < dt)
            except ValueError:
                pass
        
        bonuses = query.order_by(EmployeeBonus.created_at.desc()).all()
        
        total_amount = sum(b.amount for b in bonuses if b.status in ['approved', 'paid'])
        
        return jsonify({
            'success': True,
            'bonuses': [bonus.to_dict(include_employee=True, include_rule=True) for bonus in bonuses],
            'count': len(bonuses),
            'total_amount': total_amount
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonuses', methods=['POST'])
@require_auth
@require_any_permission('bonus.calculate', 'bonus.approve')
def create_bonus():
    """إنشاء مكافأة يدوية مباشرة (تُستخدم عند منح مكافأة الفائزين في السباق)"""
    try:
        data = request.get_json() or {}

        employee_id = data.get('employee_id')
        if not employee_id:
            return jsonify({'success': False, 'error': 'employee_id مطلوب'}), 400

        employee = Employee.query.get(employee_id)
        if not employee:
            return jsonify({'success': False, 'error': 'الموظف غير موجود'}), 404

        amount = data.get('amount')
        try:
            amount = float(amount)
        except (TypeError, ValueError):
            return jsonify({'success': False, 'error': 'قيمة المبلغ غير صالحة'}), 400

        if amount <= 0:
            return jsonify({'success': False, 'error': 'يجب أن يكون المبلغ أكبر من صفر'}), 400

        bonus_type = data.get('bonus_type', 'fixed')
        status = data.get('status', 'pending')
        if status not in ('pending', 'approved'):
            status = 'pending'

        try:
            period_start = datetime.strptime(data['period_start'], '%Y-%m-%d').date()
            period_end = datetime.strptime(data['period_end'], '%Y-%m-%d').date()
        except (KeyError, ValueError):
            return jsonify({'success': False, 'error': 'period_start و period_end مطلوبان بصيغة YYYY-MM-DD'}), 400

        if period_end < period_start:
            return jsonify({'success': False, 'error': 'تاريخ النهاية يجب أن يكون بعد تاريخ البداية'}), 400

        bonus_rule_id = data.get('bonus_rule_id')
        if bonus_rule_id:
            rule = BonusRule.query.get(bonus_rule_id)
            if not rule:
                bonus_rule_id = None

        bonus = EmployeeBonus(
            employee_id=employee_id,
            bonus_rule_id=bonus_rule_id,
            bonus_type=bonus_type,
            amount=round(amount, 2),
            period_start=period_start,
            period_end=period_end,
            calculation_data=data.get('calculation_data'),
            status=status,
            notes=data.get('notes'),
            created_at=datetime.now(),
            created_by=getattr(g, 'username', None),
        )

        if status == 'approved':
            bonus.approved_by = getattr(g, 'username', 'system')
            bonus.approved_at = datetime.now()

        db.session.add(bonus)
        db.session.commit()

        return jsonify({
            'success': True,
            'message': 'تم إنشاء المكافأة بنجاح',
            'bonus': bonus.to_dict(include_employee=True, include_rule=True),
        }), 201

    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'error': str(e)}), 500


@bonus_bp.route('/bonuses/<int:bonus_id>', methods=['GET'])
@require_any_permission('bonus.calculate', 'bonus.approve', 'bonus.pay')
@require_auth
def get_bonus(bonus_id):
    """عرض مكافأة محددة"""
    try:
        bonus = EmployeeBonus.query.get_or_404(bonus_id)
        
        return jsonify({
            'success': True,
            'bonus': bonus.to_dict(include_employee=True, include_rule=True)
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 404


@bonus_bp.route('/bonuses/<int:bonus_id>', methods=['PUT'])
@require_auth
@require_permission('bonus.calculate')
def update_bonus(bonus_id):
    """تعديل مكافأة معلقة قبل الاعتماد/الدفع"""
    try:
        bonus = EmployeeBonus.query.get_or_404(bonus_id)
        if bonus.status != 'pending':
            return jsonify({
                'success': False,
                'message': 'لا يمكن تعديل مكافأة غير معلقة'
            }), 400

        data = request.get_json() or {}

        # الحقول المسموح تعديلها قبل الاعتماد
        if 'amount' in data:
            amount = data.get('amount')
            try:
                bonus.amount = float(amount)
            except Exception:
                return jsonify({
                    'success': False,
                    'message': 'قيمة المبلغ غير صالحة'
                }), 400

        if 'notes' in data:
            bonus.notes = data.get('notes') or None

        if 'period_start' in data:
            try:
                bonus.period_start = datetime.strptime(data['period_start'], '%Y-%m-%d').date()
            except Exception:
                return jsonify({
                    'success': False,
                    'message': 'صيغة تاريخ البداية غير صحيحة'
                }), 400

        if 'period_end' in data:
            try:
                bonus.period_end = datetime.strptime(data['period_end'], '%Y-%m-%d').date()
            except Exception:
                return jsonify({
                    'success': False,
                    'message': 'صيغة تاريخ النهاية غير صحيحة'
                }), 400

        if bonus.period_start and bonus.period_end and bonus.period_end < bonus.period_start:
            return jsonify({
                'success': False,
                'message': 'تاريخ النهاية يجب أن يكون بعد تاريخ البداية'
            }), 400

        db.session.commit()

        return jsonify({
            'success': True,
            'message': 'تم تحديث المكافأة',
            'bonus': bonus.to_dict(include_employee=True, include_rule=True)
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonuses/calculate', methods=['POST'])
@require_permission('bonus.calculate')
@require_auth
def calculate_bonuses():
    """حساب المكافآت لفترة محددة"""
    try:
        data = request.get_json() or {}

        # 🔐 الصلاحيات:
        # - admin أو من لديه bonus.calculate: يستطيع حساب مكافآت أي موظف/الجميع
        # - غير ذلك: يسمح بحساب مكافآت نفسه فقط (إذا كان AppUser مرتبط بموظف)
        current_user = getattr(g, 'current_user', None)
        can_calculate_all = bool(
            current_user
            and (
                getattr(current_user, 'is_admin', False)
                or (hasattr(current_user, 'has_permission') and current_user.has_permission('bonus.calculate'))
            )
        )

        # ⚙️ دعم كل من period_start/period_end والحقول القديمة date_from/date_to القادمة من الواجهة
        period_start_str = data.get('period_start') or data.get('date_from')
        period_end_str = data.get('period_end') or data.get('date_to')

        if not period_start_str or not period_end_str:
            return jsonify({
                'success': False,
                'message': 'يجب تحديد تاريخ البداية والنهاية'
            }), 400

        try:
            period_start = datetime.strptime(period_start_str, '%Y-%m-%d').date()
            period_end = datetime.strptime(period_end_str, '%Y-%m-%d').date()
        except Exception:
            return jsonify({
                'success': False,
                'message': 'صيغة التاريخ غير صحيحة، استخدم YYYY-MM-DD'
            }), 400
        # auto_approve محذوف — الاعتماد يدوي دائماً، Scheduler هو مصدر الحقيقة
        # (نتجاهل الحقل إن أُرسل للتوافق الخلفي مع clients قديمة)

        # دعم employee_ids (list) و employee_id (single) القادم من Flutter
        employee_ids = data.get('employee_ids') if isinstance(data.get('employee_ids'), list) else None
        if employee_ids is None and isinstance(data.get('employee_id'), int):
            employee_ids = [data.get('employee_id')]

        # إن لم يكن لديه صلاحية عامة، احصر الحساب على موظفه فقط
        if not can_calculate_all:
            self_employee_id = getattr(current_user, 'employee_id', None) if current_user else None
            if not self_employee_id:
                return jsonify({
                    'success': False,
                    'message': 'ليس لديك صلاحية لحساب المكافآت',
                    'error': 'permission_denied',
                    'required_permission': 'bonus.calculate'
                }), 403
            employee_ids = [self_employee_id]

        rule_ids = data.get('rule_ids') if isinstance(data.get('rule_ids'), list) else None

        # حساب المكافآت — جميع النتائج pending، لا اعتماد تلقائي
        bonuses = BonusCalculator.calculate_all_bonuses_for_period(
            period_start=period_start,
            period_end=period_end,
            employee_ids=employee_ids,
            rule_ids=rule_ids,
        )

        # سجّل التشغيل اليدوي في bonus_calculation_log
        try:
            from models import BonusCalculationLog
            pending = [b for b in bonuses if b.status == 'pending']
            log = BonusCalculationLog(
                period_type='manual',
                period_start=period_start,
                period_end=period_end,
                bonus_count=len(pending),
                total_amount=round(sum(b.amount for b in pending), 4),
                status='success',
                message=f'تشغيل يدوي: {len(pending)} مكافأة بانتظار الاعتماد.',
            )
            db.session.add(log)
            db.session.commit()
        except Exception:
            pass  # السجل اختياري — لا يُعطّل الاستجابة
        
        total_amount = sum(b.amount for b in bonuses)
        
        return jsonify({
            'success': True,
            'message': f'تم حساب {len(bonuses)} مكافأة بنجاح',
            'bonuses': [bonus.to_dict(include_employee=True, include_rule=True) for bonus in bonuses],
            'count': len(bonuses),
            'total_amount': total_amount
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ══════════════════════════════════════════════════════════════════════════════
# خدمة الاعتماد الأساسية
# ══════════════════════════════════════════════════════════════════════════════
# نقطة الحقيقة الوحيدة لمنطق اعتماد مكافأة فردية.
# تُستدعى من approve_bonus (route) ومن bulk_approve_bonuses على حدٍّ سواء.
# كلٌّ من المستدعَيَين يحصل على نفس الحمايات:
#   - SELECT FOR UPDATE (منع double-approval)
#   - التحقق من تكرار السند (BAPP-{id})
#   - القيد المحاسبي الكامل (Dr مصروف / Cr مستحق)
#   - GoalAchievement للـ overlay الاحتفالية
# يُدير معاملته الخاصة (commit/rollback) حتى يمكن استدعاؤها في حلقة
# دون أن يُؤثر فشل عنصر واحد على بقية الدفعة.
# ══════════════════════════════════════════════════════════════════════════════

def _approve_single_bonus(bonus_id: int, approved_by: str) -> tuple:
    """
    يُنفّذ اعتماد مكافأة واحدة كاملاً مع قيدها المحاسبي.

    Returns:
        (True,  {'voucher_number': str, 'voucher_id': int, 'amount': float})
        (False, {'error': str, 'code': str, ...})
    """
    try:
        bonus = EmployeeBonus.query.with_for_update().get(bonus_id)
        if bonus is None:
            return False, {'error': 'المكافأة غير موجودة', 'code': 'not_found'}

        if bonus.status != 'pending':
            return False, {
                'error': f'لا يمكن اعتماد مكافأة بحالة "{bonus.status}"',
                'code': 'wrong_status',
            }

        bonus_expense_account = _find_bonus_expense_account()
        if not bonus_expense_account:
            return False, {
                'error': (
                    'لم يُعثر على حساب مصروف المكافآت. '
                    'يرجى إنشاء حساب مصروفات باسم يحتوي على "مصروف مكافأ" '
                    'أو تحديد رقمه في الإعدادات (bonus_expense_account_number).'
                ),
                'code': 'missing_expense_account',
            }

        employee = Employee.query.get(bonus.employee_id)
        emp_name = employee.name if employee else str(bonus.employee_id)

        bonuses_payable_account = None
        if employee:
            bonuses_payable_account = (
                Account.query
                .filter(
                    Account.account_number.like('2310%'),
                    Account.name.like(f'%{employee.name}%'),
                )
                .first()
            )
        if not bonuses_payable_account:
            bonuses_payable_account = _find_bonus_payable_account()
        if not bonuses_payable_account:
            return False, {
                'error': (
                    f'لم يُعثر على حساب مكافآت مستحقة للموظف ({emp_name}). '
                    'شغّل "إصلاح حسابات الموظف" لإنشاء حساب 2310xxx '
                    'أو حدد حساب 2310 في الإعدادات.'
                ),
                'code': 'missing_payable_account',
            }

        voucher_number = f"BAPP-{bonus.id}"
        existing_voucher = Voucher.query.filter_by(voucher_number=voucher_number).first()
        if existing_voucher:
            return False, {
                'error': f'سند الاعتماد موجود مسبقاً برقم {voucher_number}. لإعادة الاعتماد، يجب حذف السند الموجود أولاً.',
                'code': 'duplicate_voucher',
                'voucher_id': existing_voucher.id,
            }

        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type='adjustment',
            date=date.today(),
            description=f"اعتماد مكافأة {emp_name} - {bonus.bonus_type}",
            status='approved',
            created_by=approved_by,
            approved_by=approved_by,
            amount_cash=float(bonus.amount or 0.0),
            party_type='employee',
            employee_id=bonus.employee_id,
            party_name=emp_name,
            receiver_name=emp_name,
            reference_type='bonus',
            reference_id=bonus.id,
            reference_number=f'BONUS-{bonus.id}',
        )
        db.session.add(voucher)
        db.session.flush()

        db.session.add(VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=bonus_expense_account.id,
            line_type='debit',
            amount_type='cash',
            description=f"مصروف مكافأة {emp_name}",
            amount=bonus.amount,
        ))
        db.session.add(VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=bonuses_payable_account.id,
            line_type='credit',
            amount_type='cash',
            description=f"استحقاق مكافأة {emp_name}",
            amount=bonus.amount,
        ))

        # Born approved, so its entry is posted with it; a failure fails the
        # approval (V0, owner 1 Oct 2026) -- never an approved voucher without one.
        from routes import post_entry_of_approved_voucher
        post_entry_of_approved_voucher(voucher, posted_by=approved_by)

        bonus.approve(approved_by)
        bonus.payment_reference = voucher_number
        _create_achievement_for_bonus(bonus, employee)

        try:
            db.session.commit()
        except IntegrityError:
            db.session.rollback()
            ev = Voucher.query.filter_by(voucher_number=voucher_number).first()
            if ev:
                return False, {
                    'error': f'سند الاعتماد موجود مسبقاً (race condition): {voucher_number}',
                    'code': 'duplicate_voucher',
                    'voucher_id': ev.id,
                }
            raise

        return True, {
            'voucher_number': voucher_number,
            'voucher_id': voucher.id,
            'amount': bonus.amount,
        }

    except Exception as exc:
        db.session.rollback()
        import traceback
        traceback.print_exc()
        return False, {'error': str(exc), 'code': 'exception'}


@bonus_bp.route('/bonuses/<int:bonus_id>/approve', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def approve_bonus(bonus_id):
    """
    اعتماد مكافأة مع إنشاء قيد محاسبي لإثبات المصروف والالتزام.

    القيد المحاسبي:
    من ح/ مصروف مكافآت (5401)    مدين
      إلى ح/ مكافآت مستحقة (2310)  دائن
    سند: BAPP-{bonus_id}
    """
    data = request.get_json(silent=True) or {}
    approved_by = data.get('approved_by') or getattr(g, 'username', None) or 'system'

    ok, payload = _approve_single_bonus(bonus_id, approved_by)

    if not ok:
        code = payload.get('code', 'error')
        if code in ('wrong_status', 'duplicate_voucher'):
            http_status = 409
        elif code == 'not_found':
            http_status = 404
        else:
            http_status = 400
        return jsonify({'success': False, 'message': payload['error'], **payload}), http_status

    bonus = EmployeeBonus.query.get(bonus_id)
    return jsonify({
        'success': True,
        'message': 'تم اعتماد المكافأة وإثبات المصروف بنجاح',
        'bonus': bonus.to_dict(include_employee=True, include_rule=True) if bonus else None,
        'voucher': payload,
    }), 200


def _create_achievement_for_bonus(bonus: EmployeeBonus, employee):
    """
    ينشئ سجل GoalAchievement مرتبط بالمكافأة المعتمدة.
    يُستدعى تلقائياً من approve_bonus() قبل commit().
    
    - يبني اسم الهدف من نوع المكافأة أو من القاعدة إن وُجدت
    - يضع الـ metrics من calculation_data إن كانت موجودة
    - لا يرفع exception — الإنجاز اختياري ولا يعطّل الاعتماد
    """
    try:
        # لا تُنشئ إنجازاً مكرراً لنفس المكافأة
        existing = GoalAchievement.query.filter_by(bonus_id=bonus.id).first()
        if existing:
            return

        rule = bonus.rule
        goal_name = (rule.name if rule else None) or _bonus_type_label(bonus.bonus_type)
        goal_description = rule.description if rule else None

        # استخرج الـ metrics من calculation_data
        calc = bonus.calculation_data or {}
        metrics = {}
        for key in ('points', 'invoices', 'invoice_count', 'rank',
                    'sales_weight', 'total_sales', 'percentage'):
            val = calc.get(key)
            if val is not None:
                # normalize key names for the Flutter widget
                display_key = 'invoices' if key == 'invoice_count' else key
                metrics[display_key] = val

        achievement = GoalAchievement(
            employee_id=bonus.employee_id,
            bonus_rule_id=bonus.bonus_rule_id,
            bonus_id=bonus.id,
            goal_name=goal_name,
            goal_description=goal_description,
            bonus_amount=bonus.amount,
            metrics=metrics,
            achieved_at=bonus.approved_at or bonus.created_at,
        )
        db.session.add(achievement)
    except Exception as exc:
        # Non-fatal: log and continue
        import traceback
        traceback.print_exc()


def _bonus_type_label(bonus_type: str) -> str:
    labels = {
        'sales_target': 'هدف المبيعات',
        'attendance': 'مكافأة الحضور',
        'performance': 'مكافأة الأداء',
        'fixed': 'مكافأة ثابتة',
        'profit_based': 'مكافأة الأرباح',
        'goal_achieved': 'تحقيق هدف',
        'custom': 'مكافأة خاصة',
    }
    return labels.get(bonus_type, 'مكافأة معتمدة')


@bonus_bp.route('/bonuses/bulk/approve', methods=['POST'])
@bonus_bp.route('/bonuses/bulk-approve', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def bulk_approve_bonuses():
    """
    اعتماد عدة مكافآت معلقة دفعة واحدة.

    كل مكافأة تُعتمد عبر _approve_single_bonus في معاملة مستقلة:
    فشل مكافأة واحدة لا يُلغي بقية الدفعة.
    كل اعتماد ناجح يُنشئ قيده المحاسبي (BAPP-{id}) تماماً كما يفعل
    approve_bonus الفردي.

    Response:
        approved: [{id, voucher_number, amount}]   — نجحت
        failed:   [{id, error, code}]               — فشلت (حالة خاطئة / حسابات مفقودة / ...)
    """
    data = request.get_json(silent=True) or {}
    ids = data.get('ids') or data.get('bonus_ids') or []
    approved_by = data.get('approved_by') or getattr(g, 'username', None) or 'system'

    if not isinstance(ids, list) or not ids:
        return jsonify({'success': False, 'message': 'قائمة المعرفات مطلوبة'}), 400

    approved = []
    failed = []

    for bonus_id in ids:
        ok, payload = _approve_single_bonus(int(bonus_id), approved_by)
        if ok:
            approved.append({
                'id': bonus_id,
                'voucher_number': payload['voucher_number'],
                'amount': payload['amount'],
            })
        else:
            failed.append({'id': bonus_id, **payload})

    return jsonify({
        'success': True,
        'approved': approved,
        'failed': failed,
        'approved_count': len(approved),
        'failed_count': len(failed),
        # حقول توافق خلفي مع المستدعين القدامى
        'approved_ids': [a['id'] for a in approved],
        'skipped': [f for f in failed if f.get('code') == 'wrong_status'],
        'count': len(approved),
    }), 200


@bonus_bp.route('/bonuses/<int:bonus_id>/reject', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def reject_bonus(bonus_id):
    """رفض مكافأة"""
    try:
        bonus = EmployeeBonus.query.get_or_404(bonus_id)
        data = request.get_json(silent=True) or {}
        
        if bonus.status != 'pending':
            return jsonify({
                'success': False,
                'message': 'لا يمكن رفض مكافأة غير معلقة'
            }), 400
        
        reason      = data.get('reason')
        rejected_by = data.get('rejected_by') or data.get('approved_by', 'system')
        try:
            bonus.reject(reason=reason, rejected_by=rejected_by)
        except ValueError as ve:
            return jsonify({'success': False, 'message': str(ve)}), 409

        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم رفض المكافأة',
            'bonus': bonus.to_dict(include_employee=True, include_rule=True)
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonuses/bulk/reject', methods=['POST'])
@bonus_bp.route('/bonuses/bulk-reject', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def bulk_reject_bonuses():
    """رفض عدة مكافآت معلقة دفعة واحدة"""
    try:
        data = request.get_json(silent=True) or {}
        ids = data.get('ids') or data.get('bonus_ids') or []
        reason = data.get('reason')

        if not isinstance(ids, list) or not ids:
            return jsonify({'success': False, 'message': 'قائمة المعرفات مطلوبة'}), 400

        bonuses = EmployeeBonus.query.filter(EmployeeBonus.id.in_(ids)).all()
        rejected, skipped = [], []

        for bonus in bonuses:
            if bonus.status == 'pending':
                bonus.reject(reason)
                rejected.append(bonus.id)
            else:
                skipped.append({'id': bonus.id, 'status': bonus.status})

        db.session.commit()

        return jsonify({
            'success': True,
            'rejected_ids': rejected,
            'skipped': skipped,
            'count': len(rejected)
        }), 200

    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@bonus_bp.route('/bonuses/bulk-delete', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def bulk_delete_bonuses():
    """حذف نهائي لمكافآت معلقة أو مرفوضة (لا يُطبَّق على معتمدة أو مدفوعة)"""
    try:
        data = request.get_json(silent=True) or {}
        ids = data.get('ids') or data.get('bonus_ids') or []

        if not isinstance(ids, list) or not ids:
            return jsonify({'success': False, 'message': 'قائمة المعرفات مطلوبة'}), 400

        bonuses = EmployeeBonus.query.filter(EmployeeBonus.id.in_(ids)).all()
        deleted, skipped = [], []

        for bonus in bonuses:
            if bonus.status in ('pending', 'rejected'):
                BonusInvoiceLink.query.filter_by(bonus_id=bonus.id).delete()
                db.session.delete(bonus)
                deleted.append(bonus.id)
            else:
                skipped.append({'id': bonus.id, 'status': bonus.status})

        db.session.commit()
        return jsonify({'success': True, 'deleted_ids': deleted, 'skipped': skipped, 'count': len(deleted)}), 200

    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@bonus_bp.route('/bonuses/<int:bonus_id>/pay', methods=['POST'])
@require_auth
@require_permission('bonus.pay')
def pay_bonus(bonus_id):
    """
    دفع مكافأة من خزينة معينة مع إنشاء سند صرف وتحديث رصيد الخزينة
    
    القيد المحاسبي:
    من ح/ مكافآت مستحقة (2310)    مدين
      إلى ح/ حساب الخزينة           دائن
    
    Body Parameters:
        - safe_box_id: معرف الخزينة (مفضل)
        - office_id: معرف الخزينة (قديم - للتوافق فقط)
        - payment_method: طريقة الدفع ('cash', 'transfer', 'add_to_payroll')
        - paid_date: تاريخ الدفع (اختياري)
        - created_by: اسم المستخدم (اختياري)
    """
    try:
        # قفل السطر أثناء الدفع لمنع double-payment
        bonus = EmployeeBonus.query.with_for_update().get_or_404(bonus_id)
        data = request.get_json(silent=True) or {}

        if bonus.status != 'approved':
            return jsonify({
                'success': False,
                'message': f'لا يمكن دفع مكافأة بحالة "{bonus.status}"'
            }), 409
        
        payment_method = data.get('payment_method', 'cash')
        paid_date = datetime.strptime(data.get('paid_date'), '%Y-%m-%d').date() if data.get('paid_date') else date.today()
        created_by = data.get('created_by', 'system')
        
        # الحصول على معلومات الموظف
        employee = Employee.query.get(bonus.employee_id)
        if not employee:
            return jsonify({'success': False, 'message': 'الموظف غير موجود'}), 404
        
        # إذا كان الدفع عن طريق إضافة للراتب، نسجل فقط ولا ننشئ سند
        if payment_method == 'add_to_payroll':
            # تحقق مزدوج من الحالة (يمنع double-pay عبر add_to_payroll)
            if bonus.status == 'paid':
                return jsonify({
                    'success': False,
                    'message': 'المكافأة مدفوعة مسبقاً'
                }), 409
            bonus.mark_as_paid('سيتم الدفع مع الراتب', paid_by=created_by)
            bonus.notes = f"{bonus.notes or ''}\nسيتم إضافة المكافأة لراتب الشهر القادم"
            db.session.commit()
            
            return jsonify({
                'success': True,
                'message': 'تم تسجيل المكافأة لإضافتها للراتب',
                'bonus': bonus.to_dict(include_employee=True, include_rule=True)
            }), 200
        
        # التحقق من الخزينة (SafeBox مفضل) مع الحفاظ على office_id للتوافق
        safe_box_id = data.get('safe_box_id')
        office_id = data.get('office_id')

        safe_box = None
        office = None
        treasury_account = None
        treasury_name = None
        treasury_balance_cash = None

        if safe_box_id:
            safe_box = SafeBox.query.get(safe_box_id)
            if not safe_box:
                return jsonify({'success': False, 'message': 'الخزينة غير موجودة'}), 404

            if not safe_box.is_active:
                return jsonify({'success': False, 'message': 'الخزينة غير نشطة'}), 400

            # حماية: مكافآت = حركة نقدية/بنكية (لا تسمح بخزائن الذهب)
            if safe_box.safe_type not in ('cash', 'bank'):
                return jsonify({
                    'success': False,
                    'message': 'لا يمكن صرف المكافأة إلا من خزينة نقدية أو بنكية',
                    'safe_box_id': safe_box.id,
                    'safe_type': safe_box.safe_type,
                }), 400

            # توافق بسيط بين نوع الخزينة وطريقة الدفع
            if payment_method == 'cash' and safe_box.safe_type != 'cash':
                return jsonify({'success': False, 'message': 'طريقة الدفع نقدي تتطلب خزينة نقدية'}), 400
            if payment_method == 'transfer' and safe_box.safe_type != 'bank':
                return jsonify({'success': False, 'message': 'طريقة الدفع تحويل تتطلب خزينة بنكية'}), 400

            treasury_account = safe_box.account
            if not treasury_account:
                return jsonify({'success': False, 'message': f'الخزينة {safe_box.name} غير مرتبطة بحساب محاسبي'}), 400

            treasury_name = safe_box.name
            # قراءة الرصيد الحي من القيود (لا من الكائن المحلي القديم)
            # استخدام الدالة المُستوردة بالفعل في أعلى الملف
            _lb = live_balances_by_account_ids
            _live = _lb([treasury_account.id]).get(int(treasury_account.id)) or {}
            treasury_balance_cash = round(float(_live.get('cash') or 0.0), 2)

        else:
            if not office_id:
                return jsonify({'success': False, 'message': 'يجب تحديد الخزينة'}), 400

            office = Office.query.get(office_id)
            if not office:
                return jsonify({'success': False, 'message': 'الخزينة غير موجودة'}), 404

            if not office.active:
                return jsonify({'success': False, 'message': 'الخزينة غير نشطة'}), 400

            treasury_name = office.name
            treasury_balance_cash = float(getattr(office, 'balance_cash', 0.0) or 0.0)

        # التحقق من رصيد الخزينة (يُقرأ من القيود مباشرة لتفادي stale data)
        if treasury_balance_cash < bonus.amount:
            return jsonify({
                'success': False,
                'message': f'رصيد الخزينة غير كافٍ. الرصيد الحالي: {treasury_balance_cash} ريال، المطلوب: {bonus.amount} ريال'
            }), 400
        
        # حساب الذمة المدينة عند الصرف: نفس الحساب الذي جرى القيد عليه عند الاعتماد
        # الأولوية: 2310xxx (مكافآت مستحقة) الخاص بالموظف → 2310 العام كاحتياط
        bonuses_payable_account = None
        if employee:
            bonuses_payable_account = (
                Account.query
                .filter(
                    Account.account_number.like('2310%'),
                    Account.name.like(f'%{employee.name}%'),
                )
                .first()
            )
        if not bonuses_payable_account:
            bonuses_payable_account = _find_bonus_payable_account()
        if not bonuses_payable_account:
            return jsonify({
                'success': False,
                'message': 'لم يُعثر على حساب ذمة المكافآت للموظف'
            }), 400
        
        # تحديد حساب الخزينة والتحقق من ملاءمته
        if safe_box is None:
            # الحصول على حساب الخزينة من account_category (مسار قديم)
            if not office.account_category:
                return jsonify({'success': False, 'message': f'الخزينة {office.name} غير مرتبطة بحساب محاسبي'}), 400
            treasury_account = office.account_category

        # حماية: لا تسمح بحسابات وزن/مخزون (يجب أن يكون حساب نقدي/بنكي)
        if getattr(treasury_account, 'tracks_weight', False) or getattr(treasury_account, 'transaction_type', 'both') not in ('cash', 'both'):
            return jsonify({
                'success': False,
                'message': (
                    f'الخزينة {treasury_name} مرتبطة بحساب غير مناسب للصرف. '
                    'يرجى ربط الخزينة بحساب نقدي/بنكي (مثل الصندوق/البنوك) ثم إعادة المحاولة.'
                ),
                'account_id': getattr(treasury_account, 'id', None),
                'account_number': getattr(treasury_account, 'account_number', None),
                'account_name': getattr(treasury_account, 'name', None),
                'office_id': getattr(office, 'id', None),
                'safe_box_id': getattr(safe_box, 'id', None),
            }), 400
        
        # إنشاء سند صرف — الرقم مرتبط بمعرف المكافأة لضمان الفردية
        # BPAY-{bonus_id} كمعرف أساسي بدلاً من التسلسل الزمني القابل للتكرار
        voucher_number = f"BPAY-{bonus.id}"

        # التحقق من عدم وجود سند بنفس الرقم (حماية مضاعفة من double-pay)
        existing_voucher = Voucher.query.filter_by(voucher_number=voucher_number).first()
        if existing_voucher:
            return jsonify({
                'success': False,
                'message': f'سند الصرف موجود مسبقاً برقم {voucher_number}. المكافأة قد صُرفت سابقاً.',
                'voucher_id': existing_voucher.id
            }), 409
        
        # إنشاء السند
        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type='payment',
            date=paid_date,
            description=f"صرف مكافأة {employee.name} - {bonus.bonus_type} من {treasury_name}",
            status='approved',
            created_by=created_by,
            approved_by=created_by,
            amount_cash=float(bonus.amount or 0.0),
            # الطرف: الموظف المستفيد
            party_type='employee',
            employee_id=employee.id,
            party_name=employee.name,
            receiver_name=employee.name,
            # مرجع المكافأة
            reference_type='bonus',
            reference_id=bonus.id,
            reference_number=f'BONUS-{bonus.id}',
        )
        db.session.add(voucher)
        db.session.flush()
        
        # السطر المدين: مكافآت مستحقة (تسديد الالتزام)
        debit_line = VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=bonuses_payable_account.id,
            line_type='debit',
            amount_type='cash',
            description=f"تسديد مكافأة {employee.name}",
            amount=bonus.amount,
        )
        db.session.add(debit_line)
        
        # السطر الدائن: حساب الخزينة (خروج أموال)
        credit_line = VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=treasury_account.id,
            line_type='credit',
            amount_type='cash',
            description=f"صرف مكافأة من {treasury_name}",
            amount=bonus.amount,
        )
        db.session.add(credit_line)
        
        # خصم المبلغ من رصيد الخزينة
        if safe_box is not None:
            treasury_account.update_balance(cash_amount=-bonus.amount)
            # توثيق مصدر الدفع بدون تغيير مخطط قاعدة البيانات
            safe_type_ar = {'cash': 'نقدي', 'bank': 'بنكي', 'gold': 'ذهبي', 'check': 'شيكات'}.get(safe_box.safe_type, safe_box.safe_type)
            bonus.notes = f"{(bonus.notes or '').strip()}\nتم الدفع من خزينة: {safe_box.name} ({safe_type_ar})".strip()
        else:
            office.balance_cash -= bonus.amount

        # تحديث المكافأة وربطها بالخزينة (office فقط لمسار التوافق)
        bonus.mark_as_paid(voucher_number, paid_by=created_by)
        if safe_box is None:
            bonus.office_id = office_id
        
        # إنشاء القيد المحاسبي من السند — يُرحّل تسديد الالتزام وخروج الأموال إلى الـ GL.
        # السند يولد معتمدًا فيُرحَّل قيده معه، وفشل القيد يُفشل الدفع كله (V0،
        # قرار المالك 1 أكتوبر 2026) — لا سند معتمد بلا قيد.
        from routes import post_entry_of_approved_voucher
        post_entry_of_approved_voucher(voucher, posted_by=created_by)

        try:
            db.session.commit()
        except IntegrityError:
            db.session.rollback()
            existing_voucher = Voucher.query.filter_by(voucher_number=voucher_number).first()
            if existing_voucher:
                return jsonify({
                    'success': False,
                    'message': f'سند الصرف موجود مسبقاً برقم {voucher_number}. لإعادة الدفع، يجب حذف السند الموجود أولاً.',
                    'voucher_id': existing_voucher.id
                }), 409
            raise

        safe_box_payload = None
        office_payload = None
        treasury_balance_after = None

        if safe_box is not None:
            # Canonical source of truth: journal-derived balances.
            live_treasury = live_balances_by_account_ids([treasury_account.id]).get(int(treasury_account.id))
            live_treasury = live_treasury if isinstance(live_treasury, dict) else {'cash': 0.0}
            treasury_balance_after = round(float(live_treasury.get('cash') or 0.0), 2)

            safe_box_payload = safe_box.to_dict(include_account=True, include_balance=False)
            live_sb = live_balances_by_account_ids([safe_box.account_id]).get(int(safe_box.account_id))
            live_sb = live_sb if isinstance(live_sb, dict) else {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
            balance = {
                'cash': round(float(live_sb.get('cash') or 0.0), 2),
            }
            account = getattr(safe_box, 'account', None)
            if bool(getattr(account, 'tracks_weight', False)):
                w18 = float(live_sb.get('18k') or 0.0)
                w21 = float(live_sb.get('21k') or 0.0)
                w22 = float(live_sb.get('22k') or 0.0)
                w24 = float(live_sb.get('24k') or 0.0)
                balance['weight'] = {
                    '18k': round(w18, 3),
                    '21k': round(w21, 3),
                    '22k': round(w22, 3),
                    '24k': round(w24, 3),
                    'total': round(w18 + w21 + w22 + w24, 3),
                }
            safe_box_payload['balance'] = balance
        else:
            # The office's balance is its supplier's in the ledger (BALANCE-001 B3).
            treasury_balance_after = None
            if getattr(office, 'supplier', None) is not None:
                from services.party_live_balances import compute_live_supplier_balances
                treasury_balance_after = float((compute_live_supplier_balances([office.supplier]).get(
                    int(office.supplier.id)) or {}).get('cash') or 0.0)
            office_payload = {'id': office.id, 'name': office.name, 'balance_after': treasury_balance_after}
        
        return jsonify({
            'success': True,
            'message': f'تم صرف المكافأة بنجاح من {treasury_name}',
            'bonus': bonus.to_dict(include_employee=True, include_rule=True),
            'voucher': {
                'id': voucher.id,
                'voucher_number': voucher_number,
                'amount': bonus.amount
            },
            'treasury': {
                'kind': 'safe_box' if safe_box is not None else 'office',
                'id': safe_box.id if safe_box is not None else office.id,
                'name': treasury_name,
                'balance_after': float(treasury_balance_after or 0.0)
            },
            **({'safe_box': safe_box_payload} if safe_box is not None else {'office': office_payload})
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonus/employees/<int:employee_id>/bonuses-summary', methods=['GET'])
@require_any_permission('bonus.calculate', 'bonus.approve', 'bonus.pay')
@require_auth
def get_employee_bonuses_summary(employee_id):
    """الحصول على ملخص مكافآت موظف"""
    try:
        start_date = request.args.get('start_date')
        end_date = request.args.get('end_date')
        
        start = datetime.strptime(start_date, '%Y-%m-%d').date() if start_date else None
        end = datetime.strptime(end_date, '%Y-%m-%d').date() if end_date else None
        
        summary = BonusCalculator.get_employee_bonuses_summary(
            employee_id=employee_id,
            start_date=start,
            end_date=end
        )
        
        return jsonify({
            'success': True,
            **summary
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 🕐 إدارة مجدول المكافآت التلقائي
# ==========================================

@bonus_bp.route('/scheduler/status', methods=['GET'])
@require_permission('system.settings')
@require_auth
def get_scheduler_status():
    """الحصول على حالة مجدول المكافآت"""
    try:
        from bonus_scheduler import get_bonus_scheduler
        from flask import current_app
        
        scheduler = get_bonus_scheduler(current_app._get_current_object())
        
        return jsonify({
            'success': True,
            'is_running': scheduler.is_running,
            'message': 'المجدول يعمل' if scheduler.is_running else 'المجدول متوقف'
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/scheduler/start', methods=['POST'])
@require_auth
@require_permission('system.settings')
def start_scheduler():
    """بدء مجدول المكافآت"""
    try:
        from bonus_scheduler import get_bonus_scheduler
        from flask import current_app
        
        scheduler = get_bonus_scheduler(current_app._get_current_object())
        scheduler.start()
        
        return jsonify({
            'success': True,
            'message': 'تم بدء مجدول المكافآت بنجاح'
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/scheduler/stop', methods=['POST'])
@require_auth
@require_permission('system.settings')
def stop_scheduler():
    """إيقاف مجدول المكافآت"""
    try:
        from bonus_scheduler import get_bonus_scheduler
        from flask import current_app
        
        scheduler = get_bonus_scheduler(current_app._get_current_object())
        scheduler.stop()
        
        return jsonify({
            'success': True,
            'message': 'تم إيقاف مجدول المكافآت'
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/scheduler/run-now', methods=['POST'])
@require_auth
@require_permission('bonus.calculate')
def run_scheduler_now():
    """تشغيل مهمة من مجدول المكافآت فوراً"""
    try:
        from bonus_scheduler import get_bonus_scheduler
        from flask import current_app
        
        data = request.get_json() or {}
        task_type = data.get('task_type', 'daily')  # daily, weekly, monthly, check
        
        if task_type not in ['daily', 'weekly', 'monthly', 'check']:
            return jsonify({
                'success': False,
                'message': 'نوع المهمة غير صحيح. الخيارات: daily, weekly, monthly, check'
            }), 400
        
        scheduler = get_bonus_scheduler(current_app._get_current_object())
        scheduler.run_now(task_type)
        
        task_names = {
            'daily': 'المكافآت اليومية',
            'weekly': 'المكافآت الأسبوعية',
            'monthly': 'المكافآت الشهرية',
            'check': 'فحص المكافآت المعلقة'
        }
        
        return jsonify({
            'success': True,
            'message': f'تم تشغيل مهمة {task_names[task_type]} بنجاح'
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/invoices/<int:invoice_id>/assign-employee', methods=['POST'])
@require_auth
@require_permission('invoices.edit_others')
def assign_employee_to_invoice(invoice_id):
    """تعيين موظف لفاتورة موجودة"""
    try:
        from models import Invoice, Employee
        
        invoice = Invoice.query.get_or_404(invoice_id)
        data = request.get_json()
        
        employee_id = data.get('employee_id')
        if not employee_id:
            return jsonify({
                'success': False,
                'message': 'employee_id is required'
            }), 400
        
        employee = Employee.query.get(employee_id)
        if not employee:
            return jsonify({
                'success': False,
                'message': f'Employee with ID {employee_id} not found'
            }), 404
        
        invoice.employee_id = employee_id
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': f'تم تعيين الموظف {employee.name} للفاتورة رقم {invoice_id}',
            'invoice': invoice.to_dict()
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 📋 قائمة أنواع الفواتير المتاحة
# ==========================================

@bonus_bp.route('/invoice-types', methods=['GET'])
@require_auth
def get_invoice_types():
    """
    الحصول على قائمة أنواع الفواتير المتاحة في النظام
    لاستخدامها في تحديد applicable_invoice_types عند إنشاء قواعد المكافآت
    """
    invoice_types = [
        {'value': 'بيع', 'label': 'بيع', 'description': 'فاتورة بيع للعميل'},
        {'value': 'شراء من عميل', 'label': 'شراء من عميل', 'description': 'شراء ذهب من عميل'},
        {'value': 'مرتجع بيع', 'label': 'مرتجع بيع', 'description': 'إرجاع بضاعة من عميل'},
        {'value': 'مرتجع شراء', 'label': 'مرتجع شراء', 'description': 'إرجاع بضاعة لعميل'},
        {'value': 'شراء', 'label': 'شراء', 'description': 'شراء ذهب من مورد'},
        {'value': 'مرتجع شراء (مورد)', 'label': 'مرتجع شراء (مورد)', 'description': 'إرجاع بضاعة لمورد'}
    ]
    
    return jsonify({
        'success': True,
        'invoice_types': invoice_types
    }), 200


# ==========================================
# 📊 تقرير المستحقات (Payables Report)
# ==========================================

@bonus_bp.route('/bonuses/payables-report', methods=['GET'])
@require_any_permission('bonus.calculate', 'bonus.approve', 'bonus.pay')
@require_auth
def get_bonuses_payables_report():
    """
    تقرير المستحقات غير المدفوعة (approved)
    
    يوضح إجمالي المكافآت المستحقة لكل موظف والتي لم تُدفع بعد
    هذا المبلغ يجب أن يطابق رصيد حساب "مكافآت مستحقة" (215)
    """
    try:
        # إحصائيات حسب الحالة
        stats_by_status = db.session.query(
            EmployeeBonus.status,
            func.count(EmployeeBonus.id).label('count'),
            func.sum(EmployeeBonus.amount).label('total')
        ).group_by(EmployeeBonus.status).all()
        
        status_summary = {}
        for status, count, total in stats_by_status:
            status_summary[status] = {
                'count': count,
                'total': float(total or 0)
            }
        
        # المستحقات غير المدفوعة لكل موظف (approved فقط)
        unpaid_by_employee = db.session.query(
            Employee.id,
            Employee.name,
            Employee.employee_code,
            func.count(EmployeeBonus.id).label('count'),
            func.sum(EmployeeBonus.amount).label('total')
        ).join(
            EmployeeBonus, Employee.id == EmployeeBonus.employee_id
        ).filter(
            EmployeeBonus.status == 'approved'
        ).group_by(
            Employee.id, Employee.name, Employee.employee_code
        ).all()
        
        employees_payables = []
        total_unpaid = 0
        
        for emp_id, emp_name, emp_code, count, total in unpaid_by_employee:
            employees_payables.append({
                'employee_id': emp_id,
                'employee_name': emp_name,
                'employee_code': emp_code,
                'bonuses_count': count,
                'total_amount': float(total)
            })
            total_unpaid += float(total)
        
        # التحقق من رصيد حساب مكافآت مستحقة (215)
        bonuses_payable_account = Account.query.filter_by(account_number='215').first()
        account_balance = None
        balance_matches = None
        
        if bonuses_payable_account:
            # حساب الرصيد من VoucherAccountLine
            debit_sum = db.session.query(func.sum(VoucherAccountLine.amount)).filter(
                VoucherAccountLine.account_id == bonuses_payable_account.id,
                VoucherAccountLine.line_type == 'debit'
            ).scalar() or 0
            
            credit_sum = db.session.query(func.sum(VoucherAccountLine.amount)).filter(
                VoucherAccountLine.account_id == bonuses_payable_account.id,
                VoucherAccountLine.line_type == 'credit'
            ).scalar() or 0
            
            # رصيد حساب الالتزام = الدائن - المدين
            account_balance = float(credit_sum - debit_sum)
            balance_matches = abs(account_balance - total_unpaid) < 0.01
        
        return jsonify({
            'success': True,
            'report_date': date.today().isoformat(),
            'status_summary': status_summary,
            'employees_payables': employees_payables,
            'total_unpaid': total_unpaid,
            'account_info': {
                'account_number': '2310',
                'account_name': 'مكافآت مستحقة',
                'balance': account_balance,
                'balance_matches': balance_matches
            } if bonuses_payable_account else None
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 📊 تقرير المكافآت الشامل
# ==========================================

@bonus_bp.route('/bonuses/report', methods=['GET'])
@require_any_permission('bonus.calculate', 'bonus.approve', 'bonus.pay')
@require_auth
def bonuses_report():
    """
    تقرير شامل لجميع المكافآت
    
    Query Parameters:
        - employee_id: تصفية حسب موظف معين
        - status: تصفية حسب الحالة (pending, approved, rejected, paid)
        - from_date: من تاريخ
        - to_date: إلى تاريخ
        - office_id: تصفية حسب الخزينة
    """
    try:
        # الحصول على المعاملات
        employee_id = request.args.get('employee_id', type=int)
        status = request.args.get('status')
        from_date_str = request.args.get('from_date')
        to_date_str = request.args.get('to_date')
        office_id = request.args.get('office_id', type=int)
        
        # بناء الاستعلام
        query = EmployeeBonus.query
        
        if employee_id:
            query = query.filter_by(employee_id=employee_id)
        
        if status:
            query = query.filter_by(status=status)
        
        if from_date_str:
            from_date = datetime.strptime(from_date_str, '%Y-%m-%d').date()
            query = query.filter(EmployeeBonus.created_at >= from_date)
        
        if to_date_str:
            to_date = datetime.strptime(to_date_str, '%Y-%m-%d').date()
            query = query.filter(EmployeeBonus.created_at <= to_date)
        
        if office_id:
            query = query.filter_by(office_id=office_id)
        
        bonuses = query.order_by(EmployeeBonus.created_at.desc()).all()
        
        # إحصائيات حسب الحالة
        status_stats = {}
        for s in ['pending', 'approved', 'rejected', 'paid']:
            count = EmployeeBonus.query.filter_by(status=s).count()
            total = db.session.query(func.sum(EmployeeBonus.amount)).filter_by(status=s).scalar() or 0
            status_stats[s] = {
                'count': count,
                'total': float(total)
            }
        
        # إحصائيات حسب الموظف
        employee_stats = db.session.query(
            Employee.id,
            Employee.name,
            Employee.employee_code,
            func.count(EmployeeBonus.id).label('total_bonuses'),
            func.sum(EmployeeBonus.amount).label('total_amount'),
            func.sum(func.case([(EmployeeBonus.status == 'paid', EmployeeBonus.amount)], else_=0)).label('paid_amount'),
            func.sum(func.case([(EmployeeBonus.status == 'approved', EmployeeBonus.amount)], else_=0)).label('approved_amount')
        ).join(
            EmployeeBonus, Employee.id == EmployeeBonus.employee_id
        ).group_by(
            Employee.id, Employee.name, Employee.employee_code
        ).all()
        
        employees_summary = []
        for emp_id, emp_name, emp_code, total_bonuses, total_amt, paid_amt, approved_amt in employee_stats:
            employees_summary.append({
                'employee_id': emp_id,
                'employee_name': emp_name,
                'employee_code': emp_code,
                'total_bonuses': total_bonuses,
                'total_amount': float(total_amt or 0),
                'paid_amount': float(paid_amt or 0),
                'approved_not_paid': float(approved_amt or 0),
                'pending_amount': float((total_amt or 0) - (paid_amt or 0) - (approved_amt or 0))
            })
        
        # إحصائيات حسب الخزائن
        office_stats = db.session.query(
            Office.id,
            Office.name,
            Office.office_code,
            func.count(EmployeeBonus.id).label('payments_count'),
            func.sum(EmployeeBonus.amount).label('total_paid')
        ).join(
            EmployeeBonus, Office.id == EmployeeBonus.office_id
        ).filter(
            EmployeeBonus.status == 'paid'
        ).group_by(
            Office.id, Office.name, Office.office_code
        ).all()
        
        offices_summary = []
        for off_id, off_name, off_code, payments_count, total_paid in office_stats:
            offices_summary.append({
                'office_id': off_id,
                'office_name': off_name,
                'office_code': off_code,
                'payments_count': payments_count,
                'total_paid': float(total_paid or 0)
            })
        
        return jsonify({
            'success': True,
            'report_date': datetime.now().isoformat(),
            'filters': {
                'employee_id': employee_id,
                'status': status,
                'from_date': from_date_str,
                'to_date': to_date_str,
                'office_id': office_id
            },
            'status_summary': status_stats,
            'employees_summary': employees_summary,
            'offices_summary': offices_summary,
            'bonuses': [b.to_dict(include_employee=True, include_rule=True) for b in bonuses],
            'total_bonuses': len(bonuses),
            'grand_total': sum(b.amount for b in bonuses)
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonuses/employee/<int:employee_id>/summary', methods=['GET'])
@require_any_permission('bonus.calculate', 'bonus.approve', 'bonus.pay')
@require_auth
def employee_bonus_summary(employee_id):
    """
    ملخص مكافآت موظف معين
    """
    try:
        employee = Employee.query.get_or_404(employee_id)
        
        # جميع المكافآت
        bonuses = EmployeeBonus.query.filter_by(employee_id=employee_id).order_by(EmployeeBonus.created_at.desc()).all()
        
        # الإحصائيات
        total_amount = sum(b.amount for b in bonuses)
        paid_amount = sum(b.amount for b in bonuses if b.status == 'paid')
        approved_not_paid = sum(b.amount for b in bonuses if b.status == 'approved')
        pending_amount = sum(b.amount for b in bonuses if b.status == 'pending')
        rejected_amount = sum(b.amount for b in bonuses if b.status == 'rejected')
        
        # حسب النوع
        by_type = {}
        for bonus in bonuses:
            if bonus.bonus_type not in by_type:
                by_type[bonus.bonus_type] = {
                    'count': 0,
                    'total': 0,
                    'paid': 0,
                    'pending': 0
                }
            by_type[bonus.bonus_type]['count'] += 1
            by_type[bonus.bonus_type]['total'] += bonus.amount
            if bonus.status == 'paid':
                by_type[bonus.bonus_type]['paid'] += bonus.amount
            elif bonus.status == 'pending' or bonus.status == 'approved':
                by_type[bonus.bonus_type]['pending'] += bonus.amount
        
        return jsonify({
            'success': True,
            'employee': employee.to_dict(),
            'summary': {
                'total_bonuses': len(bonuses),
                'total_amount': total_amount,
                'paid_amount': paid_amount,
                'approved_not_paid': approved_not_paid,
                'pending_amount': pending_amount,
                'rejected_amount': rejected_amount,
                'by_type': by_type
            },
            'bonuses': [b.to_dict(include_rule=True) for b in bonuses]
        }), 200

    except HTTPException:
        raise
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 🎯 أهداف موظف شخصية — فحص وإشعار الاحتفالية
# ==========================================

def _build_period_key(period_name: str, today: date) -> str:
    """يبني مفتاح الفترة بصيغة موحّدة: daily-YYYY-MM-DD | weekly-YYYY-W## | monthly-YYYY-MM."""
    if period_name == 'daily':
        return f"daily-{today.isoformat()}"
    elif period_name == 'weekly':
        iso = today.isocalendar()
        return f"weekly-{iso[0]}-W{iso[1]:02d}"
    else:  # monthly
        return f"monthly-{today.year}-{today.month:02d}"


def _get_period_goal_target(emp: Employee, period_name: str, metric: str):
    """يعيد قيمة الهدف للفترة والمقياس المحدد، أو None إذا لم يُعيَّن."""
    if period_name == 'daily':
        mapping = {'weight': emp.goal_weight_daily, 'points': emp.goal_points_daily, 'invoices': emp.goal_invoices_daily}
    elif period_name == 'weekly':
        mapping = {'weight': emp.goal_weight_weekly, 'points': emp.goal_points_weekly, 'invoices': emp.goal_invoices_weekly}
    else:
        mapping = {'weight': emp.goal_weight_monthly, 'points': emp.goal_points_monthly, 'invoices': emp.goal_invoices_monthly}
    return mapping.get(metric)


def _calc_employee_period_performance(employee_id: int, metric: str, start: date, end: date) -> float:
    """يحسب الأداء الفعلي للموظف في الفترة المحددة من الفواتير المرحّلة."""
    from sqlalchemy import func as sqlfunc
    # نحسب فقط فواتير البيع المرحّلة (posted)
    from sqlalchemy import or_ as _or
    from datetime import datetime as _datetime, timedelta as _timedelta
    # للنقاط: نشمل "شراء من عميل" تطابقاً مع لوحة المبيعات
    inv_types = ['بيع', 'sell', 'sale', 'شراء من عميل'] if metric == 'points' else ['بيع', 'sell', 'sale']
    # تحويل date إلى datetime لضمان شمول فواتير كامل اليوم الأخير
    start_dt = _datetime.combine(start, _datetime.min.time()) if not isinstance(start, _datetime) else start
    end_dt = _datetime.combine(end + _timedelta(days=1), _datetime.min.time()) if not isinstance(end, _datetime) else end
    base_q = (
        Invoice.query
        .filter(
            Invoice.employee_id == employee_id,
            Invoice.invoice_type.in_(inv_types),
            _or(Invoice.is_posted.is_(True), Invoice.status == 'posted'),
            Invoice.date >= start_dt,
            Invoice.date < end_dt,
        )
    )
    if metric == 'invoices':
        return float(base_q.count())
    elif metric == 'points':
        result = base_q.with_entities(sqlfunc.sum(Invoice.profit_gold)).scalar()
        raw = float(result or 0)
        # نقاط = profit_gold × points_per_gram (نفس حساب لوحة المبيعات)
        try:
            from models import Settings
            s = Settings.query.first()
            import json as _json
            _src = s and getattr(s, 'sales_race_settings', None)
            _ppg = 10.0
            if _src:
                _p = _json.loads(_src) if isinstance(_src, str) else _src
                _ppg = max(0.001, float(_p.get('points_per_gram') or 10.0))
        except Exception:
            _ppg = 10.0
        return raw * _ppg
    else:  # weight (default)
        result = base_q.with_entities(sqlfunc.sum(Invoice.total_weight)).scalar()
        return float(result or 0)


def _calc_goal_bonus(emp: Employee, period_name: str, actual: float = 0.0) -> float:
    """يحسب مبلغ المكافأة بناءً على نوع المكافأة (ثابت أو قاعدة)."""
    reward_type = getattr(emp, f'goal_reward_type_{period_name}') or 'fixed'
    if reward_type == 'rule':
        rule_id = getattr(emp, f'goal_bonus_rule_id_{period_name}')
        if rule_id:
            rule = BonusRule.query.get(rule_id)
            if rule:
                bonus_type = (getattr(rule, 'bonus_type', None) or 'fixed').strip().lower()
                bonus_val  = float(getattr(rule, 'bonus_value', None) or 0.0)
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
                return amount
    # fixed أو fallback
    return float(getattr(emp, f'goal_bonus_{period_name}') or 0)


@bonus_bp.route('/employees/<int:employee_id>/goals', methods=['PUT'])
@require_permission('employees.bonuses')
@require_auth
def update_employee_goals(employee_id):
    """
    PUT /api/employees/{id}/goals
    تحديث إعدادات الأهداف الشخصية للموظف.
    يتطلب فقط تسجيل الدخول (require_auth).
    """
    try:
        employee = Employee.query.get_or_404(employee_id)
        data = request.get_json() or {}

        _float_fields = [
            'goal_weight_monthly', 'goal_weight_weekly', 'goal_weight_daily',
            'goal_points_monthly', 'goal_points_weekly', 'goal_points_daily',
            'goal_bonus_monthly',  'goal_bonus_weekly',  'goal_bonus_daily',
        ]
        _int_fields = [
            'goal_invoices_monthly', 'goal_invoices_weekly', 'goal_invoices_daily',
            'goal_bonus_rule_id_monthly', 'goal_bonus_rule_id_weekly', 'goal_bonus_rule_id_daily',
        ]
        _bool_fields = ['goal_monthly_enabled', 'goal_weekly_enabled', 'goal_daily_enabled']
        _str_fields  = [
            'goal_metric', 'goal_name',
            'goal_reward_type_monthly', 'goal_reward_type_weekly', 'goal_reward_type_daily',
        ]

        for f in _float_fields:
            if f in data:
                setattr(employee, f, float(data[f]) if data[f] is not None else None)
        for f in _int_fields:
            if f in data:
                setattr(employee, f, int(data[f]) if data[f] is not None else None)
        for f in _bool_fields:
            if f in data:
                setattr(employee, f, bool(data[f]))
        for f in _str_fields:
            if f in data:
                setattr(employee, f, data[f])

        db.session.commit()
        return jsonify({'employee': employee.to_dict(include_details=True)}), 200

    except HTTPException:
        raise
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


@bonus_bp.route('/employees/<int:employee_id>/goal-check', methods=['POST'])
@require_auth
def check_employee_personal_goals(employee_id):
    """
    POST /api/employees/{id}/goal-check
    يتحقق من تحقيق الأهداف الشخصية للموظف للفترات المفعّلة.
    ينشئ سجل GoalAchievement إن لم يكن موجوداً لهذه الفترة.
    يُعيد الإنجازات غير المشاهدة.
    """
    emp = Employee.query.get_or_404(employee_id)
    refused = refuse_unless_self(emp.id)
    if refused:
        return refused
    today = date.today()

    week_start  = today - timedelta(days=today.weekday())  # الاثنين
    month_start = today.replace(day=1)

    metric = emp.goal_metric or 'weight'

    periods = [
        ('daily',   bool(emp.goal_daily_enabled),   today,        today,      'اليومي'),
        ('weekly',  bool(emp.goal_weekly_enabled),  week_start,   today,      'الأسبوعي'),
        ('monthly', bool(emp.goal_monthly_enabled), month_start,  today,      'الشهري'),
    ]

    new_achievements = []

    for period_name, enabled, p_start, p_end, period_label in periods:
        if not enabled:
            continue

        target = _get_period_goal_target(emp, period_name, metric)
        if target is None or (isinstance(target, (int, float)) and target <= 0):
            continue

        period_key = _build_period_key(period_name, today)

        # البحث أولاً بالعمود المخصص، ثم داخل metrics للتوافق مع السجلات القديمة
        existing = GoalAchievement.query.filter_by(
            employee_id=emp.id,
            period_key=period_key,
        ).first()
        if not existing:
            for a in GoalAchievement.query.filter_by(employee_id=emp.id).all():
                m = a.metrics if isinstance(a.metrics, dict) else {}
                if m.get('period_key') == period_key:
                    existing = a
                    break

        if existing:
            # أُنجز من قبل — أعده إذا لم يُشاهَد بعد
            if not existing.seen_by_user:
                new_achievements.append(existing.to_dict())
            continue

        # قياس الأداء الفعلي
        actual = _calc_employee_period_performance(emp.id, metric, p_start, p_end)
        if actual < float(target):
            continue

        # تحقّق الهدف!
        bonus_amount = _calc_goal_bonus(emp, period_name, actual)
        achievement = GoalAchievement(
            employee_id=emp.id,
            goal_name=emp.goal_name or f'هدف {period_label}',
            goal_description=f'تحقيق هدف {period_label}: {actual:.1f} / {float(target):.1f}',
            bonus_amount=bonus_amount,
            currency='SAR',
            metrics={
                'period': period_name,
                'actual': round(actual, 2),
                'target': round(float(target), 2),
                'metric': metric,
            },
            period_key=period_key,
            goal_period=period_name,
            achieved_at=datetime.utcnow(),
        )
        db.session.add(achievement)
        try:
            db.session.flush()
            new_achievements.append(achievement.to_dict())
        except Exception:
            db.session.rollback()
            continue

    try:
        db.session.commit()
    except Exception:
        db.session.rollback()

    return jsonify({'achievements': new_achievements}), 200


@bonus_bp.route('/goal-achievements/<int:achievement_id>/mark-seen', methods=['POST'])
@require_auth
def mark_goal_achievement_seen(achievement_id):
    """
    POST /api/goal-achievements/{id}/mark-seen
    يضع علامة "شوهد" على إنجاز هدف شخصي.
    """
    ach = GoalAchievement.query.get_or_404(achievement_id)
    refused = refuse_unless_self(ach.employee_id)
    if refused:
        return refused
    ach.mark_seen()
    try:
        db.session.commit()
    except Exception:
        db.session.rollback()
        return jsonify({'success': False, 'message': 'فشل الحفظ'}), 500
    return jsonify({'success': True}), 200


# ══════════════════════════════════════════════════════════════════════════════
# Phase 2 — Reversal & Clawback Candidates
# ══════════════════════════════════════════════════════════════════════════════

@bonus_bp.route('/bonuses/<int:bonus_id>/reverse', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def reverse_bonus(bonus_id):
    """
    POST /api/bonuses/{id}/reverse
    عكس مكافأة معتمدة: ينشئ سند BREV-{id} (Dr 2310 / Cr 5401) ويُحوِّل الحالة إلى reversed.

    Body (JSON, اختياري):
        reversed_by  str   — المستخدم المنفِّذ (default: g.username)
        reason       str   — سبب العكس

    Responses:
        200 — نجاح: {success, message, bonus, voucher}
        404 — المكافأة غير موجودة
        409 — سند BREV موجود مسبقاً (idempotency guard)
        422 — مكافأة مدفوعة (paid_bonus_reversal_policy_not_configured)
        400 — حالة خاطئة أو بيانات ناقصة
        500 — خطأ غير متوقع
    """
    from bonus_reversal_service import BonusReversalService
    from models import BonusClawbackCandidate

    data = request.get_json(silent=True) or {}
    reversed_by = (
        data.get('reversed_by')
        or getattr(g, 'username', None)
        or 'system'
    )
    reason = data.get('reason') or None

    ok, payload = BonusReversalService.reverse(bonus_id, reversed_by, reason)

    if not ok:
        code = payload.get('code', 'error')
        if code == 'not_found':
            return jsonify({'success': False, **payload}), 404
        if code == 'paid_bonus_reversal_policy_not_configured':
            return jsonify({'success': False, **payload}), 422
        if code == 'duplicate_voucher':
            return jsonify({'success': False, **payload}), 409
        return jsonify({'success': False, **payload}), 400

    bonus = EmployeeBonus.query.get(bonus_id)

    # إغلاق أي مرشحات clawback مفتوحة مرتبطة بهذه المكافأة
    try:
        open_candidates = (
            BonusClawbackCandidate.query
            .filter_by(bonus_id=bonus_id, status='open')
            .all()
        )
        for c in open_candidates:
            c.status = 'actioned'
        if open_candidates:
            db.session.commit()
    except Exception as _cl_err:
        print(f'[reverse_bonus] ⚠️ فشل إغلاق clawback candidates: {_cl_err}')

    return jsonify({
        'success': True,
        'message': f'تم عكس المكافأة #{bonus_id} بنجاح',
        'bonus': bonus.to_dict(include_employee=True),
        'voucher': payload,
    }), 200


@bonus_bp.route('/bonuses/clawback-candidates', methods=['GET'])
@require_auth
@require_permission('bonus.approve')
def list_clawback_candidates():
    """
    GET /api/bonuses/clawback-candidates
    يُعيد قائمة مرشحات clawback (إخبارية).

    Query params:
        status   str   — open | dismissed | actioned | all (default: open)
        page     int   — رقم الصفحة (default: 1)
        per_page int   — عدد السجلات (default: 50)
    """
    from models import BonusClawbackCandidate

    status_filter = request.args.get('status', 'open')
    page = int(request.args.get('page', 1))
    per_page = min(int(request.args.get('per_page', 50)), 200)

    q = BonusClawbackCandidate.query
    if status_filter != 'all':
        q = q.filter_by(status=status_filter)

    q = q.order_by(BonusClawbackCandidate.created_at.desc())
    pagination = q.paginate(page=page, per_page=per_page, error_out=False)

    return jsonify({
        'success': True,
        'candidates': [c.to_dict() for c in pagination.items],
        'total': pagination.total,
        'page': page,
        'per_page': per_page,
        'pages': pagination.pages,
    }), 200


@bonus_bp.route('/bonuses/clawback-candidates/<int:candidate_id>/dismiss', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def dismiss_clawback_candidate(candidate_id):
    """
    POST /api/bonuses/clawback-candidates/{id}/dismiss
    يرفض مرشح clawback دون اتخاذ أي إجراء مالي.

    Body (JSON, اختياري):
        dismissed_by  str   — المستخدم (default: g.username)
    """
    from models import BonusClawbackCandidate

    candidate = BonusClawbackCandidate.query.get_or_404(candidate_id)

    data = request.get_json(silent=True) or {}
    dismissed_by = (
        data.get('dismissed_by')
        or getattr(g, 'username', None)
        or 'system'
    )

    try:
        candidate.dismiss(dismissed_by)
        db.session.commit()
    except ValueError as ve:
        return jsonify({'success': False, 'message': str(ve)}), 409
    except Exception:
        db.session.rollback()
        return jsonify({'success': False, 'message': 'فشل الحفظ'}), 500

    return jsonify({
        'success': True,
        'message': 'تم رفض المرشح',
        'candidate': candidate.to_dict(),
    }), 200


# ══════════════════════════════════════════════════════════════════════════════
# Pending Summary & Calculation Logs — Dashboard Support
# ══════════════════════════════════════════════════════════════════════════════

@bonus_bp.route('/bonuses/pending-summary', methods=['GET'])
@require_auth
@require_any_permission('bonus.approve', 'bonus.calculate', 'bonus_rule.view')
def bonuses_pending_summary():
    """
    GET /api/bonuses/pending-summary

    ملخص المكافآت pending لفترة معينة — يدعم شاشة "مكافآت الشهر".

    Query params:
        period_start  YYYY-MM-DD  (اختياري — الشهر الحالي افتراضياً)
        period_end    YYYY-MM-DD  (اختياري)
    """
    import calendar as _cal

    today = date.today()
    start_str = request.args.get('period_start')
    end_str = request.args.get('period_end')

    try:
        period_start = datetime.strptime(start_str, '%Y-%m-%d').date() if start_str else today.replace(day=1)
        period_end = (
            datetime.strptime(end_str, '%Y-%m-%d').date()
            if end_str
            else today.replace(day=_cal.monthrange(today.year, today.month)[1])
        )
    except ValueError:
        return jsonify({'success': False, 'message': 'صيغة التاريخ غير صحيحة، استخدم YYYY-MM-DD'}), 400

    base_q = EmployeeBonus.query.filter(
        EmployeeBonus.period_start >= period_start,
        EmployeeBonus.period_end <= period_end,
    )

    pending   = base_q.filter_by(status='pending').all()
    approved  = base_q.filter_by(status='approved').all()
    paid      = base_q.filter_by(status='paid').all()

    return jsonify({
        'success': True,
        'period': {
            'start': period_start.isoformat(),
            'end':   period_end.isoformat(),
        },
        'pending': {
            'count':  len(pending),
            'total':  round(sum(b.amount for b in pending), 4),
        },
        'approved': {
            'count':  len(approved),
            'total':  round(sum(b.amount for b in approved), 4),
        },
        'paid': {
            'count':  len(paid),
            'total':  round(sum(b.amount for b in paid), 4),
        },
    }), 200


@bonus_bp.route('/bonuses/calculation-logs', methods=['GET'])
@require_auth
@require_any_permission('bonus.approve', 'bonus.calculate', 'bonus_rule.view')
def list_calculation_logs():
    """
    GET /api/bonuses/calculation-logs

    آخر تشغيلات المجدول — يُعرض في الواجهة كإشعار داخلي.

    Query params:
        limit    int  (افتراضي 20)
        status   success | failed
    """
    from models import BonusCalculationLog

    limit = min(int(request.args.get('limit', 20)), 100)
    status_filter = request.args.get('status')

    q = BonusCalculationLog.query.order_by(BonusCalculationLog.run_at.desc())
    if status_filter:
        q = q.filter_by(status=status_filter)

    logs = q.limit(limit).all()

    return jsonify({
        'success': True,
        'logs': [log.to_dict() for log in logs],
        'count': len(logs),
    }), 200


# ══════════════════════════════════════════════════════════════════════════════
# Bonus Estimate — Read-Only Preview
# ══════════════════════════════════════════════════════════════════════════════

@bonus_bp.route('/invoices/<int:invoice_id>/bonus-estimate', methods=['GET'])
@require_auth
@require_any_permission('bonus.calculate', 'bonus.approve', 'bonus_rule.view')
def bonus_estimate_for_invoice(invoice_id):
    """
    GET /api/invoices/<invoice_id>/bonus-estimate

    تقدير المكافأة المتوقعة لفاتورة بعينها — Read Only.
    لا يُنشئ EmployeeBonus ولا قيوداً محاسبية ولا يُنفّذ أي commit.

    منطق تحديد الموظف:
      1. invoice.employee_id (الأساسي)
      2. invoice.posted_by → AppUser.username → Employee (للتوافق الخلفي فقط)

    الفترة = الشهر الكامل الذي تقع فيه invoice.date.
    """
    import calendar
    from bonus_calculator import _formula_string

    # 1. الفاتورة
    invoice = Invoice.query.get(invoice_id)
    if invoice is None:
        return jsonify({'success': False, 'error': 'الفاتورة غير موجودة'}), 404

    # 2. الموظف
    employee = None
    if invoice.employee_id:
        employee = Employee.query.get(invoice.employee_id)

    if employee is None and invoice.posted_by:
        from models import AppUser
        app_user = AppUser.query.filter_by(username=invoice.posted_by).first()
        if app_user:
            employee = app_user.employee

    if employee is None:
        return jsonify({
            'success': False,
            'error': 'لا يوجد موظف مرتبط بهذه الفاتورة',
            'code': 'no_employee_linked',
        }), 400

    # 3. الفترة — الشهر الكامل لتاريخ الفاتورة
    inv_date = invoice.date.date() if hasattr(invoice.date, 'date') else invoice.date
    period_start = inv_date.replace(day=1)
    period_end = inv_date.replace(day=calendar.monthrange(inv_date.year, inv_date.month)[1])

    # 4. الاحتساب — لا يُنفَّذ أي commit
    rules = BonusRule.query.filter_by(is_active=True).all()
    estimates = []

    for rule in rules:
        if not rule.is_valid_for_employee(employee):
            continue
        if not BonusCalculator._is_rule_type_enabled(rule.rule_type):
            continue

        result = None
        if rule.rule_type == 'sales_target':
            result = BonusCalculator.calculate_sales_bonus(employee, rule, period_start, period_end)
        elif rule.rule_type == 'profit_based':
            result = BonusCalculator.calculate_profit_bonus(employee, rule, period_start, period_end)
        elif rule.rule_type == 'fixed':
            result = BonusCalculator.calculate_fixed_bonus(employee, rule, period_start, period_end)
        elif rule.rule_type == 'points_based':
            result = BonusCalculator.calculate_points_bonus(employee, rule, period_start, period_end)
        elif rule.rule_type == 'attendance':
            result = BonusCalculator.calculate_attendance_bonus(employee, rule, period_start, period_end)
        elif rule.rule_type == 'performance':
            result = BonusCalculator.calculate_performance_bonus(employee, rule, period_start, period_end)

        if result is None:
            continue

        raw_amount, amount, calculation_data, min_applied, max_applied = result
        formula = _formula_string(rule)

        estimates.append({
            'rule_id': rule.id,
            'rule_name': rule.name,
            'rule_type': rule.rule_type,
            'estimated_bonus': round(amount, 4),
            'formula': formula,
            'calculation_detail': {
                'inputs': calculation_data,
                'calculation': {
                    'rule_type': rule.rule_type,
                    'formula': formula,
                    'raw_amount': round(raw_amount, 4),
                    'min_bonus_applied': min_applied,
                    'max_bonus_applied': max_applied,
                },
                'result': {
                    'final_bonus': round(amount, 4),
                },
            },
        })

    return jsonify({
        'success': True,
        'invoice_id': invoice_id,
        'employee_id': employee.id,
        'period': {
            'start': period_start.isoformat(),
            'end': period_end.isoformat(),
        },
        'estimates': estimates,
        'note': 'هذا تقدير فقط، والاحتساب الرسمي يتم تلقائياً بواسطة Scheduler في نهاية الفترة.',
    }), 200
