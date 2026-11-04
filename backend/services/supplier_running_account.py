"""A supplier's running account, read from its ledger (REPORTS ت3-2أ, ADR-028 amended).

The shop and its suppliers keep a running account: a voucher pays the
account, rarely an invoice (0 of 113 gold vouchers named one, ADR-028). So
which purchase is still open is not written anywhere -- it is read here,
each time, from the supplier's ledger lines (supplier_ledger_lines, the
balance's own rule), and never stored: ADR-028 stands, no attribution is
written without a person's decision.

Two dimensions, each on its own: gold in the main karat's equivalent, and
cash. Walking the lines by date, entry by entry (an entry's lines on the
supplier netted):
  * what the shop comes to owe opens an item -- an invoice's for an invoice
    entry (an office reservation's execution is its purchase's), otherwise
    the entry's own -- taking any prepayment first;
  * what it pays closes items: the evidence first -- a voucher's declared
    gold split (VoucherInvoiceGoldAttribution), a voucher naming its invoice,
    an invoice's own payments or correction, a return its original -- then
    the oldest open item; what is paid beyond is a prepayment;
  * a reversal (of a voucher, of an entry) undoes what the reversed entries
    did: it reopens what they closed, closes what they opened.
The law (tests/test_supplier_running_account.py): what the reading leaves
open less what is prepaid is the ledger's balance, per supplier and
dimension. An invoice is paid when both its dimensions are closed, and says
why: by evidence, by the running account, by its own reversal, or at once
(its entry paid it: the supplier's lines on it net to nothing).
"""
from __future__ import annotations

import collections

GOLD_EPS = 0.0005       # a gram's half-milligram
CASH_EPS = 0.005        # half a halala
INVOICE_REFERENCES = ('invoice', 'invoice_payments', 'office_reservation_settlement_reversal')


class _Item:
    __slots__ = ('key', 'invoice_id', 'entry_id', 'date', 'reference_type', 'original', 'remaining', 'closed_by')

    def __init__(self, key, invoice_id, entry_id, date, reference_type):
        self.key, self.invoice_id, self.entry_id = key, invoice_id, entry_id
        self.date, self.reference_type = date, reference_type
        self.original = self.remaining = 0.0
        self.closed_by = collections.defaultdict(float)     # basis -> amount

    def as_dict(self):
        return {'invoice_id': self.invoice_id, 'entry_id': self.entry_id, 'date': self.date,
                'reference_type': self.reference_type, 'original': self.original, 'remaining': self.remaining,
                'closed_by': dict(self.closed_by)}


class _Dimension:
    """One dimension's walk; every step keeps Σ remaining − prepaid = Σ what was owed."""

    def __init__(self, eps):
        self.eps = eps
        self.items: dict = {}                    # key -> _Item, opened in order
        self.prepaid = 0.0
        self.opened = collections.defaultdict(list)    # entry id -> [(item, amount)]
        self.applied = collections.defaultdict(list)   # entry id -> [[item | None, amount, basis]]

    def _item(self, key, invoice_id, entry):
        if key not in self.items:
            self.items[key] = _Item(key, invoice_id, entry['entry_id'], entry['date'], entry['reference_type'])
        return self.items[key]

    def open(self, amount, key, invoice_id, entry):
        item = self._item(key, invoice_id, entry)
        item.original += amount
        taken = min(self.prepaid, amount)
        self.prepaid -= taken
        item.remaining += amount - taken
        if taken > 0:
            item.closed_by['running_account'] += taken
        self.opened[entry['entry_id']].append((item, amount))

    def pay(self, amount, entry, evidence=()):
        """*evidence*: [(item key, at most, basis)] -- closed first, each up to what is declared."""
        left = amount
        for key, most, basis in evidence:
            item = self.items.get(key)
            if item is None or left <= 0:
                continue
            take = min(left, item.remaining, most)
            if take > 0:
                self._close(item, take, basis, entry)
                left -= take
        for item in self.items.values():
            if left <= 0:
                break
            take = min(left, item.remaining)
            if take > 0:
                self._close(item, take, 'running_account', entry)
                left -= take
        if left > 0:
            self.prepaid += left
            self.applied[entry['entry_id']].append([None, left, 'prepaid'])

    def _close(self, item, amount, basis, entry):
        item.remaining -= amount
        item.closed_by[basis] += amount
        self.applied[entry['entry_id']].append([item, amount, basis])

    def reverse(self, amount, targets, entry):
        """Undo the *targets* entries: positive *amount* reopens what they
        closed, negative closes what they opened; the rest as any entry."""
        if amount > 0:
            left = amount
            for target in targets:
                for record in reversed(self.applied.get(target, [])):
                    item, applied, basis = record
                    take = min(left, applied)
                    if take <= 0:
                        continue
                    if item is None:
                        take = min(take, self.prepaid)
                        self.prepaid -= take
                    else:
                        item.remaining += take
                        item.closed_by[basis] -= take
                    record[1] -= take
                    left -= take
            if left > 0:
                self.open(left, ('entry', entry['entry_id']), None, entry)
            self._take_prepaid()
        elif amount < 0:
            evidence = [(item.key, opened, 'reversal') for target in targets
                        for item, opened in self.opened.get(target, [])]
            self.pay(-amount, entry, evidence)

    def _take_prepaid(self):
        """What is reopened while a prepayment stands is paid from it, the oldest first."""
        for item in self.items.values():
            if self.prepaid <= 0:
                break
            take = min(self.prepaid, item.remaining)
            if take > 0:
                self.prepaid -= take
                item.remaining -= take
                item.closed_by['running_account'] += take

    def summary(self):
        items = list(self.items.values())
        return {'balance': sum(i.remaining for i in items) - self.prepaid, 'prepaid': self.prepaid,
                'items': [i.as_dict() for i in items]}


