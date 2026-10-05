"""A manual entry's refusals are said in Arabic, and name what to do (JE-UX-1).

The entry screen showed the server's English text as it came -- «Exception: Cash
debits and credits must be balanced.» -- to an Arabic-speaking accountant. The
refusal is the server's, so the words are fixed here, not translated on the
screen (one canonical message, not a table in the client). The create and the
edit route refuse the same three ways and must say the same words.

Run:
    python -m pytest tests/test_je_form_refusals_in_arabic.py -v
"""
import re

import pytest

from app import app as flask_app
from models import Account, JournalEntry, db

_ARABIC = re.compile(r'[؀-ۿ]')


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _leaf_accounts(n):
    parents = {p for (p,) in db.session.query(Account.parent_id).filter(Account.parent_id.isnot(None))}
    ids = [a.id for a in Account.query.order_by(Account.id).all() if a.id not in parents][:n]
    assert len(ids) == n, 'the test database has too few leaf accounts'
    return ids


def _body(lines):
    return {'date': '2026-10-05T00:00:00', 'description': 'اختبار', 'lines': lines}


def _post(auth_headers, lines):
    return flask_app.test_client().post('/api/journal_entries', headers=auth_headers, json=_body(lines))


def _put(auth_headers, lines):
    je = JournalEntry(entry_number='JE-UX-1', date=__import__('datetime').datetime(2026, 10, 5),
                      description='x', is_posted=False)
    db.session.add(je)
    db.session.flush()
    return flask_app.test_client().put(f'/api/journal_entries/{je.id}', headers=auth_headers, json=_body(lines))


def _cases():
    a, b = _leaf_accounts(2)
    return {
        'cash': ([{'account_id': a, 'cash_debit': 100}, {'account_id': b, 'cash_credit': 50}], 'نقد'),
        'gold': ([{'account_id': a, 'debit_21k': 10}, {'account_id': b, 'credit_21k': 5}], 'ذهب'),
        'account': ([{'cash_debit': 100}, {'account_id': b, 'cash_credit': 100}], 'حساب'),
    }


@pytest.mark.parametrize('kind', ['cash', 'gold', 'account'])
@pytest.mark.parametrize('send', [_post, _put])
def test_a_refusal_is_in_arabic_and_names_the_side(auth_headers, kind, send):
    lines, word = _cases()[kind]
    resp = send(auth_headers, lines)
    assert resp.status_code == 400
    error = resp.get_json()['error']
    assert _ARABIC.search(error) and word in error, error
