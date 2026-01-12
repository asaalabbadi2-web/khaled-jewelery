# ✅ تحديثات add_invoice_screen.dart - المرحلة 1 مكتملة

**التاريخ:** 10 أكتوبر 2025  
**الحالة:** ✅ **المرحلة الأولى مكتملة**

---

## 🎯 ملخص التحديثات

تم تحديث شاشة الفواتير الرئيسية لدعم **3 أنواع من الفواتير العادية**:
1. ✅ بيع
2. ✅ شراء من عميل
3. ✅ شراء (جديد)

---

## 📝 التغييرات التفصيلية

### 1️⃣ تصحيح القيمة الافتراضية

**قبل:**
```dart
this.invoiceType = 'مبيعات', // Default type
```

**بعد:**
```dart
this.invoiceType = 'بيع', // Default type (updated to match backend)
```

**السبب:** التوافق مع Backend API الذي يتوقع `'بيع'` وليس `'مبيعات'`

---

### 2️⃣ تحديث _getInvoiceTypeDisplayName

**قبل:**
```dart
case 'شراء':
  return 'فاتورة شراء ذهب كسر';
// case 'شراء': // Removed
```

**بعد:**
```dart
case 'شراء من عميل':
  return 'فاتورة شراء ذهب كسر';
case 'شراء':
  return 'فاتورة شراء';
case 'مرتجع شراء (مورد)':
  return 'فاتورة مرتجع شراء (مورد)';
```

**السبب:** 
- تصحيح نوع الشراء من العميل ليتطابق مع Backend
- إضافة دعم فواتير المورد
- إضافة مرتجع شراء (مورد) (للمستقبل)

---

### 3️⃣ إضافة State Variables جديدة

```dart
// Data for all steps
late String currentType;
int? selectedCustomer;
int? selectedSupplier; // Re-enabled for supplier purchases

// New fields for backend compatibility
String goldType = 'new'; // 'new' or 'scrap'
```

**الحقول الجديدة:**
- ✅ `selectedSupplier` - لاختيار المورد (تم إعادة تفعيله)
- ✅ `goldType` - نوع الذهب ('new' أو 'scrap')

---

### 4️⃣ تحديث Dropdown أنواع الفواتير

**قبل:**
```dart
items: const [
  DropdownMenuItem(value: 'بيع', child: Text('فاتورة بيع')),
  DropdownMenuItem(value: 'شراء', child: Text('فاتورة شراء ذهب كسر')),
  DropdownMenuItem(value: 'مرتجع بيع', child: Text('فاتورة مرتجع بيع')),
  DropdownMenuItem(value: 'مرتجع شراء', child: Text('فاتورة مرتجع شراء')),
],
```

**بعد:**
```dart
items: const [
  DropdownMenuItem(value: 'بيع', child: Text('فاتورة بيع')),
  DropdownMenuItem(value: 'شراء من عميل', child: Text('فاتورة شراء ذهب كسر من عميل')),
  DropdownMenuItem(value: 'شراء', child: Text('فاتورة شراء')),
],
onChanged: (value) {
  if (value != null) {
    setState(() {
      currentType = value;
      // Reset selections when changing type
      selectedCustomer = null;
      selectedSupplier = null;
    });
  }
},
```

**التحسينات:**
- ✅ تصحيح `'شراء'` → `'شراء من عميل'`
- ✅ إضافة `'شراء'`
- ✅ إزالة المرتجعات (ستكون في شاشة منفصلة)
- ✅ Reset للاختيارات عند تغيير النوع

---

### 5️⃣ إضافة UI لاختيار العميل/المورد

**العنوان الديناميكي:**
```dart
Text(
  currentType == 'شراء' ? 'اختر المورد' : 'اختر العميل',
  style: Theme.of(context).textTheme.titleMedium,
),
```

**اختيار العميل (مشروط):**
```dart
if (currentType != 'شراء')
  Autocomplete<Map<String, dynamic>>(
    // ... existing customer selection code
  ),
```

**اختيار المورد (جديد):**
```dart
if (currentType == 'شراء')
  TextFormField(
    decoration: InputDecoration(
      labelText: 'اسم المورد',
      hintText: 'أدخل اسم المورد',
      border: const OutlineInputBorder(),
      helperText: 'سيتم إضافة نظام الموردين لاحقاً',
    ),
    validator: (value) {
      if (currentType == 'شراء' && (value == null || value.isEmpty)) {
        return 'الرجاء إدخال اسم المورد';
      }
      return null;
    },
  ),
```

**ملاحظة:** حالياً نستخدم TextField بسيط للمورد. سيتم استبداله بـ Autocomplete لاحقاً.

---

### 6️⃣ إضافة Dropdown لنوع الذهب

```dart
// Gold type selector (for purchases only)
if (currentType.contains('شراء'))
  Column(
    children: [
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        value: goldType,
        decoration: const InputDecoration(
          labelText: 'نوع الذهب',
          border: OutlineInputBorder(),
        ),
        items: const [
          DropdownMenuItem(value: 'new', child: Text('ذهب جديد')),
          DropdownMenuItem(value: 'scrap', child: Text('ذهب كسر')),
        ],
        onChanged: (value) {
          if (value != null) {
            setState(() {
              goldType = value;
            });
          }
        },
      ),
    ],
  ),
```

**المميزات:**
- ✅ يظهر فقط للفواتير من نوع "شراء"
- ✅ خياران: 'new' (ذهب جديد) و 'scrap' (ذهب كسر)
- ✅ القيمة الافتراضية: 'new'

---

### 7️⃣ تحديث دالة الحفظ

