"""Two regressions from the Phase 15/16C/A gold tables, one root cause.

The posting path creates gold rows (create_gold_obligations_for_invoice, called
from add_invoice's post-commit tail). The RETRACTION paths -- unpost, reject,
delete -- were never extended to match, so a document that no longer stands keeps
acting like one.

REGRESSION 1: a rejected invoice is still a live gold obligation.
    Measured: invoice_open_gold_obligation() returns 200.0 for an invoice with
    is_posted=False and status='rejected', is_gold_obligation_eligible() still
    says True, reconcile_supplier() counts it in gross_obligation, and gold can
    actually be ATTRIBUTED to it -- 50 g went through with no objection.

REGRESSION 2: deleting a cancelled invoice fails.
    NOT a foreign key, which is what it looks like. The real error:

        sqlstate   23502  NotNullViolation
        constraint None
        table      invoice_gold_obligation   column  invoice_id
        "null value in column invoice_id violates not-null constraint"

    Both relationships are declared with a backref and no cascade, so
    SQLAlchemy's default on parent delete is to DE-ASSOCIATE the children --
    UPDATE ... SET invoice_id = NULL -- and the column forbids it. DELETE FROM
    invoice is never reached, so ondelete='CASCADE' would not have fixed it.

BLAST RADIUS of the standing check, measured on production-copy data before
writing it: all 157 obligation rows belong to invoices with is_posted=true and
status in (paid, partially_paid, unpaid); zero belong to a rejected or unposted
one; zero attribution rows exist. So TestAStandingInvoiceIsUnaffected is the
test that matters most -- the guard must change nothing that works today.

Run:
    python -m pytest tests/test_invoice_lifecycle_gold_cleanup.py -v
"""

import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (
    Account,
    GoldAttributionBoundary,
    Invoice,
    InvoiceGoldObligation,
    InvoiceItem,
    InvoiceKaratLine,
    InvoicePayment,
    Supplier,
    Voucher,
    VoucherAccountLine,
    VoucherInvoiceGoldAttribution,
    db,
)
from party_account_service import ensure_supplier_accounts
from services.gold_allocation_service import (
    attribute_gold_to_invoice,
    invoice_open_gold_obligation,
    reconcile_supplier,
)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    if GoldAttributionBoundary.query.first() is None:
        db.session.add(GoldAttributionBoundary(max_historical_voucher_id=0))
        db.session.flush()
    yield


def _uid():
    return uuid.uuid4().hex[:8]


@pytest.fixture
def supplier():
    s = Supplier(supplier_code=f'S-LC-{_uid()}', name=f'مورد {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.flush()
    return s


def _invoice(supplier, *, posted=True, status='unpaid', gold=200.0):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
        supplier_id=supplier.id, date=datetime.now(),
        total=50000.0, wage_subtotal=1000.0,
        status=status, amount_paid=0.0, is_posted=posted,
        gold_settlement_tracked=True,
    )
    db.session.add(inv)
    db.session.flush()
    if gold:
        db.session.add(InvoiceGoldObligation(
            invoice_id=inv.id, karat=21.0, weight=gold))
        db.session.flush()
    return inv


def _gold_voucher(invoice, *, weight=50.0):
    acc = Account(account_number=f'9{_uid()[:4]}', name=f'ح {_uid()}', type='Liability')
    db.session.add(acc)
    db.session.flush()
    v = Voucher(
        voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
        party_type='supplier', supplier_id=invoice.supplier_id,
        reference_type='invoice', reference_id=invoice.id,
        status='approved', created_by='t', amount_cash=0.0,
        created_at=datetime.now(),
    )
    db.session.add(v)
    db.session.flush()
    db.session.add(VoucherAccountLine(
        voucher_id=v.id, account_id=acc.id, line_type='debit',
        amount_type='gold', amount=weight, karat=21.0))
    db.session.flush()
    return v


