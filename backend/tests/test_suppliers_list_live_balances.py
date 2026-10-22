import uuid
from datetime import datetime

import pytest

from app import app, db
from models import Account, JournalEntry, JournalEntryLine, Supplier


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield



def _create_liability_payable_account() -> Account:
    acc = Account(
        account_number=f"210-{uuid.uuid4().hex[:8]}",
        name="موردين - اختبار",
        type="Liability",
        transaction_type="cash",
        tracks_weight=False,
    )
    db.session.add(acc)
    db.session.flush()
    return acc


def _post_supplier_cash_line(supplier_id: int, account_id: int, cash_debit=0.0, cash_credit=0.0):
    je = JournalEntry(
        date=datetime.utcnow(),
        description="قيد اختبار أرصدة الموردين",
        entry_type="عادي",
        is_posted=True,
        is_draft=False,
        is_deleted=False,
    )
    db.session.add(je)
    db.session.flush()

    db.session.add(
        JournalEntryLine(
            journal_entry_id=je.id,
            account_id=account_id,
            supplier_id=supplier_id,
            cash_debit=cash_debit,
            cash_credit=cash_credit,
            is_deleted=False,
        )
    )

    # Offset line to keep JE balanced.
    offset_account = Account.query.get(15)
    if offset_account is None:
        offset_account = Account(
            account_number=f"TST-OFF-{uuid.uuid4().hex[:8]}",
            name="حساب تعويض - اختبار",
            type="Asset",
            transaction_type="cash",
            tracks_weight=False,
        )
        db.session.add(offset_account)
        db.session.flush()

    db.session.add(
        JournalEntryLine(
            journal_entry_id=je.id,
            account_id=offset_account.id,
            cash_debit=cash_credit,
            cash_credit=cash_debit,
            is_deleted=False,
        )
    )


def test_suppliers_list_uses_live_balance_not_cached(auth_headers):
    with app.app_context():
        payable = _create_liability_payable_account()

        s = Supplier(
            supplier_code=f"S-TST-{uuid.uuid4().hex[:6]}",
            name="مورد اختبار - قائمة",
            account_id=payable.id,   # no stored balance: the columns are gone (3f20338), the list reads the ledger
        )
        db.session.add(s)
        db.session.flush()

        # Net should be -100 (credit on payables).
        _post_supplier_cash_line(supplier_id=s.id, account_id=payable.id, cash_credit=100.0)

        db.session.commit()
        supplier_id = s.id

    with app.test_client() as client:
        resp = client.get('/api/suppliers', headers=auth_headers)

    assert resp.status_code == 200
    suppliers = resp.get_json()
    row = next(x for x in suppliers if int(x['id']) == int(supplier_id))

    assert row['balance_cash'] == pytest.approx(-100.0)


def test_suppliers_list_returns_zero_when_no_ledger_rows(auth_headers):
    with app.app_context():
        s = Supplier(
            supplier_code=f"S-TST-{uuid.uuid4().hex[:6]}",
            name="مورد اختبار - بدون قيود",
        )
        db.session.add(s)
        db.session.commit()
        supplier_id = s.id

    with app.test_client() as client:
        resp = client.get('/api/suppliers', headers=auth_headers)

    assert resp.status_code == 200
    suppliers = resp.get_json()
    row = next(x for x in suppliers if int(x['id']) == int(supplier_id))

    assert row['balance_cash'] == pytest.approx(0.0)


def _settings_with_main_karat(main_karat):
    from models import Settings
    row = Settings.query.first()
    if row is None:
        row = Settings()
        db.session.add(row)
    row.main_karat = main_karat
    db.session.flush()


def _supplier_owed_gold(*, k21=0.0, k18=0.0):
    """A supplier we owe *k21* g of 21k and *k18* g of 18k (credits)."""
    payable = _create_liability_payable_account()
    s = Supplier(supplier_code=f"S-TST-{uuid.uuid4().hex[:6]}", name="مورد ذهب - اختبار",
                 account_id=payable.id)
    db.session.add(s)
    db.session.flush()
    offset = Account(account_number=f"TST-OFF-{uuid.uuid4().hex[:8]}", name="تعويض", type="Asset",
                     tracks_weight=True)
    db.session.add(offset)
    je = JournalEntry(date=datetime.utcnow(), description="ذهب المورد", entry_type="عادي",
                      is_posted=True, is_draft=False, is_deleted=False)
    db.session.add(je)
    db.session.flush()
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=payable.id, supplier_id=s.id,
                         credit_21k=k21, credit_18k=k18, is_deleted=False),
        JournalEntryLine(journal_entry_id=je.id, account_id=offset.id,
                         debit_21k=k21, debit_18k=k18, is_deleted=False),
    ])
    db.session.flush()
    return s.id


def _row_of(auth_headers, supplier_id):
    with app.test_client() as client:
        resp = client.get('/api/suppliers', headers=auth_headers)
    assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
    return next(x for x in resp.get_json() if int(x['id']) == int(supplier_id))


def test_the_list_says_the_gold_at_the_main_karat(auth_headers):
    """The suppliers screen worked the main-karat gold out itself (karat over
    main karat); the server says it, by the one conversion (ADR-050 ر٠)."""
    _settings_with_main_karat(21)
    supplier_id = _supplier_owed_gold(k21=10.0, k18=7.0)

    row = _row_of(auth_headers, supplier_id)

    assert row['balance_gold_21k'] == pytest.approx(-10.0)
    assert row['balance_gold_18k'] == pytest.approx(-7.0)
    assert row['balance_gold_main'] == pytest.approx(-(10.0 + 7.0 * 18 / 21), abs=0.001)


def test_with_no_main_karat_the_list_still_loads(auth_headers):
    _settings_with_main_karat(None)
    supplier_id = _supplier_owed_gold(k21=10.0)

    row = _row_of(auth_headers, supplier_id)

    assert row['balance_gold_21k'] == pytest.approx(-10.0)
    assert row['balance_gold_main'] is None
