# دليل استخدام نظام ترقيم العملاء والموردين

## نظرة عامة

تم تصميم نظام الترقيم لدعم **آلاف العملاء والمئات من الموردين** بشكل احترافي ومنظم.

---

## آلية الترقيم

### للعملاء (بالآلاف):

#### 1. عملاء بيع الذهب (1100)
- **النطاق**: 110000 - 119999
- **السعة**: 10,000 عميل
- **الترقيم**: متصل بدون تباعد (110000, 110001, 110002...)

```
مثال:
العميل الأول    : 110000
العميل الثاني   : 110001
العميل المائة   : 110099
العميل الألف    : 110999
العميل 10,000   : 119999
```

#### 2. عملاء الصياغة (1110)
- **النطاق**: 111000 - 111999
- **السعة**: 1,000 عميل
- **الترقيم**: متصل (111000, 111001, 111002...)

#### 3. عملاء المجوهرات الجاهزة (1120)
- **النطاق**: 112000 - 112999
- **السعة**: 1,000 عميل
- **الترقيم**: متصل (112000, 112001, 112002...)

---

### للموردين (بالمئات):

#### الموردين (211)
- **النطاق**: 21100 - 21999
- **السعة**: 900 مورد
- **الترقيم**: متصل (21100, 21101, 21102...)

```
مثال:
المورد الأول   : 21100
المورد الثاني  : 21101
المورد المائة  : 21199
المورد 900     : 21999
```

---

## API Endpoints الجديدة

### 1. الحصول على رقم الحساب التالي المقترح

```http
GET /api/accounts/next-number/<parent_number>
```

**مثال:**
```bash
curl http://localhost:8001/api/accounts/next-number/1100
```

**الاستجابة:**
```json
{
  "suggested_number": "110000",
  "is_valid": true,
  "message": "رقم الحساب متاح",
  "use_spacing": false,
  "capacity_info": {
    "category": "1100",
    "total_capacity": 10000,
    "used": 0,
    "available": 10000,
    "next_number": "110000",
    "usage_percentage": 0.0,
    "start_range": 110000,
    "end_range": 119999
  }
}
```

---

### 2. التحقق من صحة رقم حساب

```http
POST /api/accounts/validate-number
Content-Type: application/json

{
  "account_number": "110000",
  "parent_account_number": "1100"
}
```

**الاستجابة:**
```json
{
  "is_valid": true,
  "message": "رقم الحساب صحيح ومتاح"
}
```

---

### 3. الحصول على معلومات السعة

```http
GET /api/accounts/capacity/<category_number>
```

**مثال:**
```bash
curl http://localhost:8001/api/accounts/capacity/1100
```

**الاستجابة:**
```json
{
  "category": "1100",
  "total_capacity": 10000,
  "used": 150,
  "available": 9850,
  "next_number": "110150",
  "usage_percentage": 1.5,
  "start_range": 110000,
  "end_range": 119999
}
```

---

## الاستخدام في Flutter

### 1. إضافة الدوال في `api_service.dart`:

```dart
// الحصول على رقم الحساب التالي المقترح
Future<Map<String, dynamic>> getNextAccountNumber(String parentNumber) async {
  final response = await http.get(
    Uri.parse('$baseUrl/api/accounts/next-number/$parentNumber'),
  );
  
  if (response.statusCode == 200) {
    return json.decode(response.body);
  } else {
    throw Exception('فشل الحصول على رقم الحساب التالي');
  }
}

// التحقق من صحة رقم حساب
Future<Map<String, dynamic>> validateAccountNumber(
  String accountNumber, 
  String parentNumber
) async {
  final response = await http.post(
    Uri.parse('$baseUrl/api/accounts/validate-number'),
    headers: {'Content-Type': 'application/json'},
    body: json.encode({
      'account_number': accountNumber,
      'parent_account_number': parentNumber,
    }),
  );
  
  if (response.statusCode == 200) {
    return json.decode(response.body);
  } else {
    throw Exception('فشل التحقق من رقم الحساب');
  }
}

// الحصول على معلومات السعة
Future<Map<String, dynamic>> getAccountCapacity(String categoryNumber) async {
  final response = await http.get(
    Uri.parse('$baseUrl/api/accounts/capacity/$categoryNumber'),
  );
  
  if (response.statusCode == 200) {
    return json.decode(response.body);
  } else {
    throw Exception('فشل الحصول على معلومات السعة');
  }
}
```

---

### 2. الاستخدام في شاشة إضافة عميل جديد:

