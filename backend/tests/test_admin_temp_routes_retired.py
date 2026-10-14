"""The temporary clearing routes are gone (the owner's leave, 14 Oct 2026).

/admin/clearing-gap-report, /admin/ip-settlement-trace and
/admin/repair-voucher-date-bounded were diagnostics of one clearing repair; no
screen called them, none had answered since the routes migration (July 2026:
InvoicePayment not imported), and the last rewrote a voucher's settlement lines
-- recorded as debt by the dead-payments ratchet. A repair is an entry or a
rehearsed tool (tools/repair), never a live route. A route that brings one
back fails here.
"""
import pytest

from app import app as flask_app


@pytest.mark.parametrize('path', [
    '/api/admin/clearing-gap-report',
    '/api/admin/ip-settlement-trace',
    '/api/admin/repair-voucher-date-bounded',
])
def test_no_temporary_clearing_route(path):
    assert path not in {rule.rule for rule in flask_app.url_map.iter_rules()}
