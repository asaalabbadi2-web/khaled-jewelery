# دليل ضبط موقع العناصر على القوالب الجاهزة
# Template Element Positioning Guide

## 📋 نظرة عامة | Overview

تم إضافة نظام متقدم لضبط موقع عناصر الفاتورة على القوالب الجاهزة. يسمح هذا النظام بسحب وإفلات العناصر وضبط موقعها بدقة بالبيكسل.

An advanced system for positioning invoice elements on pre-printed templates. This system allows drag-and-drop positioning with pixel-perfect accuracy.

---

## ✨ الميزات الرئيسية | Key Features

### 1. سحب وإفلات العناصر | Drag & Drop Elements
```dart
- سحب العناصر بحرية على الصفحة
- التصاق تلقائي بالشبكة (Snap to Grid)
- معاينة حية أثناء السحب
```

### 2. ضبط دقيق | Precise Positioning
```dart
- تحديد الموقع بالإحداثيات (X, Y)
- تغيير الحجم (Width, Height)
- ضبط حجم الخط (Font Size)
```

### 3. أدوات مساعدة | Helper Tools
```dart
- شبكة قابلة للتخصيص (Grid)
- تكبير وتصغير (Zoom In/Out)
- مقابض تغيير الحجم (Resize Handles)
```

### 4. حفظ التخطيط | Save Layout
```dart
- حفظ تلقائي للتخطيط
- استعادة التخطيط عند الفتح
- إعادة تعيين للوضع الافتراضي
```

---

## 🎯 العناصر القابلة للتخطيط | Positionable Elements

### عناصر الرأس | Header Elements
| العنصر | الوصف | الحجم الافتراضي |
|--------|-------|----------------|
| **الشعار** | Logo | 100x100 |
| **اسم الشركة** | Company Name | 200x30 |
| **رقم الفاتورة** | Invoice Number | 150x25 |
| **التاريخ** | Date | 150x25 |

### معلومات العميل | Customer Info
| العنصر | الوصف | الحجم الافتراضي |
|--------|-------|----------------|
| **اسم العميل** | Customer Name | 200x25 |
| **هاتف العميل** | Customer Phone | 150x25 |

### المحتوى | Content
| العنصر | الوصف | الحجم الافتراضي |
|--------|-------|----------------|
| **جدول الأصناف** | Items Table | 500x300 |
| **الملاحظات** | Notes | 400x60 |

### الإجماليات | Totals
| العنصر | الوصف | الحجم الافتراضي |
|--------|-------|----------------|
| **المجموع الفرعي** | Subtotal | 150x25 |
| **الضريبة** | Tax | 150x25 |
| **الإجمالي** | Total | 150x30 |

### التذييل | Footer
| العنصر | الوصف | الحجم الافتراضي |
|--------|-------|----------------|
| **التذييل** | Footer Text | 500x30 |
| **رمز QR** | QR Code | 100x100 |
| **الباركود** | Barcode | 150x50 |

---

## 🚀 طريقة الاستخدام | How to Use

### 1. فتح شاشة التخطيط | Open Positioning Screen

#### من مصمم القوالب | From Template Designer
```dart
1. افتح شاشة "تصميم قالب الطباعة"
   Open "Print Template Designer" screen

2. اضغط على زر "ضبط موقع العناصر" في شريط الأدوات
   Click "Position Elements" button in toolbar

3. ستفتح شاشة التخطيط مع جميع العناصر
   Positioning screen will open with all elements
```

### 2. سحب العناصر | Dragging Elements

```dart
// خطوات السحب
1. اضغط على العنصر في القائمة اليمنى لتحديده
   Click element in right panel to select it

2. اسحب العنصر على الصفحة للموقع المطلوب
   Drag element on canvas to desired position

3. العنصر المحدد يظهر بإطار ذهبي
   Selected element shows golden border

4. استخدم مقابض تغيير الحجم في الزوايا
   Use resize handles in corners
```

### 3. الضبط الدقيق | Fine Tuning