```dart
class AddCustomerScreen extends StatefulWidget {
  @override
  _AddCustomerScreenState createState() => _AddCustomerScreenState();
}

class _AddCustomerScreenState extends State<AddCustomerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _accountNumberController = TextEditingController();
  final _nameController = TextEditingController();
  
  String? _selectedCategory = '1100'; // عملاء بيع ذهب (افتراضي)
  Map<String, dynamic>? _capacityInfo;
  
  @override
  void initState() {
    super.initState();
    _loadNextAccountNumber();
    _loadCapacityInfo();
  }
  
  // تحميل رقم الحساب التالي تلقائياً
  Future<void> _loadNextAccountNumber() async {
    try {
      final result = await ApiService().getNextAccountNumber(_selectedCategory!);
      if (result['is_valid']) {
        setState(() {
          _accountNumberController.text = result['suggested_number'];
        });
      }
    } catch (e) {
      print('خطأ في تحميل رقم الحساب: $e');
    }
  }
  
  // تحميل معلومات السعة
  Future<void> _loadCapacityInfo() async {
    try {
      final info = await ApiService().getAccountCapacity(_selectedCategory!);
      setState(() {
        _capacityInfo = info;
      });
    } catch (e) {
      print('خطأ في تحميل معلومات السعة: $e');
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('إضافة عميل جديد')),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              // عرض معلومات السعة
              if (_capacityInfo != null)
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Text('السعة المتاحة: ${_capacityInfo!['available']} من ${_capacityInfo!['total_capacity']}'),
                        SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: _capacityInfo!['usage_percentage'] / 100,
                        ),
                        SizedBox(height: 4),
                        Text('نسبة الاستخدام: ${_capacityInfo!['usage_percentage']}%'),
                      ],
                    ),
                  ),
                ),
              
              SizedBox(height: 16),
              
              // اختيار فئة العميل
              DropdownButtonFormField<String>(
                value: _selectedCategory,
                decoration: InputDecoration(labelText: 'فئة العميل'),
                items: [
                  DropdownMenuItem(value: '1100', child: Text('عملاء بيع ذهب')),
                  DropdownMenuItem(value: '1110', child: Text('عملاء صياغة')),
                  DropdownMenuItem(value: '1120', child: Text('عملاء مجوهرات جاهزة')),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedCategory = value;
                  });
                  _loadNextAccountNumber();
                  _loadCapacityInfo();
                },
              ),
              
              SizedBox(height: 16),
              
              // رقم الحساب (يتم تعبئته تلقائياً)
              TextFormField(
                controller: _accountNumberController,
                decoration: InputDecoration(
                  labelText: 'رقم الحساب',
                  hintText: 'سيتم التعبئة تلقائياً',
                  suffixIcon: IconButton(
                    icon: Icon(Icons.refresh),
                    onPressed: _loadNextAccountNumber,
                    tooltip: 'تحديث الرقم',
                  ),
                ),
                readOnly: true, // للقراءة فقط
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'رقم الحساب مطلوب';
                  }
                  return null;
                },
              ),
              
              SizedBox(height: 16),
              
              // اسم العميل
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(labelText: 'اسم العميل'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'الاسم مطلوب';
                  }
                  return null;
                },
              ),
              
              SizedBox(height: 24),
              
              // زر الحفظ
              ElevatedButton(
                onPressed: _saveCustomer,
                child: Text('حفظ'),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Future<void> _saveCustomer() async {
    if (!_formKey.currentState!.validate()) return;
    
    try {
      // التحقق من صحة الرقم قبل الحفظ
      final validation = await ApiService().validateAccountNumber(
        _accountNumberController.text,
        _selectedCategory!,
      );
      
      if (!validation['is_valid']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(validation['message'])),
        );
        return;
      }
      
      // حفظ الحساب
      await ApiService().addAccount({
        'account_number': _accountNumberController.text,
        'name': _nameController.text,
        'type': 'Asset',
        'parent_id': _getParentId(_selectedCategory!),
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم إضافة العميل بنجاح')),
      );
      
      Navigator.pop(context);
      
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ: $e')),
      );
    }
  }
  
  int? _getParentId(String categoryNumber) {
    // احصل على parent_id من قاعدة البيانات أو من الذاكرة المؤقتة
    // هذا مجرد مثال
    return null; // يجب استبداله بالقيمة الفعلية
  }
}
```

---

## ملاحظات هامة

1. **الترقيم التلقائي**: يُنصح بترك رقم الحساب للنظام ليقوم بتوليده تلقائياً لضمان عدم التكرار.

2. **مراقبة السعة**: استخدم endpoint `/api/accounts/capacity/<category>` لعرض نسبة الاستخدام للمستخدم.

3. **التحقق من الصحة**: دائماً تحقق من صحة رقم الحساب قبل الحفظ باستخدام `/api/accounts/validate-number`.

4. **الأداء**: للأعداد الكبيرة من العملاء، استخدم pagination عند عرض القوائم.

5. **النسخ الاحتياطي**: قم بعمل نسخة احتياطية من قاعدة البيانات بشكل دوري.

---

## أمثلة عملية

### مثال 1: إضافة 5000 عميل

```python
from backend.app import app
from backend.models import Account, db
from backend.account_number_generator import get_next_account_number

with app.app_context():
    # احصل على parent_id لحساب "عملاء بيع ذهب"
    parent = Account.query.filter_by(account_number='1100').first()
    
    for i in range(5000):
        # احصل على الرقم التالي
        account_number = get_next_account_number('1100', use_spacing=False)
        
        # أنشئ حساب العميل
        customer_account = Account(
            account_number=account_number,
            name=f'عميل رقم {i+1}',
            type='Asset',
            parent_id=parent.id
        )
        
        db.session.add(customer_account)
        
        # Commit كل 100 عميل لتحسين الأداء
        if (i + 1) % 100 == 0:
            db.session.commit()
            print(f'تم إضافة {i+1} عميل...')
    
    db.session.commit()
    print('تم إضافة 5000 عميل بنجاح!')
```

---

**تاريخ التحديث**: 10 أكتوبر 2025  
**الإصدار**: 1.0
