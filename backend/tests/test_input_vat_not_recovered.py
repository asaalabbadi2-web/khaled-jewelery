"""Input VAT that is not recovered is part of what it was paid on (ADR-043, phase 4b; rule 1).

The owner (11 Oct 2026): the company recovers input VAT today -- a temporary
state. When a period says it is not recovered, the VAT paid is not an asset
on 1400: on what enters the stock it is the stock's cost (IAS 2) -- the
supplier's wages carry their VAT -- and on what does not (the gold's VAT on a
supplier's purchase, posted by weight only; a card commission) it goes to
«ضريبة القيمة المضافة غير القابلة للاسترداد». A return gives it back where its
purchase put it, so the two net to nothing. While inputs are recovered,
nothing changes.

Run:
    python -m pytest tests/test_input_vat_not_recovered.py -v
"""
from datetime import date

import pytest
from sqlalchemy import func

from app import app as flask_app
from models import Account, InvoiceItem, JournalEntry, JournalEntryLine, VatPolicyPeriod, db
from tests.test_supplier_return_reverses_purchase import _return_of
from tests.test_wage_treatment_follows_the_setting import (  # noqa: F401 (fixtures)
    app, books, rollback_after_each, _vat, _create, _purchase, _settings,
)


def _not_recovered():
    VatPolicyPeriod.query.delete()
    db.session.add(VatPolicyPeriod(effective_from=date(2000, 1, 1), input_vat_recoverable=False,
                                   sales_vat_charged=False, created_by='t'))
    db.session.flush()


def _cash(invoice_id, account):
    db.session.expire_all()
    dr, cr = (db.session.query(func.coalesce(func.sum(JournalEntryLine.cash_debit), 0),
                               func.coalesce(func.sum(JournalEntryLine.cash_credit), 0))
              .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
              .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                      JournalEntry.is_deleted.is_(False), JournalEntryLine.is_deleted.is_(False),
                      JournalEntryLine.account_id == account.id).one())
    return round(float(dr), 2), round(float(cr), 2)


def _1400():
    return Account.query.filter_by(account_number='1400').one()


def test_a_suppliers_wage_vat_not_recovered_is_the_wages_cost(auth_headers, books):
    _settings('inventory')
    _not_recovered()
    purchase = _create(auth_headers, _purchase(books))
    assert _cash(purchase['id'], books['wage_inventory']) == (230.0, 0.0), 'wages 200 and their VAT 30'
    assert _cash(purchase['id'], _1400()) == (0.0, 0.0), 'no input VAT asset'


def test_its_return_gives_the_vat_back_where_the_purchase_put_it(auth_headers, books):
    _settings('inventory')
    _not_recovered()
    purchase = _create(auth_headers, _purchase(books))
    ret = _create(auth_headers, _return_of(books, purchase))
    assert _cash(ret['id'], books['wage_inventory']) == (0.0, 230.0)
    assert _cash(ret['id'], _1400()) == (0.0, 0.0)


def test_while_recovered_nothing_changes(auth_headers, books):
    _settings('inventory')
    VatPolicyPeriod.query.delete()
    db.session.add(VatPolicyPeriod(effective_from=date(2000, 1, 1), input_vat_recoverable=True,
                                   sales_vat_charged=False, created_by='t'))
    db.session.flush()
    purchase = _create(auth_headers, _purchase(books))
    assert _cash(purchase['id'], books['wage_inventory']) == (200.0, 0.0)
    assert _cash(purchase['id'], _1400()) == (30.0, 0.0)


def test_vat_on_nothing_that_enters_the_stock_goes_to_non_recoverable():
    from services.vat_policy import NON_RECOVERABLE_ROLE, input_vat_account
    _not_recovered()
    if not Account.query.filter_by(account_number='540').first():      # as on production, with its twin
        admin = Account(account_number='540', name='المصاريف الإدارية والعمومية', type='Expense')
        twin = Account(account_number='7540', name='المصاريف الإدارية والعمومية وزني', type='Expense',
                       tracks_weight=True, transaction_type='gold')
        db.session.add_all([admin, twin])
        db.session.flush()
        admin.memo_account_id, twin.memo_account_id = twin.id, admin.id
        db.session.flush()
    account_id = input_vat_account(date.today(), operation_type='بيع', role='commission_vat')
    account = db.session.get(Account, account_id)
    assert 'غير القابلة للاسترداد' in account.name
    assert account.memo_account_id, 'a cash account, paired as the chart pairs them'
    again = input_vat_account(date.today(), operation_type='شراء')
    assert again == account_id, 'one account, mapped once'
    from accounting.mappings import get_account_id_for_mapping
    assert get_account_id_for_mapping('بيع', NON_RECOVERABLE_ROLE) == account_id


def test_a_card_commissions_vat_follows_the_period_of_its_invoice():
    from datetime import datetime
    from models import Invoice
    from routes.invoices import _commission_vat_account
    from services.vat_policy import non_recoverable_account_id
    test_vat_on_nothing_that_enters_the_stock_goes_to_non_recoverable()     # 540 and the period
    sale = Invoice(invoice_type='بيع', date=datetime(2033, 3, 5), total=100.0, invoice_type_id=1)
    assert _commission_vat_account(sale, 1410) == non_recoverable_account_id(), 'not recovered: an expense'
    VatPolicyPeriod.query.delete()
    db.session.add(VatPolicyPeriod(effective_from=date(2000, 1, 1), input_vat_recoverable=True,
                                   sales_vat_charged=False, created_by='t'))
    db.session.flush()
    assert _commission_vat_account(sale, 1410) == 1410, 'recovered: its input VAT account, as before'