#### استخدام حقول الإدخال | Using Input Fields
```dart
// في لوحة الخصائص (أسفل القائمة)
In properties panel (bottom of sidebar):

X: موضع أفقي (0-595)
   Horizontal position (0-595)

Y: موضع عمودي (0-842)
   Vertical position (0-842)

العرض: عرض العنصر
Width: Element width

الارتفاع: ارتفاع العنصر
Height: Element height

حجم الخط: حجم النص (للعناصر النصية)
Font Size: Text size (for text elements)
```

### 4. أدوات الشبكة | Grid Tools

#### تفعيل الشبكة | Enable Grid
```dart
IconButton(
  icon: Icons.grid_on,
  tooltip: 'إظهار/إخفاء الشبكة',
)
// الشبكة تساعد في محاذاة العناصر بدقة
Grid helps align elements precisely
```

#### الالتصاق بالشبكة | Snap to Grid
```dart
IconButton(
  icon: Icons.grid_3x3,
  tooltip: 'الالتصاق بالشبكة',
)
// العناصر تلتصق تلقائياً بخطوط الشبكة
Elements automatically snap to grid lines
```

### 5. التكبير والتصغير | Zoom Controls

```dart
// تكبير
IconButton(
  icon: Icons.zoom_in,
  onPressed: () => _zoom += 0.1,
)

// تصغير
IconButton(
  icon: Icons.zoom_out,
  onPressed: () => _zoom -= 0.1,
)

// نطاق التكبير: 0.5x إلى 2.0x
Zoom range: 0.5x to 2.0x
```

---

## 💾 حفظ واستعادة التخطيط | Save & Load Layout

### حفظ التخطيط | Save Layout

```dart
// حفظ تلقائي
Automatic save via:

IconButton(
  icon: Icons.save,
  onPressed: _saveLayout,
)

// البيانات المحفوظة
Saved data includes:
- موقع كل عنصر (x, y)
  Position of each element
- حجم كل عنصر (width, height)
  Size of each element
- حجم الخط (fontSize)
  Font size
- حالة الإظهار/الإخفاء (visible)
  Visibility state
```

### تنسيق التخزين | Storage Format

```json
{
  "company_name": {
    "id": "company_name",
    "nameAr": "اسم الشركة",
    "nameEn": "Company Name",
    "x": 50.0,
    "y": 50.0,
    "width": 200.0,
    "height": 30.0,
    "fontSize": 20.0,
    "visible": true
  },
  "logo": {
    "id": "logo",
    "nameAr": "الشعار",
    "nameEn": "Logo",
    "x": 450.0,
    "y": 30.0,
    "width": 100.0,
    "height": 100.0,
    "fontSize": null,
    "visible": true
  }
}
```

### استعادة التخطيط | Load Layout

```dart
// يتم تحميل التخطيط تلقائياً عند فتح الشاشة
Layout loads automatically on screen open

Future<void> _loadLayout() async {
  final prefs = await SharedPreferences.getInstance();
  final layoutJson = prefs.getString('template_positioning');
  
  if (layoutJson != null) {
    final layout = json.decode(layoutJson);
    // تطبيق المواقع المحفوظة
    // Apply saved positions
  }
}
```

---

## 🎨 واجهة المستخدم | User Interface

### تخطيط الشاشة | Screen Layout

```
┌─────────────────────────────────────────────────────────┐
│  ضبط موقع العناصر          [⊞][⊡][+][-][💾][↻]        │
├───────────────┬─────────────────────────────────────────┤
│  📂 العناصر  │                                         │
│               │          منطقة التخطيط                  │
│  ☑ الشعار    │        Canvas Area                      │
│  ☑ اسم الشركة│                                         │
│  ☑ رقم الفاتورة│         [العناصر القابلة]              │
│  ...          │         [للسحب والإفلات]               │
│               │                                         │
├───────────────┤                                         │
│ خصائص العنصر │                                         │
│  X: [50   ]  │                                         │
│  Y: [50   ]  │                                         │
│  W: [200  ]  │                                         │
│  H: [30   ]  │                                         │
└───────────────┴─────────────────────────────────────────┘
```

### قائمة العناصر | Elements List

