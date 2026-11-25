"""Every change of a setting is recorded with it, and a save over another's change is refused (ADR-102).

The owner, 25 Nov 2026 («ابدأ», after the second spec): the settings screen
sent every setting on every save and the server wrote what came -- a user who
opened the screen before another put the other's values back, the sales VAT
switch among them (it writes a policy period) -- and nothing said who changed
what. Now:
  - every change of the Settings row -- through any writer -- is written to
    settings_change in the same flush: key, old and new value (a logo by its
    hash), actor, request, source, reason. A value set to what it was writes
    nothing;
  - the log is append-only in the database itself;
  - PATCH /settings takes the keys changed and the version the user saw of
    each -- the id of its last change -- and refuses the whole save (409, no
    write) when any key moved since, even back to the value it had;
  - a level-3 key (money, VAT, posting, the main karat) is not changed through
    PATCH without its reason.

Run:
    python -m pytest tests/test_settings_change_audit.py -v
"""
import hashlib
import json

import pytest
from flask import g
from sqlalchemy import text

from app import app as flask_app
from models import Settings, SettingsChange, db


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence, vat_mapped):
    yield


@pytest.fixture
def row():
    s = Settings.query.order_by(Settings.id).first()
    if s is None:
        s = Settings(main_karat=21)
        db.session.add(s)
        db.session.flush()
    return s


def _client_call(method, path, headers, body=None):
    g.pop('current_user', None)
    return getattr(flask_app.test_client(), method)(path, headers=headers, json=body)


def _changes(key):
    db.session.expire_all()
    return SettingsChange.query.filter_by(key=key).order_by(SettingsChange.id).all()


def test_a_saved_change_is_recorded_with_its_values_and_actor(auth_headers, row):
    before = row.invoice_prefix
    new = f'{before or "INV"}-X'
    resp = _client_call('put', '/api/settings', auth_headers, {'invoice_prefix': new})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    [change] = _changes('invoice_prefix')
    assert (json.loads(change.old_value), json.loads(change.new_value)) == (before, new)
    assert change.actor == 'admin' and change.actor_type == 'user'
    assert change.request_id


def test_a_value_sent_unchanged_records_nothing(auth_headers, row):
    """The old screen sends every key: only the ones that changed are recorded."""
    resp = _client_call('put', '/api/settings', auth_headers,
                        {'invoice_prefix': row.invoice_prefix, 'decimal_places': row.decimal_places})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    assert _changes('invoice_prefix') == [] and _changes('decimal_places') == []


def test_every_writer_is_recorded_the_vat_policy_too(row):
    """sales_vat_enabled follows today's VAT period (services/vat_policy.py) -- not the settings route."""
    from datetime import date
    from services.vat_policy import add_period, policy_on
    today = date.today()
    current = policy_on(today)
    add_period(effective_from=today, input_vat_recoverable=current.input_vat_recoverable,
               sales_vat_charged=not current.sales_vat_charged, by='pytest', today=today)
    db.session.flush()
    [change] = _changes('sales_vat_enabled')
    assert json.loads(change.new_value) is (not current.sales_vat_charged)


def test_a_logo_is_recorded_by_its_hash(row):
    row.company_logo_base64 = 'iVBORw0KGgo-a-logo'
    db.session.flush()
    [change] = _changes('company_logo_base64')
    assert json.loads(change.new_value) == 'sha256:' + hashlib.sha256(b'iVBORw0KGgo-a-logo').hexdigest()


def test_the_log_is_append_only_in_the_database(row):
    row.invoice_prefix = (row.invoice_prefix or 'INV') + '-Y'
    db.session.flush()
    [change] = _changes('invoice_prefix')
    with pytest.raises(Exception) as update:
        with db.session.begin_nested():
            db.session.execute(text('UPDATE settings_change SET new_value = :v WHERE id = :id'),
                               {'v': '"forged"', 'id': change.id})
    assert 'settings_change' in str(update.value)
    with pytest.raises(Exception) as delete:
        with db.session.begin_nested():
            db.session.execute(text('DELETE FROM settings_change WHERE id = :id'), {'id': change.id})
    assert 'settings_change' in str(delete.value)


