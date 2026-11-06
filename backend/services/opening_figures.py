"""A new year's opening figures, beside the closing books (ADR-044, TR-2).

The owner, 22 Oct 2026: 2027 opens «بورقة بيضاء» -- every figure as it is in
fact, from the count and the reconciliations, whatever 2026's books say; 6 Nov:
the figures by «شاشة افتتاح في النظام», empty until confirmed («فارغة حتى
تُؤكَّد»), entered by the manager and approved by the owner; a party's cash
either opens as gold on the party at the closing price of the count day, or
stays cash waiting to be closed («الاثنين معا»). A supplier's does not: its
wages closed when recorded (ADR-048), and it stays cash (7 Nov: «اذا ضل له
اجور فتبقى نقديه ولا تسكر ذهب»).

TR-3: the approval freezes the count day's closing price -- the office's last
on 31 Dec (ADR-063), decision 9 -- and the sales' riyals waiting then
(ADR-048); a customer opening as gold owes his riyals at that price, and
they no longer wait. The next year's queue starts from them
(services/weight_position.opening_lot, decision 1: «تنتقل منتظرة بسعر الجرد»).

TR-4: the approval writes 2026's differences from the figures in 2026 at the
close (the owner, 7 Nov 2026: «في 2026 عند الإقفال»), onto the count's
accounts («حسابا الجرد»): short to 5220, over to 450, in riyals and in
grams -- 2026 closes on the figures, and 2027 opens on that closing
(ADR-044's law). A customer opening as gold is refused until its entry is
built (7 Nov: «يُؤجَّل»).

TR-4b: then the stock at the count day's market price (decision 2, no
office terms), with 2100's own balance -- owed twice -- and the riyals on a
pool's weight account cleared, the rest to «فروقات تقييم الذهب» (33): ADR-042's
entry, its pools at that price (the owner, 7 Nov: «إلى 33 مع التقييم»). 2100
itself is no row: that entry clears it.

The rows are the books': each asset or liability account holding a balance,
its weight twin in its row -- so nothing is forgotten. What the count gives is
not a row: the counted stock safes and the gold stock's value (the count at
the market price, ADR-044 decision 2); nor are the customers' weight twins
(CUSTGOLD-001: no customer holds the shop's gold). Equity is the difference.
Read by tools/transition_2027.py on the year's first day.
"""
from __future__ import annotations

import datetime as dt

KARATS = (18, 21, 22, 24)
SOURCES = {'count': 'عدّ', 'statement': 'كشف', 'reconciliation': 'مطابقة', 'acknowledgment': 'إقرار',
           'other': 'أخرى'}
TREATMENTS = {'gold': 'ذهب على الطرف بسعر التسكير يوم الجرد', 'waiting': 'نقد ينتظر التسكير'}
# Whose cash asks gold or waiting: a customer's only. A supplier's stays cash
# (7 Nov 2026), and an office is a supplier, its account under the suppliers'
# (office.supplier_id; 2100020 مكتب الديوان) -- its purchase closed the riyals.
PARTY_ROLES = ('customer_accounts_parent',)


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
    # the suppliers' control account's own balance: the close clears it to 33 (TR-4b)
    control = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, 'supplier_accounts_parent')
    excluded |= {control} - {None}
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


def _number(entry_id):
    from models import JournalEntry, db
    return db.session.get(JournalEntry, entry_id).entry_number if entry_id else None


def market_price(day: dt.date) -> float:
    """The market's price per gram of the main karat at *day*'s end -- the
    ounce, no office fees or discount (decision 2); 0 before any price."""
    from models import GoldPrice
    from pricing.gold_price_service import get_main_karat
    from pricing.office_price import gram_price
    row = (GoldPrice.query.filter(GoldPrice.date <= dt.datetime.combine(day, dt.time.max))
           .order_by(GoldPrice.date.desc(), GoldPrice.id.desc()).first())
    return gram_price(row.price, int(get_main_karat()), None) if row is not None else 0.0


