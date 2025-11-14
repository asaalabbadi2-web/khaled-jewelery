"""
نظام القيود الدورية (Recurring Journal Entries)
=================================================

هذا الملف يوفر آلية لإنشاء وجدولة القيود الدورية المتكررة

الاستخدام:
1. إنشاء قالب قيد دوري (Recurring Template)
2. تحديد فترة التكرار (شهري، ربع سنوي، سنوي)
3. تنفيذ القيود تلقائياً حسب الجدول
"""

from datetime import datetime, timedelta
try:
    from dateutil.relativedelta import relativedelta
    HAS_DATEUTIL = True
except ImportError:
    HAS_DATEUTIL = False
    # Fallback: استخدام حساب يدوي للشهور والسنوات
    def add_months(source_date, months):
        """إضافة شهور إلى تاريخ"""
        month = source_date.month - 1 + months
        year = source_date.year + month // 12
        month = month % 12 + 1
        day = min(source_date.day, [31, 29 if year % 4 == 0 and (year % 100 != 0 or year % 400 == 0) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1])
        return source_date.replace(year=year, month=month, day=day)
from models import db, JournalEntry, JournalEntryLine
from sqlalchemy import Column, Integer, String, DateTime, Boolean, Float, ForeignKey, JSON
from sqlalchemy.orm import relationship


