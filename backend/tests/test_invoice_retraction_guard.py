"""Rejecting, unposting or deleting an invoice must not silently destroy -- or
revive -- a real payment, and delete must refuse anything it did not write.

INCIDENTS, 2026-09-26/27:
  3132 (purchase, 24.2 g) -- its gold payment PV-2026-01223 had physically left
  the scrap box. The invoice was unposted (which reset the payment voucher to
  'pending'), rejected, then DELETED: delete_unposted_invoice removed the
  payment and its JEs but not the voucher_reversal JE of an earlier safe-box
  correction, which stayed orphaned and doubled the supplier's balance.
  3123 (sale, 2,150.00 by Mada) -- rejected with its receipt still standing; the
  clearing scheduler later settled that dead payment (fixed in 3cfee32/fe8ffc6).
  Deleting 3123 was attempted and crashed on fk_invoice_payment_source_voucher
  -- the crash is what saved its data.

UNPOST, measured 2026-09-28 on the post-incident production copy: unposting
swept every voucher linked to the invoice -- reversed its safe-box rows,
unposted its JE, set it 'pending' -- and re-posting re-approved the voucher and
re-posted its JE but never wrote the safe-box rows back. 1641, 1779, 2204 and
2478 were unposted and re-posted between May and July: 92,385.00 of approved,
posted receipts reads as zero in the cash and Mada statements. Unpost -> re-post
was never the round trip it was assumed to be (an earlier version of this
docstring said it was).

A payment is an event that happened. Retracting the document it was linked to
does not un-happen it: the payment has to be cancelled, or its attribution
moved to the invoice that replaces this one, BEFORE the document is retracted.

RULES ENFORCED
  reject, unpost -- refused while a live payment stands against the invoice
    (services/invoice_retraction_guard.live_payments_of): a linked voucher that
    is not cancelled; an InvoicePayment whose creating voucher is not
    cancelled; a voucher whose gold is attributed to the invoice -- the only
    evidence an independent payment leaves, since its reference_type names no
    invoice. Every unpost path asks: the posting screen's single and batch
    routes and routes/invoices.py's.
  unpost -- never touches a linked voucher. Under the rule above only cancelled
    ones can remain, and the old sweep would have set them back to 'pending'
    for the next post to approve: a cancelled payment revived and counted
    again -- 3123's double settlement by another road.
  delete -- refused while any row another document or process wrote about the
    invoice exists (services/invoice_retraction_guard.REFERENCES). Every
    foreign key into an invoice, or into a row the invoice owns, must be
    classified there; TestEveryReferenceIsClassified fails otherwise. So a new
    table makes delete refuse more, never destroy more.

NOT covered here, deliberately: the edit path's own deletion of linked
vouchers (update_unposted_invoice) is recorded as a known gap.

Run:
    python -m pytest tests/test_invoice_retraction_guard.py -v
"""
import uuid
from datetime import datetime

import pytest
import sqlalchemy as sa

from app import app
from models import (
    Account, AuditLog, Invoice, InvoiceGoldObligation, InvoiceItem, InvoiceKaratLine,
    InvoicePayment, JournalEntry, JournalEntryLine, PaymentMethod, SafeBox,
    SafeBoxTransaction, Settings, Voucher, VoucherInvoiceGoldAttribution,
    WeightClosingExecution, WeightClosingOrder, db,
)
from tests.voucher_world import stand_posted


def _uid():
    return uuid.uuid4().hex[:8]


def _invoice(invoice_type='شراء'):
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type=invoice_type,
                  date=datetime.now(), total=1000.0, status='unpaid',
                  amount_paid=0.0, is_posted=False)
    db.session.add(inv)
    db.session.flush()
    return inv


def _voucher(inv, *, status, voucher_type='payment'):
    v = Voucher(voucher_number=f'PV-{_uid()}', voucher_type=voucher_type, date=datetime.now(),
                reference_type='invoice', reference_id=inv.id, status=status,
                created_by='t', amount_cash=0.0, created_at=datetime.now())
    db.session.add(v)
    db.session.flush()
    return stand_posted(v) if status == 'approved' else v


