# دليل آلية ترحيل السندات (Voucher Posting System)

## نظرة عامة

آلية ترحيل السندات هي عملية تحويل السند من حالة "بانتظار الاعتماد" (pending) إلى حالة "مرحّل" (approved)، مع إنشاء قيد محاسبي تلقائي.

---

## 🔄 دورة حياة السند (Voucher Lifecycle)

```
إنشاء السند → مراجعة → ترحيل/اعتماد → قيد محاسبي
   (Create)    (Review)   (Approve/Post)  (Journal Entry)
     ↓            ↓            ↓               ↓
  pending  →  pending  →  approved  →   مرتبط بقيد
```

---

## 📝 الحالات المتاحة للسند

| الحالة | الوصف | يمكن الترحيل؟ |
|--------|-------|----------------|
| `pending` | بانتظار المراجعة والاعتماد | ✅ نعم |
| `approved` | مرحّل ومعتمد | ❌ لا (مرحّل بالفعل) |
| `rejected` | مرفوض | ❌ لا |
| `cancelled` | ملغى | ❌ لا |

---

## 🔧 آلية الترحيل التفصيلية

### 1. **إنشاء السند**
```bash
POST /api/vouchers
```

**مثال: سند صرف**
```json
{
  "voucher_type": "payment",
  "date": "2025-11-11T12:00:00",
  "party_type": "supplier",
  "party_name": "مورد تجريبي",
  "description": "دفعة للمورد",
  "account_lines": [
    {
      "account_id": 38,
      "line_type": "debit",
      "amount_type": "cash",
      "amount": 5000,
      "description": "حساب المورد"
    },
    {
      "account_id": 15,
      "line_type": "credit",
      "amount_type": "cash",
      "amount": 5000,
      "description": "الصندوق"
    }
  ]
}
```

**النتيجة:**
- يتم إنشاء السند بحالة `pending`
- رقم السند: `PV-2025-00011` (مثال)
- `journal_entry_id = NULL` (لم يُرحّل بعد)

---

### 2. **ترحيل/اعتماد السند**
```bash
POST /api/vouchers/{voucher_id}/approve
```

**Body:**
```json
{
  "approved_by": "admin"
}
```

**ما يحدث داخلياً:**

#### أ) التحقق من الحالة
```python
if voucher.status == 'approved':
    return {'error': 'السند مرحّل بالفعل'}
    
if voucher.status == 'cancelled':
    return {'error': 'لا يمكن ترحيل سند ملغى'}
```

#### ب) إنشاء القيد المحاسبي
```python
journal_entry = create_journal_entry_from_voucher(voucher)
```

**وظيفة `create_journal_entry_from_voucher`:**

1. **توليد رقم القيد:**
   ```python
   entry_number = f'JE-{year}-{sequential_number:05d}'
   # مثال: JE-2025-00041
   ```

2. **قراءة سطور السند:**
   ```python
   account_lines = VoucherAccountLine.query.filter_by(voucher_id=voucher.id).all()
   ```

3. **تحويل كل سطر إلى سطر قيد محاسبي:**
   
   **سند الصرف (Payment):**
   ```
   مدين: حساب المورد    5,000 ر.س
   دائن: الصندوق         5,000 ر.س
   ```
   
   **سند القبض (Receipt):**
   ```
   مدين: الصندوق         5,000 ر.س
   دائن: حساب العميل     5,000 ر.س
   ```

4. **دعم المبالغ المختلطة (نقد + ذهب):**
   ```python
   if amount_type == 'cash':
       cash_debit = amount if line_type == 'debit' else 0
       cash_credit = amount if line_type == 'credit' else 0
   
   elif amount_type == 'gold':
       # تحديد العيار (18, 21, 22, 24)
       if karat == 21 and line_type == 'debit':
           debit_21k = amount
       elif karat == 21 and line_type == 'credit':
           credit_21k = amount
   ```

#### ج) تحديث السند
```python
voucher.status = 'approved'
voucher.approved_at = datetime.now()
voucher.approved_by = 'admin'
voucher.journal_entry_id = journal_entry.id
```

#### د) الحفظ
```python
db.session.commit()
```

---

### 3. **نتيجة الترحيل**

