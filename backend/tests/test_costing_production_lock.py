"""COSTING-LOCK-1: on production the moving average is not zeroed -- nor rebuilt.

«تصفير المتوسط» zeroed the gold moving average with one button on production,
«إعادة بناء من الفواتير» and /gold-costing/recompute zero it first and replay
the invoices; after the year's transition entry (ADR-042) either costs what is
sold wrongly. The owner, 14 Oct 2026: locked. The scrap average's reset too.

With it, one answer to «is this production?» (core/environment.py): four copies
disagreed -- the auth one did not read YASAR_ENV, the variable production sets,
so it said «not production» there.

Every zeroing function is replaced by one that fails the test, so a regression
fails loudly and nothing is zeroed, even on the parent.
"""
import pytest

from app import app as flask_app
from models import db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


@pytest.fixture
def production(monkeypatch):
    for name in ('APP_ENV', 'ENV', 'FLASK_ENV', 'PYTHON_ENV'):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv('YASAR_ENV', 'production')
    import routes.pricing as pricing

    def zeroed(*args, **kwargs):
        raise AssertionError('the average was zeroed on production')
    monkeypatch.setattr(pricing, '_costing_zero_config', zeroed)
    monkeypatch.setattr(pricing, '_rebuild_costing_from_invoices', zeroed)
    monkeypatch.setattr(pricing.ScrapCostingService, 'reset', staticmethod(zeroed))


@pytest.mark.parametrize('path,body', [
    ('/api/gold-costing/reset', {'mode': 'zero'}),
    ('/api/gold-costing/reset', {'mode': 'rebuild'}),
    ('/api/gold-costing/recompute', None),
    ('/api/gold-costing/scrap/reset', None),
])
def test_the_average_is_not_zeroed_on_production(app, auth_headers, production, path, body):
    resp = flask_app.test_client().post(path, headers=auth_headers, json=body or {})
    assert resp.status_code == 403, resp.get_data(as_text=True)[:200]
    assert resp.get_json()['error'] == 'production_lock'


def test_one_answer_to_is_this_production(production):
    from auth_routes import _is_production_env as auth_says
    from core.environment import is_production
    from routes.system import _is_production_env as system_says
    assert is_production() and auth_says() and system_says()
