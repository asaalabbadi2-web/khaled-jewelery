"""The move to 2027's database (ADR-044 phase 4) -- TR-1a: the chart and its roles.

The owner, 12 Oct 2026: «سنة 2027 سنبدأ بصفحة بيضاء» -- a new database; 22 Oct:
«نسخة نظيفة ومنظمة لـ2027» and its numbering «اعتمد»; 6 Nov: the ten accounts
made since added, eight left (docs/plans/fy2027-transition-tool-discovery.md).

Run with the application on the 2027 database (empty: its schema, no account)
and 2026's closed database read through its own connection, never written:

- chart_rows(): the 2027 template (docs/chart/chart-of-accounts-2027.json) in
  2027's numbers (docs/chart/numbering-2027.json) -- each parent and twin by
  its new number;
- role_rows(): each role of 2026 on its account's 2027 number; a role whose
  account 2027 has not is said, by name;
- build_chart_and_roles(): both written into the 2027 database, in the
  caller's transaction. The parties' accounts and the master data are TR-1b.
"""
from __future__ import annotations

import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
TEMPLATE = os.path.join(ROOT, 'docs', 'chart', 'chart-of-accounts-2027.json')
NUMBERING = os.path.join(ROOT, 'docs', 'chart', 'numbering-2027.json')
BY = 'transition_2027'


class TransitionRefused(ValueError):
    pass


def _load(path):
    with open(path, encoding='utf-8') as fh:
        return json.load(fh)


def numbering() -> dict:
    """{2026 number: 2027 number} as the owner approved it."""
    return _load(NUMBERING)['old_to_new']


def chart_rows() -> list:
    """The template's accounts in 2027's numbers."""
    new = numbering()
    rows = []
    for a in _load(TEMPLATE)['accounts']:
        row = dict(a)
        row['account_number'] = new[a['account_number']]
        for key in ('parent_account_number', 'memo_account_number'):
            if a.get(key):
                row[key] = new[a[key]]
        rows.append(row)
    return rows


def role_rows(mappings) -> tuple:
    """*mappings*: (operation, role, 2026 account number, active) of 2026.
    Returns ([(operation, role, 2027 number, active)], [(operation, role, 2026
    number)] that 2027's chart has not)."""
    new = numbering()
    rows, unmapped = [], []
    for operation, role, number, active in mappings:
        if number in new:
            rows.append((operation, role, new[number], bool(active)))
        else:
            unmapped.append((operation, role, number))
    return rows, unmapped


def source_mappings(source_engine) -> list:
    """2026's roles, each with its account's number -- read only."""
    from sqlalchemy import text
    with source_engine.connect() as conn:
        return [tuple(r) for r in conn.execute(text(
            'SELECT m.operation_type, m.account_type, a.account_number, m.is_active '
            'FROM accounting_mapping m JOIN account a ON a.id = m.account_id '
            'ORDER BY m.account_type, m.operation_type'))]


def build_chart_and_roles(source_engine) -> dict:
    """The 2027 chart and its roles into the (empty) 2027 database. Refuses a
    database that holds an account. The caller commits."""
    from coa_seed import seed_rows
    from models import Account, AccountingMapping, db

    if Account.query.count():
        raise TransitionRefused('قاعدة 2027 ليست فارغة: فيها حسابات')
    created = seed_rows(db, chart_rows(), created_by=BY)
    ids = {a.account_number: a.id for a in Account.query.all()}
    rows, unmapped = role_rows(source_mappings(source_engine))
    for operation, role, number, active in rows:
        db.session.add(AccountingMapping(operation_type=operation, account_type=role,
                                         account_id=ids[number], is_active=active))
    db.session.flush()
    return {'accounts': created, 'roles': len(rows), 'unmapped': unmapped}
