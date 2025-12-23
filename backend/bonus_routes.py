"""
Routes لنظام المكافآت للموظفين
====================================

Endpoints:
- GET/POST /api/employees - إدارة الموظفين
- GET/POST/PUT/DELETE /api/bonus-rules - إدارة قواعد المكافآت
- GET /api/invoice-types - الحصول على قائمة أنواع الفواتير المتاحة
- GET/POST /api/bonuses - إدارة المكافآت
- POST /api/bonuses/calculate - حساب المكافآت لفترة محددة
- POST /api/bonuses/<id>/approve - اعتماد مكافأة
- POST /api/bonuses/<id>/reject - رفض مكافأة
- POST /api/bonuses/<id>/pay - تسجيل دفع مكافأة
"""

from flask import Blueprint, request, jsonify
from models import db, Employee, BonusRule, EmployeeBonus, Voucher, VoucherAccountLine, Account
from bonus_calculator import BonusCalculator
from datetime import datetime, date
from auth_decorators import require_auth, require_permission
from sqlalchemy import or_, func

bonus_bp = Blueprint('bonuses', __name__)


# ==========================================
# 👥 إدارة الموظفين (Employees)
# ==========================================

@bonus_bp.route('/employees', methods=['GET'])
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


@bonus_bp.route('/employees/<int:employee_id>', methods=['GET'])
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
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 404


# ❌ تم حذف create_employee() من هنا لأنه مكرر
# ✅ استخدم الدالة الأصلية في routes.py التي تولّد employee_code تلقائياً
# وتنشئ حساب محاسبي تلقائياً للموظف