```dart
Card(
  child: ListTile(
    leading: Icon(_getElementIcon(id)),
    title: Text('اسم العنصر'),
    subtitle: Text('X: 50, Y: 50'),
    trailing: Checkbox(value: visible),
    onTap: () => _selectElement(id),
  ),
)
```

### لوحة الخصائص | Properties Panel

```dart
Container(
  padding: EdgeInsets.all(16),
  child: Column(
    children: [
      Text('خصائص العنصر'),
      TextField(label: 'X', value: x),
      TextField(label: 'Y', value: y),
      TextField(label: 'العرض', value: width),
      TextField(label: 'الارتفاع', value: height),
      TextField(label: 'حجم الخط', value: fontSize),
    ],
  ),
)
```

---

## 🔧 أمثلة عملية | Practical Examples

### مثال 1: ضبط الشعار | Example 1: Position Logo

```dart
// 1. حدد الشعار من القائمة
Select logo from list

// 2. اسحبه للزاوية العلوية اليسرى
Drag to top-right corner

// 3. اضبط الحجم 150x150
Adjust size to 150x150

ElementPosition(
  id: 'logo',
  x: 450,      // قريب من حافة الصفحة
  y: 30,       // في الأعلى
  width: 150,  // حجم أكبر
  height: 150,
)
```

### مثال 2: جدول الأصناف | Example 2: Items Table

```dart
// 1. حدد جدول الأصناف
Select items table

// 2. اسحبه للمنطقة الوسطى
Drag to middle area

// 3. وسّع العرض ليملأ الصفحة
Expand width to fill page

ElementPosition(
  id: 'items_table',
  x: 30,       // هامش صغير
  y: 250,      // بعد الرأس
  width: 535,  // عرض كامل تقريباً
  height: 350, // ارتفاع كافي
)
```

### مثال 3: الإجماليات | Example 3: Totals

```dart
// 1. حدد عناصر الإجماليات (المجموع، الضريبة، الإجمالي)
Select total elements

// 2. رتبها بشكل عمودي في الأسفل
Arrange vertically at bottom

ElementPosition(id: 'subtotal', x: 400, y: 580, width: 150, height: 25),
ElementPosition(id: 'tax',      x: 400, y: 610, width: 150, height: 25),
ElementPosition(id: 'total',    x: 400, y: 650, width: 150, height: 30),
```

### مثال 4: رمز QR والباركود | Example 4: QR & Barcode

```dart
// 1. ضع رمز QR في الزاوية اليسرى السفلية
Place QR code in bottom-left corner

ElementPosition(
  id: 'qr_code',
  x: 50,
  y: 600,
  width: 100,
  height: 100,
)

// 2. ضع الباركود في الأسفل الأوسط
Place barcode in bottom-center

ElementPosition(
  id: 'barcode',
  x: 200,
  y: 700,
  width: 200,
  height: 50,
)
```

---

## 📐 إحداثيات الصفحة | Page Coordinates

### نظام الإحداثيات | Coordinate System

```
(0,0) ─────────────────────────── (595,0)
  │                                   │
  │                                   │
  │         صفحة A4                   │
  │         A4 Page                   │
  │                                   │
  │                                   │
(0,842) ─────────────────────── (595,842)

العرض (Width): 595 بيكسل (210mm @ 72 DPI)
الارتفاع (Height): 842 بيكسل (297mm @ 72 DPI)
```

### المناطق الآمنة | Safe Zones

```dart
// الهوامش الموصى بها
Recommended margins:

الأعلى (Top):    30-50 بيكسل
الأسفل (Bottom): 30-50 بيكسل
اليمين (Right):  30-50 بيكسل
اليسار (Left):   30-50 بيكسل

// منطقة المحتوى الآمنة
Safe content area:
X: 30-565 بيكسل
Y: 30-812 بيكسل
```

### أحجام العناصر الموصى بها | Recommended Element Sizes

```dart
// الشعار | Logo
100x100 إلى 150x150

// العناوين | Titles
العرض: 150-300، الارتفاع: 25-40
Width: 150-300, Height: 25-40

// النصوص | Text
العرض: 100-400، الارتفاع: 20-30
Width: 100-400, Height: 20-30

// الجداول | Tables
العرض: 400-535، الارتفاع: 200-400
Width: 400-535, Height: 200-400

// الرموز (QR/Barcode) | Codes
QR: 80x80 إلى 120x120
Barcode: 150x50 إلى 250x60
```

