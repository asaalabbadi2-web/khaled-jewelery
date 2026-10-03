"""Stage 4's ledger package: corrections by entries that never touch what already matches reality.

The owner (3 Oct 2026): the main cash box and the Riyadh bank were corrected to
match reality, and so were the clearing settlement accounts -- no correction
touches them; the temporary cash box and the temporary bank account carry what
would have moved them. The laws:

- no entry stage 4 writes names a protected account;
- a reversal or re-post that would have moved one moves its temporary twin,
  and that safe's statement moves with its ledger;
- a reversal nets the original to zero on every column;
- each step corrects what was measured, refuses what is no longer so, does
  nothing on a second run and writes nothing in a dry run.

Run:
    python -m pytest tests/test_stage4_package.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (
    Account, Customer, JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, Voucher, db,
)
from services.repair import stage4_package as pkg
from services.repair.entries import (
    PROTECTED_ACCOUNT_NUMBERS, SUBSTITUTES, ProtectedAccount, UnmirroredLine, reverse_entry, write_entry,
)
from services.safebox_subledger import subledger_totals_by_box

DAY = datetime(2026, 5, 19, 18, 24)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(number=None, name='حساب', **kw):
    if number:
        found = Account.query.filter_by(account_number=number).first()
        if found:
            return found
    a = Account(account_number=number or f'9{uuid.uuid4().int % 10**7:07d}', name=name, type='Asset', **kw)
    db.session.add(a)
    db.session.flush()
    return a


def _safe(account):
    box = SafeBox.query.filter_by(account_id=account.id).first()
    if box is None:
        box = SafeBox(name=f'{account.name} {uuid.uuid4().hex[:5]}', safe_type='cash', account_id=account.id,
                      is_active=True)
        db.session.add(box)
        db.session.flush()
    return box


@pytest.fixture
def books():
    """The protected accounts and their twins, each cash one with its safe."""
    accounts = {n: _account(n, f'محمي {n}') for n in PROTECTED_ACCOUNT_NUMBERS}
    accounts.update({n: _account(n, f'مؤقت {n}') for n in SUBSTITUTES.values()})
    for n in list(SUBSTITUTES) + list(SUBSTITUTES.values()):
        _safe(accounts[n])
    return accounts


def _entry(lines, *, ref_type='invoice_payments', ref_id=None, posted=True, deleted=False, number=None):
    je = JournalEntry(entry_number=number or f'T-{uuid.uuid4().hex[:10]}', date=DAY, description='t',
                      entry_type='عادي', reference_type=ref_type, reference_id=ref_id,
                      is_posted=posted, is_draft=False, is_deleted=deleted)
    db.session.add(je)
    db.session.flush()
    for account_id, dr, cr in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account_id, cash_debit=dr,
                                        cash_credit=cr, is_deleted=deleted))
    db.session.flush()
    return je


def _ledger(account_id):
    rows = (db.session.query(JournalEntryLine).join(JournalEntry)
            .filter(JournalEntryLine.account_id == account_id, JournalEntry.is_posted.is_(True),
                    JournalEntry.is_deleted.is_(False), JournalEntryLine.is_deleted.is_(False)).all())
    return round(sum((l.cash_debit or 0) - (l.cash_credit or 0) for l in rows), 2)


def _statement_minus_ledger(box):
    t = subledger_totals_by_box([box.id])[box.id]
    return round(t['sb_total'] - t['gl_total'], 2)


# ── the guard ────────────────────────────────────────────────────────────────

@pytest.mark.parametrize('number', sorted(PROTECTED_ACCOUNT_NUMBERS))
def test_no_correction_names_a_protected_account(books, number):
    other = _account()
    with pytest.raises(ProtectedAccount):
        write_entry(date=DAY, description='t', reference_type='stage4_test', reference_id=1, by='t',
                    lines=[{'account_id': books[number].id, 'cash_debit': 1.0, 'cash_credit': 0.0},
                           {'account_id': other.id, 'cash_debit': 0.0, 'cash_credit': 1.0}])


def test_a_reversal_moves_the_temporary_twin_and_its_statement(books):
    """PAY-1450's shape: the customer debited, the main cash credited 10,400."""
    main, temp = books['1100000'], books['1100002']
    customer = _account(name='عميل نقدي')
    original = _entry([(customer.id, 10400.0, 0.0), (main.id, 0.0, 10400.0)])
    main_before, temp_before = _ledger(main.id), _ledger(temp.id)
    drift_before = _statement_minus_ledger(_safe(temp))

    reverse_entry(original, by='t', reason='اختبار', substitute=True, safe_rows=True)

    assert _ledger(main.id) == main_before, 'the main cash is not touched'
    assert round(_ledger(temp.id) - temp_before, 2) == 10400.0
    assert _ledger(customer.id) == 0.0
    assert _statement_minus_ledger(_safe(temp)) == drift_before, 'the statement moved with the ledger'


