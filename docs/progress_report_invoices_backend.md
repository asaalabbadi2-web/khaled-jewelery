# تقرير التقدم - نظام الفواتير والمرتجعات

**التاريخ:** 10 أكتوبر 2025  
**المرحلة:** Backend - قاعدة البيانات

---

## ✅ ما تم إنجازه

### 1. تحديث Models (مكتمل ✓)

#### ملف: `backend/models.py`

**الحقول الجديدة المضافة لـ Invoice:**

```python
class Invoice(db.Model):
    # ... الحقول الموجودة
    
    # 🆕 الربط بالفاتورة الأصلية (للمرتجعات)
    original_invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=True)
    
    # 🆕 سبب الإرجاع (للمرتجعات فقط)
    return_reason = db.Column(db.Text, nullable=True)
    
    # 🆕 نوع الذهب: 'new' (جديد) أو 'scrap' (كسر)
    gold_type = db.Column(db.String(20), nullable=True, server_default='new')
    
    # 🆕 العلاقة بالفاتورة الأصلية
    original_invoice = db.relationship(
        'Invoice', 
        remote_side=[id], 
        foreign_keys=[original_invoice_id], 
        backref='returns', 
        uselist=False
    )
```

**تحديث دالة `to_dict()`:**

```python
def to_dict(self):
    return {
        # ... الحقول الموجودة
        'original_invoice_id': self.original_invoice_id,  # 🆕
        'return_reason': self.return_reason,              # 🆕
        'gold_type': self.gold_type,                      # 🆕
        # ...
    }
```

---

### 2. Migration قاعدة البيانات (مكتمل ✓)

#### ملف Migration:
`backend/alembic/versions/9c5481740401_add_invoice_return_and_gold_type_fields.py`

**التغييرات:**

```sql
-- إضافة 3 أعمدة جديدة
ALTER TABLE invoice ADD COLUMN original_invoice_id INTEGER;
ALTER TABLE invoice ADD COLUMN return_reason TEXT;
ALTER TABLE invoice ADD COLUMN gold_type VARCHAR(20) DEFAULT 'new';

-- إضافة Foreign Key
ALTER TABLE invoice 
  ADD CONSTRAINT fk_invoice_original_invoice 
  FOREIGN KEY(original_invoice_id) REFERENCES invoice(id);
```

**التطبيق:**

```bash
✅ alembic upgrade head
INFO  [alembic.runtime.migration] Running upgrade 2396868be166 -> 9c5481740401
```

---

### 3. التحقق من قاعدة البيانات (مكتمل ✓)

**الأعمدة الحالية في جدول Invoice:**

| العمود | النوع | الوصف |
|--------|-------|-------|
| `id` | INTEGER | المعرف |
| `invoice_type_id` | INTEGER | رقم الفاتورة |
| `customer_id` | INTEGER | معرف العميل |
| `supplier_id` | INTEGER | معرف المورد |
| `date` | DATETIME | التاريخ |
| `total` | FLOAT | الإجمالي |
| `invoice_type` | VARCHAR(50) | نوع الفاتورة |
| `status` | VARCHAR(50) | حالة الدفع |
| **`original_invoice_id`** ⭐ | **INTEGER** | **الفاتورة الأصلية** |
| **`return_reason`** ⭐ | **TEXT** | **سبب الإرجاع** |
| **`gold_type`** ⭐ | **VARCHAR(20)** | **نوع الذهب** |
| `total_weight` | FLOAT | الوزن الكلي |
| ... | ... | باقي الحقول |

---

## 📋 أنواع الفواتير المدعومة

### القيم المسموحة لـ `invoice_type`:

| الرقم | النوع | القيمة | الوصف | القسم |
|------|-------|-------|-------|-------|
| 1 | بيع | `'بيع'` | بيع ذهب للعميل | POS |
| 2 | شراء كسر | `'شراء من عميل'` | شراء كسر من العميل | POS |
| 3 | مرتجع بيع | `'مرتجع بيع'` | العميل يرجع ذهب | POS |
| 4 | مرتجع شراء كسر | `'مرتجع شراء'` | إرجاع كسر للعميل | POS |
| 5 | شراء من مورد | `'شراء من مورد'` | شراء ذهب من المورد | Accounting |
| 6 | مرتجع شراء للمورد | `'مرتجع شراء من مورد'` | إرجاع ذهب للمورد | Accounting |

