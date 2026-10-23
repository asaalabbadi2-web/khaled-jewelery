"""A renewal's stones enter the showroom as gold, against a weight revenue (ت5أ).

The owner (21 Oct 2026): «فصوص التجديد تدخل مدين المعروض ودائن إيرادات
وزنية». A customer's scrap is bought by its net gold -- its stones come free --
and a renewed piece is sold by its standing weight as gold: its stones left the
showroom's gold at the sale, never having entered it (9.56 g in three renewals
on the 17 Oct copy). Now they enter at the renewal: debit the showroom by their
weight at the line's karat, credit the role «إيراد فصوص التجديد» -- a weight
revenue, mapped in «الربط المحاسبي». The gain is the day's, in gram profit.

The stones leave the scrap or custody as stones (their rows' weight); in the
showroom they are gold, with their line, in the line's category. Unmapped, a
renewal with stones is refused saying where the role is set. A melting's
stones are its mirror (ت5, test_melting_stones_are_an_expense).

Run:
    python -m pytest tests/test_renewal_stones_are_gold.py -v
"""
import pytest

from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from models import (AccountingMapping, JournalEntryLine, SafeBoxTransaction, StockLineAllocation, Voucher,
                    VoucherAccountLine, db)
from tests.test_melting_and_renewal_classify import _category, _post
from tests.test_melting_and_renewal_go_one_way import _account, _holds, _safe

ROLE = 'renewal_stones_revenue'


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _map_role():
    revenue = _account('74', 'إيراد فصوص التجديد وزني', type='Revenue', tracks_weight=True)
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=ROLE,
                                     account_id=revenue.id, is_active=True))
    db.session.flush()
    return revenue


def _renewal(src, dst, category, stones):
    return {'operation_type': 'renewal', 'from_safe_box_id': src.id, 'to_safe_box_id': dst.id,
            'lines': [{'karat': 18, 'gold_weight': 27.3, 'stones_weight': stones, 'category_id': category.id}]}


def test_the_stones_enter_the_showroom_as_gold_against_the_weight_revenue(auth_headers):
    revenue = _map_role()
    sets, scrap18 = _category('طقم', 18), _category('كسر', 18, scrap=True)
    src, dst = _safe('scrap'), _safe('showroom')
    _holds(src, 18, 30.0, stones=6.7)
    resp = _post(auth_headers, _renewal(src, dst, sets, 6.7))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    vid = resp.get_json()['voucher']['id']

    lines = VoucherAccountLine.query.filter_by(voucher_id=vid).all()
    assert sorted((l.line_type, l.account_id, l.amount_type, l.amount, l.karat) for l in lines) == sorted([
        ('credit', src.account_id, 'gold', 27.3, 18.0),
        ('debit', dst.account_id, 'gold', 27.3, 18.0),
        ('debit', dst.account_id, 'gold', 6.7, 18.0),
        ('credit', revenue.id, 'gold', 6.7, 18.0),
    ])

    # In the showroom the stones are gold, with their line, in its category.
    entry_id = db.session.get(Voucher, vid).journal_entry_id
    shown = JournalEntryLine.query.filter_by(journal_entry_id=entry_id, account_id=dst.account_id).all()
    allocated = StockLineAllocation.query.filter(
        StockLineAllocation.journal_entry_line_id.in_([l.id for l in shown])).all()
    assert {a.category_id for a in allocated} == {sets.id}
    assert sum(a.grams for a in allocated) == pytest.approx(34.0)

    # They leave the scrap as stones, and are gold -- no stones -- in the showroom.
    (out,) = SafeBoxTransaction.query.filter_by(safe_box_id=src.id, ref_type='voucher', ref_id=vid).all()
    assert (out.weight_18k, out.stones_weight) == (pytest.approx(27.3), pytest.approx(6.7))
    (into,) = SafeBoxTransaction.query.filter_by(safe_box_id=dst.id, ref_type='voucher', ref_id=vid).all()
    assert (into.weight_18k, into.stones_weight) == (pytest.approx(34.0), pytest.approx(0.0))


def test_a_renewal_with_stones_and_the_role_unmapped_is_refused_saying_where(auth_headers):
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    sets = _category('طقم', 18)
    _category('كسر', 18, scrap=True)
    src, dst = _safe('scrap'), _safe('showroom')
    _holds(src, 18, 30.0, stones=6.7)
    resp = _post(auth_headers, _renewal(src, dst, sets, 6.7))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'account_not_mapped'
    assert 'الربط المحاسبي' in resp.get_json()['message']
    assert SafeBoxTransaction.query.filter_by(safe_box_id=src.id, ref_type='voucher').count() == 0


def test_a_renewal_without_stones_needs_no_role(auth_headers):
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    sets = _category('طقم', 18)
    _category('كسر', 18, scrap=True)
    src, dst = _safe('scrap'), _safe('showroom')
    _holds(src, 18, 30.0)
    resp = _post(auth_headers, _renewal(src, dst, sets, 0.0))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


def test_what_is_not_gold_is_one_field_and_the_source_gives_the_stones_it_has(auth_headers):
    """The owner (23 Oct 2026): «خانة واحدة لكل ما هو غير ذهب سواء بالتجديد أو
    التكسير» -- stones, iron, a clasp. A renewal's non-gold beyond the stones
    its source holds is a part added, not a refusal; the source's stones go
    down by what it has, never below nothing."""
    revenue = _map_role()
    sets = _category('طقم', 18)
    _category('كسر', 18, scrap=True)
    src, dst = _safe('custody'), _safe('showroom')
    _holds(src, 18, 30.0, stones=2.0)
    resp = _post(auth_headers, _renewal(src, dst, sets, 6.7))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    vid = resp.get_json()['voucher']['id']

    entered = VoucherAccountLine.query.filter_by(voucher_id=vid, account_id=revenue.id).one()
    assert (entered.line_type, entered.amount) == ('credit', pytest.approx(6.7))
    (out,) = SafeBoxTransaction.query.filter_by(safe_box_id=src.id, ref_type='voucher', ref_id=vid).all()
    assert (out.weight_18k, out.stones_weight) == (pytest.approx(27.3), pytest.approx(2.0))
    (into,) = SafeBoxTransaction.query.filter_by(safe_box_id=dst.id, ref_type='voucher', ref_id=vid).all()
    assert into.weight_18k == pytest.approx(34.0)
