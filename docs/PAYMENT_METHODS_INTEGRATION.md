# 💳 ربط وسائل الدفع بالفواتير والقيود المحاسبية

**تاريخ التحديث:** 14 أكتوبر 2025  
**الحالة:** ✅ مكتمل (Backend) | 🔄 جارٍ (Frontend)

---

## 📋 نظرة عامة

تم ربط نظام وسائل الدفع مع الفواتير والقيود المحاسبية لتحقيق:
1. **حساب العمولات تلقائياً** من نسبة العمولة المحددة لكل وسيلة
2. **إنشاء قيود محاسبية تلقائية** تشمل قيود العمولات
3. **استخدام الحساب المرتبط** بوسيلة الدفع في القيود بدلاً من الصندوق العام

---

## 🗄️ التغييرات في قاعدة البيانات

### **جدول `Invoice`**

#### **الحقول الجديدة:**

```python
class Invoice(db.Model):
    # ... الحقول الموجودة
    
    # 🆕 ربط بوسيلة الدفع (Foreign Key)
    payment_method_id = db.Column(db.Integer, db.ForeignKey('payment_method.id'), nullable=True)
    payment_method_obj = db.relationship('PaymentMethod', backref='invoices')
    
    # الاحتفاظ بالحقل القديم للتوافق
    payment_method = db.Column(db.String(50))
    
    # 🆕 العمولة المحسوبة
    commission_amount = db.Column(db.Float, default=0.0)
    net_amount = db.Column(db.Float)  # المبلغ الصافي بعد خصم العمولة
```

#### **مثال على البيانات:**

```json
{
  "id": 123,
  "total": 1000.0,
  "payment_method_id": 5,
  "payment_method": "تابي",  // للتوافق مع الفواتير القديمة
  "commission_amount": 40.0,  // 4% عمولة
  "net_amount": 960.0,  // المبلغ المستلم فعلياً
  "payment_method_details": {
    "id": 5,
    "name": "تابي (Tabby)",
    "commission_rate": 4.0,
    "settlement_days": 7,
    "account": {
      "id": 91,
      "account_number": "1116",
      "name": "تمارا - مستحقات قصيرة الأجل"
    }
  }
}
```

---

## 🔌 API Changes

### **1. POST `/api/invoices`**

#### **الحقول الجديدة المقبولة:**

```json
{
  "date": "2025-10-14",
  "total": 1000.0,
  "payment_method_id": 5,  // 🆕 ID وسيلة الدفع (اختياري)
  "customer_id": 10,
  "items": [...]
}
```

#### **السلوك:**

1. **إذا تم إرسال `payment_method_id`:**
   - يتحقق من وجود الوسيلة وأنها نشطة
   - يحسب العمولة تلقائياً: `commission = total * (commission_rate / 100)`
   - يحسب المبلغ الصافي: `net_amount = total - commission`
   - يحفظ القيم في الفاتورة

2. **إذا لم يتم إرسال `payment_method_id`:**
   - يعمل كما هو (توافق مع الفواتير القديمة)
   - `commission_amount = 0.0`
   - `net_amount = total`

#### **مثال كامل للطلب:**

```bash
curl -X POST http://127.0.0.1:8001/api/invoices \
  -H "Content-Type: application/json" \
  -d '{
    "date": "2025-10-14T10:30:00",
    "total": 2000.0,
    "invoice_type": "بيع",
    "payment_method_id": 5,
    "customer_id": 10,
    "items": [
      {
        "item_id": 1,
        "name": "خاتم ذهب",
        "karat": 21,
        "weight": 10.5,
        "wage": 50.0,
        "net": 1900.0,
        "tax": 0.0,
        "price": 2000.0,
        "quantity": 1
      }
    ]
  }'
```

#### **الاستجابة:**

```json
{
  "invoice": {
    "id": 124,
    "total": 2000.0,
    "payment_method_id": 5,
    "commission_amount": 80.0,
    "net_amount": 1920.0,
    "payment_method_details": {
      "name": "تابي (Tabby)",
      "commission_rate": 4.0,
      "settlement_days": 7
    }
  },
  "journal_entry": {
    "id": 456,
    "description": "بيع #124"
  }
}
```

---

### **2. GET `/api/payment-methods`**

