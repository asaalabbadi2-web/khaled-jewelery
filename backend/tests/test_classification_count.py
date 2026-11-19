"""A classification count: a category weighed, its grams taken from «بلا تصنيف» (the owner, 19 Nov 2026).

«هل يجب في الجرد الفعلي ان نزن التصنيف كاملا ام نزن جزء ونرمز هذا الجزء؟» --
26 kg of the worked gold on hand are «بلا تصنيف» on the 19 Nov copy, «بنجرة ذهب
21» −127.01 g in the showroom; a coding batch needs the category's grams. A
periodic count of the bangles alone read them as found over -- a phantom
«زيادة جرد» -- unless «بلا تصنيف» was counted down by hand by as much. Then:
«ابنه». A count of type 'classify':
  - a category weighed whole; the same grams come off «بلا تصنيف» of its
    karat at once, never typed -- the karat nets to nothing;
  - «بلا تصنيف» is not counted by hand there; no more is taken from it than it holds;
  - it closes with what was not weighed left as it is -- no line zeroed;
  - approved, it moves grams between categories: no surplus, no shortage.

Run:
    python -m pytest tests/test_classification_count.py -v
"""
import pytest

from models import InventoryCountLine, JournalEntry, JournalEntryLine
from services.inventory_count_service import InventoryCountService as S
from tests.test_stock_count import NOW, _category, _held, _safe, _stock, app, roles, rollback_after_each  # noqa: F401


def _open(box):
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW, session_type='classify')
    S.populate_lines(session)
    return session


def _weigh(session, box, category, grams, karat=21):
    return S.record_count(session, category_id=category.id if category else None, karat=karat,
                          counted_weight=grams, counted_by='t', now=NOW, safe_box_id=box.id)


def _unclassified(session, karat=21):
    return InventoryCountLine.query.filter_by(session_id=session.id, category_id=None, karat=float(karat)).one()


def test_a_category_weighed_takes_its_grams_from_the_unclassified(app, roles):
    box, bangles, sets = _safe(), _category(), _category()
    _stock(box, 1000.0)                       # 1,000 g of 21k «بلا تصنيف»
    _stock(box, 5.0, sets)
    session = _open(box)
    _weigh(session, box, bangles, 300.0)
    assert _unclassified(session).counted_weight == pytest.approx(700.0)
    _weigh(session, box, sets, 25.0)          # 5 held, 25 weighed: 20 more off the unclassified
    assert _unclassified(session).counted_weight == pytest.approx(680.0)
    _weigh(session, box, bangles, 310.0)      # weighed again: what it weighs now
    assert _unclassified(session).counted_weight == pytest.approx(670.0)
    assert [r['difference'] for r in S.karat_review(session)] == [pytest.approx(0.0)], 'the karat nets to nothing'


def test_a_category_below_nothing_in_the_books_is_weighed_as_it_is(app, roles):
    """As «بنجرة ذهب 21» at −127.01 g: what it weighs, its trace off the unclassified too."""
    from services.stock_ledger import allocate
    box, bangles = _safe(), _category()
    _stock(box, 1000.0)
    _stock(box, 127.01, bangles)
    # its trace: sold by category with nothing of it left
    je = JournalEntry(entry_number='JE-C-NEG', date=NOW, description='بيع', entry_type='عادي', is_posted=True,
                      is_draft=False, created_by='t')
    from models import db
    db.session.add(je)
    db.session.flush()
    out = JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, description='بيع', credit_21k=254.02)
    db.session.add(out)
    db.session.flush()
    allocate(out, 21, bangles.id, -254.02, by='t', now=NOW)
    session = _open(box)
    _weigh(session, box, bangles, 400.0)
    assert [r['difference'] for r in S.karat_review(session)] == [pytest.approx(0.0)]


def test_the_unclassified_is_not_counted_by_hand_nor_taken_past_what_it_holds(app, roles):
    box, bangles = _safe(), _category()
    _stock(box, 100.0)
    session = _open(box)
    with pytest.raises(ValueError) as by_hand:
        _weigh(session, box, None, 50.0)
    assert 'تلقائيًا' in str(by_hand.value)
    with pytest.raises(ValueError) as past:
        _weigh(session, box, bangles, 150.0)
    assert 'بلا تصنيف' in str(past.value)


def test_approved_it_moves_grams_between_categories_and_nothing_else(app, roles):
    box, bangles, rings = _safe(), _category(), _category()
    _stock(box, 1000.0)
    _stock(box, 40.0, rings)                  # not weighed: left as it is
    session = _open(box)
    _weigh(session, box, bangles, 300.0)
    assert S.close_session(session, now=NOW) >= 1, 'closes with what was not weighed, no warning asked'
    _, entry = S.approve_session(session, approved_by='المدير', now=NOW)
    assert _held(box) == {(bangles.id, 21): pytest.approx(300.0), (rings.id, 21): pytest.approx(40.0),
                          (None, 21): pytest.approx(700.0)}
    lines = JournalEntryLine.query.filter_by(journal_entry_id=entry.id).all()
    assert {l.account_id for l in lines} == {box.account_id}, 'no surplus, no shortage: within the safe'
    assert roles['surplus_w'].id not in {l.account_id for l in lines}


def test_an_approval_that_would_change_a_karat_is_refused(app, roles):
    """The karat nets to nothing by construction; the approval checks it still,
    so no path past the weighing writes a surplus under a classification."""
    from models import db
    box, bangles = _safe(), _category()
    _stock(box, 1000.0)
    session = _open(box)
    _weigh(session, box, bangles, 300.0)
    rest = _unclassified(session)
    rest.counted_weight, rest.variance = 1000.0, 0.0        # written past the service
    db.session.flush()
    S.close_session(session, now=NOW)
    with pytest.raises(ValueError) as refused:
        S.approve_session(session, approved_by='المدير', now=NOW)
    assert 'لا يُغيّر وزن العيار' in str(refused.value)


def test_its_entry_says_its_reason_in_arabic(app, roles):
    """«فروق جرد — الجلسة #7 — classification» on the 19 Nov copy: a reason's
    code is the machine's word; the entry the accountant reads says its label."""
    box, bangles = _safe(), _category()
    _stock(box, 500.0)
    session = _open(box)
    _weigh(session, box, bangles, 120.0)
    S.close_session(session, now=NOW)
    _, entry = S.approve_session(session, approved_by='المدير', now=NOW, adjustment_reason='classification')
    assert 'تصنيف المخزون' in entry.description and 'classification' not in entry.description


def test_a_periodic_counts_reason_is_its_label_too(app, roles):
    box, bangles = _safe(), _category()
    _stock(box, 100.0, bangles)
    session = S.open_session(branch_id=None, safe_box_id=box.id, opened_by='t', now=NOW)
    S.populate_lines(session)
    _weigh(session, box, bangles, 99.0)
    S.close_session(session, force=True, now=NOW)
    _, entry = S.approve_session(session, approved_by='المدير', now=NOW, adjustment_reason='LOSS',
                                 adjustment_note='قطعة مفقودة')
    assert entry.description.endswith('— فاقد — قطعة مفقودة'), entry.description
