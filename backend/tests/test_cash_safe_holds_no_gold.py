"""A cash or bank safe holds no gold (the owner, 14 Nov 2026).

«راجع صندوق النقدية المالي عليه وزن قديم»: a customer's purchase of 17 Feb
2026 credited its 98.26 g of 24k to the main cash box's weight twin, and the
cash box read -98.26 g for nine months -- nothing refused it, nothing said it.
The laws:
  - no line moves a cash or bank safe's weight twin away from zero, on any
    ORM path -- refused by name; a line bringing it back toward zero is written;
  - a gold safe's twin is not judged; riyals on a cash safe's twin are not grams;
  - the nightly check CASH_SAFE_HOLDS_GOLD says what is left past the guard;
  - the correction moves the old line's own grams to the purchases' weight
    twin, dated as it, once; refused, writing nothing, when anything else
    moved the cash safe's twin.

Run:
    python -m pytest tests/test_cash_safe_holds_no_gold.py -v
"""
import datetime as dt
import uuid

import pytest
from sqlalchemy import text

from account_pair_service import link_accounts
from app import app as flask_app
from cash_safe_gold_guard import CashSafeHoldsNoGold
from models import Account, Invoice, JournalEntry, JournalEntryLine, SafeBox, db

NOW = dt.datetime(2026, 11, 14, 12, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _account(weight, kind='Asset'):
    a = Account(account_number=f'9{uuid.uuid4().int % 10**7:07d}', name=f'حساب {uuid.uuid4().hex[:5]}', type=kind,
                transaction_type='gold' if weight else 'cash', tracks_weight=weight)
    db.session.add(a)
    db.session.flush()
    return a


def _safe(safe_type='cash'):
    cash, twin = _account(False), _account(True)
    link_accounts(cash, twin, created_by='test')
    safe = SafeBox(name=f'صندوق {uuid.uuid4().hex[:5]}', safe_type=safe_type, account_id=cash.id, is_active=True)
    db.session.add(safe)
    db.session.flush()
    return safe, cash, twin


def _entry(day=dt.datetime(2026, 2, 17, 19, 55), **kw):
    je = JournalEntry(entry_number=f'JE-CS-{uuid.uuid4().hex[:6]}', date=day, description='t', entry_type='عادي',
                      is_posted=True, is_draft=False, is_deleted=False, created_by='t', **kw)
    db.session.add(je)
    db.session.flush()
    return je


def _line(je, account, **cols):
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, **cols))
    db.session.flush()


def _legacy_line(je, account, **cols):
    """A line as the older writer left it: past the mappers, as the books hold it."""
    names = ', '.join(['journal_entry_id', 'account_id', 'is_deleted', 'cash_debit', 'cash_credit'] + list(cols))
    values = ', '.join([':je', ':acc', ':no', '0', '0'] + [f':{c}' for c in cols])
    db.session.execute(text(f'INSERT INTO journal_entry_line ({names}) VALUES ({values})'),
                       {'je': je.id, 'acc': account.id, 'no': False, **cols})


# ── the guard ──────────────────────────────────────────────────────────────

def test_grams_onto_a_cash_safes_twin_are_refused_by_name():
    safe, _, twin = _safe()
    with pytest.raises(CashSafeHoldsNoGold, match=safe.name):
        _line(_entry(), twin, credit_24k=98.26, credit_weight=112.297143)
    db.session.rollback()


def test_a_bank_too_and_a_gold_safe_is_not_judged():
    _, _, bank_twin = _safe('bank')
    with pytest.raises(CashSafeHoldsNoGold):
        _line(_entry(), bank_twin, debit_21k=1.0)
    db.session.rollback()
    _, _, gold_twin = _safe('gold')
    _line(_entry(), gold_twin, debit_21k=1.0)                       # a gold safe holds gold


def test_riyals_on_the_twin_are_not_grams():
    _, _, twin = _safe()
    _line(_entry(), twin, cash_debit=10.0)


def test_a_line_bringing_it_back_to_zero_is_written_and_one_past_zero_is_not():
    _, _, twin = _safe()
    je = _entry()
    _legacy_line(je, twin, credit_24k=98.26)
    _line(_entry(), twin, debit_24k=98.26)                          # back to zero: written
    with pytest.raises(CashSafeHoldsNoGold):
        _line(_entry(), twin, debit_24k=0.01)                       # past it: refused
    db.session.rollback()


