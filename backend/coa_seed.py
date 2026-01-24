from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from models import Account


def _derive_transaction_type(account_number: str, tracks_weight: bool) -> str:
    n = (account_number or '').strip()
    if n.startswith(('1W', '2W', '3W', '4W', '5W')):
        return 'gold'
    if n.startswith('7') and tracks_weight:
        return 'gold'
    return 'cash'


def _load_accounts_rows(file_path: Path) -> List[Dict[str, Any]]:
    raw = json.loads(file_path.read_text(encoding='utf-8'))

    if isinstance(raw, dict) and isinstance(raw.get('accounts'), list):
        return list(raw['accounts'])

    if isinstance(raw, dict):
        if isinstance(raw.get('data'), list):
            return list(raw['data'])
        if all(isinstance(v, dict) for v in raw.values()):
            return [dict(v) for v in raw.values()]

    if isinstance(raw, list):
        return [dict(v) for v in raw]

    raise ValueError('Unsupported JSON format for accounts')


def _normalize_rows(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    normalized: List[Dict[str, Any]] = []

    for r in rows:
        account_number = str(r.get('account_number') or '').strip()
        if not account_number:
            continue

        name = str(r.get('name') or '').strip()
        acc_type = str(r.get('type') or '').strip()
        tracks_weight = bool(r.get('tracks_weight', False) in (1, True, '1', 'true', 'True'))

        transaction_type = r.get('transaction_type')
        if not isinstance(transaction_type, str) or not transaction_type.strip():
            transaction_type = _derive_transaction_type(account_number, tracks_weight)
        transaction_type = transaction_type.strip()

        parent_num: Optional[str] = None
        for k in ('parent_account_number', 'parent_number'):
            if r.get(k) is not None:
                parent_num = str(r.get(k)).strip() or None
                break

        memo_num: Optional[str] = None
        for k in ('memo_account_number', 'memo_account'):
            if r.get(k) is not None:
                memo_num = str(r.get(k)).strip() or None
                break

        normalized.append({
            'account_number': account_number,
            'name': name,
            'type': acc_type,
            'transaction_type': transaction_type,
            'tracks_weight': tracks_weight,
            'bank_name': r.get('bank_name'),
            'account_number_external': r.get('account_number_external'),
            'account_type': r.get('account_type'),
            'parent_account_number': parent_num,
            'memo_account_number': memo_num,
        })

    present = {r['account_number'] for r in normalized}
    missing = []
    for r in normalized:
        p = r.get('parent_account_number')
        m = r.get('memo_account_number')
        if p and p not in present:
            missing.append((r['account_number'], 'parent_account_number', p))
        if m and m not in present:
            missing.append((r['account_number'], 'memo_account_number', m))
    if missing:
        details = '\n'.join([f'- {a} missing {k}={v}' for a, k, v in missing[:50]])
        raise ValueError(f'Missing references in seed payload (showing up to 50):\n{details}')

    normalized.sort(key=lambda x: (len(x['account_number']), x['account_number']))
    return normalized


def seed_chart_of_accounts_if_empty(db, file_path: str) -> int:
    """Seed the chart of accounts from JSON if the account table is empty.

    Returns number of created accounts (0 if nothing was done).
    """
    if Account.query.count() > 0:
        return 0

    path = Path(file_path).expanduser().resolve()
    if not path.exists():
        raise FileNotFoundError(f'COA seed file not found: {path}')

    rows_raw = _load_accounts_rows(path)
    rows = _normalize_rows(rows_raw)

    by_number: Dict[str, Account] = {}
    for r in rows:
        acc = Account(
            account_number=r['account_number'],
            name=r['name'],
            type=r['type'],
            transaction_type=r['transaction_type'],
            tracks_weight=bool(r['tracks_weight']),
        )
        acc.bank_name = r.get('bank_name')
        acc.account_number_external = r.get('account_number_external')
        acc.account_type = r.get('account_type')

        db.session.add(acc)
        by_number[r['account_number']] = acc

    db.session.flush()

    number_to_id = {n: a.id for n, a in by_number.items()}
    for r in rows:
        acc = by_number[r['account_number']]
        parent_num = r.get('parent_account_number')
        memo_num = r.get('memo_account_number')
        acc.parent_id = number_to_id.get(parent_num) if parent_num else None
        acc.memo_account_id = number_to_id.get(memo_num) if memo_num else None
        db.session.add(acc)

    db.session.commit()
    return len(rows)
