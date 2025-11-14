# ✅ إضافة إعداد سير عمل السندات - مكتمل

## التحديثات المنفذة

### 1. نموذج البيانات (models.py)
```python
# إعدادات السندات
voucher_auto_post = db.Column(db.Boolean, default=False)
```
- ✅ إضافة حقل جديد في Settings model
- ✅ تحديث to_dict() لتضمين الحقل

### 2. API Endpoints (routes.py)

#### create_voucher():
```python
settings = Settings.query.first()
voucher_auto_post = settings.voucher_auto_post if settings else False

if voucher_auto_post:
    # ترحيل تلقائي - إنشاء القيد المحاسبي مباشرة
    journal_entry = create_journal_entry_from_voucher(voucher)
    voucher.status = 'approved'
else:
    # حفظ بحالة pending - يحتاج اعتماد
    pass
```

#### approve_voucher():
```python
if not voucher.journal_entry_id:
    # إنشاء القيد المحاسبي عند الاعتماد
    journal_entry = create_journal_entry_from_voucher(voucher)
    voucher.journal_entry_id = journal_entry.id
```

### 3. قاعدة البيانات
```bash
✅ Column added: voucher_auto_post BOOLEAN DEFAULT 0
✅ Current value: 0 (False) - يتطلب اعتماد قبل الترحيل
```

---

## الخيارات المتاحة

| الإعداد | القيمة | السلوك |
|---------|--------|---------|
| **الاعتماد قبل الترحيل** (افتراضي) | `false` | حفظ → اعتماد → ترحيل |
| **الترحيل التلقائي** | `true` | حفظ = اعتماد + ترحيل |

---

## الاستخدام

### تحديث الإعداد:
```bash
PUT /api/settings
{
  "voucher_auto_post": true  # أو false
}
```

### الحصول على الإعداد:
```bash
GET /api/settings
# ستجد: "voucher_auto_post": false
```

---

## الاختبار

### 1️⃣ اختبار الوضع الافتراضي (pending → approve)
```bash
# إنشاء سند
POST /api/vouchers {...}
# النتيجة: status = 'pending', journal_entry_id = null

# اعتماد السند
POST /api/vouchers/1/approve
# النتيجة: status = 'approved', journal_entry_id = 123
```

### 2️⃣ اختبار الترحيل التلقائي
```bash
# تفعيل الترحيل التلقائي
PUT /api/settings {"voucher_auto_post": true}

# إنشاء سند
POST /api/vouchers {...}
# النتيجة: status = 'approved', journal_entry_id = 124 (فوراً!)
```

---

## ملفات التوثيق

📄 **VOUCHER_WORKFLOW_SETTING.md** - دليل شامل ومفصل

---

## التحقق

```bash
# 1. التأكد من وجود العمود
sqlite3 app.db "PRAGMA table_info(settings);" | grep voucher
# النتيجة: 19|voucher_auto_post|BOOLEAN|0|0|0

# 2. التأكد من القيمة الحالية
sqlite3 app.db "SELECT voucher_auto_post FROM settings WHERE id=1;"
# النتيجة: 0 (False - افتراضي)

# 3. التحقق من الكود
python3 -m py_compile models.py routes.py
# النتيجة: ✅ لا أخطاء
```

---

## الخطوات القادمة (Frontend)

- [ ] إضافة toggle في شاشة الإعدادات
- [ ] إظهار حالة السند (pending/approved) في القائمة
- [ ] إضافة زر "اعتماد" للسندات pending
- [ ] تحديث UI حسب حالة السند

---

**الحالة:** ✅ جاهز للاستخدام  
**التاريخ:** 2025-01-22  
**Backend:** ✅ مكتمل  
**Frontend:** ⏳ قادم
