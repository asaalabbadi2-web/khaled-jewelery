"""Every route that reads declares WHO may read it -- or is on this list, with the reason (SEC-008, ADR-036 R3).

Measured 2 Oct 2026: 83 GET routes declared no permission. The July route
move took them off the blueprint whose before_request inferred one, so a
signed-in seller could read the account statements and balances, the
suppliers' ledgers, every voucher, the payroll, the bonuses and the gold
cost. The owner's matrix (ADR-036) decides each; what stays open is open by
nature -- the point of sale needs it, or it is the caller's own -- and says so.

Static, like its twin for writes: it reads each route's decorator stack.

Run:
    python -m pytest tests/test_read_routes_declare_permission.py -v
"""
import re

from tests.test_write_routes_declare_permission import DECLARES, SKIP, _python_sources, BACKEND

POS = 'the point of sale needs it for every seller'
OWN = "the caller's own"
ALLOWED = {
    ('auth_decorators.py', 'protected_route'): 'a docstring example, not a route',
    ('auth_decorators.py', 'public_route'): 'a docstring example, not a route',
    ('auth_routes.py', 'check_setup_status'): 'read before anyone signs in: is the system set up',
    ('auth_routes.py', 'get_current_user_info'): OWN + ': who am I',
    ('auth_routes.py', 'list_sessions'): OWN + ' sessions',
    ('setup_routes.py', 'setup_status'): 'the first-run wizard; refuses once setup is locked',
    ('routes/admin.py', 'serve_temp_pdf'): 'the token in the link is the permission (the printed invoice)',
    ('routes/system.py', 'get_settings'): 'every signed-in user reads the settings (main karat, VAT); changing them is system.settings',
    ('routes/pricing.py', 'get_gold_price'): POS,
    ('routes/pricing.py', 'get_gold_price_24h'): POS,
    ('routes/pricing.py', 'get_gold_price_public'): 'public by design: the gold price',
    ('branches_routes.py', 'get_branch'): POS,
    ('payment_methods_routes.py', 'get_payment_methods'): POS,
    ('payment_methods_routes.py', 'get_active_payment_methods'): POS,
    ('payment_methods_routes.py', 'get_invoice_type_options'): POS,
    ('payment_methods_routes.py', 'get_payment_types'): POS,
    ('bonus_routes.py', 'get_invoice_types'): 'a fixed list of invoice type names',
    ('routes/reports.py', 'get_home_leaderboard'): 'the sales race on the home screen, for every employee',
    ('routes/employees.py', 'get_unseen_achievements'): OWN + ' achievements',
    ('routes/employees.py', 'list_employees'): 'names only without employees.view (the owner, 2 Oct 2026: the invoice list filters by seller)',
    ('routes/invoices.py', 'pending_actions'): 'counts and lists only for those who approve; zeros for the rest (the bell)',
    ('routes/vouchers.py', 'get_vouchers'): 'vouchers.view, or a seller reading their own invoice\'s vouchers (in its body)',
    ('permissions_routes.py', 'get_user_permissions'): OWN + ' permissions; another user\'s need users.view',
}


def read_routes_without_permission():
    found = set()
    for p in sorted(_python_sources()):
        rel = str(p.relative_to(BACKEND))
        if any(s in '/' + rel for s in SKIP) or rel.startswith('test_'):
            continue
        lines = p.read_text(encoding='utf-8', errors='ignore').split('\n')
        for i, line in enumerate(lines):
            m = re.match(r"\s*@(\w+)\.route\(\s*['\"]([^'\"]+)['\"](.*)\)", line)
            if not m:
                continue
            methods = m.group(3)
            if re.search(r"'(POST|PUT|PATCH|DELETE)'", methods) and 'GET' not in methods:
                continue
            j, stack = i + 1, []
            while j < len(lines) and not lines[j].lstrip().startswith('def '):
                stack.append(lines[j])
                j += 1
            if any(DECLARES.search(s) for s in stack):
                continue
            fn = re.match(r'\s*def (\w+)', lines[j]).group(1)
            found.add((rel, fn))
    return found


def test_a_read_route_declares_its_permission():
    new = sorted(k for k in read_routes_without_permission() if k not in ALLOWED)
    assert new == [], ('read routes that declare no permission -- add @require_permission(...) per the '
                       'owner\'s matrix, or an entry in ALLOWED with the reason:\n  '
                       + '\n  '.join(f'{f}::{fn}' for f, fn in new))


def test_the_allowlist_has_no_stale_entries():
    stale = sorted(k for k in ALLOWED if k not in read_routes_without_permission())
    assert stale == [], f'entries that now declare a permission -- remove them: {stale}'
