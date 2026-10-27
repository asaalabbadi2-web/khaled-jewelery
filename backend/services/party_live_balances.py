# -*- coding: utf-8 -*-

from __future__ import annotations

from typing import Dict, Iterable, List, Optional

from sqlalchemy import and_, func, or_

from models import Account, JournalEntry, JournalEntryLine, Office, Supplier, db

_DB_COLUMN_CACHE: Dict[tuple, bool] = {}


def _db_has_column(table_name: str, column_name: str) -> bool:
    key = (table_name, column_name)
    cached = _DB_COLUMN_CACHE.get(key)
    if cached is not None:
        return cached
    try:
        from sqlalchemy import inspect as sa_inspect

        inspector = sa_inspect(db.engine)
        cols = {c.get('name') for c in inspector.get_columns(table_name)}
        exists = column_name in cols
    except Exception:
        exists = False
    _DB_COLUMN_CACHE[key] = exists
    return exists


def compute_live_supplier_balances(
    suppliers: Iterable[Supplier],
) -> Dict[int, Dict[str, float]]:
    """Compute supplier balances directly from the journal (ledger).

    Returns mapping supplier_id -> {'cash','18k','21k','22k','24k'}.

    This mirrors the filtering behavior used by the suppliers list endpoint:
    - include supplier payable liability lines (the payables group's tree, 21 on production)
    - include the supplier's own financial + memo accounts
    - include mis-tagged lines posted to the supplier's own accounts when
      supplier_id is NULL.
    """

    suppliers = list(suppliers)
    supplier_ids: List[int] = []
    for s in suppliers:
        if getattr(s, 'id', None) is None:
            continue
        try:
            supplier_ids.append(int(s.id))
        except Exception:
            continue

    supplier_fin_account_ids: List[int] = []
    for s in suppliers:
        if not getattr(s, 'account_id', None):
            continue
        try:
            supplier_fin_account_ids.append(int(s.account_id))
        except Exception:
            continue

    # Map supplier -> office posting account id (only for suppliers that are linked to an Office).
    office_account_by_supplier_id: Dict[int, int] = {}
    try:
        office_rows = (
            db.session.query(Office.supplier_id, Office.account_category_id)
            .filter(Office.supplier_id.isnot(None))
            .all()
        )
        for supplier_id, office_account_id in office_rows:
            if supplier_id is None or office_account_id is None:
                continue
            try:
                office_account_by_supplier_id[int(supplier_id)] = int(office_account_id)
            except Exception:
                continue
    except Exception:
        office_account_by_supplier_id = {}

    financial_accounts: Dict[int, Account] = {}
    if supplier_fin_account_ids:
        for a in Account.query.filter(Account.id.in_(supplier_fin_account_ids)).all():
            try:
                financial_accounts[int(a.id)] = a
            except Exception:
                continue

    # A supplier's weight twin is its account's link (memo_account_id) -- never
    # guessed as «7 + number» (CHART-002 4c4; no supplier lacked the link on the
    # production copy, 14 Oct 2026).
    allowed_account_to_supplier: Dict[int, int] = {}
    for s in suppliers:
        try:
            sid = int(s.id)
        except Exception:
            continue

        fin_id: Optional[int]
        try:
            fin_id = int(s.account_id) if s.account_id else None
        except Exception:
            fin_id = None

        if not fin_id:
            continue

        allowed_account_to_supplier[fin_id] = sid

        fin_acc = financial_accounts.get(fin_id)
        memo_id: Optional[int]
        try:
            memo_id = int(fin_acc.memo_account_id) if fin_acc and fin_acc.memo_account_id else None
        except Exception:
            memo_id = None

        if memo_id:
            allowed_account_to_supplier[memo_id] = sid

        # Office-linked suppliers can post directly to a dedicated office posting account.
        # That account lives on Office.account_category_id (NOT Supplier.account_category_id).
        # Include it so mis-tagged lines (supplier_id NULL) still reconcile.
        try:
            raw_office_acc_id = office_account_by_supplier_id.get(sid)
            if raw_office_acc_id not in (None, '', 0, '0', False):
                office_acc = Account.query.get(int(raw_office_acc_id))
                if (
                    office_acc
                    and bool(getattr(office_acc, 'tracks_weight', False))
                    and str(getattr(office_acc, 'transaction_type', '') or '').lower() == 'both'
                ):
                    allowed_account_to_supplier[int(office_acc.id)] = sid
        except Exception:
            pass

    allowed_account_ids = list({int(x) for x in allowed_account_to_supplier.keys() if x})

    # Legacy DB robustness:
    # Some datasets have NULLs in is_draft/is_posted even if the model declares them non-nullable.
    # Use COALESCE to avoid accidentally excluding valid historical entries.
    jl_filters = [
        func.coalesce(JournalEntry.is_deleted, False) == False,
        func.coalesce(JournalEntryLine.is_deleted, False) == False,
    ]
    if _db_has_column('journal_entry', 'is_draft') and _db_has_column('journal_entry', 'is_posted'):
        # A posted entry (is_posted=True) MUST always be included even if is_draft was
        # accidentally left True (data inconsistency after invoice/voucher workflows).
        # Only exclude genuine unposted drafts: is_draft=True AND is_posted=False.
        jl_filters.append(
            or_(
                func.coalesce(JournalEntry.is_posted, False) == True,
                func.coalesce(JournalEntry.is_draft, False) == False,
            )
        )
    elif _db_has_column('journal_entry', 'is_draft'):
        jl_filters.append(func.coalesce(JournalEntry.is_draft, False) == False)
    elif _db_has_column('journal_entry', 'is_posted'):
        jl_filters.append(func.coalesce(JournalEntry.is_posted, True) == True)

    # A cancelled reservation's entries are read as they are: its execution's
    # reversal names the purchase, not the reservation, and leaving out the
    # execution alone put its amount in the office's favour (RESERVATION-BALANCE-1).

    # Always return an entry for each supplier in input.
    balances_by_supplier: Dict[int, Dict[str, float]] = {
        int(sid): {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
        for sid in supplier_ids
    }

    # What is owed to suppliers: the Liability accounts under the role's group (21 on
    # production) -- by the tree, not the number's prefix (CHART-002).
    from accounting.chart_tree import SUPPLIER_PAYABLES_ROOT, role_subtree_ids
    payable_filter = and_(Account.type == 'Liability', Account.id.in_(role_subtree_ids(SUPPLIER_PAYABLES_ROOT)))
    account_filter = payable_filter
    if allowed_account_ids:
        account_filter = or_(Account.id.in_(allowed_account_ids), payable_filter)

    # (A) Tagged lines on allowed accounts only (same account_filter as statement endpoint).
    # We intentionally do NOT fall back to a relaxed (no account filter) path because that
    # would include inventory / COGS / expense lines that happen to carry supplier_id, which
    # inflates the balance. Path (B) below handles the rare case where supplier_id is NULL
    # but the line was posted to the supplier's own financial/memo account.
    if supplier_ids:
        tagged_rows = (
            db.session.query(
                JournalEntryLine.supplier_id.label('supplier_id'),
                (
                    func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0)
                ).label('cash'),
                (
                    func.coalesce(func.sum(JournalEntryLine.debit_18k), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.credit_18k), 0.0)
                ).label('b18'),
                (
                    func.coalesce(func.sum(JournalEntryLine.debit_21k), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.credit_21k), 0.0)
                ).label('b21'),
                (
                    func.coalesce(func.sum(JournalEntryLine.debit_22k), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.credit_22k), 0.0)
                ).label('b22'),
                (
                    func.coalesce(func.sum(JournalEntryLine.debit_24k), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.credit_24k), 0.0)
                ).label('b24'),
            )
            .join(JournalEntry)
            .join(Account, JournalEntryLine.account_id == Account.id)
            .filter(JournalEntryLine.supplier_id.in_(supplier_ids))
            .filter(*jl_filters)
            .filter(account_filter)
            .group_by(JournalEntryLine.supplier_id)
            .all()
        )

        for r in tagged_rows:
            try:
                sid = int(r.supplier_id)
            except Exception:
                continue
            balances_by_supplier[sid] = {
                'cash': float(getattr(r, 'cash', 0.0) or 0.0),
                '18k': float(getattr(r, 'b18', 0.0) or 0.0),
                '21k': float(getattr(r, 'b21', 0.0) or 0.0),
                '22k': float(getattr(r, 'b22', 0.0) or 0.0),
                '24k': float(getattr(r, 'b24', 0.0) or 0.0),
            }

    # (B) Mis-tagged lines posted to supplier accounts (supplier_id NULL)
    if allowed_account_ids:
        untagged_rows = (
            db.session.query(
                JournalEntryLine.account_id.label('account_id'),
                (
                    func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0)
                ).label('cash'),
                (
                    func.coalesce(func.sum(JournalEntryLine.debit_18k), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.credit_18k), 0.0)
                ).label('b18'),
                (
                    func.coalesce(func.sum(JournalEntryLine.debit_21k), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.credit_21k), 0.0)
                ).label('b21'),
                (
                    func.coalesce(func.sum(JournalEntryLine.debit_22k), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.credit_22k), 0.0)
                ).label('b22'),
                (
                    func.coalesce(func.sum(JournalEntryLine.debit_24k), 0.0)
                    - func.coalesce(func.sum(JournalEntryLine.credit_24k), 0.0)
                ).label('b24'),
            )
            .join(JournalEntry)
            .filter(JournalEntryLine.supplier_id.is_(None))
            .filter(JournalEntryLine.customer_id.is_(None))
            .filter(JournalEntryLine.account_id.in_(allowed_account_ids))
            .filter(*jl_filters)
            .group_by(JournalEntryLine.account_id)
            .all()
        )

        for r in untagged_rows:
            try:
                acc_id = int(r.account_id)
            except Exception:
                continue
            sid = allowed_account_to_supplier.get(acc_id)
            if not sid:
                continue
            cur = balances_by_supplier.get(sid)
            if not cur:
                cur = {'cash': 0.0, '18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}
                balances_by_supplier[sid] = cur

            cur['cash'] += float(getattr(r, 'cash', 0.0) or 0.0)
            cur['18k'] += float(getattr(r, 'b18', 0.0) or 0.0)
            cur['21k'] += float(getattr(r, 'b21', 0.0) or 0.0)
            cur['22k'] += float(getattr(r, 'b22', 0.0) or 0.0)
            cur['24k'] += float(getattr(r, 'b24', 0.0) or 0.0)

    return balances_by_supplier


# ── Customers (BALANCE-001 B1, the owner 2 Oct 2026) ─────────────────────────

def customer_line_clause(customer_id: int, own_account_id, all_own_account_ids):
    """The ledger lines that are a customer's: every line on its own financial
    account, tagged or not, plus the lines tagged to it on shared customer
    accounts (the receivables group's, 120 on production) -- not those tagged to
    it on another customer's own account.
    One rule for the list, the statement and the dashboard."""
    from accounting.chart_tree import CUSTOMER_RECEIVABLES_ROOT, role_subtree_ids
    from models import JournalEntryLine
    others = [a for a in all_own_account_ids if a != own_account_id] or [-1]
    tagged_on_shared = and_(
        JournalEntryLine.customer_id == int(customer_id),
        Account.type == 'Asset',
        Account.id.in_(role_subtree_ids(CUSTOMER_RECEIVABLES_ROOT)),
        JournalEntryLine.account_id.notin_(others),
    )
    if own_account_id:
        return or_(JournalEntryLine.account_id == int(own_account_id), tagged_on_shared)
    return tagged_on_shared


def all_customer_own_account_ids() -> List[int]:
    from models import Customer
    return [int(a) for (a,) in db.session.query(Customer.account_id).filter(Customer.account_id.isnot(None))]


def compute_live_customer_balances(customers: Iterable) -> Dict[int, Dict[str, float]]:
    """customer_id -> {'cash','18k','21k','22k','24k'} from the posted ledger.

    Cash and the gold columns of the same lines -- the financial accounts. The
    weight memo twin (712…) is not read: it accumulates the dual system's
    weights (19,173.5 g of 21k on the cash customer's), not gold a customer owes.
    """
    customers = [c for c in customers if getattr(c, 'id', None) is not None]
    own_all = all_customer_own_account_ids()
    out: Dict[int, Dict[str, float]] = {}
    for c in customers:
        row = (
            db.session.query(
                func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0) - func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0),
                func.coalesce(func.sum(JournalEntryLine.debit_18k), 0.0) - func.coalesce(func.sum(JournalEntryLine.credit_18k), 0.0),
                func.coalesce(func.sum(JournalEntryLine.debit_21k), 0.0) - func.coalesce(func.sum(JournalEntryLine.credit_21k), 0.0),
                func.coalesce(func.sum(JournalEntryLine.debit_22k), 0.0) - func.coalesce(func.sum(JournalEntryLine.credit_22k), 0.0),
                func.coalesce(func.sum(JournalEntryLine.debit_24k), 0.0) - func.coalesce(func.sum(JournalEntryLine.credit_24k), 0.0),
            )
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .join(Account, Account.id == JournalEntryLine.account_id)
            .filter(JournalEntry.is_posted == True, JournalEntry.is_deleted == False,
                    JournalEntryLine.is_deleted == False,
                    customer_line_clause(int(c.id), getattr(c, 'account_id', None), own_all))
            .one()
        )
        out[int(c.id)] = {k: round(float(v or 0.0), 6) for k, v in zip(('cash', '18k', '21k', '22k', '24k'), row)}
    return out
