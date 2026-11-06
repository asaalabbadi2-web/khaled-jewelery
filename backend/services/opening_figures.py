"""A new year's opening figures, beside the closing books (ADR-044, TR-2).

The owner, 22 Oct 2026: 2027 opens «بورقة بيضاء» -- every figure as it is in
fact, from the count and the reconciliations, whatever 2026's books say; 6 Nov:
the figures by «شاشة افتتاح في النظام», empty until confirmed («فارغة حتى
تُؤكَّد»), entered by the manager and approved by the owner; a party's cash
either opens as gold on the party at the closing price of the count day, or
stays cash waiting to be closed («الاثنين معا»).

The rows are the books': each asset or liability account holding a balance,
its weight twin in its row -- so nothing is forgotten. What the count gives is
not a row: the counted stock safes and the gold stock's value (the count at
the market price, ADR-044 decision 2); nor are the customers' weight twins
(CUSTGOLD-001: no customer holds the shop's gold). Equity is the difference.
Read by tools/transition_2027.py on the year's first day.
"""
from __future__ import annotations

KARATS = (18, 21, 22, 24)
SOURCES = {'count': 'عدّ', 'statement': 'كشف', 'reconciliation': 'مطابقة', 'acknowledgment': 'إقرار',
           'other': 'أخرى'}
TREATMENTS = {'gold': 'ذهب على الطرف بسعر التسكير يوم الجرد', 'waiting': 'نقد ينتظر التسكير'}
PARTY_ROLES = ('customer_accounts_parent', 'supplier_accounts_parent', 'office_accounts_parent')


class OpeningRefused(ValueError):
    pass


def _two_places(value) -> float:
    v = float(value or 0.0)
    if abs(round(v, 2) - v) > 1e-9:
        raise OpeningRefused('الرقم بخانتين عشريتين')
    return round(v, 2)


def _accounts():
    """({row account id: [its account ids]}, {row id: Account}, party row ids)."""
    from accounting.chart_tree import CUSTOMER_RECEIVABLES_ROOT, role_account_id, subtree_ids, twin_id, \
        twin_subtree_ids
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    from models import Account, SafeBox

    candidates = set()
    for root in ('assets_root', 'liabilities_root'):
        candidates |= subtree_ids(role_account_id(root))
        twin = twin_id(role_account_id(root))
        if twin:
            candidates |= subtree_ids(twin)
    excluded = {s.account_id for s in SafeBox.query.filter(SafeBox.stock_location.isnot(None),
                                                           SafeBox.stock_location != 'deposit')}
    for role in ('gold_inventory_new', 'gold_inventory_scrap'):      # the count at the market price
        value = role_account_id(role)
        excluded |= {value, twin_id(value)} - {None}
    excluded |= twin_subtree_ids(CUSTOMER_RECEIVABLES_ROOT)
    candidates -= excluded

    accounts = {a.id: a for a in Account.query.filter(Account.id.in_(candidates))}
    rows = {}
    for a in accounts.values():
        own = a.memo_account_id if a.tracks_weight and a.memo_account_id in accounts else a.id
        rows.setdefault(own, []).append(a.id)
    parties = set()
    for role in PARTY_ROLES:
        parent = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, role)
        if parent:      # its parties, not the group itself (2100 holds lines of its own)
            parties |= subtree_ids(parent) - {parent}
    return rows, accounts, parties & set(rows)


def _books(ids) -> dict:
    """{account id: {'cash': .., 18: .., ...}} -- the posted lines."""
    from sqlalchemy import func

    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    sums = [func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit)]
    sums += [func.sum(getattr(JournalEntryLine, f'debit_{k}k') - getattr(JournalEntryLine, f'credit_{k}k'))
             for k in KARATS]
    out = {}
    for account_id, cash, *grams in (db.session.query(JournalEntryLine.account_id, *sums)
                                     .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                                     .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(ids or {-1}))
                                     .group_by(JournalEntryLine.account_id)):
        out[account_id] = {'cash': float(cash or 0.0), **{k: float(g or 0.0) for k, g in zip(KARATS, grams)}}
    return out


def _section(account, by_id) -> str:
    """Its group: the ancestor at the chart's third level."""
    from models import Account, db
    chain = [account]
    while chain[-1].parent_id:
        parent = by_id.get(chain[-1].parent_id) or db.session.get(Account, chain[-1].parent_id)
        chain.append(parent)
    return chain[-3].name if len(chain) >= 3 else chain[-1].name