def test_a_reversal_nets_every_column_and_refuses_what_it_cannot_mirror(books):
    a, b = _account(), _account()
    original = _entry([(a.id, 5.0, 0.0), (b.id, 0.0, 5.0)])
    for line in original.lines:
        sign = 1 if line.account_id == a.id else -1
        line.debit_weight, line.credit_weight = (2.5, 0.0) if sign > 0 else (0.0, 2.5)
        # 2821's lines carry signed analytics and a dimension set.
        line.analytic_amount_cash, line.analytic_weight_main = 5.0 * sign, 0.0087 * sign
    db.session.flush()
    reverse_entry(original, by='t', reason='x')
    for acc in (a, b):
        lines = (db.session.query(JournalEntryLine).join(JournalEntry)
                 .filter(JournalEntryLine.account_id == acc.id, JournalEntry.is_posted.is_(True)).all())
        assert round(sum((l.debit_weight or 0) - (l.credit_weight or 0) for l in lines), 6) == 0.0
        assert round(sum(l.analytic_amount_cash or 0 for l in lines), 6) == 0.0
        assert round(sum(l.analytic_weight_main or 0 for l in lines), 6) == 0.0

    odd = _entry([(a.id, 1.0, 0.0), (b.id, 0.0, 1.0)])
    odd.lines[0].gold_weight_equiv = 0.3
    db.session.flush()
    with pytest.raises(UnmirroredLine):
        reverse_entry(odd, by='t', reason='x')


# ── the steps ────────────────────────────────────────────────────────────────

def test_a_duplicate_payment_entry_is_reversed_once(books):
    customer = _account(name='عميل نقدي')
    number = f'PAY-T-{uuid.uuid4().hex[:8]}'
    _entry([(customer.id, 8075.0, 0.0), (books['1100000'].id, 0.0, 8075.0)], ref_id=987650001, number=number)
    temp_before = _ledger(books['1100002'].id)

    dry = pkg.duplicate_payment_entries(by='t', dry_run=True, entries={number: 2012})
    assert dry[0]['reverse'] and _ledger(books['1100002'].id) == temp_before, 'a dry run writes nothing'
    pkg.duplicate_payment_entries(by='t', dry_run=False, entries={number: 2012})
    assert round(_ledger(books['1100002'].id) - temp_before, 2) == 8075.0
    again = pkg.duplicate_payment_entries(by='t', dry_run=False, entries={number: 2012})
    assert again == [{'entry': number, 'done': True}]


def test_a_payment_whose_invoice_exists_is_not_as_measured(books):
    from models import Invoice
    inv = Invoice(invoice_type='بيع', invoice_type_id=980000 + uuid.uuid4().int % 9999, date=DAY, total=1.0)
    db.session.add(inv)
    db.session.flush()
    number = f'PAY-T-{uuid.uuid4().hex[:8]}'
    _entry([(_account().id, 1.0, 0.0), (books['1100000'].id, 0.0, 1.0)], ref_id=inv.id, number=number)
    with pytest.raises(pkg.NotAsMeasured):
        pkg.duplicate_payment_entries(by='t', dry_run=True, entries={number: 1})


def _payment_voucher(entry, *, status='approved', number=None):
    v = Voucher(voucher_number=number or f'PV-T-{uuid.uuid4().hex[:6]}', voucher_type='payment', date=DAY,
                status=status, amount_cash=10000.0, journal_entry_id=entry.id if entry else None)
    db.session.add(v)
    db.session.flush()
    return v


