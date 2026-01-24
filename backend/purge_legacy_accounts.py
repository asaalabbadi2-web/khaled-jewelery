#!/usr/bin/env python3
"""Purge legacy Chart-of-Accounts nodes from the database.

Deletes specific account numbers and anything under them (by parent_id), plus
memo/weight counterparts ("7" + financial) and any memo-linked pairs.

Safety:
- Default is dry-run (no DB changes).
- Creates a SQLite backup by default when using sqlite file DB.
- Refuses to delete accounts referenced by JournalEntryLine, SafeBox,
  AccountingMapping, or Invoice.wage_inventory_account_id.
- Refuses to delete accounts referenced by Employee.account_id unless
  --force-unlink-employees is provided.

Usage (from backend/):
  ./venv/bin/python purge_legacy_accounts.py --dry-run
  ./venv/bin/python purge_legacy_accounts.py --yes

Optional:
  DATABASE_URL=sqlite:///app.db ./venv/bin/python purge_legacy_accounts.py --yes
"""

from __future__ import annotations

import argparse
import os
import shutil
from dataclasses import dataclass
from datetime import datetime
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple


LEGACY_FINANCIAL_ROOTS = ("1400", "2390", "2391", "2392")


@dataclass(frozen=True)
class AccountRow:
    id: int
    account_number: str
    name: str
    parent_id: Optional[int]
    memo_account_id: Optional[int]


def _compute_memo_number(financial_number: str) -> str:
    return f"7{financial_number}"


def _sqlite_file_from_url(database_url: str, base_dir: str) -> Optional[str]:
    url = (database_url or "").strip()
    if not url.lower().startswith("sqlite:"):
        return None

    # Supported patterns:
    # - sqlite:///relative/path.db
    # - sqlite:////absolute/path.db
    # - sqlite:// (in-memory or invalid)
    if url.lower().startswith("sqlite:////"):
        path = url[len("sqlite:////") :]
        if not path.startswith("/"):
            path = f"/{path}"
        return path

    if url.lower().startswith("sqlite:///"):
        rel = url[len("sqlite:///") :]
        # Treat as relative to backend directory.
        return os.path.abspath(os.path.join(base_dir, rel))

    return None


def _backup_sqlite(db_file: str) -> Optional[str]:
    if not db_file or not os.path.exists(db_file):
        return None

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = f"{db_file}.backup_{ts}"
    shutil.copy2(db_file, backup_path)
    return backup_path


def _build_children_map(accounts: Sequence[AccountRow]) -> Dict[Optional[int], List[int]]:
    children: Dict[Optional[int], List[int]] = {}
    for a in accounts:
        children.setdefault(a.parent_id, []).append(a.id)
    return children


def _collect_descendants(root_ids: Iterable[int], children_map: Dict[Optional[int], List[int]]) -> Set[int]:
    visited: Set[int] = set()
    stack: List[int] = list(root_ids)
    while stack:
        current = stack.pop()
        if current in visited:
            continue
        visited.add(current)
        for child_id in children_map.get(current, []):
            if child_id not in visited:
                stack.append(child_id)
    return visited


def _expand_with_memo_links(
    ids: Set[int],
    accounts_by_id: Dict[int, AccountRow],
    memo_reverse: Dict[int, List[int]],
) -> Set[int]:
    # Closure over both directions:
    # - include memo_account_id targets
    # - include financial accounts pointing to a memo account
    expanded = set(ids)
    changed = True
    while changed:
        changed = False
        for account_id in list(expanded):
            row = accounts_by_id.get(account_id)
            if not row:
                continue

            if row.memo_account_id and row.memo_account_id not in expanded:
                expanded.add(row.memo_account_id)
                changed = True

            for rev_id in memo_reverse.get(account_id, []):
                if rev_id not in expanded:
                    expanded.add(rev_id)
                    changed = True

    return expanded


