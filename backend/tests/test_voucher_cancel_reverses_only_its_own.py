"""Cancelling a voucher must reverse that voucher's money -- nobody else's.

The retraction guard (tests/test_invoice_retraction_guard.py) tells staff to
cancel a payment before unposting or rejecting its invoice. That puts
cancel_voucher on the correction path, and measured on the post-incident
production copy (2026-09-28) it could reverse money it did not own in two ways:

  JOURNAL -- add_invoice_payment has consolidated an invoice's payments into
  ONE JournalEntry since 2026-04-10, but lines only carry source_voucher_id
  since 2026-09-21. 236 shared entries (513 vouchers) predate the tag. For
  those, _reverse_voucher_journal_entry fell back to "reverse the whole entry"
  -- every sibling payment with it. 1641's six receipts share one entry.

  SAFE BOX -- an 'invoice_payment' row's ref_id is EITHER a voucher id OR an
  invoice_payment id (see _validate_safe_box_transaction_or_raise), and the
  reversal selected rows by ref_id alone. Where the numbers coincide it
  reversed a stranger's payment: cancelling voucher 638 (a 5,000.00 bank
  payment) also reversed invoice 561's 30,400.00 cash receipt, payment #638.
  Three such reversals exist; 186 more payment-keyed rows share a number with
  some other voucher.

RULES ENFORCED
  - A shared entry whose lines do not say which voucher wrote them cannot be
    split, so cancelling one of its vouchers is refused (409
    cannot_isolate_voucher_lines) -- a guess is not a reversal. An entry the
    voucher owns outright still reverses in full.
  - A safe-box row is reversed only when it is provably the voucher's own: a
    'voucher' row, a row keyed by the voucher (ref_id != invoice_payment_id),
    or a payment-keyed row whose payment names this voucher as its source.

Run:
    python -m pytest tests/test_voucher_cancel_reverses_only_its_own.py -v
"""
import json
import uuid
from datetime import datetime

from app import app
from models import (
    Account, Invoice, InvoicePayment, JournalEntry, JournalEntryLine, PaymentMethod,
    SafeBox, SafeBoxTransaction, User, Voucher, db,
)


def _uid():
    return uuid.uuid4().hex[:8]


def _account():
    acc = Account(account_number=f'9{_uid()[:6]}', name=f'حساب {_uid()}', type='Asset')
    db.session.add(acc)
    db.session.flush()
    return acc


def _box():
    now = datetime.now()
    box = SafeBox(name=f'صندوق {_uid()}', safe_type='cash', account_id=_account().id,
                  is_active=True, is_default=False, created_at=now, updated_at=now)
    db.session.add(box)
    db.session.flush()
    return box


def _voucher(amount, *, voucher_id=None, notes=None):
    v = Voucher(voucher_number=f'RV-{_uid()}', voucher_type='receipt', date=datetime.now(),
                reference_type='invoice', reference_id=1, amount_cash=amount,
                status='approved', created_by='t', created_at=datetime.now(), notes=notes)
    if voucher_id is not None:
        v.id = voucher_id
    db.session.add(v)
    db.session.flush()
    return v


def _entry(lines, *, reference_type='invoice_payments'):
    """lines: [(amount, source_voucher_id or None), ...] -> one debit/credit pair each."""
    safe, party = _account(), _account()
    je = JournalEntry(entry_number=f'JE-{_uid()}', date=datetime.now(), description='t',
                      reference_type=reference_type, reference_id=1, is_posted=True,
                      posted_at=datetime.now(), posted_by='t', created_by='t')
    db.session.add(je)
    db.session.flush()
    for amount, tag in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=safe.id,
                                        cash_debit=amount, source_voucher_id=tag))
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=party.id,
                                        cash_credit=amount, source_voucher_id=tag))
    db.session.flush()
    return je


def _cancel(voucher_id):
    # Every /api request needs a session (api_auth_guard, ADR-031). This route used
    # to answer anonymous requests only because it was open; sign in as the seeded admin.
    from auth_decorators import generate_token
    token = generate_token(User.query.filter_by(username='admin').first())
    return app.test_client().post(f'/api/vouchers/{voucher_id}/cancel',
                                  json={'reason': 'test', 'cancelled_by': 't'},
                                  headers={'Authorization': f'Bearer {token}'})


def _reversal_entry(voucher_id):
    return JournalEntry.query.filter_by(reference_type='voucher_reversal',
                                        reference_id=voucher_id).first()


