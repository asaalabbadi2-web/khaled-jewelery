"""Sales analysis: the period's sales and returns by employee, customer, day or month (REPORTS ت1-2, ADR-083).

From the documents -- the posted sales and sale returns, not withdrawn (as
the weight close reads them), each at its price less the VAT its entry
posted (services/sales_vat), its weight in the main karat -- and checked
against the books: what it sums is the net credit on the sales accounts
(sales_accounts: the roles بيع/revenue, بيع/sales_gold_scrap, مرتجع
بيع/sales_returns, and the lines on their parent itself) in its period --
every line, a reversal and an invoice's correction too. On the 2 Nov copy
each month of 2026 agrees to the halala (October 1,394,020.10).
Compared, each group says its previous period: whole months the months
before, any other span as many days before.
By category or karat (REPORTS ت4-1, the old sales reports merged): a
sale's lines carry no item (2,905 of 2,906 on the 2 Nov copy) but a category,
a karat and their value before VAT (`net`, October's sum the invoices' to the
halala), so a document's value is shared on its lines by their net -- the
value the books agree with stays the document's -- each line's grams in the
main karat; a line with no category is «بلا تصنيف». By item: the piece a
line sold -- from 2027, as piece tracking opens category by category (ADR-045,
the owner 4 Nov 2026); a line sold by weight is «بلا صنف (بالوزن)». By gold type, the
document's own. A document counts once in each group it touches. By customer
or category, each row says its last sale.
"""
from __future__ import annotations

import collections
import datetime as dt

from services.reports.contract import Chart, Check, Column, Report

BY = ('employee', 'customer', 'day', 'month', 'gold_type', 'category', 'item', 'karat')
LINES = ('category', 'item', 'karat')
LAST = ('customer', 'category', 'item')
SALE, SALE_RETURN = 'بيع', 'مرتجع بيع'
# their net credit: the returns' debits take themselves off
SALES_ROLES = (('بيع', 'revenue'), ('بيع', 'sales_gold_scrap'), ('مرتجع بيع', 'sales_returns'))
NO_SELLER, NO_CUSTOMER, NO_CATEGORY, NO_ITEM = 'بلا بائع', 'بلا عميل', 'بلا تصنيف', 'بلا صنف (بالوزن)'
GOLD_TYPES = {'new': 'ذهب جديد', 'scrap': 'كسر'}


def _bounds(start, end):
    lo = dt.datetime.combine(start, dt.time.min) if start else None
    hi = dt.datetime.combine(end + dt.timedelta(days=1), dt.time.min) if end else None
    return lo, hi


def _documents(start, end) -> list:
    """(invoice, sign, value, grams) for the period's posted sales and returns, not withdrawn."""
    from models import Invoice, db
    from routes import _invoice_weight_in_main_karat
    from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES
    from services.sales_vat import posted_sales_vat
    from services.weight_position import _with_weight_lines
    lo, hi = _bounds(start, end)
    query = (_with_weight_lines(Invoice.query)
             .filter(Invoice.is_posted.is_(True), Invoice.invoice_type.in_((SALE, SALE_RETURN)))
             .filter(db.func.coalesce(Invoice.status, '').notin_(list(RETRACTED_INVOICE_STATUSES))))
    if lo is not None:
        query = query.filter(Invoice.date >= lo)
    if hi is not None:
        query = query.filter(Invoice.date < hi)
    invoices = query.order_by(Invoice.date, Invoice.id).all()
    vat = posted_sales_vat([inv.id for inv in invoices])
    out = []
    for inv in invoices:
        sign = 1 if inv.invoice_type == SALE else -1
        value = float(inv.total or 0.0) - vat.get(inv.id, 0.0)
        out.append((inv, sign, sign * value, sign * float(_invoice_weight_in_main_karat(inv) or 0.0)))
    return out


def sales_accounts() -> set:
    """The accounts the books keep the sales on: the sales roles' (their net
    credit -- the returns' debits take themselves off), and the lines posted
    on their parent itself: 2026 posted its sales on 41 «إيرادات النشاط»,
    the leaves' parent, until April -- not on its other children (a
    discount, a stone's revenue), which are not sales."""
    from accounting.mappings import get_account_id_for_mapping
    from models import Account, db
    accounts = {get_account_id_for_mapping(op, role) for op, role in SALES_ROLES} - {None}
    parents = {a.parent_id for a in Account.query.filter(Account.id.in_(accounts or {-1})) if a.parent_id}
    if len(parents) == 1:
        accounts |= parents
    return accounts