def _route_delete(invoice):
    """The child deletions routes/invoices.py::delete_unposted_invoice performs,
    then the parent delete. Reproduces the failing path exactly."""
    iid = invoice.id
    InvoiceItem.query.filter_by(invoice_id=iid).delete()
    InvoicePayment.query.filter_by(invoice_id=iid).delete()
    InvoiceKaratLine.query.filter_by(invoice_id=iid).delete()
    db.session.delete(invoice)
    db.session.flush()


# ======================================================================
# REGRESSION 2 — the delete
# ======================================================================

class TestDeletingARetractedInvoice:

    def test_an_invoice_with_a_gold_obligation_can_be_deleted(self, supplier):
        """The exact NotNullViolation above. Nothing may be left pointing at a
        row that no longer exists, and nothing may block its removal."""
        inv = _invoice(supplier, posted=False, status='rejected')
        iid = inv.id

        _route_delete(inv)

        assert db.session.get(Invoice, iid) is None
        assert InvoiceGoldObligation.query.filter_by(invoice_id=iid).count() == 0

    def test_an_invoice_with_a_recorded_attribution_can_be_deleted(self, supplier):
        inv = _invoice(supplier, posted=False, status='rejected')
        voucher = _gold_voucher(inv)
        db.session.add(VoucherInvoiceGoldAttribution(
            voucher_id=voucher.id, invoice_id=inv.id, karat=21.0,
            weight=50.0, weight_main_karat=50.0))
        db.session.flush()
        iid = inv.id

        _route_delete(inv)

        assert db.session.get(Invoice, iid) is None
        assert VoucherInvoiceGoldAttribution.query.filter_by(
            invoice_id=iid).count() == 0

    def test_both_together_the_real_shape(self, supplier):
        inv = _invoice(supplier, posted=False, status='rejected')
        voucher = _gold_voucher(inv)
        db.session.add(VoucherInvoiceGoldAttribution(
            voucher_id=voucher.id, invoice_id=inv.id, karat=21.0,
            weight=50.0, weight_main_karat=50.0))
        db.session.flush()
        iid = inv.id

        _route_delete(inv)

        assert db.session.get(Invoice, iid) is None

    def test_the_voucher_itself_survives_the_invoice(self, supplier):
        """Deleting an invoice removes the attribution, not the payment. The
        voucher is a financial document of its own and its GL lines stand."""
        inv = _invoice(supplier, posted=False, status='rejected')
        voucher = _gold_voucher(inv)
        db.session.add(VoucherInvoiceGoldAttribution(
            voucher_id=voucher.id, invoice_id=inv.id, karat=21.0,
            weight=50.0, weight_main_karat=50.0))
        db.session.flush()
        vid = voucher.id

        _route_delete(inv)

        assert db.session.get(Voucher, vid) is not None


# ======================================================================
# REGRESSION 1 — the readers
# ======================================================================

class TestARejectedInvoiceIsNotALiveObligation:

    def test_its_open_gold_obligation_is_zero(self, supplier):
        """Measured at 200.0 before the fix. The shared ceiling is what every
        bound check goes through, so a rejected invoice reading non-zero there
        is what let gold be attributed to it."""
        inv = _invoice(supplier, posted=False, status='rejected')

        assert invoice_open_gold_obligation(inv.id) == 0.0

    def test_gold_cannot_be_attributed_to_it(self, supplier):
        """The live defect: 50 g went through with no objection."""
        inv = _invoice(supplier, posted=False, status='rejected')
        voucher = _gold_voucher(inv)

        with pytest.raises(ValueError):
            attribute_gold_to_invoice(
                voucher=voucher, invoice_id=inv.id, karat=21.0,
                weight=50.0, created_by='t')

    def test_it_is_excluded_from_the_supplier_reconciliation(self, supplier):
        """gross_obligation counted the rejected invoice's 200 g."""
        inv = _invoice(supplier, posted=False, status='rejected')

        assert reconcile_supplier(supplier)['gross_obligation'] == 0.0

    def test_the_obligation_row_itself_is_preserved(self, supplier):
        """ADR-028 makes InvoiceGoldObligation a frozen record of what the
        invoice originally obliged, and reverse_gold_allocations_for_invoice
        deliberately keeps it. The guard changes what READS as a live position,
        never the record -- so re-posting restores the obligation rather than
        having to invent it again."""
        inv = _invoice(supplier, posted=False, status='rejected')

        assert InvoiceGoldObligation.query.filter_by(invoice_id=inv.id).count() == 1


