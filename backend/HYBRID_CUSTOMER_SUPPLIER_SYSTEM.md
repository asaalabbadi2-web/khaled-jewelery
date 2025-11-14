# نظام العملاء والموردين الهجين
# Hybrid Customer & Supplier System

## نظرة عامة | Overview

This document describes the **Hybrid Customer & Supplier System** implemented in the Yasar Gold POS system. This architecture supports thousands of customers and suppliers efficiently without bloating the chart of accounts.

هذا المستند يصف **النظام الهجين للعملاء والموردين** في نظام ياسر للذهب والمجوهرات. يدعم هذا التصميم آلاف العملاء والموردين بكفاءة دون زيادة عدد الحسابات في دليل الحسابات.

---

## الفكرة الأساسية | Core Concept

### Traditional System (القديم)
- Each customer/supplier gets individual Account record
- Chart of Accounts grows with every new customer: `1100.1`, `1100.2`, `1100.3`...
- **Problem**: 10,000 customers = 10,000 account records
- Performance degradation with large account trees

### Hybrid System (الجديد - المطبق)
- Customers/suppliers stored in separate tables with **unique codes**
- Link to **aggregate accounts** in chart of accounts
- Journal entries reference both aggregate account AND specific customer/supplier
- Balances stored directly in customer/supplier records

**Customer Codes**: `C-000001`, `C-000002`, `C-000003`... (capacity: 999,999)  
**Supplier Codes**: `S-000001`, `S-000002`, `S-000003`... (capacity: 999,999)

---

## الهيكل المعماري | Architecture

### 1. Aggregate Accounts (حسابات تجميعية)

In the Chart of Accounts, we have aggregate accounts instead of individual customer/supplier accounts:

```
110  - الحسابات المدينة (Receivables)
1100 - عملاء بيع ذهب (Gold Sale Customers)
1110 - عملاء شراء ذهب (Gold Purchase Customers)  
1120 - عملاء صيانة (Maintenance Customers)

21   - الخصوم المتداولة (Current Liabilities)
211  - الموردين (Suppliers)
```

### 2. Customer Table Fields

```python
class Customer(db.Model):
    id = Column(Integer, primary_key=True)
    customer_code = Column(String(10), unique=True, nullable=False, index=True)  # C-000001
    name = Column(String(200), nullable=False)
    
    # Link to aggregate account (1100, 1110, or 1120)
    account_category_id = Column(Integer, ForeignKey('account.id'))
    account_category = relationship('Account', foreign_keys=[account_category_id])
    
    # Balance fields (for quick lookups)
    balance_cash = Column(Float, default=0.0)
    balance_gold_18k = Column(Float, default=0.0)
    balance_gold_21k = Column(Float, default=0.0)
    balance_gold_22k = Column(Float, default=0.0)
    balance_gold_24k = Column(Float, default=0.0)
    
    # Backward compatibility (optional)
    account_id = Column(Integer, ForeignKey('account.id'))  # Old individual account
```

### 3. Supplier Table Fields

```python
class Supplier(db.Model):
    id = Column(Integer, primary_key=True)
    supplier_code = Column(String(10), unique=True, nullable=False, index=True)  # S-000001
    name = Column(String(200), nullable=False)
    
    # Link to aggregate account (211)
    account_category_id = Column(Integer, ForeignKey('account.id'))
    account_category = relationship('Account', foreign_keys=[account_category_id])
    
    # Balance fields
    balance_cash = Column(Float, default=0.0)
    balance_gold_18k = Column(Float, default=0.0)
    balance_gold_21k = Column(Float, default=0.0)
    balance_gold_22k = Column(Float, default=0.0)
    balance_gold_24k = Column(Float, default=0.0)
```

### 4. Journal Entry Line Links

```python
class JournalEntryLine(db.Model):
    id = Column(Integer, primary_key=True)
    journal_entry_id = Column(Integer, ForeignKey('journal_entry.id'))
    
    # Link to aggregate account (1100, 211, etc.)
    account_id = Column(Integer, ForeignKey('account.id'))
    
    # Link to specific customer OR supplier
    customer_id = Column(Integer, ForeignKey('customer.id'))
    supplier_id = Column(Integer, ForeignKey('supplier.id'))
    
    # Debit/Credit amounts...
```

---

## استخدام النظام | Usage

### Adding a Customer

**POST /api/customers**

```json
{
  "name": "أحمد محمد",
  "phone": "0501234567",
  "account_category_number": "1100"  // Optional, defaults to 1100
}
```

**Response**:
```json
{
  "id": 15,
  "customer_code": "C-000015",
  "name": "أحمد محمد",
  "account_category_id": 42,
  "balance_cash": 0.0,
  "balance_gold_21k": 0.0
}
```

**What happens internally**:
1. ✅ Generate unique `customer_code` (C-000015)
2. ✅ Link to aggregate account 1100 ("عملاء بيع ذهب")
3. ❌ NO individual account created
4. ✅ Initialize all balances to 0.0

### Adding a Supplier

**POST /api/suppliers**

```json
{
  "name": "شركة الذهب للاستيراد",
  "phone": "0509876543",
  "account_category_number": "211"  // Optional, defaults to 211
}
```

**Response**:
```json
{
  "id": 8,
  "supplier_code": "S-000008",
  "name": "شركة الذهب للاستيراد",
  "account_category_id": 29,
  "balance_cash": 0.0
}
```

### Creating Journal Entry with Customer

**POST /api/journal-entries**