class TestAnUntaggedSharedEntryCannotBeSplit:
    def test_cancelling_one_of_two_receipts_is_refused(self):
        """1641's shape: several receipts, one entry, no tags."""
        with app.app_context():
            a, b = _voucher(3000.0), _voucher(7000.0)
            je = _entry([(3000.0, None), (7000.0, None)])
            a.journal_entry_id = je.id
            b.journal_entry_id = je.id
            db.session.commit()
            a_num, b_id = a.voucher_number, b.id

            resp = _cancel(b_id)

            assert resp.status_code == 409, resp.data
            body = resp.get_json()
            assert body['error'] == 'cannot_isolate_voucher_lines'
            assert a_num in body['message']
            db.session.expire_all()
            assert Voucher.query.get(b_id).status == 'approved'
            assert _reversal_entry(b_id) is None

    def test_a_tagged_shared_entry_reverses_only_its_own_lines(self):
        with app.app_context():
            a, b = _voucher(3000.0), _voucher(7000.0)
            je = _entry([(3000.0, a.id), (7000.0, b.id)])
            a.journal_entry_id = je.id
            b.journal_entry_id = je.id
            db.session.commit()
            b_id = b.id

            assert _cancel(b_id).status_code == 200
            db.session.expire_all()
            rev = _reversal_entry(b_id)
            assert sorted((l.cash_debit or 0.0, l.cash_credit or 0.0) for l in rev.lines) == \
                [(0.0, 7000.0), (7000.0, 0.0)]

    def test_an_entry_the_voucher_owns_outright_still_reverses_in_full(self):
        with app.app_context():
            v = _voucher(5000.0)
            je = _entry([(5000.0, None)], reference_type='voucher')
            v.journal_entry_id = je.id
            db.session.commit()
            v_id = v.id

            assert _cancel(v_id).status_code == 200
            db.session.expire_all()
            assert Voucher.query.get(v_id).status == 'cancelled'
            rev = _reversal_entry(v_id)
            assert sorted((l.cash_debit or 0.0, l.cash_credit or 0.0) for l in rev.lines) == \
                [(0.0, 5000.0), (5000.0, 0.0)]


class TestTheSafeBoxReversalTakesOnlyItsOwnRows:
    def _unrelated_payment_numbered(self, number, box, amount):
        """Another invoice's payment whose id happens to equal *number*, with
        the payment-keyed safe-box row add_invoice_payment wrote for it."""
        inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع',
                      date=datetime.now(), total=amount, status='paid', is_posted=True)
        db.session.add(inv)
        pm = PaymentMethod(name=f'نقداً {_uid()}', payment_type='cash')
        db.session.add(pm)
        db.session.flush()
        ip = InvoicePayment(id=number, invoice_id=inv.id, payment_method_id=pm.id,
                            amount=amount, net_amount=amount, created_at=datetime.now())
        db.session.add(ip)
        db.session.flush()
        db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='invoice_payment',
                                          ref_id=number, invoice_payment_id=number,
                                          invoice_id=inv.id, direction='in', amount_cash=amount,
                                          created_at=datetime.now(), created_by='t'))
        db.session.flush()
        return ip

    def test_the_638_shape_a_strangers_payment_sharing_the_number(self):
        with app.app_context():
            number = 700000 + int(_uid(), 16) % 90000
            box = _box()
            ip = self._unrelated_payment_numbered(number, box, 30400.0)
            v = _voucher(5000.0, voucher_id=number)
            je = _entry([(5000.0, None)], reference_type='voucher')
            v.journal_entry_id = je.id
            db.session.add(SafeBoxTransaction(safe_box_id=box.id, ref_type='voucher', ref_id=v.id,
                                              direction='out', amount_cash=5000.0,
                                              created_at=datetime.now(), created_by='t'))
            db.session.commit()
            v_id, ip_id = v.id, ip.id

            assert _cancel(v_id).status_code == 200

            db.session.expire_all()
            reversed_cash = sorted(
                (t.direction, t.amount_cash) for t in
                SafeBoxTransaction.query.filter_by(ref_type='voucher_reversal', ref_id=v_id))
            assert reversed_cash == [('in', 5000.0)], reversed_cash
            assert InvoicePayment.query.get(ip_id) is not None

    def test_its_own_payment_keyed_row_is_still_reversed(self):
        """When the payment names this voucher as its source, a payment-keyed
        row with the same number is the voucher's own."""
        with app.app_context():
            number = 800000 + int(_uid(), 16) % 90000
            box = _box()
            ip = self._unrelated_payment_numbered(number, box, 1200.0)
            v = _voucher(1200.0, voucher_id=number,
                         notes=json.dumps({'invoice_payment_id': number}))
            ip.source_voucher_id = v.id
            je = _entry([(1200.0, None)], reference_type='voucher')
            v.journal_entry_id = je.id
            db.session.commit()
            v_id = v.id

            assert _cancel(v_id).status_code == 200

            db.session.expire_all()
            reversed_cash = [(t.direction, t.amount_cash) for t in
                             SafeBoxTransaction.query.filter_by(ref_type='voucher_reversal',
                                                                ref_id=v_id)]
            assert reversed_cash == [('out', 1200.0)], reversed_cash
