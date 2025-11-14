# 📱 خطة تحديث Frontend للفواتير والمرتجعات

**التاريخ:** 10 أكتوبر 2025  
**الحالة:** 📋 قيد التخطيط

---

## 🔍 التحليل الحالي

### الملف: `add_invoice_screen.dart`

#### ✅ ما هو موجود:
1. **أنواع الفواتير المدعومة:**
   - `'بيع'` - فاتورة بيع
   - `'شراء'` - شراء ذهب كسر
   - `'مرتجع بيع'` - مرتجع بيع
   - `'مرتجع شراء'` - مرتجع شراء

2. **البنية:**
   - Stepper بـ 4 خطوات (عميل، أصناف، دفع، مراجعة)
   - Autocomplete لاختيار العميل
   - جدول الأصناف مع الحسابات التلقائية
   - دعم أسعار يدوية/تلقائية

#### ❌ المشاكل المكتشفة:

| المشكلة | التفاصيل | الحل المطلوب |
|---------|----------|--------------|
| **1. invoice_type غير متطابق** | الشاشة ترسل `'شراء'` لكن Backend يتوقع `'شراء من عميل'` | تحديث قيمة dropdown |
| **2. القيمة الافتراضية خاطئة** | `invoiceType = 'مبيعات'` (قديم) | تغيير إلى `'بيع'` |
| **3. حقول المرتجعات مفقودة** | لا توجد حقول `original_invoice_id` و `return_reason` | إضافة حقول جديدة |
| **4. حقل gold_type مفقود** | لا يوجد تمييز بين 'new' و 'scrap' | إضافة dropdown للنوع |
| **5. فواتير الموردين معطلة** | `'شراء من مورد'` و `'مرتجع شراء من مورد'` محذوفة | إضافة للمحاسبة لاحقاً |
| **6. لا يوجد اختيار للفاتورة الأصلية** | المرتجعات تُنشأ بدون ربط | widget لاختيار الفاتورة |

---

## 🎯 خطة التنفيذ

### المرحلة 1: تصحيح الأنواع الحالية ✅

#### 1.1 تحديث القيمة الافتراضية
```dart
// القديم:
this.invoiceType = 'مبيعات',

// الجديد:
this.invoiceType = 'بيع',
```

#### 1.2 تحديث نوع الشراء
```dart
// القديم في dropdown:
DropdownMenuItem(value: 'شراء', child: Text('فاتورة شراء ذهب كسر')),

// الجديد:
DropdownMenuItem(value: 'شراء من عميل', child: Text('فاتورة شراء ذهب كسر من عميل')),
```

#### 1.3 تحديث _getInvoiceTypeDisplayName
```dart
case 'شراء من عميل':
  return 'فاتورة شراء ذهب كسر';
```

---

### المرحلة 2: إضافة حقل gold_type

#### 2.1 إضافة متغير state
```dart
String goldType = 'new'; // 'new' or 'scrap'
```

#### 2.2 إضافة dropdown في Step 1 (اختيار العميل)
```dart
if (currentType.contains('شراء')) // للشراء فقط
  DropdownButtonFormField<String>(
    value: goldType,
    decoration: InputDecoration(labelText: 'نوع الذهب'),
    items: [
      DropdownMenuItem(value: 'new', child: Text('ذهب جديد')),
      DropdownMenuItem(value: 'scrap', child: Text('ذهب كسر')),
    ],
    onChanged: (value) => setState(() => goldType = value!),
  ),
```

#### 2.3 إرسال إلى API
```dart
final invoiceData = {
  // ... existing fields
  'gold_type': goldType,
};
```

---

### المرحلة 3: حقول المرتجعات

#### 3.1 إضافة state variables
```dart
int? originalInvoiceId; // ID الفاتورة الأصلية
String returnReason = ''; // سبب الإرجاع
Map<String, dynamic>? selectedOriginalInvoice; // بيانات الفاتورة الأصلية
```

#### 3.2 إضافة widget لاختيار الفاتورة الأصلية

**في Step 1 - بعد اختيار العميل، إذا كان النوع مرتجع:**