def _payment(inv, voucher):
    pm = PaymentMethod(name=f'مدى {_uid()}', payment_type='mada')
    db.session.add(pm)
    db.session.flush()
    ip = InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id, amount=500.0,
                        net_amount=500.0, source_voucher_id=voucher.id if voucher else None,
                        created_at=datetime.now())
    db.session.add(ip)
    db.session.flush()
    return ip


def _account():
    acc = Account(account_number=f'8{_uid()[:6]}', name=f'حساب {_uid()}', type='Asset')
    db.session.add(acc)
    db.session.flush()
    return acc


def _je(reference_type, reference_id, *, cash=500.0):
    """A posted, balanced two-line entry."""
    acc = _account()
    je = JournalEntry(entry_number=f'JE-{_uid()}', date=datetime.now(), description='t',
                      reference_type=reference_type, reference_id=reference_id,
                      is_posted=True, posted_at=datetime.now(), posted_by='t', created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=acc.id, cash_debit=cash))
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=acc.id, cash_credit=cash))
    db.session.flush()
    return je


def _posted(inv):
    inv.is_posted = True
    inv.posted_at = datetime.now()
    inv.posted_by = 't'
    _je('invoice', inv.id)
    return inv


def _receipt_with_entry(inv, *, status):
    """A receipt with its own posted JE -- and, if cancelled, the reversal JE
    that cancel_voucher writes."""
    v = _voucher(inv, status=status, voucher_type='receipt')
    vje = _je('voucher', v.id)
    v.journal_entry_id = vje.id
    rev = _je('voucher_reversal', v.id) if status == 'cancelled' else None
    db.session.flush()
    return v, vje, rev


def _independent_gold_payment(inv):
    """A gold payment made on its own -- its reference_type names no invoice --
    later attributed to *inv* (the path 3132's replacement took)."""
    v = Voucher(voucher_number=f'PV-{_uid()}', voucher_type='payment', date=datetime.now(),
                reference_type=None, reference_id=None, status='approved',
                created_by='t', amount_cash=0.0, created_at=datetime.now())
    db.session.add(v)
    db.session.flush()
    stand_posted(v)
    db.session.add(VoucherInvoiceGoldAttribution(
        voucher_id=v.id, invoice_id=inv.id, karat=18.0, weight=24.2,
        weight_main_karat=20.743, created_by='t'))
    db.session.flush()
    return v


def _box():
    now = datetime.now()
    box = SafeBox(name=f'خزينة {_uid()}', safe_type='gold', account_id=_account().id,
                  is_active=True, is_default=False, created_at=now, updated_at=now)
    db.session.add(box)
    db.session.flush()
    return box


def _movement(inv, ref_type, *, w21=5.0, direction='out'):
    t = SafeBoxTransaction(safe_box_id=_box().id, ref_type=ref_type, ref_id=inv.id,
                           invoice_id=inv.id, direction=direction, amount_cash=0.0,
                           weight_21k=w21, created_at=datetime.now(), created_by='t')
    db.session.add(t)
    db.session.flush()
    return t


def _reject(client, headers, inv_id):
    return client.post(f'/api/invoices/{inv_id}/reject', headers=headers, json={})


def _delete(client, headers, inv_id):
    return client.delete(f'/api/invoices/{inv_id}', headers=headers)


UNPOST_PATHS = ('posting_screen', 'posting_screen_batch', 'invoices_api')


def _unpost(client, headers, inv_id, path):
    if path == 'posting_screen':
        return client.post(f'/api/invoices/unpost/{inv_id}', headers=headers, json={})
    if path == 'posting_screen_batch':
        return client.post('/api/invoices/unpost-batch', headers=headers,
                           json={'invoice_ids': [inv_id]})
    return client.post(f'/api/invoices/{inv_id}/unpost', headers=headers, json={})


@pytest.fixture
def unposting_allowed():
    """allow_unposting on, and the settings left exactly as found -- a row
    this fixture had to create is deleted again, because other tests read
    their configuration from whether one exists."""
    with app.app_context():
        row = Settings.query.first()
        created = row is None
        if created:
            row = Settings()
            db.session.add(row)
        previous = row.allow_unposting
        row.allow_unposting = True
        db.session.commit()
        row_id = row.id
    yield
    with app.app_context():
        row = Settings.query.get(row_id)
        if created:
            db.session.delete(row)
        else:
            row.allow_unposting = previous
        db.session.commit()


