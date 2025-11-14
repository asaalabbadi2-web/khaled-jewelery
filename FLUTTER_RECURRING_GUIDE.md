# دليل إنشاء واجهة Flutter للقيود الدورية
## Flutter UI Guide for Recurring Journal Entries

---

## 📱 الشاشات المطلوبة

### 1. شاشة قائمة القوالب (Recurring Templates List)
**المسار**: `lib/screens/recurring_templates_list_screen.dart`

**الميزات**:
- ✅ عرض جميع القوالب
- ✅ تصفية حسب الحالة (نشط/معطل)
- ✅ بحث بالاسم
- ✅ عرض معلومات القالب (التكرار، التاريخ القادم)
- ✅ زر إنشاء قيد يدوياً
- ✅ تفعيل/تعطيل القالب
- ✅ تعديل/حذف القالب

**API Endpoint**:
```dart
Future<List<dynamic>> getRecurringTemplates() async {
  final response = await http.get(
    Uri.parse('$baseUrl/api/recurring_templates'),
  );
  return json.decode(response.body);
}
```

**مثال UI**:
```dart
Card(
  child: ListTile(
    title: Text('راتب موظفي المحل'),
    subtitle: Text('شهري - التاريخ القادم: 2025-12-25'),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(Icons.play_arrow),
          onPressed: () => _createEntryFromTemplate(templateId),
        ),
        Switch(
          value: isActive,
          onChanged: (value) => _toggleTemplate(templateId),
        ),
      ],
    ),
  ),
)
```

---

### 2. شاشة إنشاء/تعديل القالب (Create/Edit Template)
**المسار**: `lib/screens/recurring_template_form.dart`

**الحقول المطلوبة**:
- ✅ اسم القالب (مطلوب)
- ✅ الوصف
- ✅ نوع التكرار (Dropdown): يومي، أسبوعي، شهري، ربع سنوي، سنوي
- ✅ الفترة (Interval): كل كم من الفترة
- ✅ تاريخ البداية (Date Picker)
- ✅ تاريخ النهاية (اختياري)
- ✅ اليوم المفضل من الشهر (للقيود الشهرية)
- ✅ خطوط القيد (مثل شاشة القيد العادية)

**API Endpoint**:
```dart
Future<void> createTemplate(Map<String, dynamic> templateData) async {
  await http.post(
    Uri.parse('$baseUrl/api/recurring_templates'),
    headers: {'Content-Type': 'application/json'},
    body: json.encode(templateData),
  );
}
```

**مثال البيانات**:
```json
{
  "name": "راتب الموظفين",
  "description": "رواتب شهرية",
  "frequency": "monthly",
  "interval": 1,
  "start_date": "2025-11-01T00:00:00",
  "preferred_day_of_month": 25,
  "lines": [
    {
      "account_id": 510,
      "cash_debit": 15000.0,
      "cash_credit": 0.0
    },
    {
      "account_id": 101,
      "cash_debit": 0.0,
      "cash_credit": 15000.0
    }
  ]
}
```

---

### 3. شاشة القيود المستحقة (Due Templates)
**المسار**: `lib/screens/due_templates_screen.dart`

**الميزات**:
- ✅ عرض القوالب المستحقة فقط
- ✅ زر "معالجة جميع القيود المستحقة"
- ✅ عرض عدد القيود المستحقة (Badge)

**API Endpoint**:
```dart
Future<Map<String, dynamic>> getDueTemplates() async {
  final response = await http.get(
    Uri.parse('$baseUrl/api/recurring_templates/due_count'),
  );
  return json.decode(response.body);
}

Future<void> processAllDue() async {
  await http.post(
    Uri.parse('$baseUrl/api/recurring_templates/process_all'),
    headers: {'Content-Type': 'application/json'},
    body: json.encode({}),
  );
}
```

---

## 🎨 مكونات UI مقترحة

### 1. Frequency Dropdown
```dart
DropdownButtonFormField<String>(
  value: _frequency,
  decoration: InputDecoration(labelText: 'نوع التكرار'),
  items: [
    DropdownMenuItem(value: 'daily', child: Text('يومي')),
    DropdownMenuItem(value: 'weekly', child: Text('أسبوعي')),
    DropdownMenuItem(value: 'monthly', child: Text('شهري')),
    DropdownMenuItem(value: 'quarterly', child: Text('ربع سنوي')),
    DropdownMenuItem(value: 'yearly', child: Text('سنوي')),
  ],
  onChanged: (value) => setState(() => _frequency = value!),
)
```

### 2. Date Picker
```dart
TextFormField(
  controller: _startDateController,
  decoration: InputDecoration(labelText: 'تاريخ البداية'),
  readOnly: true,
  onTap: () async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2030),
    );
    if (date != null) {
      _startDateController.text = date.toIso8601String();
    }
  },
)
```