def _versions(headers, *keys):
    resp = _client_call('get', '/api/settings/versions', headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    versions = resp.get_json()['versions']
    return {k: versions.get(k, 0) for k in keys}


def test_patch_writes_what_changed_at_the_version_seen(auth_headers, row):
    seen = _versions(auth_headers, 'invoice_prefix')
    resp = _client_call('patch', '/api/settings', auth_headers,
                        {'changes': {'invoice_prefix': 'PT-1'}, 'versions': seen})
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['settings']['invoice_prefix'] == 'PT-1'
    assert body['versions']['invoice_prefix'] == _changes('invoice_prefix')[-1].id


def test_a_key_moved_since_it_was_seen_refuses_the_whole_save(auth_headers, row):
    seen = _versions(auth_headers, 'invoice_prefix', 'company_phone')
    # Another user changes the prefix meanwhile.
    assert _client_call('patch', '/api/settings', auth_headers,
                        {'changes': {'invoice_prefix': 'OTHER'}, 'versions': seen}).status_code == 200
    phone_before = Settings.query.get(row.id).company_phone
    resp = _client_call('patch', '/api/settings', auth_headers,
                        {'changes': {'invoice_prefix': 'MINE', 'company_phone': '0500000000'}, 'versions': seen})
    assert resp.status_code == 409, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'settings_conflict'
    [conflict] = body['conflicts']
    assert (conflict['key'], conflict['current'], conflict['yours']) == ('invoice_prefix', 'OTHER', 'MINE')
    assert conflict['changed_by'] == 'admin'
    db.session.expire_all()
    assert Settings.query.get(row.id).invoice_prefix == 'OTHER'
    assert Settings.query.get(row.id).company_phone == phone_before, 'nothing of a refused save is written'


def test_a_value_changed_and_changed_back_is_still_a_conflict(auth_headers, row):
    """A-B-A: the value is as seen, but someone worked on it -- the version says so."""
    original = row.invoice_prefix
    seen = _versions(auth_headers, 'invoice_prefix')
    v = dict(seen)
    for value in ('TEMP', original):
        resp = _client_call('patch', '/api/settings', auth_headers, {'changes': {'invoice_prefix': value}, 'versions': v})
        assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
        v = {'invoice_prefix': resp.get_json()['versions']['invoice_prefix']}
    resp = _client_call('patch', '/api/settings', auth_headers,
                        {'changes': {'invoice_prefix': 'MINE'}, 'versions': seen})
    assert resp.status_code == 409


def test_two_users_on_two_keys_both_save(auth_headers, row):
    seen = _versions(auth_headers, 'invoice_prefix', 'company_phone')
    a = _client_call('patch', '/api/settings', auth_headers,
                     {'changes': {'invoice_prefix': 'A-1'}, 'versions': {'invoice_prefix': seen['invoice_prefix']}})
    b = _client_call('patch', '/api/settings', auth_headers,
                     {'changes': {'company_phone': '0511111111'}, 'versions': {'company_phone': seen['company_phone']}})
    assert (a.status_code, b.status_code) == (200, 200)
    db.session.expire_all()
    s = Settings.query.get(row.id)
    assert (s.invoice_prefix, s.company_phone) == ('A-1', '0511111111')


def test_patch_asks_the_version_of_every_key(auth_headers, row):
    resp = _client_call('patch', '/api/settings', auth_headers, {'changes': {'invoice_prefix': 'NOV'}})
    assert resp.status_code == 400 and resp.get_json()['error'] == 'versions_required'


def test_a_level_3_key_is_not_changed_without_its_reason(auth_headers, row):
    seen = _versions(auth_headers, 'buy_price_ratio')
    new = 0.97 if abs(float(row.buy_price_ratio or 0) - 0.97) > 1e-9 else 0.96
    refused = _client_call('patch', '/api/settings', auth_headers,
                           {'changes': {'buy_price_ratio': new}, 'versions': seen})
    assert refused.status_code == 200, 'buy_price_ratio is level 2: no reason asked'
    seen = _versions(auth_headers, 'office_custom_fees_usd')
    refused = _client_call('patch', '/api/settings', auth_headers,
                           {'changes': {'office_custom_fees_usd': 44}, 'versions': seen})
    assert refused.status_code == 400 and refused.get_json()['error'] == 'reason_required'
    assert refused.get_json()['keys'] == ['office_custom_fees_usd']
    ok = _client_call('patch', '/api/settings', auth_headers,
                      {'changes': {'office_custom_fees_usd': 44}, 'versions': seen, 'reason': 'رسوم المكتب الجديدة'})
    assert ok.status_code == 200, ok.get_data(as_text=True)[:300]
    assert _changes('office_custom_fees_usd')[-1].reason == 'رسوم المكتب الجديدة'


def test_a_refused_value_writes_no_change(auth_headers, row):
    """The setting's own law refuses it (an unknown main karat): nothing is recorded."""
    seen = _versions(auth_headers, 'main_karat')
    resp = _client_call('patch', '/api/settings', auth_headers,
                        {'changes': {'main_karat': 19}, 'versions': seen, 'reason': 'تجربة'})
    assert resp.status_code == 400
    assert _changes('main_karat') == []


def test_no_code_writes_the_settings_table_by_raw_sql():
    """The recorder sits on the ORM: a raw UPDATE of settings would change a key unseen."""
    import pathlib
    import re
    backend = pathlib.Path(__file__).resolve().parents[1]
    hits = []
    for path in backend.rglob('*.py'):
        rel = path.relative_to(backend).as_posix()
        if rel.startswith(('venv/', 'alembic/', 'tests/')) or '/test_' in rel or rel.startswith('test_'):
            continue
        if re.search(r'UPDATE\s+settings\b(?!_)', path.read_text(errors='ignore'), re.I):
            hits.append(rel)
    assert not hits, f'raw SQL writes the settings row outside the recorder: {hits}'


@pytest.mark.xfail(strict=True, reason='SETTINGS-REASON-001: the old PUT takes a level-3 change without its reason '
                                       'until the settings center replaces the screen that sends it')
def test_the_old_put_asks_a_level_3_reason_too(auth_headers, row):
    resp = _client_call('put', '/api/settings', auth_headers, {'office_custom_fees_usd': 46})
    assert resp.status_code == 400
