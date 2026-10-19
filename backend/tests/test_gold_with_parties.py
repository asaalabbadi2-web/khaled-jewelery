"""Gold with parties is shown apart from the shop's gold, and read as ours or theirs (ADR-051).

The owner (17 Oct 2026): «حسابنا بشركة الجنيه العربي» and the offices' gold
safes are the gold we hold with them -- usually ours (a debit), sometimes owed
to them (a credit) -- kept among the safes so a voucher can pay a supplier
with it. They are not the shop's gold: a gold safe with no stock location
(ADR-045: an office's or a supplier's) is grouped «party_gold» on the safes
overview, its total apart, and each says whose the gold is.

Run:
    python -m pytest tests/test_gold_with_parties.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, SafeBox, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _gold_safe(location, grams):
    acc = Account(account_number=f'72{uuid.uuid4().int % 10**7:07d}', name='حساب وزني', type='Liability',
                  transaction_type='gold', tracks_weight=True)
    db.session.add(acc)
    db.session.flush()
    safe = SafeBox(name=f'خزينة {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=acc.id, is_active=True,
                   stock_location=location)
    db.session.add(safe)
    db.session.flush()
    if grams:
        je = JournalEntry(entry_number=f'JE-PG-{uuid.uuid4().hex[:8]}', date=dt.datetime(2026, 10, 1),
                          description='ذهب', entry_type='عادي', is_posted=True, created_by='t')
        db.session.add(je)
        db.session.flush()
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=acc.id, description='ذهب',
                                        **({'debit_21k': grams} if grams > 0 else {'credit_21k': -grams})))
        db.session.flush()
    return safe


def _overview(headers):
    g.pop('current_user', None)
    resp = flask_app.test_client().get('/api/safe-boxes/balances', headers=headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return resp.get_json()


def test_a_party_s_gold_is_its_own_group_and_says_whose(auth_headers):
    ours_there = _gold_safe(None, 50.0)          # they hold 50 g of ours
    owed = _gold_safe(None, -20.0)               # we owe them 20 g
    showroom = _gold_safe('showroom', 30.0)

    body = _overview(auth_headers)
    rows = {r['id']: r for r in body['rows']}
    assert (rows[ours_there.id]['group'], rows[ours_there.id]['party_side']) == ('party_gold', 'ours')
    assert (rows[owed.id]['group'], rows[owed.id]['party_side']) == ('party_gold', 'theirs')
    assert rows[showroom.id]['group'] == 'gold_shop' and 'party_side' not in rows[showroom.id]


def test_the_shop_s_gold_total_leaves_the_parties_out(auth_headers):
    before = _overview(auth_headers)['totals']
    _gold_safe(None, 40.0)
    _gold_safe('showroom', 10.0)

    after = _overview(auth_headers)['totals']
    gold_before = before.get('gold_shop', {'weight_main_karat': 0.0})
    assert after['gold_shop']['weight_main_karat'] == pytest.approx(gold_before['weight_main_karat'] + 10.0)
    party_before = before.get('party_gold', {'weight_main_karat': 0.0, 'count': 0})
    assert after['party_gold']['weight_main_karat'] == pytest.approx(party_before['weight_main_karat'] + 40.0)
    assert after['party_gold']['count'] == party_before['count'] + 1
