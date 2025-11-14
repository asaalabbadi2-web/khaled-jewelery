# إصلاح مشكلة طرق الدفع - Backend Endpoints

## المشكلة:
**لم تكن هناك endpoints للـ CRUD على طرق الدفع!**

عندما كان Frontend يحاول:
- **تعديل** طريقة دفع: يرسل `PUT /api/payment-methods/:id` → **404 Not Found**
- **حذف** طريقة دفع: يرسل `DELETE /api/payment-methods/:id` → **404 Not Found**

## الحل:
تم إضافة 6 endpoints جديدة في `backend/routes.py`:

### 1. GET /api/payment-methods
- الحصول على **جميع** طرق الدفع
- مُرتبة حسب `display_order`

### 2. GET /api/payment-methods/active  
- الحصول على طرق الدفع **النشطة** فقط
- مُستخدمة في الفواتير

### 3. POST /api/payment-methods
- **إضافة** وسيلة دفع جديدة
- يتحقق من وجود الحساب البنكي
- Body:
```json
{
  "payment_type": "mada",
  "name": "مدى - بنك الراجحي",
  "parent_account_id": 123,
  "commission_rate": 2.5,
  "is_active": true
}
```

### 4. PUT /api/payment-methods/:id
- **تعديل** وسيلة دفع موجودة
- يمكن تعديل: النوع، الاسم، العمولة، الحالة، الترتيب
- Body:
```json
{
  "name": "فيزا - البنك الأهلي",
  "commission_rate": 3.0,
  "is_active": false
}
```

### 5. DELETE /api/payment-methods/:id
- **حذف** وسيلة دفع
- ✅ يتحقق: هل مستخدمة في فواتير؟
- ❌ إذا مستخدمة → يرفض الحذف مع رسالة واضحة

### 6. PUT /api/payment-methods/update-order
- **تحديث ترتيب** طرق الدفع (drag & drop)
- Body:
```json
{
  "methods": [
    {"id": 1, "display_order": 0},
    {"id": 2, "display_order": 1}
  ]
}
```

## الملفات المعدلة:
- `backend/routes.py` (الأسطر 4450-4591)

## كيفية تشغيل Backend:
```bash
cd /Users/salehalabbadi/yasargold/backend
python3 app.py
```

## الاختبار:
1. تأكد Backend يعمل على `http://localhost:8001`
2. افتح Frontend
3. جرّب:
   - ✅ إضافة طريقة دفع جديدة
   - ✅ تعديل طريقة دفع موجودة
   - ✅ حذف طريقة دفع غير مستخدمة
   - ❌ محاولة حذف طريقة دفع مستخدمة في فاتورة → ترفض

---

## شرح المشكلة الأصلية:

### لماذا الجديدة لا تقبل التعديل والقديمة لا تقبل الحذف؟

**الجواب:** لأنه **لا توجد endpoints أصلاً!**

- عندما تضغط "تعديل" على طريقة دفع **جديدة**:
  - Frontend يرسل: `PUT /api/payment-methods/5`
  - Backend يرد: **404 Not Found** (لا يوجد endpoint)
  - تظهر شاشة خطأ

- عندما تضغط "حذف" على طريقة دفع **قديمة**:
  - Frontend يرسل: `DELETE /api/payment-methods/1`
  - Backend يرد: **404 Not Found** (لا يوجد endpoint)
  - لا يحدث شيء

**الآن تم إصلاح المشكلة بإضافة جميع الـ endpoints المطلوبة!** ✅
