# إصلاح مشكلة تطبيق التاريخ في دفتر الحسابات

## المشكلة

عند اختيار تاريخ من نافذة التصفية في:
- **دفتر الأستاذ العام** (`general_ledger_screen_v2.dart`)
- **دفتر أستاذ الحساب** (`account_ledger_screen.dart`)

لم يتم تطبيق التاريخ المختار - كانت الشاشة تعود لنفس البيانات بدون تصفية.

---

## السبب التقني

### المشكلة الأساسية: State Management في Dialog

عند استخدام `setState()` داخل `AlertDialog`، التحديث يحدث في **state النافذة المنبثقة** فقط، وليس في **state الشاشة الرئيسية**.

```dart
// ❌ الكود القديم (لا يعمل)
showDialog(
  context: context,
  builder: (context) => AlertDialog(
    content: OutlinedButton(
      onPressed: () async {
        final date = await showDatePicker(...);
        if (date != null) {
          setState(() {           // ⚠️ يُحدث state النافذة فقط!
            _startDate = date;    // لا يُحفظ عند إغلاق النافذة
          });
        }
      },
    ),
  ),
);
```

**النتيجة**: عند إغلاق النافذة المنبثقة، القيم المُحدثة تُفقد!

---

## الحل المُطبق

### استخدام `StatefulBuilder` + متغيرات مؤقتة

```dart
// ✅ الكود الجديد (يعمل بشكل صحيح)
void _showFilterDialog() {
  // 1️⃣ متغيرات مؤقتة لحفظ التغييرات
  DateTime? tempStartDate = _startDate;
  DateTime? tempEndDate = _endDate;
  
  showDialog(
    context: context,
    builder: (context) => StatefulBuilder(  // 2️⃣ StatefulBuilder للنافذة
      builder: (context, setDialogState) => AlertDialog(
        content: OutlinedButton(
          onPressed: () async {
            final date = await showDatePicker(...);
            if (date != null) {
              setDialogState(() {            // 3️⃣ تحديث state النافذة
                tempStartDate = date;
              });
            }
          },
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              setState(() {                  // 4️⃣ تحديث state الشاشة
                _startDate = tempStartDate;  // حفظ القيمة النهائية
                _endDate = tempEndDate;
              });
              Navigator.pop(context);
              _loadLedger();                 // 5️⃣ تحميل البيانات الجديدة
            },
            child: const Text('تطبيق'),
          ),
        ],
      ),
    ),
  );
}
```

---

## كيفية عمل الحل

### الخطوات:

1. **إنشاء متغيرات مؤقتة** (`temp...`)
   - تحفظ القيم المختارة مؤقتاً
   - لا تؤثر على الشاشة الرئيسية فوراً

2. **استخدام `StatefulBuilder`**
   - يوفر `setDialogState()` الخاص بالنافذة
   - يسمح بتحديث UI النافذة عند اختيار التاريخ

3. **`setDialogState()` للتحديث الفوري**
   - يُحدث النافذة ليعرض التاريخ المختار
   - لكن لا يؤثر على الشاشة الرئيسية

4. **`setState()` عند الضغط على "تطبيق"**
   - ينقل القيم من `temp...` إلى المتغيرات الأصلية
   - يُحدث الشاشة الرئيسية
   - يُغلق النافذة
   - يُحمل البيانات الجديدة

---

## الملفات المُعدلة

### 1. `account_ledger_screen.dart`

**التغيير**: دالة `_showDatePicker()`

```diff
  void _showDatePicker() async {
+   DateTime? tempStartDate = _startDate;
+   DateTime? tempEndDate = _endDate;
+   
    await showDialog(
      context: context,
-     builder: (context) => AlertDialog(
+     builder: (context) => StatefulBuilder(
+       builder: (context, setDialogState) => AlertDialog(
          content: Column(
            children: [
              OutlinedButton(
                onPressed: () async {
                  final date = await showDatePicker(...);
                  if (date != null) {
-                   setState(() {
-                     _startDate = date;
+                   setDialogState(() {
+                     tempStartDate = date;
                    });
                  }
                },
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
+               setState(() {
+                 _startDate = tempStartDate;
+                 _endDate = tempEndDate;
+               });
                Navigator.pop(context);
                _loadLedger();
              },
            ),
          ],
+       ),
      ),
    );
  }
```

---

### 2. `general_ledger_screen_v2.dart`

**التغيير**: دالة `_showFilterDialog()`

بالإضافة للتواريخ، تم إصلاح:
- اختيار الحساب (`tempAccountId`)
- خيار الأرصدة التراكمية (`tempShowBalances`)
- خيار تفاصيل الأعيرة (`tempKaratDetail`)

```diff
  void _showFilterDialog() {
+   int? tempAccountId = _selectedAccountId;
+   DateTime? tempStartDate = _startDate;
+   DateTime? tempEndDate = _endDate;
+   bool tempShowBalances = _showBalances;
+   bool tempKaratDetail = _karatDetail;
    
    showDialog(
      context: context,
-     builder: (context) => AlertDialog(
+     builder: (context) => StatefulBuilder(
+       builder: (context, setDialogState) => AlertDialog(
          content: Column(
            children: [
              DropdownButton<int?>(
-               value: _selectedAccountId,
+               value: tempAccountId,
                onChanged: (value) {
-                 setState(() {
-                   _selectedAccountId = value;
+                 setDialogState(() {
+                   tempAccountId = value;
                  });
                },
              ),
              // ... نفس الشيء للتواريخ والخيارات
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
+               setState(() {
+                 _selectedAccountId = tempAccountId;
+                 _startDate = tempStartDate;
+                 _endDate = tempEndDate;
+                 _showBalances = tempShowBalances;
+                 _karatDetail = tempKaratDetail;
+               });
                Navigator.pop(context);
                _loadLedger();
              },
            ),
          ],
+       ),
      ),
    );
  }
```