def test_a_line_edited_onto_the_twin_is_refused():
    _, _, twin = _safe()
    other = _account(True)
    je = _entry()
    _line(je, other, debit_21k=2.0)
    line = JournalEntryLine.query.filter_by(journal_entry_id=je.id).one()
    line.account_id = twin.id
    with pytest.raises(CashSafeHoldsNoGold):
        db.session.flush()
    db.session.rollback()


# ── the nightly check ──────────────────────────────────────────────────────

def test_the_night_says_a_cash_safe_holding_grams_and_not_one_at_zero():
    from services.books_invariants import CASH_SAFE_HOLDS_GOLD, CHECKS
    safe, _, twin = _safe()
    _legacy_line(_entry(), twin, credit_24k=98.26)
    held, _, zero = _safe()
    facts = {f.subject_key: f for f in CHECKS[CASH_SAFE_HOLDS_GOLD]()}
    assert facts[f'safe_box:{safe.id}'].detail['grams']['24k'] == -98.26
    assert f'safe_box:{held.id}' not in facts


# ── the correction ─────────────────────────────────────────────────────────

def _purchase_as_it_was():
    """«شراء من عميل» #1 as JE-2026-00066 holds it: the scrap safe debited, the cash box's twin credited."""
    safe, cash, twin = _safe()
    scrap, purchases_twin = _account(True), _account(True, 'Expense')
    inv = Invoice(invoice_type='شراء من عميل', invoice_type_id=1, date=dt.datetime(2026, 2, 17, 19, 55),
                  total=54956.82, total_weight=98.26, gold_type='scrap', is_posted=True)
    db.session.add(inv)
    db.session.flush()
    je = _entry(reference_type='invoice', reference_id=inv.id)
    _line(je, cash, cash_credit=54956.82)
    _line(je, scrap, debit_24k=98.26, debit_weight=112.297143)
    _legacy_line(je, twin, credit_24k=98.26, credit_weight=112.297143)
    return {'safe': safe, 'twin': twin, 'to': purchases_twin, 'entry': je}


def _held(account):
    rows = JournalEntryLine.query.filter_by(account_id=account.id).filter(JournalEntryLine.is_deleted.isnot(True))
    return {c: round(sum(float(getattr(l, f'debit_{c}') or 0) - float(getattr(l, f'credit_{c}') or 0) for l in rows), 6)
            for c in ('24k', 'weight')}


def test_the_old_line_moves_to_the_purchases_dated_as_it_once():
    from services.repair.cash_safe_gold import move
    w = _purchase_as_it_was()
    done = move(by='t', now=NOW, entry_number=w['entry'].entry_number, to_account=w['to'])
    assert done['grams'] == {'24k': 98.26, 'weight': 112.297143} and done['date'] == '2026-02-17'
    assert _held(w['twin']) == {'24k': 0.0, 'weight': 0.0}
    assert _held(w['to']) == {'24k': -98.26, 'weight': -112.297143}
    assert move(by='t', now=NOW, entry_number=w['entry'].entry_number, to_account=w['to'])['already'] is True
    assert {f.subject_key for f in __import__('services.books_invariants', fromlist=['x'])
            .check_cash_safes_hold_no_gold()}.isdisjoint({f"safe_box:{w['safe'].id}"})


def test_anything_else_on_the_twin_refuses_it_writing_nothing():
    from services.repair.cash_safe_gold import MOVED, NotAsFound, move
    w = _purchase_as_it_was()
    _legacy_line(_entry(), w['twin'], credit_24k=1.0)                  # another line moved it
    with pytest.raises(NotAsFound):
        move(by='t', now=NOW, entry_number=w['entry'].entry_number, to_account=w['to'])
    assert JournalEntry.query.filter_by(reference_type=MOVED, reference_id=w['entry'].id).count() == 0


def test_not_a_customer_purchase_is_refused():
    from services.repair.cash_safe_gold import NotAsFound, move
    _, _, twin = _safe()
    je = _entry()
    _legacy_line(je, twin, credit_24k=2.0)
    with pytest.raises(NotAsFound, match='customer purchase'):
        move(by='t', now=NOW, entry_number=je.entry_number, to_account=_account(True))
