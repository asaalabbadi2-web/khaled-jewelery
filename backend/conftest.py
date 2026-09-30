import os
import time
import pytest
from datetime import datetime
import sys

# IMPORTANT: tests must never run against the real dev/prod database.
#
# They run on PostgreSQL -- what development and production run (TEST-001):
# a throwaway database created for this run and dropped after it, on the
# server named by PYTEST_PG_ADMIN_URL (default: the local server's `postgres`
# maintenance database). Until 30 Sep 2026 they ran on SQLite, where 35 tests
# passed that fail on PostgreSQL -- a green run said nothing about production.
# There is no SQLite mode: one database kind, the one production runs.
# PYTEST_ALLOW_REAL_DB=1 keeps DATABASE_URL as given (never for a real one).
_THROWAWAY_PG_DB = None
_PG_ADMIN_URL = os.getenv('PYTEST_PG_ADMIN_URL', 'postgresql://localhost/postgres')


def _pg_admin(sql):
    import psycopg2
    conn = psycopg2.connect(_PG_ADMIN_URL)
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
    finally:
        conn.close()


def _drop_throwaway_pg_db():
    if not _THROWAWAY_PG_DB:
        return
    try:
        from models import db as _db
        _db.engine.dispose()
    except Exception:
        pass
    try:
        _pg_admin(f'DROP DATABASE IF EXISTS "{_THROWAWAY_PG_DB}" WITH (FORCE)')
    except Exception as exc:  # never hide it: a left database is visible, not dangerous
        print(f'[conftest] could not drop {_THROWAWAY_PG_DB}: {exc}')


if os.getenv('PYTEST_ALLOW_REAL_DB', '').strip() not in ('1', 'true', 'yes'):
    _THROWAWAY_PG_DB = f'yasargold_pytest_{int(time.time())}_{os.getpid()}'
    try:
        _pg_admin(f'CREATE DATABASE "{_THROWAWAY_PG_DB}"')
    except Exception as exc:
        raise SystemExit(
            f'[conftest] tests run on PostgreSQL and could not create a throwaway database '
            f'through {_PG_ADMIN_URL}: {exc}\n'
            f'Start PostgreSQL or set PYTEST_PG_ADMIN_URL.')
    import atexit
    atexit.register(_drop_throwaway_pg_db)
    _base = _PG_ADMIN_URL.rsplit('/', 1)[0]
    os.environ['DATABASE_URL'] = f'{_base}/{_THROWAWAY_PG_DB}'

    # The backup code calls pg_dump from PATH, and pg_dump refuses a server
    # newer than itself. Production's image ships the matching client; here
    # the first pg_dump on PATH may be older (14 against a 16 server, 30 Sep
    # 2026). Put the client tools of the server's own major version first.
    # None found: the backup tests fail and say why -- they are not skipped.
    try:
        import psycopg2 as _pg
        _conn = _pg.connect(_PG_ADMIN_URL)
        _major = _conn.server_version // 10000
        _conn.close()
        for _bin in (os.getenv('PYTEST_PG_BIN', ''),
                     f'/opt/homebrew/opt/postgresql@{_major}/bin',
                     f'/usr/local/opt/postgresql@{_major}/bin',
                     f'/usr/lib/postgresql/{_major}/bin'):
            if _bin and os.path.exists(os.path.join(_bin, 'pg_dump')):
                os.environ['PATH'] = _bin + os.pathsep + os.environ.get('PATH', '')
                break
    except Exception as _exc:
        print(f'[conftest] could not match pg_dump to the server: {_exc}')

    # Mark environment as test to reduce side effects.
    os.environ.setdefault('YASAR_ENV', 'test')

# The tests run as production does: the development bypass is OFF, whatever
# backend/.env on this machine says (TEST-002). With it on, a request with no
# token was served as admin, and 12 tests passed only because of that.
# Set before the app is imported: load_dotenv never overrides a set variable.
os.environ['BYPASS_AUTH_FOR_DEVELOPMENT'] = '0'

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

        # PostgreSQL: rows seeded with explicit ids (accounts 15, 1300, 1610,
        # safe box 32, supplier 1) do not advance their id sequences, so the
        # next insert without an id would reuse one and fail (account_pkey).
        # SQLite derived the next id from max(id) and hid it (TEST-001).
        if db.engine.dialect.name == 'postgresql':
            from sqlalchemy import text
            rows = db.session.execute(text(
                "select c.table_name, c.column_name, pg_get_serial_sequence(c.table_name, c.column_name) "
                "from information_schema.columns c where c.table_schema = 'public' "
                "and pg_get_serial_sequence(c.table_name, c.column_name) is not null")).fetchall()
            for table, column, sequence in rows:
                db.session.execute(text(
                    f'select setval(\'{sequence}\', coalesce((select max("{column}") from "{table}"), 0) + 1, false)'))
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