def _gold(line) -> float:
    from pricing.karat_service import convert_to_main_karat
    return sum(convert_to_main_karat(line[f'{k}k'], k) for k in (18, 21, 22, 24))


def _entries(lines):
    """The lines netted per entry, in their order; owed > 0: the shop owes more."""
    entries = {}
    for line in lines:
        e = entries.setdefault(line['entry_id'], {'entry_id': line['entry_id'], 'date': line['date'],
                                                  'reference_type': line['reference_type'],
                                                  'reference_id': line['reference_id'], 'gold': 0.0, 'cash': 0.0})
        e['gold'] -= _gold(line)
        e['cash'] -= line['cash']
    return list(entries.values())


def running_account(supplier, as_of=None) -> dict:
    """{'gold': {...}, 'cash': {...}, 'invoices': [...]} -- see the module;
    *as_of* (a date), to its end -- a day counts whole."""
    import datetime as dt

    from models import Invoice, OfficeReservation, Voucher, VoucherInvoiceGoldAttribution, db
    from services.party_live_balances import supplier_ledger_lines
    before = dt.datetime.combine(as_of + dt.timedelta(days=1), dt.time.min) if as_of else None
    entries = _entries(supplier_ledger_lines(supplier, before))
    # a reservation's execution is its purchase's posting: the reservation names the invoice
    reserved = {e['reference_id'] for e in entries if e['reference_type'] == 'office_reservation'}
    purchase_of = dict(db.session.query(OfficeReservation.id, OfficeReservation.purchase_invoice_id)
                       .filter(OfficeReservation.id.in_(reserved or {-1}),
                               OfficeReservation.purchase_invoice_id.isnot(None)))
    for e in entries:
        if e['reference_type'] == 'office_reservation' and e['reference_id'] in purchase_of:
            e['reference_type'], e['reference_id'] = 'invoice', purchase_of[e['reference_id']]

    def ids(kind):
        return {e['reference_id'] for e in entries if e['reference_type'] == kind and e['reference_id']}

    invoice_ids = set().union(*(ids(k) for k in INVOICE_REFERENCES))
    originals = dict(db.session.query(Invoice.id, Invoice.original_invoice_id)
                     .filter(Invoice.id.in_(invoice_ids or {-1})))
    voucher_ids = ids('voucher') | ids('voucher_reversal')
    names = {v: r for v, t, r in db.session.query(Voucher.id, Voucher.reference_type, Voucher.reference_id)
             .filter(Voucher.id.in_(voucher_ids or {-1})) if t == 'invoice' and r}
    declared = collections.defaultdict(list)
    for v, inv, grams in (db.session.query(VoucherInvoiceGoldAttribution.voucher_id,
                                           VoucherInvoiceGoldAttribution.invoice_id,
                                           VoucherInvoiceGoldAttribution.weight_main_karat)
                          .filter(VoucherInvoiceGoldAttribution.voucher_id.in_(voucher_ids or {-1}))):
        declared[v].append((('invoice', inv), float(grams or 0.0), 'evidence'))
    voucher_entries = collections.defaultdict(list)
    for e in entries:
        if e['reference_type'] == 'voucher' and e['reference_id']:
            voucher_entries[e['reference_id']].append(e['entry_id'])

    gold, cash = _Dimension(GOLD_EPS), _Dimension(CASH_EPS)
    for e in entries:
        kind, ref = e['reference_type'], e['reference_id']
        for dim, amount in ((gold, e['gold']), (cash, e['cash'])):
            if abs(amount) < 1e-12:
                if kind == 'invoice' and ref and not originals.get(ref):
                    dim.open(0.0, ('invoice', ref), ref, e)       # bought and paid in one entry
                continue
            if kind == 'voucher_reversal':
                dim.reverse(amount, voucher_entries.get(ref, []), e)
            elif kind == 'journal_entry_reversal':
                dim.reverse(amount, [ref] if ref else [], e)   # an entry never walked: as any entry
            elif kind in INVOICE_REFERENCES and ref:
                target = originals.get(ref) or ref
                if amount > 0 and kind == 'invoice' and not originals.get(ref):
                    dim.open(amount, ('invoice', ref), ref, e)
                elif amount > 0:
                    dim.open(amount, ('entry', e['entry_id']), None, e)
                else:
                    dim.pay(-amount, e, [(('invoice', target), float('inf'), 'evidence')])
            elif amount > 0:
                dim.open(amount, ('entry', e['entry_id']), None, e)
            else:
                evidence = list(declared.get(ref, [])) if kind == 'voucher' and dim is gold else []
                if kind == 'voucher' and ref in names:
                    evidence.append((('invoice', names[ref]), float('inf'), 'evidence'))
                dim.pay(-amount, e, evidence)

    return {'supplier_id': supplier.id, 'gold': gold.summary(), 'cash': cash.summary(),
            'invoices': _invoices(gold, cash)}


