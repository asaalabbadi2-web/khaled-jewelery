# 🔍 كيف تلاحظ التغييرات في نظام الترحيل

## 📱 الطرق المتاحة

---

## 1️⃣ عبر سكريبت سريع (الأسهل)

```bash
cd backend
./check_posting_status.sh
```

**الناتج:**
```
════════════════════════════════════════════════
     📊 ملخص نظام الترحيل
════════════════════════════════════════════════

🔢 الإحصائيات:
   الفواتير: 1 مرحّلة من أصل 19 (18 غير مرحّلة)
   القيود: 0 مرحّلة من أصل 40 (40 غير مرحّلة)

════════════════════════════════════════════════
     ✅ الفواتير المرحلة
════════════════════════════════════════════════
   رقم 19 | بيع | 6000.0 ر.س
   ↳ رُحّلت بتاريخ: 2025-11-10T01:31:05
   ↳ بواسطة: أحمد المحاسب
```

---

## 2️⃣ عبر API Endpoints

### الإحصائيات
```bash
curl http://localhost:8001/api/posting/stats | python3 -m json.tool
```

### الفواتير المرحلة
```bash
curl http://localhost:8001/api/invoices/posted
```

### الفواتير غير المرحلة
```bash
curl http://localhost:8001/api/invoices/unposted
```

### القيود المرحلة
```bash
curl http://localhost:8001/api/journal-entries/posted
```

### القيود غير المرحلة
```bash
curl http://localhost:8001/api/journal-entries/unposted
```

---

## 3️⃣ عبر قاعدة البيانات مباشرة

### عرض الفواتير مع حالة الترحيل
```bash
sqlite3 -header -column backend/app.db "
SELECT 
  id as 'رقم',
  invoice_type as 'النوع',
  total as 'المبلغ',
  CASE is_posted 
    WHEN 1 THEN '✅ مرحّلة' 
    ELSE '⏳ غير مرحّلة' 
  END as 'الحالة',
  posted_by as 'المستخدم',
  substr(posted_at, 1, 16) as 'وقت الترحيل'
FROM invoice 
ORDER BY id DESC 
LIMIT 10;
"
```

**الناتج:**
```
رقم  النوع         المبلغ      الحالة        المستخدم      وقت الترحيل     
---  ------------  ----------  ------------  ------------  ----------------
19   بيع           6000.0      ✅ مرحّلة      أحمد المحاسب  2025-11-10 01:31
18   بيع           4800.0      ⏳ غير مرحّلة                                
17   بيع           5000.0      ⏳ غير مرحّلة
```

### عرض الحقول الجديدة
```bash
sqlite3 backend/app.db "PRAGMA table_info(invoice);" | grep posted
```

**الناتج:**
```
37|is_posted|BOOLEAN|1|0|0
38|posted_at|DATETIME|0||0
39|posted_by|VARCHAR(100)|0||0
```

### إحصائيات سريعة
```bash
# عدد الفواتير المرحلة
sqlite3 backend/app.db "SELECT COUNT(*) FROM invoice WHERE is_posted = 1;"

# عدد الفواتير غير المرحلة
sqlite3 backend/app.db "SELECT COUNT(*) FROM invoice WHERE is_posted = 0;"

# عدد القيود المرحلة
sqlite3 backend/app.db "SELECT COUNT(*) FROM journal_entry WHERE is_posted = 1;"

# عدد القيود غير المرحلة
sqlite3 backend/app.db "SELECT COUNT(*) FROM journal_entry WHERE is_posted = 0;"
```

---

## 4️⃣ عبر المتصفح

افتح المتصفح واذهب إلى:

### صفحة Routes
```
http://localhost:8001/routes
```
ابحث عن "posting" لرؤية جميع الـendpoints الجديدة (11 endpoint)

### API مباشرة
- **الإحصائيات:** `http://localhost:8001/api/posting/stats`
- **الفواتير المرحلة:** `http://localhost:8001/api/invoices/posted`
- **الفواتير غير المرحلة:** `http://localhost:8001/api/invoices/unposted`
- **القيود المرحلة:** `http://localhost:8001/api/journal-entries/posted`
- **القيود غير المرحلة:** `http://localhost:8001/api/journal-entries/unposted`

---

## 5️⃣ في كود Flutter (مستقبلاً)

عند إضافة شاشة في Flutter، يمكنك استخدام:

```dart
// جلب الفواتير غير المرحلة
final response = await http.get(
  Uri.parse('$baseUrl/api/invoices/unposted'),
);

// ترحيل فاتورة
await http.post(
  Uri.parse('$baseUrl/api/invoices/post/$invoiceId'),
  headers: {'Content-Type': 'application/json'},
  body: jsonEncode({'posted_by': userName}),
);
```

---

## 🎯 الطريقة الموصى بها

### للاستخدام اليومي:
```bash
cd backend && ./check_posting_status.sh
```

### للتطوير والتجربة:
```bash
# الإحصائيات
curl -s http://localhost:8001/api/posting/stats | python3 -m json.tool

# ترحيل فاتورة
curl -X POST http://localhost:8001/api/invoices/post/19 \
  -H "Content-Type: application/json" \
  -d '{"posted_by":"اسمك"}'
```

### لقاعدة البيانات:
```bash
sqlite3 -header -column backend/app.db "
SELECT id, invoice_type, is_posted, posted_by 
FROM invoice 
ORDER BY id DESC 
LIMIT 5;
"
```

---

## 📊 نموذج ناتج كامل

```bash
$ ./check_posting_status.sh

════════════════════════════════════════════════
     📊 ملخص نظام الترحيل
════════════════════════════════════════════════

🔢 الإحصائيات:
   الفواتير: 1 مرحّلة من أصل 19 (18 غير مرحّلة)
   القيود: 0 مرحّلة من أصل 40 (40 غير مرحّلة)

════════════════════════════════════════════════
     ✅ الفواتير المرحلة
════════════════════════════════════════════════
   رقم 19 | بيع | 6000.0 ر.س
   ↳ رُحّلت بتاريخ: 2025-11-10T01:31:05
   ↳ بواسطة: أحمد المحاسب

════════════════════════════════════════════════
     ⏳ الفواتير غير المرحلة
════════════════════════════════════════════════
   عدد: 18 فاتورة
   • رقم 18 | بيع | 4800.0 ر.س
   • رقم 17 | بيع | 5000.0 ر.س
   • رقم 16 | بيع | 4030.76625 ر.س
   ... و 15 فاتورة أخرى

════════════════════════════════════════════════
```

---

## 🔗 الملفات المرجعية

- **دليل النظام الكامل:** `backend/POSTING_SYSTEM_GUIDE.md`
- **سكريبت الفحص:** `backend/check_posting_status.sh`
- **API Routes:** `backend/posting_routes.py`
- **Models:** `backend/models.py`

---

**آخر تحديث:** 2025-11-10
