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


# ── TR-1b: the parties' accounts and the master data ─────────────────────────

# What an empty database seeds as it first starts, before 2026's settings say
# not to (app.py: ensure_default_payment_types) -- replaced by 2026's rows.
SEEDED_AT_START = ('payment_type',)

LEVEL_OF_LENGTH = {1: 1, 2: 2, 3: 3, 5: 4, 8: 5}
WIDTH = {2: 1, 3: 1, 4: 2, 5: 3}          # the digits a level adds (CHART-002)

# The tables carried, parents first; each one's columns that name an account,
# a 2026 account number, or a safe (whose ids are kept).
MASTER = (
    ('branch', {}), ('payment_type', {}), ('category', {}), ('item', {}),
    ('safe_box', {'account_id': 'account'}),       # a supplier names its safe (an office's deposit)
    ('customer', {'account_id': 'account', 'account_category_id': 'account'}),
    ('supplier', {'account_id': 'account', 'account_category_id': 'account', 'default_safe_box_id': 'safe'}),
    ('office', {'account_category_id': 'account'}),
    ('contribution_scheme', {}), ('contribution_component', {}),
    ('employee', {'account_id': 'account', 'gold_safe_box_id': 'safe', 'cash_safe_box_id': 'safe'}),
    ('employee_account', {'account_id': 'account'}),
    ('payment_method', {'default_safe_box_id': 'safe', 'settlement_bank_safe_box_id': 'safe',
                        'fee_expense_account_id': 'account'}),
    ('leave_type', {}), ('employee_document_type', {}), ('salary_structure', {}), ('bonus_rule', {}),
    ('dimension_definition', {}), ('dimension_value', {}), ('dimension_set', {}), ('dimension_set_item', {}),
    ('inventory_costing_config', {}), ('vat_policy_period', {}),
    ('supplier_settlement_policy', {}), ('supplier_settlement_reason_limit', {}),
    ('app_user', {}), ('users', {}),
    ('settings', {'main_cash_safe_box_id': 'safe', 'main_scrap_gold_safe_box_id': 'safe',
                  'sale_gold_safe_box_id': 'safe', 'stones_display_revenue_account_id': 'account',
                  'stones_pending_account_id': 'account', 'bonus_expense_account_number': 'number',
                  'bonus_payable_account_number': 'number'}),
)


def child_number(parent_number: str, siblings, *, weight: bool) -> str:
    """The next number under *parent_number* (CHART-002): a level's width
    after its siblings' last. A weight account's level is its financial
    number's (its number without the 7). Level 5 holds no child."""
    own = parent_number[1:] if weight else parent_number
    level = LEVEL_OF_LENGTH.get(len(own))
    if level is None or level >= 5:
        raise TransitionRefused(f'لا ابن تحت الحساب {parent_number}: المستوى الخامس آخر المستويات')
    width = WIDTH[level + 1]
    taken = [int(n[len(parent_number):]) for n in siblings
             if n.startswith(parent_number) and len(n) == len(parent_number) + width]
    return parent_number + str(max(taken + [0]) + 1).zfill(width)