def _books(start, end) -> float:
    """The sales accounts' net credit in the period, from the counted lines."""
    from accounting.balances import counted_line_filters
    from models import JournalEntry, JournalEntryLine, db
    accounts = sales_accounts()
    if not accounts:
        return 0.0
    lo, hi = _bounds(start, end)
    query = (db.session.query(db.func.sum(JournalEntryLine.cash_credit - JournalEntryLine.cash_debit))
             .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(*counted_line_filters(), JournalEntryLine.account_id.in_(accounts)))
    if lo is not None:
        query = query.filter(JournalEntry.date >= lo)
    if hi is not None:
        query = query.filter(JournalEntry.date < hi)
    return float(query.scalar() or 0.0)


def _group(inv, by: str, names: dict) -> tuple:
    """(id, label, drill) of the group a document falls in -- by a document's own."""
    if by == 'employee':
        return (inv.employee_id, names['employee'].get(inv.employee_id, NO_SELLER),
                {'kind': 'employee', 'id': inv.employee_id} if inv.employee_id else None)
    if by == 'customer':
        return (inv.customer_id, names['customer'].get(inv.customer_id, NO_CUSTOMER),
                {'kind': 'customer', 'id': inv.customer_id} if inv.customer_id else None)
    if by == 'gold_type':
        return inv.gold_type, GOLD_TYPES.get(inv.gold_type, inv.gold_type or 'غير محدد'), None
    key = inv.date.strftime('%Y-%m-%d' if by == 'day' else '%Y-%m')
    return key, key, None


def _line_group(line, by: str, names: dict) -> tuple:
    if by == 'category':
        return line.category_id, names['category'].get(line.category_id, NO_CATEGORY), None
    if by == 'item':
        return line.item_id, names['item'].get(line.item_id, NO_ITEM), None
    karat = int(round(float(line.karat))) if line.karat else None
    return karat, f'عيار {karat}' if karat else 'عيار غير محدد', None


def _parts(documents, by: str, names: dict):
    """(document, sign, group id, label, drill, value, grams): a document whole, or
    -- by category or karat -- shared on its lines by their net (by their weight
    when they carry none), each line's grams in the main karat."""
    from pricing.gold_price_service import get_main_karat
    main = float(get_main_karat()) if by in LINES else None
    for inv, sign, value, grams in documents:
        lines = list(inv.items or []) if by in LINES else []
        if not lines:
            group = (_group(inv, by, names) if by not in LINES
                     else (None, {'category': NO_CATEGORY, 'item': NO_ITEM}.get(by, 'عيار غير محدد'), None))
            yield (inv, sign, *group, value, grams)
            continue
        nets = [float(line.net or 0.0) for line in lines]
        weights = [float(line.weight or 0.0) * float(line.karat or main) / main for line in lines]
        basis = nets if abs(sum(nets)) > 0.005 else weights
        whole = sum(basis)
        for line, share, line_grams in zip(lines, basis, weights):
            part = share / whole if whole else 1.0 / len(lines)
            yield (inv, sign, *_line_group(line, by, names), value * part, sign * line_grams)


def _sums(documents, by, names) -> dict:
    sums = collections.OrderedDict()
    for inv, sign, group_id, label, drill, value, grams in _parts(documents, by, names):
        s = sums.setdefault(group_id, {'group_id': group_id, 'group': label, 'drill': drill, 'sales': set(),
                                       'return_docs': set(), 'value': 0.0, 'weight': 0.0, 'last': None})
        s['sales' if sign > 0 else 'return_docs'].add(inv.id)
        s['value'] += value
        s['weight'] += grams
        if sign > 0:
            s['last'] = max(s['last'] or inv.date, inv.date)
    for s in sums.values():
        s['invoices'], s['returns'] = len(s.pop('sales')), len(s.pop('return_docs'))
    return sums


def _names(documents) -> dict:
    from models import Category, Customer, Employee, Item
    employees = {inv.employee_id for inv, *_ in documents if inv.employee_id}
    customers = {inv.customer_id for inv, *_ in documents if inv.customer_id}
    categories = {line.category_id for inv, *_ in documents for line in (inv.items or []) if line.category_id}
    items = {line.item_id for inv, *_ in documents for line in (inv.items or []) if line.item_id}
    return {'employee': {e.id: e.name for e in Employee.query.filter(Employee.id.in_(employees or {-1}))},
            'customer': {c.id: c.name for c in Customer.query.filter(Customer.id.in_(customers or {-1}))},
            'category': {c.id: c.name for c in Category.query.filter(Category.id.in_(categories or {-1}))},
            'item': {i.id: f'{i.name} ({i.item_code})' for i in Item.query.filter(Item.id.in_(items or {-1}))}}


