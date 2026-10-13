"""The stock is the entry lines themselves (ADR-045 A1, the owner, 13 Oct 2026).

Three answers to «how much gold do we hold» on the 12 Oct copy. Copying entry
lines into a second ledger cannot hold: an entry is posted from some 40 places
and some delete lines in bulk, which no watcher sees. So the stock is read
from the posted lines on the accounts of stock safes (safe_box.stock_location)
-- location from the safe, karat and grams from the line -- and a category is
an allocation of a line's grams (stock_line_allocation), written by the
document that knows it, in its posting's transaction. Law: a line's
allocations for a karat never exceed its grams there, and carry its sign;
what is not allocated is «بلا تصنيف». Deleting a line deletes its allocations.

Measured on the 12 Oct copy: in all 461 invoices since 1 Sep, an invoice's
item weights per karat equal its stock lines' grams -- so an invoice
allocates exactly.

Run:
    python -m pytest tests/test_stock_ledger.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, Category, Invoice, InvoiceItem, JournalEntry, JournalEntryLine, SafeBox, db


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


def _safe(location='showroom'):
    account = Account(account_number=f'9{_uid()[:6]}', name=f'ح {_uid()}', type='Asset', tracks_weight=True)
    db.session.add(account)
    db.session.flush()
    box = SafeBox(name=f'خزينة ذهب {_uid()}', safe_type='gold', account_id=account.id, is_active=True,
                  stock_location=location)
    db.session.add(box)
    db.session.flush()
    return box


def _category(name=None, karat='21'):
    c = Category(name=name or f'تصنيف {_uid()}', karat=karat)
    db.session.add(c)
    db.session.flush()
    return c


def _line(box, *, posted=True, reference_type='invoice', reference_id=None, **grams):
    je = JournalEntry(entry_number=f'JE-S-{_uid()}', date=datetime(2026, 10, 13), description='اختبار',
                      entry_type='عادي', is_posted=posted, is_draft=not posted, created_by='t',
                      reference_type=reference_type, reference_id=reference_id)
    db.session.add(je)
    db.session.flush()
    line = JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, description='اختبار', **grams)
    db.session.add(line)
    db.session.flush()
    return line


def _balances(box):
    from services.stock_ledger import stock_balances
    return {(r['karat'], r['category_id']): r['grams'] for r in stock_balances() if r['safe_box_id'] == box.id}


class TestTheAllocationLaw:

    def test_a_line_is_allocated_up_to_its_grams(self, app):
        from services.stock_ledger import allocate
        box, ring, chain = _safe(), _category(), _category()
        line = _line(box, credit_21k=30.0)
        allocate(line, 21, ring.id, -20.0, by='t')
        allocate(line, 21, chain.id, -10.0, by='t')
        assert _balances(box) == {(21, ring.id): -20.0, (21, chain.id): -10.0}

    def test_more_than_the_line_holds_is_refused(self, app):
        from services.stock_ledger import StockAllocationError, allocate
        box, ring = _safe(), _category()
        line = _line(box, credit_21k=30.0)
        allocate(line, 21, ring.id, -25.0, by='t')
        with pytest.raises(StockAllocationError):
            allocate(line, 21, ring.id, -5.01, by='t')

    def test_the_line_sign_is_kept(self, app):
        from services.stock_ledger import StockAllocationError, allocate
        box, ring = _safe(), _category()
        line = _line(box, credit_21k=30.0)
        with pytest.raises(StockAllocationError):
            allocate(line, 21, ring.id, 10.0, by='t')

    def test_a_karat_the_line_does_not_hold_is_refused(self, app):
        from services.stock_ledger import StockAllocationError, allocate
        box, ring = _safe(), _category()
        line = _line(box, debit_21k=30.0)
        with pytest.raises(StockAllocationError):
            allocate(line, 18, ring.id, 5.0, by='t')

    def test_a_line_that_is_not_stock_is_refused(self, app):
        """An office's gold safe: gold owed, not stock."""
        from services.stock_ledger import StockAllocationError, allocate
        box, ring = _safe(location=None), _category()
        line = _line(box, debit_21k=30.0)
        with pytest.raises(StockAllocationError):
            allocate(line, 21, ring.id, 5.0, by='t')


