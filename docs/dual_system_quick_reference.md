# Dual Accounting System - Quick Reference Guide

## 📖 Overview
The dual accounting system tracks **both cash (SAR) and weight (grams)** for every transaction. This ensures accurate inventory tracking and profit calculation for gold trading.

---

## 🔧 Core Functions

### 1. `create_dual_journal_entry()`
Creates a journal entry line with cash and weight tracking.

**Basic Usage**:
```python
from dual_system_helpers import create_dual_journal_entry

# Example 1: Debit cash only
create_dual_journal_entry(
    journal_entry_id=1,
    account_id=15,  # Cash account
    cash_debit=1000,
    description="استلام نقدي"
)

# Example 2: Credit with weight
create_dual_journal_entry(
    journal_entry_id=1,
    account_id=1203,  # Inventory 24k
    cash_credit=2000,
    weight_24k_credit=10.5,
    description="بيع ذهب عيار 24"
)

# Example 3: Mixed karat purchase
create_dual_journal_entry(
    journal_entry_id=1,
    account_id=1200,  # Inventory 18k
    cash_debit=1500,
    weight_18k_debit=5.2,
    description="شراء ذهب عيار 18"
)
```

**Parameters**:
- `journal_entry_id` (required): Parent journal entry ID
- `account_id` (required): Target account ID
- `cash_debit`: Cash debit amount (SAR)
- `cash_credit`: Cash credit amount (SAR)
- `weight_18k_debit`, `weight_18k_credit`: 18k gold weight
- `weight_21k_debit`, `weight_21k_credit`: 21k gold weight
- `weight_22k_debit`, `weight_22k_credit`: 22k gold weight
- `weight_24k_debit`, `weight_24k_credit`: 24k gold weight
- `description`: Optional text description

**What it does automatically**:
- ✅ Creates `JournalEntryLine` record
- ✅ Updates `Account.balance_cash` 
- ✅ Updates `Account.balance_18k`, `balance_21k`, `balance_22k`, `balance_24k`
- ✅ Rounds cash to 2 decimals, weight to 3 decimals
- ✅ Validates account exists

---

### 2. `verify_dual_balance()`
Checks if a journal entry balances in both cash and weight.

**Usage**:
```python
from dual_system_helpers import verify_dual_balance

# After creating all journal entry lines:
balance_check = verify_dual_balance(journal_entry_id=1)

if balance_check['balanced']:
    print("✅ Entry is balanced!")
    db.session.commit()
else:
    print("❌ Entry is NOT balanced:")
    print(f"Cash imbalance: {balance_check['cash_balance']}")
    print(f"Weight imbalances: {balance_check['weight_balances']}")
    print(f"Errors: {balance_check['errors']}")
    db.session.rollback()
```

**Returns**:
```python
{
    'balanced': True,  # or False
    'cash_balance': 0.0,  # Total debit - total credit (should be 0.0)
    'weight_balances': {
        '18k': 0.0,  # 18k debit - credit (should be 0.0)
        '21k': 0.0,
        '22k': 0.0,
        '24k': 0.0
    },
    'errors': []  # List of error messages if unbalanced
}
```

**Tolerance**:
- Cash: ±0.01 SAR (to handle rounding)
- Weight: ±0.001 grams per karat

---

### 3. `get_account_balances()`
Retrieves dual balances for an account.

**Usage**:
```python
from dual_system_helpers import get_account_balances

# Get balances for cash account (doesn't track weight)
balances = get_account_balances(account_id=15)
# Returns: {'cash': 10000.0}

# Get balances for inventory account (tracks weight)
balances = get_account_balances(account_id=1203)
# Returns:
# {
#     'cash': 50000.0,
#     'weight': {
#         '18k': 0.0,
#         '21k': 0.0,
#         '22k': 0.0,
#         '24k': 125.5,
#         'total': 125.5
#     }
# }
```

---

## 💡 Common Patterns

### Pattern 1: Sales Invoice (بيع)
```python
# Entry 1: Cash in, Sales revenue out
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=15,  # Cash
    cash_debit=5000,
    description="استلام مبلغ البيع"
)
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=55,  # Sales Revenue
    cash_credit=5000,
    description="إيرادات المبيعات"
)

# Entry 2: Cost of goods sold
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=83,  # Cost of Sales
    cash_debit=4000,
    weight_24k_debit=10.0,
    description="تكلفة المبيعات"
)
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=1203,  # Inventory 24k
    cash_credit=4000,
    weight_24k_credit=10.0,
    description="خصم من المخزون"
)

# Verify balance
balance = verify_dual_balance(je.id)
if not balance['balanced']:
    print(f"ERROR: {balance['errors']}")
```