def test_the_duplicate_salary_is_cancelled_and_its_entry_reversed(books):
    saleh = _account(name='صالح')
    e = _entry([(saleh.id, 10000.0, 0.0), (books['1100000'].id, 0.0, 10000.0)], ref_type='voucher')
    v = _payment_voucher(e)
    main_before, temp_before = _ledger(books['1100000'].id), _ledger(books['1100002'].id)
    pkg.duplicate_salary(by='t', dry_run=False, voucher_number=v.voucher_number)
    db.session.commit()   # the session guard (UNPOST-001) judges the cancelled voucher here
    assert v.status == 'cancelled'
    assert JournalEntry.query.filter_by(reference_type='voucher_reversal', reference_id=v.id, is_posted=True).count() == 1
    assert _ledger(saleh.id) == 0.0
    assert _ledger(books['1100000'].id) == main_before
    assert round(_ledger(books['1100002'].id) - temp_before, 2) == 10000.0
    assert pkg.duplicate_salary(by='t', dry_run=False, voucher_number=v.voucher_number)['done']


def test_a_deleted_payout_gets_its_entry_again_on_the_temporary_cash(books):
    saleh = _account(name='صالح')
    deleted = _entry([(saleh.id, 10000.0, 0.0), (books['1100000'].id, 0.0, 10000.0)], ref_type='voucher',
                     deleted=True)
    v = _payment_voucher(deleted)
    main_before, temp_before = _ledger(books['1100000'].id), _ledger(books['1100002'].id)
    pkg.deleted_payout(by='t', dry_run=False, voucher_number=v.voucher_number)
    new = db.session.get(JournalEntry, v.journal_entry_id)
    assert new.id != deleted.id and new.is_posted and new.date == v.date
    assert _ledger(saleh.id) == 10000.0
    assert _ledger(books['1100000'].id) == main_before
    assert round(_ledger(books['1100002'].id) - temp_before, 2) == -10000.0
    assert pkg.deleted_payout(by='t', dry_run=False, voucher_number=v.voucher_number)['done']


def test_an_approved_receipt_without_an_entry_is_posted_on_the_temporary_cash(books):
    acc = _account(name='عميل نقدي')
    customer = Customer(name=f'عميل {uuid.uuid4().hex[:5]}', customer_code=f'C-T-{uuid.uuid4().hex[:6]}',
                        account_id=acc.id)
    db.session.add(customer)
    db.session.flush()
    v = Voucher(voucher_number=f'RV-T-{uuid.uuid4().hex[:6]}', voucher_type='receipt', date=DAY,
                status='approved', amount_cash=3050.0, customer_id=customer.id)
    db.session.add(v)
    db.session.flush()
    main_before, temp_before = _ledger(books['1100000'].id), _ledger(books['1100002'].id)
    pkg.receipt_without_entry(by='t', dry_run=False, voucher_number=v.voucher_number)
    assert _ledger(acc.id) == -3050.0
    assert _ledger(books['1100000'].id) == main_before
    assert round(_ledger(books['1100002'].id) - temp_before, 2) == 3050.0
    assert pkg.receipt_without_entry(by='t', dry_run=False, voucher_number=v.voucher_number)['done']


def test_a_voucher_whose_entry_is_posted_is_approved_and_one_without_is_refused(books):
    a, b = _account(), _account()
    posted = _payment_voucher(_entry([(a.id, 1.0, 0.0), (b.id, 0.0, 1.0)], ref_type='voucher'), status='cancelled')
    bare = _payment_voucher(None, status='pending')
    pkg.vouchers_to_approve(by='t', dry_run=False, numbers=(posted.voucher_number,))
    assert posted.status == 'approved' and posted.cancelled_at is None
    with pytest.raises(pkg.NotAsMeasured):
        pkg.vouchers_to_approve(by='t', dry_run=True, numbers=(bare.voucher_number,))


def test_a_real_orphan_is_accepted_once(books):
    from services.books_invariants import list_findings
    number = f'JE-T-{uuid.uuid4().hex[:8]}'
    e = _entry([(_account().id, 3600.0, 0.0), (_account().id, 0.0, 3600.0)], ref_type='voucher',
               ref_id=987650002, number=number)
    pkg.accepted_orphans(by='t', dry_run=False, orphans={number: 'حقيقي'})
    keys = {f['subject_key'] for f in list_findings(status='accepted')}
    assert f'journal_entry:{e.id}' in keys
    assert pkg.accepted_orphans(by='t', dry_run=False, orphans={number: 'حقيقي'}) == [{'entry': number, 'done': True}]


