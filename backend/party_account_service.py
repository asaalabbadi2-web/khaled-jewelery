"""A party's accounts: its own, by link; made under a mapped parent (CHART-002 step 4b, ADR-046).

A customer, a supplier or an office posts to its own account (customer.account_id,
supplier.account_id, office.account_category_id) and that account's weight twin
(its memo_account_id). Both are links -- read, never second-guessed.

The code found these parents by number (1200 / 1100 for customers; 2100, 210, 21,
2200, 220... for suppliers and offices), built them when missing, made weight
roots (71000, 7210) and re-parented them, moved a supplier's account from 210 to
2100, and -- on every voucher -- dropped a linked twin whose number broke the
«7 + number» rule to link another: supplier 23 «مكاتب تسكير فورية واشخاص»,
linked to 72100021, was refused at every invoice payment, the rule's 721000020
marked abandoned (14 Oct 2026). The owner, 14 Oct 2026: the chart is data.

- A party with no account gets one under its category, or the parent role
  (customer_accounts_parent / supplier_accounts_parent / office_accounts_parent).
  The role unmapped, the account is refused -- no parent is made.
- A twin is made under the twin of its account's parent (the parent's own
  memo_account_id), numbered «7 + number» (the numbering table decides 2027's).
  The parent with no twin, the twin is refused -- no parent twin is made.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from account_pair_service import link_accounts
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, require_account
from models import Account, Customer, Supplier, db

CUSTOMER_PARENT = 'customer_accounts_parent'
SUPPLIER_PARENT = 'supplier_accounts_parent'
OFFICE_PARENT = 'office_accounts_parent'
PARENT_ROLES = (CUSTOMER_PARENT, SUPPLIER_PARENT, OFFICE_PARENT)


@dataclass(frozen=True)
class PartyAccounts:
    financial: Account
    memo: Account


def _digits_only(value: str) -> str:
    return ''.join(ch for ch in str(value or '').strip() if ch.isdigit())


def _memo_number_from_financial(financial_account_number: str | int) -> str:
    digits = _digits_only(str(financial_account_number))
    if not digits:
        raise ValueError('Invalid financial account number')
    return f"7{digits}"


def party_parent(role: str) -> Account:
    """The account a party parent role is mapped to -- or AccountNotMapped."""
    return db.session.get(Account, require_account(DEFAULT_MAPPING_OPERATION_TYPE, role))


def _is_posting_account(financial: Optional[Account], *, category: Optional[Account] = None) -> bool:
    """A party's own account: cash, not a weight account, not its group."""
    if financial is None:
        return False
    if financial.transaction_type != 'cash' or financial.tracks_weight:
        return False
    return category is None or financial.id != category.id


def new_account_under(parent: Account, name: str) -> Account:
    """A party's account, the next number under *parent*."""
    from account_number_generator import get_next_account_number, get_next_party_account_number

    digits = _digits_only(str(parent.account_number))
    number = (get_next_party_account_number(digits) if len(digits) == 3
              else get_next_account_number(digits, use_spacing=False))
    account = Account(account_number=_digits_only(number), name=name, type=parent.type or 'Liability',
                      transaction_type='cash', tracks_weight=False, parent_id=parent.id)
    db.session.add(account)
    db.session.flush()
    return account


def ensure_twin(financial: Account, name: str, *, by: str = 'party_account_service') -> Account:
    """The weight twin of a party's account: the linked one, or made under its parent's twin."""
    linked = db.session.get(Account, financial.memo_account_id) if financial.memo_account_id else None
    if linked is not None and linked.tracks_weight:
        return linked

    number = _memo_number_from_financial(financial.account_number)
    memo = Account.query.filter_by(account_number=number).first()
    if memo is not None:
        if not memo.tracks_weight or memo.transaction_type != 'gold':
            raise ValueError(f'Memo account number collision: {number} exists but is not a gold/weight account')
    else:
        parent = db.session.get(Account, financial.parent_id) if financial.parent_id else None
        parent_twin = (db.session.get(Account, parent.memo_account_id)
                       if parent is not None and parent.memo_account_id else None)
        if parent_twin is None:
            raise ValueError(f'«{parent.name if parent else financial.name}» بلا حساب وزني مربوط — '
                             f'يُربط في شجرة الحسابات، ولا يُنشأ للحساب «{financial.name}» توأم دونه')
        memo = Account(account_number=number, name=name, type=financial.type or parent_twin.type,
                       transaction_type='gold', tracks_weight=True, parent_id=parent_twin.id)
        db.session.add(memo)
        db.session.flush()

    # الربط الثنائي عبر الخدمة المركزية فقط (account_pair_service.py).
    link_accounts(financial, memo, created_by=by)
    db.session.flush()
    return memo


def ensure_customer_accounts(customer: Customer) -> PartyAccounts:
    """A customer's account and its weight twin: linked, or made under its category / the role."""
    if not customer:
        raise ValueError('customer is required')
    category = db.session.get(Account, customer.account_category_id) if customer.account_category_id else None
    financial = db.session.get(Account, customer.account_id) if customer.account_id else None
    if not _is_posting_account(financial, category=category):
        financial = new_account_under(category or party_parent(CUSTOMER_PARENT), customer.name)
        customer.account_id = financial.id
        db.session.flush()
    memo = ensure_twin(financial, f'أرصدة ذهب العملاء - {customer.name}')
    return PartyAccounts(financial=financial, memo=memo)


def ensure_supplier_accounts(supplier: Supplier) -> PartyAccounts:
    """A supplier's account and its weight twin: linked, or made under its category / the role."""
    if not supplier:
        raise ValueError('supplier is required')
    category = db.session.get(Account, supplier.account_category_id) if supplier.account_category_id else None
    financial = db.session.get(Account, supplier.account_id) if supplier.account_id else None
    if not _is_posting_account(financial, category=category):
        category = category or party_parent(SUPPLIER_PARENT)
        if supplier.account_category_id != category.id:
            supplier.account_category_id = category.id
        financial = new_account_under(category, supplier.name)
        supplier.account_id = financial.id
        db.session.flush()
    memo = ensure_twin(financial, f'موردو ذهب مشغول وزني - {supplier.name}')
    return PartyAccounts(financial=financial, memo=memo)
