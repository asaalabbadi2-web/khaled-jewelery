"""The payment-method screen sets the schedule; the server reads and previews it (ADR-037).

The owner (6 Oct 2026): «افضل ان يتم تطوير اعدادات وسيلة الدفع ليتوافق مع كل
ما سبق ويكون مرن في اي تعديل لاحق» -- the batch, the deposit, the bank's
weekend, the public holidays and the plan (fixed or flexible) are settings.
The laws here: a schedule the one reading cannot read is refused when saved;
the preview is the server's (the screen computes no date); the holiday
calendar is kept by the owner and moves a deposit only for a method that skips
holidays.

Run:
    python -m pytest tests/test_settlement_schedule_settings.py -v
"""
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import PaymentMethod, PublicHoliday, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence, monkeypatch):
    monkeypatch.setattr(db.session, 'commit', db.session.flush)
    yield


def _client():
    g.pop('current_user', None)
    return flask_app.test_client()


@pytest.fixture
def method():
    pm = PaymentMethod(payment_type='tabby', name=f'تابي {uuid.uuid4().hex[:6]}', commission_rate=0.0,
                       is_active=True, auto_settlement_enabled=False)
    db.session.add(pm)
    db.session.flush()
    return pm


TABBY = {'settlement_schedule_type': 'weekday', 'settlement_weekday': 6,
         'deposit_schedule_type': 'weekday', 'deposit_weekday': 0}


def test_the_schedule_is_saved_with_its_weekend_and_holidays(auth_headers, method):
    resp = _client().put(f'/api/payment-methods/{method.id}', headers=auth_headers,
                         json={**TABBY, 'bank_weekend_days': [5, 4], 'skip_public_holidays': True})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()['payment_method']
    assert (body['bank_weekend_days'], body['skip_public_holidays']) == ('4,5', True)
    assert body['schedule_summary'].startswith('دفعة أسبوعية تُقفل نهاية الأحد · تُودَع الاثنين التالي')


def test_an_unreadable_schedule_is_refused_for_a_method_that_settles_itself(auth_headers, method):
    from models import Account, SafeBox
    boxes = []
    for kind in ('clearing', 'bank'):
        acc = Account(account_number=f'86{uuid.uuid4().int % 10**6:06d}', name=f'{kind} {uuid.uuid4().hex[:4]}',
                      type='Asset')
        db.session.add(acc)
        db.session.flush()
        box = SafeBox(name=f'{kind} {uuid.uuid4().hex[:6]}', safe_type=kind, account_id=acc.id, is_active=True)
        db.session.add(box)
        db.session.flush()
        boxes.append(box)
    method.default_safe_box_id, method.settlement_bank_safe_box_id = boxes[0].id, boxes[1].id
    method.auto_settlement_enabled = True
    db.session.flush()
    resp = _client().put(f'/api/payment-methods/{method.id}', headers=auth_headers,
                         json={'deposit_schedule_type': 'weekday', 'deposit_weekday': 4,
                               'bank_weekend_days': [4, 5]})       # deposits on a day the bank is closed
    assert resp.status_code == 400 and resp.get_json()['error'] == 'schedule_invalid'
    assert 'عطلة' in resp.get_json()['message']   # the route rolls the change back before refusing


def test_a_weekend_out_of_range_is_refused(auth_headers, method):
    resp = _client().put(f'/api/payment-methods/{method.id}', headers=auth_headers,
                         json={'bank_weekend_days': '9'})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'schedule_invalid'


def test_the_preview_is_the_servers(auth_headers):
    resp = _client().post('/api/payment-methods/schedule-preview', headers=auth_headers,
                          json={**TABBY, 'from': '2026-10-05', 'days': 7})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert {r['deposit_day'] for r in body['rows']} == {'2026-10-12'}
    assert body['rows'][0]['deposit_weekday'] == 'الاثنين'


def test_a_holiday_moves_the_deposit_only_where_holidays_are_skipped(auth_headers):
    resp = _client().post('/api/public-holidays', headers=auth_headers,
                          json={'date': '2026-10-12', 'name': 'إجازة تجربة'})
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    assert _client().post('/api/public-holidays', headers=auth_headers,
                          json={'date': '2026-10-12', 'name': 'مكرر'}).status_code == 409

    def deposit(skip):
        r = _client().post('/api/payment-methods/schedule-preview', headers=auth_headers,
                           json={**TABBY, 'skip_public_holidays': skip, 'from': '2026-10-11', 'days': 1})
        return r.get_json()['rows'][0]['deposit_day']
    assert deposit(False) == '2026-10-12'
    assert deposit(True) == '2026-10-13'

    holiday_id = resp.get_json()['holiday']['id']
    listed = _client().get('/api/public-holidays', headers=auth_headers).get_json()['holidays']
    assert any(h['id'] == holiday_id for h in listed)
    assert _client().delete(f'/api/public-holidays/{holiday_id}', headers=auth_headers).status_code == 200
    assert db.session.get(PublicHoliday, holiday_id) is None
