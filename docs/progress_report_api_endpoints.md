# تقرير التقدم - API Endpoints للفواتير والمرتجعات

**التاريخ:** 10 أكتوبر 2025  
**المرحلة:** Backend - API Endpoints

---

## ✅ ما تم إنجازه

### 1. تحديث POST /api/invoices (مكتمل ✓)

#### الحقول الجديدة المدعومة:

```python
new_invoice = Invoice(
    # ... الحقول الموجودة
    original_invoice_id=data.get('original_invoice_id'),  # 🆕
    return_reason=data.get('return_reason'),                # 🆕
    gold_type=gold_type                                     # 🆕
)
```

#### Validation Rules المضافة:

##### 1. **للمرتجعات:**

```python
return_types = ['مرتجع بيع', 'مرتجع شراء', 'مرتجع شراء (مورد)']
if invoice_type in return_types:
    # ✓ التحقق من وجود original_invoice_id
    if not data.get('original_invoice_id'):
        return 400 Error
    
    # ✓ التحقق من وجود الفاتورة الأصلية
    original_invoice = Invoice.query.get(data['original_invoice_id'])
    if not original_invoice:
        return 404 Error
    
    # ✓ التحقق من تطابق العميل/المورد
    if invoice_type == 'مرتجع بيع':
        customer_id must match original
    elif invoice_type == 'مرتجع شراء':
        customer_id must match original
    elif invoice_type == 'مرتجع شراء (مورد)':
        supplier_id must match original
```

##### 2. **لنوع الذهب:**

```python
gold_type = data.get('gold_type', 'new')
if gold_type not in ['new', 'scrap']:
    return 400 Error
```

---

### 2. تحديث GET /api/invoices (مكتمل ✓)

#### الحقول الجديدة في الـ Response:

```json
{
  "invoices": [
    {
      "id": 1,
      "invoice_type": "بيع",
      ...
      "original_invoice_id": null,      // 🆕
      "return_reason": null,            // 🆕
      "gold_type": "new",               // 🆕
      "items": [...]
    }
  ]
}
```

---

### 3. Endpoints جديدة للمرتجعات (مكتمل ✓)

#### Endpoint 1: GET /api/invoices/<id>/returns

**الغرض:** الحصول على جميع المرتجعات المرتبطة بفاتورة معينة

**Request:**
```http
GET /api/invoices/123/returns
```

**Response:**
```json
{
  "original_invoice": {
    "id": 123,
    "invoice_type_id": 45,
    "invoice_type": "بيع",
    "date": "2025-10-10T10:00:00",
    "total": 10000,
    "status": "paid"
  },
  "returns": [
    {
      "id": 456,
      "invoice_type": "مرتجع بيع",
      "original_invoice_id": 123,
      "return_reason": "عيب في الصنعة",
      "total": 5000,
      "date": "2025-10-15T14:30:00"
    }
  ],
  "total_returns": 1
}
```

---

#### Endpoint 2: GET /api/invoices/<id>/can-return

**الغرض:** التحقق من إمكانية إرجاع فاتورة

**Request:**
```http
GET /api/invoices/123/can-return
```

**Response:**
```json
{
  "can_return": true,
  "invoice_type": "بيع",
  "original_total": 10000,
  "total_returned": 5000,
  "remaining_amount": 5000,
  "existing_returns_count": 1,
  "message": "يمكن إرجاع هذه الفاتورة"
}
```

**Business Logic:**
```python
# الفواتير القابلة للإرجاع
returnable_types = ['بيع', 'شراء من عميل', 'شراء']

# حساب المبلغ المتبقي
total_returned = sum(r.total for r in existing_returns)
remaining_amount = original_total - total_returned
```

---

#### Endpoint 3: GET /api/invoices/returnable

**الغرض:** الحصول على جميع الفواتير القابلة للإرجاع

**Request:**
```http
GET /api/invoices/returnable?invoice_type=بيع&customer_id=5
```

**Query Parameters:**
- `invoice_type` (optional): نوع الفاتورة للفلترة
- `customer_id` (optional): معرف العميل
- `supplier_id` (optional): معرف المورد

**Response:**
```json
{
  "invoices": [
    {
      "id": 123,
      "invoice_type_id": 45,
      "invoice_type": "بيع",
      "date": "2025-10-10T10:00:00",
      "total": 10000,
      "total_returned": 5000,
      "remaining_amount": 5000,
      "can_return": true,
      "customer_name": "أحمد محمد",
      "supplier_name": null,
      "items_count": 3
    },
    {
      "id": 124,
      "invoice_type_id": 46,
      "invoice_type": "بيع",
      "date": "2025-10-09T15:20:00",
      "total": 8000,
      "total_returned": 0,
      "remaining_amount": 8000,
      "can_return": true,
      "customer_name": "أحمد محمد",
      "supplier_name": null,
      "items_count": 2
    }
  ],
  "total_count": 2
}
```

---

## 📊 ملخص التحديثات

### Endpoints المحدثة:

