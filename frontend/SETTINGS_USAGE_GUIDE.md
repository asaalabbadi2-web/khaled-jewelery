# دليل استخدام الإعدادات العامة في جميع الشاشات

## نظام الإعدادات المركزي

تم تحديث `SettingsProvider` ليكون مركزاً لجميع الإعدادات العامة للتطبيق ويتم تطبيقها فوراً على جميع الشاشات بعد الحفظ.

## الإعدادات المتوفرة

### 1. العيار الرئيسي (Main Karat)
```dart
final settingsProvider = Provider.of<SettingsProvider>(context);
int mainKarat = settingsProvider.mainKarat; // القيمة الافتراضية: 21
```

### 2. عدد الأصفار بعد الفاصلة (Decimal Places)
```dart
int decimalPlaces = settingsProvider.decimalPlaces; // القيمة الافتراضية: 2
String formattedNumber = settingsProvider.formatNumber(12.3456); // "12.35"
```

### 3. رمز العملة (Currency Symbol)
```dart
String currency = settingsProvider.currencySymbol; // القيمة الافتراضية: "ر.س"
```

### 4. إعدادات الضريبة (Tax Settings)
```dart
bool taxEnabled = settingsProvider.taxEnabled;
double taxRate = settingsProvider.taxRate; // 0.15 (15%)
double taxAmount = settingsProvider.calculateTax(1000); // 150.0
```

### 5. إعدادات الخصم (Discount Settings)
```dart
bool allowDiscount = settingsProvider.allowDiscount;
double defaultDiscountPercent = settingsProvider.defaultDiscountPercent;
double discount = settingsProvider.calculateDiscount(1000); // باستخدام النسبة الافتراضية
double customDiscount = settingsProvider.calculateDiscount(1000, customRate: 0.1); // 100.0
```

### 6. بيانات الشركة (Company Info)
```dart
String companyName = settingsProvider.companyName;
String companyAddress = settingsProvider.companyAddress;
String companyPhone = settingsProvider.companyPhone;
String companyTaxNumber = settingsProvider.companyTaxNumber;
bool showLogo = settingsProvider.showCompanyLogo;
```

### 7. تنسيق التاريخ (Date Format)
```dart
String dateFormat = settingsProvider.dateFormat; // "DD/MM/YYYY"
```

### 8. بادئة الفاتورة (Invoice Prefix)
```dart
String invoicePrefix = settingsProvider.invoicePrefix; // "INV"
```

## استخدام الإعدادات في الشاشات

### مثال 1: شاشة الفواتير

```dart
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

class InvoiceScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    
    return Column(
      children: [
        // عرض العيار الرئيسي
        Text('العيار الافتراضي: ${settings.mainKarat}'),
        
        // عرض السعر مع عدد الأصفار المحدد
        Text('السعر: ${settings.formatNumber(1234.5678)} ${settings.currencySymbol}'),
        
        // حساب الضريبة تلقائياً
        if (settings.taxEnabled)
          Text('الضريبة: ${settings.formatNumber(settings.calculateTax(1000))}'),
      ],
    );
  }
}
```

### مثال 2: حساب الإجمالي مع الضريبة والخصم

```dart
double calculateTotal(double subtotal, SettingsProvider settings) {
  double total = subtotal;
  
  // تطبيق الخصم إذا كان مفعلاً
  if (settings.allowDiscount) {
    double discount = settings.calculateDiscount(total);
    total -= discount;
  }
  
  // إضافة الضريبة إذا كانت مفعلة
  if (settings.taxEnabled) {
    double tax = settings.calculateTax(total);
    total += tax;
  }
  
  return total;
}

// في الواجهة
final settings = Provider.of<SettingsProvider>(context);
double total = calculateTotal(1000, settings);
Text('الإجمالي: ${settings.formatNumber(total)} ${settings.currencySymbol}');
```

### مثال 3: عرض بيانات الشركة في طباعة الفاتورة

```dart
Widget buildInvoiceHeader(SettingsProvider settings) {
  return Column(
    children: [
      if (settings.showCompanyLogo)
        Image.asset('assets/logo.png'),
      Text(settings.companyName, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      Text(settings.companyAddress),
      Text('هاتف: ${settings.companyPhone}'),
      if (settings.companyTaxNumber.isNotEmpty)
        Text('الرقم الضريبي: ${settings.companyTaxNumber}'),
    ],
  );
}
```

## كيفية الاستماع للتغييرات

### الطريقة 1: Consumer (موصى بها للأداء)
```dart
Consumer<SettingsProvider>(
  builder: (context, settings, child) {
    return Text('العيار: ${settings.mainKarat}');
  },
)
```

### الطريقة 2: Provider.of مع listen: true (افتراضي)
```dart
final settings = Provider.of<SettingsProvider>(context); // يستمع للتغييرات
```

### الطريقة 3: Provider.of مع listen: false (للعمليات)
```dart
final settings = Provider.of<SettingsProvider>(context, listen: false); // لا يستمع
await settings.updateSettings({...});
```

## تحديث الإعدادات

```dart
final settings = Provider.of<SettingsProvider>(context, listen: false);

await settings.updateSettings({
  'main_karat': 22,
  'decimal_places': 3,
  'tax_enabled': true,
  'tax_rate': 0.15,
});

// سيتم تطبيق التغييرات فوراً على جميع الشاشات المستمعة
```

## الميزات الرئيسية

✅ **حفظ محلي تلقائي**: تُحفظ الإعدادات في SharedPreferences لتكون متاحة عند إعادة فتح التطبيق
✅ **تطبيق فوري**: جميع الشاشات المستمعة تتحدث فوراً عند تغيير الإعدادات
✅ **دوال مساعدة**: دوال جاهزة للتنسيق والحساب
✅ **آمن من الأخطاء**: معالجة تلقائية للقيم الخاطئة مع قيم افتراضية

## ملاحظات هامة

1. استخدم `Consumer` للأجزاء الصغيرة التي تحتاج للتحديث فقط لتحسين الأداء
2. استخدم `listen: false` عند استدعاء دوال التحديث لتجنب إعادة البناء غير الضرورية
3. جميع الإعدادات محمية بقيم افتراضية آمنة
4. التحديثات تُطبق على الـ API والـ SharedPreferences معاً
