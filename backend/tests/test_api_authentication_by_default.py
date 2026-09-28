"""Every /api route answers only an authenticated caller -- unless it is listed as public.

Until September 2026, authentication in this API was opt-in, route by route: a
route was protected only if its function carried @require_auth or
@require_permission, or if it lived on the legacy `api` blueprint, whose
before_request enforced a session for everything under it. The July 2026 routes
migration (c1195c4 .. 0232533) moved the routes into per-domain blueprints, and
the protection did not travel with them. 111 route-methods reached their view
with no authentication at all. A request with NO token deleted a journal entry,
a voucher, a supplier and a customer -- witnessed on a throwaway database.

The rule "every /api route requires a session" lived in a hook, so moving the
routes silently removed it. It now lives in api_auth_guard.py and HERE: this
file asks every /api route in the url map, so a route added or moved tomorrow
is covered the day it exists.

Only the request hooks run (preprocess_request) -- never a view -- so asking
every route is safe even for routes that delete or reset.

Run:
    python -m pytest tests/test_api_authentication_by_default.py -v
"""
import re
import uuid
from datetime import datetime

import pytest
from werkzeug.routing import FloatConverter, IntegerConverter, UUIDConverter

from app import app as flask_app
from models import Customer, JournalEntry, JournalEntryLine, Account, Supplier, User, Voucher, db


@pytest.fixture
def app():
    """Deliberately holds NO app context open. flask.g lives in the app context,
    and require_auth trusts a g.current_user left there by an earlier request:
    under a shared context an anonymous request rides on the previous caller's
    session, and every 401 in this file would pass for the wrong reason. Each
    request below gets its own context; database setup opens and closes its own."""
    flask_app.config['TESTING'] = True
    return flask_app


@pytest.fixture(autouse=True)
def _the_production_path(monkeypatch):
    """backend/.env turns BYPASS_AUTH_FOR_DEVELOPMENT on for local work, which
    serves every tokenless /api request as admin -- every 401 here would turn into
    a 200 for that reason alone. Production refuses to boot with the bypass on
    (tests/test_auth_bypass_production_guard.py), so these tests take the path
    production takes."""
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0')


def _public_routes():
    from api_auth_guard import PUBLIC_API_ROUTES
    return PUBLIC_API_ROUTES


def _sample_url(rule):
    def value(name):
        conv = rule._converters.get(name)
        if isinstance(conv, IntegerConverter):
            return '1'
        if isinstance(conv, FloatConverter):
            return '1.0'
        if isinstance(conv, UUIDConverter):
            return '00000000-0000-0000-0000-000000000000'
        return 'x'
    return re.sub(r'<(?:[^:<>]+:)?([^<>]+)>', lambda m: value(m.group(1)), rule.rule)


def _hook_status(rule, method, headers=None):
    """What the request hooks answer, before any view: None means 'let it through'."""
    with flask_app.test_request_context(_sample_url(rule), method=method, headers=headers or {}):
        resp = flask_app.preprocess_request()
    if resp is None:
        return None
    if isinstance(resp, tuple):
        return resp[1]
    return getattr(resp, 'status_code', resp)


def _api_rules():
    for rule in flask_app.url_map.iter_rules():
        if rule.rule.startswith('/api/'):
            for method in sorted(rule.methods - {'HEAD', 'OPTIONS'}):
                yield rule, method