class TestTheOneReader:

    def test_what_is_not_allocated_is_unclassified(self, app):
        from services.stock_ledger import allocate
        box, ring = _safe(), _category()
        line = _line(box, debit_21k=30.0, debit_18k=4.0)
        allocate(line, 21, ring.id, 20.0, by='t')
        assert _balances(box) == {(21, ring.id): 20.0, (21, None): 10.0, (18, None): 4.0}

    def test_it_is_the_books_on_stock_safes_only(self, app):
        """Unposted lines and an office's safe count nowhere; the karat totals
        are the books' to the gram -- one record, not two."""
        from services.live_balances import live_balances_by_account_ids
        box, office = _safe(), _safe(location=None)
        _line(box, debit_21k=30.0)
        _line(box, posted=False, debit_21k=500.0)
        _line(office, debit_21k=70.0)
        assert _balances(box) == {(21, None): 30.0}
        assert _balances(office) == {}
        assert live_balances_by_account_ids([box.account_id])[box.account_id]['21k'] == 30.0

    def test_deleting_a_line_in_bulk_deletes_its_allocations(self, app):
        """Invoice deletion and journal edits delete lines with Query.delete(),
        which no ORM event sees: the database cascades."""
        from models import StockLineAllocation
        from services.stock_ledger import allocate
        box, ring = _safe(), _category()
        line = _line(box, debit_21k=30.0)
        allocate(line, 21, ring.id, 30.0, by='t')
        line_id = line.id
        JournalEntryLine.query.filter_by(id=line_id).delete(synchronize_session=False)
        db.session.flush()
        assert StockLineAllocation.query.filter_by(journal_entry_line_id=line_id).count() == 0


class TestTheInvoiceAllocates:

    @staticmethod
    def _sale(box, items, *, posted=False):
        invoice = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع',
                          date=datetime(2026, 10, 13), total=0.0, is_posted=posted, posted_by='t')
        db.session.add(invoice)
        db.session.flush()
        grams = {}
        for category, karat, weight in items:
            db.session.add(InvoiceItem(invoice_id=invoice.id, category_id=category.id if category else None,
                                       name='قطعة', quantity=1, price=0.0, karat=float(karat), weight=weight))
            grams[f'credit_{karat}k'] = grams.get(f'credit_{karat}k', 0.0) + weight
        line = _line(box, posted=posted, reference_id=invoice.id, **grams)
        return invoice, line

    def test_a_sale_allocates_its_line_by_category(self, app):
        from services.stock_ledger import allocate_invoice
        box, ring, chain = _safe(), _category(), _category()
        invoice, _ = self._sale(box, [(ring, 21, 5.3), (chain, 21, 16.2)], posted=True)
        allocate_invoice(invoice, by='t')
        assert _balances(box) == {(21, ring.id): -5.3, (21, chain.id): -16.2}

    def test_a_line_without_a_category_stays_unclassified(self, app):
        from services.stock_ledger import allocate_invoice
        box, ring = _safe(), _category()
        invoice, _ = self._sale(box, [(ring, 21, 5.0), (None, 21, 3.0)], posted=True)
        allocate_invoice(invoice, by='t')
        assert _balances(box) == {(21, ring.id): -5.0, (21, None): -3.0}

    def test_allocating_twice_writes_once(self, app):
        from models import StockLineAllocation
        from services.stock_ledger import allocate_invoice
        box, ring = _safe(), _category()
        invoice, line = self._sale(box, [(ring, 21, 5.0)], posted=True)
        allocate_invoice(invoice, by='t')
        allocate_invoice(invoice, by='t')
        assert StockLineAllocation.query.filter_by(journal_entry_line_id=line.id).count() == 1

    def test_items_heavier_than_the_line_are_refused(self, app):
        from services.stock_ledger import StockAllocationError, allocate_invoice
        box, ring = _safe(), _category()
        invoice, line = self._sale(box, [(ring, 21, 5.0)], posted=True)
        line.credit_21k = 4.0
        db.session.flush()
        with pytest.raises(StockAllocationError):
            allocate_invoice(invoice, by='t')

    def test_posting_an_invoice_allocates_it(self, app):
        from posting_routes import post_invoice_document
        box, ring = _safe(), _category()
        invoice, _ = self._sale(box, [(ring, 21, 7.5)])
        post_invoice_document(invoice, 't')
        db.session.flush()
        assert _balances(box) == {(21, ring.id): -7.5}

    def test_a_failed_allocation_refuses_the_posting(self, app, monkeypatch):
        """No «if it fails, skip» (ADR-045): 21 purchases since 5 July never
        reached the old ledger and nothing said so."""
        import services.stock_ledger as stock_ledger
        from posting_routes import post_invoice_document

        def fail(*a, **k):
            raise stock_ledger.StockAllocationError('boom')
        monkeypatch.setattr(stock_ledger, 'allocate_invoice', fail)
        box, ring = _safe(), _category()
        invoice, _ = self._sale(box, [(ring, 21, 7.5)])
        with pytest.raises(stock_ledger.StockAllocationError):
            post_invoice_document(invoice, 't')


