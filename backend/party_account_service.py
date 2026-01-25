from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Tuple

from sqlalchemy import and_

from models import Account, Customer, Supplier, db


@dataclass(frozen=True)
class PartyAccounts:
    financial: Account
    memo: Account


def _digits_only(value: str) -> str:
    return ''.join(ch for ch in str(value or '').strip() if ch.isdigit())


def _find_account_by_number(account_number: str | int | None) -> Optional[Account]:
    if account_number is None:
        return None
    digits = _digits_only(str(account_number))
    if not digits:
        return None
    return Account.query.filter_by(account_number=digits).first()


def _get_parent_id_hint_for_memo_root(prefix: str) -> Optional[int]:
    """Try to find a sensible parent_id by looking at existing siblings.

    For example, for prefix '71' we can use the parent of an existing 71100.
    """
    try:
        # Avoid choosing the prefix root itself (e.g. '71'), because that would
        # return parent_id=7 and place 71000 under 7. We want 71000 under 71.
        sibling = (
            Account.query.filter(
                and_(
                    Account.account_number.like(f"{prefix}%"),
                    Account.account_number != str(prefix),
                )
            )
            .order_by(db.cast(Account.account_number, db.Integer).asc())
            .first()
        )
        if sibling and sibling.parent_id:
            return sibling.parent_id

        # Fallback: if the prefix account exists, use it as the parent.
        root = Account.query.filter_by(account_number=str(prefix)).first()
        return root.id if root else None
    except Exception:
        return None


def _ensure_account(
    *,
    account_number: str,
    name: str,
    type: str,
    transaction_type: str,
    tracks_weight: bool,
    parent_id: Optional[int] = None,
) -> Account:
    existing = _find_account_by_number(account_number)
    if existing:
        return existing

    acc = Account(
        account_number=_digits_only(account_number),
        name=name,
        type=type,
        transaction_type=transaction_type,
        tracks_weight=tracks_weight,
        parent_id=parent_id,
    )
    db.session.add(acc)
    db.session.flush()
    return acc


def _memo_number_from_financial(financial_account_number: str | int) -> str:
    digits = _digits_only(str(financial_account_number))
    if not digits:
        raise ValueError('Invalid financial account number')
    return f"7{digits}"


def _is_valid_party_financial_account(
    financial: Account,
    *,
    category: Optional[Account],
) -> bool:
    """Return True if an account is a valid party financial (cash) posting account."""

    if not financial:
        return False

    # Must be a cash account (party financial accounts are cash-based in this system).
    if financial.transaction_type != 'cash':
        return False

    # Must NOT be a weight/memo account.
    if financial.tracks_weight:
        return False
    if str(financial.account_number or '').startswith('7'):
        return False

    # Must not be the category/group account itself.
    if category and financial.id == category.id:
        return False
    if category and str(financial.account_number) == str(category.account_number):
        return False

    # Must be under the category if category is known.
    if category and financial.parent_id != category.id:
        return False

    return True


def _ensure_memo_account_for_financial(
    *,
    financial: Account,
    memo_root: Account,
    memo_name: str,
) -> Account:
    """Ensure memo account exists and is linked.

    Numbering rule: memo_number = '7' + financial.account_number.
    Parenting rule: memo.parent = memo(financial.parent).

    This keeps the memo (وزني) chart mirroring the financial chart shape.
    """

    # Determine the desired parent memo account.
    desired_parent_id: Optional[int] = None
    if financial.parent_id:
        parent_financial = Account.query.get(financial.parent_id)
        if parent_financial:
            parent_memo_number = _memo_number_from_financial(parent_financial.account_number)
            parent_memo = _find_account_by_number(parent_memo_number)
            if not parent_memo:
                parent_memo = _ensure_memo_account_for_financial(
                    financial=parent_financial,
                    memo_root=memo_root,
                    memo_name=f"{parent_financial.name} وزني",
                )
            desired_parent_id = parent_memo.id
        else:
            desired_parent_id = memo_root.id
    else:
        # Root financial accounts (no parent) should sit under memo root '7' when available.
        memo_root_7 = _find_account_by_number('7')
        desired_parent_id = memo_root_7.id if memo_root_7 else memo_root.id

    memo_number = _memo_number_from_financial(financial.account_number)

    # Prefer an existing memo linked to the financial, but validate it matches the numbering rule.
    existing = Account.query.get(financial.memo_account_id) if financial.memo_account_id else None
    if existing:
        if _digits_only(str(existing.account_number)) != _digits_only(memo_number):
            existing = None

    memo = existing or _find_account_by_number(memo_number)
    if memo:
        if not memo.tracks_weight or (memo.transaction_type != 'gold'):
            raise ValueError(
                f"Memo account number collision: {memo_number} exists but is not a gold/weight account"
            )
        # Re-parent if needed to match the mirrored hierarchy.
        if desired_parent_id and memo.parent_id != desired_parent_id:
            memo.parent_id = desired_parent_id
    else:
        memo = Account(
            account_number=_digits_only(memo_number),
            name=memo_name,
            type=financial.type or memo_root.type,
            transaction_type='gold',
            tracks_weight=True,
            parent_id=desired_parent_id,
        )
        db.session.add(memo)
        db.session.flush()

    # Link the financial -> memo (primary link).
    financial.memo_account_id = memo.id
    # Optional reverse link for easier navigation.
    memo.memo_account_id = financial.id
    db.session.flush()
    return memo


