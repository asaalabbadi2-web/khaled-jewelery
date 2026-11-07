"""A category's negative balance is never counted «as the books» (8 Nov 2026).

A transfer voucher moves a karat's grams without their category: the scrap
classified «كسر 21» in a custody stays classified there when it is moved to
the scrap safe, and the custody's «بلا تصنيف» goes as negative (Mubarak's
custody on the 5 Nov copy: «كسر 21» +243.93, «بلا تصنيف» −243.93, its 21k
0). A periodic count closed with force leaves an uncounted line as the books
-- and a negative line is no gold to be left as it is: counted «كسر 21» 0, the
approval wrote 243.93 g short to «خسارة الوزن (الفقد)» and the custody went
243.93 g negative in the books. Closing counts a negative line zero.

Run:
    python -m pytest tests/test_count_negative_line.py -v
"""
import pytest

from models import JournalEntry, JournalEntryLine, db
from tests.test_stock_count import NOW, _category, _safe, _stock, _uid, roles  # noqa: F401 -- the fixture
from tests.test_stock_count import app, rollback_after_each  # noqa: F401 -- the module's fixtures


def _moved_out(box, grams, karat=21):
    """A transfer out of the location, as the voucher writes it: grams, no category."""
    je = JournalEntry(entry_number=f'JE-T-{_uid()}', date=NOW, description='نقل', entry_type='عادي',
                      is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, description='نقل',
                                    **{f'credit_{karat}k': grams}))
    db.session.flush()


def _custody_emptied():
    """20 g of «كسر 21» bought into a location, then all of it moved out."""
    box, scrap = _safe('custody'), _category()
    _stock(box, 20.0, scrap)
    _moved_out(box, 20.0)
    return box, scrap


@pytest.mark.parametrize('session_type', ['periodic', 'opening'])
def test_an_emptied_location_counted_empty_differs_in_nothing(app, roles, session_type):
    from services.inventory_count_service import InventoryCountService as S
    box, scrap = _custody_emptied()
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW,
                             session_type=session_type)
    S.populate_lines(session)
    assert sorted(l.expected_weight for l in session.lines) == [-20.0, 20.0]
    S.record_count(session, category_id=scrap.id, karat=21.0, counted_weight=0.0, counted_by='t', now=NOW,
                   safe_box_id=box.id)
    S.close_session(session, force=True, now=NOW)
    _, entry = S.approve_session(session, approved_by='المدير', now=NOW, adjustment_reason='COUNT_ERROR')
    shortage = [l for l in (entry.lines if entry else []) if l.account_id == roles['shortage_w'].id]
    assert not shortage, 'no gold was lost: the negative line is counted zero, not left as the books'


def test_the_negative_line_closes_counted_zero_and_says_so(app, roles):
    from services.inventory_count_service import InventoryCountService as S
    box, scrap = _custody_emptied()
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
    S.populate_lines(session)
    S.record_count(session, category_id=scrap.id, karat=21.0, counted_weight=0.0, counted_by='t', now=NOW,
                   safe_box_id=box.id)
    left = S.close_session(session, now=NOW)
    assert left == 0, 'nothing is left uncounted: no force needed'
    negative = next(l for l in session.lines if l.category_id is None)
    assert (negative.counted_weight, negative.variance) == (0.0, 20.0)
