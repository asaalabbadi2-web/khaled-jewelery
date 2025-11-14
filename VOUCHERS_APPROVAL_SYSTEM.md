# ✅ نظام الموافقة على السندات

## 📋 الحالة الحالية

تم إضافة نظام الموافقة الكامل للسندات مع JWT authentication!

## 🔐 الصلاحيات المضافة

تم إضافة 6 صلاحيات جديدة للسندات:

1. **voucher.view** - عرض السندات
2. **voucher.create** - إنشاء سند
3. **voucher.edit** - تعديل سند
4. **voucher.delete** - حذف سند
5. **voucher.approve** - الموافقة على السندات
6. **voucher.cancel** - إلغاء سند

✅ تم إضافة جميع الصلاحيات لدور Admin تلقائياً!

## 🚀 Endpoints الجديدة

### 1. عرض السندات حسب الحالة

#### السندات بانتظار الموافقة
```bash
GET /api/vouchers/pending
Authorization: Bearer {token}
```

#### السندات الموافق عليها
```bash
GET /api/vouchers/approved
Authorization: Bearer {token}
```

#### السندات المرفوضة
```bash
GET /api/vouchers/rejected
Authorization: Bearer {token}
```

### 2. الموافقة والرفض

#### الموافقة على سند واحد
```bash
POST /api/vouchers/approve/{voucher_id}
Authorization: Bearer {token}
```

#### رفض سند
```bash
POST /api/vouchers/reject/{voucher_id}
Authorization: Bearer {token}
Content-Type: application/json

{
  "rejection_reason": "سبب الرفض"
}
```

#### الموافقة على مجموعة سندات
```bash
POST /api/vouchers/approve/batch
Authorization: Bearer {token}
Content-Type: application/json

{
  "voucher_ids": [1, 2, 3, ...]
}
```

#### إلغاء الموافقة على سند
```bash
POST /api/vouchers/unapprove/{voucher_id}
Authorization: Bearer {token}
```

**ملاحظة**: لا يمكن إلغاء الموافقة إذا كان السند مرتبط بقيد محاسبي.

### 3. الإحصائيات

```bash
GET /api/vouchers/stats
Authorization: Bearer {token}
```

**يرجع**:
```json
{
  "success": true,
  "stats": {
    "by_status": {
      "pending": 10,
      "approved": 25,
      "rejected": 2,
      "cancelled": 1
    },
    "by_type": {
      "receipt": 20,
      "payment": 18
    },
    "total": 38
  }
}
```

## 📊 سير العمل (Workflow)

### حالات السند (Status)

1. **pending** - بانتظار الموافقة (الحالة الافتراضية)
2. **approved** - موافق عليه
3. **rejected** - مرفوض
4. **cancelled** - ملغى

### المسار الطبيعي

```
إنشاء سند (pending)
      ↓
   [مراجعة]
      ↓
  ┌──────┴──────┐
  ↓             ↓
Approve      Reject
  ↓             ↓
approved    rejected
```

### إلغاء الموافقة

```
approved
    ↓
unapprove (إذا لم يكن مرتبط بقيد)
    ↓
 pending
```

## 🔒 الأمان

### JWT Required
جميع الـ endpoints تتطلب JWT token صالح.

### Permission Checks
- `voucher.view` - لعرض السندات
- `voucher.approve` - للموافقة/الرفض/إلغاء الموافقة

### Audit Logging
يتم تسجيل جميع العمليات في audit log:
- `voucher_approve` - الموافقة
- `voucher_reject` - الرفض
- `voucher_unapprove` - إلغاء الموافقة
- `batch_voucher_approve` - موافقة جماعية

## 🧪 أمثلة الاستخدام

### مثال 1: الموافقة على سند

```bash
# تسجيل الدخول للحصول على token
TOKEN=$(curl -s -X POST http://localhost:8001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | jq -r '.token')

# الموافقة على سند رقم 5
curl -X POST http://localhost:8001/api/vouchers/approve/5 \
  -H "Authorization: Bearer $TOKEN"
```

### مثال 2: رفض سند مع سبب

```bash
curl -X POST http://localhost:8001/api/vouchers/reject/7 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "rejection_reason": "المبلغ غير صحيح - يرجى المراجعة"
  }'
```

### مثال 3: موافقة جماعية

```bash
curl -X POST http://localhost:8001/api/vouchers/approve/batch \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "voucher_ids": [1, 2, 3, 4, 5]
  }'
```

### مثال 4: عرض السندات بانتظار الموافقة

```bash
curl http://localhost:8001/api/vouchers/pending \
  -H "Authorization: Bearer $TOKEN"
```

## 📝 ملاحظات مهمة

### 1. الموافقة على السند
- يغير الحالة من `pending` إلى `approved`
- يسجل `approved_by` و `approved_at`
- يُسجل في audit log

### 2. رفض السند
- يغير الحالة من `pending` إلى `rejected`
- **يتطلب سبب الرفض**
- يسجل `rejected_by`، `rejected_at`، `rejection_reason`

### 3. إلغاء الموافقة
- يعيد الحالة إلى `pending`
- **لا يمكن إذا كان السند مرتبط بقيد محاسبي**
- يمسح `approved_by` و `approved_at`

### 4. السندات الملغاة
- لا يمكن الموافقة على سند ملغى
- لا يمكن رفض سند ملغى

## 🎯 الخطوات التالية

### للمستخدم:
1. ✅ سجّل خروج ثم دخول للحصول على token جديد
2. ✅ انتقل لشاشة السندات
3. ✅ استمتع بنظام الموافقة الجديد!

### للمطور (Frontend):
يمكن إضافة شاشة إدارة السندات في Flutter:

```dart
// في api_service.dart
Future<Map<String, dynamic>> getPendingVouchers() async {
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('jwt_token');
  
  if (token == null) {
    throw Exception('يجب تسجيل الدخول أولاً');
  }
  
  final response = await http.get(
    Uri.parse('$_baseUrl/vouchers/pending'),
    headers: {
      'Authorization': 'Bearer $token',
    },
  );
  
  if (response.statusCode == 200) {
    return json.decode(utf8.decode(response.bodyBytes));
  } else {
    throw Exception('فشل تحميل السندات');
  }
}

Future<Map<String, dynamic>> approveVoucher(int voucherId) async {
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('jwt_token');
  
  final response = await http.post(
    Uri.parse('$_baseUrl/vouchers/approve/$voucherId'),
    headers: {
      'Authorization': 'Bearer $token',
    },
  );
  
  return json.decode(utf8.decode(response.bodyBytes));
}
```

## 📚 الملفات المعدلة

1. **backend/posting_routes.py** - أضيف نظام الموافقة الكامل
2. **backend/add_voucher_permissions.py** - سكريبت إضافة الصلاحيات
3. **backend/models.py** - (موجود مسبقاً) Voucher model مع status
4. **VOUCHERS_APPROVAL_SYSTEM.md** - هذا الملف

## ✅ الخلاصة

نظام الموافقة على السندات جاهز تماماً! 🎉

- ✅ Backend endpoints كاملة
- ✅ JWT authentication
- ✅ Permission system
- ✅ Audit logging
- ✅ Batch operations
- ✅ Validation rules
- ✅ Documentation

**تذكر**: قد تحتاج لإعادة تشغيل Backend server لتفعيل الـ routes الجديدة!

```bash
cd backend
source venv/bin/activate
python app.py
```

---

**التاريخ**: 11 يناير 2025  
**الحالة**: ✅ جاهز للاستخدام  
**الإصدار**: 1.0
