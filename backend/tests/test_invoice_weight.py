#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""A manual invoice line's weight counts in the invoice's total weight -- once.

Brought in from the root (TEST-003): it multiplied the line's weight by its
quantity, as if 1.5 g were each piece's. A line's recorded weight is the whole
line's (POSTGOLD-001: multiplying it moved 56.1 g for sale 1057's 18.7 g), so
it went red, unseen. In the settings' main karat, not a fixed 21.
"""

from datetime import datetime

import pytest

from models import Invoice, InvoiceItem, db
from pricing.gold_price_service import get_main_karat


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def test_a_manual_lines_weight_counts_once_in_the_invoices_weight():
    invoice = Invoice(invoice_type='بيع', invoice_type_id=999_999, date=datetime(2026, 10, 1), total=0.0)
    db.session.add(invoice)
    db.session.flush()
    db.session.add(InvoiceItem(
        invoice_id=invoice.id, item_id=None, name='خاتم يدوي',  # a manual line: no Item
        quantity=2, price=0.0, karat=18, weight=1.5,             # 1.5 g the whole line, karat 18
        wage=0.0, net=0.0, tax=0.0,
    ))
    db.session.flush()
    assert invoice.calculate_total_weight() == pytest.approx(1.5 * 18 / get_main_karat())
