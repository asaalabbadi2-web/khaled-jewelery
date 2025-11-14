"""
Dual accounting system helpers (cash + weight)
Note: These functions must be called from within a Flask app context
"""


def create_dual_journal_entry(journal_entry_id, account_id, cash_debit=0, cash_credit=0, 
                               weight_18k_debit=0, weight_18k_credit=0,
                               weight_21k_debit=0, weight_21k_credit=0,
                               weight_22k_debit=0, weight_22k_credit=0,
                               weight_24k_debit=0, weight_24k_credit=0,
                               description=None, customer_id=None, supplier_id=None):
    """
    Create dual journal entry with cash and weight.
    Must be called from routes.py where db is already in context.
    
    Args:
        customer_id: معرف العميل (اختياري)
        supplier_id: معرف المورد (اختياري)
    """
    # Get db from current Flask app extensions
    from flask import current_app
    from models import JournalEntryLine, Account
    
    db = current_app.extensions['sqlalchemy']
    
    # Create the journal entry line (description is ignored - not in model)
    line = JournalEntryLine(
        journal_entry_id=journal_entry_id,
        account_id=account_id,
        customer_id=customer_id,  # 🆕 ربط بالعميل
        supplier_id=supplier_id   # 🆕 ربط بالمورد
    )
    
    # Set cash amounts
    if cash_debit > 0:
        line.cash_debit = round(cash_debit, 2)
    if cash_credit > 0:
        line.cash_credit = round(cash_credit, 2)
    
    # Set weight amounts (only if weight parameters provided)
    if weight_18k_debit > 0:
        line.debit_18k = round(weight_18k_debit, 3)
    if weight_18k_credit > 0:
        line.credit_18k = round(weight_18k_credit, 3)
        
    if weight_21k_debit > 0:
        line.debit_21k = round(weight_21k_debit, 3)
    if weight_21k_credit > 0:
        line.credit_21k = round(weight_21k_credit, 3)
        
    if weight_22k_debit > 0:
        line.debit_22k = round(weight_22k_debit, 3)
    if weight_22k_credit > 0:
        line.credit_22k = round(weight_22k_credit, 3)
        
    if weight_24k_debit > 0:
        line.debit_24k = round(weight_24k_debit, 3)
    if weight_24k_credit > 0:
        line.credit_24k = round(weight_24k_credit, 3)
    
    db.session.add(line)
    
    # Update account balance
    try:
        account = db.session.query(Account).filter_by(id=account_id).first()
        if account and hasattr(account, 'update_balance'):
            account.update_balance(
                cash_amount=(cash_debit - cash_credit),
                weight_18k=(weight_18k_debit - weight_18k_credit),
                weight_21k=(weight_21k_debit - weight_21k_credit),
                weight_22k=(weight_22k_debit - weight_22k_credit),
                weight_24k=(weight_24k_debit - weight_24k_credit)
            )
    except Exception as e:
        # If account update fails, log it but don't fail the entry creation
        print(f"Warning: Could not update account balance for account {account_id}: {e}")
    
    # 🆕 Update supplier/customer balance in their own table
    try:
        if supplier_id:
            from models import Supplier
            supplier = db.session.query(Supplier).filter_by(id=supplier_id).first()
            if supplier:
                print(f"🔍 Updating supplier {supplier_id} balance:")
                print(f"   Before: cash={supplier.balance_cash}, 18k={supplier.balance_gold_18k}, 21k={supplier.balance_gold_21k}")
                supplier.balance_cash += (cash_debit - cash_credit)
                supplier.balance_gold_18k += (weight_18k_debit - weight_18k_credit)
                supplier.balance_gold_21k += (weight_21k_debit - weight_21k_credit)
                supplier.balance_gold_22k += (weight_22k_debit - weight_22k_credit)
                supplier.balance_gold_24k += (weight_24k_debit - weight_24k_credit)
                print(f"   After: cash={supplier.balance_cash}, 18k={supplier.balance_gold_18k}, 21k={supplier.balance_gold_21k}")
            else:
                print(f"⚠️ Supplier {supplier_id} not found!")
        
        if customer_id:
            from models import Customer
            customer = db.session.query(Customer).filter_by(id=customer_id).first()
            if customer:
                print(f"🔍 Updating customer {customer_id} balance:")
                print(f"   Before: cash={customer.balance_cash}, 18k={customer.balance_gold_18k}, 21k={customer.balance_gold_21k}")
                customer.balance_cash += (cash_debit - cash_credit)
                customer.balance_gold_18k += (weight_18k_debit - weight_18k_credit)
                customer.balance_gold_21k += (weight_21k_debit - weight_21k_credit)
                customer.balance_gold_22k += (weight_22k_debit - weight_22k_credit)
                customer.balance_gold_24k += (weight_24k_debit - weight_24k_credit)
                print(f"   After: cash={customer.balance_cash}, 18k={customer.balance_gold_18k}, 21k={customer.balance_gold_21k}")
            else:
                print(f"⚠️ Customer {customer_id} not found!")
    except Exception as e:
        print(f"❌ Warning: Could not update customer/supplier balance: {e}")
    
    return line


