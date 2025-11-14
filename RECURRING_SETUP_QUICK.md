# إعداد نظام القيود الدورية - دليل سريع
## Quick Setup Guide for Recurring Journal Entries

---

## 🚀 خطوات الإعداد السريعة

### 1. تطبيق قاعدة البيانات

```bash
cd backend
source venv/bin/activate
alembic upgrade head
```

### 2. تحديث ملف `app.py`

أضف هذه الأسطر في بداية `backend/app.py`:

```python
# استيراد نماذج القيود الدورية
from backend.recurring_journal_system import (
    RecurringJournalTemplate, 
    RecurringJournalLine
)

# استيراد routes القيود الدورية
import backend.recurring_journal_routes
```

### 3. إعادة تشغيل Backend

```bash
python app.py
```

### 4. اختبار النظام

```bash
# اختبار API
curl http://localhost:8001/api/recurring_templates

# يجب أن ترى: []  (قائمة فارغة)
```

---

## ✅ التحقق من التثبيت

### اختبار Python

```python
from backend.models import db
from backend.recurring_journal_system import RecurringJournalTemplate
from app import app

with app.app_context():
    count = RecurringJournalTemplate.query.count()
    print(f"✓ النظام يعمل! عدد القوالب: {count}")
```

### اختبار API

```bash
# جلب القوالب
curl http://localhost:8001/api/recurring_templates

# جلب عدد القيود المستحقة
curl http://localhost:8001/api/recurring_templates/due_count
```

---

## 📝 إنشاء أول قالب (مثال: راتب شهري)

### عبر Python

```python
from datetime import datetime
from backend.recurring_journal_system import create_recurring_template
from app import app

with app.app_context():
    lines = [
        {
            'account_id': 510,  # حساب الرواتب (عدّله حسب نظامك)
            'cash_debit': 15000.0,
            'cash_credit': 0.0
        },
        {
            'account_id': 101,  # حساب الصندوق
            'cash_debit': 0.0,
            'cash_credit': 15000.0
        }
    ]
    
    template = create_recurring_template(
        name='راتب موظفي المحل',
        description='رواتب الموظفين الشهرية',
        frequency='monthly',
        start_date=datetime(2025, 11, 1),
        lines_data=lines,
        interval=1,
        preferred_day=25,
        created_by='admin'
    )
    
    print(f"✓ تم إنشاء القالب: {template.id}")
    print(f"  التاريخ القادم: {template.next_run_date}")
```

### عبر API (curl)

```bash
curl -X POST http://localhost:8001/api/recurring_templates \
  -H "Content-Type: application/json" \
  -d '{
    "name": "راتب موظفي المحل",
    "description": "رواتب الموظفين الشهرية",
    "frequency": "monthly",
    "interval": 1,
    "start_date": "2025-11-01T00:00:00",
    "preferred_day_of_month": 25,
    "lines": [
      {
        "account_id": 510,
        "cash_debit": 15000.0,
        "cash_credit": 0.0
      },
      {
        "account_id": 101,
        "cash_debit": 0.0,
        "cash_credit": 15000.0
      }
    ]
  }'
```

---

## ⏰ إعداد الجدولة التلقائية

### الطريقة 1: Cron Job (Linux/Mac) - الموصى به

```bash
# تحرير crontab
crontab -e

# أضف هذا السطر (تشغيل يومياً الساعة 1 صباحاً)
0 1 * * * cd /Users/salehalabbadi/yasargold/backend && source venv/bin/activate && python process_recurring_journals.py >> /tmp/recurring_journals.log 2>&1
```

### الطريقة 2: Flask-APScheduler (داخل التطبيق)

```bash
# تثبيت
pip install flask-apscheduler
```

أضف في `app.py`:

