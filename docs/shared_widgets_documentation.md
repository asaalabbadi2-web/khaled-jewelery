# 🎨 Shared Widgets - Documentation

**التاريخ:** 10 أكتوبر 2025  
**الحالة:** ✅ **مكتمل 100%**

---

## 📁 الملفات المنشأة

```
frontend/lib/widgets/
├── gold_type_selector.dart        (Widget لاختيار نوع الذهب)
├── return_reason_input.dart       (Widget لإدخال سبب الإرجاع)
├── original_invoice_selector.dart (Widget لاختيار الفاتورة الأصلية)
└── widgets.dart                   (Index file للتصدير)
```

---

## 1️⃣ Gold Type Selector Widget

### الغرض:
Widget مشترك لاختيار نوع الذهب (جديد/كسر) في شاشات الفواتير.

### الميزات:
- ✅ Dropdown بخيارين: ذهب جديد / ذهب كسر
- ✅ Icons ملونة (أخضر للجديد، برتقالي للكسر)
- ✅ دعم bilingual (عربي/إنجليزي)
- ✅ Validation تلقائي
- ✅ يمكن تعطيله (enabled/disabled)
- ✅ Label قابل للتخصيص

### الاستخدام:
```dart
import '../widgets/widgets.dart';

GoldTypeSelector(
  selectedGoldType: goldType,  // 'new' أو 'scrap'
  onChanged: (value) {
    setState(() {
      goldType = value!;
    });
  },
  isEnabled: true,  // optional
  labelText: 'نوع الذهب',  // optional
)
```

### Properties:
| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `selectedGoldType` | String | ✅ | - | القيمة الحالية ('new' أو 'scrap') |
| `onChanged` | ValueChanged<String?> | ✅ | - | Callback عند التغيير |
| `isEnabled` | bool | ❌ | true | تفعيل/تعطيل الحقل |
| `labelText` | String? | ❌ | 'نوع الذهب' | نص التسمية |

### أماكن الاستخدام:
- ✅ `add_invoice_screen.dart` (lines ~1072)
- يظهر فقط في فواتير الشراء (شراء من عميل، شراء من مورد)

---

## 2️⃣ Return Reason Input Widget

### الغرض:
Widget مشترك لإدخال سبب الإرجاع في شاشات المرتجعات.

### الميزات:
- ✅ TextField متعدد الأسطر (default: 4 أسطر)
- ✅ Validation تلقائي (مطلوب + 5 أحرف كحد أدنى)
- ✅ دعم bilingual
- ✅ Icon معبرة (comment icon)
- ✅ Helper text توضيحي
- ✅ خيارات قابلة للتخصيص

### الاستخدام:
```dart
import '../widgets/widgets.dart';

ReturnReasonInput(
  controller: _returnReasonController,
  isRequired: true,  // optional
  maxLines: 4,  // optional
  labelText: 'سبب الإرجاع',  // optional
  hintText: 'أدخل سبب إرجاع البضاعة...',  // optional
  helperText: 'مطلوب: اذكر السبب بشكل واضح',  // optional
)
```

### Properties:
| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `controller` | TextEditingController | ✅ | - | Controller للحقل |
| `isRequired` | bool | ❌ | true | هل الحقل مطلوب |
| `maxLines` | int | ❌ | 4 | عدد الأسطر |
| `labelText` | String? | ❌ | 'سبب الإرجاع' | نص التسمية |
| `hintText` | String? | ❌ | 'أدخل سبب...' | نص المساعدة |
| `helperText` | String? | ❌ | 'مطلوب...' | نص توضيحي |

### Validation Rules:
1. ✅ **Required**: إذا كان `isRequired = true`
2. ✅ **Min Length**: 5 أحرف كحد أدنى
3. ✅ **Trim**: يزيل المسافات من البداية والنهاية

### أماكن الاستخدام:
- ✅ `add_return_invoice_screen.dart` (Step 3 - lines ~571)
- استخدام في جميع أنواع المرتجعات

