"""A customer's return is the accountant's and the manager's (the owner, 11 Nov 2026).

«الموظف ليس له صلاحية عمل مرتجع حتى لفواتيره هو؛ المرتجع بصلاحيات المحاسب
والمدير ومن هو أعلى». A sale's return and a scrap purchase's -- in part
(POST /invoices) or whole (/invoices/<id>/reverse) -- ask `invoices.return`,
which the accountant and the manager hold and the seller does not; the
system's administrator holds every permission. A supplier's return was
already the accountant's (`invoices.supplier`, ADR-036).

Run:
    python -m pytest tests/test_returns_are_the_accountants.py -v
"""
import uuid

import pytest

from app import app as flask_app
from auth_decorators import generate_token
from models import AppUser, db
from permissions import ROLE_PERMISSIONS
from tests.retraction_world import world  # noqa: F401 (fixture)
from tests.test_return_line_remaining import _post, _return, _sale


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _headers_for(role):
    user = AppUser(username=f'{role}-{uuid.uuid4().hex[:6]}', role=role, is_active=True, password_hash='x')
    db.session.add(user)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


def _reverse(headers, sale, world):
    from flask import g
    g.pop('current_user', None)
    return flask_app.test_client().post(f"/api/invoices/{sale['id']}/reverse", headers=headers, json={
        'reason': 'عيب', 'payments': [{'payment_method_id': world['pm'].id}]})


def test_the_seller_does_not_hold_it_and_the_accountant_and_the_manager_do():
    assert 'invoices.return' not in ROLE_PERMISSIONS['employee']
    assert 'invoices.return' in ROLE_PERMISSIONS['accountant']
    assert 'invoices.return' in ROLE_PERMISSIONS['manager']


def test_a_seller_returns_no_part_even_of_their_own_sale(auth_headers, world):
    sale = _sale(auth_headers, world)
    resp = _post(_headers_for('employee'), _return(world, sale, [('خاتم', 2.0, 1, 1000.0)]))
    assert resp.status_code == 403, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['required_permission'] == 'invoices.return'


def test_a_seller_reverses_no_sale(auth_headers, world):
    sale = _sale(auth_headers, world)
    resp = _reverse(_headers_for('employee'), sale, world)
    assert resp.status_code == 403, resp.get_data(as_text=True)[:300]


@pytest.mark.parametrize('role', ['accountant', 'manager'])
def test_the_accountant_and_the_manager_return(auth_headers, world, role):
    sale = _sale(auth_headers, world)
    resp = _post(_headers_for(role), _return(world, sale, [('خاتم', 2.0, 1, 1000.0)]))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    resp = _reverse(_headers_for(role), _sale(auth_headers, world), world)
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
