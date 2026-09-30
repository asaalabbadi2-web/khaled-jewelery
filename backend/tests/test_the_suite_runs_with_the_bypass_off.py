"""The tests run as production does: no development bypass (TEST-002).

backend/.env -- untracked, on the developer's machine -- sets
BYPASS_AUTH_FOR_DEVELOPMENT=1, which serves a request with no token as admin.
Twelve tests passed only because of it (SEC-005's warning, realised): in a
clean checkout, in CI and in production they would fail. backend/conftest.py
now forces the bypass off before the app is imported, whatever .env says.

Run:
    python -m pytest tests/test_the_suite_runs_with_the_bypass_off.py -v
"""
import os

from app import app as flask_app


def test_the_bypass_is_off_in_every_test_run():
    assert os.environ.get('BYPASS_AUTH_FOR_DEVELOPMENT') == '0'


def test_a_request_without_a_session_is_refused():
    with flask_app.test_client() as c:
        assert c.get('/api/invoices').status_code == 401
