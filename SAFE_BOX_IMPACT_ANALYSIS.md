# تأثير نظام الخزائن على الملفات والشاشات

## 📋 ملخص التأثير

نظام الخزائن الجديد سيؤثر على **19 ملف** في المشروع، موزعة كالتالي:
- **Backend**: 3 ملفات
- **Frontend Flutter**: 16 شاشة

---

## 🔧 Backend Files (3 ملفات)

### ✅ 1. `backend/models.py`
**الحالة**: تم التحديث ✓

**التغييرات**:
- ✅ إضافة نموذج `SafeBox`
- ✅ استيراد SafeBox في routes.py

---

### ✅ 2. `backend/routes.py`
**الحالة**: تم التحديث جزئياً

**ما تم**:
- ✅ إضافة 7 endpoints للخزائن
- ✅ تحديث `/api/payroll/payment-accounts`

**ما يحتاج تحديث**:
- ⚠️ `/api/vouchers` (POST) - إضافة سندات صرف/قبض
- ⚠️ `/api/invoices` (POST) - الفواتير مع الدفع
- ⚠️ جميع endpoints التي تتعامل مع حسابات الدفع

---

### 🔴 3. `backend/seed_safe_boxes.py`
**الحالة**: تم الإنشاء ✓

**الاستخدام**: تشغيل مرة واحدة لإنشاء الخزائن الأولية

---

## 📱 Frontend Flutter Files (16 شاشة)

### 🟡 المجموعة الأولى: شاشات السندات (3 ملفات)

#### 1. `add_voucher_screen.dart` ⚠️ تحديث مطلوب
**التأثير**: عالي جداً

**ما يحتاج تغيير**:
```dart
// الحالي: dropdown يعرض جميع الحسابات (100+ حساب)
DropdownButton<Account>(
  items: allAccounts.map(...), // مئات الحسابات!
)

// المطلوب: dropdown يعرض الخزائن فقط
DropdownButton<SafeBox>(
  items: safebox.where((sb) => sb.type == 'cash' || sb.type == 'bank'),
)
```

**الحقول المتأثرة**:
- حساب الصرف/القبض (عند إنشاء سند صرف/قبض)
- اختيار البنك (للشيكات البنكية)

**الفائدة**: تبسيط الاختيار من 100+ حساب إلى 4-5 خزائن فقط

---

#### 2. `vouchers_list_screen.dart` ⚠️ تحديث مطلوب
**التأثير**: متوسط

**ما يحتاج تغيير**:
- عرض اسم الخزينة بدلاً من رقم الحساب
- فلترة حسب نوع الخزينة (نقدي/بنكي)

```dart
// الحالي
Text('حساب: ${voucher.accountNumber}')

// المطلوب
Text('الخزينة: ${voucher.safeBoxName}') // "بنك الرياض" بدلاً من "1010"
```

---

#### 3. `voucher_details_screen.dart` ⚠️ تحديث مطلوب
**التأثير**: منخفض

**ما يحتاج تغيير**:
- عرض تفاصيل الخزينة (الاسم، النوع، البنك)

---

### 🟢 المجموعة الثانية: شاشات الفواتير (8 ملفات)

#### 4. `sales_invoice_screen_v2.dart` ⚠️ تحديث مطلوب
**التأثير**: عالي

**ما يحتاج تغيير**:
```dart
// الحالي: عند تحديد طريقة الدفع "نقدي"
payment_method_id: selectedPaymentMethodId

// المطلوب: إضافة اختيار الخزينة
payment_method_id: selectedPaymentMethodId,
safe_box_id: selectedSafeBoxId, // الخزينة التي سيتم الدفع منها/إليها
```

**السيناريوهات**:
- فاتورة بيع نقدي → اختيار صندوق النقدية
- فاتورة بيع ببنك → اختيار البنك (الرياض/الراجحي/الأهلي)
- فاتورة شراء نقدي → اختيار صندوق النقدية

---

#### 5-11. باقي شاشات الفواتير ⚠️ تحديث مطلوب
**الملفات**:
- `purchase_invoice_screen.dart`
- `scrap_sales_invoice_screen.dart`
- `scrap_purchase_invoice_screen.dart`
- `add_return_invoice_screen.dart`
- `add_invoice_screen.dart`
- `add_purchase_invoice_screen.dart`
- `invoices_list_screen.dart`