def opening(year: int) -> dict:
    """The year's rows, its figures, what they differ by, and whether it is approved."""
    from models import OpeningApproval, OpeningFigure, db
    from pricing.karat_service import convert_to_main_karat
    from services.weight_position import carried_cash

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
               'actual': None, 'difference': None, 'gold_grams': None}
        if figure is not None:
            actual = {'cash': figure.actual_cash, **{str(k): getattr(figure, f'actual_{k}k') for k in KARATS}}
            diff = {key: round(actual[key] - row['books'][key], 3) for key in actual}
            row.update(actual=actual, difference=diff, source=figure.source, treatment=figure.treatment,
                       note=figure.note, entered_by=figure.entered_by, gold_grams=figure.gold_grams,
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
            'approved': None if approval is None else {
                'by': approval.approved_by, 'at': approval.approved_at.isoformat(),
                'count_day': approval.count_day.isoformat() if approval.count_day else None,
                'closing_price': approval.closing_price, 'waiting_cash': approval.waiting_cash,
                'to_gold_cash': approval.to_gold_cash,
                'carried_cash': (carried_cash(approval.waiting_cash, approval.to_gold_cash)
                                 if approval.closing_price else None),
                'reconciliation_entry': _number(approval.reconciliation_entry_id),
                'market_price': approval.market_price,
                'revaluation_entry': _number(approval.revaluation_entry_id)}}


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


def count_day(year: int) -> dt.date:
    """The count: the last day of the year before (ADR-044, «جرد 31 ديسمبر»)."""
    return dt.date(year - 1, 12, 31)


def approve(year: int, *, by: str, now):
    """The owner's approval: every row has its figure, then the year's
    figures lock -- and with them the count day's closing price, the riyals
    waiting then, and each party opening as gold, in grams at that price."""
    from models import OpeningApproval, OpeningFigure, db
    from services.weight_position import _replayed, office_prices

    if db.session.get(OpeningApproval, year) is not None:
        raise OpeningRefused('الافتتاح معتمد من قبل')
    state = opening(year)
    missing = state['total'] - state['entered']
    if missing:
        raise OpeningRefused(f'{missing} حسابًا بلا رقم فعلي: لا يُعتمد الافتتاح قبل أن يُؤكَّد كل رقم')
    as_gold = [r['name'] for r in state['rows'] if r.get('treatment') == 'gold']
    if as_gold:
        raise OpeningRefused('قيد تحويل نقد العميل إلى ذهب لم يُبنَ بعد (قرار المالك 7 نوفمبر: يُؤجَّل): '
                             + '، '.join(as_gold) + ' — اجعله «نقد ينتظر التسكير» أو اطلب بناءه')
    day = count_day(year)
    price, _ = office_prices(day)(day)
    if not price:
        raise OpeningRefused(f'لا سعر تسكير يوم الجرد {day}: لا يُعتمد الافتتاح بلا سعره')
    price = round(price, 4)
    waiting = round(sum(lot.cash_open for lot in _replayed(day).open_lots), 2)
    gold = [f for f in OpeningFigure.query.filter_by(year=year, treatment='gold')]
    to_gold = round(sum(f.actual_cash for f in gold), 2)
    # More turned to gold than waits is no fault: a credit sale's riyals may
    # have closed already from the cash in hand while the customer still owes
    # them -- a closing past the queue, unmatched (ADR-048); the year starts
    # with nothing waiting (weight_position.opening_lot).
    for f in gold:
        f.gold_grams = round(f.actual_cash / price, 3)
    market = round(market_price(day), 4)
    if not market:
        raise OpeningRefused(f'لا سعر سوق يوم الجرد {day}: لا يُقيَّم المخزون بلا سعره')
    entry = _write_differences(year, state['rows'], day=day, by=by, now=now)
    revaluation = _write_revaluation(year, day=day, market=market, by=by, now=now)
    approval = OpeningApproval(year=year, approved_by=by, approved_at=now, count_day=day,
                               closing_price=price, waiting_cash=waiting, to_gold_cash=to_gold,
                               reconciliation_entry_id=entry.id if entry is not None else None,
                               market_price=market,
                               revaluation_entry_id=revaluation.id if revaluation is not None else None)
    db.session.add(approval)
    db.session.flush()
    return approval