def _invoices(gold, cash) -> list:
    """Each invoice the walk opened: paid when both dimensions are closed, and why."""
    keys = [k for k in {**gold.items, **cash.items} if k[0] == 'invoice']
    out = []
    for key in keys:
        parts = [(d.items.get(key), d.eps) for d in (gold, cash)]
        parts = [(i, eps) for i, eps in parts if i is not None]
        open_ = [i.remaining > eps for i, eps in parts]
        closed_by = collections.defaultdict(float)
        for i, eps in parts:
            for basis, amount in i.closed_by.items():
                if amount > eps:
                    closed_by[basis] += amount
        if any(open_):
            state = 'open' if all(i.remaining >= i.original - eps for i, eps in parts) else 'partial'
        else:
            state = 'reversed' if set(closed_by) == {'reversal'} else 'paid'
        basis = ('running_account' if 'running_account' in closed_by else
                 'evidence' if 'evidence' in closed_by else 'reversal' if closed_by else
                 'at_once' if state == 'paid' else None)
        gold_item, cash_item = gold.items.get(key), cash.items.get(key)
        out.append({'invoice_id': key[1], 'state': state, 'basis': basis,
                    'gold_original': gold_item.original if gold_item else 0.0,
                    'gold_remaining': gold_item.remaining if gold_item else 0.0,
                    'cash_original': cash_item.original if cash_item else 0.0,
                    'cash_remaining': cash_item.remaining if cash_item else 0.0})
    return out


# ── A purchase's shown status (REPORTS ت3-2ج; the owner 4 Nov 2026) ──────────

SHOWN = {'paid': 'paid', 'partial': 'partially_paid', 'open': 'unpaid', 'reversed': 'cancelled',
         'not_on_account': 'not_on_account'}


def is_supplier_purchase(invoice) -> bool:
    """A posted supplier purchase: what the reading answers for."""
    return (invoice.invoice_type == 'شراء' and invoice.supplier_id is not None
            and bool(invoice.is_posted) and invoice.status != 'rejected')


def purchase_states(invoice_ids=None) -> dict:
    """{invoice id: {'state', 'basis', 'shown', 'cash_original', 'cash_remaining', 'gold_remaining'}}
    for the posted supplier purchases among *invoice_ids* (all of them when
    None), each supplier read once. One the supplier's ledger does not hold is
    'not_on_account'. *shown* is the list's status word for the state."""
    from models import Invoice, Supplier, db
    query = Invoice.query.filter(Invoice.invoice_type == 'شراء', Invoice.supplier_id.isnot(None),
                                 Invoice.is_posted.is_(True), Invoice.status != 'rejected')
    if invoice_ids is not None:
        query = query.filter(Invoice.id.in_(list(invoice_ids) or [-1]))
    by_supplier = collections.defaultdict(set)
    for invoice_id, supplier_id in query.with_entities(Invoice.id, Invoice.supplier_id):
        by_supplier[supplier_id].add(invoice_id)
    out = {}
    for supplier_id, ids in by_supplier.items():
        supplier = db.session.get(Supplier, supplier_id)
        read = {i['invoice_id']: i for i in running_account(supplier)['invoices']} if supplier else {}
        for invoice_id in ids:
            i = read.get(invoice_id)
            state = i['state'] if i else 'not_on_account'
            out[invoice_id] = {'state': state, 'basis': i['basis'] if i else None, 'shown': SHOWN[state],
                               'cash_original': round(i['cash_original'], 2) if i else None,
                               'cash_remaining': round(i['cash_remaining'], 2) if i else None,
                               'gold_remaining': round(i['gold_remaining'], 3) if i else None}
    return out
