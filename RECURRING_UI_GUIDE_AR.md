# 📱 دليل الواجهة: القيود الدورية (Recurring Journal Entries)
## الواجهة العربية - شرح مفصّل

**التاريخ**: 8 نوفمبر 2025  
**الحالة**: دليل عملي للمطورين والمستخدمين

---

## 🎯 ما هي القيود الدورية؟

القيود الدورية هي قيود محاسبية **تتكرر تلقائياً** في مواعيد محددة (شهرياً، سنوياً، الخ).  
مثال: رواتب الموظفين كل يوم 25 من الشهر، إيجار المحل كل يوم 1.

---

## 📋 المكونات الأساسية في الواجهة

### 1️⃣ **شاشة قائمة القوالب** (Templates List Screen)

**المسار المقترح**: `frontend/lib/screens/recurring_templates_screen.dart`

#### 🖼️ ما يظهر في الشاشة:

```
┌─────────────────────────────────────────┐
│  🔄 القيود الدورية          [+]       │
├─────────────────────────────────────────┤
│                                         │
│  📋 راتب موظفي المحل          [نشط]   │
│  📅 التالي: 2025-12-25                 │
│  ✅ تم إنشاء: 1 قيد                   │
│  [إنشاء الآن] [تعديل] [⚙️]            │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│  📋 إيجار المحل               [نشط]   │
│  📅 التالي: 2025-12-01                 │
│  ✅ تم إنشاء: 1 قيد                   │
│  [إنشاء الآن] [تعديل] [⚙️]            │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│  📋 فواتير الخدمات            [نشط]   │
│  📅 التالي: 2025-11-15                 │
│  ⏳ لم يتم إنشاء قيود بعد             │
│  [إنشاء الآن] [تعديل] [⚙️]            │
│                                         │
└─────────────────────────────────────────┘
```

#### 📊 بيانات كل بطاقة (Card):

| العنصر | الحقل من API | الوصف |
|--------|--------------|-------|
| الاسم | `name` | اسم القالب |
| الحالة | `is_active` | نشط/متوقف |
| التاريخ القادم | `next_run_date` | متى سيتم إنشاء القيد التلقائي |
| النوع | `frequency_text` | شهري/سنوي/أسبوعي |
| عدد القيود | `total_created` | كم قيد تم إنشاؤه من هذا القالب |
| آخر إنشاء | `last_created_date` | تاريخ آخر قيد تم إنشاؤه |

#### 🔘 الأزرار والإجراءات:

**1. زر [+] إضافة قالب جديد**
```dart
// عند الضغط:
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => RecurringTemplateFormScreen(),
  ),
);
```

**2. زر [إنشاء الآن] Create Now**
```dart
// استدعاء API:
POST /api/recurring_templates/{id}/create_entry

// الاستجابة:
{
  "message": "تم إنشاء القيد بنجاح",
  "entry": {
    "id": 22,
    "entry_number": "JE-2025-00022",
    "date": "2025-11-01",
    "description": "إيجار شهري لمحل الذهب (دوري - إيجار المحل)"
  }
}

// عرض رسالة نجاح:
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    content: Text('✅ تم إنشاء القيد رقم ${entry['entry_number']}'),
    action: SnackBarAction(
      label: 'عرض',
      onPressed: () {
        // فتح شاشة تفاصيل القيد
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => JournalEntryDetailsScreen(
              entryId: entry['id'],
            ),
          ),
        );
      },
    ),
  ),
);
```

**3. زر [تعديل] Edit**
```dart
// فتح نموذج التعديل مع بيانات القالب:
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => RecurringTemplateFormScreen(
      templateId: template['id'],
      initialData: template,
    ),
  ),
);
```

**4. زر [⚙️] القائمة المنسدلة**
```dart
PopupMenuButton(
  itemBuilder: (context) => [
    PopupMenuItem(
      child: Text('تفعيل/تعطيل'),
      onTap: () => toggleActive(template['id']),
    ),
    PopupMenuItem(
      child: Text('حذف'),
      onTap: () => deleteTemplate(template['id']),
    ),
    PopupMenuItem(
      child: Text('عرض التفاصيل'),
      onTap: () => showDetails(template['id']),
    ),
  ],
)
```

---

### 2️⃣ **شاشة إنشاء/تعديل القالب** (Template Form Screen)

**المسار المقترح**: `frontend/lib/screens/recurring_template_form_screen.dart`

#### 🖼️ ما يظهر في الشاشة:

