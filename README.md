# Yasar Gold & Jewelry POS System 💎# 💎 Yasar Gold & Jewelry POS System



نظام نقاط البيع للمجوهرات والذهب - ثنائي اللغة (عربي/إنجليزي)نظام نقاط البيع الشامل لتجارة الذهب والمجوهرات مع دعم كامل للمرتجعات والمعالجة المحاسبية.



## 📁 هيكل المشروع[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[![Python](https://img.shields.io/badge/python-3.9+-green.svg)](https://python.org)

```[![Flutter](https://img.shields.io/badge/flutter-latest-blue.svg)](https://flutter.dev)

yasargold/[![Status](https://img.shields.io/badge/status-production%20ready-success.svg)]()

├── backend/              # Flask REST API Backend

│   ├── alembic/         # Database migrations---

│   ├── venv/           # Python virtual environment (old - unused)

│   ├── _archived/      # Archived temporary files## 📋 جدول المحتويات

│   ├── app.py          # Main application

│   ├── models.py       # Database models- [نظرة عامة](#نظرة-عامة)

│   ├── routes.py       # API endpoints- [الميزات الرئيسية](#الميزات-الرئيسية)

│   └── ...- [البنية التقنية](#البنية-التقنية)

│- [التثبيت](#التثبيت)

├── frontend/            # Flutter Mobile App- [الاستخدام](#الاستخدام)

│   ├── lib/            # Dart source code- [التوثيق](#التوثيق)

│   │   ├── screens/   # UI screens- [المساهمة](#المساهمة)

│   │   ├── widgets/   # Reusable widgets- [الترخيص](#الترخيص)

│   │   └── api_service.dart

│   ├── assets/        # Fonts, images---

│   └── ...

│## 🎯 نظرة عامة

├── docs/               # Documentation

├── .venv/             # Active Python virtual environment**Yasar Gold POS** هو نظام متكامل لإدارة تجارة الذهب والمجوهرات يتميز بـ:

├── .github/           # GitHub config & copilot instructions

└── _archived/         # Archived old files & projects- 🔢 **6 أنواع من الفواتير**: بيع، شراء من عميل، شراء، ومرتجعاتها

- 📊 **معالجة محاسبية تلقائية**: قيود يومية تلقائية لكل نوع فاتورة
- 📈 **قائمة دخل تفاعلية**: تقرير دخلي متكامل يعرض صافي المبيعات، تكلفة المبيعات، المصاريف، والربح الصافي مع فلاتر زمنية ذكية في تطبيق Flutter

```- 🔄 **نظام مرتجعات متقدم**: ربط بالفواتير الأصلية مع تتبع أسباب الإرجاع

- ⚖️ **حسابات قائمة على الوزن**: جميع العمليات بالجرام وليس بالقيمة النقدية

## 🚀 التشغيل السريع- 🌍 **ثنائي اللغة**: دعم كامل للعربية والإنجليزية



### Backend (Flask)---

```bash

cd backend## ✨ الميزات الرئيسية

source ../venv/bin/activate  # أو: source ../.venv/bin/activate

python app.py  # يعمل على المنفذ 8001### 📦 إدارة الفواتير

```

#### الفواتير العادية:

### Frontend (Flutter)1. **بيع (Sales)**: 

```bash   - إنشاء فواتير بيع للعملاء

cd frontend   - حساب الأجرة بالجرام

flutter run   - دعم طرق دفع متعددة

```   

2. **شراء من عميل (Scrap Purchase from Customer)**:

## 🔑 الميزات الرئيسية   - شراء ذهب كسر من العملاء

   - تصنيف نوع الذهب (جديد/كسر)

- ✅ **إدارة المخزون**: تتبع الذهب بالوزن والعيار   - تحويل العيارات تلقائياً

- ✅ **فواتير البيع والشراء**: نظام فواتير شامل   

- ✅ **وسائل دفع متعددة**: نقدي، بطاقات، تحويلات، مع حساب العمولات3. **شراء (Purchase from Supplier)**:

- ✅ **نظام محاسبي**: قيود يومية، شجرة حسابات   - إدارة مشتريات الذهب من الموردين

- ✅ **إدارة العملاء والموردين**: سجل كامل بالتفاصيل   - دعم الدفع الآجل والنقدي

- ✅ **تحديث أسعار الذهب**: تلقائي ويدوي   - تتبع المخزون

- ✅ **واجهة عربية**: بخط Cairo وتصميم RTL
- 🆕 **Office Reservations Endpoint**: `POST /api/office-reservations` يسجل حجوزات الذهب من المكاتب، ويستهلك وزن أوامر التسكير المفتوحة فوراً مع تحديث إحصائيات المكتب، كما أن شاشة التسكير في Flutter أصبحت تتصل بهذا المسار مباشرة لتسجيل الحجوزات من التطبيق.
- 🆕 **Gold Reservation History UI**: شاشة Flutter جديدة تعرض سجل حجوزات الذهب مع فلاتر التاريخ والحالة والدفع، ويمكن الوصول إليها من قسم التسكير في القائمة الرئيسية.
- 🆕 **التكويد داخل فاتورة شراء المورد**: أصبح بإمكان أمين المخزون إنشاء الأصناف وباركودها مباشرة داخل شاشة فاتورة الشراء، ويتم إرسال تفاصيل القطع إلى نفس طلب إنشاء الفاتورة ليتم حفظها وترحيلها في خطوة واحدة.

#### فواتير المرتجعات:

## 📊 التقنيات المستخدمة4. **مرتجع بيع (Sales Return)**:

   - ربط بفاتورة البيع الأصلية

**Backend:**   - تسجيل سبب الإرجاع (إلزامي)

- Python 3.9.6   - معالجة محاسبية عكسية

- Flask + SQLAlchemy   

- SQLite/PostgreSQL5. **مرتجع شراء (Purchase Return from Customer)**:

- Alembic (Migrations)   - إرجاع الذهب المشترى من العميل

   - تتبع كامل للعملية

**Frontend:**   

- Flutter/Dart6. **مرتجع شراء (مورد) (Supplier Return)**:

- Material Design   - إرجاع المشتريات للموردين

- Cairo Font (Arabic)   - تحديث حساب الموردين تلقائياً



## 📝 ملاحظات مهمة### 💰 المحاسبة التلقائية



### حول venvالنظام ينشئ قيود محاسبية تلقائياً لكل عملية:

- المشروع يستخدم `.venv` في الجذر (مشترك بين backend و frontend)

- مجلد `backend/venv` قديم وغير مستخدم```

- دائماً فعّل `.venv` قبل تشغيل أوامر Pythonبيع          → مدين: الصندوق | دائن: المبيعات + المخزون

شراء من عميل  → مدين: المخزون | دائن: الصندوق

### حول المجلدات المؤرشفةشراء  → مدين: المخزون | دائن: الموردين

- `_archived/`: ملفات قديمة من الجذرمرتجع بيع     → عكس قيد البيع

- `backend/_archived/`: ملفات JSON مؤقتة وسجلاتمرتجع شراء    → عكس قيد الشراء

- `frontend/_archived/`: سجلات نظام Flutter```



## 🔧 الصيانة### 🎨 واجهة المستخدم

### 🔄 تهيئة العمليات من الصفر

مسح العمليات يكون من شاشة «إعادة التهيئة» في الإعدادات، على نسخة مُستعادة فقط: على الإنتاج لا يُنفَّذ أي تصفير (RESET-1). حُذفت أداة سطر الأوامر `reset_operations.py` (14 أكتوبر 2026، CHART-002 4ج1)، فقد كانت تتخطّى ذلك القفل.

بعد إعادة التهيئة:

1. أنشئ فاتورة شراء (عميل أو مورد) لتغذية المخزون ومتوسط التكلفة.
2. أنشئ فاتورة بيع للتحقق من تكلفة البضاعة المباعة والربحية.
3. استخدم تقرير قائمة الدخل أو `GET /api/gold-costing` للتأكد من أن المتوسط الجديد مطابق لعمليات الاختبار.