def _next_sequential_under_root(root_number: str, *, start_suffix: int = 1, width: int = 3) -> str:
    """Generate next account number under a root using fixed-width suffix.

    Example:
      root_number=71000, width=3 => children 71000001..71000999

    This avoids collisions with existing 71100/71200 groups while keeping a
    stable and predictable namespace.
    """
    root_digits = _digits_only(root_number)
    if not root_digits:
        raise ValueError('Invalid root account number')

    base = int(root_digits) * (10**width)
    start = base + start_suffix
    end = base + (10**width) - 1

    last = (
        Account.query.filter(
            and_(
                db.cast(Account.account_number, db.Integer) >= start,
                db.cast(Account.account_number, db.Integer) <= end,
            )
        )
        .order_by(db.cast(Account.account_number, db.Integer).desc())
        .first()
    )

    if last:
        next_number = int(last.account_number) + 1
    else:
        next_number = start

    if next_number > end:
        raise ValueError(f"Memo account capacity exceeded under {root_digits}")

    return str(next_number)


def ensure_customer_accounts(
    customer: Customer,
    *,
    memo_root_number: str = '71000',
    memo_root_name: str = 'أرصدة ذهب العملاء',
    memo_root_type: str = 'Asset',
    memo_root_prefix_hint: str = '71',
) -> PartyAccounts:
    """Ensure a customer has a financial account + a linked weight memo account.

    - Financial account: under customer's account_category (e.g. 1100/1200/...)
      transaction_type='cash', tracks_weight=False.
    - Memo account: under memo_root_number in the 7xxx memo section,
      transaction_type='gold', tracks_weight=True.

    The financial account's memo_account_id is set to the memo account.
    """

    if not customer:
        raise ValueError('customer is required')

    # 1) Ensure memo root exists.
    memo_root_parent_id = _get_parent_id_hint_for_memo_root(memo_root_prefix_hint)
    memo_root = _ensure_account(
        account_number=memo_root_number,
        name=memo_root_name,
        type=memo_root_type,
        transaction_type='gold',
        tracks_weight=True,
        parent_id=memo_root_parent_id,
    )

    # 2) Ensure financial account exists.
    category = Account.query.get(customer.account_category_id) if customer.account_category_id else None

    financial = Account.query.get(customer.account_id) if customer.account_id else None
    if financial and not _is_valid_party_financial_account(financial, category=category):
        financial = None

    if not financial:
        if not category:
            # Best-effort fallback: use any "customers" group.
            category = _find_account_by_number('1200') or _find_account_by_number('1100')

        if not category:
            raise ValueError('Customer account_category is missing and no fallback category found')

        # Use existing generator rules when possible (4-digit categories supported).
        from account_number_generator import get_next_account_number

        next_number = get_next_account_number(str(category.account_number), use_spacing=False)
        financial = Account(
            account_number=_digits_only(next_number),
            name=customer.name,
            type=category.type,
            transaction_type='cash',
            tracks_weight=False,
            parent_id=category.id,
        )
        db.session.add(financial)
        db.session.flush()
        customer.account_id = financial.id
        db.session.flush()

    # 3) Ensure memo account exists + linked.
    memo = _ensure_memo_account_for_financial(
        financial=financial,
        memo_root=memo_root,
        memo_name=f"{memo_root_name} - {customer.name}",
    )

    return PartyAccounts(financial=financial, memo=memo)


