"""A supplier's running account: derived from the ledger each reading, evidence first, then oldest first (REPORTS ت3-2أ, ADR-028 amended).

The owner, 4 Nov 2026 («امضي»): the shop and its suppliers keep a running
account -- 0 of 113 gold vouchers named an invoice (ADR-028) -- so every one
of the 171 supplier purchases on the 2 Nov copy read «pending», and the small
remainders could not be cleared. ADR-028 stands: the ledger is the truth, a
balance is derived, no attribution is stored without a person's decision. To
it, one reading: never stored, rebuilt from the supplier's ledger lines (the
balance's own rule) each time -- purchases open, payments close; the
evidence first (a voucher's declared split, a voucher naming its invoice, a
return its original, a reversal what it reverses), the oldest first for the
rest; what is paid beyond, a prepayment the next purchase takes first.
The law: what it leaves open is the ledger's balance, per supplier, gold
(the main karat's equivalent) and cash.

Run:
    python -m pytest tests/test_supplier_running_account.py -v
"""
import datetime as dt
import uuid

import pytest

from models import Account, Invoice, JournalEntry, Supplier, Voucher, VoucherInvoiceGoldAttribution, db

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _supplier():
    weight = Account(account_number=f'72{uuid.uuid4().int % 10**8:08d}', name='مورد جاري وزني', type='Liability')
    db.session.add(weight)
    db.session.flush()
    cash = Account(account_number=f'21{uuid.uuid4().int % 10**8:08d}', name='مورد جاري', type='Liability',
                   memo_account_id=weight.id)
    db.session.add(cash)
    db.session.flush()
    supplier = Supplier(supplier_code=f'RA{uuid.uuid4().hex[:8]}', name='مورد حساب جاري', account_id=cash.id)
    db.session.add(supplier)
    db.session.flush()
    return supplier, weight


def _invoice(supplier, day, kind='شراء', original=None):
    inv = Invoice(invoice_type=kind, invoice_type_id=10**8 + uuid.uuid4().int % 10**8, date=D(2043, 5, day),
                  supplier_id=supplier.id, total=0.0, is_posted=True, status='posted', original_invoice_id=original)
    db.session.add(inv)
    db.session.flush()
    return inv


def _voucher(day, reference_invoice=None):
    v = Voucher(voucher_number=f'RA-{uuid.uuid4().hex[:8]}', voucher_type='payment', date=D(2043, 5, day),
                status='approved', created_by='t', reference_type='invoice' if reference_invoice else None,
                reference_id=reference_invoice)
    db.session.add(v)
    db.session.flush()
    return v


def _post(supplier, weight, day, grams, reference_type, reference_id):
    """grams > 0: the shop owes more (a credit on the supplier's weight account)."""
    from dual_system_helpers import create_dual_journal_entry
    entry = JournalEntry(date=D(2043, 5, day, 12), description='جاري', entry_type='عادي', is_posted=True,
                         created_by='t', reference_type=reference_type, reference_id=reference_id)
    db.session.add(entry)
    db.session.flush()
    side = {'credit_21k': grams} if grams > 0 else {'debit_21k': -grams}
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=weight.id, supplier_id=supplier.id,
                              apply_golden_rule=False, **side)
    if reference_type == 'voucher':
        # an approved voucher's entry is linked to it (journal_entry_guard holds it at commit)
        db.session.get(Voucher, reference_id).journal_entry_id = entry.id
    db.session.flush()
    return entry


@pytest.fixture
def books():
    from pricing.karat_service import convert_to_main_karat
    supplier, weight = _supplier()
    a, b = _invoice(supplier, 1), _invoice(supplier, 2)
    _post(supplier, weight, 1, 10.0, 'invoice', a.id)
    _post(supplier, weight, 2, 5.0, 'invoice', b.id)
    v1 = _voucher(3)
    _post(supplier, weight, 3, -8.0, 'voucher', v1.id)                    # no evidence: the oldest
    v2 = _voucher(4)
    db.session.add(VoucherInvoiceGoldAttribution(voucher_id=v2.id, invoice_id=b.id, karat=21.0, weight=5.0,
                                                 weight_main_karat=convert_to_main_karat(5.0, 21), created_by='t'))
    _post(supplier, weight, 4, -5.0, 'voucher', v2.id)                    # declared: B, though A is older
    _post(supplier, weight, 5, 8.0, 'voucher_reversal', v1.id)            # v1 undone: what it closed reopens
    v3 = _voucher(6)
    _post(supplier, weight, 6, -12.0, 'voucher', v3.id)                   # beyond what is open: 2 paid ahead
    c = _invoice(supplier, 7)
    _post(supplier, weight, 7, 3.0, 'invoice', c.id)                      # takes the prepayment first
    db.session.flush()
    return {'supplier': supplier, 'a': a, 'b': b, 'c': c, 'g': lambda x: convert_to_main_karat(x, 21)}


def _reading(supplier):
    from services.supplier_running_account import running_account
    return running_account(supplier)