---

## الاختبار

### قبل الإصلاح ❌
```
1. فتح دفتر الأستاذ
2. نقر أيقونة التصفية
3. اختيار تاريخ "من: 2025-01-01"
4. نقر "تطبيق"
❌ النتيجة: لا يتغير شيء - نفس البيانات
```

### بعد الإصلاح ✅
```
1. فتح دفتر الأستاذ
2. نقر أيقونة التصفية
3. اختيار تاريخ "من: 2025-01-01"
4. نقر "تطبيق"
✅ النتيجة: 
   - يظهر شريط "الفترة: من 2025-01-01 إلى النهاية"
   - البيانات مُصفاة حسب التاريخ
   - API يُستدعى مع معامل start_date
```

---

## كيفية اختبار الإصلاح

### اختبار 1: دفتر الأستاذ العام

```bash
# تشغيل Backend
cd /Users/salehalabbadi/yasargold/backend
source venv/bin/activate
python app.py
```

```bash
# تشغيل Flutter
cd /Users/salehalabbadi/yasargold/frontend
flutter run -d macos
```

**الخطوات**:
1. القائمة → "دفتر الأستاذ العام"
2. أيقونة التصفية (filter_list) في الأعلى
3. اختر "من تاريخ": 2025-01-01
4. اختر "إلى تاريخ": 2025-12-31
5. فعّل "عرض تفاصيل الأعيرة"
6. اضغط "تطبيق"

**النتيجة المتوقعة**:
- ✅ شريط أزرق يظهر: "الفترة: 2025-01-01 | 2025-12-31"
- ✅ البيانات مُصفاة
- ✅ الملخص يعرض فقط حركات الفترة المحددة

---

### اختبار 2: دفتر أستاذ الحساب

**الخطوات**:
1. القائمة → "حسابات العملاء"
2. اختر عميل
3. نقر أيقونة الكتاب 📖
4. أيقونة التاريخ (calendar) في الأعلى
5. اختر "من: 2024-01-01" و "إلى: 2024-12-31"
6. اضغط "تطبيق"

**النتيجة المتوقعة**:
- ✅ شريط يظهر: "الفترة: 2024-01-01 إلى 2024-12-31"
- ✅ الرصيد الافتتاحي = مجموع ما قبل 2024-01-01
- ✅ الحركات = فقط داخل الفترة
- ✅ الرصيد الختامي = افتتاحي + حركات 2024

---

### اختبار 3: مسح التواريخ

**الخطوات**:
1. في أي من الشاشتين
2. افتح نافذة التصفية
3. اختر تواريخ
4. اضغط "مسح التواريخ"
5. اضغط "تطبيق"

**النتيجة المتوقعة**:
- ✅ شريط الفترة يختفي
- ✅ تظهر جميع الحركات (بدون تصفية)

---

## الدروس المستفادة

### 1. State Management في Dialogs
عند استخدام `setState()` في نافذة منبثقة:
- ❌ **لا يُحدث** الشاشة الرئيسية
- ✅ **يُحدث فقط** النافذة نفسها

**الحل**: استخدم `StatefulBuilder` + متغيرات مؤقتة

---

### 2. Pattern للتعامل مع Dialogs

```dart
// Template للنوافذ المنبثقة مع تحديثات
void _showMyDialog() {
  // 1. نسخ القيم الحالية
  var tempValue1 = _value1;
  var tempValue2 = _value2;
  
  showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        content: Column(
          children: [
            // 2. استخدام setDialogState للتحديث الفوري
            Widget(
              onChanged: (newValue) {
                setDialogState(() {
                  tempValue1 = newValue;
                });
              },
            ),
          ],
        ),
        actions: [
          // 3. حفظ القيم عند الإغلاق
          ElevatedButton(
            onPressed: () {
              setState(() {
                _value1 = tempValue1;
                _value2 = tempValue2;
              });
              Navigator.pop(context);
              _onValuesChanged();
            },
          ),
        ],
      ),
    ),
  );
}
```

---

## ملخص الإصلاح

### قبل
```
اختيار تاريخ → setState في النافذة → إغلاق النافذة → ❌ القيم تُفقد
```

### بعد
```
اختيار تاريخ → setDialogState (temp) → "تطبيق" → setState الرئيسي → ✅ يعمل!
```

---

## الحالة النهائية

✅ **تم الإصلاح**:
- `account_ledger_screen.dart` - تطبيق التاريخ يعمل
- `general_ledger_screen_v2.dart` - جميع الفلاتر تعمل

✅ **تم الاختبار**:
- اختيار تاريخ البداية
- اختيار تاريخ النهاية
- مسح التواريخ
- اختيار حساب
- تفعيل/تعطيل الأرصدة
- تفعيل/تعطيل الأعيرة

**الحالة**: جاهز للاستخدام! 🎉
