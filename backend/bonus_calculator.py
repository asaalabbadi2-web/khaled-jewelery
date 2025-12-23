"""
خدمة حساب المكافآت للموظفين
===================================

توفر وظائف لحساب المكافآت بناءً على القواعد المحددة والبيانات المتاحة
"""

from datetime import datetime, date, timedelta
from models import db, Employee, BonusRule, EmployeeBonus, Invoice, BonusInvoiceLink
from sqlalchemy import func, and_


class BonusCalculator:
    """حاسبة المكافآت للموظفين"""
    
    @staticmethod
    def calculate_sales_bonus(employee, rule, period_start, period_end):
        """
        حساب مكافأة المبيعات
        
        Parameters:
        -----------
        employee : Employee
            الموظف
        rule : BonusRule
            قاعدة المكافأة
        period_start : date
            بداية الفترة
        period_end : date
            نهاية الفترة
        
        Returns:
        --------
        tuple[float, dict] or None
            (المبلغ، بيانات الحساب) أو None إذا لم يتحقق الشرط
        """
        # الحصول على إجمالي مبيعات الموظف في الفترة
        # نربط عبر User.employee_id → Employee.id
        
        # البحث عن المستخدم المرتبط بالموظف
        username = None
        if hasattr(employee, 'user_link') and employee.user_link:
            username = employee.user_link.username
        
        if not username:
            return None
        
        sales_query = db.session.query(func.sum(Invoice.total)).filter(
            and_(
                Invoice.posted_by == username,
                Invoice.date >= period_start,
                Invoice.date <= period_end,
                Invoice.invoice_type == 'بيع',
                Invoice.is_posted == True
            )
        )
        
        total_sales = sales_query.scalar() or 0.0
        
        # التحقق من تحقيق الهدف
        conditions = rule.conditions or {}
        sales_target = conditions.get('sales_target', 0)
        
        if total_sales < sales_target:
            return None
        
        # حساب المكافأة
        amount = 0.0
        
        if rule.bonus_type == 'percentage':
            # نسبة من الراتب
            amount = employee.salary * (rule.bonus_value / 100)
        elif rule.bonus_type == 'fixed':
            # مبلغ ثابت
            amount = rule.bonus_value
        elif rule.bonus_type == 'sales_percentage':
            # نسبة من المبيعات
            amount = total_sales * (rule.bonus_value / 100)
        
        # تطبيق الحد الأدنى والأقصى
        if rule.min_bonus:
            amount = max(amount, rule.min_bonus)
        if rule.max_bonus:
            amount = min(amount, rule.max_bonus)
        
        calculation_data = {
            'sales_amount': total_sales,
            'sales_target': sales_target,
            'achievement_percentage': (total_sales / sales_target * 100) if sales_target > 0 else 0,
            'base_salary': employee.salary,  # استخدام salary
        }
        
        return amount, calculation_data
    
    @staticmethod
    def calculate_attendance_bonus(employee, rule, period_start, period_end):
        """
        حساب مكافأة الحضور والانضباط
        
        يحتاج إلى نظام حضور وغياب (يمكن إضافته لاحقاً)
        حالياً: نموذج بسيط
        """
        conditions = rule.conditions or {}
        required_attendance = conditions.get('attendance_percentage', 95)
        
        # في التطبيق الفعلي، نحتاج جدول Attendance لتتبع الحضور
        # لتبسيط المثال، نفترض حضور 100%
        actual_attendance = 100.0
        
        if actual_attendance < required_attendance:
            return None
        
        # حساب المكافأة
        amount = 0.0
        
        if rule.bonus_type == 'percentage':
            amount = employee.salary * (rule.bonus_value / 100)
        elif rule.bonus_type == 'fixed':
            amount = rule.bonus_value
        
        # تطبيق الحدود
        if rule.min_bonus:
            amount = max(amount, rule.min_bonus)
        if rule.max_bonus:
            amount = min(amount, rule.max_bonus)
        
        calculation_data = {
            'attendance_percentage': actual_attendance,
            'required_attendance': required_attendance,
            'base_salary': employee.salary,
        }
        
        return amount, calculation_data
    
    @staticmethod
    def calculate_performance_bonus(employee, rule, period_start, period_end):
        """
        حساب مكافأة الأداء
        
        يحتاج إلى نظام تقييم الأداء (يمكن إضافته لاحقاً)
        حالياً: نموذج بسيط
        """
        conditions = rule.conditions or {}
        required_rating = conditions.get('performance_rating', 4.0)
        
        # في التطبيق الفعلي، نحتاج جدول PerformanceReview
        # لتبسيط المثال، نفترض تقييم 4.5
        actual_rating = 4.5
        
        if actual_rating < required_rating:
            return None
        
        # حساب المكافأة
        amount = 0.0
        
        if rule.bonus_type == 'percentage':
            amount = employee.salary * (rule.bonus_value / 100)
        elif rule.bonus_type == 'fixed':
            amount = rule.bonus_value
        
        # تطبيق الحدود
        if rule.min_bonus:
            amount = max(amount, rule.min_bonus)
        if rule.max_bonus:
            amount = min(amount, rule.max_bonus)
        
        calculation_data = {
            'performance_rating': actual_rating,
            'required_rating': required_rating,
            'base_salary': employee.salary,
        }
        
        return amount, calculation_data
    
    @staticmethod
    def calculate_fixed_bonus(employee, rule, period_start, period_end):
        """
        حساب مكافأة ثابتة (شهرية/سنوية)
        """
        amount = 0.0
        
        if rule.bonus_type == 'percentage':
            amount = employee.salary * (rule.bonus_value / 100)
        elif rule.bonus_type == 'fixed':
            amount = rule.bonus_value
        
        # تطبيق الحدود
        if rule.min_bonus:
            amount = max(amount, rule.min_bonus)
        if rule.max_bonus:
            amount = min(amount, rule.max_bonus)
        
        calculation_data = {
            'bonus_type': 'fixed',
            'base_salary': employee.salary,
        }
        
        return amount, calculation_data
    
    @staticmethod
    def calculate_profit_bonus(employee, rule, period_start, period_end):
        """
        حساب مكافأة الأرباح
        
        Parameters:
        -----------
        employee : Employee
            الموظف
        rule : BonusRule
            قاعدة المكافأة
        period_start : date
            بداية الفترة
        period_end : date
            نهاية الفترة
        
        Returns:
        --------
        tuple[float, dict] or None
            (المبلغ، بيانات الحساب) أو None إذا لم يتحقق الشرط
        """
        from datetime import datetime
        
        # حساب إجمالي الأرباح النقدية والذهبية في الفترة
        # نستخدم employee_id للربط المباشر بدلاً من posted_by
        # تحويل date إلى datetime للمقارنة الصحيحة
        period_start_dt = datetime.combine(period_start, datetime.min.time())
        period_end_dt = datetime.combine(period_end, datetime.max.time())
        
        # 🆕 فلتر أنواع الفواتير المطبقة
        applicable_types = rule.applicable_invoice_types
        
        # استبعاد الفواتير المرتبطة بالفعل بأي مكافأة لنفس الموظف
        linked_invoice_subq = db.session.query(BonusInvoiceLink.invoice_id).join(
            EmployeeBonus, BonusInvoiceLink.bonus_id == EmployeeBonus.id
        ).filter(EmployeeBonus.employee_id == employee.id)

        # بناء الاستعلام الأساسي (قائمة فواتير مؤهلة)
        eligible_invoices_query = Invoice.query.filter(
            and_(
                Invoice.employee_id == employee.id,
                Invoice.date >= period_start_dt,
                Invoice.date <= period_end_dt,
                Invoice.is_posted == True,
                ~Invoice.id.in_(linked_invoice_subq)
            )
        )
        
        # 🆕 تطبيق فلتر أنواع الفواتير إذا كان محدداً
        if applicable_types and len(applicable_types) > 0:
            eligible_invoices_query = eligible_invoices_query.filter(Invoice.invoice_type.in_(applicable_types))

        eligible_invoices = eligible_invoices_query.all()

        invoice_ids = [inv.id for inv in eligible_invoices]
        total_profit_cash = sum(inv.profit_cash or 0 for inv in eligible_invoices)
        total_profit_gold = sum(inv.profit_gold or 0 for inv in eligible_invoices)
        invoice_count = len(eligible_invoices)

        # لا ننشئ مكافأة إذا لم توجد فواتير مؤهلة
        if invoice_count == 0:
            return None
        
        # التحقق من الشروط
        conditions = rule.conditions or {}
        min_profit = conditions.get('min_profit', 0)
        profit_type = conditions.get('profit_type', 'cash')  # 'cash' or 'gold' or 'combined'
        
        # حساب الربح المستهدف بناءً على النوع
        target_profit = 0.0
        if profit_type == 'cash':
            target_profit = total_profit_cash
        elif profit_type == 'gold':
            target_profit = total_profit_gold
        else:  # combined - نحسب المجموع
            target_profit = total_profit_cash + total_profit_gold
        
        # يجب أن يكون الربح المستهدف موجباً وأعلى من الحد الأدنى
        if target_profit <= 0 or target_profit < min_profit:
            return None
        
        # حساب المكافأة
        amount = 0.0
        
        if rule.bonus_type == 'percentage':
            # نسبة من الراتب
            amount = employee.salary * (rule.bonus_value / 100)
        elif rule.bonus_type == 'fixed':
            # مبلغ ثابت
            amount = rule.bonus_value
        elif rule.bonus_type == 'profit_percentage':
            # نسبة من الربح
            amount = target_profit * (rule.bonus_value / 100)
        
        # تطبيق الحد الأدنى والأقصى
        if rule.min_bonus:
            amount = max(amount, rule.min_bonus)
        if rule.max_bonus:
            amount = min(amount, rule.max_bonus)
        
        calculation_data = {
            'total_profit_cash': total_profit_cash,
            'total_profit_gold': total_profit_gold,
            'target_profit': target_profit,
            'profit_type': profit_type,
            'invoice_count': invoice_count,
            'min_profit': min_profit,
            'base_salary': employee.salary,
            'applicable_invoice_types': applicable_types,  # 🆕
            'invoice_ids': invoice_ids,
        }
        
        return amount, calculation_data
    
    @staticmethod
    def calculate_bonus(employee, rule, period_start, period_end):
        """
        حساب المكافأة بناءً على نوع القاعدة
        
        Parameters:
        -----------
        employee : Employee
            الموظف
        rule : BonusRule
            قاعدة المكافأة
        period_start : date
            بداية الفترة
        period_end : date
            نهاية الفترة
        
        Returns:
        --------
        EmployeeBonus or None
            كائن المكافأة إذا تحققت الشروط، أو None
        """
        # التحقق من صلاحية القاعدة للموظف
        if not rule.is_active or not rule.is_valid_for_employee(employee):
            return None
        
        # حساب المكافأة حسب النوع
        result = None
        
        if rule.rule_type == 'sales_target':
            result = BonusCalculator.calculate_sales_bonus(employee, rule, period_start, period_end)
        elif rule.rule_type == 'attendance':
            result = BonusCalculator.calculate_attendance_bonus(employee, rule, period_start, period_end)
        elif rule.rule_type == 'performance':
            result = BonusCalculator.calculate_performance_bonus(employee, rule, period_start, period_end)
        elif rule.rule_type == 'fixed':
            result = BonusCalculator.calculate_fixed_bonus(employee, rule, period_start, period_end)
        elif rule.rule_type == 'profit_based':
            result = BonusCalculator.calculate_profit_bonus(employee, rule, period_start, period_end)
        
        if not result:
            return None
        
        amount, calculation_data = result
        
        # إنشاء سجل المكافأة
        bonus = EmployeeBonus(
            employee_id=employee.id,
            bonus_rule_id=rule.id,
            bonus_type=rule.rule_type,
            amount=amount,
            period_start=period_start,
            period_end=period_end,
            calculation_data=calculation_data,
            status='pending',
            created_at=datetime.utcnow()
        )
        
        return bonus
    
    @staticmethod
    def calculate_all_bonuses_for_period(
        period_start,
        period_end,
        employee_ids=None,
        rule_ids=None,
        auto_approve=False,
        refresh_results=True,
    ):
        """
        حساب جميع المكافآت للموظفين النشطين في فترة معينة
        
        Parameters:
        -----------
        period_start : date
            بداية الفترة
        period_end : date
            نهاية الفترة
        employee_ids : list[int] | None
            قائمة اختيارية لتقييد الحساب على موظفين محددين
        rule_ids : list[int] | None
            قائمة اختيارية لتقييد الحساب على قواعد محددة
        auto_approve : bool
            اعتماد تلقائي للمكافآت
        refresh_results : bool
            إعادة جلب المكافآت من قاعدة البيانات بعد الحساب لضمان أحدث القيم
        
        Returns:
        --------
        list[EmployeeBonus]
            قائمة المكافآت المحسوبة
        """
        bonuses = []
        processed_bonus_ids = []  # تتبع المكافآت المعالجة

        employees_query = Employee.query.filter_by(is_active=True)
        if employee_ids:
            employees_query = employees_query.filter(Employee.id.in_(employee_ids))
        employees = employees_query.all()

        rules_query = BonusRule.query.filter_by(is_active=True)
        if rule_ids:
            rules_query = rules_query.filter(BonusRule.id.in_(rule_ids))
        rules = rules_query.all()
        
        def _sync_invoice_links(bonus_obj, invoice_ids):
            if invoice_ids is None:
                return
            # احذف الروابط القديمة ثم أضف الحالية فقط
            BonusInvoiceLink.query.filter_by(bonus_id=bonus_obj.id).delete()
            for inv_id in invoice_ids:
                db.session.add(BonusInvoiceLink(bonus_id=bonus_obj.id, invoice_id=inv_id))

        for employee in employees:
            for rule in rules:
                # التحقق من وجود مكافأة سابقة أولاً
                existing = EmployeeBonus.query.filter_by(
                    employee_id=employee.id,
                    bonus_rule_id=rule.id,
                    period_start=period_start,
                    period_end=period_end
                ).first()
                
                # تخطي المكافآت المرفوضة/المدفوعة/المعتمدة إذا لم يكن auto_approve
                if existing and existing.status in ['rejected', 'paid', 'approved'] and not auto_approve:
                    continue
                
                bonus = BonusCalculator.calculate_bonus(employee, rule, period_start, period_end)
                
                if bonus:
                    target_status = 'approved' if auto_approve else 'pending'

                    if existing:
                        existing.amount = bonus.amount
                        existing.calculation_data = bonus.calculation_data
                        existing.status = target_status
                        if auto_approve:
                            existing.approved_by = 'system'
                            existing.approved_at = datetime.utcnow()
                        # مزامنة روابط الفواتير المستخدمة في الحساب
                        invoice_ids = bonus.calculation_data.get('invoice_ids') if bonus.calculation_data else None
                        if invoice_ids is not None:
                            _sync_invoice_links(existing, invoice_ids)
                        processed_bonus_ids.append(existing.id)
                        bonuses.append(existing)
                    else:
                        if auto_approve:
                            bonus.approve('system')
                        db.session.add(bonus)
                        db.session.flush()  # للحصول على ID
                        invoice_ids = bonus.calculation_data.get('invoice_ids') if bonus.calculation_data else None
                        if invoice_ids is not None:
                            _sync_invoice_links(bonus, invoice_ids)
                        processed_bonus_ids.append(bonus.id)
                        bonuses.append(bonus)
        
        try:
            db.session.commit()
        except Exception as e:
            db.session.rollback()
            print(f"خطأ في حساب المكافآت: {e}")
            return []

        # إعادة جلب المكافآت المعالجة فقط (وليس كل المكافآت في الفترة)
        if refresh_results and processed_bonus_ids:
            bonuses = EmployeeBonus.query.filter(
                EmployeeBonus.id.in_(processed_bonus_ids)
            ).order_by(
                EmployeeBonus.employee_id.asc(),
                EmployeeBonus.bonus_rule_id.asc().nullsfirst(),
            ).all()

        return bonuses
    
    @staticmethod
    def calculate_bonus_for_invoice(invoice_id):
        """
        حساب المكافأة تلقائياً لفاتورة واحدة فور حفظها
        
        Parameters:
        -----------
        invoice_id : int
            معرف الفاتورة
        
        Returns:
        --------
        EmployeeBonus or None
            المكافأة المحسوبة أو None
        """
        invoice = Invoice.query.get(invoice_id)
        
        print(f"\n🔍 calculate_bonus_for_invoice called for invoice #{invoice_id}")
        
        # التحقق من الشروط الأساسية
        if not invoice:
            print(f"   ❌ Invoice not found")
            return None
            
        if not invoice.employee_id:
            print(f"   ❌ No employee_id assigned to invoice")
            return None
        
        print(f"   ✅ Invoice found: Type={invoice.invoice_type}, Employee={invoice.employee_id}")
        
        # التحقق من وجود ربح
        profit_cash = float(invoice.profit_cash) if invoice.profit_cash else 0.0
        print(f"   💰 Profit Cash: {profit_cash}")
        
        if profit_cash <= 0:
            print(f"   ❌ No profit (profit_cash <= 0)")
            return None
        
        # البحث عن قواعد مكافآت نشطة تنطبق على هذا الموظف ونوع الفاتورة
        rules = BonusRule.query.filter_by(
            is_active=True,
            rule_type='profit_based'
        ).all()
        
        print(f"   📋 Found {len(rules)} active profit_based rules")
        
        # فلترة القواعد حسب target_employee_ids و applicable_invoice_types
        applicable_rules = []
        for rule in rules:
            print(f"\\n   🔍 Checking rule: {rule.name}")
            
            # فحص إذا كانت القاعدة تنطبق على هذا الموظف
            if rule.target_employee_ids:
                if invoice.employee_id not in rule.target_employee_ids:
                    print(f"      ❌ Employee {invoice.employee_id} not in target list: {rule.target_employee_ids}")
                    continue
                else:
                    print(f"      ✅ Employee {invoice.employee_id} is in target list")
            else:
                print(f"      ✅ No employee filter (applies to all)")
            
            # فحص إذا كانت القاعدة تنطبق على نوع هذه الفاتورة
            if rule.applicable_invoice_types:
                if invoice.invoice_type not in rule.applicable_invoice_types:
                    print(f"      ❌ Invoice type '{invoice.invoice_type}' not in applicable types: {rule.applicable_invoice_types}")
                    continue
                else:
                    print(f"      ✅ Invoice type '{invoice.invoice_type}' is applicable")
            else:
                print(f"      ✅ No invoice type filter (applies to all)")
            
            print(f"      ✅ Rule '{rule.name}' is applicable!")
            applicable_rules.append(rule)
        
        if not applicable_rules:
            print(f"\\n   ❌ No applicable rules found")
            return None
        
        print(f"\\n   ✅ Found {len(applicable_rules)} applicable rule(s)")
        
        # استخدام أول قاعدة مطابقة (يمكن تحسين هذا لاحقاً)
        rule = applicable_rules[0]
        print(f"   📌 Using rule: {rule.name} ({rule.bonus_value}%)")
        
        # حساب المكافأة (نسبة من الربح)
        bonus_percentage = rule.bonus_value  # مثلاً 10
        bonus_amount = profit_cash * (bonus_percentage / 100.0)
        
        # تطبيق الحد الأدنى والأقصى
        if rule.min_bonus and bonus_amount < rule.min_bonus:
            bonus_amount = rule.min_bonus
        if rule.max_bonus and bonus_amount > rule.max_bonus:
            bonus_amount = rule.max_bonus
        
        # التحقق من وجود مكافأة مسبقة لنفس الفاتورة عبر الربط الصريح
        existing_link = BonusInvoiceLink.query.filter_by(invoice_id=invoice_id).join(
            EmployeeBonus, BonusInvoiceLink.bonus_id == EmployeeBonus.id
        ).filter(
            EmployeeBonus.employee_id == invoice.employee_id,
            EmployeeBonus.bonus_rule_id == rule.id,
        ).first()

        existing = existing_link.bonus if existing_link else None
        
        if existing:
            # لا نعيد فتح مكافأة مرفوضة/مدفوعة/معتمدة
            if existing.status in ['rejected', 'paid', 'approved']:
                return existing

            # تحديث المكافأة الموجودة
            existing.amount = round(bonus_amount, 2)
            existing.calculation_data = {
                'invoice_id': invoice_id,
                'profit_cash': profit_cash,
                'bonus_percentage': bonus_percentage,
                'auto_calculated': True
            }
            BonusInvoiceLink.query.filter_by(bonus_id=existing.id).delete()
            db.session.add(BonusInvoiceLink(bonus_id=existing.id, invoice_id=invoice_id))
            db.session.commit()
            return existing
        
        # إنشاء مكافأة جديدة
        bonus = EmployeeBonus(
            employee_id=invoice.employee_id,
            bonus_rule_id=rule.id,
            amount=round(bonus_amount, 2),
            bonus_type='profit_based',
            period_start=invoice.date.date() if isinstance(invoice.date, datetime) else invoice.date,
            period_end=invoice.date.date() if isinstance(invoice.date, datetime) else invoice.date,
            status='pending',
            calculation_data={
                'invoice_id': invoice_id,
                'profit_cash': profit_cash,
                'bonus_percentage': bonus_percentage,
                'auto_calculated': True
            }
        )
        
        db.session.add(bonus)
        db.session.flush()
        db.session.add(BonusInvoiceLink(bonus_id=bonus.id, invoice_id=invoice_id))
        db.session.commit()
        
        return bonus
    
    @staticmethod
    def get_employee_bonuses_summary(employee_id, start_date=None, end_date=None):
        """
        الحصول على ملخص مكافآت موظف معين
        
        Parameters:
        -----------
        employee_id : int
            معرف الموظف
        start_date : date, optional
            تاريخ البداية
        end_date : date, optional
            تاريخ النهاية
        
        Returns:
        --------
        dict
            ملخص المكافآت
        """
        query = EmployeeBonus.query.filter_by(employee_id=employee_id)
        
        if start_date:
            query = query.filter(EmployeeBonus.period_start >= start_date)
        if end_date:
            query = query.filter(EmployeeBonus.period_end <= end_date)
        
        bonuses = query.all()
        
        total_bonuses = sum(b.amount for b in bonuses if b.status in ['approved', 'paid'])
        pending_bonuses = sum(b.amount for b in bonuses if b.status == 'pending')
        paid_bonuses = sum(b.amount for b in bonuses if b.status == 'paid')
        
        return {
            'total_bonuses': total_bonuses,
            'pending_bonuses': pending_bonuses,
            'paid_bonuses': paid_bonuses,
            'bonuses_count': len(bonuses),
            'bonuses': [b.to_dict(include_employee=False, include_rule=True) for b in bonuses]
        }
