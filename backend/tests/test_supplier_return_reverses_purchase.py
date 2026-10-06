"""A supplier return reverses its purchase, line by line (RETURN-WAGE-1).

A supplier purchase posts in cash only its wages (1320, or the wage expense
under «expense» -- ADR-039) and their VAT (1400) against the supplier; the
gold itself is posted by weight. The return posted something else: it
debited the supplier for wages and VAT, debited 2100 («عكس جسر التقييم») with
the gold's cash value, and credited 1300 with the whole total. Measured on
the 6 Oct production copy (5 returns): 1300 lost 128,111.41 in cash that never
entered it, 2100 gained 120,394.24 never charged, and 1320 / 1400 kept the
returned wages and their VAT.

The owner (7 Oct 2026): a return reverses the purchase exactly. Its cash:
the supplier debited for wages and VAT, the wage account of the original's
frozen treatment and 1400 credited; no cash for the gold's value.

Run:
    python -m pytest tests/test_supplier_return_reverses_purchase.py -v
"""
from datetime import datetime

from sqlalchemy import func

from app import app as flask_app
from models import Account, InvoiceItem, JournalEntry, JournalEntryLine, db
from tests.test_wage_treatment_follows_the_setting import (  # noqa: F401 (fixtures)
    app, books, rollback_after_each, _create, _purchase, _settings,
)


def _cash(invoice_id, account):
    """(debit, credit) the invoice's entries put on [account], in cash."""
    db.session.expire_all()
    dr, cr = (db.session.query(func.coalesce(func.sum(JournalEntryLine.cash_debit), 0),
                               func.coalesce(func.sum(JournalEntryLine.cash_credit), 0))
              .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
              .filter(JournalEntry.reference_type == 'invoice',
                      JournalEntry.reference_id == invoice_id,
                      JournalEntry.is_deleted.is_(False),
                      JournalEntryLine.is_deleted.is_(False),
                      JournalEntryLine.account_id == account.id).one())
    return round(float(dr), 2), round(float(cr), 2)


def _return_of(b, purchase):
    """The whole purchase back: 10 g of 21k, its wages 200.00 and VAT 30.00."""
    item = InvoiceItem.query.filter_by(invoice_id=purchase['id']).first()
    gold, wage, vat = 3675.0, 200.0, 30.0
    return {
        'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': b['supplier'].id,
        'original_invoice_id': purchase['id'], 'gold_type': 'new',
        'date': datetime.now().isoformat(),
        'total': gold + wage + vat, 'total_tax': vat,
        'gold_subtotal': gold, 'wage_subtotal': wage,
        'wage_tax_total': vat, 'gold_tax_total': 0.0, 'vat_applied': True,
        'items': [{'name': 'سلسال', 'karat': 21, 'weight': 10.0, 'quantity': 1,
                   'manufacturing_wage_per_gram': 20.0,
                   'original_invoice_item_id': item.id}],
    }


def _account(number):
    return Account.query.filter_by(account_number=number).one()


def test_a_return_reverses_its_purchase_on_wages_vat_and_the_supplier(auth_headers, books):
    _settings('inventory')
    purchase = _create(auth_headers, _purchase(books))
    ret = _create(auth_headers, _return_of(books, purchase))

    supplier_acc = db.session.get(Account, books['supplier'].account_id) if books['supplier'].account_id else None
    assert _cash(ret['id'], books['wage_inventory']) == (0.0, 200.0)
    assert _cash(ret['id'], _account('1400')) == (0.0, 30.0)
    if supplier_acc is not None:
        assert _cash(ret['id'], supplier_acc)[0] == 230.0
    # Net of the purchase and its return: nothing left on wages, VAT, supplier.
    for acc in [books['wage_inventory'], _account('1400')] + ([supplier_acc] if supplier_acc else []):
        p_dr, p_cr = _cash(purchase['id'], acc)
        r_dr, r_cr = _cash(ret['id'], acc)
        assert round(p_dr + r_dr - p_cr - r_cr, 2) == 0.0, acc.account_number


def test_a_return_posts_no_cash_for_the_gold_value(auth_headers, books):
    _settings('inventory')
    purchase = _create(auth_headers, _purchase(books))
    ret = _create(auth_headers, _return_of(books, purchase))

    assert _cash(ret['id'], _account('1300')) == (0.0, 0.0)
    bridge = Account.query.filter_by(account_number='2100').first()
    if bridge is not None:
        assert _cash(ret['id'], bridge) == (0.0, 0.0)


def test_a_return_of_an_expensed_purchase_credits_the_wage_expense(auth_headers, books):
    _settings('expense')
    purchase = _create(auth_headers, _purchase(books))
    _settings('inventory')   # the original's frozen treatment decides, not the live one
    ret = _create(auth_headers, _return_of(books, purchase))

    assert _cash(ret['id'], books['wage_expense']) == (0.0, 200.0)
    assert _cash(ret['id'], books['wage_inventory']) == (0.0, 0.0)
