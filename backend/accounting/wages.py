from __future__ import annotations

from models import db, Account, Settings
from accounting.mappings import (
    get_account_id_by_number,
    get_account_id_for_mapping,
    _ACCOUNT_NUMBER_CACHE,
)

# ---------------------------------------------------------------------------
# How manufacturing wages are treated (ADR-039) -- the one reading.
#
# The company's policy (Settings.manufacturing_wage_mode):
#   inventory: a purchase capitalizes its wages on the wage inventory (1320);
#              a sale moves them to the wage expense; a sale return back.
#   expense:   a purchase charges them to the wage expense; a sale, a sale
#              return and a melting leave the wage inventory alone.
# Each invoice freezes the mode at creation (manufacturing_wage_mode_snapshot,
# section 13) and its entry follows that, not the live setting.
# ---------------------------------------------------------------------------
WAGE_MODE_INVENTORY = 'inventory'
WAGE_MODE_EXPENSE = 'expense'
WAGE_MODES = (WAGE_MODE_INVENTORY, WAGE_MODE_EXPENSE)


def live_wage_mode() -> str:
    """The company's setting now; `expense` when unset (the column's default)."""
    row = Settings.query.first()
    mode = str(getattr(row, 'manufacturing_wage_mode', '') or '').strip().lower()
    return mode if mode in WAGE_MODES else WAGE_MODE_EXPENSE


def wage_mode_of(invoice) -> str:
    """The mode frozen on [invoice] at its creation; the live setting only for
    an invoice that predates the snapshot."""
    mode = str(getattr(invoice, 'manufacturing_wage_mode_snapshot', '') or '').strip().lower()
    return mode if mode in WAGE_MODES else live_wage_mode()


def wages_are_capitalized(mode: str) -> bool:
    return mode == WAGE_MODE_INVENTORY


def manufacturing_wage_inventory_account_id() -> int | None:
    """Where capitalized wages live: the mapping, else 1320, else 1350."""
    for operation in ('شراء', 'شراء من مورد', 'بيع'):
        acc_id = get_account_id_for_mapping(operation, 'manufacturing_wage_inventory')
        if acc_id:
            return acc_id
    return get_account_id_by_number('1320') or get_account_id_by_number('1350')


def manufacturing_wage_expense_account_id() -> int | None:
    """Where wages become an expense -- at sale when capitalized, at purchase
    when expensed: one account either way."""
    return (
        get_account_id_for_mapping('بيع', 'manufacturing_wage')
        or _ensure_manufacturing_wage_expense_account()
        or get_account_id_for_mapping('بيع', 'operating_expenses')
        or get_account_id_by_number('51')
    )


def _ensure_manufacturing_wage_expense_account() -> int | None:
    """Find or create the manufacturing wage expense account (510) and return its ID."""
    target_number = '510'
    cached = get_account_id_by_number(target_number)
    if cached:
        return cached

    parent = Account.query.filter_by(account_number='51').first()
    account = Account(
        account_number=target_number,
        name='مصروفات أجور المصنعية',
        type='expense',
        transaction_type='cash',
        tracks_weight=False,
        parent_id=parent.id if parent else None,
    )
    db.session.add(account)
    db.session.commit()
    _ACCOUNT_NUMBER_CACHE[target_number] = account.id
    return account.id


def _ensure_gold24k_commission_revenue_account() -> int | None:
    """Find or create إيرادات عمولة السداد بذهب صافي under 41 (إيرادات النشاط).

    Uses name-first lookup so the account is found regardless of which number
    was assigned on first creation (avoids clashes across dev/prod DBs).
    Production account number: 4110.
    """
    by_number = Account.query.filter_by(account_number='4110').first()
    if by_number:
        return by_number.id

    acct_name = 'إيرادات عمولة السداد بذهب صافي'
    by_name = Account.query.filter_by(name=acct_name).first()
    if by_name:
        return by_name.id

    parent = Account.query.filter_by(account_number='41').first()
    if not parent:
        parent = Account.query.filter_by(account_number='4').first()
    chosen_number = None
    for candidate in ('4110', '4111', '4112', '4113', '4120'):
        if not Account.query.filter_by(account_number=candidate).first():
            chosen_number = candidate
            break
    if not chosen_number:
        chosen_number = '4110'

    account = Account(
        account_number=chosen_number,
        name=acct_name,
        type='revenue',
        transaction_type='cash',
        tracks_weight=False,
        parent_id=parent.id if parent else None,
    )
    db.session.add(account)
    db.session.flush()
    return account.id