#### **Query Parameters الجديدة:**

- `active_only=true` (افتراضي): جلب الوسائل النشطة فقط
- `active_only=false`: جلب جميع الوسائل (نشطة ومعطلة)

#### **مثال:**

```bash
# جلب الوسائل النشطة فقط (للاستخدام في الفواتير)
curl http://127.0.0.1:8001/api/payment-methods

# جلب جميع الوسائل (للإدارة)
curl http://127.0.0.1:8001/api/payment-methods?active_only=false
```

---

## 📊 القيود المحاسبية التلقائية

### **السيناريو 1: فاتورة بيع بدون عمولة**

```
الفاتورة:
- الإجمالي: 1000 ريال
- وسيلة الدفع: نقداً (عمولة: 0%)

القيد المحاسبي:
-----------------------------------------
من حـ/  1111 - الصندوق           1000 ريال (مدين)
    إلى حـ/ 1300 - المخزون         800 ريال (دائن)
    إلى حـ/ 4100 - الإيرادات        200 ريال (دائن)
```

---

### **السيناريو 2: فاتورة بيع بعمولة (مدى)**

```
الفاتورة:
- الإجمالي: 1000 ريال
- وسيلة الدفع: مدى (عمولة: 2.5%)
- العمولة المحسوبة: 25 ريال
- صافي المبلغ: 975 ريال

القيد المحاسبي:
-----------------------------------------
من حـ/  1112.1 - بنك الراجحي (مدى)     975 ريال (مدين)
من حـ/  5200 - مصروف العمولات           25 ريال (مدين)
    إلى حـ/ 1300 - المخزون              800 ريال (دائن)
    إلى حـ/ 4100 - الإيرادات             200 ريال (دائن)
```

**شرح القيد:**
1. **مدين البنك (975)**: المبلغ الذي سيصل فعلياً لحسابك البنكي
2. **مدين مصروف العمولات (25)**: العمولة التي خصمها البنك
3. **دائن المخزون (800)**: تكلفة البضاعة المباعة
4. **دائن الإيرادات (200)**: الربح من البيع

---

### **السيناريو 3: فاتورة بيع بعمولة عالية (تابي)**

```
الفاتورة:
- الإجمالي: 5000 ريال
- وسيلة الدفع: تابي (عمولة: 4%)
- العمولة المحسوبة: 200 ريال
- صافي المبلغ: 4800 ريال
- أيام الاستلام: 7 أيام

القيد المحاسبي:
-----------------------------------------
من حـ/  1116 - تمارا (مستحقات قصيرة)   4800 ريال (مدين)
من حـ/  5200 - مصروف العمولات           200 ريال (مدين)
    إلى حـ/ 1300 - المخزون             4000 ريال (دائن)
    إلى حـ/ 4100 - الإيرادات            1000 ريال (دائن)

ملاحظة: المبلغ سيُستلم بعد 7 أيام
```

---

## 🧮 حساب العمولات - أمثلة عملية

### **مثال 1: بطاقة مدى**

```python
total = 1000.0
commission_rate = 2.5  # %
commission_amount = 1000 * (2.5 / 100) = 25.0
net_amount = 1000 - 25 = 975.0
```

### **مثال 2: تابي**

```python
total = 5000.0
commission_rate = 4.0  # %
commission_amount = 5000 * (4.0 / 100) = 200.0
net_amount = 5000 - 200 = 4800.0
```

### **مثال 3: نقداً (بدون عمولة)**

```python
total = 1000.0
commission_rate = 0.0  # %
commission_amount = 1000 * (0.0 / 100) = 0.0
net_amount = 1000 - 0 = 1000.0
```

---

## 🔍 منطق الكود

### **في `routes.py` - دالة `add_invoice()`**

