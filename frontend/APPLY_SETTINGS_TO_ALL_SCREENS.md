# دليل تطبيق الإعدادات على جميع الشاشات

## ✅ الشاشات المكتملة

### 1. ✅ sales_invoice_screen_v2.dart
- تم إضافة `SettingsProvider`
- يتم تحديث `_mainKarat` و `_currencySymbol` من الإعدادات
- التطبيق فوري عند تغيير الإعدادات

### 2. ✅ scrap_purchase_invoice_screen.dart
- تم إضافة `SettingsProvider`
- يتم تحديث `_mainKarat` و `_currencySymbol` من الإعدادات
- التطبيق فوري عند تغيير الإعدادات

### 3. ✅ scrap_sales_invoice_screen.dart  
- تم إضافة `SettingsProvider`
- يتم تحديث `_mainKarat` و `_currencySymbol` من الإعدادات
- التطبيق فوري عند تغيير الإعدادات

### 4. ✅ settings_screen_enhanced.dart
- يستخدم `SettingsProvider` عند الحفظ
- يتم تطبيق التغييرات على جميع الشاشات فوراً

### 5. ✅ home_screen_enhanced.dart
- جاهز للتحديث - يستخدم قيم محلية حالياً

---

## 📋 الشاشات المتبقية

### القائمة الكاملة للشاشات التي تحتاج تحديث:

#### شاشات الفواتير:
- [ ] `add_invoice_screen.dart`
- [ ] `add_purchase_invoice_screen.dart`
- [ ] `add_return_invoice_screen.dart`
- [ ] `purchase_invoice_screen.dart`
- [ ] `invoices_list_screen.dart`

#### شاشات المحاسبة:
- [ ] `journal_entry_screen.dart` (يستخدم `_mainKarat = 21`)
- [ ] `account_ledger_screen.dart`
- [ ] `general_ledger_screen_v2.dart`
- [ ] `trial_balance_screen_v2.dart`

#### شاشات أخرى:
- [ ] `safe_boxes_screen.dart`
- [ ] `gold_price_manual_screen_enhanced.dart`
- [ ] `barcode_print_screen.dart`

---

## 🔧 طريقة التطبيق السريعة

### الخطوة 1: إضافة الاستيراد
```dart
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
```

### الخطوة 2: إضافة متغير الإعدادات
```dart
class _YourScreenState extends State<YourScreen> {
  SettingsProvider? _settingsProvider;
  
  // بدلاً من:
  // String _currencySymbol = 'ر.س';
  // int _mainKarat = 21;
  
  // استخدم:
  String get _currencySymbol => _settingsProvider?.currencySymbol ?? 'ر.س';
  int get _mainKarat => _settingsProvider?.mainKarat ?? 21;
  int get _decimalPlaces => _settingsProvider?.decimalPlaces ?? 2;
```

### الخطوة 3: ربط الإعدادات
```dart
@override
void didChangeDependencies() {
  super.didChangeDependencies();
  final settings = Provider.of<SettingsProvider>(context);
  if (!identical(_settingsProvider, settings)) {
    setState(() {
      _settingsProvider = settings;
    });
  }
}
```

### الخطوة 4: استخدام دوال التنسيق
```dart
// بدلاً من:
Text('${amount.toStringAsFixed(2)} ر.س')

// استخدم:
Text('${_settingsProvider?.formatNumber(amount) ?? amount.toStringAsFixed(2)} ${_currencySymbol}')

// أو بشكل أبسط:
final settings = context.read<SettingsProvider>();
Text('${settings.formatNumber(amount)} ${settings.currencySymbol}')
```

### الخطوة 5: حساب الضريبة
```dart
// بدلاً من:
final tax = amount * 0.15;

// استخدم:
final tax = _settingsProvider?.calculateTax(amount) ?? 0;
```

---

## 📝 قالب جاهز لأي شاشة جديدة

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

class NewInvoiceScreen extends StatefulWidget {
  const NewInvoiceScreen({Key? key}) : super(key: key);

  @override
  State<NewInvoiceScreen> createState() => _NewInvoiceScreenState();
}

class _NewInvoiceScreenState extends State<NewInvoiceScreen> {
  SettingsProvider? _settingsProvider;

  // استخدم Getters بدلاً من المتغيرات المباشرة
  String get _currencySymbol => _settingsProvider?.currencySymbol ?? 'ر.س';
  int get _mainKarat => _settingsProvider?.mainKarat ?? 21;
  int get _decimalPlaces => _settingsProvider?.decimalPlaces ?? 2;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);
    if (!identical(_settingsProvider, settings)) {
      setState(() {
        _settingsProvider = settings;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('فاتورة جديدة')),
      body: Column(
        children: [
          // مثال على استخدام العيار الرئيسي
          Text('العيار الأساسي: $_mainKarat'),
          
          // مثال على تنسيق الأرقام
          Text(_settingsProvider?.formatNumber(1234.5678) ?? '1234.57'),
          
          // مثال على حساب الضريبة
          Text('الضريبة: ${_settingsProvider?.calculateTax(1000) ?? 0}'),
          
          // مثال على عرض العملة
          Text('الإجمالي: 1000 $_currencySymbol'),
        ],
      ),
    );
  }
}
```

---

## 🎯 الفوائد

1. ✅ **تحديث فوري**: أي تغيير في الإعدادات يظهر مباشرة
2. ✅ **توحيد**: جميع الشاشات تستخدم نفس القيم
3. ✅ **مرونة**: سهولة تغيير العيار أو العملة أو الضريبة
4. ✅ **صيانة**: تعديل واحد في مكان واحد
5. ✅ **دقة**: تنسيق موحد للأرقام
6. ✅ **أمان**: قيم افتراضية في حال فشل التحميل

---

## ⚠️ ملاحظات هامة

1. **لا تستخدم قيم ثابتة** مثل `21` أو `'ر.س'` أو `0.15` في الكود
2. **استخدم Getters** بدلاً من المتغيرات لضمان التحديث الفوري
3. **استخدم `context.read`** للعمليات و `context.watch` للعرض
4. **اختبر** بعد كل تعديل بتغيير الإعدادات والتحقق من التطبيق

---

## 🚀 الخطوات التالية

1. ابدأ بشاشة واحدة كمثال
2. اختبر التكامل جيداً
3. طبق النمط على الشاشات الأخرى
4. راجع جميع الشاشات للتأكد من عدم وجود قيم ثابتة