**التأثير**: متوسط إلى عالي

**التغييرات المشتركة**:
```dart
// إضافة dropdown للخزائن عند الدفع الفوري
Widget _buildSafeBoxSelector() {
  return DropdownButtonFormField<int>(
    decoration: InputDecoration(
      labelText: 'الخزينة',
      hintText: 'اختر الخزينة',
    ),
    items: safebox.map((sb) => DropdownMenuItem(
      value: sb.id,
      child: Row(
        children: [
          Icon(_getIcon(sb.type)),
          SizedBox(width: 8),
          Text(sb.name),
        ],
      ),
    )).toList(),
  );
}
```

---

### 🔵 المجموعة الثالثة: شاشات الرواتب (2 ملف)

#### 12. `payroll_screen.dart` ✅ تم التحديث
**الحالة**: جاهز ✓

**ما تم**:
- ✅ dialog لاختيار طريقة الدفع من الخزائن
- ✅ عرض أيقونات للخزائن (💵 نقد، 🏦 بنك)
- ✅ تمرير `payment_account_id` للـ API

---

#### 13. `payroll_report_screen.dart` ⚠️ تحديث اختياري
**التأثير**: منخفض

**ما يمكن إضافته**:
- إحصائيات حسب طريقة الدفع (كم راتب دُفع نقداً، كم من البنك)

---

### 🟣 المجموعة الرابعة: شاشات الإعدادات (2 ملف)

#### 14. `settings_screen_enhanced.dart` 🆕 إضافة جديدة مطلوبة
**التأثير**: متوسط

**ما يحتاج إضافته**:
```dart
// إضافة قسم جديد: إدارة الخزائن
ListTile(
  leading: Icon(Icons.account_balance_wallet),
  title: Text('إدارة الخزائن'),
  subtitle: Text('النقدية، البنوك، الذهب'),
  trailing: Icon(Icons.chevron_right),
  onTap: () {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SafeBoxesScreen()),
    );
  },
)
```

---

#### 15. `safe_boxes_screen.dart` 🆕 شاشة جديدة - يجب إنشاؤها
**الحالة**: غير موجودة

**الوظائف المطلوبة**:
- ✅ عرض قائمة الخزائن
- ✅ إضافة خزينة جديدة
- ✅ تعديل خزينة
- ✅ حذف خزينة
- ✅ عرض الرصيد لكل خزينة
- ✅ فلترة حسب النوع (نقدي/بنكي/ذهبي)
- ✅ تحديد خزينة افتراضية

**واجهة مقترحة**:
```dart
class SafeBoxesScreen extends StatefulWidget {
  @override
  _SafeBoxesScreenState createState() => _SafeBoxesScreenState();
}

class _SafeBoxesScreenState extends State<SafeBoxesScreen> {
  List<SafeBox> _safeBoxes = [];
  String _filterType = 'all'; // all, cash, bank, gold
  
  // عرض بطاقات الخزائن
  Widget _buildSafeBoxCard(SafeBox safeBox) {
    return Card(
      child: ListTile(
        leading: Icon(_getIconByType(safeBox.type)),
        title: Text(safeBox.name),
        subtitle: Text('الرصيد: ${safeBox.balance} ريال'),
        trailing: Row(
          children: [
            if (safeBox.isDefault) Chip(label: Text('افتراضي')),
            IconButton(icon: Icon(Icons.edit), onPressed: () => _edit(safeBox)),
            IconButton(icon: Icon(Icons.delete), onPressed: () => _delete(safeBox)),
          ],
        ),
      ),
    );
  }
}
```

---

### 🟠 المجموعة الخامسة: ملفات API (2 ملف)

#### 16. `api_service.dart` ⚠️ تحديث مطلوب
**التأثير**: عالي جداً

