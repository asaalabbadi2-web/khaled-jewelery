"""test_voucher_reversal_scoped_to_own_lines.py
=================================================
Proves the fix for a real reversal bug: add_invoice_payment consolidates every
payment for one invoice into ONE JournalEntry (reference_type='invoice_payments',
see _add_payment_lines_to_consolidated_je). Two vouchers — Payment A and
Payment B — can therefore share voucher.journal_entry_id.

Before the fix, _reverse_voucher_journal_entry mirrored EVERY line of that
shared entry with no regard for which voucher created them. Cancelling
Payment B's voucher reversed Payment A's lines too — a real, silent
over-reversal of money that was never touched.

The fix: JournalEntryLine.source_voucher_id tags which voucher produced each
line. Reversal now selects only the cancelled voucher's own lines when any
line in the entry carries the tag, and falls back to reversing the whole
entry when none do — the correct, unchanged behaviour for the overwhelming
majority of JEs, which were never part of a consolidation to begin with.
"""

from datetime import datetime

import pytest

from app import app
from models import (
    Account,
    JournalEntry,
    JournalEntryLine,
    Voucher,
    db,
)
from routes.vouchers import _reverse_voucher_journal_entry


def _account(number, name, type_='Asset'):
    existing = Account.query.filter_by(account_number=number).first()
    if existing is not None:
        return existing
    acc = Account(account_number=number, name=name, type=type_)
    db.session.add(acc)
    db.session.flush()
    return acc


def _voucher(number, amount):
    v = Voucher(
        voucher_number=number,
        voucher_type='receipt',
        date=datetime.now(),
        reference_type='invoice',
        reference_id=1,
        amount_cash=amount,
        status='approved',
        created_by='test',
    )
    db.session.add(v)
    db.session.flush()
    return v


@pytest.fixture
def consolidated_je_with_two_payments():
    """The exact shape _add_payment_lines_to_consolidated_je produces:
    one JE, two vouchers, each voucher's two lines tagged with its own id."""
    with app.app_context():
        safe_acc = _account('9901', 'صندوق اختبار')
        party_acc = _account('9902', 'ذمم اختبار', 'Liability')

        voucher_a = _voucher('V-TEST-A', 3000.0)
        voucher_b = _voucher('V-TEST-B', 7000.0)

        je = JournalEntry(
            entry_number='JE-TEST-CONSOLIDATED',
            date=datetime.now(),
            description='دفعات فاتورة اختبار',
            entry_type='عادي',
            reference_type='invoice_payments',
            reference_id=1,
            is_posted=True,
            posted_at=datetime.now(),
            posted_by='test',
            created_by='test',
        )
        db.session.add(je)
        db.session.flush()

        voucher_a.journal_entry_id = je.id
        voucher_b.journal_entry_id = je.id

        # Payment A: 3,000 — debit safe / credit party, tagged voucher_a.
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id, account_id=safe_acc.id,
            cash_debit=3000.0, description='دفعة A', source_voucher_id=voucher_a.id,
        ))
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id, account_id=party_acc.id,
            cash_credit=3000.0, description='دفعة A', source_voucher_id=voucher_a.id,
        ))
        # Payment B: 7,000 — same shape, tagged voucher_b.
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id, account_id=safe_acc.id,
            cash_debit=7000.0, description='دفعة B', source_voucher_id=voucher_b.id,
        ))
        db.session.add(JournalEntryLine(
            journal_entry_id=je.id, account_id=party_acc.id,
            cash_credit=7000.0, description='دفعة B', source_voucher_id=voucher_b.id,
        ))
        db.session.commit()

        ids = (voucher_a.id, voucher_b.id, je.id)
        yield ids

        # Teardown: everything this test created, by id, nothing else.
        v_a_id, v_b_id, je_id = ids
        JournalEntryLine.query.filter(
            JournalEntryLine.journal_entry_id.in_(
                [je_id] + [
                    r.id for r in JournalEntry.query.filter_by(reference_type='voucher_reversal').all()
                    if r.reference_id in (v_a_id, v_b_id)
                ]
            )
        ).delete(synchronize_session=False)
        JournalEntry.query.filter(
            (JournalEntry.id == je_id) |
            ((JournalEntry.reference_type == 'voucher_reversal') & (JournalEntry.reference_id.in_([v_a_id, v_b_id])))
        ).delete(synchronize_session=False)
        Voucher.query.filter(Voucher.id.in_([v_a_id, v_b_id])).delete(synchronize_session=False)
        db.session.commit()