# ======================================================================
# THE TEST THAT MATTERS MOST — 157 real rows depend on it
# ======================================================================

class TestAStandingInvoiceIsUnaffected:

    def test_a_posted_unpaid_invoice_keeps_its_full_obligation(self, supplier):
        inv = _invoice(supplier, posted=True, status='unpaid')
        assert invoice_open_gold_obligation(inv.id) == 200.0

    def test_a_posted_partially_paid_invoice_keeps_its_obligation(self, supplier):
        inv = _invoice(supplier, posted=True, status='partially_paid')
        assert invoice_open_gold_obligation(inv.id) == 200.0

    def test_a_posted_paid_invoice_keeps_its_obligation(self, supplier):
        """'paid' is a payment state, not a retraction."""
        inv = _invoice(supplier, posted=True, status='paid')
        assert invoice_open_gold_obligation(inv.id) == 200.0

    def test_attribution_to_a_standing_invoice_still_works(self, supplier):
        inv = _invoice(supplier, posted=True, status='unpaid')
        voucher = _gold_voucher(inv)

        row = attribute_gold_to_invoice(
            voucher=voucher, invoice_id=inv.id, karat=21.0,
            weight=50.0, created_by='t')
        db.session.flush()

        assert row.weight == 50.0
        assert invoice_open_gold_obligation(inv.id) == 150.0

    def test_the_supplier_reconciliation_still_counts_it(self, supplier):
        inv = _invoice(supplier, posted=True, status='unpaid')
        assert reconcile_supplier(supplier)['gross_obligation'] == 200.0


class TestEveryRetractedStatusIsRecognised:
    """'rejected' is the only status reject_invoice writes, but the reports layer
    (routes/invoices.py, the tab summary) already skips 'cancelled' and 'ملغاة'.
    A reader of gold that disagreed with a reader of totals about whether a
    document stands would be the harder bug to find, so all three are covered.
    Real data carries only paid/unpaid/partially_paid/rejected."""

    @pytest.mark.parametrize('status', ['rejected', 'cancelled', 'ملغاة', 'REJECTED'])
    def test_a_retracted_status_zeroes_the_ceiling(self, supplier, status):
        inv = _invoice(supplier, posted=False, status=status)
        assert invoice_open_gold_obligation(inv.id) == 0.0

    @pytest.mark.parametrize('status', ['unpaid', 'partially_paid', 'paid'])
    def test_a_payment_status_does_not(self, supplier, status):
        inv = _invoice(supplier, posted=True, status=status)
        assert invoice_open_gold_obligation(inv.id) == 200.0

    def test_an_unposted_invoice_has_no_position_even_unrejected(self, supplier):
        """Standing means posted AND not retracted. An unposted invoice has no GL
        entry, and ADR-028 makes the GL the source of truth for the position."""
        inv = _invoice(supplier, posted=False, status='unpaid')
        assert invoice_open_gold_obligation(inv.id) == 0.0


# ======================================================================
# LAYER 1+2 — the guard must be unbypassable, not merely present
#
# The first fix put the standing test at the readers I knew about. There are 11
# direct InvoiceGoldObligation.query sites; 3 were guarded; the FOURTH — the
# picker endpoint an employee chooses an invoice from — still offered a rejected
# invoice at 200 g while the guarded ceiling said 0. A filter that must be
# remembered at every reader will be forgotten at the next one.
# ======================================================================

