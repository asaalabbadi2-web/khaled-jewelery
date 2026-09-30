"""What every invoice retraction path does today, measured (UNPOST-001, U0).

Not a law: a record. Each path runs on invoices the real creation path made,
and what it changed in the books is compared with tests/u0_retraction_effects.json.
The file is the map U1-U4 change on purpose: a phase that changes a path's
behaviour changes its entry in the same commit, where review sees it. A change
nobody meant shows up here as a failure.

Paths, on invoices POSTED at creation (below the live price):
    unpost via the posting screen      POST /api/invoices/unpost/<id>
    unpost via the invoices route      POST /api/invoices/<id>/unpost
    unpost via the batch               POST /api/invoices/unpost-batch
  each followed by a re-post (POST /api/invoices/post/<id>) -- the round trip.
Paths, on invoices HELD for approval (a purchase above the live price, a sale with a large discount):
    reject    POST   /api/invoices/<id>/reject
    delete    DELETE /api/invoices/<id>
    edit      PUT    /api/invoices/<id>

Shapes: a scrap purchase paid in cash (3170's), the same unpaid, and a sale on
credit. A supplier purchase is not here: the test chart lacks the weight
accounts it posts to, and add_invoice refuses it unbalanced.

Regenerate the record (review the diff before committing it):
    U0_RECORD=1 python -m pytest tests/test_u0_retraction_characterization.py
Run:
    python -m pytest tests/test_u0_retraction_characterization.py -v
"""
import json
import os
from pathlib import Path

import pytest

from app import app as flask_app
from models import JournalEntry, JournalEntryLine, db
from tests.books_snapshot import cached_vs_ledger, diff, snapshot
from tests.retraction_world import SHAPES, _create, _payload, unposting_allowed, world  # noqa: F401 (fixtures)

RECORD = Path(__file__).with_name('u0_retraction_effects.json')
RECORDING = os.getenv('U0_RECORD') == '1'
_results = {}


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _accounts_of(invoice_id):
    return [a for (a,) in db.session.query(JournalEntryLine.account_id).join(JournalEntry)
            .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id).distinct()]


def _call(headers, path, invoice_id, world, shape):
    client = flask_app.test_client()
    if path == 'unpost_posting_screen':
        return client.post(f'/api/invoices/unpost/{invoice_id}', headers=headers, json={})
    if path == 'unpost_invoices_route':
        return client.post(f'/api/invoices/{invoice_id}/unpost', headers=headers, json={})
    if path == 'unpost_batch':
        return client.post('/api/invoices/unpost-batch', headers=headers, json={'invoice_ids': [invoice_id]})
    if path == 'reject':
        return client.post(f'/api/invoices/{invoice_id}/reject', headers=headers, json={'reason': 'U0'})
    if path == 'delete':
        return client.delete(f'/api/invoices/{invoice_id}', headers=headers)
    if path == 'edit':
        edit = _payload(world, shape, held=True)
        edit['items'][0]['weight'] = edit['items'][0].get('standing_weight', edit['items'][0]['weight']) + 0.1
        if 'standing_weight' in edit['items'][0]:
            edit['items'][0]['standing_weight'] = edit['items'][0]['weight']
        edit['total_weight'] = edit['items'][0]['weight']
        return client.put(f'/api/invoices/{invoice_id}', headers=headers, json=edit)
    raise ValueError(path)


def _answer(resp):
    body = resp.get_json(silent=True) or {}
    return f"{resp.status_code}:{body.get('error') or ('ok' if resp.status_code < 400 else '?')}"


UNPOST_PATHS = ('unpost_posting_screen', 'unpost_invoices_route', 'unpost_batch')
HELD_PATHS = ('reject', 'delete', 'edit')


def _check(key, observed):
    _results[key] = observed
    if RECORDING:
        return
    expected = json.loads(RECORD.read_text(encoding='utf-8')).get(key)
    assert expected is not None, f'{key}: not in {RECORD.name} -- record it (U0_RECORD=1) and review'
    assert observed == expected, f'{key} changed:\n{json.dumps(diff(expected, observed), ensure_ascii=False, indent=1)}'


@pytest.mark.parametrize('path', UNPOST_PATHS)
@pytest.mark.parametrize('shape', SHAPES)
def test_unpost_then_repost(auth_headers, unposting_allowed, world, shape, path):
    inv = _create(auth_headers, world, shape, held=False)
    key_args = (inv['invoice_type'], inv['invoice_type_id'], (inv['id'],))
    accounts = _accounts_of(inv['id'])
    posted = snapshot(*key_args)
    resp = _call(auth_headers, path, inv['id'], world, shape)
    unposted = snapshot(*key_args)
    repost = flask_app.test_client().post(f"/api/invoices/post/{inv['id']}", headers=auth_headers, json={})
    reposted = snapshot(*key_args)
    _check(f'{shape}/{path}', {
        'answer': _answer(resp),
        'unpost_changes': {k: list(v) for k, v in diff(posted, unposted).items()},
        'cached_balance_drift_after_unpost': len(cached_vs_ledger(accounts)),
        'repost_answer': _answer(repost),
        'round_trip_differs_from_posted': {k: list(v) for k, v in diff(posted, reposted).items()},
    })


@pytest.mark.parametrize('path', HELD_PATHS)
@pytest.mark.parametrize('shape', SHAPES)
def test_held_invoice(auth_headers, world, shape, path):
    inv = _create(auth_headers, world, shape, held=True)
    key_args = (inv['invoice_type'], inv['invoice_type_id'], (inv['id'],))
    before = snapshot(*key_args)
    resp = _call(auth_headers, path, inv['id'], world, shape)
    after = snapshot(*key_args)
    _check(f'held:{shape}/{path}', {
        'answer': _answer(resp),
        'changes': {k: list(v) for k, v in diff(before, after).items()},
    })


def teardown_module(module):
    if RECORDING and _results:
        existing = json.loads(RECORD.read_text(encoding='utf-8')) if RECORD.exists() else {}
        existing.update(_results)
        RECORD.write_text(json.dumps(dict(sorted(existing.items())), ensure_ascii=False, indent=1) + '\n',
                          encoding='utf-8')