def _write_revaluation(year: int, *, day, market: float, by: str, now):
    """ADR-042's entry at the close, its pools at *market*: 1300 and 1310 to
    each pool's weight x the price, 2100's own balance and a pool weight
    account's riyals cleared, the rest to 33 -- after the differences, on the
    count day's last minute. None when nothing moves."""
    from models import Account
    from services.gold_cost_books import plan_transition
    from services.repair.entries import write_entry
    plan = plan_transition(opening_price=market, at=day + dt.timedelta(days=1), valued_at=market)
    if not plan['lines']:
        return None
    ids = dict(Account.query.with_entities(Account.account_number, Account.id)
               .filter(Account.account_number.in_(list(plan['lines']))).all())
    description = f'تقييم مخزون الذهب بسعر سوق يوم الجرد {day} ({market:,.4f}) — إقفال {year - 1} (ADR-044، ADR-042)'
    return write_entry(
        date=dt.datetime.combine(day, dt.time(23, 59)), description=description,
        reference_type='opening_revaluation', reference_id=year, reference_number=f'{day}@{market:.4f}',
        lines=[{'account_id': ids[number], 'description': description,
                **({'cash_debit': amount} if amount > 0 else {'cash_credit': -amount})}
               for number, amount in sorted(plan['lines'].items())],
        by=by, now=now, prefix='COR', safe_rows=False)


def _write_differences(year: int, rows: list, *, day, by: str, now):
    """One entry on the count day's last minute: each row's figure less its
    books onto its accounts -- the riyals on its own, the grams on its weight
    twin -- and the other side on the count's: short to 5220, over to 450
    (InventoryAccountingService, the count's roles). None when nothing differs."""
    from accounting.mappings import get_account_id_for_mapping
    from accounting.reference_number_service import generate_journal_entry_number
    from dimensions_service import compute_line_analytics
    from models import JournalEntry, JournalEntryLine, db
    from pricing.karat_service import convert_to_main_karat
    from services.inventory_accounting_service import ROLE_SHORTAGE, ROLE_SURPLUS, InventoryAccountingService
    from services.repair.entries import write_safe_rows

    rows_of, _, _ = _accounts()
    specs = []
    description = f'فروق مطابقة إقفال {year - 1} — أرقام افتتاح {year} المعتمدة'
    roles = {}

    def role(name, weight):
        if (name, weight) not in roles:
            if weight:
                roles[(name, weight)] = InventoryAccountingService._weight_account(name)
            else:
                account_id = get_account_id_for_mapping('افتراضي', name)
                if not account_id:
                    raise OpeningRefused(f'حساب «{name}» غير مربوط في الربط المحاسبي: يُضبط قبل الاعتماد')
                roles[(name, weight)] = account_id
        return roles[(name, weight)]

    def cash(account_id, amount):
        return dict(account_id=account_id, description=description, **(
            {'cash_debit': amount} if amount > 0 else {'cash_credit': -amount}))

    def grams(account_id, karat, amount):
        main = round(convert_to_main_karat(abs(amount), karat), 6)
        return dict(account_id=account_id, description=description, **(
            {f'debit_{karat}k': amount, 'debit_weight': main} if amount > 0
            else {f'credit_{karat}k': -amount, 'credit_weight': main}))

    for row in rows:
        diff = row['difference'] or {}
        own = row['account_id']
        weight = next((i for i in rows_of.get(own, ()) if i != own), own)    # its twin, or itself
        moved = round(diff.get('cash', 0.0), 2)
        if abs(moved) >= 0.005:
            specs.append(cash(own, moved))
            specs.append(cash(role(ROLE_SURPLUS if moved > 0 else ROLE_SHORTAGE, False), -moved))
        for k in KARATS:
            moved = round(diff.get(str(k), 0.0), 3)
            if abs(moved) >= 0.0005:
                specs.append(grams(weight, k, moved))
                specs.append(grams(role(ROLE_SURPLUS if moved > 0 else ROLE_SHORTAGE, True), k, -moved))
    if not specs:
        return None
    when = dt.datetime.combine(day, dt.time(23, 59))
    entry = JournalEntry(entry_number=generate_journal_entry_number('JE', entry_date=when), date=when,
                         description=description, entry_type='عادي', reference_type='opening_reconciliation',
                         reference_id=year, is_posted=True, is_draft=False, posted_at=now, posted_by=by,
                         created_by=by)
    db.session.add(entry)
    db.session.flush()
    for spec in specs:
        line = JournalEntryLine(journal_entry_id=entry.id, **spec)
        line.analytic_amount_cash, line.analytic_weight_24k, line.analytic_weight_main = \
            compute_line_analytics(db.session, line)
        db.session.add(line)
    db.session.flush()
    write_safe_rows(entry, specs, by, ref_type='opening_reconciliation')
    return entry
