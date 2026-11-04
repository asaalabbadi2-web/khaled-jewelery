"""A supplier's karats are converted to the main karat, then only the net is written off (REPORTS ت3-2د, ADR-083; ADR-025 amended).

The owner, 4 Nov 2026 («تحويل عيار ثم تصفية»): a supplier paid in 24k for a
21k purchase carries two large opposite karat balances that are nothing in
the main karat (on the 2 Nov copy: 21k -424.31 g, 24k +371.27 g -- 0.001 g of
21k). The write-off measured each karat's magnitude, so it refused 21 of 27
suppliers. Now, in the same voucher and entry:
  * each other karat's balance moves to the main karat at its purity's
    equivalent, against «تحويل أعيرة الموردين» (supplier_karat_conversion) --
    the engine balances every karat, so a conversion needs its counterpart;
    that account is zero in the main karat, always (the nightly check says
    the night it is not);
  * the main karat's net is what is written off, and what the tolerance and
    the month's cap measure;
  * a reversal undoes both.
The «no unpaid invoices» gate reads the supplier's running account, not the
stored status.

Run:
    python -m pytest tests/test_supplier_settlement_karat_conversion.py -v
"""
import pytest

from models import Invoice, JournalEntryLine, SupplierSettlementAdjustment, db
from services.supplier_settlement_adjustment_service import ACCOUNT_TYPE_KARAT_CONVERSION, MissingAccountingMappingError
from tests.test_supplier_settlement_adjustment import (  # noqa: F401 (fixtures)
    NOW, _balance, _give_residual, _post_adjustment, app, conversion, policy, rollback_after_each, service,
    settlement_accounts, supplier,
)


def _held(account):
    """{karat: debit - credit} on *account*."""
    out = {}
    for k in (18, 21, 22, 24):
        d = db.session.query(db.func.sum(getattr(JournalEntryLine, f'debit_{k}k'))).filter(
            JournalEntryLine.account_id == account.id).scalar() or 0.0
        c = db.session.query(db.func.sum(getattr(JournalEntryLine, f'credit_{k}k'))).filter(
            JournalEntryLine.account_id == account.id).scalar() or 0.0
        out[k] = round(float(d) - float(c), 6)
    return out


def _offsetting(supplier):
    """21k -424.31 (owed to it), 24k +371.27 (it holds ours): 0.0014 g of 21k owed."""
    _give_residual(supplier, karat_field='credit_21k', karat_amount=424.31)
    _give_residual(supplier, karat_field='debit_24k', karat_amount=371.27)


def test_offsetting_karats_are_converted_and_only_the_net_written_off(
        service, supplier, policy, settlement_accounts, conversion):
    _offsetting(supplier)
    sad = _post_adjustment(service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE)
    assert sad.status == SupplierSettlementAdjustment.STATUS_POSTED
    after = _balance(supplier)
    assert all(abs(after[f'{k}k']) <= 0.001 for k in (18, 21, 22, 24)), after
    held = _held(conversion)
    assert held[24] == pytest.approx(371.27, abs=1e-6)
    assert held[21] == pytest.approx(-424.309, abs=1e-6)
    assert held[24] * 24 / 21 + held[21] == pytest.approx(0.0, abs=0.001), 'zero in the main karat'
    written = [l for l in sad.voucher.account_lines.all()
               if l.account_id in (settlement_accounts['weight_expense'].id, settlement_accounts['weight_income'].id)]
    assert [(l.karat, l.amount) for l in written] == [(21.0, 0.001)]


def test_a_conversion_asks_for_its_account(service, supplier, policy, settlement_accounts):
    _offsetting(supplier)
    sad = service.create_draft(supplier=supplier, reason_code=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE,
                               created_by='tester', now=NOW)
    preview = service.preview(sad=sad, now=NOW)
    configured = next(c for c in preview.eligibility.checks if c.name == 'accounting_configured')
    assert not configured.passed and ACCOUNT_TYPE_KARAT_CONVERSION in configured.detail
    service.approve(sad=sad, approved_by='approver', now=NOW)
    with pytest.raises(MissingAccountingMappingError):
        service.post(sad=sad, posted_by='poster', now=NOW)


def test_one_karat_needs_no_conversion(service, supplier, policy, settlement_accounts):
    """No conversion account mapped: a main-karat residual is written off as before."""
    _give_residual(supplier, karat_field='debit_21k', karat_amount=0.030)
    sad = _post_adjustment(service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE)
    assert sad.status == SupplierSettlementAdjustment.STATUS_POSTED
    assert abs(_balance(supplier)['21k']) <= 0.001


def test_a_reversal_undoes_the_conversion_too(service, supplier, policy, settlement_accounts, conversion):
    _offsetting(supplier)
    before = _balance(supplier)
    sad = _post_adjustment(service, supplier, reason=SupplierSettlementAdjustment.REASON_WEIGHT_DIFFERENCE)
    service.reverse(sad=sad, reversed_by='reverser', now=NOW, reason='اختبار')
    after = _balance(supplier)
    for k in (18, 21, 22, 24):
        assert after[f'{k}k'] == pytest.approx(before[f'{k}k'], abs=1e-6)
    assert all(abs(v) < 1e-6 for v in _held(conversion).values())


def test_the_invoices_gate_reads_the_running_account(service, supplier, policy, settlement_accounts):
    """A tracked purchase stored «unpaid» that the running account has paid does not block."""
    from datetime import timedelta
    invoice = Invoice(invoice_type='شراء', invoice_type_id=10**8 + supplier.id, date=NOW - timedelta(days=3),
                      supplier_id=supplier.id, total=0.0, is_posted=True, status='unpaid',
                      gold_settlement_tracked=True)
    db.session.add(invoice)
    db.session.flush()
    bought = _give_residual(supplier, karat_field='credit_21k', karat_amount=10.0)
    bought.reference_type, bought.reference_id = 'invoice', invoice.id
    _give_residual(supplier, karat_field='debit_21k', karat_amount=10.03)
    db.session.flush()
    result = service.check_eligibility(supplier, now=NOW)
    gate = next(c for c in result.checks if c.name == 'no_unpaid_invoices')
    assert gate.passed, gate.detail


def test_the_night_says_when_the_conversion_account_is_not_zero(conversion):
    from datetime import datetime
    from models import JournalEntry
    from services.books_invariants import KARAT_CONVERSION_ADRIFT, check_karat_conversion_adrift
    assert check_karat_conversion_adrift() == []
    entry = JournalEntry(entry_number='JE-KC-1', date=datetime(2026, 9, 1), description='انحراف', entry_type='عادي',
                         is_posted=True, is_draft=False, created_by='test')
    db.session.add(entry)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=entry.id, account_id=conversion.id, debit_24k=1.0,
                                    description='انحراف'))
    db.session.flush()
    [fact] = check_karat_conversion_adrift()
    assert fact.kind == KARAT_CONVERSION_ADRIFT
    assert fact.metric == pytest.approx(24 / 21, abs=1e-3)