---

## 3️⃣ Original Invoice Selector Widget

### الغرض:
Widget مشترك لاختيار الفاتورة الأصلية عند إنشاء مرتجع.

### الميزات:
- ✅ Card قابل للضغط لفتح Dialog
- ✅ Dialog مع قائمة الفواتير القابلة للإرجاع
- ✅ Icons معبرة (check/block) حسب حالة الإرجاع
- ✅ عرض تفاصيل الفاتورة (ID, التاريخ، المبلغ، العميل/المورد)
- ✅ Filters تلقائية (حسب النوع، العميل، المورد)
- ✅ Error handling كامل
- ✅ دعم bilingual

### الاستخدام:
```dart
import '../widgets/widgets.dart';

OriginalInvoiceSelector(
  api: widget.api,
  invoiceType: 'بيع',  // نوع الفاتورة الأصلية
  customerId: 123,  // optional
  supplierId: 456,  // optional
  selectedInvoice: selectedOriginalInvoice,  // optional
  onInvoiceSelected: (invoice) {
    setState(() {
      selectedOriginalInvoice = invoice;
      _loadItems(invoice['id']);
    });
  },
)
```

### Properties:
| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `api` | ApiService | ✅ | - | API service للاتصال |
| `invoiceType` | String | ✅ | - | نوع الفاتورة المطلوبة |
| `customerId` | int? | ❌ | null | فلترة حسب العميل |
| `supplierId` | int? | ❌ | null | فلترة حسب المورد |
| `selectedInvoice` | Map? | ❌ | null | الفاتورة المختارة حالياً |
| `onInvoiceSelected` | ValueChanged | ✅ | - | Callback عند الاختيار |

### API Integration:
```dart
// يستدعي:
final response = await api.getReturnableInvoices(
  invoiceType: invoiceType,
  customerId: customerId,
  supplierId: supplierId,
);
```

### Dialog UI:
```
┌─────────────────────────────┐
│ اختر الفاتورة الأصلية       │
├─────────────────────────────┤
│ ┌─────────────────────────┐ │
│ │ #123 | عميل أحمد        │ │ ✅
│ │ التاريخ: 2025-10-01    │ │
│ │ المبلغ: 1500.00        │ │
│ └─────────────────────────┘ │
│ ┌─────────────────────────┐ │
│ │ #124 | عميل محمد        │ │ ❌ (لا يمكن الإرجاع)
│ │ التاريخ: 2025-09-30    │ │
│ │ المبلغ: 2000.00        │ │
│ └─────────────────────────┘ │
├─────────────────────────────┤
│             [إلغاء]          │
└─────────────────────────────┘
```

### أماكن الاستخدام:
- ✅ `add_return_invoice_screen.dart` (Step 1 - lines ~443)
- يستخدم في جميع أنواع المرتجعات

---

## 4️⃣ Widgets Index File

### الغرض:
ملف `widgets.dart` لتصدير جميع الـ widgets المشتركة.

### الاستخدام:
```dart
// بدلاً من:
import '../widgets/gold_type_selector.dart';
import '../widgets/return_reason_input.dart';
import '../widgets/original_invoice_selector.dart';

// استخدم:
import '../widgets/widgets.dart';
```

---

## 📊 الإحصائيات

### الكود المحذوف (Refactored):
- `add_return_invoice_screen.dart`: ~80 سطر (dialog الفاتورة الأصلية)
- `add_return_invoice_screen.dart`: ~15 سطر (return reason input)
- `add_invoice_screen.dart`: ~10 سطر (gold type selector)
- **الإجمالي:** ~105 سطر محذوف

### الكود المضاف:
- `gold_type_selector.dart`: 64 سطر
- `return_reason_input.dart`: 56 سطر
- `original_invoice_selector.dart`: 184 سطر
- `widgets.dart`: 5 سطر
- **الإجمالي:** 309 سطر جديد

### Net Change:
```
الكود المضاف: +309 سطر
الكود المحذوف: -105 سطر
الكود الصافي:  +204 سطر
```

