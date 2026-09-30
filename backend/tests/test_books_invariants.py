"""The books must be checked against each other — continuously, and without ever being touched.

Every incident in September 2026 was found by a person reconciling by hand,
weeks or months late. None was found by the system:

  - voucher_invoice_gold_attribution held ZERO rows for its whole life, while
    34 approved gold vouchers should have written one. Nothing noticed.
  - 92,385.00 of posted receipts read as zero in the safe-box statements from
    May to September. Nothing noticed.
  - rejecting invoice 3132 distorted supplier 15 by -20.742 g-eq and -1,322.50
    while its entries sat unposted-but-counted; deleting it left reversal 7413
    posted with its original gone and DOUBLED the distortion. Nothing noticed.

services/books_invariants.py asserts, every night, that the books agree, and
writes what it finds to ReconciliationFinding -- the table designed as "one
source of truth for all operational gaps". It REPORTS. It never repairs,
because a job that silently "heals" divergence destroys the only evidence that
a writer somewhere is wrong.

THE WITNESS that these checks see real damage, not invented fixtures, lives on
the reference bench (seven restored production snapshots): the difference
between the snapshot before and after 3132 was deleted is exactly
{+ORPHAN_POSTED_ENTRY 7413, -UNPOSTED_ENTRY_IN_LIMBO 7410, 7411, 7414}. The
existing SAFEBOX_SUBLEDGER comparison did not move at all across that incident
-- the delete removed both sides -- which is why entry-level checks exist.

Run:
    python -m pytest tests/test_books_invariants.py -v
"""

import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (
    Account,
    GoldAttributionBoundary,
    Invoice,
    JournalEntry,
    JournalEntryLine,
    ReconciliationFinding,
    SafeBox,
    SafeBoxTransaction,
    Supplier,
    Voucher,
    VoucherAccountLine,
    VoucherInvoiceGoldAttribution,
    db,
)


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


def _account(**kw):
    a = Account(account_number=f'9{_uid()[:5]}', name=f'ح {_uid()}', type='Asset', **kw)
    db.session.add(a)
    db.session.flush()
    return a


def _safe_box(account=None):
    account = account or _account()
    now = datetime.now()
    sb = SafeBox(name=f'خزينة {_uid()}', safe_type='cash', account_id=account.id,
                 is_active=True, is_default=False, created_at=now, updated_at=now)
    db.session.add(sb)
    db.session.flush()
    return sb


def _entry(*, posted=True, draft=False, reference_type=None, reference_id=None,
           lines=(), deleted=False):
    je = JournalEntry(
        entry_number=f'JE-T-{_uid()}', date=datetime.now(), description='اختبار',
        entry_type='عادي', is_posted=posted, is_draft=draft, is_deleted=deleted,
        reference_type=reference_type, reference_id=reference_id, created_by='t',
    )
    db.session.add(je)
    db.session.flush()
    for account_id, cash_debit, cash_credit, extra in lines:
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id, account_id=account_id,
            cash_debit=cash_debit, cash_credit=cash_credit, description='اختبار',
            **(extra or {}),
        ))
    db.session.flush()
    return je


def _voucher(*, status='approved', reference_type=None, reference_id=None,
             supplier_id=None, gold_debit=None, karat=21.0, account=None):
    v = Voucher(
        voucher_number=f'V-{_uid()}', voucher_type='payment', date=datetime.now(),
        status=status, reference_type=reference_type, reference_id=reference_id,
        supplier_id=supplier_id, party_type='supplier' if supplier_id else None,
        created_by='t', amount_cash=0.0, created_at=datetime.now(),
    )
    db.session.add(v)
    db.session.flush()
    if gold_debit:
        account = account or _account()
        db.session.add(VoucherAccountLine(
            voucher_id=v.id, account_id=account.id, line_type='debit',
            amount_type='gold', amount=gold_debit, karat=karat))
        db.session.flush()
    return v


def _supplier():
    s = Supplier(supplier_code=f'S-{_uid()}', name=f'مورد {_uid()}')
    db.session.add(s)
    db.session.flush()
    return s


def _invoice(supplier_id=None, *, posted=True, status='unpaid'):
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
                  supplier_id=supplier_id, date=datetime.now(), total=1000.0,
                  status=status, amount_paid=0.0, is_posted=posted)
    db.session.add(inv)
    db.session.flush()
    return inv