class RecurringJournalTemplate(db.Model):
    """
    قالب القيد الدوري - يحتوي على معلومات القيد الأساسية وخطوط القيد
    """
    __tablename__ = 'recurring_journal_template'
    
    id = Column(Integer, primary_key=True)
    name = Column(String(200), nullable=False)  # اسم القالب (مثل: "راتب موظفي المحل")
    description = Column(String(500))  # وصف القالب
    
    # تفاصيل التكرار
    frequency = Column(String(50), nullable=False)  # monthly, quarterly, yearly, weekly, daily
    interval = Column(Integer, default=1)  # كل كم من الفترة (مثلاً كل شهرين = interval=2)
    
    # تواريخ البداية والنهاية
    start_date = Column(DateTime, nullable=False)  # تاريخ البداية
    end_date = Column(DateTime, nullable=True)  # تاريخ النهاية (اختياري)
    next_run_date = Column(DateTime, nullable=False)  # التاريخ القادم للتنفيذ
    
    # اليوم المفضل من الشهر (للقيود الشهرية)
    preferred_day_of_month = Column(Integer, default=1)  # اليوم الأول من الشهر افتراضياً
    
    # الحالة
    is_active = Column(Boolean, default=True)  # هل القالب نشط
    auto_create = Column(Boolean, default=True)  # إنشاء تلقائي أم يدوي
    
    # إحصائيات
    last_created_date = Column(DateTime, nullable=True)  # آخر تاريخ تم فيه إنشاء قيد
    total_created = Column(Integer, default=0)  # عدد القيود المنشأة من هذا القالب
    
    # معلومات الإنشاء
    created_at = Column(DateTime, default=datetime.now)
    created_by = Column(String(100))
    
    # العلاقات
    template_lines = relationship('RecurringJournalLine', backref='template', 
                                 cascade="all, delete-orphan", lazy=True)
    created_entries = relationship('JournalEntry', backref='recurring_template',
                                  foreign_keys='JournalEntry.recurring_template_id')
    
    def __repr__(self):
        return f'<RecurringTemplate {self.name} - {self.frequency}>'
    
    def calculate_next_run_date(self):
        """حساب تاريخ التشغيل القادم"""
        current = self.next_run_date
        
        if self.frequency == 'daily':
            next_date = current + timedelta(days=self.interval)
        elif self.frequency == 'weekly':
            next_date = current + timedelta(weeks=self.interval)
        elif self.frequency == 'monthly':
            if HAS_DATEUTIL:
                next_date = current + relativedelta(months=self.interval)
            else:
                next_date = add_months(current, self.interval)
            # التأكد من اليوم المفضل
            if self.preferred_day_of_month:
                try:
                    next_date = next_date.replace(day=self.preferred_day_of_month)
                except ValueError:
                    # إذا كان اليوم غير موجود (مثل 31 في فبراير)، استخدم آخر يوم في الشهر
                    if HAS_DATEUTIL:
                        next_date = next_date.replace(day=1) + relativedelta(months=1) - timedelta(days=1)
                    else:
                        next_date = add_months(next_date.replace(day=1), 1) - timedelta(days=1)
        elif self.frequency == 'quarterly':
            if HAS_DATEUTIL:
                next_date = current + relativedelta(months=3 * self.interval)
            else:
                next_date = add_months(current, 3 * self.interval)
        elif self.frequency == 'yearly':
            if HAS_DATEUTIL:
                next_date = current + relativedelta(years=self.interval)
            else:
                next_date = add_months(current, 12 * self.interval)
        else:
            next_date = current + relativedelta(months=self.interval)
        
        return next_date
    
    def should_create_entry(self, check_date=None):
        """التحقق من ضرورة إنشاء قيد في التاريخ المحدد"""
        if not self.is_active:
            return False
        
        if check_date is None:
            check_date = datetime.now()
        
        # التحقق من أن التاريخ القادم قد حان
        if check_date < self.next_run_date:
            return False
        
        # التحقق من تاريخ النهاية
        if self.end_date and check_date > self.end_date:
            return False
        
        return True
    
    def create_journal_entry(self):
        """إنشاء قيد يومية من القالب"""
        from backend.routes import _generate_journal_entry_number
        
        # إنشاء القيد الرئيسي
        entry_number = _generate_journal_entry_number(self.next_run_date)
        
        new_entry = JournalEntry(
            entry_number=entry_number,
            date=self.next_run_date,
            description=f"{self.description} (دوري - {self.name})",
            entry_type='دوري',
            reference_type='recurring_template',
            reference_id=self.id,
            reference_number=f"REC-{self.id}-{self.total_created + 1}",
            created_by='نظام القيود الدورية',
            recurring_template_id=self.id
        )
        
        db.session.add(new_entry)
        db.session.flush()  # للحصول على معرف القيد
        
        # إنشاء خطوط القيد من القالب
        for template_line in self.template_lines:
            new_line = JournalEntryLine(
                journal_entry_id=new_entry.id,
                account_id=template_line.account_id,
                cash_debit=template_line.cash_debit,
                cash_credit=template_line.cash_credit,
                debit_18k=template_line.debit_18k,
                credit_18k=template_line.credit_18k,
                debit_21k=template_line.debit_21k,
                credit_21k=template_line.credit_21k,
                debit_22k=template_line.debit_22k,
                credit_22k=template_line.credit_22k,
                debit_24k=template_line.debit_24k,
                credit_24k=template_line.credit_24k,
            )
            db.session.add(new_line)
        
        # تحديث معلومات القالب
        self.last_created_date = self.next_run_date
        self.total_created += 1
        self.next_run_date = self.calculate_next_run_date()
        
        db.session.commit()
        
        return new_entry
    
    def to_dict(self):
        """تحويل القالب إلى قاموس"""
        return {
            'id': self.id,
            'name': self.name,
            'description': self.description,
            'frequency': self.frequency,
            'frequency_text': self._get_frequency_text(),
            'interval': self.interval,
            'start_date': self.start_date.isoformat() if self.start_date else None,
            'end_date': self.end_date.isoformat() if self.end_date else None,
            'next_run_date': self.next_run_date.isoformat() if self.next_run_date else None,
            'preferred_day_of_month': self.preferred_day_of_month,
            'is_active': self.is_active,
            'auto_create': self.auto_create,
            'last_created_date': self.last_created_date.isoformat() if self.last_created_date else None,
            'total_created': self.total_created,
            'lines': [line.to_dict() for line in self.template_lines]
        }
    
    def _get_frequency_text(self):
        """الحصول على نص الفترة بالعربية"""
        freq_map = {
            'daily': 'يومي',
            'weekly': 'أسبوعي',
            'monthly': 'شهري',
            'quarterly': 'ربع سنوي',
            'yearly': 'سنوي'
        }
        return freq_map.get(self.frequency, self.frequency)


class RecurringJournalLine(db.Model):
    """
    خط قيد دوري - يمثل سطر واحد في قالب القيد الدوري
    """
    __tablename__ = 'recurring_journal_line'
    
    id = Column(Integer, primary_key=True)
    template_id = Column(Integer, ForeignKey('recurring_journal_template.id'), nullable=False)
    account_id = Column(Integer, ForeignKey('account.id'), nullable=False)
    
    # الأرصدة النقدية
    cash_debit = Column(Float, default=0.0)
    cash_credit = Column(Float, default=0.0)
    
    # أرصدة الذهب حسب العيار
    debit_18k = Column(Float, default=0.0)
    credit_18k = Column(Float, default=0.0)
    debit_21k = Column(Float, default=0.0)
    credit_21k = Column(Float, default=0.0)
    debit_22k = Column(Float, default=0.0)
    credit_22k = Column(Float, default=0.0)
    debit_24k = Column(Float, default=0.0)
    credit_24k = Column(Float, default=0.0)
    
    # العلاقة مع الحساب
    account = relationship('Account', foreign_keys=[account_id])
    
    def to_dict(self):
        """تحويل خط القيد إلى قاموس"""
        return {
            'id': self.id,
            'account_id': self.account_id,
            'account_name': self.account.name if self.account else None,
            'cash_debit': self.cash_debit,
            'cash_credit': self.cash_credit,
            'debit_18k': self.debit_18k,
            'credit_18k': self.credit_18k,
            'debit_21k': self.debit_21k,
            'credit_21k': self.credit_21k,
            'debit_22k': self.debit_22k,
            'credit_22k': self.credit_22k,
            'debit_24k': self.debit_24k,
            'credit_24k': self.credit_24k,
        }


