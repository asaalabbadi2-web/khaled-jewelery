"""Gold safes: the statement follows the ledger, and two ledger corrections
(stage-4 items 12, 13, 15; the owner, 12 Oct 2026).

- Item 13: the display safe's (30) and Al-Junaih's (41) statements drifted
  from their ledgers -- 78 supplier purchases with no row (9,528.47 g), 17
  reservation purchases with a row and no entry (3,388.84 g), sales whose row
  outweighed their entry, a deleted invoice's row, and two «تسوية تاريخية»
  rows written on 13 Jun on the statement alone. The owner: the safes match
  reality -- their balances, which are the ledger's, do not move. Per document
  and karat the difference becomes one statement row, as for the cash safes
  (services/repair/statement_alignment.py).
- Item 12: invoice 992's 59.6 g is twice in the ledger -- its entry and the
  manual JE-2026-01881 «استلام كسر ذهب مفقود». The main scrap safe matches
  reality: the second credit to purchases (7512) is the error, and the gold
  came from the reserve scrap safe (71310002), not a purchase. The main scrap
  safe and the Riyadh bank are not touched (the owner).
- Rows copying a manual entry (items 12, 15): a manual entry writes no row and
  the check leaves it out on both sides, but two rows copy one under another
  type -- the main scrap safe's second 992 row, Al-Raqi's 396.6 g (the owner:
  it holds them). Accepted, only as measured; nothing written. (A first plan
  put Al-Raqi's grams into the ledger again: the rehearsal doubled its
  balance.)

Run:
    python -m pytest tests/test_gold_statements_repair.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, db
from services.repair import gold_statements as gs
from services.repair.entries import PROTECTED_ACCOUNT_NUMBERS, SUBSTITUTES, ProtectedAccount, write_entry
from services.safebox_subledger import gold_subledger_by_box


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


NOW = datetime(2026, 10, 12, 12, 0)


def _account(number=None, name='حساب وزني', type_='Asset'):
    number = number or f'79{uuid.uuid4().hex[:8]}'
    found = Account.query.filter_by(account_number=number).first()
    if found:
        return found
    a = Account(account_number=number, name=name, type=type_, tracks_weight=True)
    db.session.add(a)
    db.session.flush()
    return a


def _safe(account, name='خزينة ذهب اختبار'):
    s = SafeBox(name=f'{name} {uuid.uuid4().hex[:4]}', safe_type='gold', account_id=account.id, is_active=True)
    db.session.add(s)
    db.session.flush()
    return s


def _entry(lines, *, ref_type='invoice', ref_id=None, date=datetime(2026, 4, 1), number=None):
    je = JournalEntry(entry_number=number or f'JE-T-{uuid.uuid4().hex[:6]}', date=date, description='اختبار',
                      entry_type='عادي', reference_type=ref_type, reference_id=ref_id,
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for spec in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, weight_type='ANALYTICAL', **spec))
    db.session.flush()
    return je


def _row(safe, direction, *, ref_type='invoice_gold', ref_id=None, invoice_id=None, created_at=None, **karats):
    t = SafeBoxTransaction(safe_box_id=safe.id, ref_type=ref_type, ref_id=ref_id, invoice_id=invoice_id,
                           direction=direction, created_at=created_at or datetime(2026, 4, 1), created_by='t',
                           **{f'weight_{k}': v for k, v in karats.items()})
    db.session.add(t)
    db.session.flush()
    return t


def _drift(safe):
    return {k: round(s - l, 3) for k, (s, l) in gold_subledger_by_box([safe.id])[safe.id].items()}


# ── item 13: the statement follows the ledger ──

def test_each_document_brings_its_statement_to_its_ledger_and_the_balance_does_not_move():
    acc, other = _account(), _account()
    safe = _safe(acc)
    # A purchase posted with no statement row (S1).
    _entry([{'account_id': acc.id, 'debit_21k': 100.0}, {'account_id': other.id, 'credit_21k': 100.0}],
           ref_type='voucher', ref_id=987654)
    # A row with no entry behind it (a reservation's purchase, a deleted invoice).
    _row(safe, 'in', ref_type='ledger_balance_adjustment', created_at=datetime(2026, 6, 13), **{'24k': 40.0})
    # A document whose row and entry disagree karat by karat, both ways.
    _entry([{'account_id': acc.id, 'credit_18k': 10.0, 'debit_22k': 3.0},
            {'account_id': other.id, 'debit_18k': 10.0, 'credit_22k': 3.0}], ref_type='voucher', ref_id=987655)
    _row(safe, 'out', ref_type='voucher', ref_id=987655, **{'18k': 5.0})
    # A manual entry counts on neither side.
    _entry([{'account_id': acc.id, 'debit_21k': 7.0}, {'account_id': other.id, 'credit_21k': 7.0}],
           ref_type='manual')
    balance_before = _ledger_grams(acc)
    assert _drift(safe) == {'18k': 5.0, '21k': -100.0, '22k': -3.0, '24k': 40.0}

    dry = gs.align_gold_statement(safe.id, by='t', dry_run=True)
    assert dry['documents'] == 3 and not dry['written']
    assert not SafeBoxTransaction.query.filter_by(safe_box_id=safe.id, ref_type=gs.ALIGNMENT).first(), 'dry run writes nothing'

    gs.align_gold_statement(safe.id, by='t', dry_run=False)
    assert _drift(safe) == {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}, 'the nightly check closes'
    assert _ledger_grams(acc) == balance_before, 'the ledger -- the balance -- is not touched'
    mixed = SafeBoxTransaction.query.filter_by(safe_box_id=safe.id, ref_type=gs.ALIGNMENT, ref_id=987655).all()
    assert sorted(r.direction for r in mixed) == ['in', 'out'], 'a karat up and a karat down: a row each way'
    adjustment = SafeBoxTransaction.query.filter_by(safe_box_id=safe.id, ref_type=gs.ALIGNMENT, ref_id=None).one()
    assert adjustment.created_at == datetime(2026, 6, 13), 'dated at the document'
    assert gs.align_gold_statement(safe.id, by='t', dry_run=False)['done'], 'once per safe'


def _ledger_grams(account):
    lines = JournalEntryLine.query.filter_by(account_id=account.id).all()
    return {k: round(sum(float(getattr(l, f'debit_{k}') or 0) - float(getattr(l, f'credit_{k}') or 0)
                         for l in lines), 3) for k in ('18k', '21k', '22k', '24k')}


# ── the guard: the main scrap safe matches reality ──

def test_the_main_scrap_safe_is_protected_and_its_twin_is_the_reserve():
    assert '71310000' in PROTECTED_ACCOUNT_NUMBERS
    assert SUBSTITUTES['71310000'] == '71310002'
    main = _account('71310000', 'صندوق الكسر الرئيسي وزني')
    other = _account()
    with pytest.raises(ProtectedAccount):
        write_entry(date=datetime(2026, 4, 17), description='x', reference_type='t', reference_id=None,
                    lines=[{'account_id': main.id, 'debit_21k': 1.0}, {'account_id': other.id, 'credit_21k': 1.0}],
                    by='t', now=NOW)


def test_a_gold_line_on_a_safe_writes_its_statement_row():
    acc, other = _account(), _account()
    safe = _safe(acc)
    write_entry(date=datetime(2026, 4, 17), description='تصحيح', reference_type='t', reference_id=None,
                lines=[{'account_id': acc.id, 'credit_21k': 59.6, 'debit_24k': 2.0},
                       {'account_id': other.id, 'debit_21k': 59.6, 'credit_24k': 2.0}], by='t', now=NOW)
    assert _drift(safe) == {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}, 'the statement moves with the ledger'


# ── item 12: invoice 992 purchased twice ──

def _item12_books():
    main = _account('71310000', 'صندوق الكسر الرئيسي وزني')
    reserve = _account('71310002', 'صندوق الكسر الرئيسي احتياطي')
    purchases = _account('7512', 'مشتريات ذهب كسر من العملاء وزني')
    reserve_safe = SafeBox.query.filter_by(account_id=reserve.id).first() or _safe(reserve, 'احتياطي')
    manual = (JournalEntry.query.filter_by(entry_number=gs.DUPLICATE_ENTRY).first()
              or _entry([{'account_id': main.id, 'debit_21k': 59.6},
                         {'account_id': purchases.id, 'credit_21k': 59.6}],
                        ref_type=None, number=gs.DUPLICATE_ENTRY, date=datetime(2026, 4, 17)))
    return main, reserve, purchases, reserve_safe, manual


def test_the_second_purchase_of_992_comes_back_from_the_reserve_not_the_main_safe():
    main, reserve, purchases, reserve_safe, manual = _item12_books()
    before = _ledger_grams(main)

    plan = gs.duplicate_purchase_992(by='t', now=NOW, dry_run=True)
    assert plan['grams_21k'] == pytest.approx(59.6) and not plan['written']

    gs.duplicate_purchase_992(by='t', now=NOW, dry_run=False)
    fix = JournalEntry.query.filter_by(reference_type=gs.DUPLICATE_FIX, reference_id=manual.id).one()
    assert fix.date == manual.date
    lines = {l.account_id: l for l in fix.lines}
    assert lines[purchases.id].debit_21k == pytest.approx(59.6)
    assert lines[reserve.id].credit_21k == pytest.approx(59.6)
    assert main.id not in lines and _ledger_grams(main) == before, 'the main scrap safe is not touched'
    assert _drift(reserve_safe)['21k'] == 0.0, 'the reserve\'s statement moves with its ledger'
    assert gs.duplicate_purchase_992(by='t', now=NOW, dry_run=False)['done']


def test_992_is_refused_when_the_manual_entry_is_not_as_measured():
    main, reserve, purchases, _, manual = _item12_books()
    line = next(l for l in manual.lines if l.account_id == main.id)
    line.debit_21k = 60.0
    db.session.flush()
    with pytest.raises(gs.NotAsMeasured):
        gs.duplicate_purchase_992(by='t', now=NOW, dry_run=True)


# ── rows copying a manual entry: accepted, only as measured ──

def _office_with_a_copied_row(grams=396.6):
    office, display = _account(name='مكتب اختبار'), _account()
    safe = _safe(office, 'مكتب')
    manual = _entry([{'account_id': office.id, 'debit_21k': 396.6}, {'account_id': display.id, 'credit_21k': 396.6}],
                    ref_type=None, number=f'JE-T-{uuid.uuid4().hex[:6]}', date=datetime(2026, 2, 26))
    _row(safe, 'in', ref_type='opening_balance', ref_id=manual.id, created_at=datetime(2026, 3, 16), **{'21k': grams})
    return office, safe, manual


def test_a_row_copying_a_manual_entry_is_accepted_and_nothing_written():
    from services.books_invariants import ReconciliationFinding
    office, safe, manual = _office_with_a_copied_row()
    copies = {office.account_number: (manual.entry_number, '21k', 396.6)}
    entries_before = JournalEntry.query.count()

    plan = gs.accept_manual_copies(by='t', now=NOW, dry_run=True, copies=copies)
    assert plan[0]['subject'] == f'safe_box:{safe.id}:21k'
    assert not ReconciliationFinding.query.filter_by(subject_key=plan[0]['subject']).first(), 'dry run writes nothing'

    gs.accept_manual_copies(by='t', now=NOW, dry_run=False, copies=copies)
    finding = ReconciliationFinding.query.filter_by(subject_key=plan[0]['subject'], resolved_at=None).one()
    assert finding.accepted_at and manual.entry_number in finding.accepted_reason
    assert JournalEntry.query.count() == entries_before, 'no entry: the ledger already holds it'
    assert _ledger_grams(office)['21k'] == 396.6


def test_a_copy_not_as_measured_is_refused():
    office, safe, manual = _office_with_a_copied_row(grams=400.0)
    with pytest.raises(gs.NotAsMeasured):
        gs.accept_manual_copies(by='t', now=NOW, dry_run=True,
                                copies={office.account_number: (manual.entry_number, '21k', 396.6)})