def previous_period(start: dt.date, end: dt.date) -> tuple[dt.date, dt.date]:
    """The period a comparison reads: whole months against as many whole months
    before (October against September); any other span against the days just
    before it, as many."""
    whole = start.day == 1 and (end + dt.timedelta(days=1)).day == 1
    if whole:
        months = (end.year - start.year) * 12 + end.month - start.month + 1
        first = start.year * 12 + start.month - 1 - months
        return dt.date(first // 12, first % 12 + 1, 1), start - dt.timedelta(days=1)
    prev_end = start - dt.timedelta(days=1)
    return prev_end - (end - start), prev_end


def sales_analysis(*, now: dt.datetime, start: dt.date | None = None, end: dt.date | None = None,
                   by: str = 'employee', compare: bool = False) -> Report:
    """*now*: the caller's clock (ADR-015). *compare* needs a period: the one
    before it (previous_period)."""
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

    rows = []
    order = sorted(sums.values(), key=lambda s: s['group'] if by in ('day', 'month') else -s['value'])
    for s in order:
        row = {'group_id': s['group_id'], 'group': s['group'], 'invoices': s['invoices'], 'returns': s['returns'],
               'value': round(s['value'], 2), 'weight': round(s['weight'], 3),
               'average': round(s['value'] / s['invoices'], 2) if s['invoices'] else None,
               'share': round(s['value'] / total_value * 100, 2) if total_value else None,
               'drill': s['drill']}
        if by in ('gold_type', *LINES):
            row['per_gram'] = round(s['value'] / s['weight'], 2) if abs(s['weight']) > 0.0005 else None
        if by in LAST:
            row['last'] = s['last'].date().isoformat() if s['last'] else None
        if compared:
            prev = previous.get(s['group_id'])
            row['prev_value'] = round(prev, 2) if prev is not None else None
            row['change'] = round((s['value'] - prev) / prev * 100, 2) if prev else None
        rows.append(row)

    # a document once, however many groups its lines fell in
    invoices = sum(1 for _, sign, *_ in documents if sign > 0)
    totals = {'invoices': invoices, 'returns': sum(1 for _, sign, *_ in documents if sign < 0),
              'value': round(total_value, 2), 'weight': round(sum(s['weight'] for s in sums.values()), 3),
              'average': round(total_value / invoices, 2) if invoices else None, 'share': 100.0 if total_value else None}
    if compared:
        prev_total = sum(previous.values())
        totals['prev_value'] = round(prev_total, 2)
        totals['change'] = round((total_value - prev_total) / prev_total * 100, 2) if prev_total else None

    label = {'employee': 'الموظف', 'customer': 'العميل', 'day': 'اليوم', 'month': 'الشهر',
             'gold_type': 'نوع الذهب', 'category': 'التصنيف', 'item': 'الصنف', 'karat': 'العيار'}[by]
    columns = [Column('group', label), Column('invoices', 'الفواتير', 'count'), Column('returns', 'المرتجعات', 'count'),
               Column('value', 'القيمة', 'money'), Column('weight', 'الوزن', 'grams'),
               Column('average', 'متوسط الفاتورة', 'money'), Column('share', 'الحصة', 'percent')]
    if by in ('gold_type', *LINES):
        columns.append(Column('per_gram', 'سعر الجرام', 'money'))
    if compared:
        columns += [Column('prev_value', 'الفترة السابقة', 'money'),
                    Column('change', 'التغيّر', 'percent', signed=True)]
    if by in LAST:
        columns.append(Column('last', 'آخر بيع', 'date'))
    books = _books(start, end)
    checks = [Check('books_agree', 'مطابق لإيراد المبيعات في الدفاتر', abs(round(total_value - books, 2)) < 0.01)]
    return Report(id='sales_analysis', title='تحليل المبيعات', basis='documents', columns=columns, rows=rows,
                  totals=totals, checks=checks, start=start, end=end, read_at=now,
                  chart=Chart('group', 'value') if by in ('day', 'month') else None)