```python
from flask_apscheduler import APScheduler
from backend.recurring_journal_system import process_recurring_journals

scheduler = APScheduler()

def scheduled_recurring_processing():
    with app.app_context():
        try:
            created = process_recurring_journals()
            print(f"[Scheduler] تم إنشاء {len(created)} قيد دوري")
        except Exception as e:
            print(f"[Scheduler] خطأ: {str(e)}")

if __name__ == '__main__':
    # تفعيل الجدولة
    scheduler.init_app(app)
    scheduler.start()
    
    # إضافة وظيفة يومية
    scheduler.add_job(
        id='process_recurring',
        func=scheduled_recurring_processing,
        trigger='cron',
        hour=1,
        minute=0
    )
    
    app.run(debug=True, port=8001)
```

### الطريقة 3: معالجة يدوية

```bash
cd backend
source venv/bin/activate
python process_recurring_journals.py
```

---

## 🧪 اختبار النظام

### 1. إنشاء قيد يدوياً من قالب

```bash
# افترض أن القالب رقمه 1
curl -X POST http://localhost:8001/api/recurring_templates/1/create_entry
```

### 2. معالجة جميع القيود المستحقة

```bash
curl -X POST http://localhost:8001/api/recurring_templates/process_all
```

### 3. التحقق من القيد المُنشأ

```bash
curl http://localhost:8001/api/journal_entries | grep "دوري"
```

---

## 📊 API Endpoints المتاحة

| Method | Endpoint | الوصف |
|--------|----------|-------|
| GET | `/api/recurring_templates` | جلب جميع القوالب |
| POST | `/api/recurring_templates` | إنشاء قالب جديد |
| GET | `/api/recurring_templates/:id` | جلب قالب محدد |
| PUT | `/api/recurring_templates/:id` | تحديث قالب |
| DELETE | `/api/recurring_templates/:id` | حذف قالب |
| POST | `/api/recurring_templates/:id/toggle_active` | تفعيل/تعطيل قالب |
| POST | `/api/recurring_templates/:id/create_entry` | إنشاء قيد يدوياً |
| POST | `/api/recurring_templates/process_all` | معالجة جميع القيود المستحقة |
| GET | `/api/recurring_templates/due_count` | عدد القيود المستحقة |

---

## 🐛 حل المشاكل الشائعة

### المشكلة: خطأ في Migration

```bash
# الحل: إعادة تطبيق
cd backend
alembic downgrade -1
alembic upgrade head
```

### المشكلة: لا يظهر entry_type في القيود

✅ **تم الإصلاح!** الآن API يرسل نوع القيد مع البيانات.

### المشكلة: القيود لا تُنشأ تلقائياً

تحقق من:
- [ ] القالب نشط: `is_active = true`
- [ ] الإنشاء التلقائي مفعّل: `auto_create = true`
- [ ] التاريخ القادم قد حان: `next_run_date <= now`
- [ ] Cron Job أو Scheduler يعمل

### المشكلة: خطأ في استيراد النماذج

تأكد من إضافة imports في `app.py`:

```python
from backend.recurring_journal_system import (
    RecurringJournalTemplate, 
    RecurringJournalLine
)
import backend.recurring_journal_routes
```

---

## 📖 المزيد من التفاصيل

اطلع على الدليل الكامل: [RECURRING_JOURNAL_GUIDE.md](RECURRING_JOURNAL_GUIDE.md)

---

## ✅ Checklist

- [ ] تطبيق Migration (`alembic upgrade head`)
- [ ] تحديث `app.py` بالـ imports
- [ ] إعادة تشغيل Backend
- [ ] اختبار API (`curl http://localhost:8001/api/recurring_templates`)
- [ ] إنشاء قالب تجريبي
- [ ] اختبار إنشاء قيد يدوي
- [ ] إعداد Cron Job أو Scheduler
- [ ] اختبار المعالجة التلقائية

---

**جاهز! 🎉**

في حالة وجود أي مشاكل، راجع: [RECURRING_JOURNAL_GUIDE.md](RECURRING_JOURNAL_GUIDE.md)