```python
# 1. جلب وسيلة الدفع والتحقق منها
payment_method_id = data.get('payment_method_id')
commission_amount = 0.0
net_amount = data['total']

if payment_method_id:
    payment_method_obj = PaymentMethod.query.get(payment_method_id)
    if not payment_method_obj:
        return jsonify({'error': 'Payment method not found'}), 404
    
    if not payment_method_obj.is_active:
        return jsonify({'error': 'Payment method is not active'}), 400
    
    # 2. حساب العمولة
    if payment_method_obj.commission_rate > 0:
        commission_amount = data['total'] * (payment_method_obj.commission_rate / 100)
        net_amount = data['total'] - commission_amount

# 3. إنشاء الفاتورة مع القيم المحسوبة
new_invoice = Invoice(
    total=data['total'],
    payment_method_id=payment_method_id,
    commission_amount=commission_amount,
    net_amount=net_amount,
    # ... باقي الحقول
)

# 4. إنشاء القيود المحاسبية
if payment_method_id and payment_method_obj.account:
    # استخدام الحساب المرتبط بوسيلة الدفع
    db.session.add(JournalEntryLine(
        journal_entry_id=journal_entry.id,
        account_id=payment_method_obj.account.id,  # ← الحساب البنكي
        cash_debit=net_amount,  # ← المبلغ الصافي
        description=f'استلام عبر {payment_method_obj.name}'
    ))
    
    # إضافة قيد العمولة
    if commission_amount > 0:
        commission_account = Account.query.filter_by(account_number='5200').first()
        db.session.add(JournalEntryLine(
            journal_entry_id=journal_entry.id,
            account_id=commission_account.id,
            cash_debit=commission_amount,
            description=f'عمولة {payment_method_obj.name} ({payment_method_obj.commission_rate}%)'
        ))
```

---

## 📱 Frontend Integration (التالي)

### **الخطوات المطلوبة:**

1. **استبدال TextField بـ Dropdown في شاشة الفواتير**
   ```dart
   DropdownButtonFormField<int>(
     items: paymentMethods.map((method) {
       return DropdownMenuItem(
         value: method['id'],
         child: Row(
           children: [
             Text(method['name']),
             if (method['commission'] > 0)
               Text(' (عمولة: ${method['commission']}%)',
                 style: TextStyle(color: Colors.orange)),
           ],
         ),
       );
     }).toList(),
     onChanged: (value) {
       setState(() {
         selectedPaymentMethodId = value;
         _calculateCommission();
       });
     },
   )
   ```

2. **عرض ملخص العمولة قبل الحفظ**
   ```dart
   if (selectedCommission > 0)
     Card(
       color: Colors.orange.shade50,
       child: Padding(
         padding: EdgeInsets.all(12),
         child: Column(
           children: [
             Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
               children: [
                 Text('الإجمالي:', style: TextStyle(fontSize: 16)),
                 Text('$total ريال', style: TextStyle(fontSize: 16)),
               ],
             ),
             Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
               children: [
                 Text('العمولة ($commissionRate%):',
                   style: TextStyle(color: Colors.red)),
                 Text('- $commissionAmount ريال',
                   style: TextStyle(color: Colors.red)),
               ],
             ),
             Divider(),
             Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
               children: [
                 Text('صافي المبلغ:',
                   style: TextStyle(fontWeight: FontWeight.bold)),
                 Text('$netAmount ريال',
                   style: TextStyle(fontWeight: FontWeight.bold,
                     color: Colors.green)),
               ],
             ),
             SizedBox(height: 8),
             Text('سيتم استلام المبلغ خلال $settlementDays يوم',
               style: TextStyle(fontSize: 12, color: Colors.grey)),
           ],
         ),
       ),
     )
   ```

3. **تحديث API call**
   ```dart
   final response = await _apiService.createInvoice({
     'date': selectedDate.toIso8601String(),
     'total': totalAmount,
     'payment_method_id': selectedPaymentMethodId,  // ← جديد
     'customer_id': selectedCustomerId,
     'items': items,
   });
   ```

---

## 📊 تقارير وسائل الدفع (مستقبلاً)

### **تقرير مقترح:**

```sql
SELECT 
  pm.name AS payment_method,
  COUNT(i.id) AS invoice_count,
  SUM(i.total) AS total_sales,
  SUM(i.commission_amount) AS total_commission,
  SUM(i.net_amount) AS net_received,
  AVG(pm.settlement_days) AS avg_settlement_days
FROM invoices i
JOIN payment_method pm ON i.payment_method_id = pm.id
WHERE i.date BETWEEN '2025-10-01' AND '2025-10-31'
GROUP BY pm.id
ORDER BY total_sales DESC
```