class TestRejectIsRefusedWhileAPaymentStands:
    def test_the_3132_shape_a_pending_gold_payment(self, auth_headers):
        """After unpost the payment voucher is 'pending', not 'cancelled' --
        exactly the state 3132's PV-2026-01223 was in when it was rejected."""
        with app.app_context():
            inv = _invoice('شراء')
            v = _voucher(inv, status='pending')
            db.session.commit()
            inv_id, v_id = inv.id, v.id

            resp = _reject(app.test_client(), auth_headers, inv_id)

            assert resp.status_code == 409, resp.data
            body = resp.get_json()
            assert body['error'] == 'has_live_payments'
            assert v.voucher_number in body['message']
            db.session.expire_all()
            assert Invoice.query.get(inv_id).status == 'unpaid'
            assert Voucher.query.get(v_id).status == 'pending'

    def test_the_3123_shape_a_standing_receipt(self, auth_headers):
        with app.app_context():
            inv = _invoice('بيع')
            v = _voucher(inv, status='approved', voucher_type='receipt')
            _payment(inv, v)
            db.session.commit()
            inv_id = inv.id

            resp = _reject(app.test_client(), auth_headers, inv_id)

            assert resp.status_code == 409, resp.data
            db.session.expire_all()
            assert Invoice.query.get(inv_id).status == 'unpaid'

    def test_a_draft_payment_goes_with_the_rejection(self, auth_headers):
        """source_voucher_id NULL on an unposted invoice, and no safe-box row: a
        payment saved while the invoice waited for approval. Until 1 Oct 2026
        it stood -- nothing showed it cancelled -- and it made the invoice
        impossible to reject or delete (RETRACT-001, invoice 3158). The owner's
        decision: an unposted invoice is a draft with no financial effect
        (ADR-034), and so is such a payment; rejecting withdraws it, and the
        audit row names it."""
        with app.app_context():
            inv = _invoice('بيع')
            ip = _payment(inv, None)
            db.session.commit()
            inv_id, ip_id = inv.id, ip.id
            resp = _reject(app.test_client(), auth_headers, inv_id)
            assert resp.status_code == 200, resp.get_data(as_text=True)[:200]
            db.session.expire_all()
            assert db.session.get(InvoicePayment, ip_id) is None
            row = (AuditLog.query.filter_by(entity_id=inv_id, action='reject', success=True)
                   .order_by(AuditLog.id.desc()).first())
            assert row is not None and '"payment_id": %d' % ip_id in row.details

    def test_a_voucherless_payment_that_moved_a_safe_still_stands(self, auth_headers):
        """No voucher, but a safe-box row: the money moved. That is an event, not
        a draft, and it still refuses the rejection."""
        with app.app_context():
            inv = _invoice('بيع')
            ip = _payment(inv, None)
            box = _box()
            db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='invoice_payment', ref_id=ip.id,
                                              invoice_id=inv.id, invoice_payment_id=ip.id,
                                              direction='in', amount_cash=500.0))
            db.session.commit()
            assert _reject(app.test_client(), auth_headers, inv.id).status_code == 409

    def test_an_independent_gold_payment_attributed_to_it(self, auth_headers):
        """Its voucher names no invoice; the attribution row is the evidence.
        Remove or move the attribution first -- the payment itself stays."""
        with app.app_context():
            inv = _invoice('شراء')
            v = _independent_gold_payment(inv)
            db.session.commit()
            inv_id = inv.id

            resp = _reject(app.test_client(), auth_headers, inv_id)

            assert resp.status_code == 409, resp.data
            assert v.voucher_number in resp.get_json()['message']
            db.session.expire_all()
            assert Invoice.query.get(inv_id).status == 'unpaid'
            assert VoucherInvoiceGoldAttribution.query.filter_by(invoice_id=inv_id).count() == 1