def _boundary(max_id):
    row = GoldAttributionBoundary.query.first()
    if row is None:
        row = GoldAttributionBoundary(max_historical_voucher_id=max_id)
        db.session.add(row)
    else:
        row.max_historical_voucher_id = max_id
    db.session.flush()


def _subjects(facts):
    return {f.subject_key for f in facts}


# ======================================================================
# The four checks — each named for the incident it would have caught
# ======================================================================

class TestOrphanPostedEntry:
    """Reversal 7413 stayed posted after its original voucher was deleted with
    invoice 3132, and doubled the supplier's gold distortion."""

    def test_a_posted_reversal_whose_voucher_is_gone_is_reported(self, app):
        from services.books_invariants import check_orphan_posted_entries
        acc = _account()
        je = _entry(reference_type='voucher_reversal', reference_id=987654321,
                    lines=[(acc.id, 0.0, 24.2, None)])
        assert f'journal_entry:{je.id}' in _subjects(check_orphan_posted_entries())

    def test_a_posted_entry_whose_invoice_is_gone_is_reported(self, app):
        from services.books_invariants import check_orphan_posted_entries
        je = _entry(reference_type='invoice_payments', reference_id=987654322,
                    lines=[(_account().id, 100.0, 0.0, None)])
        assert f'journal_entry:{je.id}' in _subjects(check_orphan_posted_entries())

    def test_an_entry_whose_document_exists_is_not(self, app):
        from services.books_invariants import check_orphan_posted_entries
        v = _voucher()
        je = _entry(reference_type='voucher', reference_id=v.id,
                    lines=[(_account().id, 10.0, 0.0, None)])
        assert f'journal_entry:{je.id}' not in _subjects(check_orphan_posted_entries())

    def test_an_unposted_or_deleted_orphan_is_not(self, app):
        """Neither counts anywhere, so neither distorts a balance."""
        from services.books_invariants import check_orphan_posted_entries
        a = _entry(posted=False, draft=True, reference_type='voucher', reference_id=987654323)
        b = _entry(deleted=True, reference_type='voucher', reference_id=987654324)
        found = _subjects(check_orphan_posted_entries())
        assert f'journal_entry:{a.id}' not in found
        assert f'journal_entry:{b.id}' not in found


class TestUnpostedEntryInLimbo:
    """posted=False yet not a draft: party_live_balances counts it
    (or_(is_posted, not is_draft)) while the account reader does not. Invoice
    3132's three entries sat here and distorted supplier 15 by -20.742 g-eq
    from the moment it was rejected -- before anything was deleted."""

    def test_an_entry_of_a_rejected_invoice_is_reported(self, app):
        """The 3132 shape: rejected, and its entries still counted by the party reader."""
        from services.books_invariants import check_unposted_entries_in_limbo
        inv = _invoice(posted=False, status='rejected')
        je = _entry(posted=False, draft=False, reference_type='invoice', reference_id=inv.id,
                    lines=[(_account().id, 1322.5, 0.0, None)])
        assert f'journal_entry:{je.id}' in _subjects(check_unposted_entries_in_limbo())

    def test_an_entry_whose_document_is_gone_is_reported(self, app):
        """The 3123 shape: invoice_payments of an invoice that no longer exists."""
        from services.books_invariants import check_unposted_entries_in_limbo
        je = _entry(posted=False, draft=False, reference_type='invoice_payments', reference_id=987654321,
                    lines=[(_account().id, 2150.0, 0.0, None)])
        assert f'journal_entry:{je.id}' in _subjects(check_unposted_entries_in_limbo())

    def test_an_unposted_entry_of_a_posted_invoice_is_reported(self, app):
        from services.books_invariants import check_unposted_entries_in_limbo
        inv = _invoice(posted=True)
        je = _entry(posted=False, draft=False, reference_type='invoice', reference_id=inv.id)
        assert f'journal_entry:{je.id}' in _subjects(check_unposted_entries_in_limbo())

    def test_an_invoice_awaiting_approval_is_not(self, app):
        """The 3158 shape, found on the 29 Sep production copy: a paid sale waiting
        to be approved. Its entries are unposted because the invoice is -- that is
        the pending state working as designed, not a disagreement."""
        from services.books_invariants import check_unposted_entries_in_limbo
        inv = _invoice(posted=False, status='paid')
        je = _entry(posted=False, draft=False, reference_type='invoice', reference_id=inv.id,
                    lines=[(_account().id, 4150.0, 0.0, None)])
        assert f'journal_entry:{je.id}' not in _subjects(check_unposted_entries_in_limbo())

    def test_a_voucher_left_pending_on_a_rejected_invoice_is_reported(self, app):
        """The other half of 3132: rejecting it reset its payment vouchers to
        'pending' (PV-2026-01221, -01223), and their entries 7411 and 7414 kept
        counting in the supplier's balance. A pending status alone does not mean
        awaiting approval when the invoice the voucher pays has been retracted."""
        from services.books_invariants import check_unposted_entries_in_limbo
        inv = _invoice(posted=False, status='rejected')
        v = _voucher(status='pending', reference_type='invoice', reference_id=inv.id)
        je = _entry(posted=False, draft=False, reference_type='voucher', reference_id=v.id)
        assert f'journal_entry:{je.id}' in _subjects(check_unposted_entries_in_limbo())

    def test_a_voucher_awaiting_approval_is_not(self, app):
        from services.books_invariants import check_unposted_entries_in_limbo
        v = _voucher(status='pending')
        je = _entry(posted=False, draft=False, reference_type='voucher', reference_id=v.id)
        assert f'journal_entry:{je.id}' not in _subjects(check_unposted_entries_in_limbo())

    def test_a_draft_is_not(self, app):
        from services.books_invariants import check_unposted_entries_in_limbo
        je = _entry(posted=False, draft=True)
        assert f'journal_entry:{je.id}' not in _subjects(check_unposted_entries_in_limbo())

    def test_a_posted_entry_is_not(self, app):
        from services.books_invariants import check_unposted_entries_in_limbo
        je = _entry(posted=True, draft=False)
        assert f'journal_entry:{je.id}' not in _subjects(check_unposted_entries_in_limbo())


