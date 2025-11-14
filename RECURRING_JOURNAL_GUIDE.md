# دليل نظام القيود الدورية
## Recurring Journal Entries System Guide

---

## 📋 المحتويات
1. [نظرة عامة](#نظرة-عامة)
2. [الفرق بين القيد العادي والدوري](#الفرق-بين-القيد-العادي-والدوري)
3. [إعداد النظام](#إعداد-النظام)
4. [أمثلة عملية](#أمثلة-عملية)
5. [استخدام API](#استخدام-api)
6. [الجدولة التلقائية](#الجدولة-التلقائية)

---

## 🎯 نظرة عامة

نظام القيود الدورية يسمح بإنشاء قيود محاسبية متكررة تلقائياً حسب جدول زمني محدد، مثل:
- **الرواتب الشهرية**
- **الإيجار**
- **فواتير الخدمات**
- **الاستهلاك الدوري**
- **أقساط التأمين**

---

## 📊 الفرق بين القيد العادي والدوري

### القيد العادي (Regular Entry)

| الخاصية | الوصف |
|---------|-------|
| **التكرار** | مرة واحدة فقط |
| **الإنشاء** | يدوي أو تلقائي مع العملية |
| **التوقيت** | عند حدوث العملية مباشرة |
| **الاستخدام** | فواتير البيع/الشراء، الدفعات اليومية |
| **الربط** | مرتبط بمستند محدد (فاتورة، سند) |

**مثال**: قيد فاتورة بيع ذهب لعميل اليوم

```json
{
  "entry_type": "عادي",
  "date": "2025-11-07",
  "description": "بيع ذهب للعميل محمد أحمد",
  "reference_type": "invoice",
  "reference_id": 123
}
```

### القيد الدوري (Recurring Entry)

| الخاصية | الوصف |
|---------|-------|
| **التكرار** | يتكرر حسب جدول (يومي، أسبوعي، شهري، إلخ) |
| **الإنشاء** | تلقائي من قالب Template |
| **التوقيت** | حسب الجدول المحدد |
| **الاستخدام** | المصروفات والإيرادات المتكررة |
| **الربط** | مرتبط بقالب دوري |

**مثال**: قيد راتب الموظفين الشهري

```json
{
  "entry_type": "دوري",
  "frequency": "monthly",
  "interval": 1,
  "preferred_day_of_month": 25,
  "start_date": "2025-11-01",
  "auto_create": true
}
```

### أنواع القيود المدعومة في النظام

1. **عادي** (Regular): القيود اليومية العادية
2. **دوري** (Recurring): القيود المتكررة التلقائية
3. **افتتاحي** (Opening): قيد افتتاح الفترة المالية
4. **إقفال** (Closing): قيد إقفال نهاية الفترة

---

## ⚙️ إعداد النظام

### 1. تطبيق الـ Migration

```bash
cd backend
source venv/bin/activate
alembic upgrade head
```

### 2. استيراد النماذج في `app.py`

تأكد من إضافة الاستيراد في ملف `backend/app.py`:

```python
# في بداية الملف
from backend.recurring_journal_system import (
    RecurringJournalTemplate, 
    RecurringJournalLine
)

# استيراد الـ routes
import backend.recurring_journal_routes
```

### 3. التحقق من التثبيت

```python
from backend.models import db
from backend.recurring_journal_system import RecurringJournalTemplate

# التحقق من وجود الجدول
templates = RecurringJournalTemplate.query.all()
print(f"عدد القوالب: {len(templates)}")
```

---

## 💡 أمثلة عملية

### مثال 1: راتب موظفي المحل (شهري)

```python
from datetime import datetime
from backend.recurring_journal_system import create_recurring_template

# تحديد خطوط القيد
lines = [
    {
        'account_id': 510,  # حساب الرواتب والأجور (مصروف)
        'cash_debit': 15000.0,  # 15,000 ريال
        'cash_credit': 0.0
    },
    {
        'account_id': 101,  # حساب الصندوق
        'cash_debit': 0.0,
        'cash_credit': 15000.0
    }
]

# إنشاء القالب
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

print(f"✓ تم إنشاء القالب بنجاح")
print(f"التاريخ القادم: {template.next_run_date}")
```

### مثال 2: إيجار المحل (شهري)

```python
lines = [
    {
        'account_id': 520,  # حساب الإيجار (مصروف)
        'cash_debit': 5000.0,
        'cash_credit': 0.0
    },
    {
        'account_id': 101,  # الصندوق
        'cash_debit': 0.0,
        'cash_credit': 5000.0
    }
]

template = create_recurring_template(
    name='إيجار المحل',
    description='إيجار شهري لمحل الذهب',
    frequency='monthly',
    start_date=datetime(2025, 11, 1),
    lines_data=lines,
    interval=1,
    preferred_day=1,  # أول يوم من الشهر
    created_by='admin'
)
```

### مثال 3: استهلاك الأصول (سنوي)

```python
lines = [
    {
        'account_id': 530,  # حساب مصروف الاستهلاك
        'cash_debit': 10000.0,
        'cash_credit': 0.0
    },
    {
        'account_id': 150,  # حساب مجمع الاستهلاك
        'cash_debit': 0.0,
        'cash_credit': 10000.0
    }
]

template = create_recurring_template(
    name='استهلاك الأصول',
    description='استهلاك سنوي للأصول الثابتة',
    frequency='yearly',
    start_date=datetime(2025, 12, 31),  # نهاية السنة
    end_date=datetime(2030, 12, 31),  # مدة 5 سنوات
    lines_data=lines,
    interval=1,
    created_by='admin'
)
```

### مثال 4: فاتورة خدمات (شهري)

```python
lines = [
    {
        'account_id': 540,  # حساب الكهرباء والماء
        'cash_debit': 800.0,
        'cash_credit': 0.0
    },
    {
        'account_id': 101,  # الصندوق
        'cash_debit': 0.0,
        'cash_credit': 800.0
    }
]

template = create_recurring_template(
    name='فواتير الخدمات',
    description='كهرباء، ماء، إنترنت',
    frequency='monthly',
    start_date=datetime(2025, 11, 1),
    lines_data=lines,
    interval=1,
    preferred_day=15,
    created_by='admin'
)
```

---

## 🔌 استخدام API

### 1. جلب جميع القوالب

```bash
GET /api/recurring_templates
```

**Response:**
```json
[
  {
    "id": 1,
    "name": "راتب موظفي المحل",
    "description": "رواتب الموظفين الشهرية",
    "frequency": "monthly",
    "frequency_text": "شهري",
    "interval": 1,
    "start_date": "2025-11-01T00:00:00",
    "next_run_date": "2025-11-25T00:00:00",
    "preferred_day_of_month": 25,
    "is_active": true,
    "auto_create": true,
    "total_created": 0,
    "lines": [...]
  }
]
```

### 2. إنشاء قالب جديد

```bash
POST /api/recurring_templates
Content-Type: application/json

{
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
}
```

### 3. تفعيل/تعطيل قالب

```bash
POST /api/recurring_templates/1/toggle_active
```

**Response:**
```json
{
  "message": "تم التفعيل بنجاح",
  "is_active": true
}
```

### 4. إنشاء قيد يدوياً من قالب

```bash
POST /api/recurring_templates/1/create_entry
```

**Response:**
```json
{
  "message": "تم إنشاء القيد بنجاح",
  "entry": {
    "id": 456,
    "entry_number": "JE-2025-11-001",
    "date": "2025-11-25T00:00:00",
    "description": "رواتب الموظفين الشهرية (دوري - راتب موظفي المحل)"
  }
}
```

### 5. معالجة جميع القيود المستحقة

```bash
POST /api/recurring_templates/process_all
```

**Response:**
```json
{
  "message": "تم إنشاء 3 قيد بنجاح",
  "entries": [
    {
      "id": 456,
      "entry_number": "JE-2025-11-001",
      "date": "2025-11-25T00:00:00",
      "description": "رواتب الموظفين الشهرية (دوري)"
    },
    ...
  ]
}
```

### 6. الحصول على عدد القيود المستحقة

```bash
GET /api/recurring_templates/due_count
```

**Response:**
```json
{
  "due_count": 3,
  "due_templates": [
    {
      "id": 1,
      "name": "راتب موظفي المحل",
      "next_run_date": "2025-11-25T00:00:00"
    },
    ...
  ]
}
```

---

## ⏰ الجدولة التلقائية

### استخدام Cron Job (Linux/Mac)

قم بإنشاء سكريبت Python للمعالجة التلقائية:

**ملف: `process_recurring.py`**
```python
#!/usr/bin/env python3
from backend.recurring_journal_system import process_recurring_journals
from backend.models import db
from backend import create_app

app = create_app()

with app.app_context():
    created = process_recurring_journals()
    print(f"تم إنشاء {len(created)} قيد دوري")
```

**إضافة Cron Job:**
```bash
# تشغيل يومياً في الساعة 1 صباحاً
crontab -e

# أضف السطر التالي:
0 1 * * * cd /path/to/yasargold/backend && source venv/bin/activate && python process_recurring.py
```

### استخدام Task Scheduler (Windows)

1. افتح Task Scheduler
2. Create Basic Task
3. اسم المهمة: "Process Recurring Journals"
4. Trigger: Daily at 01:00
5. Action: Start a Program
   - Program: `python.exe`
   - Arguments: `C:\path\to\yasargold\backend\process_recurring.py`
   - Start in: `C:\path\to\yasargold\backend`

### استخدام Flask-APScheduler (الموصى به)

**تثبيت:**
```bash
pip install flask-apscheduler
```

**في `app.py`:**
```python
from flask_apscheduler import APScheduler
from backend.recurring_journal_system import process_recurring_journals

scheduler = APScheduler()

def scheduled_recurring_processing():
    """وظيفة معالجة القيود الدورية"""
    with app.app_context():
        try:
            created = process_recurring_journals()
            print(f"[Scheduler] تم إنشاء {len(created)} قيد دوري")
        except Exception as e:
            print(f"[Scheduler] خطأ: {str(e)}")

if __name__ == '__main__':
    # تكوين الجدولة
    scheduler.init_app(app)
    scheduler.start()
    
    # إضافة وظيفة يومية
    scheduler.add_job(
        id='process_recurring',
        func=scheduled_recurring_processing,
        trigger='cron',
        hour=1,  # الساعة 1 صباحاً
        minute=0
    )
    
    app.run(debug=True, port=8001)
```

---

## 📊 أنواع الفترات المدعومة

| النوع | القيمة | الوصف | مثال |
|------|--------|-------|------|
| يومي | `daily` | كل يوم/أيام | كل 3 أيام |
| أسبوعي | `weekly` | كل أسبوع/أسابيع | كل أسبوعين |
| شهري | `monthly` | كل شهر/أشهر | كل شهر بتاريخ 25 |
| ربع سنوي | `quarterly` | كل 3 أشهر | كل ربع سنة |
| سنوي | `yearly` | كل سنة/سنوات | كل سنة |

---

## ✅ الخلاصة

### ما تم إضافته:
1. ✓ نموذج `RecurringJournalTemplate` للقوالب
2. ✓ نموذج `RecurringJournalLine` لخطوط القوالب
3. ✓ إضافة حقل `recurring_template_id` للقيود
4. ✓ دوال معالجة وإنشاء تلقائي
5. ✓ API endpoints كاملة
6. ✓ Migration للجداول الجديدة
7. ✓ إصلاح عرض `entry_type` في قائمة القيود

### الخطوات التالية:
1. تطبيق Migration: `alembic upgrade head`
2. إضافة imports في `app.py`
3. اختبار إنشاء قالب دوري
4. إعداد الجدولة التلقائية
5. إنشاء واجهة Flutter للقيود الدورية (اختياري)

---

## 🆘 حل المشاكل

### المشكلة: لا يظهر نوع القيد بعد الحفظ
**الحل**: تم إصلاحها! الآن API يرسل `entry_type` مع البيانات.

### المشكلة: القيود لا تُنشأ تلقائياً
**الحل**: تأكد من:
1. القالب نشط (`is_active = True`)
2. الإنشاء التلقائي مفعّل (`auto_create = True`)
3. التاريخ القادم قد حان (`next_run_date <= now`)
4. Scheduler يعمل

### المشكلة: خطأ في Migration
**الحل**:
```bash
# حذف الـ migration وإعادة إنشائها
alembic downgrade -1
alembic upgrade head
```

---

**تم بحمد الله! 🎉**