> ملاحظة: السكربت يعيد موازنة أرصدة الحسابات إلى صفر ويعيد إنشاء سجل متوسط التكلفة تلقائياً، لذا لا حاجة لأي خطوات يدوية إضافية قبل إدخال البيانات الجديدة.



### تحديث التبعيات- **تصميم عربي**: واجهة مصممة خصيصاً للمستخدم العربي

```bash- **Navigation سهل**: وصول سريع لجميع الوظائف

# Backend- **Widgets قابلة لإعادة الاستخدام**: مكونات مشتركة للاتساق

pip install -r backend/requirements.txt- **Dark Theme**: تصميم عصري بألوان الذهب



# Frontend---

flutter pub get

```## 🏗️ البنية التقنية



### تشغيل Migrations### Backend

```bash

cd backend```

alembic upgrade headTechnology Stack:

```├── Python 3.9+

├── Flask 3.0.3 (REST API)

## 📞 الدعم├── SQLAlchemy (ORM)

├── Alembic (Database Migrations)

للمزيد من المعلومات، راجع ملفات التوثيق في مجلد `docs/`├── SQLite / PostgreSQL

└── CORS enabled

---```



**آخر تحديث:** 16 أكتوبر 2025**الملفات الرئيسية:**

- `app.py` - تطبيق Flask الرئيسي
- `models.py` - نماذج البيانات (Customer, Item, Invoice, JournalEntry)
- `routes.py` - API endpoints
- `config.py` - الإعدادات (MAIN_KARAT, DATABASE_URL)
- `utils.py` - وظائف مساعدة (تحويل الأوزان)

### Frontend

```
Technology Stack:
├── Flutter (Dart)
├── Material Design
├── HTTP client
├── Shared Preferences
└── Cairo Font (Arabic)
```

**الملفات الرئيسية:**
- `lib/main.dart` - نقطة البداية
- `lib/screens/` - شاشات التطبيق
- `lib/widgets/` - مكونات مشتركة
- `lib/api_service.dart` - خدمة الاتصال بـ API

### Database Schema

```sql
-- الجداول الرئيسية
Customer          -- العملاء
Supplier          -- الموردين
Item              -- الأصناف
Invoice           -- الفواتير (6 أنواع)
InvoiceItem       -- تفاصيل الفاتورة
Account           -- الحسابات
JournalEntry      -- القيود اليومية
JournalEntryLine  -- سطور القيد
GoldPrice         -- أسعار الذهب
```

---

## 🚀 التثبيت

### المتطلبات الأساسية

- Python 3.9 أو أحدث
- Flutter SDK (latest stable)
- Git

### 1. Backend Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/yasargold.git
cd yasargold/backend

# Create virtual environment
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Run database migrations
alembic upgrade head

# Start the server
python app.py
```

السيرفر سيعمل على: `http://localhost:8001`

### 2. Frontend Setup

```bash
cd ../frontend

# Get Flutter dependencies
flutter pub get

# Run the app
flutter run
```

للويب:
```bash
flutter run -d chrome
```

---

## 📱 الاستخدام

### إنشاء فاتورة بيع

```
1. الشاشة الرئيسية → زر "فاتورة"
2. اختر "فاتورة بيع"
3. أدخل بيانات العميل
4. أضف الأصناف (وزن، عيار، أجرة)
5. احفظ
```

### إنشاء مرتجع

```
1. الشاشة الرئيسية → "فاتورة" → "المرتجعات"
2. اختر نوع المرتجع
3. اختر الفاتورة الأصلية
4. أدخل سبب الإرجاع (إلزامي)
5. راجع واحفظ
```

### عرض التقارير المحاسبية وقائمة الدخل