**استجابة الـ API:**
```json
{
  "message": "تم ترحيل السند بنجاح",
  "voucher": {
    "id": 12,
    "voucher_number": "PV-2025-00011",
    "status": "approved",
    "approved_at": "2025-11-11T23:46:59",
    "approved_by": "admin",
    "journal_entry_id": 41
  },
  "journal_entry": {
    "id": 41,
    "entry_number": "JE-2025-00041",
    "date": "2025-11-11T12:00:00"
  }
}
```

**في قاعدة البيانات:**

**جدول `voucher`:**
| id | voucher_number | status | journal_entry_id | approved_at |
|----|----------------|--------|------------------|-------------|
| 12 | PV-2025-00011 | approved | 41 | 2025-11-11 23:46:59 |

**جدول `journal_entry`:**
| id | entry_number | date | description | reference_type | reference_id |
|----|--------------|------|-------------|----------------|--------------|
| 41 | JE-2025-00041 | 2025-11-11 | PAYMENT - PV-2025-00011: سند صرف تجريبي | voucher | 12 |

**جدول `journal_entry_line`:**
| id | journal_entry_id | account_id | cash_debit | cash_credit |
|----|------------------|------------|------------|-------------|
| 101 | 41 | 38 (المورد) | 5000.00 | 0.00 |
| 102 | 41 | 15 (الصندوق) | 0.00 | 5000.00 |

---

## 🎯 أنواع السندات والقيود الناتجة

### 1. **سند قبض نقدي (Receipt Voucher - Cash)**
```
مدين: الصندوق          1,000 ر.س
دائن: حساب العميل       1,000 ر.س
```

### 2. **سند صرف نقدي (Payment Voucher - Cash)**
```
مدين: حساب المورد       2,000 ر.س
دائن: الصندوق          2,000 ر.س
```

### 3. **سند قبض ذهب (Receipt Voucher - Gold)**
```
مدين: مخزون ذهب 21 قيراط    10 غرام
دائن: حساب العميل          10 غرام (21 قيراط)
```

### 4. **سند مختلط (نقد + ذهب)**
```
مدين: الصندوق          500 ر.س
مدين: مخزون ذهب 21     5 غرام
دائن: حساب العميل      500 ر.س + 5 غرام (21 قيراط)
```

---

## 🔐 الصلاحيات المطلوبة

في نظام الصلاحيات الكامل (عبر `posting_routes.py`):

```python
@require_permission('voucher.approve')
def approve_voucher(voucher_id):
    # ...
```

**الصلاحيات:**
- `voucher.view` - عرض السندات
- `voucher.create` - إنشاء سند جديد
- `voucher.edit` - تعديل سند
- `voucher.delete` - حذف سند
- `voucher.approve` - ترحيل/اعتماد سند ⭐
- `voucher.cancel` - إلغاء سند

---

## 🛠️ استخدام API من Flutter

**في `api_service.dart`:**
```dart
Future<Map<String, dynamic>> approveVoucher(
  int voucherId, {
  String? approvedBy,
}) async {
  final response = await http.post(
    Uri.parse('$_baseUrl/vouchers/$voucherId/approve'),
    headers: {'Content-Type': 'application/json; charset=UTF-8'},
    body: json.encode({'approved_by': approvedBy ?? 'user'}),
  );
  
  if (response.statusCode == 200) {
    return json.decode(utf8.decode(response.bodyBytes));
  } else {
    throw Exception('Failed to approve voucher: ${response.body}');
  }
}
```

**في الشاشة:**
```dart
Future<void> _approveVoucher() async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('اعتماد السند'),
      content: const Text('هل تريد اعتماد (ترحيل) هذا السند الآن؟'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('إلغاء'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('اعتماد'),
        ),
      ],
    ),
  );

  if (confirm == true) {
    try {
      await _apiService.approveVoucher(widget.voucherId);
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم اعتماد السند بنجاح')),
      );
      
      _loadVoucher(); // إعادة تحميل بيانات السند
    } catch (e) {
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ: $e')),
      );
    }
  }
}
```

---

## ⚠️ القيود والتحذيرات

### 1. **لا يمكن ترحيل سند مرحّل**
```json
{
  "error": "السند مرحّل بالفعل"
}
```

### 2. **لا يمكن ترحيل سند ملغى**
```json
{
  "error": "لا يمكن ترحيل سند ملغى"
}
```

