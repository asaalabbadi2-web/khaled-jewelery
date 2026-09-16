import os
import time
import pytest
from datetime import datetime
import sys

# IMPORTANT: tests must never run against the real dev/prod database.
# Force an isolated SQLite DB for pytest BEFORE importing the Flask app.
_DEFAULT_SAFE_TEST_DB = None
try:
    base_dir = os.path.dirname(os.path.abspath(__file__))
    safe_dir = os.path.join(base_dir, '.pytest_db')
    os.makedirs(safe_dir, exist_ok=True)
    _DEFAULT_SAFE_TEST_DB = os.path.join(
        safe_dir,
        f"yasargold_test_{int(time.time())}_{os.getpid()}.db",
    )
except Exception:
    _DEFAULT_SAFE_TEST_DB = None

if os.getenv('PYTEST_ALLOW_REAL_DB', '').strip() not in ('1', 'true', 'yes'):
    # Override any existing DATABASE_URL to protect user data.
    if _DEFAULT_SAFE_TEST_DB:
        os.environ['DATABASE_URL'] = f"sqlite:///{_DEFAULT_SAFE_TEST_DB}"
    else:
        os.environ['DATABASE_URL'] = 'sqlite:///:memory:'

    # Mark environment as test to reduce side effects.
    os.environ.setdefault('YASAR_ENV', 'test')

# Ensure backend package is importable
base_dir = os.path.dirname(os.path.abspath(__file__))
if base_dir not in sys.path:
    sys.path.insert(0, base_dir)

import app as flask_app_module

from app import app, reset_database
from models import db, Account, SafeBox, Supplier, Customer, Employee, Invoice, User


@pytest.fixture(scope='session', autouse=True)
def initialize_db():
    """Reset DB and seed minimal chart-of-accounts and basic data for tests.

    This fixture runs once per pytest session. It creates required accounts
    with specific IDs used by unit tests, plus a sample supplier/customer/employee.
    """
    # Make sure we run inside the Flask app context
    with app.app_context():
        # reset the database to a clean state
        try:
            reset_database()
        except Exception:
            # best-effort: if reset_database isn't available, fallback to create_all
            db.session.remove()
            db.drop_all()
            db.create_all()

        # Seed essential accounts with fixed IDs used in tests
        # Use explicit ids so tests referencing account numbers work reliably
        #
        # transaction_type is set explicitly rather than left to the column's
        # server_default ('both'). Accounts 15/400/521/1200/1220 are the five the
        # P4.2 migration corrects (ADR-026): they are the financial (SAR) side of
        # the dual system, and their historical transaction_type='both' plus
        # tracks_weight=True came from a name-based misclassification, not from
        # their accounting role. Seeding the pre-migration state here would leave
        # the whole suite running in a world the migration has already corrected,
        # so no test could catch a regression caused by the correction.
        #
        # Weight-side coverage belongs on 7xxx accounts, which the dual-chart
        # helpers create as the memo pair of a financial account.
        #
        # (id, name, type, transaction_type, tracks_weight)
        accounts = [
            (15, 'صندوق النقدية', 'Asset', 'cash', False),
            (400, 'مبيعات ذهب جديد', 'Revenue', 'cash', False),
            (521, 'تكلفة مبيعات الذهب', 'Expense', 'cash', False),
            (1200, 'مخزون ذهب عيار 24', 'Asset', 'cash', False),
            (1220, 'مخزون ذهب عيار 21', 'Asset', 'cash', False),
            # Unified inventory fallbacks used by _resolve_inventory_account_id_for_invoice.
            # Left as-is: these are not P4.2 targets and several tests depend on
            # their current shape.
            (1300, 'مخزون ذهب معروض للبيع (موحد)', 'Asset', 'both', True),
            (1310, 'مخزون ذهب كسر (موحد)', 'Asset', 'both', True),
        ]

        for acc_id, name, acc_type, transaction_type, tracks_weight in accounts:
            existing = Account.query.get(acc_id)
            if existing:
                existing.name = name
                existing.type = acc_type
                existing.transaction_type = transaction_type
                existing.tracks_weight = tracks_weight
            else:
                a = Account(
                    id=acc_id,
                    account_number=str(acc_id),
                    name=name,
                    type=acc_type,
                    transaction_type=transaction_type,
                    tracks_weight=tracks_weight,
                )
                # initialize balances to known values if needed
                if acc_id == 15:
                    a.balance_cash = 10000.0
                db.session.add(a)

        # Seed an admin user for authenticated endpoints in unit tests.
        admin = User.query.filter_by(username='admin').first()
        if not admin:
            admin = User(username='admin', full_name='Admin', email=None, is_active=True, is_admin=True)
            admin.set_password('admin123')
            db.session.add(admin)

        # Account 1610 — dedicated ledger account for SafeBox 32 (مدى).
        # Must NOT reuse Account 15 (cash): voucher_engine skips supplier-tagging
        # on safe-box accounts, which breaks test_voucher_party_tagging.
        if not Account.query.get(1610):
            db.session.add(Account(
                id=1610,
                account_number='1610',
                name='خزينة مدى',
                type='Asset',
                tracks_weight=False,
            ))
            db.session.flush()

        # SafeBox id=32 (مدى) — required by test_historical_clearing_adjustment.py
        if not SafeBox.query.get(32):
            db.session.add(SafeBox(
                id=32,
                name='مدى',
                safe_type='cash',
                account_id=1610,
            ))

        # Seed a supplier with id=1 (some integration tests expect supplier 1)
        if not Supplier.query.get(1):
            s = Supplier(id=1, supplier_code='S-000001', name='لازوردي')
            db.session.add(s)

        # Seed a sample customer and employee for tests
        if not Customer.query.first():
            c = Customer(customer_code='C-000001', name='عميل اختبار', phone='0500000001', email='test@example.com')
            db.session.add(c)

        if not Employee.query.first():
            e = Employee(employee_code='E-000001', name='موظف اختبار', is_active=True)
            db.session.add(e)

        db.session.commit()