class _Accounts:
    """2026 account id -> 2027 account id: a template account by its number;
    any other a carried row names (a party's, a custody's, a deposit's) made
    under its parent's 2027 account at the next number, with its twin."""

    def __init__(self, conn):
        from sqlalchemy import text
        self.src = {r.id: r for r in conn.execute(text(
            'SELECT id, account_number, name, type, transaction_type, tracks_weight, parent_id, memo_account_id '
            'FROM account'))}
        self.new = numbering()
        self.map = {}
        self.created = []

    def _target(self, number):
        from models import Account
        return Account.query.filter_by(account_number=number).one()

    def _make(self, parent, row, *, weight):
        from models import Account, db
        siblings = [a.account_number for a in Account.query.filter_by(parent_id=parent.id)]
        account = Account(account_number=child_number(parent.account_number, siblings, weight=weight),
                          name=row.name, type=row.type, transaction_type=row.transaction_type,
                          tracks_weight=bool(row.tracks_weight), parent_id=parent.id)
        db.session.add(account)
        db.session.flush()
        self.created.append((row.account_number, account.account_number, row.name))
        return account

    def id(self, old_id):
        from account_pair_service import link_accounts
        from models import Account, db
        if old_id is None or old_id not in self.src:
            return None
        if old_id in self.map:
            return self.map[old_id]
        row = self.src[old_id]
        if row.account_number in self.new:
            self.map[old_id] = self._target(self.new[row.account_number]).id
            return self.map[old_id]
        twin = self.src.get(row.memo_account_id)
        if row.tracks_weight and twin is not None and not twin.tracks_weight:
            self.id(twin.id)                          # a twin is made with its financial account
            return self.map[old_id]
        parent = db.session.get(Account, self.id(row.parent_id)) if row.parent_id else None
        if parent is None:
            raise TransitionRefused(f'الحساب {row.account_number} «{row.name}» بلا أب في شجرة 2027')
        account = self._make(parent, row, weight=bool(row.tracks_weight))
        self.map[old_id] = account.id
        if twin is not None and not row.tracks_weight and parent.memo_account_id:
            from accounting.twins import twin_number
            memo = Account(account_number=twin_number(account.account_number), name=twin.name, type=twin.type,
                           transaction_type=twin.transaction_type, tracks_weight=True,
                           parent_id=parent.memo_account_id)
            db.session.add(memo)
            db.session.flush()
            link_accounts(account, memo, created_by=BY)
            self.map[twin.id] = memo.id
        return account.id


def _excluded(conn) -> dict:
    """What does not move (the owner, 6 Nov 2026: «اي موظف تم ايقافه لا ينتقل»):
    the stopped employees, their accounts, structures, users and custody
    safes. A custody safe of one holding a balance refuses, by name."""
    from sqlalchemy import text
    from models import CASH_CUSTOMER_NAMES
    employees = {r.id for r in conn.execute(text('SELECT id FROM employee WHERE NOT is_active'))}
    # one walk-in customer (the owner, 6 Nov 2026: «عميل نقدي واحد + الثلاثة»):
    # the first; the others, each with an account and no balance, stay behind
    cash = sorted(r.id for r in conn.execute(text('SELECT id, name FROM customer'))
                  if ' '.join(str(r.name or '').split()) in CASH_CUSTOMER_NAMES)
    duplicates = set(cash[1:])
    owing = conn.execute(text(
        'SELECT c.customer_code FROM customer c JOIN journal_entry_line l ON l.account_id = c.account_id '
        'JOIN journal_entry j ON j.id = l.journal_entry_id WHERE c.id = ANY(:ids) '
        'AND NOT COALESCE(l.is_deleted, false) AND NOT COALESCE(j.is_deleted, false) AND j.is_posted '
        'GROUP BY c.customer_code HAVING ABS(SUM(l.cash_debit - l.cash_credit)) > 0.005'),
        {'ids': list(duplicates) or [-1]}).fetchall()
    if owing:
        raise TransitionRefused(f'عميل نقدي مكرَّر عليه رصيد: {", ".join(r[0] for r in owing)} — يُحسم قبل الإقفال')
    safes = {sid for r in conn.execute(text('SELECT gold_safe_box_id, cash_safe_box_id FROM employee '
                                            'WHERE NOT is_active')) for sid in r if sid}
    held = conn.execute(text(
        'SELECT s.name, SUM(l.cash_debit - l.cash_credit), SUM(l.debit_18k - l.credit_18k), '
        'SUM(l.debit_21k - l.credit_21k), SUM(l.debit_22k - l.credit_22k), SUM(l.debit_24k - l.credit_24k) '
        'FROM safe_box s JOIN journal_entry_line l ON l.account_id = s.account_id '
        'JOIN journal_entry j ON j.id = l.journal_entry_id '
        'WHERE s.id = ANY(:ids) AND NOT COALESCE(l.is_deleted, false) AND NOT COALESCE(j.is_deleted, false) '
        'AND j.is_posted GROUP BY s.name'), {'ids': list(safes) or [-1]}).fetchall()
    for name, *amounts in held:
        if any(abs(float(a or 0)) > 0.0005 for a in amounts):
            raise TransitionRefused(f'عهدة «{name}» لموظف موقوف فيها رصيد: يُحسم قبل الإقفال')
    return {'employees': employees, 'safes': safes, 'customers': duplicates}