class TestTheLawIsWatchedEveryNight:
    """allocate() refuses at writing; a line edited after it, or a safe that
    stops being stock, would break the law silently -- the nightly check says so."""

    @staticmethod
    def _subjects():
        from services.books_invariants import check_stock_allocations
        return {f.subject_key for f in check_stock_allocations()}

    def test_a_line_edited_below_its_allocations_is_reported(self, app):
        from services.stock_ledger import allocate
        box, ring = _safe(), _category()
        line = _line(box, credit_21k=30.0)
        allocate(line, 21, ring.id, -30.0, by='t')
        line.credit_21k = 20.0
        db.session.flush()
        assert f'journal_entry:{line.journal_entry_id}:21k' in self._subjects()

    def test_a_safe_that_stops_being_stock_is_reported(self, app):
        from services.stock_ledger import allocate
        box, ring = _safe(), _category()
        line = _line(box, debit_21k=30.0)
        allocate(line, 21, ring.id, 30.0, by='t')
        box.stock_location = None
        db.session.flush()
        assert f'journal_entry:{line.journal_entry_id}:21k' in self._subjects()

    def test_a_lawful_allocation_is_not(self, app):
        from services.stock_ledger import allocate
        box, ring = _safe(), _category()
        line = _line(box, debit_21k=30.0)
        allocate(line, 21, ring.id, 30.0, by='t')
        assert f'journal_entry:{line.journal_entry_id}:21k' not in self._subjects()

    def test_it_runs_every_night_and_has_a_meaning_on_the_screen(self, app):
        from services.books_invariants import CHECKS, KINDS, STOCK_ALLOCATION_INVALID, check_stock_allocations
        from services.finding_kinds import KIND_INFO
        assert CHECKS[STOCK_ALLOCATION_INVALID] is check_stock_allocations
        assert STOCK_ALLOCATION_INVALID in KINDS and KIND_INFO[STOCK_ALLOCATION_INVALID]['title_ar']


def test_the_gold_safe_for_a_karat_does_not_depend_on_row_order(app):
    """get_gold_safe_by_karat took .first() with no order: PostgreSQL then
    answers in physical order, which an UPDATE changes. On the 12 Oct copy it
    answered the showroom (30); after A0's migration updated the gold safes, it
    answered our account with the Arabic Pound company (41) -- caught by the
    release rehearsal. Posting falls back to it."""
    from datetime import datetime as _dt
    first, second = _safe(), _safe()
    for box in (first, second):
        box.karat = None
    db.session.flush()
    expected = (SafeBox.query.filter_by(safe_type='gold', karat=None, is_active=True)
                .order_by(SafeBox.id).first().id)
    lowest = db.session.get(SafeBox, expected)
    lowest.updated_at = _dt(2026, 10, 13)          # an UPDATE moves the row to the end
    db.session.flush()
    assert SafeBox.get_gold_safe_by_karat(21).id == expected