def ensure_supplier_accounts(
    supplier: Supplier,
    *,
    memo_root_number: str = '7220',
    memo_root_name: str = 'موردو ذهب مشغول وزني',
    memo_root_type: str = 'Liability',
    memo_root_prefix_hint: str = '72',
) -> PartyAccounts:
    """Ensure a supplier has a financial account + linked weight memo account."""

    if not supplier:
        raise ValueError('supplier is required')

    memo_root_parent_id = _get_parent_id_hint_for_memo_root(memo_root_prefix_hint)
    # If the memo prefix root itself exists (e.g. '72'), prefer using it as the parent.
    memo_prefix_root = _find_account_by_number(memo_root_prefix_hint)
    if memo_prefix_root:
        memo_root_parent_id = memo_prefix_root.id
    memo_root = _ensure_account(
        account_number=memo_root_number,
        name=memo_root_name,
        type=memo_root_type,
        transaction_type='gold',
        tracks_weight=True,
        parent_id=memo_root_parent_id,
    )

    # Best-effort: if we later discover a better parent (e.g. '72'), re-parent the memo root.
    if memo_root_parent_id and memo_root.parent_id != memo_root_parent_id:
        memo_root.parent_id = memo_root_parent_id
        db.session.flush()

    def _resolve_supplier_posting_category(raw_category: Account | None) -> Account | None:
        """Prefer creating supplier posting accounts under 2100 (not directly under 210).

        Some DBs store suppliers under 210 (group) and 2100 (posting group).
        This normalizes to 2100 when possible.
        """

        if raw_category is None:
            return None

        raw_num = _digits_only(str(getattr(raw_category, 'account_number', '') or ''))
        if raw_num == '210':
            # Ensure 2100 exists as a child of 210.
            category_2100 = Account.query.filter_by(account_number='2100').first()
            if category_2100 and category_2100.parent_id == raw_category.id:
                return category_2100
            return _ensure_account(
                account_number='2100',
                name='حسابات موردو ذهب',
                type=raw_category.type,
                transaction_type='cash',
                tracks_weight=False,
                parent_id=raw_category.id,
            )

        return raw_category

    raw_category = Account.query.get(supplier.account_category_id) if supplier.account_category_id else None
    category = _resolve_supplier_posting_category(raw_category)
    if category and supplier.account_category_id != category.id:
        supplier.account_category_id = category.id
        db.session.flush()

    financial = Account.query.get(supplier.account_id) if supplier.account_id else None
    if financial and not _is_valid_party_financial_account(financial, category=category):
        financial = None

    if not financial:
        if not category:
            # Prefer current chart numbers (e.g., 220/210/21). Keep legacy fallbacks for old DBs.
            category = (
                _find_account_by_number('2100')
                or _find_account_by_number('220')
                or _find_account_by_number('210')
                or _find_account_by_number('21')
                or _find_account_by_number('21100')
                or _find_account_by_number('2110')
                or _find_account_by_number('211')
            )

        # If the chart is missing supplier roots, bootstrap a minimal hierarchy.
        # This keeps supplier invoices usable even on partial COA installs.
        if not category:
            category_210 = _ensure_account(
                account_number='210',
                name='حسابات الموردين',
                type=memo_root_type,
                transaction_type='cash',
                tracks_weight=False,
                parent_id=None,
            )
            category = _ensure_account(
                account_number='2100',
                name='حسابات موردو ذهب',
                type=memo_root_type,
                transaction_type='cash',
                tracks_weight=False,
                parent_id=category_210.id,
            )

        # If the resolved category is 210, normalize to 2100.
        category = _resolve_supplier_posting_category(category)
        if category and supplier.account_category_id != category.id:
            supplier.account_category_id = category.id
            db.session.flush()

        if not category:
            raise ValueError('Supplier account_category is missing and no fallback category found')

        from account_number_generator import get_next_account_number, get_next_party_account_number

        category_digits = _digits_only(str(category.account_number))
        if len(category_digits) == 3:
            next_number = get_next_party_account_number(category_digits)
        else:
            next_number = get_next_account_number(category_digits, use_spacing=False)
        financial = Account(
            account_number=_digits_only(next_number),
            name=supplier.name,
            type=category.type,
            transaction_type='cash',
            tracks_weight=False,
            parent_id=category.id,
        )
        db.session.add(financial)
        db.session.flush()
        supplier.account_id = financial.id
        db.session.flush()

    # If an existing account is valid but parented under 210 instead of 2100, normalize it.
    if financial and category and financial.parent_id != category.id:
        financial.parent_id = category.id
        db.session.flush()

    memo = _ensure_memo_account_for_financial(
        financial=financial,
        memo_root=memo_root,
        memo_name=f"{memo_root_name} - {supplier.name}",
    )

    return PartyAccounts(financial=financial, memo=memo)
