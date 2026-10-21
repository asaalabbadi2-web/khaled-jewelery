"""A melting's stones leave the showroom as gold, written off as a weight expense (ت5).

The owner (21 Oct 2026): «تُعدم مصروفًا». The mirror of ت5أ: a renewal's stones
entered the showroom as gold against a weight revenue; the showroom's stones
counted as gold came in at the standing weight too (ADR-055). When a piece is
melted, the scrap receives its net gold alone -- it is sold and closed by it --
so the stones' weight leaves the showroom as gold: credit the showroom at the
line's karat, debit the role «فصوص التكسير» (a weight expense, mapped in
«الربط المحاسبي»). Unmapped, a melting with stones is refused saying where.

The showroom holds them as gold: a line's gold and stones together are
weighed on its gold, and leave its category; its rows say weight, not stones.

Run:
    python -m pytest tests/test_melting_stones_are_an_expense.py -v
"""
import pytest

from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from models import (AccountingMapping, JournalEntryLine, SafeBoxTransaction, StockLineAllocation, Voucher,
                    VoucherAccountLine, db)
from tests.test_melting_and_renewal_classify import _category, _post
from tests.test_melting_and_renewal_go_one_way import _account, _holds, _safe

ROLE = 'melting_stones_expense'


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _map_role():
    expense = _account('75', 'فصوص التكسير وزني', type='Expense', tracks_weight=True)
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=ROLE,
                                     account_id=expense.id, is_active=True))
    db.session.flush()
    return expense


def _melting(src, dst, category, gold, stones):
    return {'operation_type': 'melting', 'from_safe_box_id': src.id, 'to_safe_box_id': dst.id,
            'lines': [{'karat': 18, 'gold_weight': gold, 'stones_weight': stones, 'category_id': category.id}]}


def test_the_stones_leave_the_showroom_as_gold_against_the_weight_expense(auth_headers):
    expense = _map_role()
    sets, scrap18 = _category('طقم', 18), _category('كسر', 18, scrap=True)
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 18, 40.0)                       # the showroom holds its stones as gold
    resp = _post(auth_headers, _melting(src, dst, sets, 27.3, 6.7))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    vid = resp.get_json()['voucher']['id']

    lines = VoucherAccountLine.query.filter_by(voucher_id=vid).all()
    assert sorted((l.line_type, l.account_id, l.amount_type, l.amount, l.karat) for l in lines) == sorted([
        ('credit', src.account_id, 'gold', 27.3, 18.0),
        ('debit', dst.account_id, 'gold', 27.3, 18.0),
        ('credit', src.account_id, 'gold', 6.7, 18.0),
        ('debit', expense.id, 'gold', 6.7, 18.0),
    ])

    entry_id = db.session.get(Voucher, vid).journal_entry_id

    def allocated(account_id):
        on = JournalEntryLine.query.filter_by(journal_entry_id=entry_id, account_id=account_id).all()
        return StockLineAllocation.query.filter(StockLineAllocation.journal_entry_line_id.in_([l.id for l in on])).all()
    assert {a.category_id for a in allocated(src.account_id)} == {sets.id}
    assert sum(a.grams for a in allocated(src.account_id)) == pytest.approx(-34.0)
    assert sum(a.grams for a in allocated(dst.account_id)) == pytest.approx(27.3)
    assert {a.category_id for a in allocated(dst.account_id)} == {scrap18.id}

    (out,) = SafeBoxTransaction.query.filter_by(safe_box_id=src.id, ref_type='voucher', ref_id=vid).all()
    assert (out.weight_18k, out.stones_weight) == (pytest.approx(34.0), pytest.approx(0.0))
    (into,) = SafeBoxTransaction.query.filter_by(safe_box_id=dst.id, ref_type='voucher', ref_id=vid).all()
    assert (into.weight_18k, into.stones_weight) == (pytest.approx(27.3), pytest.approx(0.0))


def test_the_gold_and_its_stones_are_weighed_together_on_the_showroom(auth_headers):
    _map_role()
    sets = _category('طقم', 18)
    _category('كسر', 18, scrap=True)
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 18, 30.0)
    resp = _post(auth_headers, _melting(src, dst, sets, 27.3, 6.7))   # 34 > 30
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'insufficient_balance'


def test_a_melting_with_stones_and_the_role_unmapped_is_refused_saying_where(auth_headers):
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    sets = _category('طقم', 18)
    _category('كسر', 18, scrap=True)
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 18, 40.0)
    resp = _post(auth_headers, _melting(src, dst, sets, 27.3, 6.7))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'account_not_mapped'
    assert 'الربط المحاسبي' in resp.get_json()['message']
    assert SafeBoxTransaction.query.filter_by(safe_box_id=src.id, ref_type='voucher').count() == 0


def test_a_melting_without_stones_needs_no_role(auth_headers):
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    sets = _category('طقم', 18)
    _category('كسر', 18, scrap=True)
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 18, 40.0)
    resp = _post(auth_headers, _melting(src, dst, sets, 27.3, 0.0))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