### 3. **يجب توازن المبالغ**
عند إنشاء السند، يتم التحقق من:
```python
if abs(total_debit_cash - total_credit_cash) > 0.01:
    return {'error': 'Cash amounts not balanced'}

if abs(total_debit_gold - total_credit_gold) > 0.001:
    return {'error': 'Gold amounts not balanced'}
```

### 4. **الحسابات يجب أن تكون موجودة**
```python
for line in account_lines_data:
    account = Account.query.get(line['account_id'])
    if not account:
        return {'error': f'Account {line["account_id"]} not found'}
```

---

## 📊 مثال عملي كامل

### الخطوة 1: إنشاء سند صرف
```bash
curl -X POST http://localhost:8001/api/vouchers \
  -H "Content-Type: application/json" \
  -d '{
    "voucher_type": "payment",
    "date": "2025-11-11T12:00:00",
    "party_type": "supplier",
    "party_name": "مورد ABC",
    "description": "دفعة شهرية",
    "account_lines": [
      {
        "account_id": 38,
        "line_type": "debit",
        "amount_type": "cash",
        "amount": 10000,
        "description": "حساب المورد"
      },
      {
        "account_id": 15,
        "line_type": "credit",
        "amount_type": "cash",
        "amount": 10000,
        "description": "الصندوق"
      }
    ]
  }'
```

**النتيجة:**
```json
{
  "id": 13,
  "voucher_number": "PV-2025-00012",
  "status": "pending",
  "journal_entry_id": null
}
```

---

### الخطوة 2: ترحيل السند
```bash
curl -X POST http://localhost:8001/api/vouchers/13/approve \
  -H "Content-Type: application/json" \
  -d '{"approved_by": "محاسب_رئيسي"}'
```

**النتيجة:**
```json
{
  "message": "تم ترحيل السند بنجاح",
  "voucher": {
    "id": 13,
    "voucher_number": "PV-2025-00012",
    "status": "approved",
    "approved_at": "2025-11-11T23:50:00",
    "approved_by": "محاسب_رئيسي",
    "journal_entry_id": 42
  },
  "journal_entry": {
    "id": 42,
    "entry_number": "JE-2025-00042",
    "date": "2025-11-11T12:00:00"
  }
}
```

---

### الخطوة 3: التحقق من القيد المحاسبي
```bash
# عرض تفاصيل السند (يحتوي على رابط القيد)
curl http://localhost:8001/api/vouchers/13
```

---

## 🔄 عكس الترحيل (Reverse Posting)

**ملاحظة:** حالياً لا يوجد endpoint لعكس الترحيل تلقائياً. 

**الطريقة الحالية:**
1. إلغاء السند (`/vouchers/{id}/cancel`)
2. إنشاء قيد عكسي يدوياً (TODO)

**المخطط مستقبلاً:**
```bash
POST /api/vouchers/{voucher_id}/unapprove
```
سيقوم بـ:
- إنشاء قيد عكسي تلقائياً
- تغيير حالة السند إلى `pending`
- حذف رابط القيد

---

## 📚 الملفات ذات الصلة

| الملف | الوظيفة |
|-------|---------|
| `backend/routes.py` | الـ endpoints الأساسية للسندات |
| `backend/posting_routes.py` | نظام الترحيل مع الصلاحيات |
| `backend/models.py` | نماذج Voucher و JournalEntry |
| `frontend/lib/api_service.dart` | خدمات API في Flutter |
| `frontend/lib/screens/voucher_details_screen.dart` | شاشة تفاصيل السند |

---

## ✅ ملخص العملية

```
1. إنشاء سند (POST /api/vouchers)
   ↓
2. مراجعة السند (حالة pending)
   ↓
3. ترحيل السند (POST /api/vouchers/{id}/approve)
   ↓
4. إنشاء قيد محاسبي تلقائي
   ↓
5. تحديث حالة السند إلى approved
   ↓
6. ربط السند بالقيد (journal_entry_id)
```

**النتيجة النهائية:**
- ✅ سند مرحّل ومعتمد
- ✅ قيد محاسبي في دفتر اليومية
- ✅ تحديث أرصدة الحسابات
- ✅ سجل تدقيق كامل (audit log)

---

**آخر تحديث:** 11 نوفمبر 2025
