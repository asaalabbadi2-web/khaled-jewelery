# إصلاح الحلقة اللانهائية و أخطاء Layout في شاشة إضافة وسيلة دفع

## المشكلة
1. عند محاولة إضافة وسيلة دفع جديدة، كان النظام يدخل في حلقة لانهائية تؤدي إلى تعليق التطبيق
2. أخطاء Rendering: `"RenderBox was not laid out"` في Flutter Web

## السبب الجذري

### السبب الأول: FutureBuilder داخل StatefulBuilder
كان الكود يستخدم `FutureBuilder` داخل `StatefulBuilder` في Dialog:

```dart
showDialog(
  context: context,
  builder: (context) => StatefulBuilder(
    builder: (context, setDialogState) => AlertDialog(
      // ...
      FutureBuilder<List<SafeBoxModel>>(
        future: apiService.getSafeBoxes(),  // ❌ يُستدعى في كل rebuild
        builder: (context, snapshot) {
          // ...
        },
      ),
    ),
  ),
);
```

**المشكلة:** عند تغيير `selectedType` باستخدام `setDialogState()`, يُعاد بناء `AlertDialog` بالكامل، مما يؤدي إلى:
1. إعادة إنشاء `FutureBuilder`
2. استدعاء `apiService.getSafeBoxes()` من جديد
3. تحديث الحالة عند وصول البيانات
4. إعادة بناء الـ Dialog مرة أخرى
5. العودة للخطوة 1 → **حلقة لانهائية**

### السبب الثاني: selectedBankId غير صالح بعد تغيير النوع
عند تغيير نوع الدفع من "نقدي" إلى "بنكي" (أو العكس)، كانت قيمة `selectedBankId` تبقى تشير إلى خزينة من النوع القديم، مما يسبب:
- تعارض في `DropdownButtonFormField.value` (قيمة غير موجودة في القائمة المصفاة)
- محاولات متكررة لإعادة البناء
- **حلقة لانهائية**

### السبب الثالث: Layout errors في Builder
استخدام `Builder` مباشرة داخل `Column` مع `Row` يحتوي على `Expanded` سبب أخطاء layout:
```
🔴 RenderBox was not laid out: RenderSemanticsAnnotations NEEDS-PAINT
```

## الحل المطبق

### 1. تحويل الدالة إلى async
```dart
void _showPaymentMethodDialog({Map<String, dynamic>? editingMethod}) async {
```

### 2. تحميل الخزائن مرة واحدة قبل فتح Dialog
```dart
// 🔧 تحميل الخزائن مرة واحدة قبل فتح الـ Dialog
List<SafeBoxModel>? allSafeBoxes;
if (editingMethod == null) {
  try {
    allSafeBoxes = await apiService.getSafeBoxes();
  } catch (e) {
    _showMessage('خطأ في تحميل الخزائن: $e', isError: true);
    allSafeBoxes = [];
  }
}
```

### 3. فصل dropdown الخزائن إلى دالة منفصلة
```dart
Widget _buildSafeBoxDropdown(
  List<SafeBoxModel> allBoxes,
  String? selectedType,
  int? selectedBankId,
  void Function(int?) onChanged,
) {
  // تصفية الخزائن
  // validation
  // build dropdown
  return DropdownButtonFormField<int>(...);
}
```

**الفائدة:**
- Widget منفصل بحجم محدد
- لا يسبب أخطاء layout
- أسهل في الصيانة والتطوير

### 4. إعادة تعيين selectedBankId عند تغيير النوع
```dart
onChanged: (value) {
  setDialogState(() {
    selectedType = value;
    // ✅ إعادة تعيين الخزينة المختارة عند تغيير نوع الدفع
    selectedBankId = null;
  });
},
```

### 5. التحقق من صحة selectedBankId قبل استخدامه
```dart
// التحقق من أن selectedBankId موجود ضمن الخزائن المتاحة
final isValidSelection = selectedBankId != null && 
    filteredBoxes.any((box) => box.id == selectedBankId);

return DropdownButtonFormField<int>(
  value: isValidSelection ? selectedBankId : null,  // ✅ استخدام null إذا كانت القيمة غير صالحة
  // ...
);
```

### 6. استخدام Flexible بدلاً من Expanded في dropdown items
```dart
child: Row(
  mainAxisSize: MainAxisSize.min,  // ✅ تحديد حجم Row
  children: [
    Icon(...),
    SizedBox(width: 8),
    Flexible(  // ✅ بدلاً من Expanded
      child: Text(box.name, overflow: TextOverflow.ellipsis),
    ),
  ],
),
```

**الفائدة:**
- `Flexible` أكثر مرونة من `Expanded`
- `mainAxisSize: MainAxisSize.min` يمنع أخطاء layout
- يحل مشكلة "RenderBox was not laid out"

## الفوائد النهائية
✅ **تحميل واحد فقط:** البيانات تُحمل مرة واحدة قبل فتح Dialog  
✅ **لا rebuilds غير ضرورية:** تغيير `selectedType` لا يُعيد استدعاء API  
✅ **إعادة تعيين ذكية:** عند تغيير النوع، يتم إعادة تعيين الخزينة المختارة  
✅ **validation صارم:** التحقق من صحة القيمة قبل عرضها في dropdown  
✅ **لا أخطاء layout:** فصل logic إلى دوال منفصلة مع تحديد الأحجام  
✅ **أداء أفضل:** لا طلبات شبكة متكررة  
✅ **تجربة مستخدم سلسة:** Dialog يفتح فوراً بدون تعليق أو أخطاء  

## الملفات المعدلة
- `frontend/lib/screens/payment_methods_screen_enhanced.dart`
  - إضافة `_buildSafeBoxDropdown()` method
  - تحويل `_showPaymentMethodDialog()` إلى async
  - استبدال `Builder` بـ widget method call

## التاريخ
31 أكتوبر 2025
