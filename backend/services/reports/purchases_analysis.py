"""Purchases analysis: the period's purchases and their returns by kind, party, employee, day, month or karat (REPORTS ت4-4أ, ADR-083).

The owner, 4 Nov 2026: a purchase's value is what keeps the income statement
sound -- the books' riyals, and the grams beside. From the documents -- the
posted purchases and purchase returns, not withdrawn:
  * a customer's purchase (شراء من عميل), or an office's (شراء naming its
    office: a reservation's execution), is its price before VAT -- the books
    keep it on the purchase roles' accounts (512 scrap, 511 new);
  * a supplier's purchase (شراء) is its wage before VAT -- the books keep it
    on the wage inventory (1320); its gold is a debt in grams, never riyals
    (Invoice.cash_obligation's own rule);
  * a return takes its own off: its price (513, purchase_returns), or a
    supplier return's wage.
Its grams are the document's in the main karat (_invoice_weight_in_main_karat);
by karat, its lines' -- their grams, the value shared by them.
Against sales (ت4-4ب, the old «اتجاه المبيعات مقابل المشتريات»): by day,
month, karat or employee -- the dimensions the sales analysis shares -- each
group says the sales of the same group, their riyals and grams, and the chart
draws both; by kind or party it says it does not apply.
And checked against the books: what it sums is the net debit on the purchase
roles' accounts in its period, plus the wage inventory's net debit from the
purchases' and their returns' own entries. On the 2 Nov copy October agrees
to the halala: 512 1,053,167.59, 513 -11,250.00, 1320 26,693.98 -- and July
to October each month. Before July the books kept purchases otherwise (a
January balance correction on 512; February to April a customer's scrap on
the scrap stock 1310, a supplier's gold valued in riyals on 1300, an office's
cash on a weight account): those months say they do not agree, and by how
much -- the books' history, not the report's to rewrite.
"""
from __future__ import annotations

import collections
import datetime as dt

from services.reports.contract import Chart, Check, Column, Report
from services.reports.sales_analysis import _bounds, previous_period

BY = ('kind', 'party', 'employee', 'day', 'month', 'karat')
AGAINST_SALES = ('employee', 'day', 'month', 'karat')    # the dimensions the sales analysis shares
CUSTOMER, SUPPLIER, CUSTOMER_RETURN, SUPPLIER_RETURN = 'شراء من عميل', 'شراء', 'مرتجع شراء', 'مرتجع شراء (مورد)'
TYPES = (CUSTOMER, SUPPLIER, CUSTOMER_RETURN, SUPPLIER_RETURN)
KINDS = {'customer': 'من العملاء', 'office': 'من المكاتب', 'supplier': 'من الموردين'}
# what the books keep the purchases' riyals on: these roles' accounts, net
PURCHASE_ROLES = ((CUSTOMER, 'purchases_gold'), (CUSTOMER, 'purchases_gold_new'), (CUSTOMER, 'purchases_gold_scrap'),
                  (SUPPLIER, 'purchases_gold'), (CUSTOMER_RETURN, 'purchase_returns'),
                  (SUPPLIER_RETURN, 'purchase_returns'))
WAGE_ROLE = (SUPPLIER, 'manufacturing_wage_inventory')


def _kind(inv) -> str:
    if inv.office_id:
        return 'office'
    return 'supplier' if inv.invoice_type in (SUPPLIER, SUPPLIER_RETURN) else 'customer'


def _riyals(inv) -> float:
    """The books' riyals of one purchase, before VAT, unsigned -- to the halala,
    as its entry posts it (an office's total can carry 42,574.99999683)."""
    if _kind(inv) == 'supplier':
        return round(float(inv.wage_subtotal or 0.0), 2)
    return round(float(inv.total or 0.0) - float(inv.total_tax or 0.0), 2)


def _documents(start, end) -> list:
    """(invoice, sign, riyals, grams) for the period's posted purchases and returns, not withdrawn."""
    from models import Invoice, db
    from routes import _invoice_weight_in_main_karat
    from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES
    from services.weight_position import _with_weight_lines
    lo, hi = _bounds(start, end)
    query = (_with_weight_lines(Invoice.query)
             .filter(Invoice.is_posted.is_(True), Invoice.invoice_type.in_(TYPES))
             .filter(db.func.coalesce(Invoice.status, '').notin_(list(RETRACTED_INVOICE_STATUSES))))
    if lo is not None:
        query = query.filter(Invoice.date >= lo)
    if hi is not None:
        query = query.filter(Invoice.date < hi)
    out = []
    for inv in query.order_by(Invoice.date, Invoice.id).all():
        sign = -1 if inv.invoice_type in (CUSTOMER_RETURN, SUPPLIER_RETURN) else 1
        out.append((inv, sign, sign * _riyals(inv), sign * float(_invoice_weight_in_main_karat(inv) or 0.0)))
    return out