```
┌─────────────────────────────────────────┐
│  ← إنشاء قالب دوري جديد                │
├─────────────────────────────────────────┤
│                                         │
│  الاسم *                                │
│  [____________________________]         │
│                                         │
│  الوصف                                  │
│  [____________________________]         │
│                                         │
│  نوع التكرار *                          │
│  [شهري ▼]                               │
│   ├─ يومي                               │
│   ├─ أسبوعي                             │
│   ├─ شهري ✓                             │
│   ├─ ربع سنوي                           │
│   └─ سنوي                               │
│                                         │
│  كل كم مدة؟ *                           │
│  [1] شهر                                │
│                                         │
│  اليوم المفضل (للشهري)                 │
│  [25] من كل شهر                         │
│                                         │
│  تاريخ البدء *                          │
│  [2025-11-01] 📅                        │
│                                         │
│  تاريخ الانتهاء (اختياري)              │
│  [________] 📅                          │
│                                         │
│  ☑ تفعيل القالب                        │
│  ☑ إنشاء تلقائي عند الموعد             │
│                                         │
├─────────────────────────────────────────┤
│  📝 سطور القيد                          │
├─────────────────────────────────────────┤
│                                         │
│  السطر 1:                               │
│  الحساب: [صندوق النقدية ▼]            │
│  مدين نقد: [5000]                       │
│  دائن نقد: [0]                          │
│                              [❌ حذف]   │
│                                         │
│  السطر 2:                               │
│  الحساب: [مصروف الإيجار ▼]            │
│  مدين نقد: [0]                          │
│  دائن نقد: [5000]                       │
│                              [❌ حذف]   │
│                                         │
│  [+ إضافة سطر]                          │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│  💰 الإجمالي:                           │
│  مدين: 5000   دائن: 5000   ✅ متوازن   │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│  [حفظ القالب]            [إلغاء]       │
│                                         │
└─────────────────────────────────────────┘
```

#### 📝 الحقول المطلوبة:

| الحقل | اسم API | نوع البيانات | مطلوب؟ | الوصف |
|-------|---------|--------------|--------|-------|
| الاسم | `name` | String | ✅ | اسم القالب |
| الوصف | `description` | String | ❌ | وصف مختصر |
| نوع التكرار | `frequency` | Enum | ✅ | daily/weekly/monthly/quarterly/yearly |
| الفترة | `interval` | Int | ✅ | كل كم مدة (1 = كل شهر، 2 = كل شهرين) |
| اليوم المفضل | `preferred_day_of_month` | Int | ❌ | لليوم المحدد (1-31) |
| تاريخ البدء | `start_date` | Date | ✅ | متى يبدأ القالب |
| تاريخ الانتهاء | `end_date` | Date | ❌ | متى يتوقف (اختياري) |
| نشط | `is_active` | Bool | ✅ | مفعّل أم لا |
| إنشاء تلقائي | `auto_create` | Bool | ✅ | يُنشأ تلقائياً أم يدوياً فقط |
| السطور | `lines` | Array | ✅ | قائمة سطور القيد |

#### 📊 بيانات كل سطر:

| الحقل | اسم API | الوصف |
|-------|---------|-------|
| الحساب | `account_id` | رقم الحساب |
| مدين نقد | `cash_debit` | المبلغ المدين نقداً |
| دائن نقد | `cash_credit` | المبلغ الدائن نقداً |
| مدين ذهب 21 | `debit_21k` | الوزن المدين ذهب 21 |
| دائن ذهب 21 | `credit_21k` | الوزن الدائن ذهب 21 |

#### 🔄 مثال JSON للإرسال:

```json
{
  "name": "راتب موظفي المحل",
  "description": "رواتب الموظفين الشهرية",
  "frequency": "monthly",
  "interval": 1,
  "preferred_day_of_month": 25,
  "start_date": "2025-11-01",
  "end_date": null,
  "is_active": true,
  "auto_create": true,
  "lines": [
    {
      "account_id": 510,
      "cash_debit": 15000.0,
      "cash_credit": 0.0,
      "debit_21k": 0.0,
      "credit_21k": 0.0
    },
    {
      "account_id": 101,
      "cash_debit": 0.0,
      "cash_credit": 15000.0,
      "debit_21k": 0.0,
      "credit_21k": 0.0
    }
  ]
}
```

#### 🔘 عند الضغط على [حفظ]:

**للإنشاء (Create):**
```dart
Future<void> saveTemplate() async {
  final response = await http.post(
    Uri.parse('$baseUrl/api/recurring_templates'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(templateData),
  );
  
  if (response.statusCode == 201) {
    // نجح الحفظ
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ تم حفظ القالب بنجاح')),
    );
    Navigator.pop(context, true); // العودة وتحديث القائمة
  } else {
    // فشل الحفظ
    final error = jsonDecode(response.body);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('❌ خطأ: ${error['error']}')),
    );
  }
}
```

**للتعديل (Update):**
```dart
Future<void> updateTemplate(int id) async {
  final response = await http.put(
    Uri.parse('$baseUrl/api/recurring_templates/$id'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(templateData),
  );
  
  if (response.statusCode == 200) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ تم تحديث القالب بنجاح')),
    );
    Navigator.pop(context, true);
  }
}
```

---

### 3️⃣ **شاشة تفاصيل القالب** (Template Details Screen)

**المسار المقترح**: `frontend/lib/screens/recurring_template_details_screen.dart`

#### 🖼️ ما يظهر في الشاشة:

```
┌─────────────────────────────────────────┐
│  ← راتب موظفي المحل              [✏️]  │
├─────────────────────────────────────────┤
│                                         │
│  📋 معلومات القالب                     │
│  ────────────────                       │
│  الوصف: رواتب الموظفين الشهرية         │
│  النوع: شهري (كل 1 شهر)                │
│  اليوم المفضل: 25 من كل شهر            │
│  تاريخ البدء: 2025-11-01               │
│  الحالة: ✅ نشط                        │
│  إنشاء تلقائي: ✅ مفعّل                │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│  📅 التواريخ                            │
│  ────────                               │
│  التالي: 2025-12-25                    │
│  آخر إنشاء: 2025-11-01                 │
│  إجمالي القيود: 1                      │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│  📝 سطور القيد                          │
│  ────────                               │
│                                         │
│  ┌──────────────────────────────────┐  │
│  │ الحساب: مصروف الرواتب (510)    │  │
│  │ مدين نقد: 15,000 ريال           │  │
│  │ دائن نقد: 0 ريال                │  │
│  └──────────────────────────────────┘  │
│                                         │
│  ┌──────────────────────────────────┐  │
│  │ الحساب: صندوق النقدية (101)    │  │
│  │ مدين نقد: 0 ريال                │  │
│  │ دائن نقد: 15,000 ريال           │  │
│  └──────────────────────────────────┘  │
│                                         │
│  💰 الإجمالي: متوازن ✅               │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│  [🔄 إنشاء قيد الآن]                   │
│  [⚙️ تعديل القالب]                    │
│  [⏸️ تعطيل/تفعيل]                     │
│  [🗑️ حذف القالب]                      │
│                                         │
└─────────────────────────────────────────┘
```

---

## 🔄 سيناريوهات الاستخدام (Use Cases)

### ✅ سيناريو 1: إنشاء قالب جديد (رواتب)

**الخطوات:**
1. المستخدم يفتح شاشة القيود الدورية
2. يضغط على زر [+]
3. يملأ البيانات:
   - الاسم: "رواتب فريق المبيعات"
   - النوع: شهري
   - اليوم: 28
   - تاريخ البدء: 2025-11-28
4. يضيف سطرين:
   - مصروف رواتب (مدين 20000)
   - صندوق النقدية (دائن 20000)
5. يضغط [حفظ]

**API Call:**
```bash
curl -X POST http://localhost:8001/api/recurring_templates \
  -H "Content-Type: application/json" \
  -d '{
    "name": "رواتب فريق المبيعات",
    "frequency": "monthly",
    "interval": 1,
    "preferred_day_of_month": 28,
    "start_date": "2025-11-28",
    "is_active": true,
    "auto_create": true,
    "lines": [
      {"account_id": 510, "cash_debit": 20000, "cash_credit": 0},
      {"account_id": 101, "cash_debit": 0, "cash_credit": 20000}
    ]
  }'
```

**النتيجة:**
- يُنشأ القالب برقم ID جديد
- يظهر في قائمة القوالب
- `next_run_date` = 2025-11-28

---

### ✅ سيناريو 2: إنشاء قيد فوري (إعادة طلب)

**الخطوات:**
1. المستخدم في شاشة القائمة
2. يرى قالب "إيجار المحل"
3. يضغط على [إنشاء الآن]
4. يظهر Loading
5. يظهر إشعار: "✅ تم إنشاء القيد JE-2025-00022"
6. زر [عرض] للانتقال لتفاصيل القيد