---

## 🎯 حالات استخدام | Use Cases

### 1. فواتير بترويسة جاهزة | Pre-printed Letterhead

```dart
// السيناريو: ورق بترويسة الشركة مطبوع مسبقاً
Scenario: Pre-printed company letterhead

// الحل:
Solution:
1. أخفِ عناصر الرأس (الشعار، اسم الشركة، العنوان)
   Hide header elements (logo, company name, address)

2. ابدأ برقم الفاتورة من Y: 150
   Start invoice number from Y: 150

3. حافظ على باقي العناصر كما هي
   Keep remaining elements as is

_elements['logo'].visible = false;
_elements['company_name'].visible = false;
_elements['address'].visible = false;
```

### 2. قوالب بمساحات محددة | Templates with Fixed Areas

```dart
// السيناريو: قالب بمربعات محددة مسبقاً
Scenario: Template with pre-defined boxes

// الحل:
Solution:
1. قس أبعاد المربعات على القالب
   Measure box dimensions on template

2. اضبط موقع وحجم العناصر لتطابق المربعات
   Adjust element position and size to match boxes

// مثال: مربع معلومات العميل
Example: Customer info box
X: 50, Y: 180, Width: 250, Height: 80

_elements['customer_name'].x = 60;
_elements['customer_name'].y = 190;
_elements['customer_phone'].x = 60;
_elements['customer_phone'].y = 220;
```

### 3. فواتير بتذييل ثابت | Fixed Footer Templates

```dart
// السيناريو: تذييل مطبوع مع معلومات قانونية
Scenario: Pre-printed footer with legal info

// الحل:
Solution:
1. أخفِ عنصر التذييل
   Hide footer element

2. اضبط ارتفاع جدول الأصناف
   Adjust items table height

3. ضع الإجماليات فوق التذييل المطبوع
   Place totals above printed footer

_elements['footer'].visible = false;
_elements['items_table'].height = 280;
_elements['total'].y = 600; // فوق التذييل
```

### 4. فواتير حرارية | Thermal Receipts

```dart
// السيناريو: طباعة حرارية بعرض 80mm
Scenario: Thermal printing 80mm width

// الحل:
Solution:
1. غيّر حجم الصفحة
   Change page size

_pageWidth = 226;  // 80mm @ 72 DPI
_pageHeight = 600; // متغير حسب المحتوى

2. رتب العناصر عمودياً
   Arrange elements vertically

3. قلل أحجام الخطوط
   Reduce font sizes

_elements.forEach((key, element) {
  element.width = 180; // عرض محدود
  if (element.fontSize != null) {
    element.fontSize = element.fontSize! * 0.8;
  }
});
```

---

## 🔍 نصائح وحيل | Tips & Tricks

### 1. استخدام الشبكة بفعالية | Using Grid Effectively

```dart
// للمحاذاة الدقيقة
For precise alignment:

✓ فعّل الشبكة والالتصاق
  Enable grid and snap

✓ استخدم مسافات 10 بيكسل
  Use 10-pixel intervals

✓ حاذِ العناصر المتشابهة
  Align similar elements

// مثال
_gridSize = 10;
_snapToGrid = true;
```

### 2. تجميع العناصر | Grouping Elements

```dart
// رتب العناصر المترابطة معاً
Arrange related elements together:

// مجموعة معلومات العميل
Customer info group:
X: 50-250 (نفس المحاذاة)
Y: 200, 225, 250 (بفارق 25)

// مجموعة الإجماليات
Totals group:
X: 400 (نفس المحاذاة)
Y: 580, 610, 640 (بفارق 30)
```

### 3. الاختبار على القالب الفعلي | Testing on Actual Template

```dart
// خطوات الاختبار
Testing steps:

1. اطبع صفحة اختبار على القالب
   Print test page on template

2. قس المسافات بالمسطرة
   Measure distances with ruler

3. اضبط الإحداثيات بناءً على القياسات
   Adjust coordinates based on measurements

4. كرر حتى المطابقة الدقيقة
   Repeat until perfect match
```