---

## 🔄 العلاقات

### المرتجعات:

```python
# فاتورة بيع أصلية
original_sale = Invoice(
    id=100,
    invoice_type='بيع',
    customer_id=1,
    total=10000,
    gold_type='new'
)

# فاتورة مرتجع بيع
return_invoice = Invoice(
    invoice_type='مرتجع بيع',
    customer_id=1,
    original_invoice_id=100,  # 👈 ربط بالفاتورة الأصلية
    return_reason='عيب في الصنعة',
    total=10000,
    gold_type='new'
)

# الوصول للفاتورة الأصلية
print(return_invoice.original_invoice.id)  # 100

# الوصول للمرتجعات من الفاتورة الأصلية
print(original_sale.returns)  # [<Invoice مرتجع بيع>]
```

---

## 📊 إحصائيات

### التغييرات:

- **Models محدثة:** 1 (Invoice)
- **حقول جديدة:** 3 (original_invoice_id, return_reason, gold_type)
- **Migrations منفذة:** 1
- **Foreign Keys جديدة:** 1
- **أنواع فواتير مدعومة:** 6

---

## 🎯 الخطوات التالية

### المرحلة القادمة: تحديث API Endpoints

#### 1. تحديث `routes.py`:

```python
@app.route('/api/invoices', methods=['POST'])
def create_invoice():
    data = request.json
    
    # 🆕 Validation للمرتجعات
    if data['invoice_type'] in ['مرتجع بيع', 'مرتجع شراء', 'مرتجع شراء من مورد']:
        if not data.get('original_invoice_id'):
            return jsonify({'error': 'original_invoice_id required for returns'}), 400
        
        # التحقق من وجود الفاتورة الأصلية
        original = Invoice.query.get(data['original_invoice_id'])
        if not original:
            return jsonify({'error': 'Original invoice not found'}), 404
    
    # إنشاء الفاتورة
    invoice = Invoice(**data)
    db.session.add(invoice)
    db.session.commit()
    
    return jsonify(invoice.to_dict()), 201
```

#### 2. إضافة Endpoint لجلب الفاتورة الأصلية:

```python
@app.route('/api/invoices/<int:id>/returns', methods=['GET'])
def get_invoice_returns(id):
    """Get all returns for an invoice"""
    invoice = Invoice.query.get_or_404(id)
    returns = [r.to_dict() for r in invoice.returns]
    return jsonify(returns)
```

#### 3. Validation Rules:

- **للمرتجعات:** يجب وجود `original_invoice_id`
- **نوع الذهب:** `gold_type` يجب أن يكون `'new'` أو `'scrap'`
- **العميل/المورد:** يجب أن يتطابق مع الفاتورة الأصلية

---

## 📝 ملاحظات مهمة

### 1. **الحذف الآمن:**
- النظام يدعم soft delete للقيود اليومية
- يجب تطبيق نفس المنطق للفواتير والمرتجعات

### 2. **القيود المحاسبية:**
- كل نوع فاتورة يجب أن ينشئ قيد محاسبي مناسب
- المرتجعات تنشئ قيود عكسية

### 3. **الأرصدة:**
- تحديث أرصدة العملاء/الموردين تلقائياً
- تحديث المخزون عند البيع والشراء والمرتجعات

---

## ✅ الخلاصة

**تم بنجاح:**
- ✅ تحديث Invoice Model بـ 3 حقول جديدة
- ✅ إنشاء وتطبيق Migration
- ✅ إضافة علاقة Foreign Key للفاتورة الأصلية
- ✅ تحديث `to_dict()` لتشمل الحقول الجديدة
- ✅ التحقق من قاعدة البيانات

**جاهز للانتقال إلى:**
- 🔜 تحديث API Endpoints
- 🔜 إضافة Validation للمرتجعات
- 🔜 القيود المحاسبية لكل نوع فاتورة

---

**الحالة:** 🟢 Backend - قاعدة البيانات جاهزة 100%