def _books(start, end) -> float:
    """The purchase roles' accounts' net debit, and the wage inventory's from the purchases' own entries."""
    from accounting.balances import counted_line_filters
    from accounting.mappings import get_account_id_for_mapping
    from models import Invoice, JournalEntry, JournalEntryLine, db
    lo, hi = _bounds(start, end)

    def net(accounts, *where):
        query = (db.session.query(db.func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit))
                 .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
                 .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(accounts or {-1}), *where))
        if lo is not None:
            query = query.filter(JournalEntry.date >= lo)
        if hi is not None:
            query = query.filter(JournalEntry.date < hi)
        return float(query.scalar() or 0.0)

    purchases = {get_account_id_for_mapping(op, role) for op, role in PURCHASE_ROLES} - {None}
    wage = get_account_id_for_mapping(*WAGE_ROLE)
    theirs = (db.session.query(Invoice.id).filter(Invoice.invoice_type.in_(TYPES)))
    return net(purchases) + (net({wage}, JournalEntry.reference_type == 'invoice',
                                 JournalEntry.reference_id.in_(theirs)) if wage else 0.0)


def _names(documents) -> dict:
    from models import Customer, Employee, Office, Supplier
    ids = collections.defaultdict(set)
    for inv, *_ in documents:
        for key in ('customer_id', 'supplier_id', 'office_id', 'employee_id'):
            if getattr(inv, key):
                ids[key].add(getattr(inv, key))
    return {'customer': {c.id: c.name for c in Customer.query.filter(Customer.id.in_(ids['customer_id'] or {-1}))},
            'supplier': {s.id: s.name for s in Supplier.query.filter(Supplier.id.in_(ids['supplier_id'] or {-1}))},
            'office': {o.id: o.name for o in Office.query.filter(Office.id.in_(ids['office_id'] or {-1}))},
            'employee': {e.id: e.name for e in Employee.query.filter(Employee.id.in_(ids['employee_id'] or {-1}))}}


def _parts(documents, by, names):
    """(document, sign, group id, label, drill, riyals, grams): a document whole,
    or by karat its lines -- their grams, its riyals shared by them."""
    from pricing.gold_price_service import get_main_karat
    main = float(get_main_karat()) if by == 'karat' else None
    for inv, sign, value, grams in documents:
        if by == 'kind':
            kind = _kind(inv)
            yield inv, sign, kind, KINDS[kind], None, value, grams
        elif by == 'party':
            for kind, attr in (('office', 'office_id'), ('supplier', 'supplier_id'), ('customer', 'customer_id')):
                party = getattr(inv, attr)
                if party:
                    # an office's statement is its supplier's (one statement for every party, ت3-1)
                    drill = ({'kind': 'supplier', 'id': inv.supplier_id} if kind == 'office' and inv.supplier_id
                             else None if kind == 'office' else {'kind': kind, 'id': party})
                    yield inv, sign, (kind, party), names[kind].get(party, '—'), drill, value, grams
                    break
            else:
                yield inv, sign, None, 'بلا طرف', None, value, grams
        elif by == 'employee':
            yield inv, sign, inv.employee_id, names['employee'].get(inv.employee_id, 'بلا موظف'), \
                ({'kind': 'employee', 'id': inv.employee_id} if inv.employee_id else None), value, grams
        elif by in ('day', 'month'):
            key = inv.date.strftime('%Y-%m-%d' if by == 'day' else '%Y-%m')
            yield inv, sign, key, key, None, value, grams
        else:
            lines = [(line.karat, float(line.weight_grams or 0.0)) for line in (inv.karat_lines or [])] or \
                    [(line.karat, float(line.weight or 0.0)) for line in (inv.items or [])]
            lines = [(int(round(float(k))) if k else None, w * float(k or main) / main) for k, w in lines if w]
            whole = sum(w for _, w in lines)
            if not whole:
                yield inv, sign, None, 'عيار غير محدد', None, value, grams
                continue
            for karat, line_grams in lines:
                yield inv, sign, karat, f'عيار {karat}' if karat else 'عيار غير محدد', None, \
                    value * line_grams / whole, sign * line_grams


def _sums(documents, by, names) -> dict:
    sums = collections.OrderedDict()
    for inv, sign, group_id, label, drill, value, grams in _parts(documents, by, names):
        s = sums.setdefault(group_id, {'group_id': group_id, 'group': label, 'drill': drill, 'bought': set(),
                                       'returned': set(), 'value': 0.0, 'weight': 0.0, 'last': None})
        s['bought' if sign > 0 else 'returned'].add(inv.id)
        s['value'] += value
        s['weight'] += grams
        if sign > 0:
            s['last'] = max(s['last'] or inv.date, inv.date)
    for s in sums.values():
        s['invoices'], s['returns'] = len(s.pop('bought')), len(s.pop('returned'))
    return sums


def _sales(start, end, by) -> dict:
    """The sales analysis's groups, by the same dimension: {group id: its sums}."""
    from services.reports import sales_analysis as sales
    documents = sales._documents(start, end)
    return sales._sums(documents, by, sales._names(documents))


