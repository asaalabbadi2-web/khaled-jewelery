"""What every voucher path does today, measured (V0 -- the voucher lifecycle discovery).

Not a law: a record, like U0 for invoices. The owner left two decisions for
after this discovery (1 Oct 2026): whether a voucher's status and its entry's
posting must agree, and whether the accountant may cancel a voucher. Each path
runs on vouchers the real creation route made; what it changed is compared with
tests/v0_voucher_effects.json. A phase that changes a path changes its entry in
the same commit; a change nobody meant fails here. V1 (the owner's decision,
same day) changed three: rejecting an approved voucher is refused (auto:*/reject).

World 'auto' -- voucher_auto_post on, production's setting: a voucher is
approved when it is created. Paths: cancel, unapprove, reject, delete, edit,
and unapprove followed by approve (the round trip).
World 'pending' -- auto-post off: approve by each of the three routes,
reject, delete, edit, cancel.
And a voucher an invoice wrote (a scrap purchase paid in cash, posted at
creation): cancel and unapprove.

Regenerate the record (review the diff before committing it):
    V0_RECORD=1 python -m pytest tests/test_v0_voucher_characterization.py
Run:
    python -m pytest tests/test_v0_voucher_characterization.py -v
"""
import json
import os
from pathlib import Path

import pytest

from app import app as flask_app
from models import Voucher, db
from tests.books_snapshot import diff
from tests.retraction_world import _create as create_invoice, world  # noqa: F401 (fixture)
from tests.voucher_world import SHAPES, auto_post, create, snapshot, vworld  # noqa: F401 (fixture)

RECORD = Path(__file__).with_name('v0_voucher_effects.json')
RECORDING = os.getenv('V0_RECORD') == '1'
_results = {}


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _call(headers, path, vid, amount=700.0):
    c = flask_app.test_client()
    if path == 'cancel':
        return c.post(f'/api/vouchers/{vid}/cancel', headers=headers, json={'reason': 'V0'})
    if path == 'unapprove':
        return c.post(f'/api/vouchers/unapprove/{vid}', headers=headers, json={})
    if path == 'reject':
        return c.post(f'/api/vouchers/reject/{vid}', headers=headers, json={'rejection_reason': 'V0'})
    if path == 'delete':
        return c.delete(f'/api/vouchers/{vid}', headers=headers)
    if path == 'approve_vouchers_route':
        return c.post(f'/api/vouchers/{vid}/approve', headers=headers, json={})
    if path == 'approve_posting_screen':
        return c.post(f'/api/vouchers/approve/{vid}', headers=headers, json={})
    if path == 'approve_batch':
        return c.post('/api/vouchers/approve/batch', headers=headers, json={'voucher_ids': [vid]})
    raise ValueError(path)


def _edit(headers, w, shape, vid):
    from tests.voucher_world import payload
    return flask_app.test_client().put(f'/api/vouchers/{vid}', headers=headers, json=payload(w, shape, amount=700.0))


def _answer(resp):
    body = resp.get_json(silent=True) or {}
    err = body.get('error') if isinstance(body.get('error'), str) else None
    return f"{resp.status_code}:{err or ('ok' if resp.status_code < 400 else '?')}"


def _check(key, observed):
    _results[key] = observed
    if RECORDING:
        return
    expected = json.loads(RECORD.read_text(encoding='utf-8')).get(key)
    assert expected is not None, f'{key}: not in {RECORD.name} -- record it (V0_RECORD=1) and review'
    assert observed == expected, f'{key} changed:\n{json.dumps(diff(expected, observed), ensure_ascii=False, indent=1)}'


def _changes(before, after):
    return {k: list(v) for k, v in diff(before, after).items()}


@pytest.mark.parametrize('path', ('cancel', 'unapprove', 'reject', 'delete', 'edit', 'unapprove_then_approve'))
@pytest.mark.parametrize('shape', SHAPES)
def test_auto_posted(auth_headers, vworld, shape, path):
    auto_post(True)
    vid = create(auth_headers, vworld, shape)
    created = snapshot(vid)
    if path == 'edit':
        resp = _edit(auth_headers, vworld, shape, vid)
    elif path == 'unapprove_then_approve':
        resp = _call(auth_headers, 'unapprove', vid)
        resp2 = _call(auth_headers, 'approve_posting_screen', vid)
    else:
        resp = _call(auth_headers, path, vid)
    after = snapshot(vid)
    observed = {'created': created, 'answer': _answer(resp), 'changes': _changes(created, after)}
    if path == 'unapprove_then_approve':
        observed['approve_answer'] = _answer(resp2)
    _check(f'auto:{shape}/{path}', observed)


@pytest.mark.parametrize('path', ('approve_vouchers_route', 'approve_posting_screen', 'approve_batch',
                                  'reject', 'delete', 'edit', 'cancel'))
@pytest.mark.parametrize('shape', SHAPES)
def test_pending(auth_headers, vworld, shape, path):
    auto_post(False)
    vid = create(auth_headers, vworld, shape)
    created = snapshot(vid)
    resp = _edit(auth_headers, vworld, shape, vid) if path == 'edit' else _call(auth_headers, path, vid)
    _check(f'pending:{shape}/{path}', {'created': created, 'answer': _answer(resp),
                                       'changes': _changes(created, snapshot(vid))})


@pytest.mark.parametrize('path', ('cancel', 'unapprove'))
def test_an_invoices_payment_voucher(auth_headers, world, path):
    inv = create_invoice(auth_headers, world, 'scrap_purchase_paid', held=False)
    vid = Voucher.query.filter_by(reference_type='invoice', reference_id=inv['id']).first().id
    created = snapshot(vid)
    resp = _call(auth_headers, path, vid)
    db.session.expire_all()
    from models import Invoice
    inv_after = db.session.get(Invoice, inv['id'])
    _check(f'invoice_payment/{path}', {
        'created': created, 'answer': _answer(resp), 'changes': _changes(created, snapshot(vid)),
        'invoice_after': {'status': inv_after.status, 'amount_paid': float(inv_after.amount_paid or 0),
                          'is_posted': bool(inv_after.is_posted)},
    })


def teardown_module(module):
    if RECORDING and _results:
        existing = json.loads(RECORD.read_text(encoding='utf-8')) if RECORD.exists() else {}
        existing.update(_results)
        RECORD.write_text(json.dumps(dict(sorted(existing.items())), ensure_ascii=False, indent=1) + '\n',
                          encoding='utf-8')
