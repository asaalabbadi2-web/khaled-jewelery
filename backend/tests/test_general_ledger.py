import uuid
from datetime import datetime
import pytest

from app import app, db
from models import Account, JournalEntry, JournalEntryLine, SafeBox


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield



def _create_account(name: str) -> Account:
    account = Account(
        account_number=f'TST-GL-{uuid.uuid4().hex[:8]}',
        name=name,
        type='Asset',
        transaction_type='both',
        tracks_weight=True,
    )
    db.session.add(account)
    db.session.flush()
    return account


def _add_entry(account_id: int, cash_debit=0.0, cash_credit=0.0, gold_debit_21k=0.0,
               gold_credit_21k=0.0, entry_date=None, entry_kwargs=None):
    entry_data = {
        'date': entry_date or datetime.utcnow(),
        'description': 'قيد اختبار الأستاذ العام',
        'entry_type': 'عادي',
        'is_posted': True,
    }
    if entry_kwargs:
        entry_data.update(entry_kwargs)

    entry = JournalEntry(**entry_data)
    db.session.add(entry)
    db.session.flush()

    db.session.add(JournalEntryLine(
        journal_entry_id=entry.id,
        account_id=account_id,
        cash_debit=cash_debit,
        cash_credit=cash_credit,
        debit_21k=gold_debit_21k,
        credit_21k=gold_credit_21k,
    ))

    offset_account = Account.query.get(15)
    if offset_account is None:
        offset_account = _create_account('حساب تعويض تلقائي')

    db.session.add(JournalEntryLine(
        journal_entry_id=entry.id,
        account_id=offset_account.id,
        cash_debit=cash_credit,
        cash_credit=cash_debit,
        debit_21k=gold_credit_21k,
        credit_21k=gold_debit_21k,
    ))

    return entry


def test_general_ledger_account_filter_and_balances(auth_headers):
    with app.app_context():
        primary_account = _create_account('حساب الأستاذ العام')
        _add_entry(
            primary_account.id,
            cash_debit=2000.0,
            gold_debit_21k=1.25,
            entry_date=datetime(2025, 1, 5),
        )

        other_account = _create_account('حساب آخر')
        _add_entry(
            other_account.id,
            cash_debit=700.0,
            gold_debit_21k=0.5,
            entry_date=datetime(2025, 1, 6),
        )

        db.session.commit()
        target_account_id = primary_account.id

    with app.test_client() as client:
        resp = client.get('/api/general_ledger_all', query_string={
            'account_id': target_account_id,
            'show_balances': 'true',
            'karat_detail': 'true',
        }, headers=auth_headers)

    assert resp.status_code == 200
    payload = resp.get_json()

    assert payload['filters']['account_id'] == target_account_id
    assert payload['summary']['total_entries'] == 1
    assert len(payload['entries']) == 1

    entry = payload['entries'][0]
    assert entry['account_id'] == target_account_id
    assert entry['cash_debit'] == 2000.0
    assert entry['running_balance']['cash'] == pytest.approx(2000.0)
    assert entry['running_balance']['gold_normalized'] == pytest.approx(1.25, rel=1e-4)
    assert entry['karat_details']['21k']['debit'] == pytest.approx(1.25, rel=1e-4)
    assert entry['running_balance']['by_karat']['21k'] == pytest.approx(1.25, rel=1e-4)


def test_general_ledger_date_filters_trim_entries(auth_headers):
    with app.app_context():
        date_account = _create_account('حساب التواريخ')
        _add_entry(
            date_account.id,
            cash_debit=500.0,
            entry_date=datetime(2025, 1, 1),
        )
        _add_entry(
            date_account.id,
            cash_debit=800.0,
            entry_date=datetime(2025, 1, 20),
        )
        db.session.commit()
        account_id = date_account.id

    with app.test_client() as client:
        resp = client.get('/api/general_ledger_all', query_string={
            'account_id': account_id,
            'start_date': '2025-01-10',
            'show_balances': 'true',
        }, headers=auth_headers)

    assert resp.status_code == 200
    payload = resp.get_json()

    assert payload['summary']['total_entries'] == 1
    assert len(payload['entries']) == 1
    entry = payload['entries'][0]
    assert entry['cash_debit'] == 800.0
    assert entry['running_balance']['cash'] == pytest.approx(800.0)


def test_general_ledger_extended_filters(auth_headers):
    with app.app_context():
        riyadh_account = _create_account('خزينة الرياض')
        jeddah_account = _create_account('خزينة جدة')

        riyadh_account_id = riyadh_account.id
        jeddah_account_id = jeddah_account.id

        db.session.add_all([
            SafeBox(name='صندوق الرياض', safe_type='cash', account_id=riyadh_account.id, branch='Riyadh'),
            SafeBox(name='صندوق جدة', safe_type='cash', account_id=jeddah_account.id, branch='Jeddah'),
        ])

        _add_entry(
            riyadh_account.id,
            cash_debit=1200.0,
            entry_date=datetime(2025, 2, 1),
            entry_kwargs={
                'created_by': 'ali',
                'posted_by': 'auditor',
                'is_posted': True,
                'reference_type': 'invoice',
                'reference_number': 'INV-100',
            },
        )

        _add_entry(
            riyadh_account.id,
            cash_debit=900.0,
            entry_date=datetime(2025, 2, 2),
            entry_kwargs={
                'created_by': 'ali',
                'is_posted': False,
                'reference_type': 'invoice',
                'reference_number': 'INV-101',
            },
        )

        _add_entry(
            riyadh_account.id,
            cash_debit=500.0,
            entry_date=datetime(2025, 2, 3),
            entry_kwargs={
                'created_by': 'ali',
                'posted_by': 'auditor',
                'is_posted': True,
                'reference_type': 'voucher',
                'reference_number': 'VCH-55',
            },
        )

        _add_entry(
            jeddah_account.id,
            cash_debit=700.0,
            entry_date=datetime(2025, 2, 4),
            entry_kwargs={
                'created_by': 'sara',
                'posted_by': 'auditor',
                'is_posted': True,
                'reference_type': 'invoice',
                'reference_number': 'INV-200',
            },
        )

        db.session.commit()

    with app.test_client() as client:
        resp = client.get('/api/general_ledger_all', query_string={
            'posted_only': 'true',
            'reference_types': 'invoice',
            'user': 'auditor',
            'branch': 'riyadh',
        }, headers=auth_headers)

    assert resp.status_code == 200
    payload = resp.get_json()
    assert payload['summary']['total_entries'] == 1
    assert len(payload['entries']) == 1
    assert payload['entries'][0]['reference_number'] == 'INV-100'
    assert payload['entries'][0]['account_branch'] == 'Riyadh'

    with app.test_client() as client:
        resp_created = client.get('/api/general_ledger_all', query_string={
            'account_id': riyadh_account_id,
            'created_by': 'ali',
            'show_balances': 'false',
        }, headers=auth_headers)

    assert resp_created.status_code == 200
    payload_created = resp_created.get_json()
    # ثلاثة قيود مرتبطة بالحساب تم إنشاؤها من قبل علي
    assert payload_created['summary']['total_entries'] == 3