class TestThePickerOffersOnlyStandingInvoices:

    def test_a_retracted_invoice_is_not_offered(self, supplier):
        """GET /suppliers/<id>/open-gold-obligations — the screen the choice is
        made from. Measured at 200.0 before this."""
        from services.gold_allocation_service import live_obligations_for_supplier

        _invoice(supplier, posted=False, status='rejected')

        assert live_obligations_for_supplier(supplier.id) == []

    def test_a_standing_invoice_is_offered(self, supplier):
        from services.gold_allocation_service import live_obligations_for_supplier

        inv = _invoice(supplier, posted=True, status='unpaid')

        rows = live_obligations_for_supplier(supplier.id)
        assert [r.invoice_id for r in rows] == [inv.id]

    def test_the_endpoint_itself_no_longer_queries_the_model_directly(self):
        """The route must go through a named reader, or the ratchet below cannot
        protect it."""
        from pathlib import Path
        src = (Path(__file__).resolve().parent.parent
               / 'routes' / 'gold_advances.py').read_text(encoding='utf-8')
        assert 'InvoiceGoldObligation.query' not in src


class TestObligationReadsAreFunnelled:
    """THE RATCHET. A rule without an enforcing machine is a comment, and this is
    the machine: position reads of InvoiceGoldObligation may only happen where
    the standing test is applied. A new reader in a route or another service
    fails here instead of silently resurrecting a retracted invoice."""

    ALLOWED = {
        # Defines the funnel, the derived quantities, and the retraction helpers
        # that must see every row precisely because they run during retraction.
        'services/gold_allocation_service.py',
        # Reads the invoice's OWN record for its own status. Must NOT be filtered:
        # an unposted-but-not-rejected invoice would report gold_required 0 and
        # could flip to 'paid'. The retracted case is already handled by
        # recompute()'s 'rejected' guard.
        'services/invoice_payment_state_service.py',
        # Deletes the rows with the invoice.
        'routes/invoices.py',
    }

    def test_nothing_outside_the_funnel_queries_obligations(self):
        import re
        from pathlib import Path

        backend = Path(__file__).resolve().parent.parent
        pattern = re.compile(r'InvoiceGoldObligation\s*\.\s*query')
        offenders = []
        for path in backend.rglob('*.py'):
            rel = path.relative_to(backend).as_posix()
            if rel in self.ALLOWED or rel.startswith(
                ('venv/', 'devtools/', 'tools/', 'tests/', 'alembic/')
            ) or rel.startswith('test_'):
                continue
            for line_no, line in enumerate(
                path.read_text(encoding='utf-8', errors='ignore').splitlines(), 1
            ):
                if pattern.search(line.split('#', 1)[0]):
                    offenders.append(f'{rel}:{line_no}: {line.strip()}')
        assert not offenders, (
            'read obligations through a named reader in gold_allocation_service '
            '(live_obligations_for_supplier / invoice_open_gold_obligation for a '
            'POSITION, recorded_obligations_for_invoice for the RECORD):\n  '
            + '\n  '.join(offenders)
        )


class TestAllocatingToARetractedInvoiceIsRefused:

    def test_an_advance_cannot_be_allocated_to_a_retracted_obligation(self, supplier):
        """allocate() already resolves the obligation's invoice to check the
        supplier, and never checked whether it still stands."""
        from models import SupplierGoldAdvance
        from services.gold_allocation_service import GoldAllocationService

        inv = _invoice(supplier, posted=False, status='rejected')
        obligation = InvoiceGoldObligation.query.filter_by(invoice_id=inv.id).one()
        advance = SupplierGoldAdvance(
            supplier_id=supplier.id, source_voucher_id=_gold_voucher(inv).id,
            karat=21.0, weight=100.0)
        db.session.add(advance)
        db.session.flush()

        with pytest.raises(ValueError, match='invoice_not_standing'):
            GoldAllocationService().allocate(
                advance_id=advance.id, obligation_id=obligation.id,
                weight_main_karat=50.0)