### 4. حفظ قوالب متعددة | Multiple Template Versions

```dart
// للقوالب المختلفة
For different templates:

// قالب A
Template A:
prefs.setString('layout_template_a', json.encode(layout));

// قالب B
Template B:
prefs.setString('layout_template_b', json.encode(layout));

// تبديل بين القوالب
Switch between templates:
String currentTemplate = 'layout_template_a';
```

---

## 🐛 استكشاف الأخطاء | Troubleshooting

### مشكلة: العناصر تتداخل | Issue: Elements Overlap

```dart
// الحل
Solution:

1. افحص الإحداثيات والأحجام
   Check coordinates and sizes

2. استخدم الشبكة للمحاذاة
   Use grid for alignment

3. أعد ترتيب العناصر عمودياً
   Rearrange elements vertically

// فحص التداخل
Check overlap:
if (element1.x < element2.x + element2.width &&
    element1.x + element1.width > element2.x &&
    element1.y < element2.y + element2.height &&
    element1.y + element1.height > element2.y) {
  // تداخل موجود
  // Overlap detected
}
```

### مشكلة: العنصر خارج الصفحة | Issue: Element Off Page

```dart
// الحل
Solution:

1. افحص قيم X و Y
   Check X and Y values

2. تأكد من المنطقة الآمنة
   Ensure safe zone

// قيود الموقع
Position constraints:
element.x = element.x.clamp(0, _pageWidth - element.width);
element.y = element.y.clamp(0, _pageHeight - element.height);
```

### مشكلة: النص مقطوع | Issue: Text Truncated

```dart
// الحل
Solution:

1. زد عرض العنصر
   Increase element width

2. قلل حجم الخط
   Reduce font size

3. استخدم نص أقصر
   Use shorter text

// حساب العرض المطلوب
Calculate required width:
double requiredWidth = text.length * fontSize * 0.6;
element.width = max(element.width, requiredWidth);
```

---

## 📱 التكامل مع الطباعة | Print Integration

### استخدام التخطيط في الطباعة | Using Layout in Printing

```dart
// 1. تحميل التخطيط المحفوظ
Load saved layout:

final prefs = await SharedPreferences.getInstance();
final layoutJson = prefs.getString('template_positioning');
final layout = json.decode(layoutJson);

// 2. تطبيق المواقع في PDF
Apply positions in PDF:

pw.Positioned(
  left: layout['company_name']['x'],
  top: layout['company_name']['y'],
  child: pw.Text(
    companyName,
    style: pw.TextStyle(
      fontSize: layout['company_name']['fontSize'],
    ),
  ),
)

// 3. احترام حالة الإظهار/الإخفاء
Respect visibility:

if (layout['logo']['visible'] == true) {
  // اعرض الشعار
  // Show logo
}
```

### مثال كامل | Complete Example

```dart
Future<pw.Document> _generatePdfWithLayout() async {
  final pdf = pw.Document();
  
  // تحميل التخطيط
  final prefs = await SharedPreferences.getInstance();
  final layoutJson = prefs.getString('template_positioning');
  final layout = json.decode(layoutJson) ?? {};

  pdf.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (context) {
        return pw.Stack(
          children: [
            // الشعار
            if (layout['logo']?['visible'] == true)
              pw.Positioned(
                left: layout['logo']['x'],
                top: layout['logo']['y'],
                width: layout['logo']['width'],
                height: layout['logo']['height'],
                child: pw.Container(
                  color: PdfColors.grey300,
                  child: pw.Center(child: pw.Text('LOGO')),
                ),
              ),
            
            // اسم الشركة
            if (layout['company_name']?['visible'] == true)
              pw.Positioned(
                left: layout['company_name']['x'],
                top: layout['company_name']['y'],
                child: pw.Text(
                  'محل ياسر للذهب',
                  style: pw.TextStyle(
                    fontSize: layout['company_name']['fontSize'],
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            
            // باقي العناصر...
            // Rest of elements...
          ],
        );
      },
    ),
  );
  
  return pdf;
}
```