class TestPostedEntryOfUnpostedInvoice:
    """The mirror of limbo: posted=True while the invoice is not posted. It
    counts in every balance for a document that never happened. On 28 Sep 2026
    a settings save posted rejected invoice 2821's entry -- 5,700 g out of
    display inventory, 102,600 of wages (SETTINGS-001) -- and nothing saw it."""

    def test_a_posted_entry_of_a_rejected_invoice_is_reported(self, app):
        from services.books_invariants import check_posted_entries_of_unposted_invoices
        inv = _invoice(posted=False, status='rejected')
        je = _entry(posted=True, reference_type='invoice', reference_id=inv.id,
                    lines=[(_account().id, 102600.0, 0.0, None)])
        facts = {f.subject_key: f for f in check_posted_entries_of_unposted_invoices()}
        assert f'journal_entry:{je.id}' in facts
        assert facts[f'journal_entry:{je.id}'].detail['invoice_status'] == 'rejected'

    def test_a_posted_entry_of_an_invoice_awaiting_approval_is_reported(self, app):
        """What the next settings save would have done to invoice 3158."""
        from services.books_invariants import check_posted_entries_of_unposted_invoices
        inv = _invoice(posted=False, status='paid')
        je = _entry(posted=True, reference_type='invoice_payments', reference_id=inv.id,
                    lines=[(_account().id, 4150.0, 0.0, None)])
        assert f'journal_entry:{je.id}' in _subjects(check_posted_entries_of_unposted_invoices())

    def test_a_posted_invoice_or_an_unposted_or_deleted_entry_is_not(self, app):
        from services.books_invariants import check_posted_entries_of_unposted_invoices
        posted_inv = _invoice(posted=True)
        waiting = _invoice(posted=False, status='paid')
        ok = [
            _entry(posted=True, reference_type='invoice', reference_id=posted_inv.id),
            _entry(posted=False, reference_type='invoice', reference_id=waiting.id),
            _entry(posted=True, deleted=True, reference_type='invoice', reference_id=waiting.id),
        ]
        found = _subjects(check_posted_entries_of_unposted_invoices())
        assert not any(f'journal_entry:{je.id}' in found for je in ok)