### الفوائد:
- ✅ **Reusability**: استخدام نفس الـ widgets في أماكن متعددة
- ✅ **Maintainability**: تحديث في مكان واحد يؤثر على كل الاستخدامات
- ✅ **Consistency**: UI/UX موحد في كل الشاشات
- ✅ **Testability**: widgets مستقلة سهلة الاختبار
- ✅ **Readability**: كود أنظف وأسهل للقراءة

---

## 🎯 أماكن الاستخدام

### GoldTypeSelector:
| Screen | Lines | Usage |
|--------|-------|-------|
| `add_invoice_screen.dart` | 1072-1078 | شراء من عميل، شراء من مورد |

### ReturnReasonInput:
| Screen | Lines | Usage |
|--------|-------|-------|
| `add_return_invoice_screen.dart` | 571 | Step 3 - جميع المرتجعات |

### OriginalInvoiceSelector:
| Screen | Lines | Usage |
|--------|-------|-------|
| `add_return_invoice_screen.dart` | 443-453 | Step 1 - جميع المرتجعات |

---

## 🧪 سيناريوهات الاختبار

### Test 1: GoldTypeSelector
```dart
// Test changing gold type
testWidgets('GoldTypeSelector changes value', (tester) async {
  String goldType = 'new';
  
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GoldTypeSelector(
          selectedGoldType: goldType,
          onChanged: (value) {
            goldType = value!;
          },
        ),
      ),
    ),
  );
  
  // Find dropdown
  expect(find.text('ذهب جديد'), findsOneWidget);
  
  // Tap dropdown
  await tester.tap(find.byType(DropdownButtonFormField));
  await tester.pumpAndSettle();
  
  // Select scrap
  await tester.tap(find.text('ذهب كسر').last);
  await tester.pumpAndSettle();
  
  // Verify change
  expect(goldType, 'scrap');
});
```

### Test 2: ReturnReasonInput Validation
```dart
testWidgets('ReturnReasonInput validates input', (tester) async {
  final controller = TextEditingController();
  
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Form(
          child: ReturnReasonInput(controller: controller),
        ),
      ),
    ),
  );
  
  // Try to validate empty
  final formState = tester.state<FormState>(find.byType(Form));
  expect(formState.validate(), false);
  
  // Enter short text
  await tester.enterText(find.byType(TextFormField), 'abc');
  expect(formState.validate(), false);
  
  // Enter valid text
  await tester.enterText(find.byType(TextFormField), 'سبب إرجاع صحيح');
  expect(formState.validate(), true);
});
```

### Test 3: OriginalInvoiceSelector Dialog
```dart
testWidgets('OriginalInvoiceSelector opens dialog', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OriginalInvoiceSelector(
          api: mockApi,
          invoiceType: 'بيع',
          onInvoiceSelected: (invoice) {},
        ),
      ),
    ),
  );
  
  // Find card
  expect(find.byType(Card), findsOneWidget);
  
  // Tap card
  await tester.tap(find.byType(Card));
  await tester.pumpAndSettle();
  
  // Verify dialog opened
  expect(find.text('اختر الفاتورة الأصلية'), findsOneWidget);
});
```

---

## ✅ الخلاصة

### ما تم إنجازه:
- ✅ إنشاء 3 widgets مشتركة
- ✅ استخدام الـ widgets في الشاشات الموجودة
- ✅ تقليل التكرار في الكود
- ✅ توثيق كامل للاستخدام

### التأثير:
- 🎯 **DRY Principle**: Don't Repeat Yourself
- 📦 **Modularity**: كل widget مستقل
- 🔧 **Maintainability**: صيانة أسهل
- 🎨 **Consistency**: تصميم موحد

---

**الحالة:** ✅ **100% مكتمل**  
**التقدم الإجمالي:** 100% (10/10 مراحل - المهمة 7 مكتملة)  
**التاريخ:** 10 أكتوبر 2025
