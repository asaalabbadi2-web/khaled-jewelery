from __future__ import annotations

from models import Settings
from accounting.mappings import get_account_id_for_mapping

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
    """Where capitalized wages live: the mapped role, nothing else (CHART-002)."""
    for operation in ('شراء', 'شراء من مورد', 'بيع'):
        acc_id = get_account_id_for_mapping(operation, 'manufacturing_wage_inventory')
        if acc_id:
            return acc_id
    return None


def manufacturing_wage_expense_account_id() -> int | None:
    """Where wages become an expense -- at sale when capitalized, at purchase
    when expensed: one account either way, the mapped role (CHART-002: no 510
    created on the fly, no 51 standing in)."""
    return get_account_id_for_mapping('بيع', 'manufacturing_wage')