class TestGoldAttributionMissing:
    """The attribution table held zero rows for its whole life: auto-approve
    skipped the hook. PV-2026-01230 (voucher 4309) is the live instance."""

    def test_an_approved_gold_invoice_payment_without_attribution_is_reported(self, app):
        from services.books_invariants import check_gold_attribution_missing
        _boundary(0)
        s = _supplier()
        inv = _invoice(s.id)
        v = _voucher(reference_type='invoice', reference_id=inv.id, supplier_id=s.id,
                     gold_debit=24.2, karat=18.0)
        assert f'voucher:{v.id}' in _subjects(check_gold_attribution_missing())

    def test_an_attributed_voucher_is_not(self, app):
        from services.books_invariants import check_gold_attribution_missing
        _boundary(0)
        s = _supplier()
        inv = _invoice(s.id)
        v = _voucher(reference_type='invoice', reference_id=inv.id, supplier_id=s.id,
                     gold_debit=24.2)
        db.session.add(VoucherInvoiceGoldAttribution(
            voucher_id=v.id, invoice_id=inv.id, karat=21.0, weight=24.2,
            weight_main_karat=24.2))
        db.session.flush()
        assert f'voucher:{v.id}' not in _subjects(check_gold_attribution_missing())

    def test_a_historical_voucher_is_not(self, app):
        """At or below the boundary, attribution may legitimately be derived."""
        from services.books_invariants import check_gold_attribution_missing
        s = _supplier()
        inv = _invoice(s.id)
        v = _voucher(reference_type='invoice', reference_id=inv.id, supplier_id=s.id,
                     gold_debit=24.2)
        _boundary(v.id)
        assert f'voucher:{v.id}' not in _subjects(check_gold_attribution_missing())

    def test_a_pending_voucher_is_not(self, app):
        from services.books_invariants import check_gold_attribution_missing
        _boundary(0)
        s = _supplier()
        inv = _invoice(s.id)
        v = _voucher(status='pending', reference_type='invoice', reference_id=inv.id,
                     supplier_id=s.id, gold_debit=24.2)
        assert f'voucher:{v.id}' not in _subjects(check_gold_attribution_missing())


class TestSafeboxSubledgerDrift:
    """The one-sided class: unpost wrote reversal movements, re-post restored
    the ledger only -- 92,385.00 read as zero in the statements. Reuses the
    computation behind /safe-boxes/reconciliation, extracted to a service."""

    def test_a_box_whose_statement_differs_from_its_ledger_is_reported(self, app):
        from services.books_invariants import check_safebox_subledger_drift
        box = _safe_box()
        _entry(reference_type='voucher', reference_id=1,
               lines=[(box.account_id, 5000.0, 0.0, None)])
        db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='voucher', ref_id=1,
                                          direction='in', amount_cash=3000.0,
                                          created_at=datetime.now(), created_by='t'))
        db.session.flush()
        facts = {f.subject_key: f for f in check_safebox_subledger_drift()}
        assert f'safe_box:{box.id}' in facts
        assert facts[f'safe_box:{box.id}'].metric == -2000.0

    def test_a_box_that_agrees_is_not(self, app):
        from services.books_invariants import check_safebox_subledger_drift
        box = _safe_box()
        _entry(reference_type='voucher', reference_id=1,
               lines=[(box.account_id, 5000.0, 0.0, None)])
        db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='voucher', ref_id=1,
                                          direction='in', amount_cash=5000.0,
                                          created_at=datetime.now(), created_by='t'))
        db.session.flush()
        assert f'safe_box:{box.id}' not in _subjects(check_safebox_subledger_drift())

    def test_the_reconciliation_endpoint_reads_the_same_computation(self, app):
        """One implementation, not two: the diagnostic route and the nightly
        check must report the same difference for the same box."""
        from services.books_invariants import check_safebox_subledger_drift
        from services.safebox_subledger import subledger_totals_by_box
        box = _safe_box()
        _entry(reference_type='voucher', reference_id=1,
               lines=[(box.account_id, 700.0, 0.0, None)])
        db.session.flush()
        totals = subledger_totals_by_box([box.id])[box.id]
        fact = {f.subject_key: f for f in check_safebox_subledger_drift()}[f'safe_box:{box.id}']
        assert round(totals['sb_total'] - totals['gl_total'], 2) == fact.metric

    def test_the_screen_with_its_defaults_and_the_nightly_check_agree(self, app, monkeypatch):
        """The route kept its own copies of the threshold and of the ignored
        statement rows, so the screen and the nightly check could drift apart on
        what drift IS while sharing the computation. Both now read
        services/safebox_subledger.py. This asks the screen itself, with no
        parameters, about a box whose only statement row is one the defaults
        ignore -- a different ignore list on either side changes the answer."""
        import inspect

        from auth_decorators import generate_token
        from models import User
        from services import safebox_subledger as sub
        from services.books_invariants import check_safebox_subledger_drift

        monkeypatch.setattr(db.session, 'commit', db.session.flush)  # auth may commit
        viewer = User(username=f'sb_{_uid()}', full_name='drift witness',
                      is_active=True, is_admin=True)
        viewer.set_password('x')
        db.session.add(viewer)
        box = _safe_box()
        _entry(reference_type='voucher', reference_id=1,
               lines=[(box.account_id, 700.0, 0.0, None)])
        db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='journal_entry', ref_id=1,
                                          direction='in', amount_cash=700.0,
                                          created_at=datetime.now(), created_by='t'))
        db.session.flush()

        with flask_app.test_client() as c:
            resp = c.get(f'/api/safe-boxes/reconciliation?safe_box_id={box.id}',
                         headers={'Authorization': f'Bearer {generate_token(viewer)}'})
        if resp.status_code != 200:
            pytest.fail(f'precondition: the screen must answer, got {resp.status_code}')
        body = resp.get_json()

        assert body['threshold'] == sub.DRIFT_THRESHOLD
        assert tuple(body['ignore_ref_types']) == sub.DEFAULT_IGNORED_REF_TYPES
        assert (inspect.signature(check_safebox_subledger_drift).parameters['threshold'].default
                == sub.DRIFT_THRESHOLD)
        screen = {r['safe_box_id']: r['diff'] for r in body['summary']}
        fact = {f.subject_key: f for f in check_safebox_subledger_drift()}[f'safe_box:{box.id}']
        assert screen[box.id] == fact.metric == -700.0


