"""The development auth bypass must never be active in production.

BYPASS_AUTH_FOR_DEVELOPMENT serves any /api/ request without an Authorization
header as `admin`. That defeats authentication and every permission check built
on it, so a production process carrying this flag must refuse to start rather
than run silently unauthenticated.

Registered as a P0 security blocker in architecture-v1.md §4.6 (SEC-005).
"""

import pytest

from app import _assert_auth_bypass_not_in_production, _is_production


# ── Production detection ─────────────────────────────────────────────────────

@pytest.mark.parametrize('env_var', ['YASAR_ENV', 'FLASK_ENV'])
@pytest.mark.parametrize('value', ['production', 'prod', 'PRODUCTION', ' Prod '])
def test_production_is_detected_from_either_variable(monkeypatch, env_var, value):
    monkeypatch.setenv('YASAR_ENV', '')
    monkeypatch.setenv('FLASK_ENV', '')
    monkeypatch.setenv(env_var, value)
    assert _is_production() is True


@pytest.mark.parametrize('value', ['development', 'test', 'staging', ''])
def test_non_production_values_are_not_production(monkeypatch, value):
    monkeypatch.setenv('YASAR_ENV', value)
    monkeypatch.setenv('FLASK_ENV', '')
    assert _is_production() is False


# ── The guard ────────────────────────────────────────────────────────────────

def test_boot_is_refused_when_bypass_is_enabled_in_production(monkeypatch):
    monkeypatch.setenv('YASAR_ENV', 'production')
    monkeypatch.setenv('FLASK_ENV', '')
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '1')

    with pytest.raises(RuntimeError) as exc:
        _assert_auth_bypass_not_in_production()

    message = str(exc.value)
    # The error must name the offending flag and the fix, not just fail.
    assert 'BYPASS_AUTH_FOR_DEVELOPMENT' in message
    assert 'production' in message.lower()


@pytest.mark.parametrize('flag', ['1', 'true', 'True'])
def test_every_truthy_flag_spelling_is_caught(monkeypatch, flag):
    monkeypatch.setenv('YASAR_ENV', 'production')
    monkeypatch.setenv('FLASK_ENV', '')
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', flag)

    with pytest.raises(RuntimeError):
        _assert_auth_bypass_not_in_production()


def test_production_without_the_bypass_boots(monkeypatch):
    monkeypatch.setenv('YASAR_ENV', 'production')
    monkeypatch.setenv('FLASK_ENV', '')
    monkeypatch.delenv('BYPASS_AUTH_FOR_DEVELOPMENT', raising=False)

    _assert_auth_bypass_not_in_production()  # must not raise


@pytest.mark.parametrize('env', ['development', 'test', ''])
def test_bypass_is_permitted_outside_production(monkeypatch, env):
    """The flag stays a legitimate convenience in dev and test."""
    monkeypatch.setenv('YASAR_ENV', env)
    monkeypatch.setenv('FLASK_ENV', '')
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '1')

    _assert_auth_bypass_not_in_production()  # must not raise


# ── Request-level defence in depth ───────────────────────────────────────────

def test_bypass_is_not_applied_to_requests_in_production(monkeypatch):
    """Even if the boot guard were circumvented, requests stay unauthenticated.

    The before_request hook checks production independently, so a running
    production process cannot serve an anonymous caller as admin.
    """
    from app import app, bypass_auth_for_development
    from flask import g

    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '1')
    monkeypatch.setenv('YASAR_ENV', 'production')
    monkeypatch.setenv('FLASK_ENV', '')

    with app.test_request_context('/api/suppliers'):
        bypass_auth_for_development()
        assert not getattr(g, 'current_user', None)

    # And the same hook does populate the user outside production, proving the
    # test above is measuring the production check and not a broken hook.
    monkeypatch.setenv('YASAR_ENV', 'development')
    with app.test_request_context('/api/suppliers'):
        bypass_auth_for_development()
        assert getattr(g, 'current_user', None) is not None


def test_unauthenticated_api_request_is_rejected_without_the_bypass(monkeypatch):
    """The authorization proof itself: no token, no access."""
    from app import app

    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0')

    with app.test_client() as client:
        resp = client.get('/api/suppliers/1/settlement-adjustments')

    assert resp.status_code == 401
