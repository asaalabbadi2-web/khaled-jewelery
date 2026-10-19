"""An office holds our gold as a bank holds our money (ADR-052) -- the one place a deposit is made.

A deposit is «ذهب مودع لدى <office>»: a weight-only asset under the mapped
parent `office_gold_deposit_parent` («ذهب مودع لدى المكاتب»), and its safe at
the place «deposit» -- stock, counted with the shop's gold. It is the office
supplier's gold safe: a settled reservation keeps its gold there, a payment
voucher from it pays a supplier. The office's supplier account stays for the
trade: what is bought from it, sold to it, owed.

The parent is a role, never a number (CHART-002): unmapped, a deposit is
refused (AccountNotMapped) -- only the one-time setup tool makes it.
"""
from __future__ import annotations

from models import Account, AccountingMapping, SafeBox, Supplier, db

DEPOSIT_PARENT = 'office_gold_deposit_parent'


def deposit_parent(*, by, create=False) -> tuple:
    """(the deposits' weight group, made now?). Unmapped: made and mapped when
    *create* (the setup tool), else AccountNotMapped."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping, require_account

    found = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, DEPOSIT_PARENT)
    if found:
        return db.session.get(Account, found), False
    if not create:
        require_account(DEFAULT_MAPPING_OPERATION_TYPE, DEPOSIT_PARENT)      # raises, by name
    from account_number_generator import get_next_account_number
    from employee_account_helpers import ensure_memo_for_account
    root = db.session.get(Account, require_account(DEFAULT_MAPPING_OPERATION_TYPE, 'gold_inventory_root'))
    group = Account(account_number=str(get_next_account_number(str(root.account_number))),
                    name='ذهب مودع لدى المكاتب', type='Asset', transaction_type='cash', tracks_weight=False,
                    parent_id=root.id)
    db.session.add(group)
    db.session.flush()
    weight = ensure_memo_for_account(group)
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=DEPOSIT_PARENT,
                                     account_id=weight.id, is_active=True, created_by=by,
                                     description='ذهب مودع لدى المكاتب (ADR-052)'))
    db.session.flush()
    return weight, True


def deposit_name(office) -> str:
    return 'ذهب مودع لدى ' + ' '.join((office.name or '').split())


def deposit_of(supplier):
    """The supplier's gold safe when it is a deposit -- else None. By id, not
    the relationship: a link set in this session reads true."""
    safe_id = getattr(supplier, 'default_safe_box_id', None) if supplier is not None else None
    safe = db.session.get(SafeBox, safe_id) if safe_id else None
    return safe if safe is not None and safe.stock_location == 'deposit' else None


def ensure_deposit(office, *, by, parent=None) -> tuple:
    """(the office's deposit safe, made now?): its supplier's, or made under the
    parent and made its supplier's gold safe. The old safe on the supplier
    account, if it was the gold safe, is stopped."""
    from account_number_generator import get_next_account_number

    supplier = db.session.get(Supplier, office.supplier_id) if office.supplier_id else None
    if supplier is None:
        raise ValueError(f'«{office.name}» بلا مورد مرتبط: لا وديعة له')
    found = deposit_of(supplier)
    if found is not None:
        return found, False
    if parent is None:
        parent, _ = deposit_parent(by=by)
    account = Account(account_number=str(get_next_account_number(str(parent.account_number))),
                      name=deposit_name(office), type='Asset', transaction_type='gold', tracks_weight=True,
                      parent_id=parent.id)
    db.session.add(account)
    db.session.flush()
    safe = SafeBox(name=account.name, safe_type='gold', account_id=account.id, stock_location='deposit',
                   is_active=True, created_by=by)
    db.session.add(safe)
    db.session.flush()
    old = db.session.get(SafeBox, supplier.default_safe_box_id) if supplier.default_safe_box_id else None
    if old is not None and old.holds_party_gold:
        old.is_active = False
    supplier.default_safe_box_id = safe.id
    db.session.flush()
    return safe, True