**ما يحدث في الخلفية:**
```bash
POST /api/recurring_templates/2/create_entry
```

**النتيجة:**
- يُنشأ قيد جديد في جدول `journal_entry`
- `entry_type` = "دوري"
- `recurring_template_id` = 2
- `reference_number` = "REC-2-1"
- `next_run_date` يتحدث إلى الشهر التالي (2025-12-01)
- `total_created` يزيد من 0 إلى 1
- `last_created_date` = تاريخ اليوم

---

### ✅ سيناريو 3: تفعيل/تعطيل قالب

**الخطوات:**
1. المستخدم يضغط على [⚙️] → [تعطيل]
2. يتغير لون البطاقة إلى رمادي
3. رمز الحالة يتحول من ✅ إلى ⏸️

**API Call:**
```bash
POST /api/recurring_templates/3/toggle_active
```

**النتيجة:**
- `is_active` = false
- القالب لن يُنشئ قيود تلقائياً
- يبقى موجوداً للتعديل أو إعادة التفعيل

---

## 🎨 توصيات تصميم الواجهة (UI/UX)

### الألوان المقترحة:

| العنصر | اللون | الكود |
|--------|-------|------|
| قالب نشط | أخضر | `#4CAF50` |
| قالب معطل | رمادي | `#9E9E9E` |
| زر "إنشاء الآن" | أزرق | `#2196F3` |
| زر "حذف" | أحمر | `#F44336` |
| خلفية البطاقة | أبيض | `#FFFFFF` |
| الحد | رمادي فاتح | `#E0E0E0` |

### الأيقونات:

| العنصر | الأيقونة |
|--------|---------|
| قائمة القوالب | `Icons.repeat` |
| إضافة قالب | `Icons.add_circle` |
| إنشاء الآن | `Icons.play_arrow` |
| تعديل | `Icons.edit` |
| حذف | `Icons.delete` |
| تفعيل | `Icons.toggle_on` |
| تعطيل | `Icons.toggle_off` |
| تاريخ | `Icons.calendar_today` |
| نقد | `Icons.attach_money` |
| ذهب | `Icons.stars` (ذهبي) |

---

## 🧪 حالات الاختبار (Test Cases)

### ✅ اختبار 1: إنشاء قالب صحيح
- **الإدخال**: بيانات كاملة وصحيحة
- **المتوقع**: `201 Created`
- **التحقق**: القالب يظهر في القائمة

### ❌ اختبار 2: إنشاء قالب بدون اسم
- **الإدخال**: `name` فارغ
- **المتوقع**: `400 Bad Request`
- **الرسالة**: "الاسم مطلوب"

### ✅ اختبار 3: إنشاء قيد من قالب
- **الإدخال**: `template_id` صحيح
- **المتوقع**: `200 OK` + بيانات القيد
- **التحقق**: `total_created` يزيد، `next_run_date` يتحدث

### ❌ اختبار 4: إنشاء من قالب معطل
- **الإدخال**: `is_active = false`
- **المتوقع**: ينجح (الإنشاء اليدوي يعمل دائماً)
- **ملاحظة**: التلقائي فقط يتأثر بـ `is_active`

### ✅ اختبار 5: تعديل قالب
- **الإدخال**: تغيير `name` أو `interval`
- **المتوقع**: `200 OK`
- **التحقق**: البيانات تتحدث في القائمة

---

## 🔐 التحقق والحماية (Validation & Security)

### في الواجهة (Frontend):

```dart
// 1. التحقق من اسم القالب
if (nameController.text.trim().isEmpty) {
  return 'الاسم مطلوب';
}

// 2. التحقق من التوازن المحاسبي
double totalDebit = lines.fold(0, (sum, line) => sum + line.cashDebit);
double totalCredit = lines.fold(0, (sum, line) => sum + line.cashCredit);
if (totalDebit != totalCredit) {
  return 'القيد غير متوازن: مدين $totalDebit ≠ دائن $totalCredit';
}

// 3. التحقق من وجود سطور
if (lines.length < 2) {
  return 'يجب إضافة سطرين على الأقل';
}

// 4. التحقق من اختيار حسابات صالحة
for (var line in lines) {
  if (line.accountId == null) {
    return 'يجب اختيار حساب لكل سطر';
  }
}

// 5. التحقق من التاريخ
if (startDate.isBefore(DateTime.now().subtract(Duration(days: 365)))) {
  return 'تاريخ البدء قديم جداً';
}
```