@bonus_bp.route('/employees/<int:employee_id>', methods=['PUT'])
@require_auth
@require_permission('employee.update')
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
@require_auth
def get_bonus_rule(rule_id):
    """عرض قاعدة مكافأة محددة"""
    try:
        rule = BonusRule.query.get_or_404(rule_id)
        
        return jsonify({
            'success': True,
            'rule': rule.to_dict()
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 404


@bonus_bp.route('/bonus-rules', methods=['POST'])
@require_auth
@require_permission('bonus_rule.create')
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
        
        # تحويل التواريخ
        valid_from = None
        valid_to = None
        if data.get('valid_from'):
            valid_from = datetime.strptime(data['valid_from'], '%Y-%m-%d').date()
        if data.get('valid_to'):
            valid_to = datetime.strptime(data['valid_to'], '%Y-%m-%d').date()
        
        # 🔍 التحقق من صحة أنواع الفواتير المحددة
        valid_invoice_types = ['بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء من مورد', 'مرتجع شراء من مورد']
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
            target_employee_ids=data.get('target_employee_ids'),  # 🆕
            applicable_invoice_types=data.get('applicable_invoice_types'),  # 🆕
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
@require_permission('bonus_rule.update')
def update_bonus_rule(rule_id):
    """تحديث قاعدة مكافأة"""
    try:
        rule = BonusRule.query.get_or_404(rule_id)
        data = request.get_json()
        
        # 🔍 التحقق من صحة أنواع الفواتير إذا تم تحديثها
        valid_invoice_types = ['بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء من مورد', 'مرتجع شراء من مورد']
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
        if 'applicable_invoice_types' in data:  # 🆕
            rule.applicable_invoice_types = data['applicable_invoice_types']
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
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonus-rules/<int:rule_id>', methods=['DELETE'])
@require_auth
@require_permission('bonus_rule.delete')
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
@require_auth
def get_bonuses():
    """عرض جميع المكافآت"""
    try:
        employee_id = request.args.get('employee_id', type=int)
        status = request.args.get('status')
        period_start = request.args.get('period_start')
        period_end = request.args.get('period_end')
        
        query = EmployeeBonus.query
        
        if employee_id:
            query = query.filter_by(employee_id=employee_id)
        
        if status:
            query = query.filter_by(status=status)
        
        if period_start:
            start_date = datetime.strptime(period_start, '%Y-%m-%d').date()
            query = query.filter(EmployeeBonus.period_start >= start_date)
        
        if period_end:
            end_date = datetime.strptime(period_end, '%Y-%m-%d').date()
            query = query.filter(EmployeeBonus.period_end <= end_date)
        
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


@bonus_bp.route('/bonuses/<int:bonus_id>', methods=['GET'])
@require_auth
def get_bonus(bonus_id):
    """عرض مكافأة محددة"""
    try:
        bonus = EmployeeBonus.query.get_or_404(bonus_id)
        
        return jsonify({
            'success': True,
            'bonus': bonus.to_dict(include_employee=True, include_rule=True)
        }), 200
        
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

    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonuses/calculate', methods=['POST'])
@require_auth
@require_permission('bonus.calculate')
def calculate_bonuses():
    """حساب المكافآت لفترة محددة"""
    try:
        data = request.get_json()
        
        # التحقق من البيانات المطلوبة
        if not data.get('period_start') or not data.get('period_end'):
            return jsonify({
                'success': False,
                'message': 'يجب تحديد تاريخ البداية والنهاية'
            }), 400
        
        period_start = datetime.strptime(data['period_start'], '%Y-%m-%d').date()
        period_end = datetime.strptime(data['period_end'], '%Y-%m-%d').date()
        auto_approve = data.get('auto_approve', False)

        employee_ids = data.get('employee_ids') if isinstance(data.get('employee_ids'), list) else None
        rule_ids = data.get('rule_ids') if isinstance(data.get('rule_ids'), list) else None
        
        # حساب المكافآت
        bonuses = BonusCalculator.calculate_all_bonuses_for_period(
            period_start=period_start,
            period_end=period_end,
            employee_ids=employee_ids,
            rule_ids=rule_ids,
            auto_approve=auto_approve
        )
        
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


@bonus_bp.route('/bonuses/<int:bonus_id>/approve', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def approve_bonus(bonus_id):
    """
    اعتماد مكافأة مع إنشاء قيد محاسبي لإثبات المصروف والالتزام
    
    القيد المحاسبي:
    من ح/ مصروف مكافآت (514)    مدين
      إلى ح/ مكافآت مستحقة (215)  دائن
    """
    try:
        bonus = EmployeeBonus.query.get_or_404(bonus_id)
        data = request.get_json() or {}
        
        if bonus.status != 'pending':
            return jsonify({
                'success': False,
                'message': 'لا يمكن اعتماد مكافأة غير معلقة'
            }), 400
        
        approved_by = data.get('approved_by', 'system')
        
        # البحث عن حساب مصروف المكافآت (514)
        bonus_expense_account = Account.query.filter_by(account_number='514').first()
        if not bonus_expense_account:
            return jsonify({
                'success': False,
                'message': 'حساب مصروف المكافآت غير موجود (514)'
            }), 400
        
        # البحث عن حساب مكافآت مستحقة (215)
        bonuses_payable_account = Account.query.filter_by(account_number='215').first()
        if not bonuses_payable_account:
            return jsonify({
                'success': False,
                'message': 'حساب مكافآت مستحقة غير موجود (215)'
            }), 400
        
        # إنشاء سند قيد لإثبات المصروف والالتزام
        employee = Employee.query.get(bonus.employee_id)
        voucher_number = f"BAPP-{bonus.id}"
        
        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type='قيد',
            date=date.today(),
            description=f"اعتماد مكافأة {employee.name if employee else bonus.employee_id} - {bonus.bonus_type}",
            status='approved',
            created_by=approved_by,
        )
        db.session.add(voucher)
        db.session.flush()
        
        # السطر المدين: مصروف المكافآت
        debit_line = VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=bonus_expense_account.id,
            line_type='debit',
            amount_type='cash',
            description=f"مصروف مكافأة {employee.name if employee else ''}",
            amount=bonus.amount,
        )
        db.session.add(debit_line)
        
        # السطر الدائن: مكافآت مستحقة
        credit_line = VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=bonuses_payable_account.id,
            line_type='credit',
            amount_type='cash',
            description=f"استحقاق مكافأة {employee.name if employee else ''}",
            amount=bonus.amount,
        )
        db.session.add(credit_line)
        
        # اعتماد المكافأة
        bonus.approve(approved_by)
        bonus.payment_reference = voucher_number  # حفظ رقم سند الاستحقاق
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم اعتماد المكافأة وإثبات المصروف بنجاح',
            'bonus': bonus.to_dict(include_employee=True, include_rule=True),
            'voucher': {
                'id': voucher.id,
                'voucher_number': voucher_number,
                'amount': bonus.amount
            }
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonuses/bulk/approve', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def bulk_approve_bonuses():
    """اعتماد عدة مكافآت معلقة دفعة واحدة"""
    try:
        data = request.get_json() or {}
        ids = data.get('ids') or []
        approved_by = data.get('approved_by', 'system')

        if not isinstance(ids, list) or not ids:
            return jsonify({'success': False, 'message': 'قائمة المعرفات مطلوبة'}), 400

        bonuses = EmployeeBonus.query.filter(EmployeeBonus.id.in_(ids)).all()
        approved, skipped = [], []

        for bonus in bonuses:
            if bonus.status == 'pending':
                bonus.approve(approved_by)
                approved.append(bonus.id)
            else:
                skipped.append({'id': bonus.id, 'status': bonus.status})

        db.session.commit()

        return jsonify({
            'success': True,
            'approved_ids': approved,
            'skipped': skipped,
            'count': len(approved)
        }), 200

    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@bonus_bp.route('/bonuses/<int:bonus_id>/reject', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def reject_bonus(bonus_id):
    """رفض مكافأة"""
    try:
        bonus = EmployeeBonus.query.get_or_404(bonus_id)
        data = request.get_json() or {}
        
        if bonus.status != 'pending':
            return jsonify({
                'success': False,
                'message': 'لا يمكن رفض مكافأة غير معلقة'
            }), 400
        
        reason = data.get('reason')
        bonus.reject(reason)
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم رفض المكافأة',
            'bonus': bonus.to_dict(include_employee=True, include_rule=True)
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/bonuses/bulk/reject', methods=['POST'])
@require_auth
@require_permission('bonus.approve')
def bulk_reject_bonuses():
    """رفض عدة مكافآت معلقة دفعة واحدة"""
    try:
        data = request.get_json() or {}
        ids = data.get('ids') or []
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


@bonus_bp.route('/bonuses/<int:bonus_id>/pay', methods=['POST'])
@require_auth
@require_permission('bonus.pay')
def pay_bonus(bonus_id):
    """
    دفع مكافأة مع إنشاء سند صرف لتسديد الالتزام
    
    القيد المحاسبي:
    من ح/ مكافآت مستحقة (215)    مدين
      إلى ح/ الصندوق/البنك          دائن
    
    Body Parameters:
        - payment_method: طريقة الدفع ('cash', 'transfer', 'add_to_payroll')
        - payment_account_id: معرف حساب الدفع (للصرف النقدي أو التحويل)
        - paid_date: تاريخ الدفع (اختياري)
        - created_by: اسم المستخدم (اختياري)
    """
    try:
        bonus = EmployeeBonus.query.get_or_404(bonus_id)
        data = request.get_json() or {}
        
        if bonus.status != 'approved':
            return jsonify({
                'success': False,
                'message': 'لا يمكن دفع مكافأة غير معتمدة'
            }), 400
        
        payment_method = data.get('payment_method', 'cash')  # cash, transfer, add_to_payroll
        paid_date = datetime.strptime(data.get('paid_date'), '%Y-%m-%d').date() if data.get('paid_date') else date.today()
        created_by = data.get('created_by', 'system')
        
        # الحصول على معلومات الموظف
        employee = Employee.query.get(bonus.employee_id)
        if not employee:
            return jsonify({'success': False, 'message': 'الموظف غير موجود'}), 404
        
        # إذا كان الدفع عن طريق إضافة للراتب، نسجل فقط ولا ننشئ سند
        if payment_method == 'add_to_payroll':
            bonus.mark_as_paid(f"سيتم الدفع مع الراتب")
            bonus.notes = f"{bonus.notes or ''}\nسيتم إضافة المكافأة لراتب الشهر القادم"
            db.session.commit()
            
            return jsonify({
                'success': True,
                'message': 'تم تسجيل المكافأة لإضافتها للراتب',
                'bonus': bonus.to_dict(include_employee=True, include_rule=True)
            }), 200
        
        # البحث عن حساب مكافآت مستحقة (215)
        bonuses_payable_account = Account.query.filter_by(account_number='215').first()
        if not bonuses_payable_account:
            return jsonify({'success': False, 'message': 'حساب مكافآت مستحقة غير موجود (215)'}), 400
        
        # إنشاء سند صرف للدفع النقدي أو التحويل
        voucher_prefix = f"BPAY-{paid_date.year}-{paid_date.month:02d}"
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
        
        # إنشاء السند
        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type='صرف',
            date=paid_date,
            description=f"صرف مكافأة {employee.name} - {bonus.bonus_type}",
            status='approved',
            created_by=created_by,
        )
        db.session.add(voucher)
        db.session.flush()
        
        # تحديد حساب الدفع
        payment_account_id = data.get('payment_account_id')
        if payment_account_id:
            payment_account = Account.query.get(payment_account_id)
            if not payment_account:
                db.session.rollback()
                return jsonify({'success': False, 'message': 'حساب الدفع غير موجود'}), 400
        else:
            # البحث عن حساب الصندوق الافتراضي
            payment_account = Account.query.filter(
                or_(
                    Account.account_number == '111',
                    Account.name.like('%الصندوق%'),
                    Account.name.like('%نقدية%')
                )
            ).first()
            
            if not payment_account:
                db.session.rollback()
                return jsonify({'success': False, 'message': 'لا يوجد حساب نقدية في النظام'}), 400
        
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
        
        # السطر الدائن: حساب الدفع (خروج أموال)
        credit_line = VoucherAccountLine(
            voucher_id=voucher.id,
            account_id=payment_account.id,
            line_type='credit',
            amount_type='cash',
            description=f"صرف مكافأة - {payment_account.name}",
            amount=bonus.amount,
        )
        db.session.add(credit_line)
        
        # تحديث المكافأة
        bonus.mark_as_paid(voucher_number)
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم صرف المكافأة وتسديد الالتزام بنجاح',
            'bonus': bonus.to_dict(include_employee=True, include_rule=True),
            'voucher': {
                'id': voucher.id,
                'voucher_number': voucher_number,
                'amount': bonus.amount
            }
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@bonus_bp.route('/employees/<int:employee_id>/bonuses-summary', methods=['GET'])
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
@require_permission('bonus.admin')
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
@require_permission('bonus.admin')
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
@require_permission('invoice.update')
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
        {'value': 'شراء من مورد', 'label': 'شراء من مورد', 'description': 'شراء ذهب من مورد'},
        {'value': 'مرتجع شراء من مورد', 'label': 'مرتجع شراء من مورد', 'description': 'إرجاع بضاعة لمورد'}
    ]
    
    return jsonify({
        'success': True,
        'invoice_types': invoice_types
    }), 200


# ==========================================
# 📊 تقرير المستحقات (Payables Report)
# ==========================================

@bonus_bp.route('/bonuses/payables-report', methods=['GET'])
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
                'account_number': '215',
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