**ما يحتاج إضافته**:
```dart
class ApiService {
  // ... الكود الموجود
  
  // 🆕 Endpoints الخزائن
  Future<List<SafeBox>> getSafeBoxes({String? type, bool? isActive}) async {
    final params = <String, String>{};
    if (type != null) params['safe_type'] = type;
    if (isActive != null) params['is_active'] = isActive.toString();
    
    final uri = Uri.parse('$_baseUrl/safe-boxes').replace(queryParameters: params);
    final response = await http.get(uri);
    
    if (response.statusCode == 200) {
      final List data = json.decode(utf8.decode(response.bodyBytes));
      return data.map((json) => SafeBox.fromJson(json)).toList();
    }
    throw Exception('Failed to load safe boxes');
  }
  
  Future<SafeBox> getSafeBox(int id) async {
    final response = await http.get(Uri.parse('$_baseUrl/safe-boxes/$id'));
    if (response.statusCode == 200) {
      return SafeBox.fromJson(json.decode(utf8.decode(response.bodyBytes)));
    }
    throw Exception('Failed to load safe box');
  }
  
  Future<SafeBox> createSafeBox(SafeBox safeBox) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/safe-boxes'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(safeBox.toJson()),
    );
    if (response.statusCode == 201) {
      return SafeBox.fromJson(json.decode(utf8.decode(response.bodyBytes)));
    }
    throw Exception('Failed to create safe box');
  }
  
  Future<SafeBox> updateSafeBox(int id, SafeBox safeBox) async {
    final response = await http.put(
      Uri.parse('$_baseUrl/safe-boxes/$id'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(safeBox.toJson()),
    );
    if (response.statusCode == 200) {
      return SafeBox.fromJson(json.decode(utf8.decode(response.bodyBytes)));
    }
    throw Exception('Failed to update safe box');
  }
  
  Future<void> deleteSafeBox(int id) async {
    final response = await http.delete(Uri.parse('$_baseUrl/safe-boxes/$id'));
    if (response.statusCode != 200) {
      throw Exception('Failed to delete safe box');
    }
  }
  
  Future<SafeBox> getDefaultSafeBox(String type) async {
    final response = await http.get(Uri.parse('$_baseUrl/safe-boxes/default/$type'));
    if (response.statusCode == 200) {
      return SafeBox.fromJson(json.decode(utf8.decode(response.bodyBytes)));
    }
    throw Exception('Failed to load default safe box');
  }
  
  // 🔄 تحديث endpoints الموجودة
  
  // تحديث createVoucher لقبول safe_box_id
  Future<Voucher> createVoucher({
    required String voucherType,
    required DateTime date,
    String? description,
    int? safeBoxId, // 🆕 جديد
    List<VoucherLine> lines = const [],
  }) async {
    final payload = {
      'voucher_type': voucherType,
      'date': date.toIso8601String(),
      'description': description,
      'safe_box_id': safeBoxId, // 🆕 جديد
      'lines': lines.map((l) => l.toJson()).toList(),
    };
    // ... باقي الكود
  }
  
  // تحديث createInvoice لقبول safe_box_id
  Future<Invoice> createInvoice({
    required String invoiceType,
    required List<InvoiceItem> items,
    int? paymentMethodId,
    int? safeBoxId, // 🆕 جديد
    // ... باقي المعاملات
  }) async {
    final payload = {
      'invoice_type': invoiceType,
      'items': items.map((i) => i.toJson()).toList(),
      'payment_method_id': paymentMethodId,
      'safe_box_id': safeBoxId, // 🆕 جديد
      // ... باقي البيانات
    };
    // ... باقي الكود
  }
}
```

---

#### 17. `models/safe_box_model.dart` 🆕 ملف جديد - يجب إنشاؤه
**الحالة**: غير موجود

