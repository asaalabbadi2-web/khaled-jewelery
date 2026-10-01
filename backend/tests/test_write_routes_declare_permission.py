"""Every route that writes declares WHO may call it -- or is on this list, with the reason.

api_auth_guard settles that a caller is signed in. It does not settle what that
caller may do: that is each route's @require_permission. When the guard went in
(ADR-031), 44 write routes declared no permission and checked none in their
body -- among them the hard delete of journal entries, PUT /settings, approving
and cancelling vouchers, deleting suppliers, customers and payment methods, and
resetting gold costing. Any signed-in employee can do those. Which role may do
each is a business decision, so they are recorded here as SEC-007 debt instead
of being guessed; the ratchet fails on any NEW write route that declares no
permission, and on any entry here that no longer matches (debt paid: remove it).

Static by nature: it reads each route's decorator stack in the source.

Run:
    python -m pytest tests/test_write_routes_declare_permission.py -v
"""
import pathlib
import re

BACKEND = pathlib.Path(__file__).resolve().parents[1]
DECLARES = re.compile(r'@(require_permission|require_any_permission|require_admin|admin_required|require_role)\b')
SKIP = ('tests/', '.pytest_db', 'devtools/', 'tools/', 'alembic/', 'venv/', '/test_')

ALLOWED = {
    ('auth_routes.py', 'change_password'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'confirm_password_reset'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'disable_2fa'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'enable_2fa'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'forgot_password'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'forgot_username'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'login'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'logout'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'refresh_access_token'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'revoke_session'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'setup_2fa'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'setup_initial_admin'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'smtp_test'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'terminate_all_sessions'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'terminate_session'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'update_current_user_photo'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('auth_routes.py', 'verify_2fa'):
        "sign-in and own-account actions (public, or acting on the caller's own session)",
    ('bonus_routes.py', 'calculate_bonuses'):
        'DEBT (SEC-007): only an is_admin branch in its body; no permission declared',
    ('bonus_routes.py', 'check_employee_personal_goals'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('bonus_routes.py', 'mark_goal_achievement_seen'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('bonus_routes.py', 'update_employee_goals'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('branches_routes.py', 'activate_branch'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('branches_routes.py', 'delete_branch'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('branches_routes.py', 'update_branch'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('offices_routes.py', 'activate_office'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('offices_routes.py', 'delete_office'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('offices_routes.py', 'update_office'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('payment_methods_routes.py', 'create_payment_method'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('payment_methods_routes.py', 'create_payment_type'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('payment_methods_routes.py', 'delete_payment_method'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('payment_methods_routes.py', 'delete_payment_type'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('payment_methods_routes.py', 'update_payment_method'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('payment_methods_routes.py', 'update_payment_methods_order'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('permissions_routes.py', 'update_user_permissions'):
        'checks users.change_permissions in its body; the decorator would make it visible',
    ('permissions_routes.py', 'update_user_role'):
        'checks users.change_permissions in its body; the decorator would make it visible',
    ('recurring_journal_routes.py', 'create_entry_from_template'):
        'api blueprint: _enforce_api_auth_and_permissions infers the permission',
    ('recurring_journal_routes.py', 'create_recurring_template_endpoint'):
        'api blueprint: _enforce_api_auth_and_permissions infers the permission',
    ('recurring_journal_routes.py', 'delete_recurring_template'):
        'api blueprint: _enforce_api_auth_and_permissions infers the permission',
    ('recurring_journal_routes.py', 'process_all_recurring'):
        'api blueprint: _enforce_api_auth_and_permissions infers the permission',
    ('recurring_journal_routes.py', 'toggle_template_active'):
        'api blueprint: _enforce_api_auth_and_permissions infers the permission',
    ('recurring_journal_routes.py', 'update_recurring_template'):
        'api blueprint: _enforce_api_auth_and_permissions infers the permission',
    ('routes/admin.py', 'upload_temp_pdf'):
        'any signed-in user may upload the PDF of the invoice they print',
    ('routes/customers.py', 'add_customer'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/customers.py', 'delete_customer'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/customers.py', 'update_customer'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/employees.py', 'check_goal_progress'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/employees.py', 'create_achievement'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/employees.py', 'create_employee_advance_account'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/employees.py', 'mark_achievement_seen'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/employees.py', 'update_employee_goals'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/invoices.py', 'add_invoice'):
        'DEBT (SEC-007): checks is_admin only for the employee override; creating an invoice needs no permission',
    ('routes/invoices.py', 'add_invoice_payment'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/invoices.py', 'set_invoice_print_template'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/pricing.py', 'calculate_gold_costing_cogs'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/pricing.py', 'recompute_gold_costing'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/pricing.py', 'recompute_scrap_costing'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/pricing.py', 'reset_gold_costing'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/pricing.py', 'reset_scrap_costing'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/pricing.py', 'update_gold_costing'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/pricing.py', 'update_gold_price'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/suppliers.py', 'add_supplier'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/suppliers.py', 'delete_supplier'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/suppliers.py', 'update_supplier'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/system.py', 'sign_statement_qr_payload'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/system.py', 'update_settings'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/vouchers.py', 'approve_voucher'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/vouchers.py', 'create_voucher'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('routes/vouchers.py', 'update_voucher'):
        'DEBT (SEC-007): no permission declared -- any signed-in user can do this',
    ('setup_routes.py', 'save_store_settings'):
        'first-run wizard; refuses (403) once setup is locked',
    ('setup_routes.py', 'test_db_connection'):
        'first-run wizard; refuses (403) once setup is locked',
    ('setup_routes.py', 'write_env_production'):
        'first-run wizard; refuses (403) once setup is locked',
}


def _python_sources():
    """Walks the backend without descending into virtualenvs or caches."""
    import os
    for root, dirs, files in os.walk(BACKEND):
        dirs[:] = [d for d in dirs if d not in ('venv', '.venv', '__pycache__', '.pytest_db', 'node_modules')]
        for name in files:
            if name.endswith('.py'):
                yield pathlib.Path(root) / name


def write_routes_without_permission():
    found = set()
    for p in sorted(_python_sources()):
        rel = str(p.relative_to(BACKEND))
        if any(s in '/' + rel for s in SKIP) or rel.startswith('test_'):
            continue
        lines = p.read_text(encoding='utf-8', errors='ignore').split('\n')
        for i, line in enumerate(lines):
            m = re.match(r"\s*@(\w+)\.route\(\s*['\"]([^'\"]+)['\"](.*)\)", line)
            if not m or not re.search(r"'(POST|PUT|PATCH|DELETE)'", m.group(3)):
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


def test_a_new_write_route_declares_its_permission():
    new = sorted(k for k in write_routes_without_permission() if k not in ALLOWED)
    assert new == [], (
        'write routes that declare no permission -- add @require_permission(...) '
        '(or, if it truly must not have one, an entry in ALLOWED with the reason):\n  '
        + '\n  '.join(f'{f}::{fn}' for f, fn in new))


def test_the_allowlist_has_no_stale_entries():
    stale = sorted(k for k in ALLOWED if k not in write_routes_without_permission())
    assert stale == [], f'entries that now declare a permission (debt paid) -- remove them: {stale}'


def test_every_entry_says_why():
    assert all((why or '').strip() for why in ALLOWED.values())