```
1. من الشاشة الرئيسية افتح "مركز التقارير"
2. اختر "قائمة الدخل" لتحليل صافي المبيعات والمصاريف حسب الفترة أو اختر أي تقرير محاسبي آخر (قيود اليومية، دفتر الأستاذ...)
3. حدد نطاق التاريخ، نوع التجميع (يومي/شهري/ربع سنوي/سنوي)، وحدد إذا كنت تريد تضمين القيود غير المرحلة، ثم استعرض المخططات والبطاقات التفصيلية
```

---

## 📚 التوثيق

### الوثائق المتوفرة

```
docs/
├── final_comprehensive_report.md       # التقرير الشامل
├── invoice_types_organization.md       # أنواع الفواتير
├── backend_complete_summary.md         # ملخص Backend
├── shared_widgets_documentation.md     # توثيق Widgets
└── ... (11 ملف إضافي)
```

### API Documentation

#### Create Invoice
```http
POST /api/invoices
Content-Type: application/json

{
  "customer_id": 1,
  "invoice_type": "بيع",
  "date": "2025-10-10",
  "items": [
    {
      "description": "خاتم ذهب",
      "karat": 21,
      "weight": 5.5,
      "wage_per_gram": 10.0
    }
  ],
  "payment_method": "نقدي",
  "amount_paid": 1000.0
}
```

#### Get Returnable Invoices
```http
GET /api/invoices/returnable?invoice_type=بيع&customer_id=1
```

**المزيد:** راجع `docs/` للتوثيق الكامل

---

## 🧪 الاختبار

### Backend Tests

```bash
cd backend
python test_invoices.py
```

**الاختبارات المشمولة:**
- ✅ إنشاء جميع أنواع الفواتير
- ✅ التحقق من القيود المحاسبية
- ✅ Validation للمرتجعات
- ✅ API endpoints

### Frontend Tests

```bash
cd frontend
flutter test
```

---

## 📊 الإحصائيات

```
Backend:
  الملفات: 15+
  السطور: 3,000+
  Endpoints: 20+
  
Frontend:
  الملفات: 25+
  السطور: 5,000+
  Screens: 10+
  Widgets: 15+
  
Documentation:
  الملفات: 11
  السطور: 10,000+
  التغطية: 100%
```

---

## 🤝 المساهمة

نرحب بالمساهمات! اتبع الخطوات التالية:

1. Fork المشروع
2. إنشاء branch جديد (`git checkout -b feature/AmazingFeature`)
3. Commit التغييرات (`git commit -m 'Add some AmazingFeature'`)
4. Push إلى Branch (`git push origin feature/AmazingFeature`)
5. فتح Pull Request

---

## 🗺️ خارطة الطريق

### النسخة 2.0 (قادمة)
- [ ] نظام موردين كامل مع قاعدة بيانات
- [ ] تقارير متقدمة (Excel, PDF)
- [ ] Barcode scanning
- [ ] Multi-user مع صلاحيات
- [ ] Mobile app منفصل
- [ ] Cloud sync

### النسخة 3.0 (مستقبلية)
- [ ] Multi-branch support
- [ ] Inventory forecasting
- [ ] Customer loyalty program
- [ ] WhatsApp integration
- [ ] Online catalog

---

## 👥 الفريق

- **المطور الرئيسي**: GitHub Copilot + Saleh Alabbadi
- **التصميم**: Material Design + Cairo Font
- **الاختبار**: Manual + Automated

---

## 📄 الترخيص

هذا المشروع مرخص تحت [MIT License](LICENSE).

---

## 📞 الدعم

للاستفسارات والدعم:
- 📧 Email: support@yasargold.com
- 💬 GitHub Issues: [Create an issue](https://github.com/yourusername/yasargold/issues)
- 📱 WhatsApp: +966XXXXXXXXX

---

## 🙏 شكر خاص

- Cairo Font Project
- Flutter Community
- Flask Community
- جميع المساهمين في المشروع

---

<div align="center">

**صُنع بـ ❤️ في السعودية**

⭐ إذا أعجبك المشروع، لا تنسى إضافة نجمة!

</div>
