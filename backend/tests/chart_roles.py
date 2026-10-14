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
    'inventory_18k': ['1300'], 'inventory_21k': ['1220', '1310'], 'inventory_22k': ['1320'],
    'inventory_24k': ['1200', '1330', '1340'],
    'manufacturing_wage_inventory': ['1340', '1350', '1320'],
    'cash': ['15', '1100'], 'customers': ['1200'], 'suppliers': ['210'],
    'revenue': ['400', '40'], 'sales_gold_new': ['400', '40'], 'sales_gold_scrap': ['401'],
    'sales_returns': ['420', '400', '40'],
    'purchases_gold': ['511', '512', '510', '51'], 'purchases_gold_new': ['511', '510', '51'],
    'purchases_gold_scrap': ['512', '511', '510'], 'purchase_returns': ['513', '512', '511', '50'],
    'commission': ['5150'], 'manufacturing_wage': ['510'],
}
_NAMES = {
    'cash': ['صندوق النقدية'], 'sales_gold_new': ['مبيعات ذهب جديد'], 'sales_gold_scrap': ['مبيعات ذهب كسر'],
    'revenue': ['مبيعات ذهب جديد'], 'inventory_21k': ['مخزون ذهب عيار 21'],
    'inventory_24k': ['مخزون ذهب عيار 24'], 'suppliers': ['موردو ذهب'], 'customers': ['أرصدة ذهب العملاء'],
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
