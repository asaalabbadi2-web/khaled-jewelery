"""Every /api request needs a session -- unless its route is listed here as public.

Deny by default. Until September 2026 authentication was opt-in per route: a
route was protected only if its function carried @require_auth or
@require_permission, or if it lived on the legacy `api` blueprint, whose
before_request enforced a session for everything under it. The July 2026 routes
migration (c1195c4 .. 0232533) moved the routes into per-domain blueprints and
the protection did not travel with them: 111 route-methods reached their view
with no authentication, and a request carrying no token deleted a journal
entry, a voucher, a supplier and a customer.

Authentication only: WHO is calling. WHAT a signed-in caller may do remains
each route's @require_permission.

tests/test_api_authentication_by_default.py asks every /api route in the url
map, so a route added or moved later is covered the day it exists.
"""
from __future__ import annotations

from flask import request

from auth_decorators import require_auth

# (rule, method) -> why it must answer before sign-in. Anything not here needs a
# session. Adding a line is a security decision: say why, in the entry itself.
PUBLIC_API_ROUTES: dict[tuple[str, str], str] = {
    ('/api/auth/login', 'POST'): 'signing in',
    ('/api/auth/refresh', 'POST'): 'renews an expired access token; the refresh token is the credential',
    ('/api/auth/check-setup', 'GET'): 'the app asks it at start-up, before anyone can sign in',
    ('/api/auth/setup-initial', 'POST'): 'creates the first admin; refuses (403/409) once any active user exists',
    ('/api/auth/forgot-password', 'POST'): 'password recovery happens before sign-in',
    ('/api/auth/forgot-username', 'POST'): 'username recovery happens before sign-in',
    ('/api/auth/password-reset/confirm', 'POST'): 'completes a recovery; its one-time code is the credential',
    ('/api/setup/status', 'GET'): 'first-run wizard, before any account exists',
    ('/api/setup/test-db', 'POST'): 'first-run wizard; refuses (403) once setup is locked',
    ('/api/setup/store-settings', 'POST'): 'first-run wizard; refuses (403) once setup is locked',
    ('/api/public/gold_price', 'GET'): 'the gold price is public by design',
    ('/api/temp-pdf/<string:token>', 'GET'):
        'a browser opens it without headers; the random 24-hour token in the URL is the credential',
    ('/api/internal/online-orders', 'POST'): 'service-to-service; the view checks X-Internal-Secret (SEC-003)',
    ('/api/internal/item-sale/<int:item_id>', 'GET'): 'service-to-service; the view checks X-Internal-Secret (SEC-003)',
    ('/api/internal/order-reconcile/<order_id>', 'GET'):
        'service-to-service; the view checks X-Internal-Secret (SEC-003)',
}


def _nothing():
    return None


# The session check itself is require_auth's -- token, blacklist, idle timeout,
# and the 401 bodies the app already understands -- not a second copy of it.
_require_session = require_auth(_nothing)


def enforce_session_for_api():
    """before_request: refuse any /api request without a session, unless public."""
    if request.method == 'OPTIONS':
        return None  # a CORS preflight carries no credentials by design
    if not (request.path or '').startswith('/api/'):
        return None
    rule = request.url_rule.rule if request.url_rule is not None else None
    method = 'GET' if request.method == 'HEAD' else request.method
    if rule is not None and (rule, method) in PUBLIC_API_ROUTES:
        return None
    return _require_session()


def install(app) -> None:
    """Register the guard. Call it after the development-bypass hook, so that in
    development a bypassed request already carries its user when this runs."""
    app.before_request(enforce_session_for_api)