### **النتيجة المتوقعة:**

```
+------------------+---------------+-------------+------------------+--------------+---------------------+
| payment_method   | invoice_count | total_sales | total_commission | net_received | avg_settlement_days |
+------------------+---------------+-------------+------------------+--------------+---------------------+
| نقداً            |           150 |    75,000.0 |              0.0 |     75,000.0 |                 0.0 |
| مدى              |            80 |    40,000.0 |          1,000.0 |     39,000.0 |                 2.0 |
| تابي             |            30 |    15,000.0 |            600.0 |     14,400.0 |                 7.0 |
| تمارا            |            20 |    10,000.0 |            400.0 |      9,600.0 |                 7.0 |
+------------------+---------------+-------------+------------------+--------------+---------------------+
```

---

## ✅ الفوائد المحققة

### **1. محاسبياً:**
- ✅ قيود دقيقة تلقائياً
- ✅ فصل واضح للعمولات (حساب 5200)
- ✅ استخدام الحساب المرتبط بوسيلة الدفع

### **2. تشغيلياً:**
- ✅ لا داعي لحساب العمولة يدوياً
- ✅ معرفة تاريخ استلام المبلغ (settlement_days)
- ✅ تقارير دقيقة عن العمولات المدفوعة

### **3. تحليلياً:**
- ✅ إمكانية مقارنة تكلفة وسائل الدفع
- ✅ معرفة الوسيلة الأكثر استخداماً
- ✅ حساب هامش الربح الحقيقي بعد العمولات

---

## 🚨 ملاحظات هامة

### **1. التوافق مع الفواتير القديمة**
- الحقل القديم `payment_method` (String) محفوظ
- الفواتير القديمة ستعمل بدون مشاكل
- الفواتير الجديدة تستخدم `payment_method_id` فقط

### **2. حساب مصروف العمولات (5200)**
- يتم إنشاؤه تلقائياً إذا لم يكن موجوداً
- يمكن تعديل رقم الحساب حسب الدليل المحاسبي

### **3. Validation**
- لا يمكن استخدام وسيلة دفع معطلة (`is_active=False`)
- لا يمكن استخدام وسيلة دفع محذوفة
- يجب أن يكون للوسيلة حساب مرتبط لإنشاء القيود

---

## 🧪 اختبار الميزة

### **Test Case 1: فاتورة بدون عمولة**

```bash
curl -X POST http://127.0.0.1:8001/api/invoices \
  -H "Content-Type: application/json" \
  -d '{
    "date": "2025-10-14T10:00:00",
    "total": 1000.0,
    "invoice_type": "بيع",
    "payment_method_id": 1,
    "customer_id": 10,
    "items": [...]
  }'
```

**النتيجة المتوقعة:**
- `commission_amount = 0.0`
- `net_amount = 1000.0`
- قيد واحد: مدين الصندوق 1000 ريال

---

### **Test Case 2: فاتورة بعمولة 2.5%**

```bash
curl -X POST http://127.0.0.1:8001/api/invoices \
  -H "Content-Type: application/json" \
  -d '{
    "date": "2025-10-14T10:00:00",
    "total": 1000.0,
    "invoice_type": "بيع",
    "payment_method_id": 2,
    "customer_id": 10,
    "items": [...]
  }'
```

**النتيجة المتوقعة:**
- `commission_amount = 25.0`
- `net_amount = 975.0`
- قيدان: مدين البنك 975 ريال + مدين مصروف العمولات 25 ريال

---

### **Test Case 3: وسيلة دفع معطلة**

```bash
curl -X POST http://127.0.0.1:8001/api/invoices \
  -H "Content-Type: application/json" \
  -d '{
    "payment_method_id": 99  # معطّلة
  }'
```

**النتيجة المتوقعة:**
```json
{
  "error": "Payment method is not active",
  "status": 400
}
```

---

## 📚 مراجع إضافية

- [نموذج PaymentMethod](../backend/models.py#L776)
- [نموذج Invoice](../backend/models.py#L234)
- [API Routes](../backend/routes.py#L851)
- [شاشة الإعدادات](../frontend/lib/screens/settings_screen.dart)

---

**🎉 تم إنجاز Backend بنجاح! التالي: Frontend Integration**
