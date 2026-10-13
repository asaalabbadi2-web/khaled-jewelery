"""The count on the one reader (ADR-045 C1, the owner, 13 Oct 2026).

A count session read its expected weights from the old inventory ledger, and
its approval wrote the difference there alone: the books never knew of a
shortage or a surplus -- one root of the three answers to the stock. Now:

- a session's expected weights are the stock itself (services/stock_ledger),
  per (location, category, karat), frozen when it opens;
- its approval writes ONE posted entry -- per location and karat, the
  shortage out of the safe against «خسارة الوزن (الفقد)» (role
  inventory_count_shortage), the surplus into it against «زيادة جرد» (role
  inventory_count_surplus), each safe line allocated to its categories -- so
  the books hold, per (location, category, karat), what was counted;
- grams only for now: the value line comes with the two pools' accounts
  (ADR-042 phase 3); 2026's last count needs none (ADR-044 opens 2027 at the
  opening average).

Run:
    python -m pytest tests/test_stock_count.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (Account, AccountingMapping, Category, InventoryCountLine, JournalEntry, JournalEntryLine,
                    SafeBox, db)

NOW = datetime(2026, 12, 31, 18, 0)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:8]


def _pair(name, kind):
    """A financial account and its weight twin, as the chart pairs them."""
    weight = Account(account_number=f'7{_uid()[:6]}', name=f'{name} وزني', type=kind, tracks_weight=True)
    db.session.add(weight)
    db.session.flush()
    fin = Account(account_number=f'5{_uid()[:6]}', name=name, type=kind, memo_account_id=weight.id)
    db.session.add(fin)
    db.session.flush()
    weight.memo_account_id = fin.id
    db.session.flush()
    return fin, weight


@pytest.fixture
def roles():
    shortage, shortage_w = _pair('خسارة الوزن (الفقد)', 'Expense')
    surplus, surplus_w = _pair('زيادة جرد', 'Revenue')
    for role, acc in (('inventory_count_shortage', shortage), ('inventory_count_surplus', surplus)):
        AccountingMapping.query.filter_by(operation_type='افتراضي', account_type=role).delete()
        db.session.add(AccountingMapping(operation_type='افتراضي', account_type=role, account_id=acc.id,
                                         is_active=True))
    db.session.flush()
    return {'shortage_w': shortage_w, 'surplus_w': surplus_w}


def _safe(location='showroom'):
    account = Account(account_number=f'9{_uid()[:6]}', name=f'ح {_uid()}', type='Asset', tracks_weight=True)
    db.session.add(account)
    db.session.flush()
    box = SafeBox(name=f'خزينة {_uid()}', safe_type='gold', account_id=account.id, is_active=True,
                  stock_location=location)
    db.session.add(box)
    db.session.flush()
    return box


def _category():
    c = Category(name=f'تصنيف {_uid()}', karat='21')
    db.session.add(c)
    db.session.flush()
    return c


def _stock(box, grams, category=None, karat=21):
    """Gold in a stock safe, as a posted entry -- allocated when a category is given."""
    from services.stock_ledger import allocate
    je = JournalEntry(entry_number=f'JE-C-{_uid()}', date=datetime(2026, 12, 1), description='رصيد',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, description='رصيد',
                            **{f'debit_{karat}k': grams})
    db.session.add(line)
    db.session.flush()
    if category is not None:
        allocate(line, karat, category.id, grams, by='t', now=NOW)


def _held(box):
    from services.stock_ledger import stock_balances
    return {(r['category_id'], r['karat']): r['grams'] for r in stock_balances() if r['safe_box_id'] == box.id}


def _count(box, counted, roles):
    """Open a count of one location, count it, close and approve it."""
    from services.inventory_count_service import InventoryCountService as S
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
    S.populate_lines(session)
    for (category_id, karat), grams in counted.items():
        S.record_count(session, category_id=category_id, karat=karat, counted_weight=grams,
                       counted_by='t', now=NOW, safe_box_id=box.id)
    S.close_session(session, force=True, now=NOW)
    return S.approve_session(session, approved_by='المدير', now=NOW)


class TestTheSessionReadsTheStock:

    def test_its_lines_are_the_stock_by_category_frozen_at_opening(self, app):
        from services.inventory_count_service import InventoryCountService as S
        box, ring = _safe(), _category()
        _stock(box, 20.0, ring)
        _stock(box, 5.0)
        session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
        S.populate_lines(session)
        lines = {(l.category_id, l.karat): l.expected_weight for l in InventoryCountLine.query.filter_by(session_id=session.id)}
        assert lines == {(ring.id, 21.0): 20.0, (None, 21.0): 5.0}
        assert {l.safe_box_id for l in InventoryCountLine.query.filter_by(session_id=session.id)} == {box.id}

    def test_one_open_session_per_location(self, app):
        from services.inventory_count_service import InventoryCountService as S
        box = _safe()
        S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
        with pytest.raises(ValueError):
            S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)


class TestTheApprovalWritesTheBooks:

    def test_a_shortage_leaves_the_safe_against_the_loss_account(self, app, roles):
        box, ring = _safe(), _category()
        _stock(box, 20.0, ring)
        session, entry = _count(box, {(ring.id, 21.0): 18.5}, roles)
        assert entry is not None and entry.is_posted and session.entry_id == entry.id
        assert _held(box) == {(ring.id, 21): 18.5}, 'the books hold what was counted'
        loss = [l for l in entry.lines if l.account_id == roles['shortage_w'].id]
        assert [(l.debit_21k, l.credit_21k) for l in loss] == [(1.5, 0.0)] or \
               [(l.debit_21k, l.credit_21k or 0.0) for l in loss] == [(1.5, 0.0)]

    def test_a_surplus_enters_the_safe_against_the_surplus_account(self, app, roles):
        box, ring = _safe(), _category()
        _stock(box, 20.0, ring)
        _, entry = _count(box, {(ring.id, 21.0): 22.0}, roles)
        assert _held(box) == {(ring.id, 21): 22.0}
        gain = [l for l in entry.lines if l.account_id == roles['surplus_w'].id]
        assert [round(l.credit_21k or 0.0, 3) for l in gain] == [2.0]

    def test_a_shortage_and_a_surplus_in_one_karat_are_two_safe_lines(self, app, roles):
        """The allocation law keeps a line's sign: categories short and over
        cannot share one safe line."""
        box, ring, chain = _safe(), _category(), _category()
        _stock(box, 20.0, ring)
        _stock(box, 10.0, chain)
        _, entry = _count(box, {(ring.id, 21.0): 17.0, (chain.id, 21.0): 11.0}, roles)
        assert _held(box) == {(ring.id, 21): 17.0, (chain.id, 21): 11.0}
        assert len([l for l in entry.lines if l.account_id == box.account_id]) == 2

    def test_the_unclassified_is_counted_too(self, app, roles):
        box = _safe()
        _stock(box, 5.0)
        _count(box, {(None, 21.0): 4.0}, roles)
        assert _held(box) == {(None, 21): 4.0}

    def test_no_difference_writes_no_entry(self, app, roles):
        box, ring = _safe(), _category()
        _stock(box, 20.0, ring)
        session, entry = _count(box, {(ring.id, 21.0): 20.0}, roles)
        assert entry is None and session.status == 'approved'

    def test_the_entry_balances_in_every_karat_and_its_weight_column(self, app, roles):
        box, ring, chain = _safe(), _category(), _category()
        _stock(box, 20.0, ring)
        _stock(box, 10.0, chain)
        _, entry = _count(box, {(ring.id, 21.0): 17.0, (chain.id, 21.0): 11.0}, roles)
        for col in ('21k', 'weight'):
            debit = sum(getattr(l, f'debit_{col}') or 0.0 for l in entry.lines)
            credit = sum(getattr(l, f'credit_{col}') or 0.0 for l in entry.lines)
            assert debit == pytest.approx(credit), col
        assert entry.date == NOW and entry.reference_type == 'inventory_count'

    def test_an_unmapped_role_refuses_the_approval(self, app):
        from services.inventory_count_service import InventoryCountService as S
        AccountingMapping.query.filter(AccountingMapping.account_type.in_(
            ['inventory_count_shortage', 'inventory_count_surplus'])).delete(synchronize_session=False)
        box, ring = _safe(), _category()
        _stock(box, 20.0, ring)
        session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
        S.populate_lines(session)
        S.record_count(session, category_id=ring.id, karat=21.0, counted_weight=19.0, counted_by='t',
                       now=NOW, safe_box_id=box.id)
        S.close_session(session, force=True, now=NOW)
        with pytest.raises(ValueError):
            S.approve_session(session, approved_by='المدير', now=NOW)

    def test_the_old_inventory_ledger_is_not_written(self, app, roles):
        from models import InventoryLedger
        before = InventoryLedger.query.count()
        box, ring = _safe(), _category()
        _stock(box, 20.0, ring)
        _count(box, {(ring.id, 21.0): 18.0}, roles)
        assert InventoryLedger.query.count() == before

    def test_the_safe_statement_moves_with_the_entry(self, app, roles):
        """A gold safe's statement is checked against its ledger every night
        (SAFEBOX_GOLD_DRIFT): the count's entry writes its rows too."""
        from models import SafeBoxTransaction
        box, ring = _safe(), _category()
        _stock(box, 20.0, ring)
        _, entry = _count(box, {(ring.id, 21.0): 18.5}, roles)
        rows = SafeBoxTransaction.query.filter_by(safe_box_id=box.id, ref_type='inventory_count',
                                                  ref_id=entry.id).all()
        assert [(r.direction, round(r.weight_21k, 3)) for r in rows] == [('out', 1.5)]


