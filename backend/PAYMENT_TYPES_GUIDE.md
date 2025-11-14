# 📚 دليل إضافة وسيلة دفع جديدة

## 🎯 الهدف
جعل نظام وسائل الدفع **ديناميكياً بالكامل** - بحيث يمكن إضافة أنواع جديدة **بدون تعديل الكود**

---

## 🔄 الآلية الديناميكية

### ❌ **قبل: النظام القديم (Hardcoded)**
```dart
// في payment_methods_screen.dart - قائمة ثابتة
final paymentTypes = [
  {'value': 'mada', 'label': 'مدى 💳'},
  {'value': 'visa', 'label': 'فيزا 💳'},
  // لإضافة نوع جديد → يجب تعديل الكود!
];
```

### ✅ **بعد: النظام الجديد (Dynamic)**
```dart
// تُجلب من Backend API
List<dynamic> _paymentTypes = [];

@override
void initState() {
  _fetchPaymentTypes(); // جلب الأنواع من القاعدة
}

Future<void> _fetchPaymentTypes() async {
  final types = await apiService.getPaymentTypes();
  setState(() => _paymentTypes = types);
}
```

---

## 📋 خطوات إضافة وسيلة دفع جديدة (مثال: Binance Pay)

### 1️⃣ **إضافة النوع عبر API** (بدون كود!)

#### أ. باستخدام cURL:
```bash
curl -X POST http://localhost:8001/api/payment-types \
  -H "Content-Type: application/json" \
  -d '{
    "code": "binance_pay",
    "name_ar": "Binance Pay",
    "name_en": "Binance Pay",
    "icon": "₿",
    "category": "crypto",
    "sort_order": 12
  }'
```

#### ب. أو عبر شاشة الإعدادات (إذا أضفنا واجهة):
- افتح "الإعدادات" → "أنواع وسائل الدفع"
- اضغط "إضافة نوع جديد"
- املأ:
  - **الكود**: `binance_pay` (اسم فريد بالإنجليزية)
  - **الاسم بالعربية**: `Binance Pay`
  - **الأيقونة**: `₿`
  - **التصنيف**: `crypto`
  - **الترتيب**: `12`
- احفظ ✅

### 2️⃣ **إضافة الحساب المحاسبي**
- افتح "الدليل المحاسبي"
- أضف حساب:
  ```
  رقم: 1150
  الاسم: محفظة Binance Pay
  النوع: receivable (أوراق قبض)
  ```

### 3️⃣ **إضافة وسيلة الدفع**
- افتح "وسائل الدفع"
- اضغط "إضافة وسيلة دفع"
- **الآن ستجد "Binance Pay ₿" في القائمة تلقائياً!** ✅
- اختر الحساب: `1150 - محفظة Binance Pay`
- احفظ

**النتيجة:**
- رقم الحساب التلقائي: `1150.1`
- النوع: `binance_pay`
- جاهز للاستخدام في الفواتير! 🎉

---

## 🔧 التفاصيل التقنية

### Backend (Flask)

#### Model: `PaymentType` (في `models.py`)
```python
class PaymentType(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(50), unique=True)  # binance_pay
    name_ar = db.Column(db.String(100))            # Binance Pay
    name_en = db.Column(db.String(100))            # Binance Pay
    icon = db.Column(db.String(10))                # ₿
    category = db.Column(db.String(50))            # crypto
    is_active = db.Column(db.Boolean)
    sort_order = db.Column(db.Integer)
```

#### Endpoints (في `payment_methods_routes.py`)
```python
# GET /api/payment-types → جلب الأنواع
# POST /api/payment-types → إضافة نوع جديد
# DELETE /api/payment-types/:id → حذف نوع
```

### Frontend (Flutter)

#### في `ApiService`:
```dart
Future<List<dynamic>> getPaymentTypes() async {
  final response = await http.get(
    Uri.parse('$_baseUrl/payment-types'),
  );
  return json.decode(response.body);
}
```

#### في `payment_methods_screen.dart`:
```dart
List<dynamic> _paymentTypes = [];

@override
void initState() {
  super.initState();
  _fetchData();
}

Future<void> _fetchData() async {
  final types = await apiService.getPaymentTypes();
  final methods = await apiService.getPaymentMethods();
  setState(() {
    _paymentTypes = types;
    _paymentMethods = methods;
  });
}

// في Dialog الإضافة:
DropdownButtonFormField<String>(
  items: _paymentTypes.map((type) {
    return DropdownMenuItem(
      value: type['code'],
      child: Text('${type['name_ar']} ${type['icon']}'),
    );
  }).toList(),
)
```

---

## 📊 التصنيفات المتاحة