```json
{
  "date": "2025-01-10",
  "description": "بيع ذهب عيار 21 - فاتورة #123",
  "lines": [
    {
      "account_id": 42,           // Account 1100 (عملاء بيع ذهب)
      "customer_id": 15,           // Link to customer C-000015
      "debit_cash": 5000.0,
      "credit_cash": 0.0
    },
    {
      "account_id": 67,           // Account 4000 (إيرادات المبيعات)
      "debit_cash": 0.0,
      "credit_cash": 5000.0
    }
  ]
}
```

**Important Notes**:
- ✅ Journal entry line includes BOTH `account_id` (aggregate) AND `customer_id` (specific)
- ✅ Balance fields in customer record updated automatically (via trigger/application logic)
- ✅ Financial reports use aggregate accounts (1100)
- ✅ Customer statements use `customer_id` filter

### Getting Customer Statement

**GET /api/customers/15/statement**

**Response**:
```json
{
  "customer": {
    "id": 15,
    "customer_code": "C-000015",
    "name": "أحمد محمد",
    "balance_cash": 5000.0,
    "balance_gold_21k": 12.5
  },
  "statement": [
    {
      "id": 342,
      "date": "2025-01-10",
      "entry_number": "JE-2025-0042",
      "description": "بيع ذهب عيار 21 - فاتورة #123",
      "account_number": "1100",
      "account_name": "عملاء بيع ذهب",
      "debit_cash": 5000.0,
      "credit_cash": 0.0,
      "debit_gold_21k": 12.5,
      "credit_gold_21k": 0.0
    }
  ]
}
```

### Getting Next Available Code

**GET /api/customers/next-code**

**Response**:
```json
{
  "next_code": "C-000016",
  "total_customers": 15,
  "remaining_capacity": 999984
}
```

**GET /api/suppliers/next-code**

**Response**:
```json
{
  "next_code": "S-000009",
  "total_suppliers": 8,
  "remaining_capacity": 999991
}
```

---

## المزايا | Advantages

### ✅ Scalability (قابلية التوسع)
- Support 999,999 customers without chart of accounts bloat
- Account tree remains clean and manageable
- Fast queries on customer/supplier tables

### ✅ Performance (الأداء)
- Direct balance lookups from customer/supplier records
- No need to traverse account tree for customer lists
- Indexed customer_code/supplier_code for fast searches

### ✅ Accounting Integrity (سلامة المحاسبة)
- Aggregate accounts maintain double-entry bookkeeping
- Financial statements show totals (عملاء = 1100)
- Customer statements show individual transactions

### ✅ Flexibility (المرونة)
- Can assign customers to different categories (1100, 1110, 1120)
- Can change account_category if customer type changes
- Backward compatible with old account_id field

---

## كود المولدات | Code Generators

The `code_generator.py` module provides:

```python
from code_generator import (
    generate_customer_code,      # Returns "C-000001", "C-000002"...
    generate_supplier_code,       # Returns "S-000001", "S-000002"...
    validate_customer_code,       # Checks format and uniqueness
    validate_supplier_code,
    get_customer_statistics,      # Returns counts and capacity
    get_supplier_statistics
)
```

**Format Rules**:
- Customer: `C-XXXXXX` (6 digits, zero-padded)
- Supplier: `S-XXXXXX` (6 digits, zero-padded)
- Unique, sequential, indexed for fast lookups

---

## الترحيل من النظام القديم | Migration from Old System

If you have existing customers/suppliers with individual accounts:

1. **Migration script** (`alembic/versions/6b85df6f61db_add_hybrid_customer_supplier_system.py`):
   - Adds new columns to customer/supplier tables
   - Generates codes for existing records (C-000001, C-000002...)
   - Preserves old `account_id` for backward compatibility
   - Adds `customer_id`/`supplier_id` to journal_entry_line

2. **Run migration**:
   ```bash
   cd backend
   source venv/bin/activate
   alembic upgrade head
   ```

3. **Verify**:
   ```bash
   sqlite3 app.db "SELECT id, customer_code, name FROM customer LIMIT 10;"
   ```

---

## الأسئلة الشائعة | FAQ

### Q: What happens to existing individual customer accounts?
**A**: They remain in the database (`account_id` field preserved). New customers use the hybrid system. You can optionally migrate old journal entries to link to aggregate accounts.

### Q: Can I still use account numbers for customers?
**A**: No. Customer codes (C-XXXXXX) are the new primary identifier. Account numbers (1100, 1110, etc.) refer to aggregate categories.

### Q: How do financial reports work?
**A**: Reports aggregate by account number (1100 = all gold sale customers). Use customer statements for individual details.

### Q: What if I need more than 999,999 customers?
**A**: Adjust the code format in `code_generator.py` to use more digits (C-XXXXXXX for 7 digits = 9,999,999 capacity).

### Q: Can a customer be in multiple categories?
**A**: No. Each customer has one `account_category_id`. But you can change it if the customer type changes.

---

## الملفات ذات الصلة | Related Files

- **Models**: `backend/models.py` (Customer, Supplier, JournalEntryLine)
- **Routes**: `backend/routes.py` (Customer/Supplier APIs)
- **Code Generator**: `backend/code_generator.py`
- **Migration**: `backend/alembic/versions/6b85df6f61db_add_hybrid_customer_supplier_system.py`
- **Chart of Accounts**: `backend/seed_accounts.py` (defines aggregate accounts)

---

## المراجع | References

- [CHART_OF_ACCOUNTS.md](./CHART_OF_ACCOUNTS.md) - Spaced Block Numbering System
- [CUSTOMER_NUMBERING_GUIDE.md](./CUSTOMER_NUMBERING_GUIDE.md) - Original design discussion
- [NUMBERING_SYSTEM_SUMMARY.md](./NUMBERING_SYSTEM_SUMMARY.md) - Complete numbering overview

---

**تم التطبيق بنجاح** ✅  
**Successfully Implemented** ✅