```dart
if (currentType.contains('مرتجع'))
  Column(
    children: [
      SizedBox(height: 16),
      Text('اختر الفاتورة الأصلية', style: Theme.of(context).textTheme.titleMedium),
      SizedBox(height: 8),
      
      // زر لفتح dialog اختيار الفاتورة
      ElevatedButton.icon(
        icon: Icon(Icons.receipt_long),
        label: Text(selectedOriginalInvoice == null 
          ? 'اختر الفاتورة الأصلية' 
          : 'فاتورة رقم ${selectedOriginalInvoice!['id']}'),
        onPressed: () => _showSelectOriginalInvoiceDialog(),
      ),
      
      // عرض ملخص الفاتورة الأصلية
      if (selectedOriginalInvoice != null)
        Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('رقم الفاتورة: ${selectedOriginalInvoice!['id']}'),
                Text('التاريخ: ${selectedOriginalInvoice!['date']}'),
                Text('المبلغ: ${selectedOriginalInvoice!['total_amount']}'),
              ],
            ),
          ),
        ),
      
      // حقل سبب الإرجاع
      SizedBox(height: 16),
      TextFormField(
        decoration: InputDecoration(
          labelText: 'سبب الإرجاع',
          hintText: 'أدخل سبب إرجاع الفاتورة',
        ),
        maxLines: 3,
        onChanged: (value) => returnReason = value,
        validator: (value) {
          if (currentType.contains('مرتجع') && (value == null || value.isEmpty)) {
            return 'سبب الإرجاع مطلوب';
          }
          return null;
        },
      ),
    ],
  ),
```

#### 3.3 Dialog اختيار الفاتورة الأصلية

```dart
Future<void> _showSelectOriginalInvoiceDialog() async {
  // جلب الفواتير القابلة للإرجاع
  final String invoiceTypeToFetch = currentType == 'مرتجع بيع' ? 'بيع' : 'شراء من عميل';
  
  final response = await widget.api.getReturnableInvoices(
    invoiceType: invoiceTypeToFetch,
    customerId: selectedCustomer,
  );
  
  if (!mounted) return;
  
  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('اختر الفاتورة الأصلية'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: response['invoices'].length,
          itemBuilder: (context, index) {
            final invoice = response['invoices'][index];
            return ListTile(
              title: Text('فاتورة رقم ${invoice['id']}'),
              subtitle: Text('${invoice['date']} - ${invoice['total_amount']} ${currencySymbol}'),
              trailing: invoice['can_return'] 
                ? Icon(Icons.check_circle, color: Colors.green)
                : Icon(Icons.error, color: Colors.red),
              onTap: invoice['can_return']
                ? () => Navigator.pop(context, invoice)
                : null,
            );
          },
        ),
      ),
    ),
  );
  
  if (result != null) {
    setState(() {
      selectedOriginalInvoice = result;
      originalInvoiceId = result['id'];
    });
  }
}
```

#### 3.4 إرسال إلى API
```dart
final invoiceData = {
  // ... existing fields
  if (currentType.contains('مرتجع')) ...{
    'original_invoice_id': originalInvoiceId,
    'return_reason': returnReason,
  },
};
```

---

### المرحلة 4: إضافة endpoint جديد في ApiService

```dart
// في api_service.dart

Future<Map<String, dynamic>> getReturnableInvoices({
  String? invoiceType,
  int? customerId,
  int? supplierId,
}) async {
  final queryParams = <String, String>{};
  if (invoiceType != null) queryParams['invoice_type'] = invoiceType;
  if (customerId != null) queryParams['customer_id'] = customerId.toString();
  if (supplierId != null) queryParams['supplier_id'] = supplierId.toString();
  
  final uri = Uri.parse('$baseUrl/invoices/returnable')
      .replace(queryParameters: queryParams);
  
  final response = await http.get(
    uri,
    headers: {'Content-Type': 'application/json'},
  );
  
  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  } else {
    throw Exception('Failed to load returnable invoices');
  }
}

Future<Map<String, dynamic>> checkCanReturn(int invoiceId) async {
  final response = await http.get(
    Uri.parse('$baseUrl/invoices/$invoiceId/can-return'),
    headers: {'Content-Type': 'application/json'},
  );
  
  if (response.statusCode == 200) {
    return jsonDecode(response.body);
  } else {
    throw Exception('Failed to check return status');
  }
}
```