### في الخادم (Backend):

```python
# الحماية موجودة في backend/recurring_journal_system.py
# يتم التحقق من:
# 1. صحة account_id (موجود في جدول accounts)
# 2. التوازن المحاسبي (مدين = دائن)
# 3. صلاحيات المستخدم (إذا موجودة)
# 4. عدم إنشاء قيود مكررة في نفس اليوم
```

---

## 📱 كود Flutter جاهز للنسخ

### 1. نموذج البيانات (Model):

```dart
class RecurringTemplate {
  final int id;
  final String name;
  final String? description;
  final String frequency;
  final String frequencyText;
  final int interval;
  final DateTime startDate;
  final DateTime nextRunDate;
  final DateTime? endDate;
  final bool isActive;
  final bool autoCreate;
  final int totalCreated;
  final DateTime? lastCreatedDate;
  final int? preferredDayOfMonth;
  final List<RecurringLine> lines;

  RecurringTemplate({
    required this.id,
    required this.name,
    this.description,
    required this.frequency,
    required this.frequencyText,
    required this.interval,
    required this.startDate,
    required this.nextRunDate,
    this.endDate,
    required this.isActive,
    required this.autoCreate,
    required this.totalCreated,
    this.lastCreatedDate,
    this.preferredDayOfMonth,
    required this.lines,
  });

  factory RecurringTemplate.fromJson(Map<String, dynamic> json) {
    return RecurringTemplate(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      frequency: json['frequency'],
      frequencyText: json['frequency_text'],
      interval: json['interval'],
      startDate: DateTime.parse(json['start_date']),
      nextRunDate: DateTime.parse(json['next_run_date']),
      endDate: json['end_date'] != null ? DateTime.parse(json['end_date']) : null,
      isActive: json['is_active'],
      autoCreate: json['auto_create'],
      totalCreated: json['total_created'],
      lastCreatedDate: json['last_created_date'] != null 
          ? DateTime.parse(json['last_created_date']) 
          : null,
      preferredDayOfMonth: json['preferred_day_of_month'],
      lines: (json['lines'] as List)
          .map((line) => RecurringLine.fromJson(line))
          .toList(),
    );
  }
}

class RecurringLine {
  final int id;
  final int accountId;
  final String? accountName;
  final double cashDebit;
  final double cashCredit;
  final double debit21k;
  final double credit21k;

  RecurringLine({
    required this.id,
    required this.accountId,
    this.accountName,
    required this.cashDebit,
    required this.cashCredit,
    required this.debit21k,
    required this.credit21k,
  });

  factory RecurringLine.fromJson(Map<String, dynamic> json) {
    return RecurringLine(
      id: json['id'],
      accountId: json['account_id'],
      accountName: json['account_name'],
      cashDebit: json['cash_debit'].toDouble(),
      cashCredit: json['cash_credit'].toDouble(),
      debit21k: json['debit_21k'].toDouble(),
      credit21k: json['credit_21k'].toDouble(),
    );
  }
}
```

### 2. خدمة API (Service):

```dart
class RecurringTemplateService {
  final String baseUrl = 'http://localhost:8001';

  // جلب جميع القوالب
  Future<List<RecurringTemplate>> fetchTemplates() async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/recurring_templates'),
    );
    
    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((json) => RecurringTemplate.fromJson(json)).toList();
    } else {
      throw Exception('فشل جلب القوالب');
    }
  }

  // إنشاء قيد فوري
  Future<Map<String, dynamic>> createEntryNow(int templateId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/recurring_templates/$templateId/create_entry'),
    );
    
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('فشل إنشاء القيد');
    }
  }

  // تفعيل/تعطيل قالب
  Future<void> toggleActive(int templateId) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/recurring_templates/$templateId/toggle_active'),
    );
    
    if (response.statusCode != 200) {
      throw Exception('فشل تغيير حالة القالب');
    }
  }

  // حذف قالب
  Future<void> deleteTemplate(int templateId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/api/recurring_templates/$templateId'),
    );
    
    if (response.statusCode != 200) {
      throw Exception('فشل حذف القالب');
    }
  }

  // إنشاء قالب جديد
  Future<RecurringTemplate> createTemplate(Map<String, dynamic> data) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/recurring_templates'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    );
    
    if (response.statusCode == 201) {
      return RecurringTemplate.fromJson(jsonDecode(response.body));
    } else {
      final error = jsonDecode(response.body);
      throw Exception(error['error'] ?? 'فشل إنشاء القالب');
    }
  }
}
```