**المحتوى المطلوب**:
```dart
class SafeBox {
  final int? id;
  final String name;
  final String? nameEn;
  final String safeType; // cash, bank, gold, check
  final int accountId;
  final int? karat; // للذهب
  final String? bankName;
  final String? iban;
  final String? swiftCode;
  final String? branch;
  final bool isActive;
  final bool isDefault;
  final String? notes;
  final double? balance; // من الحساب المرتبط
  final Account? account; // الحساب المرتبط
  
  SafeBox({
    this.id,
    required this.name,
    this.nameEn,
    required this.safeType,
    required this.accountId,
    this.karat,
    this.bankName,
    this.iban,
    this.swiftCode,
    this.branch,
    this.isActive = true,
    this.isDefault = false,
    this.notes,
    this.balance,
    this.account,
  });
  
  factory SafeBox.fromJson(Map<String, dynamic> json) {
    return SafeBox(
      id: json['id'],
      name: json['name'],
      nameEn: json['name_en'],
      safeType: json['safe_type'],
      accountId: json['account_id'],
      karat: json['karat'],
      bankName: json['bank_name'],
      iban: json['iban'],
      swiftCode: json['swift_code'],
      branch: json['branch'],
      isActive: json['is_active'] ?? true,
      isDefault: json['is_default'] ?? false,
      notes: json['notes'],
      balance: json['balance']?['cash']?.toDouble(),
      account: json['account'] != null ? Account.fromJson(json['account']) : null,
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'name_en': nameEn,
      'safe_type': safeType,
      'account_id': accountId,
      'karat': karat,
      'bank_name': bankName,
      'iban': iban,
      'swift_code': swiftCode,
      'branch': branch,
      'is_active': isActive,
      'is_default': isDefault,
      'notes': notes,
    };
  }
  
  IconData get icon {
    switch (safeType) {
      case 'cash':
        return Icons.money;
      case 'bank':
        return Icons.account_balance;
      case 'gold':
        return Icons.diamond;
      case 'check':
        return Icons.receipt_long;
      default:
        return Icons.account_balance_wallet;
    }
  }
  
  String get typeNameAr {
    switch (safeType) {
      case 'cash':
        return 'نقدي';
      case 'bank':
        return 'بنكي';
      case 'gold':
        return 'ذهبي';
      case 'check':
        return 'شيكات';
      default:
        return 'غير محدد';
    }
  }
}
```

---

### 🔷 المجموعة السادسة: شاشات أخرى (1 ملف)

#### 18. `home_screen_enhanced.dart` ⚠️ تحديث اختياري
**التأثير**: منخفض

**ما يمكن إضافته**:
```dart
// إضافة quick action للخزائن
QuickActionItem(
  icon: Icons.account_balance_wallet,
  label: isAr ? 'الخزائن' : 'Safe Boxes',
  color: Colors.amber,
  onTap: () {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SafeBoxesScreen()),
    );
  },
)
```

---

## 📊 ملخص الأولويات

### 🔴 أولوية عالية جداً (يجب تنفيذها فوراً)
1. ✅ `backend/models.py` - **تم** ✓
2. ✅ `backend/routes.py` - **تم جزئياً** ✓
3. 🆕 `frontend/lib/models/safe_box_model.dart` - **يجب إنشاؤه**
4. ⚠️ `frontend/lib/api_service.dart` - **تحديث مطلوب**
5. 🆕 `frontend/lib/screens/safe_boxes_screen.dart` - **يجب إنشاؤه**

### 🟠 أولوية عالية (تنفيذ خلال أسبوع)
6. ⚠️ `add_voucher_screen.dart`
7. ⚠️ `sales_invoice_screen_v2.dart`
8. ⚠️ `purchase_invoice_screen.dart`
9. ⚠️ `scrap_sales_invoice_screen.dart`
10. ⚠️ `scrap_purchase_invoice_screen.dart`

### 🟡 أولوية متوسطة (تنفيذ خلال أسبوعين)
11. ⚠️ `vouchers_list_screen.dart`
12. ⚠️ `add_return_invoice_screen.dart`
13. ⚠️ `add_invoice_screen.dart`
14. ⚠️ `settings_screen_enhanced.dart`

### 🟢 أولوية منخفضة (اختياري)
15. ⚠️ `voucher_details_screen.dart`
16. ⚠️ `invoices_list_screen.dart`
17. ⚠️ `payroll_report_screen.dart`
18. ⚠️ `home_screen_enhanced.dart`

---

## 🎯 خطة التنفيذ المقترحة

### المرحلة 1: الأساسيات (يوم واحد)
- [x] ✅ إنشاء نموذج SafeBox في Backend
- [x] ✅ إنشاء API endpoints للخزائن
- [ ] 🔲 إنشاء SafeBoxModel في Flutter
- [ ] 🔲 إضافة methods في ApiService