# إضافة حقل للربط بالقيد الأصلي في جدول JournalEntry
# هذا يتطلب إضافة migration
# JournalEntry.recurring_template_id = Column(Integer, ForeignKey('recurring_journal_template.id'))


def process_recurring_journals(check_date=None):
    """
    معالجة جميع القيود الدورية النشطة وإنشاء القيود اللازمة
    
    Args:
        check_date: التاريخ المراد التحقق منه (افتراضياً: اليوم)
    
    Returns:
        قائمة بالقيود المنشأة
    """
    if check_date is None:
        check_date = datetime.now()
    
    # جلب جميع القوالب النشطة
    templates = RecurringJournalTemplate.query.filter_by(
        is_active=True,
        auto_create=True
    ).all()
    
    created_entries = []
    
    for template in templates:
        # التحقق من ضرورة إنشاء قيد
        while template.should_create_entry(check_date):
            try:
                entry = template.create_journal_entry()
                created_entries.append(entry)
                print(f"✓ تم إنشاء قيد دوري: {template.name} - رقم القيد: {entry.entry_number}")
            except Exception as e:
                print(f"✗ خطأ في إنشاء قيد دوري {template.name}: {str(e)}")
                db.session.rollback()
                break
    
    return created_entries


def create_recurring_template(name, description, frequency, start_date, 
                             lines_data, interval=1, end_date=None,
                             preferred_day=1, created_by=None):
    """
    إنشاء قالب قيد دوري جديد
    
    Args:
        name: اسم القالب
        description: وصف القالب
        frequency: الفترة (daily, weekly, monthly, quarterly, yearly)
        start_date: تاريخ البداية
        lines_data: قائمة بخطوط القيد (كل خط عبارة عن dict)
        interval: الفترة الزمنية (افتراضياً 1)
        end_date: تاريخ النهاية (اختياري)
        preferred_day: اليوم المفضل من الشهر (للقيود الشهرية)
        created_by: من قام بالإنشاء
    
    Returns:
        القالب المُنشأ
    """
    template = RecurringJournalTemplate(
        name=name,
        description=description,
        frequency=frequency,
        interval=interval,
        start_date=start_date,
        end_date=end_date,
        next_run_date=start_date,
        preferred_day_of_month=preferred_day,
        created_by=created_by
    )
    
    db.session.add(template)
    db.session.flush()
    
    # إضافة خطوط القيد
    for line_data in lines_data:
        line = RecurringJournalLine(
            template_id=template.id,
            account_id=line_data['account_id'],
            cash_debit=line_data.get('cash_debit', 0.0),
            cash_credit=line_data.get('cash_credit', 0.0),
            debit_18k=line_data.get('debit_18k', 0.0),
            credit_18k=line_data.get('credit_18k', 0.0),
            debit_21k=line_data.get('debit_21k', 0.0),
            credit_21k=line_data.get('credit_21k', 0.0),
            debit_22k=line_data.get('debit_22k', 0.0),
            credit_22k=line_data.get('credit_22k', 0.0),
            debit_24k=line_data.get('debit_24k', 0.0),
            credit_24k=line_data.get('credit_24k', 0.0),
        )
        db.session.add(line)
    
    db.session.commit()
    
    return template


# مثال على الاستخدام:
"""
# إنشاء قالب راتب شهري
from datetime import datetime
from backend.recurring_journal_system import create_recurring_template

lines = [
    {
        'account_id': 101,  # حساب الرواتب (مصروف)
        'cash_debit': 10000.0,
        'cash_credit': 0.0
    },
    {
        'account_id': 201,  # حساب الصندوق
        'cash_debit': 0.0,
        'cash_credit': 10000.0
    }
]

template = create_recurring_template(
    name='راتب موظفي المحل',
    description='رواتب الموظفين الشهرية',
    frequency='monthly',
    start_date=datetime(2025, 11, 1),
    lines_data=lines,
    interval=1,  # كل شهر
    preferred_day=25,  # يوم 25 من كل شهر
    created_by='admin'
)

print(f"تم إنشاء القالب: {template.name}")
print(f"التاريخ القادم للتنفيذ: {template.next_run_date}")
"""
