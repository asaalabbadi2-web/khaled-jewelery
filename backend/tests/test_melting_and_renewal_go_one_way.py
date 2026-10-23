"""Melting and renewal go one way, keep their karat, and post no stones as gold (ت1).

The owner (21 Oct 2026, docs/plans/melting-renewal-stones-roadmap.md): measured
on the 17 Oct copy -- melting took the showroom's jewellery to the scrap (11,
1,185 g), renewal brought scrap and custody gold to the showroom (29, 327 g).
But the server took any two safes, either way, chosen on the screen by a name
containing «كسر»; it took an output karat other than the input and moved the
same grams (10 g of 18k in as 10 g of 21k: gold from nothing); and a renewal's
stones were written as gold of the line's karat on «stones asset» and «stones
revenue» -- had the revenue been mapped, stones were grams of gold profit.

The law:
  - melting: from a showroom to a scrap safe; renewal: from a scrap safe or a
    custody to a showroom -- by the safe's stock location, not its name;
  - the karat stays; a karat is corrected by the safes' own correction;
  - a renewal's stones are no gold line: they stay on the safe rows, by weight.

Run:
    python -m pytest tests/test_melting_and_renewal_go_one_way.py -v
"""
import uuid
from datetime import datetime

import pytest
from flask import g

from app import app as flask_app
from models import (Account, JournalEntry, JournalEntryLine, SafeBox, SafeBoxTransaction, Settings, Voucher,
                    VoucherAccountLine, db)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _account(prefix, name, **kw):
    acc = Account(account_number=f'{prefix}{uuid.uuid4().int % 10**7:07d}', name=name, **kw)
    db.session.add(acc)
    db.session.flush()
    return acc


def _safe(location, name=None):
    acc = _account('7', name or location, type='Asset', tracks_weight=True)
    box = SafeBox(name=f'{name or location} {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=acc.id,
                  is_active=True, stock_location=location)
    db.session.add(box)
    db.session.flush()
    return box


def _holds(box, karat, grams, stones=0.0):
    other = _account('8', 'مقابل', type='Asset', tracks_weight=True)
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=datetime(2026, 9, 1), description='t',
                      is_posted=True)
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=box.account_id, **{f'debit_{karat}k': grams}),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, **{f'credit_{karat}k': grams}),
    ])
    if stones:
        db.session.add(SafeBoxTransaction(safe_box_id=box.id, direction='in', ref_type='journal_entry',
                                          ref_id=je.id, stones_weight=stones, amount_cash=0.0,
                                          **{f'stones_{karat}k': stones}))
    db.session.flush()


def with_categories(body):
    """Each line a category of its karat, and each karat its scrap category --
    as the shop's chart has them (ت3): for the tests of the other laws."""
    from models import Category

    def of(karat, scrap):
        found = Category.query.filter_by(karat=str(karat), is_scrap=scrap).filter(Category.is_active.isnot(False)).first()
        if found is None:
            found = Category(name=f'{"كسر" if scrap else "تصنيف"} {karat} {uuid.uuid4().hex[:5]}', karat=str(karat),
                             is_scrap=scrap, is_active=True)
            db.session.add(found)
            db.session.flush()
        return found
    lines = body.get('lines')
    if lines is not None and not isinstance(lines, list):
        return body                      # a malformed body, sent as it is
    if lines is None and body.get('from_karat') and 'category_id' not in body:
        of(body['from_karat'], True)
        return {**body, 'category_id': of(body['from_karat'], False).id}
    out = []
    for line in lines or []:
        try:
            karat = int(line.get('karat'))
        except (AttributeError, TypeError, ValueError):
            out.append(line)
            continue
        of(karat, True)
        out.append(line if 'category_id' in line else {**line, 'category_id': of(karat, False).id})
    return {**body, 'lines': out} if lines is not None else body


def _post(headers, body):
    g.pop('current_user', None)
    return flask_app.test_client().post('/api/melting-renewal', headers=headers, json=with_categories(body))


def _op(kind, source, target, **line):
    return {'operation_type': kind, 'from_safe_box_id': source.id, 'to_safe_box_id': target.id,
            'lines': [{'karat': 21, 'gold_weight': 2.0, **line}]}


@pytest.mark.parametrize('kind, source, target', [
    ('melting', 'showroom', 'scrap'),
    ('renewal', 'scrap', 'showroom'),
    ('renewal', 'custody', 'showroom'),
])
def test_each_goes_its_own_way(auth_headers, kind, source, target):
    src, dst = _safe(source), _safe(target)
    _holds(src, 21, 10.0)
    resp = _post(auth_headers, _op(kind, src, dst))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]


@pytest.mark.parametrize('kind, source, target', [
    ('melting', 'scrap', 'showroom'),       # melting the wrong way round
    ('melting', 'showroom', 'showroom'),    # «كسر» in a showroom's name made it the target
    ('melting', 'custody', 'scrap'),
    ('renewal', 'showroom', 'scrap'),
    ('renewal', 'scrap', 'scrap'),
])
def test_the_other_way_is_refused_by_name_and_posts_nothing(auth_headers, kind, source, target):
    src, dst = _safe(source, 'خزينة كسر'), _safe(target, 'خزينة كسر')
    _holds(src, 21, 10.0)
    resp = _post(auth_headers, _op(kind, src, dst))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'operation_direction_refused'
    assert resp.get_json()['message']
    assert SafeBoxTransaction.query.filter_by(safe_box_id=src.id, ref_type='voucher').count() == 0


def test_the_karat_does_not_change(auth_headers):
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 18, 10.0)
    resp = _post(auth_headers, {'operation_type': 'melting', 'from_safe_box_id': src.id,
                                'to_safe_box_id': dst.id,
                                'lines': [{'karat': 18, 'to_karat': 21, 'gold_weight': 10.0}]})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'karat_change_refused'
    assert SafeBoxTransaction.query.filter_by(safe_box_id=dst.id, ref_type='voucher').count() == 0


def test_a_renewals_stones_never_reach_the_old_stones_accounts(auth_headers):
    """ت1 took their gold lines off «stones asset» / «stones revenue»; ت5أ (the
    owner) puts them on the showroom against the renewal stones revenue role --
    the two old settings, set, still receive nothing."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
    from models import AccountingMapping
    src, dst = _safe('scrap'), _safe('showroom')
    _holds(src, 18, 30.0, stones=6.7)
    settings = Settings.query.first()
    old_asset = _account('1', 'أصول فصوص', type='Asset')
    old_revenue = _account('4', 'إيراد فصوص', type='Revenue', tracks_weight=True)
    settings.stones_pending_account_id, settings.stones_display_revenue_account_id = old_asset.id, old_revenue.id
    role = _account('74', 'إيراد فصوص التجديد وزني', type='Revenue', tracks_weight=True)
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type='renewal_stones_revenue',
                                     account_id=role.id, is_active=True))
    db.session.flush()
    resp = _post(auth_headers, {'operation_type': 'renewal', 'from_safe_box_id': src.id, 'to_safe_box_id': dst.id,
                                'lines': [{'karat': 18, 'gold_weight': 27.3, 'stones_weight': 6.7}]})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    voucher = Voucher.query.get(resp.get_json()['voucher']['id'])
    lines = VoucherAccountLine.query.filter_by(voucher_id=voucher.id).all()
    assert {l.account_id for l in lines} == {src.account_id, dst.account_id, role.id}
    assert 'warning' not in resp.get_json()
