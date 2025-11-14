# تحسينات نظام الفواتير - المرحلة 1

## ✅ ما تم إنجازه

### 1. إعادة هيكلة المشروع
تم إنشاء هيكل جديد منظم:
```
lib/features/invoice/
├── models/
│   └── invoice_item_row.dart          # نموذج محسّن للأصناف
├── validators/
│   └── invoice_form_validator.dart    # نظام تحقق شامل
├── widgets/
│   └── barcode_scanner_screen.dart    # ماسح باركود/QR
└── providers/                         # (قريباً)
```

### 2. نموذج InvoiceItemRow محسّن
**الميزات:**
- ✅ دعم الباركود (`barcode` field)
- ✅ دعم صور الأصناف (`imageUrl` field)
- ✅ حسابات تلقائية ذكية مع 3 أولويات:
  1. إجمالي يدوي (`manualTotal`)
  2. سعر البيع لكل جرام (`sellingPricePerGram`)
  3. حساب تلقائي من سعر الذهب
- ✅ Serialization كامل (toJson/fromJson)
- ✅ دالة `toBackendJson()` للتوافق مع الـ Backend

### 3. نظام تحقق شامل (InvoiceFormValidator)
**قواعد التحقق:**
- ✅ الوزن (مع حدود معقولة وتحذيرات)
- ✅ العيار (مع تحذير للعيارات غير الشائعة)
- ✅ المصنعية
- ✅ الكمية
- ✅ السعر
- ✅ بيانات العميل (الاسم، الجوال، البريد)
- ✅ الدفع (المبلغ المدفوع، طريقة الدفع)
- ✅ **الباركود** (مع قواعد طول معقولة)

**مثال الاستخدام:**
```dart
TextFormField(
  validator: (value) => InvoiceFormValidator.validateWeight(value),
  // ...
)
```

### 4. ماسح الباركود/QR Code
**الميزات:**
- 📷 ماسح احترافي بواجهة عصرية
- 🔦 تشغيل/إطفاء الفلاش
- 🔄 تبديل الكاميرا
- ⌨️ إدخال يدوي كبديل
- 🎨 Overlay مع إطار تركيز
- ⚡ كشف تلقائي بدون تكرار

**الاستخدام:**
```dart
// من أي مكان في التطبيق:
final barcode = await Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => BarcodeScannerScreen(),
  ),
);

if (barcode != null) {
  // البحث عن الصنف بالباركود
  final item = await api.searchItemByBarcode(barcode);
}
```

---

## 📦 المتطلبات

### تثبيت المكتبات
```bash
cd frontend
flutter pub get
```

### أذونات الكاميرا

#### **Android** (`android/app/src/main/AndroidManifest.xml`):
```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-feature android:name="android.hardware.camera" android:required="false"/>
```

#### **iOS** (`ios/Runner/Info.plist`):
```xml
<key>NSCameraUsageDescription</key>
<string>نحتاج للوصول إلى الكاميرا لمسح الباركود</string>
```

---

## 🚀 الخطوات التالية

### المرحلة 2: تقسيم Widgets
- [ ] `CustomerStepWidget` - شاشة اختيار العميل
- [ ] `ItemsStepWidget` - شاشة الأصناف (مع دمج ماسح الباركود)
- [ ] `PaymentStepWidget` - شاشة الدفع
- [ ] `ReviewStepWidget` - شاشة المراجعة

### المرحلة 3: State Management
- [ ] إنشاء `InvoiceFormProvider` مع Riverpod
- [ ] نقل منطق الأعمال من StatefulWidget

### المرحلة 4: UI/UX Enhancement
- [ ] Material 3 Design
- [ ] Animations سلسة
- [ ] Responsive layouts

---

## 🎯 كيفية استخدام الميزات الجديدة

### 1. استخدام Validator
```dart
Form(
  child: Column(
    children: [
      TextFormField(
        validator: InvoiceFormValidator.validateWeight,
        decoration: InputDecoration(labelText: 'الوزن'),
      ),
      TextFormField(
        validator: InvoiceFormValidator.validateKarat,
        decoration: InputDecoration(labelText: 'العيار'),
      ),
    ],
  ),
)
```

### 2. استخدام Model الجديد
```dart
// إنشاء صنف
final item = InvoiceItemRow(
  itemName: 'خاتم ذهب',
  karat: 21.0,
  weight: 5.2,
  wage: 10.0,
  barcode: '1234567890',
);

// حساب الإجمالي
final updated = item.withCalculations(
  goldPrice24k: 80.5,
  exchangeRate: 3.75,
  taxRate: 0.15,
);

print('الإجمالي: ${updated.total}');
```

### 3. استخدام Barcode Scanner
```dart
ElevatedButton.icon(
  icon: Icon(Icons.qr_code_scanner),
  label: Text('مسح باركود'),
  onPressed: () async {
    final code = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BarcodeScannerScreen(),
      ),
    );
    
    if (code != null) {
      // البحث بالباركود
      setState(() {
        searchController.text = code;
      });
    }
  },
)
```

---

## 📝 ملاحظات مهمة

1. **الباركود في Backend**: تأكد من إضافة حقل `barcode` في جدول `items` في قاعدة البيانات
2. **الصور**: يمكن إضافة رفع صور الأصناف لاحقاً باستخدام `image_picker`
3. **Validation**: رسائل الخطأ بالعربية ومفصلة للمستخدم
4. **Performance**: الـ Model يستخدم `const` constructors للأداء الأفضل

---

## 🐛 المشاكل المعروفة

- ⚠️ المكتبة `mobile_scanner` تحتاج `flutter pub get` قبل الاستخدام
- ⚠️ يجب إضافة أذونات الكاميرا في AndroidManifest.xml و Info.plist

---

## 💡 اقتراحات للتحسين

1. إضافة دعم لأنواع باركود متعددة (EAN-13, Code128, QR, etc.)
2. إضافة history للباركودات الممسوحة مؤخراً
3. إضافة صوت تأكيد عند نجاح المسح
4. إضافة وضع "Batch Scanning" لمسح عدة أصناف بسرعة

---

**تم بواسطة:** GitHub Copilot  
**التاريخ:** 11 أكتوبر 2025
