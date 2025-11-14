# 🔧 Backend - دليل التشغيل السريع

## ⚠️ قاعدة ذهبية / Golden Rule

**🔴 دائماً فعّل البيئة الافتراضية أولاً!**  
**🔴 Always activate virtual environment first!**

---

## 🚀 الطريقة الصحيحة / Correct Way

### الخيار 1: التفعيل اليدوي (Manual)

```bash
# 1. الانتقال للمجلد
cd /Users/salehalabbadi/yasargold/backend

# 2. تفعيل البيئة الافتراضية
source venv/bin/activate

# 3. تأكد من رؤية (venv) في البداية
# You should see: (venv) salehalabbadi@Mac backend %

# 4. الآن شغّل ما تريد
python app.py
```

### الخيار 2: استخدام السكريبت المساعد (Helper Script)

```bash
cd /Users/salehalabbadi/yasargold/backend

# سيقوم بتفعيل venv تلقائياً ثم التشغيل
./run_python.sh app.py
./run_python.sh test_invoices.py
```

---

## 📋 الأوامر الشائعة / Common Commands

### تشغيل السيرفر / Run Server
```bash
source venv/bin/activate
python app.py
# أو / or
./run_python.sh app.py
```

### تشغيل الاختبارات / Run Tests
```bash
source venv/bin/activate
python test_invoices.py
# أو / or
./run_python.sh test_invoices.py
```

### تطبيق Migrations
```bash
source venv/bin/activate
alembic upgrade head
```

### تثبيت المكتبات / Install Packages
```bash
source venv/bin/activate
pip install -r requirements.txt
# أو مكتبة معينة / or specific package
pip install package_name
```

---

## ❌ أخطاء شائعة / Common Mistakes

### ❌ خطأ 1: تشغيل بدون venv
```bash
cd backend
python app.py  # ❌ خطأ!
```

**النتيجة:** قد تواجه:
- مكتبات غير موجودة
- إصدارات خاطئة
- أخطاء غريبة

### ✅ الحل:
```bash
cd backend
source venv/bin/activate  # ✅
python app.py            # ✅
```

---

### ❌ خطأ 2: نسيان cd للمجلد
```bash
# أنت في yasargold/
source venv/bin/activate  # ❌ خطأ! venv ليس هنا
```

**النتيجة:** `bash: venv/bin/activate: No such file or directory`

### ✅ الحل:
```bash
cd backend              # ✅ أولاً
source venv/bin/activate  # ✅ ثانياً
```

---

### ❌ خطأ 3: استخدام python3 بدلاً من python
```bash
source venv/bin/activate
python3 app.py  # ⚠️ قد يعمل لكن ليس مضموناً
```

### ✅ الحل:
```bash
source venv/bin/activate
python app.py  # ✅ استخدم python (بدون 3)
```

---

## 🔍 كيف أعرف أن venv مفعّل؟ / How to know venv is active?

### علامات التفعيل / Activation Signs:

1. **ظهور (venv) في البداية:**
   ```bash
   (venv) salehalabbadi@Mac backend %  ← ✅ مفعّل
   ```

2. **فحص المسار:**
   ```bash
   which python
   # يجب أن يظهر:
   # /Users/salehalabbadi/yasargold/backend/venv/bin/python
   ```

3. **فحص المتغير:**
   ```bash
   echo $VIRTUAL_ENV
   # يجب أن يظهر:
   # /Users/salehalabbadi/yasargold/backend/venv
   ```

---

## 🆘 مشاكل شائعة وحلولها / Troubleshooting

### مشكلة 1: venv غير موجود
```bash
# الإنشاء:
python3 -m venv venv

# التفعيل:
source venv/bin/activate

# التثبيت:
pip install -r requirements.txt
```

### مشكلة 2: Permission denied عند التشغيل
```bash
# إعطاء صلاحيات:
chmod +x run_python.sh

# ثم التشغيل:
./run_python.sh app.py
```

### مشكلة 3: ModuleNotFoundError
```bash
# تأكد من تفعيل venv:
source venv/bin/activate

# ثبّت المكتبات:
pip install -r requirements.txt

# ثم جرّب:
python app.py
```

---

## 📚 موارد إضافية / Additional Resources

- [Backend README](README.md) - توثيق كامل
- [🔴_READ_FIRST.txt](🔴_READ_FIRST.txt) - تذكير بصري
- [run_python.sh](run_python.sh) - سكريبت مساعد

---

## ✅ Checklist قبل التشغيل

قبل تشغيل أي أمر Python، تأكد من:

- [ ] أنت في مجلد `backend/`
- [ ] نفذت `source venv/bin/activate`
- [ ] ترى `(venv)` في بداية السطر
- [ ] جميع المكتبات مثبتة (`requirements.txt`)

---

**تذكر:** البيئة الافتراضية ليست خياراً، بل إلزامية! 🔴
**Remember:** Virtual environment is not optional, it's mandatory! 🔴