class TestRejectStillWorksWhenNothingStands:
    def test_no_payment_at_all(self, auth_headers):
        with app.app_context():
            inv = _invoice()
            db.session.commit()
            resp = _reject(app.test_client(), auth_headers, inv.id)
            assert resp.status_code == 200, resp.data
            db.session.expire_all()
            assert Invoice.query.get(inv.id).status == 'rejected'

    def test_a_cancelled_payment_does_not_block(self, auth_headers):
        """The safe order: cancel the payment first, then reject."""
        with app.app_context():
            inv = _invoice('بيع')
            v = _voucher(inv, status='cancelled', voucher_type='receipt')
            _payment(inv, v)
            db.session.commit()
            resp = _reject(app.test_client(), auth_headers, inv.id)
            assert resp.status_code == 200, resp.data


class TestUnpostIsRefusedWhileAPaymentStands:
    @pytest.mark.parametrize('path', UNPOST_PATHS)
    def test_a_standing_receipt_blocks_every_unpost_path(self, auth_headers, unposting_allowed, path):
        """1641's shape. Refused before anything is written: the voucher stays
        approved, its JE stays posted, no safe-box reversal appears."""
        with app.app_context():
            inv = _posted(_invoice('بيع'))
            v, vje, _ = _receipt_with_entry(inv, status='approved')
            db.session.commit()
            inv_id, v_id, vje_id = inv.id, v.id, vje.id

            resp = _unpost(app.test_client(), auth_headers, inv_id, path)

            assert resp.status_code == 409, resp.data
            assert resp.get_json()['error'] == 'has_live_payments'
            assert v.voucher_number in resp.get_json()['message']
            db.session.expire_all()
            assert Invoice.query.get(inv_id).is_posted is True
            assert Voucher.query.get(v_id).status == 'approved'
            assert JournalEntry.query.get(vje_id).is_posted is True
            assert SafeBoxTransaction.query.filter_by(
                ref_type='voucher_reversal', ref_id=v_id).count() == 0

    @pytest.mark.parametrize('path', UNPOST_PATHS)
    def test_an_independent_gold_payment_blocks_every_unpost_path(
            self, auth_headers, unposting_allowed, path):
        with app.app_context():
            inv = _posted(_invoice('شراء'))
            _independent_gold_payment(inv)
            db.session.commit()
            inv_id = inv.id

            resp = _unpost(app.test_client(), auth_headers, inv_id, path)

            assert resp.status_code == 409, resp.data
            db.session.expire_all()
            assert Invoice.query.get(inv_id).is_posted is True
            assert VoucherInvoiceGoldAttribution.query.filter_by(invoice_id=inv_id).count() == 1

    def test_the_batch_refuses_whole_and_names_the_blocking_invoice(
            self, auth_headers, unposting_allowed):
        """All or nothing: a batch that would retract one paid invoice
        retracts none, and says which one stopped it."""
        with app.app_context():
            paid = _posted(_invoice('بيع'))
            _receipt_with_entry(paid, status='approved')
            unpaid = _posted(_invoice('بيع'))
            db.session.commit()
            paid_id, unpaid_id = paid.id, unpaid.id

            resp = app.test_client().post('/api/invoices/unpost-batch', headers=auth_headers,
                                          json={'invoice_ids': [unpaid_id, paid_id]})

            assert resp.status_code == 409, resp.data
            assert str(paid_id) in resp.get_json()['blocked']
            db.session.expire_all()
            assert Invoice.query.get(unpaid_id).is_posted is True
            assert Invoice.query.get(paid_id).is_posted is True