def purchases_analysis(*, now: dt.datetime, start: dt.date | None = None, end: dt.date | None = None,
                       by: str = 'kind', compare: bool = False, against_sales: bool = False) -> Report:
    """*now*: the caller's clock (ADR-015). *compare* needs a period: the one before
    it (previous_period). *against_sales*: by AGAINST_SALES, the sales beside."""
    if by not in BY:
        raise ValueError(f'by is {"|".join(BY)}, not {by!r}')
    documents = _documents(start, end)
    sums = _sums(documents, by, _names(documents))
    total_value = sum(s['value'] for s in sums.values())
    compared = compare and start is not None and end is not None
    previous = {}
    if compared:
        before = _documents(*previous_period(start, end))
        previous = {k: s['value'] for k, s in _sums(before, by, _names(before)).items()}

    sold = _sales(start, end, by) if against_sales and by in AGAINST_SALES else None
    if sold is not None:
        # a group that sold and bought nothing still says its sales
        for key in sold.keys() - sums.keys():
            sums[key] = {'group_id': key, 'group': sold[key]['group'], 'drill': sold[key]['drill'],
                         'invoices': 0, 'returns': 0, 'value': 0.0, 'weight': 0.0, 'last': None}

    rows = []
    order = sorted(sums.values(), key=lambda s: s['group'] if by in ('day', 'month') else -s['value'])
    for s in order:
        row = {'group_id': s['group_id'] if not isinstance(s['group_id'], tuple) else '-'.join(map(str, s['group_id'])),
               'group': s['group'], 'invoices': s['invoices'], 'returns': s['returns'],
               'value': round(s['value'], 2), 'weight': round(s['weight'], 3),
               'share': round(s['value'] / total_value * 100, 2) if total_value else None, 'drill': s['drill']}
        if by == 'party':
            row['last'] = s['last'].date().isoformat() if s['last'] else None
        if compared:
            prev = previous.get(s['group_id'])
            row['prev_value'] = round(prev, 2) if prev is not None else None
            row['change'] = round((s['value'] - prev) / prev * 100, 2) if prev else None
        if sold is not None:
            sale = sold.get(s['group_id'])
            row['sales_value'] = round(sale['value'], 2) if sale else None
            row['sales_weight'] = round(sale['weight'], 3) if sale else None
        rows.append(row)
    if against_sales and sold is None:
        rows.append({'group': 'المقارنة بالمبيعات حسب اليوم والشهر والعيار والموظف فقط', 'style': 'note'})

    totals = {'invoices': sum(1 for _, sign, *_ in documents if sign > 0),
              'returns': sum(1 for _, sign, *_ in documents if sign < 0),
              'value': round(total_value, 2), 'weight': round(sum(s['weight'] for s in sums.values()), 3),
              'share': 100.0 if total_value else None}
    if sold is not None:
        totals['sales_value'] = round(sum(s['value'] for s in sold.values()), 2)
        totals['sales_weight'] = round(sum(s['weight'] for s in sold.values()), 3)
    if compared:
        prev_total = sum(previous.values())
        totals['prev_value'] = round(prev_total, 2)
        totals['change'] = round((total_value - prev_total) / prev_total * 100, 2) if prev_total else None

    label = {'kind': 'النوع', 'party': 'الطرف', 'employee': 'الموظف', 'day': 'اليوم', 'month': 'الشهر',
             'karat': 'العيار'}[by]
    beside = sold is not None                    # beside the sales, each side says whose it is
    columns = [Column('group', label), Column('invoices', 'الفواتير', 'count'), Column('returns', 'المرتجعات', 'count'),
               Column('value', 'المشتريات (ريال)' if beside else 'الريال', 'money'),
               Column('weight', 'المشتريات (جم)' if beside else 'الوزن', 'grams'),
               Column('share', 'الحصة', 'percent')]
    if compared:
        columns += [Column('prev_value', 'الفترة السابقة', 'money'),
                    Column('change', 'التغيّر', 'percent', signed=True)]
    if sold is not None:
        columns += [Column('sales_value', 'المبيعات (ريال)', 'money'),
                    Column('sales_weight', 'المبيعات (جم)', 'grams')]
    if by == 'party':
        columns.append(Column('last', 'آخر شراء', 'date'))
    books = _books(start, end)
    gap = round(total_value - books, 2)
    accounts = 'حسابات المشتريات وأجور المصنعية في الدفاتر'
    says = (f'مطابق ل{accounts}' if abs(gap) < 0.01 else
            f'لا يطابق {accounts}: المستندات {"أكثر" if gap > 0 else "أقل"} بـ {abs(gap):,.2f} '
            f'(الدفاتر {books:,.2f})')
    checks = [Check('books_agree', says, abs(gap) < 0.01)]
    return Report(id='purchases_analysis', title='تحليل المشتريات', basis='documents', columns=columns, rows=rows,
                  totals=totals, checks=checks, start=start, end=end, read_at=now,
                  chart=Chart('group', 'value', ('sales_value',) if sold is not None else ())
                  if by in ('day', 'month') else None)