---

### المرحلة 5: Validation للمرتجعات

#### 5.1 في _onStepContinue - Step 0 (اختيار العميل):

```dart
case 0:
  if (!_customerFormKey.currentState!.validate()) {
    isStepValid = false;
  } else if (currentType.contains('مرتجع')) {
    // تحقق إضافي للمرتجعات
    if (originalInvoiceId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('يجب اختيار الفاتورة الأصلية للمرتجع')),
      );
      isStepValid = false;
    } else if (returnReason.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('يجب إدخال سبب الإرجاع')),
      );
      isStepValid = false;
    } else {
      isStepValid = true;
    }
  } else {
    isStepValid = true;
  }
  break;
```

---

## 📊 ملخص التغييرات

### ملفات تحتاج تعديل:

| الملف | التغييرات | الأولوية |
|------|----------|---------|
| `add_invoice_screen.dart` | - تصحيح invoice_type<br>- إضافة gold_type<br>- إضافة حقول المرتجعات<br>- dialog اختيار الفاتورة الأصلية | 🔴 عالية |
| `api_service.dart` | - إضافة getReturnableInvoices()<br>- إضافة checkCanReturn() | 🔴 عالية |

### متغيرات State جديدة:

```dart
String goldType = 'new';
int? originalInvoiceId;
String returnReason = '';
Map<String, dynamic>? selectedOriginalInvoice;
```

### Widgets جديدة:

1. ✅ Dropdown لنوع الذهب (new/scrap)
2. ✅ زر اختيار الفاتورة الأصلية
3. ✅ Card عرض ملخص الفاتورة الأصلية
4. ✅ TextField سبب الإرجاع
5. ✅ Dialog قائمة الفواتير القابلة للإرجاع

---

## 🧪 خطة الاختبار

### السيناريوهات:

#### 1. فاتورة بيع عادية
- ✅ اختيار عميل
- ✅ إضافة أصناف
- ✅ gold_type = 'new' (افتراضي)
- ✅ الدفع والحفظ

#### 2. شراء كسر من عميل
- ✅ اختيار عميل
- ✅ إضافة أصناف
- ✅ gold_type = 'scrap'
- ✅ الدفع والحفظ

#### 3. مرتجع بيع
- ✅ اختيار عميل
- ✅ اختيار فاتورة بيع أصلية
- ✅ عرض تفاصيل الفاتورة
- ✅ إدخال سبب الإرجاع
- ✅ إضافة الأصناف المرتجعة
- ✅ التحقق من original_invoice_id يُرسل

#### 4. مرتجع شراء
- ✅ اختيار عميل
- ✅ اختيار فاتورة شراء أصلية
- ✅ إدخال سبب الإرجاع
- ✅ الحفظ

#### 5. Validation
- ❌ محاولة حفظ مرتجع بدون فاتورة أصلية
- ❌ محاولة حفظ مرتجع بدون سبب إرجاع
- ✅ التحقق من رسائل الخطأ

---

## 📝 الخطوات التالية

1. ✅ **تصحيح الأنواع الحالية**
   - تحديث القيمة الافتراضية
   - تحديث 'شراء' إلى 'شراء من عميل'

2. ✅ **إضافة حقل gold_type**
   - State variable
   - Dropdown
   - إرسال للـ API

3. ✅ **إضافة حقول المرتجعات**
   - State variables
   - UI widgets
   - Dialog اختيار الفاتورة

4. ✅ **تحديث ApiService**
   - getReturnableInvoices
   - checkCanReturn

5. ✅ **Validation شامل**
   - التحقق من الحقول المطلوبة
   - رسائل خطأ واضحة

6. ✅ **الاختبار**
   - كل السيناريوهات
   - Edge cases

---

**الحالة:** 📋 جاهز للتنفيذ  
**المدة المتوقعة:** 2-3 ساعات  
**التعقيد:** متوسط ⭐⭐⭐
