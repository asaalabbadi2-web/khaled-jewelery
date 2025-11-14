# نظام الخزائن (SafeBox System)

## نظرة عامة
نظام إدارة الخزائن يوفر طريقة منظمة لإدارة جميع الخزائن (النقدية، البنكية، الذهبية) وربطها بالحسابات المحاسبية.

## المميزات
- ✅ تصنيف الخزائن حسب النوع (cash, bank, gold, check)
- ✅ ربط كل خزينة بحساب محاسبي محدد
- ✅ تحديد خزينة افتراضية لكل نوع
- ✅ دعم معلومات البنوك (IBAN, SWIFT, الفرع)
- ✅ دعم الخزائن الذهبية حسب العيار (18, 21, 22, 24)
- ✅ عرض الأرصدة مباشرة من الحساب المرتبط

## أنواع الخزائن

### 1. خزائن نقدية (cash)
```json
{
  "name": "صندوق النقدية الرئيسي",
  "safe_type": "cash",
  "account_id": 15,
  "is_default": true
}
```

### 2. خزائن بنكية (bank)
```json
{
  "name": "بنك الرياض",
  "safe_type": "bank",
  "account_id": 16,
  "bank_name": "بنك الرياض",
  "iban": "SA...",
  "swift_code": "RIBLSARI",
  "branch": "فرع الرياض",
  "is_default": true
}
```

### 3. خزائن ذهبية (gold)
```json
{
  "name": "صندوق الذهب عيار 21",
  "safe_type": "gold",
  "account_id": 24,
  "karat": 21,
  "is_default": true
}
```

### 4. خزائن شيكات (check)
```json
{
  "name": "صندوق الشيكات",
  "safe_type": "check",
  "account_id": 19
}
```

## API Endpoints

### 1. الحصول على جميع الخزائن
```bash
GET /api/safe-boxes
GET /api/safe-boxes?safe_type=bank
GET /api/safe-boxes?is_active=true
GET /api/safe-boxes?include_balance=true
GET /api/safe-boxes?karat=21
```

**مثال:**
```bash
curl "http://127.0.0.1:8001/api/safe-boxes?safe_type=bank&include_balance=true"
```

**الاستجابة:**
```json
[
  {
    "id": 2,
    "name": "بنك الرياض",
    "safe_type": "bank",
    "account_id": 16,
    "bank_name": "بنك الرياض",
    "is_default": true,
    "is_active": true,
    "balance": {
      "cash": 12500.50
    }
  }
]
```

### 2. الحصول على خزينة محددة
```bash
GET /api/safe-boxes/{id}
```

### 3. إنشاء خزينة جديدة
```bash
POST /api/safe-boxes
Content-Type: application/json

{
  "name": "صندوق الكسر",
  "name_en": "Scrap Gold Box",
  "safe_type": "gold",
  "account_id": 25,
  "karat": 24,
  "is_default": false,
  "is_active": true,
  "notes": "صندوق الذهب الكسر للبيع"
}
```

### 4. تحديث خزينة
```bash
PUT /api/safe-boxes/{id}
Content-Type: application/json

{
  "name": "صندوق النقدية - الفرع الرئيسي",
  "is_default": true
}
```

### 5. حذف خزينة
```bash
DELETE /api/safe-boxes/{id}
```

### 6. الحصول على الخزينة الافتراضية حسب النوع
```bash
GET /api/safe-boxes/default/{safe_type}
```

**مثال:**
```bash
curl http://127.0.0.1:8001/api/safe-boxes/default/cash
```

### 7. الحصول على خزينة الذهب حسب العيار
```bash
GET /api/safe-boxes/gold/{karat}
```

**مثال:**
```bash
curl http://127.0.0.1:8001/api/safe-boxes/gold/21
```

## الدمج مع الأنظمة الأخرى

### 1. نظام الرواتب
تم تحديث endpoint `/api/payroll/payment-accounts` ليستخدم نظام الخزائن:

```javascript
// قبل (يعرض جميع الحسابات)
GET /api/payroll/payment-accounts
// يعرض: 100+ حساب محاسبي

// بعد (يعرض الخزائن فقط)
GET /api/payroll/payment-accounts
// يعرض: 4 خزائن فقط (نقدية + 3 بنوك)
```

**مثال الاستجابة:**
```json
[
  {
    "id": 16,
    "safe_box_id": 2,
    "name": "بنك الرياض",
    "type": "bank",
    "bank_name": "بنك الرياض",
    "is_default": true
  },
  {
    "id": 15,
    "safe_box_id": 1,
    "name": "صندوق النقدية الرئيسي",
    "type": "cash",
    "is_default": true
  }
]
```

