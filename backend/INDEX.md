# 📖 Backend Directory - Index

## 🔴 ابدأ هنا / Start Here

قبل أي شيء، اقرأ: **[🔴_READ_FIRST.txt](🔴_READ_FIRST.txt)**

---

## 📁 دليل الملفات / File Directory

### 🚨 ملفات التنبيه والحماية / Safety Files
| الملف | الوصف | الأولوية |
|-------|-------|----------|
| [🔴_READ_FIRST.txt](🔴_READ_FIRST.txt) | تنبيه بصري - اقرأ أولاً | 🔴 عالية جداً |
| [QUICKSTART.md](QUICKSTART.md) | دليل التشغيل السريع | 🟡 عالية |
| [VENV_PROTECTION_COMPLETE.md](VENV_PROTECTION_COMPLETE.md) | تقرير نظام الحماية | 🔵 للمرجع |
| [VENV_REMINDERS_ADDED.md](VENV_REMINDERS_ADDED.md) | ملخص التغييرات | 🔵 للمرجع |

### 🔧 سكريبتات التشغيل / Run Scripts
| السكريبت | الاستخدام | مثال |
|----------|-----------|------|
| [run_python.sh](run_python.sh) ⭐ | تشغيل آمن مع venv | `./run_python.sh app.py` |
| [ACTIVATE_VENV_FIRST.sh](ACTIVATE_VENV_FIRST.sh) | عرض تعليمات التفعيل | `./ACTIVATE_VENV_FIRST.sh` |

### 📚 التوثيق الرئيسي / Main Documentation
| الملف | المحتوى |
|-------|---------|
| [README.md](README.md) | توثيق شامل للـ Backend |
| [requirements.txt](requirements.txt) | المكتبات المطلوبة |

### 🐍 ملفات Python الرئيسية / Main Python Files
| الملف | الوظيفة |
|-------|---------|
| [app.py](app.py) | تطبيق Flask الرئيسي |
| [models.py](models.py) | نماذج قاعدة البيانات |
| [routes.py](routes.py) | API endpoints |
| [config.py](config.py) | الإعدادات |
| [utils.py](utils.py) | وظائف مساعدة |
| [init_db.py](init_db.py) | تهيئة قاعدة البيانات |
| [gold_price.py](gold_price.py) | جلب أسعار الذهب |
| [test_invoices.py](test_invoices.py) | اختبارات شاملة |

### 🗄️ قاعدة البيانات / Database
| الملف/المجلد | الوصف |
|--------------|--------|
| [app.db](app.db) | قاعدة بيانات SQLite |
| [alembic/](alembic/) | مجلد Migrations |
| [alembic.ini](alembic.ini) | إعدادات Alembic |

---

## 🚀 سير العمل السريع / Quick Workflows

### 1️⃣ أول مرة تشغيل / First Time Setup
```bash
# تأكد من وجود venv
python3 -m venv venv

# فعّل venv
source venv/bin/activate

# ثبّت المكتبات
pip install -r requirements.txt

# طبّق migrations
alembic upgrade head
```

### 2️⃣ التشغيل اليومي / Daily Usage

**الخيار أ: التفعيل اليدوي**
```bash
cd backend
source venv/bin/activate
python app.py
```

**الخيار ب: السكريبت المساعد** ⭐
```bash
cd backend
./run_python.sh app.py
```

### 3️⃣ تشغيل الاختبارات / Run Tests
```bash
cd backend
./run_python.sh test_invoices.py
```

### 4️⃣ تحديث المكتبات / Update Packages
```bash
cd backend
source venv/bin/activate
pip install --upgrade -r requirements.txt
```

---

## 📖 ترتيب القراءة الموصى به / Recommended Reading Order

### للمبتدئين:
1. 🔴 [🔴_READ_FIRST.txt](🔴_READ_FIRST.txt)
2. 📘 [QUICKSTART.md](QUICKSTART.md)
3. 📗 [README.md](README.md)
4. 📙 [VENV_PROTECTION_COMPLETE.md](VENV_PROTECTION_COMPLETE.md)

### للمحترفين:
1. 📗 [README.md](README.md)
2. 🐍 [app.py](app.py) + [models.py](models.py)
3. 🔌 [routes.py](routes.py)
4. 📘 [QUICKSTART.md](QUICKSTART.md) (للمرجع)

---

## ⚠️ تذكيرات مهمة / Important Reminders

### 🔴 القاعدة الذهبية:
**دائماً فعّل venv قبل تشغيل أي أمر Python!**

### ✅ كيف أعرف أن venv مفعّل؟
يجب أن ترى:
```bash
(venv) salehalabbadi@Mac backend %  ← ✅ مفعّل
```

### 🆘 مشكلة؟
راجع: [QUICKSTART.md](QUICKSTART.md) → قسم Troubleshooting

---

## 📊 هيكل المشروع / Project Structure

```
backend/
├── 🔴_READ_FIRST.txt           ← ابدأ هنا!
├── QUICKSTART.md               ← دليل سريع
├── README.md                   ← توثيق كامل
├── run_python.sh               ← سكريبت آمن ⭐
├── ACTIVATE_VENV_FIRST.sh      ← تذكير
│
├── app.py                      ← Flask app
├── models.py                   ← Database models
├── routes.py                   ← API endpoints
├── config.py                   ← Settings
├── utils.py                    ← Helpers
│
├── requirements.txt            ← Dependencies
├── alembic.ini                 ← Migration config
├── app.db                      ← SQLite database
│
├── venv/                       ← Virtual environment
├── alembic/                    ← Migrations
│   └── versions/
│
└── test_invoices.py            ← Tests
```

---

## 🎯 الأهداف المحققة / Achieved Goals

- ✅ حماية كاملة من تشغيل Python بدون venv
- ✅ تنبيهات واضحة في 4 أماكن
- ✅ سكريبت تشغيل آمن ومُختبر
- ✅ توثيق شامل (300+ سطر)
- ✅ أمثلة وحلول للمشاكل
- ✅ دعم ثنائي اللغة (عربي/إنجليزي)

---

## 🔗 روابط سريعة / Quick Links

### التشغيل:
- [كيف أشغل السيرفر؟](QUICKSTART.md#تشغيل-السيرفر--run-server)
- [كيف أشغل الاختبارات؟](QUICKSTART.md#تشغيل-الاختبارات--run-tests)

### المشاكل:
- [venv غير موجود](QUICKSTART.md#مشكلة-1-venv-غير-موجود)
- [ModuleNotFoundError](QUICKSTART.md#مشكلة-3-modulenotfounderror)
- [Permission denied](QUICKSTART.md#مشكلة-2-permission-denied-عند-التشغيل)

### التوثيق:
- [نظرة عامة على المشروع](../README.md)
- [تعليمات Copilot](../.github/copilot-instructions.md)
- [تقرير نظام الحماية](VENV_PROTECTION_COMPLETE.md)

---

<div align="center">

## 💡 نصيحة اليوم

استخدم `./run_python.sh` للتشغيل الآمن التلقائي!

**Happy Coding! 🚀**

</div>

---

**آخر تحديث:** 10 أكتوبر 2025