class TestUnpostNeverRevivesACancelledPayment:
    @pytest.mark.parametrize('path', UNPOST_PATHS)
    def test_a_cancelled_receipt_stays_cancelled_through_unpost_and_repost(
            self, auth_headers, unposting_allowed, path):
        """The order the guard asks for -- cancel the payment, then unpost --
        must not bring the payment back. The old sweep set every linked
        voucher to 'pending' and unposted its JE while leaving the cancel's
        reversal posted; the next post then approved it again."""
        with app.app_context():
            inv = _posted(_invoice('بيع'))
            v, vje, rev = _receipt_with_entry(inv, status='cancelled')
            db.session.commit()
            inv_id, v_id, vje_id, rev_id = inv.id, v.id, vje.id, rev.id
            client = app.test_client()

            resp = _unpost(client, auth_headers, inv_id, path)
            assert resp.status_code == 200, resp.data
            db.session.expire_all()
            assert Invoice.query.get(inv_id).is_posted is False
            assert Voucher.query.get(v_id).status == 'cancelled'
            # The payment and its cancellation are both facts; both stay posted.
            assert JournalEntry.query.get(vje_id).is_posted is True
            assert JournalEntry.query.get(rev_id).is_posted is True

            resp = client.post(f'/api/invoices/post/{inv_id}', headers=auth_headers, json={})
            assert resp.status_code == 200, resp.data
            db.session.expire_all()
            assert Voucher.query.get(v_id).status == 'cancelled'
            from services.invoice_retraction_guard import live_payments_of
            assert live_payments_of(inv_id) == []


class TestUnpostStillWorksWhenNothingStands:
    @pytest.mark.parametrize('path', UNPOST_PATHS)
    def test_an_unpaid_invoice_unposts(self, auth_headers, unposting_allowed, path):
        with app.app_context():
            inv = _posted(_invoice('بيع'))
            db.session.commit()
            resp = _unpost(app.test_client(), auth_headers, inv.id, path)
            assert resp.status_code == 200, resp.data
            db.session.expire_all()
            assert Invoice.query.get(inv.id).is_posted is False


class TestDeleteIsRefusedForAnyFinancialHistory:
    def test_a_cancelled_voucher_is_still_history(self, auth_headers):
        with app.app_context():
            inv = _invoice()
            _voucher(inv, status='cancelled')
            db.session.commit()
            inv_id = inv.id

            resp = _delete(app.test_client(), auth_headers, inv_id)

            assert resp.status_code == 409, resp.data
            assert resp.get_json()['error'] == 'has_financial_history'
            db.session.expire_all()
            assert Invoice.query.get(inv_id) is not None

    def test_the_3123_shape_no_longer_crashes(self, auth_headers):
        """Used to end in a 500 ForeignKeyViolation on
        fk_invoice_payment_source_voucher. Now a clear refusal."""
        with app.app_context():
            inv = _invoice('بيع')
            v = _voucher(inv, status='pending', voucher_type='receipt')
            _payment(inv, v)
            inv.status = 'rejected'
            db.session.commit()
            resp = _delete(app.test_client(), auth_headers, inv.id)
            assert resp.status_code == 409, resp.data

    def test_an_invoice_with_no_history_is_deleted(self, auth_headers):
        with app.app_context():
            inv = _invoice()
            db.session.commit()
            inv_id = inv.id
            resp = _delete(app.test_client(), auth_headers, inv_id)
            assert resp.status_code == 200, resp.data
            db.session.expire_all()
            assert Invoice.query.get(inv_id) is None