# ======================================================================
# Lifecycle — the alarm is a NEW finding or a CHANGED magnitude
# ======================================================================

def _open(kind):
    return ReconciliationFinding.query.filter_by(kind=kind, resolved_at=None).all()


class TestLifecycle:

    def test_the_database_itself_allows_one_open_finding_per_subject(self, app):
        """reconcile_findings keeps one open row per (kind, subject); the partial
        unique index uq_rf_open_subject makes that the database's rule too, so
        two overlapping runs cannot both open one. A resolved row for the same
        subject, and open rows with no subject (STALE_SETTLEMENT), stay free.

        This suite runs on SQLite, where the model's sqlite_where builds the
        index. On PostgreSQL the migration 20260928_rf_subject builds it; that
        was verified on the reference bench, not here."""
        from sqlalchemy.exc import IntegrityError
        key = f'journal_entry:uq-{_uid()}'
        db.session.add(ReconciliationFinding(kind='ORPHAN_POSTED_ENTRY', source='books_invariants',
                                             subject_key=key, metric=1.0))
        db.session.add(ReconciliationFinding(kind='ORPHAN_POSTED_ENTRY', source='books_invariants',
                                             subject_key=key, metric=2.0,
                                             resolved_at=datetime.utcnow()))
        db.session.add(ReconciliationFinding(kind='STALE_SETTLEMENT', source='t'))
        db.session.add(ReconciliationFinding(kind='STALE_SETTLEMENT', source='t'))
        db.session.flush()

        savepoint = db.session.begin_nested()
        db.session.add(ReconciliationFinding(kind='ORPHAN_POSTED_ENTRY', source='books_invariants',
                                             subject_key=key, metric=3.0))
        with pytest.raises(IntegrityError):
            db.session.flush()
        savepoint.rollback()

    def test_first_run_opens_one_finding_per_subject(self, app):
        from services.books_invariants import run_books_invariants
        je = _entry(posted=False, draft=False)
        result = run_books_invariants()
        key = f'journal_entry:{je.id}'
        assert key in result['UNPOSTED_ENTRY_IN_LIMBO']['opened']
        rows = [r for r in _open('UNPOSTED_ENTRY_IN_LIMBO') if r.subject_key == key]
        assert len(rows) == 1 and rows[0].check_count == 1

    def test_a_persisting_condition_is_counted_not_duplicated(self, app):
        from services.books_invariants import run_books_invariants
        je = _entry(posted=False, draft=False)
        run_books_invariants()
        result = run_books_invariants()
        key = f'journal_entry:{je.id}'
        assert key in result['UNPOSTED_ENTRY_IN_LIMBO']['persisting']
        rows = [r for r in _open('UNPOSTED_ENTRY_IN_LIMBO') if r.subject_key == key]
        assert len(rows) == 1 and rows[0].check_count == 2

    def test_a_cleared_condition_resolves_itself(self, app):
        from services.books_invariants import run_books_invariants
        je = _entry(posted=False, draft=False)
        run_books_invariants()
        je.is_posted = True
        db.session.flush()
        result = run_books_invariants()
        key = f'journal_entry:{je.id}'
        assert key in result['UNPOSTED_ENTRY_IN_LIMBO']['resolved']
        assert not [r for r in _open('UNPOSTED_ENTRY_IN_LIMBO') if r.subject_key == key]

    def test_a_changed_magnitude_is_a_new_fact(self, app):
        """A box drifting from -2,000 to -9,000 is not 'the same finding, seen
        again' -- it is a writer still damaging the statement tonight. The old
        magnitude is closed with its history; the new one opens."""
        from services.books_invariants import run_books_invariants
        box = _safe_box()
        _entry(reference_type='voucher', reference_id=1,
               lines=[(box.account_id, 5000.0, 0.0, None)])
        db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='voucher', ref_id=1,
                                          direction='in', amount_cash=3000.0,
                                          created_at=datetime.now(), created_by='t'))
        db.session.flush()
        run_books_invariants()
        _entry(reference_type='voucher', reference_id=2,
               lines=[(box.account_id, 7000.0, 0.0, None)])
        result = run_books_invariants()
        key = f'safe_box:{box.id}'
        assert key in result['SAFEBOX_SUBLEDGER_DRIFT']['changed']
        open_rows = [r for r in _open('SAFEBOX_SUBLEDGER_DRIFT') if r.subject_key == key]
        assert len(open_rows) == 1 and open_rows[0].metric == -9000.0
        closed = ReconciliationFinding.query.filter(
            ReconciliationFinding.kind == 'SAFEBOX_SUBLEDGER_DRIFT',
            ReconciliationFinding.subject_key == key,
            ReconciliationFinding.resolved_at.isnot(None)).all()
        assert [r.metric for r in closed] == [-2000.0]

    def test_it_never_resolves_another_jobs_findings(self, app):
        """STALE_SETTLEMENT belongs to the clearing scheduler."""
        from services.books_invariants import run_books_invariants
        other = ReconciliationFinding(kind='STALE_SETTLEMENT', source='clearing_settlement_scheduler',
                                      detail='x')
        db.session.add(other)
        db.session.flush()
        run_books_invariants()
        assert db.session.get(ReconciliationFinding, other.id).resolved_at is None