### 2. سندات الصرف والقبض
يمكن استخدام نظام الخزائن لتحديد مصدر/وجهة الأموال في السندات:

```python
# الحصول على الخزينة الافتراضية للنقدية
cash_safe = SafeBox.get_default_by_type('cash')
account_id = cash_safe.account_id

# إنشاء سند صرف
voucher = Voucher(
    voucher_type='صرف',
    ...
)
```

### 3. الفواتير
عند تحديد طريقة الدفع في الفاتورة، يمكن اختيار الخزينة:

```python
# الحصول على خزينة بنكية
bank_safe = SafeBox.query.get(2)  # بنك الرياض
payment_account_id = bank_safe.account_id
```

## الخزائن الافتراضية المُنشأة

عند تشغيل `seed_safe_boxes.py`، يتم إنشاء:

### خزائن نقدية (1)
- ⭐ صندوق النقدية الرئيسي (افتراضي)

### خزائن بنكية (3)
- ⭐ بنك الرياض (افتراضي)
- مصرف الراجحي
- البنك الأهلي

### خزائن ذهبية (4)
- صندوق الذهب عيار 18
- ⭐ صندوق الذهب عيار 21 (افتراضي)
- صندوق الذهب عيار 22
- صندوق الكسر عيار 24

## أفضل الممارسات

### 1. تسمية الخزائن
- استخدم أسماء واضحة ومحددة
- أضف الترجمة الإنجليزية في `name_en`
- مثال: "صندوق النقدية - الفرع الرئيسي"

### 2. الخزينة الافتراضية
- حدد خزينة افتراضية واحدة فقط لكل نوع
- النظام يلغي التفعيل التلقائي للخزائن الأخرى عند تحديد افتراضية جديدة

### 3. معلومات البنوك
- أضف IBAN وSWIFT للخزائن البنكية
- سجل اسم الفرع للمرجع

### 4. الخزائن الذهبية
- أنشئ خزينة منفصلة لكل عيار
- اجعل عيار 21 هو الافتراضي (العيار الرئيسي في السعودية)

### 5. التتبع
- استخدم `created_by` لتسجيل من أنشأ الخزينة
- أضف ملاحظات توضيحية في `notes`

## أمثلة عملية

### مثال 1: إنشاء خزينة بنك جديدة
```bash
curl -X POST http://127.0.0.1:8001/api/safe-boxes \
  -H "Content-Type: application/json" \
  -d '{
    "name": "بنك الأهلي - فرع الملك فهد",
    "name_en": "Al Ahli Bank - King Fahd Branch",
    "safe_type": "bank",
    "account_id": 18,
    "bank_name": "البنك الأهلي التجاري",
    "iban": "SA0380000000608010167519",
    "swift_code": "NCBKSAJE",
    "branch": "فرع الملك فهد",
    "is_active": true,
    "is_default": false,
    "notes": "حساب بنكي للمعاملات اليومية",
    "created_by": "admin"
  }'
```

### مثال 2: الحصول على جميع الخزائن البنكية النشطة
```bash
curl "http://127.0.0.1:8001/api/safe-boxes?safe_type=bank&is_active=true&include_balance=true"
```

### مثال 3: تحديث خزينة لتصبح افتراضية
```bash
curl -X PUT http://127.0.0.1:8001/api/safe-boxes/3 \
  -H "Content-Type: application/json" \
  -d '{
    "is_default": true
  }'
```

### مثال 4: الحصول على خزينة الذهب عيار 24
```bash
curl http://127.0.0.1:8001/api/safe-boxes/gold/24
```

## الفوائد

1. **تنظيم أفضل**: فصل واضح بين أنواع الخزائن
2. **سهولة الاستخدام**: اختيار من قائمة محددة بدلاً من مئات الحسابات
3. **مرونة**: إضافة/تعديل/حذف الخزائن بسهولة
4. **تتبع دقيق**: معرفة مصدر/وجهة كل عملية مالية
5. **معلومات إضافية**: IBAN، SWIFT، العيار، إلخ
6. **أرصدة مباشرة**: عرض الرصيد مباشرة من الحساب المرتبط

## الخطوات التالية

- [ ] إضافة واجهة Flutter لإدارة الخزائن
- [ ] دمج مع نظام السندات (اختيار الخزينة في سندات الصرف/القبض)
- [ ] دمج مع نظام الفواتير (اختيار الخزينة عند الدفع)
- [ ] تقارير حركة الخزائن (الإيداعات/السحوبات)
- [ ] صلاحيات الوصول للخزائن (من يمكنه الصرف من كل خزينة)