class TestDeleteRefusesWhatItDidNotWrite:
    """Each of these was written by another document or process. The old
    delete removed some (attributions, closings, recon rows) and would have
    crashed on others -- by accident, not by rule."""

    def _refused(self, auth_headers, inv_id):
        resp = _delete(app.test_client(), auth_headers, inv_id)
        assert resp.status_code == 409, resp.data
        assert resp.get_json()['error'] == 'has_financial_history'
        db.session.expire_all()
        assert Invoice.query.get(inv_id) is not None
        return resp.get_json()

    def test_an_independent_gold_payment_attributed_to_it(self, auth_headers):
        with app.app_context():
            inv = _invoice('شراء')
            v = _independent_gold_payment(inv)
            db.session.commit()
            body = self._refused(auth_headers, inv.id)
            assert v.voucher_number in body['message']
            assert VoucherInvoiceGoldAttribution.query.filter_by(invoice_id=inv.id).count() == 1

    def test_a_return_that_points_at_it(self, auth_headers):
        with app.app_context():
            inv = _invoice('بيع')
            ret = _invoice('مرتجع بيع')
            ret.original_invoice_id = inv.id
            db.session.commit()
            self._refused(auth_headers, inv.id)

    def test_a_closing_another_invoice_executed_against_its_order(self, auth_headers):
        """The execution was written by the scrap purchase that closed it, with
        a JE of its own. Deleting it with the order orphaned that JE."""
        with app.app_context():
            inv = _invoice('بيع')
            order = WeightClosingOrder(invoice_id=inv.id, order_number=f'WCO-{_uid()}',
                                       status='partially_closed', main_karat=21.0)
            db.session.add(order)
            db.session.flush()
            closer = _invoice('شراء من عميل')
            db.session.add(WeightClosingExecution(order_id=order.id, source_invoice_id=closer.id,
                                                  execution_type='purchase_scrap',
                                                  weight_main_karat=2.0))
            db.session.commit()
            self._refused(auth_headers, inv.id)
            assert WeightClosingExecution.query.filter_by(order_id=order.id).count() == 1

    def test_a_safe_box_row_another_process_wrote(self, auth_headers):
        """hist_gold_recon_invoice_reversal rows are written by the historical
        reconciliation, not by the invoice (184 in production)."""
        with app.app_context():
            inv = _invoice('بيع')
            _movement(inv, 'hist_gold_recon_invoice_reversal', direction='in')
            db.session.commit()
            self._refused(auth_headers, inv.id)
            assert SafeBoxTransaction.query.filter_by(invoice_id=inv.id).count() == 1

    def test_what_it_did_write_goes_with_it(self, auth_headers):
        """Items, karat lines, its own gold movement, its obligation and its
        closing order -- none of which anyone else wrote -- are removed."""
        with app.app_context():
            inv = _invoice('بيع')
            db.session.add(InvoiceItem(invoice_id=inv.id, quantity=1, price=100.0))
            db.session.add(InvoiceKaratLine(invoice_id=inv.id, karat=21.0, weight_grams=5.0))
            db.session.add(InvoiceGoldObligation(invoice_id=inv.id, karat=21.0, weight=5.0))
            db.session.add(WeightClosingOrder(invoice_id=inv.id, order_number=f'WCO-{_uid()}',
                                              status='open', main_karat=21.0))
            _movement(inv, 'invoice_sale_gold_movement')
            db.session.commit()
            inv_id = inv.id

            resp = _delete(app.test_client(), auth_headers, inv_id)

            assert resp.status_code == 200, resp.data
            db.session.expire_all()
            assert Invoice.query.get(inv_id) is None
            for model in (InvoiceItem, InvoiceKaratLine, InvoiceGoldObligation,
                          WeightClosingOrder, SafeBoxTransaction):
                assert model.query.filter_by(invoice_id=inv_id).count() == 0, model.__name__


class TestEveryReferenceIsClassified:
    """The machine behind "refuse more, never destroy more"."""

    def test_every_foreign_key_into_an_invoice_is_classified(self):
        from services.invoice_retraction_guard import unclassified_references
        unclassified = unclassified_references(db.Model.metadata)
        assert not unclassified, (
            'Unclassified reference(s) into an invoice or a row it owns: '
            f'{sorted(unclassified)}. Add each to REFERENCES in '
            'services/invoice_retraction_guard.py: "owned" if the invoice itself '
            'writes the row (delete removes it), "evidence" if any other document '
            'or process does (delete refuses while one exists). When unsure it '
            'is evidence.'
        )

    def test_every_classification_still_names_a_real_reference(self):
        from services.invoice_retraction_guard import stale_references
        assert not stale_references(db.Model.metadata)

    def test_the_ratchet_sees_a_new_table(self):
        """Witness that the check above can fail: a table it has never heard
        of, pointing at an invoice, is reported."""
        from services.invoice_retraction_guard import unclassified_references
        meta = sa.MetaData()
        sa.Table('invoice', meta, sa.Column('id', sa.Integer, primary_key=True))
        sa.Table('future_thing', meta,
                 sa.Column('id', sa.Integer, primary_key=True),
                 sa.Column('invoice_id', sa.Integer, sa.ForeignKey('invoice.id')))
        assert unclassified_references(meta) == {('future_thing', 'invoice_id')}