### 3. Template Card Widget
```dart
class RecurringTemplateCard extends StatelessWidget {
  final Map<String, dynamic> template;
  
  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      margin: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  template['name'],
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Chip(
                  label: Text(template['frequency_text']),
                  backgroundColor: Colors.blue[100],
                ),
              ],
            ),
            SizedBox(height: 8),
            Text(template['description']),
            SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.calendar_today, size: 16),
                SizedBox(width: 4),
                Text('التاريخ القادم: ${template['next_run_date']}'),
              ],
            ),
            SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.check_circle, size: 16),
                SizedBox(width: 4),
                Text('تم إنشاء ${template['total_created']} قيد'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

---

## 🔧 API Service Methods

أضف هذه الدوال إلى `lib/api_service.dart`:

```dart
// جلب جميع القوالب
Future<List<dynamic>> getRecurringTemplates() async {
  final response = await http.get(
    Uri.parse('$baseUrl/api/recurring_templates'),
  );
  if (response.statusCode == 200) {
    return json.decode(response.body);
  }
  throw Exception('فشل جلب القوالب');
}

// إنشاء قالب جديد
Future<void> createRecurringTemplate(Map<String, dynamic> data) async {
  final response = await http.post(
    Uri.parse('$baseUrl/api/recurring_templates'),
    headers: {'Content-Type': 'application/json'},
    body: json.encode(data),
  );
  if (response.statusCode != 201) {
    throw Exception('فشل إنشاء القالب');
  }
}

// تحديث قالب
Future<void> updateRecurringTemplate(int id, Map<String, dynamic> data) async {
  await http.put(
    Uri.parse('$baseUrl/api/recurring_templates/$id'),
    headers: {'Content-Type': 'application/json'},
    body: json.encode(data),
  );
}

// حذف قالب
Future<void> deleteRecurringTemplate(int id) async {
  await http.delete(
    Uri.parse('$baseUrl/api/recurring_templates/$id'),
  );
}

// تفعيل/تعطيل قالب
Future<void> toggleTemplate(int id) async {
  await http.post(
    Uri.parse('$baseUrl/api/recurring_templates/$id/toggle_active'),
  );
}

// إنشاء قيد من قالب
Future<Map<String, dynamic>> createEntryFromTemplate(int id) async {
  final response = await http.post(
    Uri.parse('$baseUrl/api/recurring_templates/$id/create_entry'),
  );
  return json.decode(response.body);
}

// معالجة جميع القيود المستحقة
Future<Map<String, dynamic>> processAllRecurring() async {
  final response = await http.post(
    Uri.parse('$baseUrl/api/recurring_templates/process_all'),
    headers: {'Content-Type': 'application/json'},
    body: json.encode({}),
  );
  return json.decode(response.body);
}

// عدد القيود المستحقة
Future<Map<String, dynamic>> getDueCount() async {
  final response = await http.get(
    Uri.parse('$baseUrl/api/recurring_templates/due_count'),
  );
  return json.decode(response.body);
}
```

---

## 🗺️ Navigation & Routing

أضف إلى `main.dart`:

```dart
// في MaterialApp routes
routes: {
  '/recurring-templates': (context) => RecurringTemplatesListScreen(),
  '/recurring-template/create': (context) => RecurringTemplateFormScreen(),
  '/recurring-template/edit': (context) => RecurringTemplateFormScreen(isEdit: true),
  '/due-templates': (context) => DueTemplatesScreen(),
}
```

---

## 🎯 خطوات التطبيق

### الخطوة 1: إنشاء ملفات الشاشات
```bash
cd frontend/lib/screens
touch recurring_templates_list_screen.dart
touch recurring_template_form.dart
touch due_templates_screen.dart
```

### الخطوة 2: إضافة API Methods
افتح `lib/api_service.dart` وأضف الدوال أعلاه

### الخطوة 3: إضافة زر في Home Screen
```dart
ElevatedButton(
  onPressed: () => Navigator.pushNamed(context, '/recurring-templates'),
  child: Text('القيود الدورية'),
)
```

### الخطوة 4: Badge للقيود المستحقة
```dart
FutureBuilder<Map<String, dynamic>>(
  future: _apiService.getDueCount(),
  builder: (context, snapshot) {
    if (snapshot.hasData) {
      final count = snapshot.data!['due_count'];
      return Badge(
        label: Text('$count'),
        child: IconButton(
          icon: Icon(Icons.notifications),
          onPressed: () => Navigator.pushNamed(context, '/due-templates'),
        ),
      );
    }
    return SizedBox();
  },
)
```

---

## ✅ Checklist

- [ ] إنشاء شاشة قائمة القوالب
- [ ] إنشاء شاشة إضافة/تعديل القالب
- [ ] إنشاء شاشة القيود المستحقة
- [ ] إضافة API methods في ApiService
- [ ] إضافة Navigation routes
- [ ] إضافة زر في Home Screen
- [ ] إضافة Badge للقيود المستحقة
- [ ] اختبار جميع الوظائف

---

## 🎨 Theme & Colors

استخدم نفس الثيم الذهبي:
```dart
Color(0xFFFFD700) // ذهبي
Color(0xFFF5F5DC) // بيج فاتح
Color(0xFF8B7355) // بني ذهبي
```

---

**جاهز للبدء! 🚀**