| Endpoint | Method | التحديث | الحالة |
|----------|--------|---------|--------|
| `/api/invoices` | POST | إضافة 3 حقول جديدة + validation | ✅ |
| `/api/invoices` | GET | إضافة الحقول الجديدة للـ response | ✅ |
| `/api/invoices/<id>/returns` | GET | جديد - جلب المرتجعات | ✅ |
| `/api/invoices/<id>/can-return` | GET | جديد - التحقق من إمكانية الإرجاع | ✅ |
| `/api/invoices/returnable` | GET | جديد - الفواتير القابلة للإرجاع | ✅ |

### Validation Rules:

✅ **للمرتجعات:**
- وجود `original_invoice_id` إلزامي
- وجود الفاتورة الأصلية في قاعدة البيانات
- تطابق العميل/المورد مع الفاتورة الأصلية

✅ **لنوع الذهب:**
- القيم المسموحة: `'new'` أو `'scrap'`
- القيمة الافتراضية: `'new'`

---

## 🔄 أمثلة الاستخدام

### مثال 1: إنشاء فاتورة بيع عادية

```json
POST /api/invoices
{
  "invoice_type": "بيع",
  "customer_id": 5,
  "date": "2025-10-10T10:00:00",
  "total": 10000,
  "gold_type": "new",
  "items": [...]
}
```

**Response:** `201 Created`

---

### مثال 2: إنشاء مرتجع بيع

```json
POST /api/invoices
{
  "invoice_type": "مرتجع بيع",
  "customer_id": 5,
  "original_invoice_id": 123,
  "return_reason": "عيب في الصنعة",
  "date": "2025-10-15T14:30:00",
  "total": 5000,
  "gold_type": "new",
  "items": [...]
}
```

**Response:** `201 Created`

---

### مثال 3: محاولة إنشاء مرتجع بدون فاتورة أصلية

```json
POST /api/invoices
{
  "invoice_type": "مرتجع بيع",
  "customer_id": 5,
  "date": "2025-10-15T14:30:00",
  "total": 5000
}
```

**Response:** `400 Bad Request`
```json
{
  "error": "original_invoice_id is required for return invoices"
}
```

---

### مثال 4: محاولة إرجاع فاتورة غير موجودة

```json
POST /api/invoices
{
  "invoice_type": "مرتجع بيع",
  "customer_id": 5,
  "original_invoice_id": 99999,
  "date": "2025-10-15T14:30:00",
  "total": 5000
}
```

**Response:** `404 Not Found`
```json
{
  "error": "Original invoice with ID 99999 not found"
}
```

---

### مثال 5: محاولة إرجاع مع عميل مختلف

```json
POST /api/invoices
{
  "invoice_type": "مرتجع بيع",
  "customer_id": 10,  // العميل الأصلي كان 5
  "original_invoice_id": 123,
  "date": "2025-10-15T14:30:00",
  "total": 5000
}
```

**Response:** `400 Bad Request`
```json
{
  "error": "Customer ID must match original invoice"
}
```

---

## 🎯 الخطوة التالية

### المرحلة القادمة: القيود المحاسبية

يجب تحديث منطق إنشاء القيود اليومية لدعم:

#### 1. **فاتورة بيع:**
```
من حـ/ العميل (أو الصندوق)    [مدين]
    إلى حـ/ المخزون            [دائن]
    إلى حـ/ الإيرادات          [دائن]
```

#### 2. **فاتورة شراء كسر من عميل:**
```
من حـ/ المخزون - كسر          [مدين]
    إلى حـ/ العميل (أو الصندوق) [دائن]
```

#### 3. **مرتجع بيع (عكس البيع):**
```
من حـ/ المخزون                [مدين]
من حـ/ الإيرادات (عكس)        [مدين]
    إلى حـ/ العميل            [دائن]
```

#### 4. **مرتجع شراء كسر (عكس الشراء):**
```
من حـ/ العميل                 [مدين]
    إلى حـ/ المخزون - كسر     [دائن]
```

#### 5. **شراء:**
```
من حـ/ المخزون                [مدين]
    إلى حـ/ المورد            [دائن]
```

#### 6. **مرتجع شراء (مورد):**
```
من حـ/ المورد                 [مدين]
    إلى حـ/ المخزون           [دائن]
```

---

## ✅ الخلاصة

**تم بنجاح:**
- ✅ تحديث POST endpoint لدعم الحقول الجديدة
- ✅ إضافة validation شامل للمرتجعات
- ✅ تحديث GET endpoint لإرجاع الحقول الجديدة
- ✅ إنشاء 3 endpoints جديدة للمرتجعات
- ✅ اختبار تحميل التطبيق بنجاح

**جاهز للانتقال إلى:**
- 🔜 تحديث منطق القيود المحاسبية
- 🔜 إنشاء واجهات Frontend
- 🔜 شاشات المرتجعات

---

**الحالة:** 🟢 Backend - API Endpoints جاهزة 100%
**التقدم الإجمالي:** 3/8 مهام مكتملة (37.5%)