| Category | الوصف | أمثلة |
|----------|-------|-------|
| `card` | بطاقات بنكية | مدى، فيزا، ماستركارد |
| `mobile_wallet` | محافظ إلكترونية | STC Pay، Apple Pay، UrPay |
| `bnpl` | اشتر الآن وادفع لاحقاً | تمارا، تابي |
| `cash` | نقد | نقداً |
| `crypto` | عملات رقمية | Bitcoin، Binance Pay |
| `bank_transfer` | تحويل بنكي | تحويل IBAN |

---

## 🚀 الأنواع الافتراضية

عند تشغيل `python seed_payment_types.py`:
```python
✅ مدى (mada) 💳
✅ فيزا (visa) 💳
✅ ماستركارد (mastercard) 💳
✅ أمريكان إكسبريس (amex) 💳
✅ Apple Pay (apple_pay) 📱
✅ STC Pay (stc_pay) 📱
✅ يور باي (urpay) 📱
✅ تمارا (tamara) 🛍️
✅ تابي (tabby) 🛍️
✅ نقداً (cash) 💵
✅ عملات رقمية (crypto) ₿
```

---

## ✨ مزايا النظام الجديد

### ✅ **ديناميكي 100%**
- إضافة أنواع جديدة بدون برمجة
- حذف أنواع غير مستخدمة
- تعديل الترتيب والأيقونات

### ✅ **متعدد اللغات**
- `name_ar`: العربية
- `name_en`: الإنجليزية
- قابل للتوسع لإضافة لغات أخرى

### ✅ **مصنف ومنظم**
- تصنيفات منطقية (بطاقات، محافظ، BNPL...)
- ترتيب قابل للتخصيص
- أيقونات تعبيرية

### ✅ **آمن**
- لا يمكن حذف نوع مستخدم في وسائل دفع
- كود فريد (Unique) لكل نوع
- تحقق من البيانات

---

## 🎯 أمثلة عملية

### مثال 1: إضافة "UrPay"
```bash
# 1. إضافة النوع
curl -X POST http://localhost:8001/api/payment-types \
  -H "Content-Type: application/json" \
  -d '{"code": "urpay", "name_ar": "يور باي", "icon": "📱", "category": "mobile_wallet"}'

# 2. إضافة الحساب في الدليل المحاسبي
# رقم: 1160، الاسم: محفظة UrPay، النوع: receivable

# 3. في شاشة وسائل الدفع → اختر "يور باي 📱" → اختر الحساب 1160
# ✅ يُنشئ تلقائياً: 1160.1 - UrPay
```

### مثال 2: إضافة "Klarna" (BNPL)
```bash
curl -X POST http://localhost:8001/api/payment-types \
  -H "Content-Type: application/json" \
  -d '{
    "code": "klarna",
    "name_ar": "كلارنا",
    "name_en": "Klarna",
    "icon": "🛒",
    "category": "bnpl",
    "sort_order": 10
  }'
```

---

## 📝 ملاحظات مهمة

1. **الكود (code) يجب أن يكون فريداً**: `urpay`, `binance_pay`, `klarna`
2. **التصنيف اختياري**: إذا لم يُحدد، يكون `card` افتراضياً
3. **الترتيب**: الأرقام الأصغر تظهر أولاً (1, 2, 3...)
4. **الحذف**: لا يمكن حذف نوع مستخدم في وسائل دفع نشطة

---

## 🔗 الخطوات التالية

### لتطبيق النظام كاملاً:

1. **إنشاء الجدول**:
   ```bash
   cd backend
   source venv/bin/activate
   python
   >>> from app import app, db
   >>> from models import PaymentType
   >>> with app.app_context():
   ...     db.create_all()
   >>> exit()
   ```

2. **تعبئة البيانات الافتراضية**:
   ```bash
   python seed_payment_types.py
   ```

3. **تحديث Flutter**:
   - تعديل `payment_methods_screen.dart`
   - استبدال القائمة الثابتة بـ `_fetchPaymentTypes()`

4. **اختبار**:
   ```bash
   curl http://localhost:8001/api/payment-types
   ```

---

## 🎉 النتيجة

**الآن يمكنك:**
- ✅ إضافة أي وسيلة دفع جديدة عبر API
- ✅ تظهر تلقائياً في التطبيق
- ✅ لا حاجة لتعديل الكود أبداً
- ✅ مرونة كاملة للمستقبل

**أمثلة وسائل يمكن إضافتها لاحقاً:**
- Stripe, PayPal, Square
- Western Union, MoneyGram
- التحويلات الدولية (SWIFT)
- الشيكات
- بطاقات الهدايا (Gift Cards)

**🚀 نظام قابل للتوسع اللانهائي!**