def _postorder_delete_ids(children_map: Dict[Optional[int], List[int]], ids: Set[int]) -> List[int]:
    # Postorder DFS so children are deleted before parents.
    result: List[int] = []
    temp_mark: Set[int] = set()
    perm_mark: Set[int] = set()

    def visit(node: int) -> None:
        if node in perm_mark:
            return
        if node in temp_mark:
            # Cycle shouldn't happen; ignore.
            return
        temp_mark.add(node)
        for child in children_map.get(node, []):
            if child in ids:
                visit(child)
        temp_mark.remove(node)
        perm_mark.add(node)
        result.append(node)

    for node in list(ids):
        visit(node)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Purge legacy accounts and memo equivalents.")
    parser.add_argument(
        "--database-url",
        default=None,
        help="Override DATABASE_URL for this run (otherwise uses env/app default).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Show what would be deleted (default behavior unless --yes).",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        default=False,
        help="Apply deletion to the database.",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        default=False,
        help="Do not create a SQLite backup before deletion.",
    )
    parser.add_argument(
        "--force-unlink-employees",
        action="store_true",
        default=False,
        help="If any employees are linked to these accounts, set employee.account_id=NULL.",
    )
    args = parser.parse_args()

    base_dir = os.path.abspath(os.path.dirname(__file__))

    if args.database_url:
        os.environ["DATABASE_URL"] = args.database_url

    # Import app + db after DATABASE_URL override.
    try:
        from app import app  # type: ignore
        from models import AccountingMapping, Account, Employee, Invoice, JournalEntryLine, SafeBox, db  # type: ignore
    except Exception as exc:
        print(f"Failed to import backend app/models: {exc}")
        return 2

    apply_changes = bool(args.yes)
    dry_run = bool(args.dry_run) or not apply_changes

    database_url = (
        (args.database_url or os.getenv("DATABASE_URL") or app.config.get("SQLALCHEMY_DATABASE_URI") or "")
    ).strip()

    if apply_changes:
        print("Mode: APPLY (will delete)")
    else:
        print("Mode: DRY-RUN (no changes)")

    print(f"Database: {database_url}")

    sqlite_file = _sqlite_file_from_url(database_url, base_dir)
    backup_path = None

    if apply_changes and (not args.no_backup) and sqlite_file:
        backup_path = _backup_sqlite(sqlite_file)
        if backup_path:
            print(f"SQLite backup created: {backup_path}")

    financial_roots = set(LEGACY_FINANCIAL_ROOTS)
    memo_roots = {_compute_memo_number(n) for n in financial_roots}

    def _is_target_account_number(account_number: str) -> bool:
        num = (account_number or "").strip()
        if not num:
            return False
        # Match both exact nodes (e.g. 1400) and padded variants (e.g. 1400000)
        # used by some legacy data/seed paths.
        for root in financial_roots:
            if num == root or num.startswith(root):
                return True
        for root in memo_roots:
            if num == root or num.startswith(root):
                return True
        return False

    with app.app_context():
        rows: List[AccountRow] = [
            AccountRow(
                id=a.id,
                account_number=str(a.account_number),
                name=str(a.name),
                parent_id=a.parent_id,
                memo_account_id=a.memo_account_id,
            )
            for a in Account.query.with_entities(
                Account.id,
                Account.account_number,
                Account.name,
                Account.parent_id,
                Account.memo_account_id,
            ).all()
        ]

        accounts_by_id: Dict[int, AccountRow] = {a.id: a for a in rows}
        children_map = _build_children_map(rows)
        memo_reverse: Dict[int, List[int]] = {}
        for a in rows:
            if a.memo_account_id:
                memo_reverse.setdefault(a.memo_account_id, []).append(a.id)

        root_ids = [a.id for a in rows if _is_target_account_number(a.account_number)]
        if not root_ids:
            print("No matching root accounts found. Nothing to do.")
            return 0

        ids = _collect_descendants(root_ids, children_map)
        ids = _expand_with_memo_links(ids, accounts_by_id, memo_reverse)

        # Also include descendants starting at any additional prefix matches.
        ids |= _collect_descendants(root_ids, children_map)

        delete_rows = [accounts_by_id[i] for i in ids if i in accounts_by_id]
        delete_rows.sort(key=lambda r: (len(r.account_number), r.account_number))

        print(f"Found {len(delete_rows)} accounts to delete (including descendants and memo links).")
        for r in delete_rows[:60]:
            print(f" - {r.account_number} | {r.name} | id={r.id}")
        if len(delete_rows) > 60:
            print(f" ... and {len(delete_rows) - 60} more")

        # Safety checks
        jel_count = JournalEntryLine.query.filter(JournalEntryLine.account_id.in_(ids)).count()
        safebox_count = SafeBox.query.filter(SafeBox.account_id.in_(ids)).count()
        mapping_count = AccountingMapping.query.filter(AccountingMapping.account_id.in_(ids)).count()
        invoice_wage_count = Invoice.query.filter(Invoice.wage_inventory_account_id.in_(ids)).count()
        employee_count = Employee.query.filter(Employee.account_id.in_(ids)).count()

        blockers: List[str] = []
        if jel_count:
            blockers.append(f"JournalEntryLine references: {jel_count}")
        if safebox_count:
            blockers.append(f"SafeBox references: {safebox_count}")
        if mapping_count:
            blockers.append(f"AccountingMapping references: {mapping_count}")
        if invoice_wage_count:
            blockers.append(f"Invoice.wage_inventory_account_id references: {invoice_wage_count}")
        if employee_count and (not args.force_unlink_employees):
            blockers.append(f"Employee.account_id references: {employee_count} (use --force-unlink-employees)")

        if blockers:
            print("\nRefusing to delete due to references:")
            for b in blockers:
                print(f" - {b}")
            if apply_changes:
                print("No changes applied.")
            return 3

        if dry_run:
            print("\nDry-run complete. Re-run with --yes to apply.")
            return 0

        # Unlink employees if requested and needed.
        if employee_count and args.force_unlink_employees:
            updated = Employee.query.filter(Employee.account_id.in_(ids)).update(
                {Employee.account_id: None}, synchronize_session=False
            )
            print(f"Unlinked employees: {updated}")

        # Nullify memo links from accounts NOT being deleted.
        remaining_memo_links = (
            Account.query.filter(Account.memo_account_id.in_(ids))
            .filter(~Account.id.in_(ids))
            .update({Account.memo_account_id: None}, synchronize_session=False)
        )
        if remaining_memo_links:
            print(f"Cleared memo links from remaining accounts: {remaining_memo_links}")

        # Delete accounts in child-first order.
        delete_order = _postorder_delete_ids(children_map, ids)
        deleted = 0
        for account_id in delete_order:
            acc = db.session.get(Account, account_id)
            if not acc:
                continue
            db.session.delete(acc)
            deleted += 1

        db.session.commit()
        print(f"Deleted accounts: {deleted}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