# ======================================================================
# THE LOAD-BEARING TEST — it reports, it never repairs
# ======================================================================

class TestReportOnly:

    FINANCIAL = (JournalEntry, JournalEntryLine, Voucher, VoucherAccountLine,
                 SafeBoxTransaction, Invoice, VoucherInvoiceGoldAttribution)

    def test_running_the_invariants_changes_nothing_but_findings(self, app):
        """A check that 'heals' what it finds destroys the evidence that a writer
        is wrong. The only table this may touch is reconciliation_findings."""
        from services.books_invariants import run_books_invariants
        _boundary(0)
        s = _supplier()
        inv = _invoice(s.id)
        _voucher(reference_type='invoice', reference_id=inv.id, supplier_id=s.id, gold_debit=5.0)
        _entry(posted=False, draft=False)
        _entry(reference_type='voucher_reversal', reference_id=987654399,
               lines=[(_account().id, 0.0, 10.0, None)])
        box = _safe_box()
        _entry(reference_type='voucher', reference_id=1, lines=[(box.account_id, 50.0, 0.0, None)])

        def snapshot():
            out = {m.__tablename__: m.query.count() for m in self.FINANCIAL}
            out['_posted'] = JournalEntry.query.filter_by(is_posted=True).count()
            return out

        before = snapshot()
        run_books_invariants()
        assert snapshot() == before


# ======================================================================
# The self-healing job stops healing silently
# ======================================================================