@pytest.fixture
def access_token():
    """JWT access token for the seeded admin user."""
    with app.app_context():
        from auth_decorators import generate_token

        admin = User.query.filter_by(username='admin').first()
        if not admin:
            admin = User(username='admin', full_name='Admin', email=None, is_active=True, is_admin=True)
            admin.set_password('admin123')
            db.session.add(admin)
            db.session.commit()
        return generate_token(admin)


@pytest.fixture
def auth_headers(access_token):
    return {'Authorization': f'Bearer {access_token}'}


@pytest.fixture
def customer_id():
    with app.app_context():
        c = Customer.query.first()
        return c.id if c else None


@pytest.fixture
def original_invoice_id():
    """Create a minimal invoice to be used as 'original' for return tests."""
    with app.app_context():
        inv = Invoice(invoice_type_id=1, invoice_type='بيع', date=datetime.now(), total=1000.0)
        db.session.add(inv)
        db.session.commit()
        return inv.id


def pytest_collection_modifyitems(config, items):
    """Skip integration-like HTTP tests unless RUN_SERVER_TESTS env is set.

    Tests that rely on a running HTTP server (the files starting with
    `test_invoices.py` and `test_supplier_purchase.py`) are skipped by default.
    Set RUN_SERVER_TESTS=1 to run them.
    """
    run_server = os.getenv('RUN_SERVER_TESTS') == '1'
    if run_server:
        return

    skip_marker = pytest.mark.skip(reason="Integration server tests skipped; set RUN_SERVER_TESTS=1 to enable")
    skip_files = {'test_invoices.py', 'test_supplier_purchase.py', 'test_invoice.py', 'test_advance_accounts.py'}
    for item in items:
        if item.fspath.basename in skip_files:
            item.add_marker(skip_marker)