# ======================================================================
# LAYER 3 — retraction undoes what posting did
# ======================================================================

class TestRetractionReleasesGoldEvidence:

    def test_it_removes_the_attributions(self, supplier):
        """Mirrors the rule the codebase already states for the other parent:
        remove_attributions_for_voucher() exists because 'an attribution must
        never outlive the payment that proves it'. Nor the invoice it settles —
        the gold was still paid, so it returns to being UNATTRIBUTED settlement,
        which is the quantity reconcile_supplier() exists to name honestly."""
        from services.gold_allocation_service import release_invoice_gold_evidence

        inv = _invoice(supplier, posted=True, status='unpaid')
        voucher = _gold_voucher(inv)
        db.session.add(VoucherInvoiceGoldAttribution(
            voucher_id=voucher.id, invoice_id=inv.id, karat=21.0,
            weight=50.0, weight_main_karat=50.0))
        db.session.flush()

        release_invoice_gold_evidence(inv.id)
        db.session.flush()

        assert VoucherInvoiceGoldAttribution.query.filter_by(
            invoice_id=inv.id).count() == 0

    def test_it_preserves_the_obligation_record(self, supplier):
        """ADR-028's frozen record. Releasing evidence is not erasing history."""
        from services.gold_allocation_service import release_invoice_gold_evidence

        inv = _invoice(supplier, posted=True, status='unpaid')

        release_invoice_gold_evidence(inv.id)
        db.session.flush()

        assert InvoiceGoldObligation.query.filter_by(invoice_id=inv.id).count() == 1

    def test_it_leaves_the_voucher_standing(self, supplier):
        """The payment happened. Only the link to this invoice is withdrawn."""
        from services.gold_allocation_service import release_invoice_gold_evidence

        inv = _invoice(supplier, posted=True, status='unpaid')
        voucher = _gold_voucher(inv)
        db.session.add(VoucherInvoiceGoldAttribution(
            voucher_id=voucher.id, invoice_id=inv.id, karat=21.0,
            weight=50.0, weight_main_karat=50.0))
        db.session.flush()
        vid = voucher.id

        release_invoice_gold_evidence(inv.id)
        db.session.flush()

        assert db.session.get(Voucher, vid) is not None

    def test_both_retraction_routes_call_it(self):
        """reject_invoice and the unposting are the paths that retract a posted
        document. Neither mentioned the gold tables at all -- the root cause of
        both regressions. Since UNPOST-001 U1 the three unpost routes (the
        posting screen, its batch, the invoices route) share one operation,
        posting_routes.unpost_invoice_document: it releases the evidence, and
        each route must call it."""
        import inspect
        import posting_routes
        from routes import invoices

        def body(fn):
            return inspect.getsource(fn)

        assert 'release_invoice_gold_evidence' in body(invoices.reject_invoice), \
            'reject_invoice does not release the invoice gold evidence'
        assert 'release_invoice_gold_evidence' in body(posting_routes.unpost_invoice_document), \
            'unpost_invoice_document does not release the invoice gold evidence'
        for route in (invoices.unpost_invoice, posting_routes.unpost_invoice, posting_routes.unpost_invoices_batch):
            assert 'unpost_invoice_document(' in body(route), \
                f'{route.__module__}.{route.__name__} does not use the one unposting'


class TestTheInvoiceOwnStatusIsUnaffected:
    """The allowlisted reader, protected by a test rather than a comment."""

    def test_an_unposted_tracked_invoice_keeps_its_gold_requirement(self, supplier):
        """If _gold_dimension were funnelled, this would report 0 required, the
        gold side would read as satisfied, and an unposted invoice could flip to
        'paid'. That is why it reads the record, not the position."""
        from services.invoice_payment_state_service import InvoicePaymentStateService

        inv = _invoice(supplier, posted=False, status='unpaid')

        required, attributed = InvoicePaymentStateService._gold_dimension(inv)
        assert required == 200.0
