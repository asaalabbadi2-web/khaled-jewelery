"""An office's own account: linked, or made under the mapped parent (CHART-002 step 4b).

The office posts to office.account_category_id and its weight twin. The code
found the parent by number (2100, 210, 21, 2200, 220...), built 210/2100 or
220/2200 when missing, moved the office's account under that parent on every
call, and made the parent's twin when missing. Now the parent is the role
office_accounts_parent (2100 on production, the suppliers' -- an office is a
supplier too), and the twin is party_account_service's one rule.
"""
from __future__ import annotations

from models import db, Account, Office
from party_account_service import OFFICE_PARENT, ensure_twin, new_account_under, party_parent


def office_parent_account() -> Account:
    """The parent an office's account is made under -- or AccountNotMapped."""
    return party_parent(OFFICE_PARENT)


def ensure_office_account(office: Office, *, auto_commit: bool = False) -> Account:
    """The office's own account and its weight twin: linked, or made under the role."""
    if not office:
        raise ValueError('office is required to ensure accounting linkage')

    account = db.session.get(Account, office.account_category_id) if office.account_category_id else None
    if account is None:
        account = new_account_under(office_parent_account(), office.name or 'مكتب')
        office.account_category_id = account.id
        db.session.add(office)
        db.session.flush()
    ensure_twin(account, f'{account.name} وزني', by='office_account_service')

    if auto_commit:
        db.session.commit()
    return account