def _as_column(column, value):
    """A JSON value the 2026 database returns as a dict or list, written as
    the 2027 column holds it -- text, unless the column is JSON."""
    from sqlalchemy import JSON
    if isinstance(value, (dict, list)) and not isinstance(column.type, JSON):
        return json.dumps(value, ensure_ascii=False)
    return value


def _skip(table, row, ex) -> bool:
    if table == 'employee':
        return row['id'] in ex['employees']
    if table == 'customer':
        return row['id'] in ex['customers']
    if table in ('employee_account', 'salary_structure', 'app_user'):
        return row.get('employee_id') in ex['employees']
    if table == 'safe_box':
        return row['id'] in ex['safes']
    return False


def carry_master_data(source_engine, *, opens_on) -> dict:
    """The master data into the 2027 database, after its chart and roles:
    each row with its id, its accounts in 2027's, what does not move left
    out. *opens_on*: 2027's first day -- the gold's cost from it (ADR-042)."""
    from sqlalchemy import text
    from models import db

    new = numbering()
    carried, skipped = {}, {}
    with source_engine.connect() as conn:
        accounts = _Accounts(conn)
        ex = _excluded(conn)
        # parents first, by the model's own dependencies (a supplier names its
        # safe, an employee his bonus rule)
        order = [t.name for t in db.metadata.sorted_tables]
        for table, columns in sorted(MASTER, key=lambda tc: order.index(tc[0])):
            target = db.metadata.tables[table]
            present = db.session.execute(text(f'SELECT COUNT(*) FROM {table}')).scalar()
            if present and table in SEEDED_AT_START:
                db.session.execute(target.delete())      # the boot's defaults give way to 2026's own
            elif present:
                raise TransitionRefused(f'جدول {table} في قاعدة 2027 ليس فارغًا')
            rows = [dict(r._mapping) for r in conn.execute(text(f'SELECT * FROM {table} ORDER BY 1'))]
            out = []
            for row in rows:
                if _skip(table, row, ex):
                    skipped[table] = skipped.get(table, 0) + 1
                    continue
                for column, kind in columns.items():
                    value = row.get(column)
                    if value is None:
                        continue
                    if kind == 'account':
                        row[column] = accounts.id(value)
                    elif kind == 'number':
                        row[column] = new.get(str(value))
                    elif kind == 'safe' and value in ex['safes']:
                        row[column] = None
                if table == 'settings':
                    row['gold_cost_from'] = opens_on
                    row['disable_startup_bootstrap'] = True
                out.append({k: _as_column(target.c[k], v) for k, v in row.items() if k in target.c})
            if out:
                db.session.execute(target.insert(), out)
            carried[table] = len(out)
        db.session.flush()
        for table, _ in MASTER:           # the next id after the carried ones
            if carried.get(table):
                db.session.execute(text(
                    f"SELECT setval(pg_get_serial_sequence('{table}', 'id'), (SELECT MAX(id) FROM {table}))"))
    return {'carried': carried, 'skipped': skipped, 'accounts_made': accounts.created}


def carry_waiting(source_engine, *, year: int) -> dict:
    """TR-3: the year's approved opening into its database -- the count day's
    closing price and the riyals waiting then, from which the year's queue
    starts (services/weight_position.opening_lot). An opening not approved
    does not open a year."""
    from sqlalchemy import text
    from models import OpeningApproval, db

    with source_engine.connect() as conn:
        row = conn.execute(text('SELECT * FROM opening_approval WHERE year = :y'), {'y': year}).mappings().first()
    if row is None or not row['closing_price']:
        raise TransitionRefused(f'افتتاح {year} لم يُعتمد في قاعدة {year - 1}: لا يُنقل ما لم يعتمده المالك')
    if db.session.get(OpeningApproval, year) is not None:
        raise TransitionRefused(f'افتتاح {year} في القاعدة الجديدة من قبل')
    db.session.add(OpeningApproval(**{k: row[k] for k in ('year', 'approved_by', 'approved_at', 'count_day',
                                                          'closing_price', 'waiting_cash', 'to_gold_cash')}))
    db.session.flush()
    return {'count_day': row['count_day'], 'closing_price': row['closing_price'],
            'waiting_cash': row['waiting_cash'], 'to_gold_cash': row['to_gold_cash']}