def test_evidence_first_then_the_oldest_a_reversal_reopens_a_prepayment_is_taken(books):
    g = books['g']
    reading = _reading(books['supplier'])
    open_ = {i['invoice_id']: i for i in reading['gold']['items'] if i['invoice_id']}
    assert open_[books['a'].id]['remaining'] == pytest.approx(0.0, abs=1e-6), 'reopened by the reversal, then paid'
    assert open_[books['b'].id]['remaining'] == pytest.approx(0.0, abs=1e-6), 'its declared payment, first'
    assert open_[books['c'].id]['remaining'] == pytest.approx(g(1.0), abs=1e-6), 'the 2 paid ahead taken first'
    assert reading['gold']['prepaid'] == pytest.approx(0.0, abs=1e-6)


def test_the_law_what_it_leaves_open_is_the_ledger_s(books):
    from pricing.karat_service import convert_to_main_karat
    from services.party_live_balances import compute_live_supplier_balances
    supplier = books['supplier']
    reading = _reading(supplier)
    balance = compute_live_supplier_balances([supplier])[supplier.id]
    owed = -sum(convert_to_main_karat(balance[f'{k}k'], k) for k in (18, 21, 22, 24))
    assert reading['gold']['balance'] == pytest.approx(owed, abs=1e-6)
    assert reading['cash']['balance'] == pytest.approx(-balance['cash'], abs=1e-6)


def test_the_ledger_lines_are_the_balance_s_own(books):
    from services.party_live_balances import compute_live_supplier_balances, supplier_ledger_lines
    supplier = books['supplier']
    lines = supplier_ledger_lines(supplier)
    balance = compute_live_supplier_balances([supplier])[supplier.id]
    for key in ('cash', '18k', '21k', '22k', '24k'):
        assert sum(line[key] for line in lines) == pytest.approx(balance[key], abs=1e-6), key


def test_each_invoice_says_its_state_and_why(books):
    reading = _reading(books['supplier'])
    state = {i['invoice_id']: (i['state'], i['basis']) for i in reading['invoices']}
    assert state[books['a'].id] == ('paid', 'running_account')
    assert state[books['b'].id] == ('paid', 'evidence')
    assert state[books['c'].id][0] == 'partial'


def test_what_a_reversal_reopens_is_paid_from_a_standing_prepayment():
    """Found on the 2 Nov copy: a reversal reopened an invoice while a later
    payment stood ahead (الجنية العربي read 18,092.52 open beside 18,100 prepaid)."""
    supplier, weight = _supplier()
    a = _invoice(supplier, 1)
    _post(supplier, weight, 1, 10.0, 'invoice', a.id)
    v1, v2 = _voucher(2), _voucher(3)
    _post(supplier, weight, 2, -10.0, 'voucher', v1.id)
    _post(supplier, weight, 3, -4.0, 'voucher', v2.id)                    # 4 ahead
    _post(supplier, weight, 4, 10.0, 'voucher_reversal', v1.id)           # A reopens: 4 of it already paid
    from pricing.karat_service import convert_to_main_karat
    reading = _reading(supplier)
    item = next(i for i in reading['gold']['items'] if i['invoice_id'] == a.id)
    assert item['remaining'] == pytest.approx(convert_to_main_karat(6.0, 21), abs=1e-6)
    assert reading['gold']['prepaid'] == pytest.approx(0.0, abs=1e-6)


def test_bought_and_paid_in_one_entry_is_paid_at_once():
    from dual_system_helpers import create_dual_journal_entry
    supplier, weight = _supplier()
    a = _invoice(supplier, 1)
    entry = _post(supplier, weight, 1, 5.0, 'invoice', a.id)
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=weight.id, supplier_id=supplier.id,
                              apply_golden_rule=False, debit_21k=5.0)
    db.session.flush()
    state = {i['invoice_id']: (i['state'], i['basis']) for i in _reading(supplier)['invoices']}
    assert state[a.id] == ('paid', 'at_once')


def test_an_office_reservation_s_execution_is_its_purchase_s_posting():
    """35 of the 2 Nov copy's purchases have no invoice entry: their
    reservation's execution posted them, and the reservation names them."""
    from models import Office, OfficeReservation
    supplier, weight = _supplier()
    office = Office(office_code=f'RA{uuid.uuid4().hex[:8]}', name='مكتب جاري')
    db.session.add(office)
    db.session.flush()
    a = _invoice(supplier, 1)
    reservation = OfficeReservation(office_id=office.id, reservation_code=f'RES-RA-{uuid.uuid4().hex[:8]}',
                                    weight_grams=5.0, weight_main_karat=5.0, price_per_gram=1.0,
                                    execution_price_per_gram=1.0, total_amount=5.0, purchase_invoice_id=a.id)
    db.session.add(reservation)
    db.session.flush()
    _post(supplier, weight, 1, 5.0, 'office_reservation', reservation.id)
    state = {i['invoice_id']: i['state'] for i in _reading(supplier)['invoices']}
    assert state[a.id] == 'open'