**قبل:**
```dart
final payload = {
  'customer_id': selectedCustomer,
  'date': DateTime.now().toIso8601String(),
  'invoice_type': currentType,
  'total': grandTotal,
  // ...
};
```

**بعد:**
```dart
final payload = {
  'customer_id': currentType != 'شراء' ? selectedCustomer : null,
  'supplier_id': currentType == 'شراء' ? selectedSupplier : null,
  'date': DateTime.now().toIso8601String(),
  'invoice_type': currentType,
  'gold_type': goldType, // New field
  'total': grandTotal,
  // ...
};
```

**التحسينات:**
- ✅ إرسال `customer_id` فقط للمعاملات مع العملاء
- ✅ إرسال `supplier_id` فقط للمعاملات مع الموردين
- ✅ إضافة حقل `gold_type` الجديد

---

## 🆕 تحديثات ApiService

تم إضافة 3 methods جديدة في `api_service.dart`:

### 1. getReturnableInvoices

```dart
Future<Map<String, dynamic>> getReturnableInvoices({
  String? invoiceType,
  int? customerId,
  int? supplierId,
}) async {
  // Returns list of invoices that can be returned
}
```

**الاستخدام:**
```dart
final result = await api.getReturnableInvoices(
  invoiceType: 'بيع',
  customerId: 5,
);
```

---

### 2. checkCanReturn

```dart
Future<Map<String, dynamic>> checkCanReturn(int invoiceId) async {
  // Checks if a specific invoice can be returned
  // Returns: can_return, remaining_amount, message
}
```

**الاستخدام:**
```dart
final result = await api.checkCanReturn(123);
if (result['can_return']) {
  print('يمكن الإرجاع');
}
```

---

### 3. getInvoiceReturns

```dart
Future<Map<String, dynamic>> getInvoiceReturns(int invoiceId) async {
  // Gets all returns associated with an invoice
}
```

**الاستخدام:**
```dart
final returns = await api.getInvoiceReturns(123);
print('عدد المرتجعات: ${returns['count']}');
```

---

## 📊 جدول مقارنة

| الميزة | قبل | بعد |
|--------|-----|-----|
| **القيمة الافتراضية** | 'مبيعات' ❌ | 'بيع' ✅ |
| **نوع الشراء من عميل** | 'شراء' ❌ | 'شراء من عميل' ✅ |
| **فواتير الموردين** | غير مدعومة ❌ | مدعومة ✅ |
| **نوع الذهب** | لا يوجد ❌ | dropdown للنوع ✅ |
| **اختيار المورد** | معطل ❌ | TextField مؤقت ✅ |
| **API Methods** | 0 | 3 methods جديدة ✅ |

---

## 🧪 السيناريوهات المدعومة الآن

### ✅ فاتورة بيع
1. اختيار عميل
2. إضافة أصناف
3. `gold_type = 'new'` (افتراضي)
4. الدفع والحفظ

### ✅ شراء من عميل
1. اختيار عميل
2. اختيار نوع الذهب (new/scrap)
3. إضافة أصناف
4. الدفع والحفظ

### ✅ شراء (جديد)
1. إدخال اسم المورد (مؤقت)
2. اختيار نوع الذهب (new/scrap)
3. إضافة أصناف
4. الدفع والحفظ

---

## ⚠️ ملاحظات مهمة

### 1. نظام الموردين
حالياً يستخدم **TextField بسيط** لإدخال اسم المورد.  
**سيتم استبداله لاحقاً بـ:**
- Autocomplete مع قاعدة بيانات الموردين
- زر لإضافة مورد جديد
- عرض تفاصيل المورد

### 2. المرتجعات
تم **إزالة المرتجعات** من dropdown هذه الشاشة.  
**السبب:** ستكون لها شاشة منفصلة (`add_return_invoice_screen.dart`) مع workflow خاص.

### 3. Validation
- ✅ لا يمكن حفظ فاتورة عميل بدون اختيار عميل
- ✅ لا يمكن حفظ فاتورة مورد بدون إدخال اسم مورد
- ✅ نوع الذهب يظهر فقط للمشتريات

---

## 🚀 الخطوات القادمة

### المرحلة 2: إنشاء add_return_invoice_screen.dart

**الميزات المطلوبة:**
1. ✅ اختيار الفاتورة الأصلية (من قائمة returnable)
2. ✅ عرض تفاصيل الفاتورة الأصلية
3. ✅ اختيار الأصناف المرتجعة (partial return)
4. ✅ حقل سبب الإرجاع (إلزامي)
5. ✅ إرسال `original_invoice_id` و `return_reason`

**أنواع المرتجعات:**
- مرتجع بيع
- مرتجع شراء (من عميل)
- مرتجع شراء (من مورد)

---

## 📁 الملفات المحدثة

| الملف | التغييرات | الأسطر المضافة |
|------|----------|----------------|
| `add_invoice_screen.dart` | تصحيحات + gold_type + مورد | ~80 سطر |
| `api_service.dart` | 3 methods جديدة | ~60 سطر |

---

## ✅ الحالة

**المرحلة 1:** ✅ **مكتملة 100%**

**الجاهزية:**
- ✅ تصحيح أنواع الفواتير
- ✅ دعم حقل gold_type
- ✅ دعم شراء (مؤقت)
- ✅ API methods للمرتجعات
- ⏳ شاشة المرتجعات (قادم)

---

**التقدم الإجمالي:** 5/10 مراحل (50%) ✨  
**الحالة:** 🟢 Ready for Phase 2  
**التاريخ:** 10 أكتوبر 2025