def _reversal_lines_for(voucher_id):
    with app.app_context():
        rev_entry = JournalEntry.query.filter_by(
            reference_type='voucher_reversal', reference_id=voucher_id
        ).first()
        if rev_entry is None:
            return []
        return [
            (round(l.cash_debit or 0.0, 2), round(l.cash_credit or 0.0, 2))
            for l in rev_entry.lines
        ]


class TestReversalIsScopedToTheCancelledVoucherOnly:

    def test_cancelling_b_reverses_only_bs_lines_not_as(
        self, consolidated_je_with_two_payments
    ):
        voucher_a_id, voucher_b_id, je_id = consolidated_je_with_two_payments
        with app.app_context():
            voucher_b = Voucher.query.get(voucher_b_id)
            reversal = _reverse_voucher_journal_entry(voucher_b, cancelled_by='test')
            db.session.commit()
            assert reversal is not None

            # Exactly B's two lines (7,000), mirrored — debit/credit swapped.
            rev_lines = sorted(
                [(round(l.cash_debit or 0.0, 2), round(l.cash_credit or 0.0, 2))
                 for l in reversal.lines]
            )
            assert rev_lines == [(0.0, 7000.0), (7000.0, 0.0)], (
                f'expected only B\'s 7,000 reversed, got {rev_lines}'
            )

            # A's original lines are untouched — no reversal entry for A yet.
            assert _reversal_lines_for(voucher_a_id) == []

    def test_cancelling_both_reverses_each_exactly_once(
        self, consolidated_je_with_two_payments
    ):
        """Cancel B, then A. The shared JE must end up reversed once per
        voucher — not the whole entry twice — leaving a clean net-zero."""
        voucher_a_id, voucher_b_id, je_id = consolidated_je_with_two_payments
        with app.app_context():
            voucher_b = Voucher.query.get(voucher_b_id)
            _reverse_voucher_journal_entry(voucher_b, cancelled_by='test')
            db.session.commit()

            voucher_a = Voucher.query.get(voucher_a_id)
            _reverse_voucher_journal_entry(voucher_a, cancelled_by='test')
            db.session.commit()

            b_lines = sorted(_reversal_lines_for(voucher_b_id))
            a_lines = sorted(_reversal_lines_for(voucher_a_id))
            assert b_lines == [(0.0, 7000.0), (7000.0, 0.0)]
            assert a_lines == [(0.0, 3000.0), (3000.0, 0.0)]

            # Net effect across original + both reversals is exactly zero on
            # each account — the whole point of a correct reversal.
            all_line_ids = (
                [l.id for l in JournalEntry.query.get(je_id).lines]
            )
            rev_entries = JournalEntry.query.filter(
                JournalEntry.reference_type == 'voucher_reversal',
                JournalEntry.reference_id.in_([voucher_a_id, voucher_b_id]),
            ).all()
            for e in rev_entries:
                all_line_ids += [l.id for l in e.lines]

            lines = JournalEntryLine.query.filter(JournalEntryLine.id.in_(all_line_ids)).all()
            net_debit = sum(float(l.cash_debit or 0.0) for l in lines)
            net_credit = sum(float(l.cash_credit or 0.0) for l in lines)
            assert round(net_debit, 2) == round(net_credit, 2) == 20000.0, (
                'original (10,000 across 2 lines' + "'" + ' debit+credit) + two full '
                'reversals should sum to 20,000 each side — a fully balanced net-zero'
            )