def test_a_statement_follows_its_ledger_document_by_document_and_the_ledger_stays(books):
    """The main cash's shape: a payment the statement keyed to invoice 382 and
    the ledger to 442, and a receipt the statement never got."""
    from services.repair.statement_alignment import ALIGNMENT, align_statement
    cash = _account(name='صندوق')
    box = _safe(cash)
    other = _account()
    early, late = datetime(2026, 2, 1), datetime(2026, 3, 1)
    for ref_id, when, amount in ((987650100, early, 48100.0), (987650101, late, 900.0)):
        je = _entry([(cash.id, amount, 0.0), (other.id, 0.0, amount)], ref_type='stage4_test_doc', ref_id=ref_id)
        je.date = when
    db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='stage4_test_doc', ref_id=987650102,
                                      direction='in', amount_cash=48100.0, created_at=early, created_by='t'))
    db.session.flush()
    ledger_before = _ledger(cash.id)
    assert _statement_minus_ledger(box) == -900.0

    assert align_statement(box.id, by='t', dry_run=True)['written'] is False
    assert SafeBoxTransaction.query.filter_by(safe_box_id=box.id, ref_type=ALIGNMENT).count() == 0
    plan = align_statement(box.id, by='t', dry_run=False)
    assert plan['documents'] == 3 and plan['net'] == 900.0
    assert _statement_minus_ledger(box) == 0.0
    assert _ledger(cash.id) == ledger_before, 'the ledger is not touched'
    rows = SafeBoxTransaction.query.filter_by(safe_box_id=box.id, ref_type=ALIGNMENT).all()
    assert {r.created_at for r in rows} == {early, late}, 'each row on its document\'s day'
    assert align_statement(box.id, by='t', dry_run=False)['done']


def test_the_unposting_freeze_is_lifted_once(books):
    from models import Settings
    row = Settings.query.first() or Settings()
    db.session.add(row)
    row.allow_unposting = False
    db.session.flush()
    assert pkg.unposting_allowed(by='t', dry_run=True) == {'allow_unposting': {'from': False, 'to': True}}
    assert row.allow_unposting is False, 'a dry run writes nothing'
    pkg.unposting_allowed(by='t', dry_run=False)
    assert row.allow_unposting is True
    assert pkg.unposting_allowed(by='t', dry_run=False)['done']


def test_riyals_on_a_weight_account_move_to_its_twin_and_the_party_keeps_its_balance(books):
    """The Arab pound's shape: a reservation's weight entry wrote 59,250 riyals on
    the company's weight account; its two accounts read 7.48 together, the
    owner's real balance."""
    weight = _account(name='مورد وزني', tracks_weight=True)
    twin = _account(name='مورد', memo_account_id=weight.id)
    _safe(weight)
    scrap_w = _account(name='كسر وزني', tracks_weight=True)
    _entry([(twin.id, 59257.48, 0.0), (_account().id, 0.0, 59257.48)], ref_type='stage4_test_doc')
    number = f'WGT-T-{uuid.uuid4().hex[:6]}'
    _entry([(scrap_w.id, 59250.0, 0.0), (weight.id, 0.0, 59250.0)], ref_type='office_reservation', number=number)
    party_before = _ledger(weight.id) + _ledger(twin.id)
    rows_before = SafeBoxTransaction.query.filter_by(safe_box_id=_safe(weight).id).count()

    pkg.cash_moved_to_financial_twin(by='t', dry_run=False, account_number=weight.account_number, entries=(number,))
    assert _ledger(weight.id) == 0.0, 'the weight account carries no riyals'
    assert round(_ledger(weight.id) + _ledger(twin.id), 2) == round(party_before, 2) == 7.48
    assert SafeBoxTransaction.query.filter_by(safe_box_id=_safe(weight).id).count() == rows_before
    again = pkg.cash_moved_to_financial_twin(by='t', dry_run=False, account_number=weight.account_number,
                                             entries=(number,))
    assert again == [{'entry': number, 'done': True}]