---

## 🎓 أفضل الممارسات | Best Practices

### 1. التخطيط الجيد | Good Layout

```dart
✓ استخدم هوامش متسقة (30-50 بيكسل)
  Use consistent margins (30-50 pixels)

✓ حافظ على محاذاة العناصر
  Keep elements aligned

✓ اترك مساحة بيضاء كافية
  Leave sufficient white space

✓ استخدم شبكة 10 أو 20 بيكسل
  Use 10 or 20 pixel grid

✗ لا تكدس العناصر
  Don't overcrowd elements

✗ لا تستخدم خطوط صغيرة جداً
  Don't use very small fonts

✗ لا تضع عناصر على الحواف
  Don't place elements at edges
```

### 2. الأداء | Performance

```dart
✓ احفظ التخطيط بعد التعديلات الكبيرة فقط
  Save layout only after major changes

✓ استخدم setState بحذر
  Use setState carefully

✓ حمّل التخطيط مرة واحدة عند الفتح
  Load layout once on open

// تحسين الأداء
Performance optimization:
Timer? _saveTimer;

void _debouncedSave() {
  _saveTimer?.cancel();
  _saveTimer = Timer(Duration(seconds: 1), _saveLayout);
}
```

### 3. سهولة الاستخدام | Usability

```dart
✓ اعرض إحداثيات العنصر المحدد
  Show selected element coordinates

✓ استخدم ألوان واضحة للعناصر المحددة
  Use clear colors for selected elements

✓ وفر طرق متعددة للتحديد (قائمة + نقر)
  Provide multiple selection methods

✓ أضف أزرار تراجع/إعادة
  Add undo/redo buttons
```

---

## 📊 مقارنة قبل وبعد | Before & After Comparison

### قبل: التخطيط الثابت | Before: Fixed Layout
```
❌ موقع ثابت لجميع العناصر
   Fixed position for all elements

❌ لا يتوافق مع القوالب الجاهزة
   Doesn't work with pre-printed templates

❌ صعوبة التعديل
   Difficult to modify

❌ يتطلب إعادة برمجة
   Requires reprogramming
```

### بعد: التخطيط المرن | After: Flexible Layout
```
✅ موقع قابل للتخصيص لكل عنصر
   Customizable position for each element

✅ يعمل مع أي قالب جاهز
   Works with any pre-printed template

✅ سهل التعديل عبر الواجهة
   Easy modification through UI

✅ لا يحتاج برمجة
   No programming needed
```

---

## 🚀 الخلاصة | Summary

### تم إضافة | Added
- ✅ شاشة ضبط موقع العناصر (TemplatePositioningScreen)
- ✅ 14 عنصر قابل للتخطيط
- ✅ سحب وإفلات مع التصاق تلقائي
- ✅ ضبط دقيق بالإحداثيات
- ✅ أدوات شبكة وتكبير/تصغير
- ✅ حفظ واستعادة التخطيط
- ✅ مقابض تغيير الحجم
- ✅ معاينة حية
- ✅ دعم كامل للعربية

### الملفات المعدلة | Modified Files
```
✅ frontend/lib/screens/template_positioning_screen.dart (جديد)
✅ frontend/lib/screens/print_template_designer_screen.dart
✅ TEMPLATE_POSITIONING_GUIDE.md (جديد)
```

### طريقة الوصول | Access Path
```
الطباعة → تصميم القالب → ضبط موقع العناصر
Printing → Template Designer → Position Elements
```

---

## 📞 الدعم | Support

للاستفسارات أو المشاكل، يرجى الرجوع إلى:
For questions or issues, please refer to:

- دليل مركز الطباعة: `PRINTING_CENTER_GUIDE.md`
- دليل تصميم القوالب: `PRINT_TEMPLATE_DESIGNER_GUIDE.md`
- دليل إعدادات الطباعة: `PRINT_SETTINGS_GUIDE.md`

---

**تم إنشاء هذا النظام لتسهيل استخدام القوالب الجاهزة مع نظام ياسر للذهب والمجوهرات**

**This system was created to facilitate using pre-printed templates with Yasar Gold & Jewelry POS System**