def verify_dual_balance(journal_entry_id):
    """
    Verify dual balance for a journal entry.
    Must be called from routes.py where db is already in context.
    """
    from sqlalchemy import func
    from flask import current_app
    from models import JournalEntryLine
    
    db = current_app.extensions['sqlalchemy']
    
    cash_totals = db.session.query(
        func.sum(JournalEntryLine.cash_debit).label('total_debit'),
        func.sum(JournalEntryLine.cash_credit).label('total_credit')
    ).filter_by(journal_entry_id=journal_entry_id).first()
    
    cash_debit = cash_totals.total_debit or 0
    cash_credit = cash_totals.total_credit or 0
    cash_balance = round(cash_debit - cash_credit, 2)
    
    weight_totals = db.session.query(
        func.sum(JournalEntryLine.debit_18k).label('debit_18k'),
        func.sum(JournalEntryLine.credit_18k).label('credit_18k'),
        func.sum(JournalEntryLine.debit_21k).label('debit_21k'),
        func.sum(JournalEntryLine.credit_21k).label('credit_21k'),
        func.sum(JournalEntryLine.debit_22k).label('debit_22k'),
        func.sum(JournalEntryLine.credit_22k).label('credit_22k'),
        func.sum(JournalEntryLine.debit_24k).label('debit_24k'),
        func.sum(JournalEntryLine.credit_24k).label('credit_24k')
    ).filter_by(journal_entry_id=journal_entry_id).first()
    
    weight_balances = {
        '18k': round((weight_totals.debit_18k or 0) - (weight_totals.credit_18k or 0), 3),
        '21k': round((weight_totals.debit_21k or 0) - (weight_totals.credit_21k or 0), 3),
        '22k': round((weight_totals.debit_22k or 0) - (weight_totals.credit_22k or 0), 3),
        '24k': round((weight_totals.debit_24k or 0) - (weight_totals.credit_24k or 0), 3)
    }
    
    errors = []
    balanced = True
    
    if abs(cash_balance) > 0.01:
        balanced = False
        errors.append(f'Cash imbalance: {cash_balance}')
    
    for karat, balance in weight_balances.items():
        if abs(balance) > 0.001:
            balanced = False
            errors.append(f'Weight imbalance ({karat}): {balance}')
    
    return {
        'balanced': balanced,
        'cash_balance': cash_balance,
        'weight_balances': weight_balances,
        'errors': errors
    }


def get_account_balances(account_id):
    """
    Get account balances (cash + weight).
    Must be called from routes.py where db is already in context.
    """
    from flask import current_app
    from models import Account
    
    db = current_app.extensions['sqlalchemy']
    
    account = db.session.query(Account).filter_by(id=account_id).first()
    if not account:
        raise ValueError(f'Account {account_id} not found')
    
    result = {
        'cash': round(account.balance_cash, 2)
    }
    
    if account.tracks_weight:
        result['weight'] = {
            '18k': round(account.balance_18k, 3),
            '21k': round(account.balance_21k, 3),
            '22k': round(account.balance_22k, 3),
            '24k': round(account.balance_24k, 3),
            'total': round(account.get_total_weight(), 3)
        }
    
    return result