class TestEveryApiRouteIsClosedToAnonymousCallers:

    def test_every_non_public_route_refuses_an_anonymous_request_before_its_view(self, app):
        public = _public_routes()
        open_routes = [
            f'{method} {rule.rule} -> {status}'
            for rule, method in _api_rules()
            if (rule.rule, method) not in public
            for status in [_hook_status(rule, method)]
            if status != 401
        ]
        assert open_routes == [], (
            f'{len(open_routes)} /api route(s) reach their view with no session. Protect the '
            f'route, or -- only if it must work before sign-in -- add it to '
            f'api_auth_guard.PUBLIC_API_ROUTES with the reason:\n  ' + '\n  '.join(open_routes))

    def test_public_routes_are_let_through_without_a_session(self, app):
        by_key = {(rule.rule, method): rule for rule, method in _api_rules()}
        stopped = [f'{m} {r} -> {_hook_status(by_key[(r, m)], m)}'
                   for (r, m) in _public_routes() if (r, m) in by_key
                   and _hook_status(by_key[(r, m)], m) is not None]
        assert stopped == [], 'a public route is refused before sign-in:\n  ' + '\n  '.join(stopped)

    def test_the_public_list_names_only_routes_that_exist(self, app):
        existing = {(rule.rule, method) for rule, method in _api_rules()}
        stale = sorted(f'{m} {r}' for (r, m) in _public_routes() if (r, m) not in existing)
        assert stale == [], 'public entries that match no route (renamed or removed?):\n  ' + '\n  '.join(stale)

    def test_every_public_route_says_why_it_is_public(self, app):
        silent = [f'{m} {r}' for (r, m), why in _public_routes().items() if not (why or '').strip()]
        assert silent == []

    def test_a_cors_preflight_is_not_refused(self, app):
        rule = next(r for r in flask_app.url_map.iter_rules() if r.rule == '/api/suppliers')
        assert _hook_status(rule, 'OPTIONS') is None

    def test_an_unknown_api_path_is_refused_too(self, app):
        """Deny by default means no route, no answer -- not a 404 that maps the API."""
        with flask_app.test_client() as c:
            assert c.get('/api/no-such-thing-at-all').status_code == 401


# ----------------------------------------------------------------------
# The witnessed deletes: behaviour, through the real HTTP stack
# ----------------------------------------------------------------------

def _uid():
    return uuid.uuid4().hex[:8]


@pytest.fixture
def victims(app):
    """One of each witnessed kind, committed so the HTTP request can see it."""
    with flask_app.app_context():
        acc = Account(account_number=f'97{_uid()[:4]}', name=f'witness {_uid()}', type='Asset')
        db.session.add(acc)
        db.session.flush()
        je = JournalEntry(entry_number=f'JE-W-{_uid()}', date=datetime.now(), description='witness',
                          entry_type='عادي', is_posted=True, is_draft=False,
                          reference_type='manual', created_by='t')
        db.session.add(je)
        db.session.flush()
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=acc.id,
                                        cash_debit=100.0, cash_credit=0.0, description='w'))
        v = Voucher(voucher_number=f'V-W-{_uid()}', voucher_type='payment', date=datetime.now(),
                    status='pending', created_by='t', amount_cash=10.0, created_at=datetime.now())
        s = Supplier(supplier_code=f'S-W-{_uid()}', name=f'witness {_uid()}')
        cu = Customer(customer_code=f'C-W-{_uid()}', name=f'witness {_uid()}')
        db.session.add_all([v, s, cu])
        db.session.commit()
        ids = {'journal_entries': (JournalEntry, je.id), 'vouchers': (Voucher, v.id),
               'suppliers': (Supplier, s.id), 'customers': (Customer, cu.id)}
    yield ids
    with flask_app.app_context():
        for model, pk in ids.values():
            row = db.session.get(model, pk)
            if row is not None:
                if model is JournalEntry:
                    JournalEntryLine.query.filter_by(journal_entry_id=pk).delete()
                db.session.delete(row)
        db.session.commit()


@pytest.mark.parametrize('kind', ['journal_entries', 'vouchers', 'suppliers', 'customers'])
def test_an_anonymous_delete_is_refused_and_the_row_stays(victims, kind):
    model, pk = victims[kind]
    with flask_app.test_client() as c:
        resp = c.delete(f'/api/{kind}/{pk}')
    assert resp.status_code == 401
    with flask_app.app_context():
        assert db.session.get(model, pk) is not None, f'an anonymous request deleted {kind} {pk}'


def test_a_signed_in_caller_passes_the_guard(app):
    """The guard adds a session requirement and nothing else."""
    from auth_decorators import generate_token
    with flask_app.app_context():
        admin = User.query.filter_by(username='admin').first()
        token = generate_token(admin)
    with flask_app.test_client() as c:
        resp = c.get('/api/suppliers', headers={'Authorization': f'Bearer {token}'})
    assert resp.status_code == 200