### Pattern 2: Purchase from Customer (شراء من عميل)
```python
# Add to inventory
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=1203,  # Inventory 24k
    cash_debit=3000,
    weight_24k_debit=7.5,
    description="شراء ذهب كسر"
)

# Pay cash
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=15,  # Cash
    cash_credit=3000,
    description="دفع نقدي"
)

# Verify
balance = verify_dual_balance(je.id)
```

### Pattern 3: Sales Return (مرتجع بيع)
```python
# Return to inventory
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=1203,  # Inventory 24k
    cash_debit=4000,  # Cost value
    weight_24k_debit=10.0,
    description="مرتجع للمخزون"
)

# Sales returns expense (difference)
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=60,  # Sales Returns
    cash_debit=1000,  # 5000 - 4000
    description="مردودات المبيعات"
)

# Refund customer
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=15,  # Cash
    cash_credit=5000,
    description="استرداد للعميل"
)

balance = verify_dual_balance(je.id)
```

---

## ⚠️ Important Rules

### 1. Always Balance Both Dimensions
Every journal entry must balance in **both** cash and weight:
- Cash: Total debits = Total credits
- Weight: Total debits = Total credits (for each karat)

### 2. Only Weight-Tracking Accounts Get Weight
Not all accounts track weight. Check `account.tracks_weight` before adding weight.

**Accounts that track weight** (22 total):
- Inventory accounts (8): عيار 18, 21, 22, 24 for both جديد and كسر
- Sales accounts (5): مبيعات ذهب جديد, كسر, etc.
- Cost accounts (4): تكلفة المبيعات ذهب جديد, كسر, etc.
- Other gold accounts (5): مردودات مبيعات, مشتريات, etc.

**Accounts that DON'T track weight**:
- Cash accounts
- Customer/Supplier accounts
- Commission accounts
- VAT accounts
- Revenue accounts (unless gold-specific)

### 3. Use Correct Parameter Names
The dual system uses different parameter names than the old system:

**OLD (Direct JournalEntryLine)**:
```python
debit_24k=10.0
credit_24k=10.0
```

**NEW (Dual System)**:
```python
weight_24k_debit=10.0
weight_24k_credit=10.0
```

### 4. Always Verify Before Commit
```python
# ALWAYS do this before commit:
balance = verify_dual_balance(journal_entry_id)
if not balance['balanced']:
    db.session.rollback()
    raise ValueError(f"Unbalanced entry: {balance['errors']}")
db.session.commit()
```

---

## 🐛 Troubleshooting

### Error: "Account not found"
**Cause**: Invalid `account_id`  
**Solution**: Verify account exists in database

### Error: "Cash imbalance: 0.05"
**Cause**: Rounding issues or missing entry line  
**Solution**: Check all debits and credits sum to same total

### Error: "Weight imbalance (24k): 0.002"
**Cause**: Weight debits ≠ weight credits  
**Solution**: Ensure all gold movements are double-entry

### Account balance not updating
**Cause**: Using old `JournalEntryLine()` instead of dual system  
**Solution**: Replace with `create_dual_journal_entry()`

---

## 📊 Example: Complete Invoice Flow

```python
from models import db, JournalEntry
from dual_system_helpers import create_dual_journal_entry, verify_dual_balance

# Create journal entry
je = JournalEntry(
    date=datetime.now(),
    description="فاتورة بيع #123"
)
db.session.add(je)
db.session.flush()

# Entry 1: Debit Cash
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=15,  # Cash
    cash_debit=5000,
    description="استلام نقدي"
)

# Entry 2: Credit Sales
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=55,  # Sales Revenue
    cash_credit=5000,
    description="مبيعات ذهب"
)

# Entry 3: Debit Cost of Sales
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=83,  # Cost of Sales
    cash_debit=4000,
    weight_24k_debit=10.0,
    description="تكلفة المبيعات"
)

# Entry 4: Credit Inventory
create_dual_journal_entry(
    journal_entry_id=je.id,
    account_id=1203,  # Inventory 24k
    cash_credit=4000,
    weight_24k_credit=10.0,
    description="خصم من المخزون"
)

# Verify and commit
balance = verify_dual_balance(je.id)
if balance['balanced']:
    db.session.commit()
    print("✅ Invoice created successfully!")
else:
    db.session.rollback()
    print(f"❌ Error: {balance['errors']}")
```

---

## 📞 Need Help?

- **Documentation**: `/docs/dual_accounting_system_v2.md`
- **Implementation**: `/docs/phase3_implementation_summary.md`
- **Code**: `/backend/dual_system_helpers.py`

---

**Last Updated**: December 2024  
**Version**: 1.0