class TestClassifyingIsNotALossOrAGain:
    """A count that finds 250 g «بلا تصنيف» short and 200 g of bangles over has
    lost 50 g, not 250 and gained 200: the rest moved between categories. The
    rehearsal on the 12 Oct copy booked both in full; 31 Dec, classifying
    ~22 kg, would have booked a loss and a gain of 22 kg each. Per location and
    karat only the net reaches the shortage or surplus account."""

    def test_only_the_net_is_a_shortage(self, app, roles):
        box, bangle = _safe(), _category()
        _stock(box, 300.0)
        _, entry = _count(box, {(None, 21.0): 50.0, (bangle.id, 21.0): 200.0}, roles)
        assert _held(box) == {(None, 21): 50.0, (bangle.id, 21): 200.0}
        loss = sum((l.debit_21k or 0.0) - (l.credit_21k or 0.0) for l in entry.lines if l.account_id == roles['shortage_w'].id)
        gain = sum((l.credit_21k or 0.0) - (l.debit_21k or 0.0) for l in entry.lines if l.account_id == roles['surplus_w'].id)
        assert (round(loss, 3), round(gain, 3)) == (50.0, 0.0)

    def test_a_pure_reclassification_touches_neither_account(self, app, roles):
        box, ring = _safe(), _category()
        _stock(box, 10.0)
        _, entry = _count(box, {(None, 21.0): 0.0, (ring.id, 21.0): 10.0}, roles)
        assert _held(box) == {(ring.id, 21): 10.0}
        assert not [l for l in entry.lines if l.account_id in (roles['shortage_w'].id, roles['surplus_w'].id)]


def test_a_count_awaiting_approval_holds_its_location(app, roles):
    """A closed session was reachable from no screen, and another could be opened
    for the same location -- two counts awaiting one approval (found walking the
    screens on the 12 Oct copy)."""
    from services.inventory_count_service import InventoryCountService as S
    box, ring = _safe(), _category()
    _stock(box, 20.0, ring)
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
    S.populate_lines(session)
    S.close_session(session, force=True, now=NOW)
    with pytest.raises(ValueError, match='بانتظار الاعتماد'):
        S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