def opening(year: int) -> dict:
    """The year's rows, its figures, what they differ by, and whether it is approved."""
    from models import OpeningApproval, OpeningFigure, db
    from pricing.karat_service import convert_to_main_karat

    rows_of, accounts, parties = _accounts()
    books = _books(list(accounts))
    figures = {f.account_id: f for f in OpeningFigure.query.filter_by(year=year)}
    out = []
    totals = {'cash': 0.0, 'grams': 0.0}
    for row_id, ids in rows_of.items():
        held = {'cash': 0.0, **{k: 0.0 for k in KARATS}}
        for i in ids:
            for key, v in books.get(i, {}).items():
                held[key] += v
        figure = figures.get(row_id)
        if figure is None and abs(held['cash']) < 0.005 and all(abs(held[k]) < 0.0005 for k in KARATS):
            continue
        account = accounts[row_id]
        row = {'account_id': row_id, 'number': account.account_number, 'name': account.name,
               'section': _section(account, accounts), 'party': row_id in parties,
               'books': {'cash': round(held['cash'], 2), **{str(k): round(held[k], 3) for k in KARATS}},
               'actual': None, 'difference': None}
        if figure is not None:
            actual = {'cash': figure.actual_cash, **{str(k): getattr(figure, f'actual_{k}k') for k in KARATS}}
            diff = {key: round(actual[key] - row['books'][key], 3) for key in actual}
            row.update(actual=actual, difference=diff, source=figure.source, treatment=figure.treatment,
                       note=figure.note, entered_by=figure.entered_by,
                       entered_at=figure.entered_at.isoformat() if figure.entered_at else None)
            totals['cash'] += diff['cash']
            totals['grams'] += sum(convert_to_main_karat(diff[str(k)], k) for k in KARATS)
        out.append(row)
    out.sort(key=lambda r: (r['section'], r['number']))
    approval = db.session.get(OpeningApproval, year)
    return {'year': year, 'rows': out, 'sources': SOURCES, 'treatments': TREATMENTS,
            'entered': sum(1 for r in out if r['actual'] is not None), 'total': len(out),
            # what equity takes: the figures less the books (ADR-044: equity is the difference)
            'difference': {'cash': round(totals['cash'], 2), 'grams': round(totals['grams'], 3)},
            'approved': None if approval is None else {'by': approval.approved_by,
                                                      'at': approval.approved_at.isoformat()}}


def enter(year: int, account_id: int, *, cash, karats: dict, source: str, treatment, note, by: str, now):
    """One account's figure, entered or entered again before the approval."""
    from models import OpeningApproval, OpeningFigure, db

    if db.session.get(OpeningApproval, year) is not None:
        raise OpeningRefused('الافتتاح معتمد: لا يُغيَّر رقم فيه')
    rows_of, _, parties = _accounts()
    if account_id not in rows_of:
        raise OpeningRefused('ليس حساب افتتاح: أصلًا أو التزامًا خارج ما يعطيه الجرد')
    if source not in SOURCES:
        raise OpeningRefused('اذكر مصدر الرقم: عدّ، أو كشف، أو مطابقة، أو إقرار، أو أخرى')
    cash = _two_places(cash)
    grams = {k: _two_places((karats or {}).get(str(k), (karats or {}).get(k, 0.0))) for k in KARATS}
    if account_id in parties and abs(cash) >= 0.005:
        if treatment not in TREATMENTS:
            raise OpeningRefused('رصيد الطرف النقدي: ذهب بسعر التسكير، أو نقد ينتظر التسكير')
    else:
        treatment = None
    figure = OpeningFigure.query.filter_by(year=year, account_id=account_id).first()
    if figure is None:
        figure = OpeningFigure(year=year, account_id=account_id)
        db.session.add(figure)
    figure.actual_cash = cash
    for k in KARATS:
        setattr(figure, f'actual_{k}k', grams[k])
    figure.source, figure.treatment, figure.note = source, treatment, (note or None)
    figure.entered_by, figure.entered_at = by, now
    db.session.flush()
    return figure


def approve(year: int, *, by: str, now):
    """The owner's approval: every row has its figure, then the year's figures lock."""
    from models import OpeningApproval, db

    if db.session.get(OpeningApproval, year) is not None:
        raise OpeningRefused('الافتتاح معتمد من قبل')
    state = opening(year)
    missing = state['total'] - state['entered']
    if missing:
        raise OpeningRefused(f'{missing} حسابًا بلا رقم فعلي: لا يُعتمد الافتتاح قبل أن يُؤكَّد كل رقم')
    approval = OpeningApproval(year=year, approved_by=by, approved_at=now)
    db.session.add(approval)
    db.session.flush()
    return approval