### 3. بطاقة القالب (Widget):

```dart
class RecurringTemplateCard extends StatelessWidget {
  final RecurringTemplate template;
  final VoidCallback onCreateNow;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const RecurringTemplateCard({
    Key? key,
    required this.template,
    required this.onCreateNow,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // العنوان والحالة
            Row(
              children: [
                Expanded(
                  child: Text(
                    template.name,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: template.isActive ? Colors.black : Colors.grey,
                    ),
                  ),
                ),
                Chip(
                  label: Text(
                    template.isActive ? 'نشط' : 'متوقف',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  backgroundColor: template.isActive 
                      ? Colors.green 
                      : Colors.grey,
                  padding: EdgeInsets.symmetric(horizontal: 8),
                ),
              ],
            ),
            SizedBox(height: 8),
            
            // الوصف
            if (template.description != null)
              Text(
                template.description!,
                style: TextStyle(color: Colors.grey[600], fontSize: 14),
              ),
            SizedBox(height: 12),
            
            // التفاصيل
            Row(
              children: [
                Icon(Icons.repeat, size: 16, color: Colors.blue),
                SizedBox(width: 4),
                Text(
                  template.frequencyText,
                  style: TextStyle(fontSize: 14),
                ),
                SizedBox(width: 16),
                Icon(Icons.calendar_today, size: 16, color: Colors.orange),
                SizedBox(width: 4),
                Text(
                  'التالي: ${_formatDate(template.nextRunDate)}',
                  style: TextStyle(fontSize: 14),
                ),
              ],
            ),
            SizedBox(height: 8),
            
            // الإحصائيات
            Row(
              children: [
                Icon(Icons.check_circle, size: 16, color: Colors.green),
                SizedBox(width: 4),
                Text(
                  'تم إنشاء: ${template.totalCreated} قيد',
                  style: TextStyle(fontSize: 14),
                ),
                if (template.lastCreatedDate != null) ...[
                  SizedBox(width: 16),
                  Text(
                    'آخر إنشاء: ${_formatDate(template.lastCreatedDate!)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ],
            ),
            SizedBox(height: 12),
            
            // الأزرار
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: onCreateNow,
                  icon: Icon(Icons.play_arrow, size: 18),
                  label: Text('إنشاء الآن'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
                SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: onEdit,
                  icon: Icon(Icons.edit, size: 18),
                  label: Text('تعديل'),
                ),
                Spacer(),
                PopupMenuButton(
                  icon: Icon(Icons.more_vert),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      child: Row(
                        children: [
                          Icon(
                            template.isActive 
                                ? Icons.toggle_off 
                                : Icons.toggle_on,
                          ),
                          SizedBox(width: 8),
                          Text(template.isActive ? 'تعطيل' : 'تفعيل'),
                        ],
                      ),
                      onTap: onToggle,
                    ),
                    PopupMenuItem(
                      child: Row(
                        children: [
                          Icon(Icons.delete, color: Colors.red),
                          SizedBox(width: 8),
                          Text('حذف', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                      onTap: onDelete,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
```

---

## 🎯 الخلاصة

**في الواجهة، القيود الدورية تُدار عبر 3 شاشات رئيسية:**

1. **قائمة القوالب** - عرض جميع القوالب مع أزرار الإجراءات
2. **نموذج الإنشاء/التعديل** - إدخال بيانات القالب والسطور
3. **تفاصيل القالب** - عرض كامل التفاصيل والإحصائيات

**الإجراءات الرئيسية:**
- ✅ **إنشاء الآن** → `POST /api/recurring_templates/{id}/create_entry`
- ✏️ **تعديل** → `PUT /api/recurring_templates/{id}`
- ⏸️ **تفعيل/تعطيل** → `POST /api/recurring_templates/{id}/toggle_active`
- 🗑️ **حذف** → `DELETE /api/recurring_templates/{id}`

**النتيجة:**
- قيد جديد يُنشأ بـ `entry_type = "دوري"`
- يُحدث `next_run_date` تلقائياً للموعد التالي
- تزداد إحصائية `total_created`

---

**للمزيد من التفاصيل التقنية، راجع:**
- `FLUTTER_RECURRING_GUIDE.md` - دليل المطورين الكامل
- `RECURRING_JOURNAL_GUIDE.md` - دليل النظام الشامل
- `backend/recurring_journal_routes.py` - تفاصيل API

---

_تم بحمد الله_ 🎉
