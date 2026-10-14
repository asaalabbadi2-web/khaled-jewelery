"""The test chart's role mappings (CHART-002).

No number stands in for a role any more: production maps each role to its
account (AccountingMapping), and so does the test database. At its creation,
each required role (accounting.mappings.REQUIRED_ROLES) is mapped to the
account the old number/name fallback found in this chart -- the same accounts
the suite has always posted to, now written down as data instead of guessed by
the code. A test that wants another account for a role maps it, as the books it
imitates do (cf. vat_mapped).
"""
from __future__ import annotations

# The fallback the code held until CHART-002 -- here only to say what the test
# chart's roles have always been. Never read by the application.
_NUMBERS = {
    'manufacturing_wage_inventory': ['1340', '1350', '1320'],
    'cash': ['15', '1100'], 'customers': ['1200'], 'suppliers': ['210'],
    'revenue': ['400', '40'], 'sales_gold_new': ['400', '40'], 'sales_gold_scrap': ['401'],
    'sales_returns': ['420', '400', '40'],
    'purchases_gold': ['511', '512', '510', '51'], 'purchases_gold_new': ['511', '510', '51'],
    'purchases_gold_scrap': ['512', '511', '510'], 'purchase_returns': ['513', '512', '511', '50'],
    'commission': ['5150'], 'manufacturing_wage': ['510'],
    'gold_cost_of_sales': ['521'], 'gold_cost_of_sales_weight': ['7521'],
    # The employee structure (CHART-002 step 3): what the code built by these
    # numbers before; production maps the same.
    'employee_personal_parent': ['1700'], 'employee_salary_payable_parent': ['2400'],
    'employee_commission_payable_parent': ['2410'], 'employee_eos_payable_parent': ['2420'],
    'employee_bonus_payable_parent': ['2310'], 'employee_gold_custody_parent': ['71310001'],
    'employee_cash_custody_parent': ['1100001'], 'salary_expense': ['5410'], 'bonus_expense': ['5401'],
    # Step 4: the gold's financial inventory (the old settings' defaults), the
    # weight closing's bridge, the karat-difference commission.
    'gold_inventory_new': ['1300'], 'gold_inventory_scrap': ['1310'], 'weight_closing_bridge': ['1710'],
    'karat_diff_revenue': ['4110'], 'karat_diff_expense': ['5240'],
    # Step 4b: the parents a party's account is made under (the code's old order).
    'customer_accounts_parent': ['1200', '1100', '120', '110'],
    'supplier_accounts_parent': ['2100', '210', '21', '21100', '2110', '211', '2200', '220'],
    'office_accounts_parent': ['2100', '210', '21', '2200', '220', '21100', '211'],
}
_NAMES = {
    'cash': ['صندوق النقدية'], 'sales_gold_new': ['مبيعات ذهب جديد'], 'sales_gold_scrap': ['مبيعات ذهب كسر'],
    'revenue': ['مبيعات ذهب جديد'], 'suppliers': ['موردو ذهب'], 'customers': ['أرصدة ذهب العملاء'],
}


def map_roles_as_the_test_chart_resolves():
    from accounting.mappings import REQUIRED_ROLES, get_account_id_for_mapping
    from models import Account, AccountingMapping, db

    def found(role):
        for number in _NUMBERS.get(role, ()):
            account = Account.query.filter_by(account_number=number).first()
            if account:
                return account
        for name in _NAMES.get(role, ()):
            account = Account.query.filter_by(name=name).first()
            if account:
                return account
        return None

    for operation, role in REQUIRED_ROLES:
        if get_account_id_for_mapping(operation, role):
            continue
        account = found(role)
        if account is not None:
            db.session.add(AccountingMapping(operation_type=operation, account_type=role,
                                             account_id=account.id, is_active=True, created_by='test-chart'))
            db.session.flush()