class TestSafeboxJobReportsInsteadOfPosting:

    @pytest.fixture(autouse=True)
    def _keep_the_jobs_commit_inside_the_savepoint(self, monkeypatch):
        """_run_repair() ends with db.session.commit(), and the fence above does
        not hold against a commit: Flask-SQLAlchemy's get_bind() returns the
        engine, never db.session.bind, so the session is not on the fence
        connection -- what discards a test's rows is db.session.remove(), and
        only while they are uncommitted. Left alone, the job made this test's
        box, invoice, entry and backfilled statement row permanent in the run's
        database, and a clearing test later in the run failed on them. Its commit
        is a flush here: what it writes is unchanged; it is discarded at teardown
        with the rest of the test."""
        monkeypatch.setattr(db.session, 'commit', db.session.flush)

    def test_phase_a_no_longer_posts_an_unposted_voucher_entry(self, app):
        """Phase A posted any unposted voucher entry on a posted invoice with no
        look at the voucher's status -- a pending or cancelled payment would
        have reached the ledger at 02:30 with nobody's approval."""
        from safebox_reconciliation_scheduler import SafeboxReconciliationScheduler
        inv = _invoice(posted=True)
        v = _voucher(status='pending', reference_type='invoice', reference_id=inv.id)
        je = _entry(posted=False, draft=False, reference_type='voucher', reference_id=v.id,
                    lines=[(_account().id, 500.0, 0.0, None)])

        SafeboxReconciliationScheduler(flask_app)._run_repair()

        assert db.session.get(JournalEntry, je.id).is_posted is False
        assert [r for r in _open('VOUCHER_ENTRY_UNPOSTED_ON_POSTED_INVOICE')
                if r.subject_key == f'journal_entry:{je.id}']

    def test_phase_b_makes_every_row_it_writes_visible(self, app):
        from safebox_reconciliation_scheduler import SafeboxReconciliationScheduler
        box = _safe_box()
        inv = _invoice(posted=True)
        _entry(posted=True, reference_type='invoice', reference_id=inv.id,
               lines=[(box.account_id, 800.0, 0.0, None)])

        SafeboxReconciliationScheduler(flask_app)._run_repair()

        written = SafeBoxTransaction.query.filter_by(safe_box_id=box.id, ref_type='invoice').all()
        assert written, 'phase B still backfills — the business may rely on it'
        keys = {r.subject_key for r in _open('SAFEBOX_ROW_BACKFILLED')}
        assert {f'safe_box_transaction:{t.id}' for t in written} <= keys


class TestManualRepairStillPostsStatusBlind:
    """REPAIR-001 (architecture-v1.md §4.6 Known Gaps) -- phase A's twin.

    POST /safe-boxes/repair-transactions?dry_run=false (admin) still posts every
    unposted voucher entry on a posted invoice, with no look at the voucher's
    status: the defect removed from the nightly job above, left in the manual
    tool. Its dry run lists 'would_post_voucher_je' without the status, so the
    admin who confirms it cannot see a pending or cancelled payment in the list.

    Strict: the day the endpoint stops posting, this XPASSes and turns red --
    the signal to delete the marker and close REPAIR-001. Preconditions fail
    with pytest.fail, not assert, so a broken setup is a real failure and never
    passes as the expected one (raises=AssertionError).
    """

    @pytest.fixture(autouse=True)
    def _keep_the_endpoints_commit_inside_the_test(self, monkeypatch):
        # Same reason as the nightly job's tests: a real commit escapes teardown.
        monkeypatch.setattr(db.session, 'commit', db.session.flush)

    @pytest.mark.xfail(strict=True, raises=AssertionError,
                       reason='REPAIR-001: the manual repair endpoint posts voucher '
                              'entries without reading the voucher status')
    def test_it_does_not_post_a_pending_vouchers_entry(self, app):
        from auth_decorators import generate_token
        from models import User

        admin = User(username=f'repair_{_uid()}', full_name='repair witness',
                     is_active=True, is_admin=True)
        admin.set_password('x')
        db.session.add(admin)
        inv = _invoice(posted=True)
        v = _voucher(status='pending', reference_type='invoice', reference_id=inv.id)
        je = _entry(posted=False, draft=False, reference_type='voucher', reference_id=v.id,
                    lines=[(_account().id, 500.0, 0.0, None)])

        with flask_app.test_client() as c:
            resp = c.post('/api/safe-boxes/repair-transactions?dry_run=false',
                          headers={'Authorization': f'Bearer {generate_token(admin)}'})
        if resp.status_code != 200:
            pytest.fail(f'precondition: the endpoint must run, got {resp.status_code} '
                        f'{resp.get_data(as_text=True)[:300]}')

        assert db.session.get(JournalEntry, je.id).is_posted is False, (
            "a pending voucher's entry reached the ledger through the manual repair")