### المرحلة 2: شاشة إدارة الخزائن (يومين)
- [ ] 🔲 إنشاء SafeBoxesScreen
- [ ] 🔲 إضافة dialog لإنشاء/تعديل خزينة
- [ ] 🔲 ربطها بشاشة الإعدادات

### المرحلة 3: السندات (3 أيام)
- [ ] 🔲 تحديث add_voucher_screen
- [ ] 🔲 تحديث vouchers_list_screen
- [ ] 🔲 اختبار إنشاء سندات مع الخزائن

### المرحلة 4: الفواتير (5 أيام)
- [ ] 🔲 تحديث sales_invoice_screen_v2
- [ ] 🔲 تحديث purchase_invoice_screen
- [ ] 🔲 تحديث scrap invoices
- [ ] 🔲 تحديث return invoices
- [ ] 🔲 اختبار شامل

### المرحلة 5: التحسينات (يومين)
- [ ] 🔲 إضافة تقارير حسب الخزينة
- [ ] 🔲 إضافة quick actions
- [ ] 🔲 تحسين واجهة المستخدم

---

## 💡 نصائح التنفيذ

1. **ابدأ بالـ Models والـ API**: أنشئ SafeBoxModel و API methods أولاً
2. **اختبر كل مرحلة**: لا تنتقل للمرحلة التالية قبل اختبار الحالية
3. **استخدم Safe Defaults**: إذا لم يُختر خزينة، استخدم الافتراضية
4. **Backward Compatibility**: احتفظ بالكود القديم مؤقتاً للتوافق
5. **User Feedback**: اعرض رسائل واضحة عند اختيار الخزينة

---

## 📝 ملاحظات مهمة

### التوافق مع الكود القديم
```dart
// للحفاظ على التوافق، يمكن جعل safe_box_id اختيارياً
Future<void> createVoucher({
  int? safeBoxId, // إذا null، استخدم الحساب القديم
  int? accountId, // deprecated - for backward compatibility
}) async {
  final actualSafeBoxId = safeBoxId ?? await _getSafeBoxFromAccount(accountId);
  // ...
}
```

### معالجة الأخطاء
```dart
try {
  final safeBoxes = await api.getSafeBoxes(type: 'cash');
  if (safeBoxes.isEmpty) {
    // عرض رسالة: "لا توجد خزائن نقدية. يرجى إنشاء خزينة من الإعدادات"
  }
} catch (e) {
  // عرض رسالة خطأ واضحة
}
```

### UX Improvements
```dart
// إضافة أيقونات توضيحية
Widget _buildSafeBoxTile(SafeBox sb) {
  return ListTile(
    leading: Icon(sb.icon, color: _getColor(sb.type)),
    title: Text(sb.name),
    subtitle: Text('${sb.typeNameAr} • رصيد: ${sb.balance} ر.س'),
    trailing: sb.isDefault ? Chip(label: Text('افتراضي')) : null,
  );
}
```

---

## 🎉 الفوائد المتوقعة بعد التنفيذ

1. **تجربة مستخدم أفضل**: اختيار من 4 خزائن بدلاً من 100+ حساب
2. **تقليل الأخطاء**: صعب اختيار الحساب الخطأ
3. **تقارير أوضح**: "إجمالي الصرف من بنك الرياض" بدلاً من "الحساب 1010"
4. **مرونة أكبر**: إضافة خزائن جديدة بسهولة
5. **معلومات غنية**: IBAN, SWIFT, العيار مرتبطة بكل خزينة

---

## 📌 خلاصة

**إجمالي الملفات المتأثرة**: 19 ملف
- **تم تحديثها**: 3 ملفات (Backend + PayrollScreen)
- **يجب إنشاؤها**: 2 ملف (SafeBoxModel + SafeBoxesScreen)
- **يجب تحديثها**: 14 ملف (السندات + الفواتير + الإعدادات)

**الوقت المتوقع للتنفيذ الكامل**: 10-14 يوم عمل

**الأولوية القصوى**: SafeBoxModel → ApiService → SafeBoxesScreen
