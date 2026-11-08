"""Receiving works from a day the settings name (ADR-087 §8, the owner, 8 Nov 2026).

Built now, working from 1 January on 2027's database: as the gold's cost
(Settings.gold_cost_from, ADR-042), a date -- NULL in 2026, so a purchase posts
as it always has; the transition writes 2027's first day, so no one has to
remember it on the opening. A purchase document carries its stage (received,
invoiced) and the key its screen sends with each save attempt (one document
however often it is sent, ADR-087 §1أ ٤); a line, the supplier's weight beside
the weight received.

Run:
    python -m pytest tests/test_receiving_from.py -v
"""
import uuid
from datetime import date, datetime

import pytest
from sqlalchemy.exc import IntegrityError

from models import Invoice, InvoiceItem, Settings, db


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def test_null_it_never_works_from_its_day_it_does():
    from services.receiving import receiving_on
    settings = Settings.query.first()
    settings.receiving_from = None
    db.session.flush()
    assert receiving_on(date(2027, 1, 1)) is False
    settings.receiving_from = date(2027, 1, 1)
    db.session.flush()
    assert receiving_on(date(2026, 12, 31)) is False
    assert receiving_on(date(2027, 1, 1)) is True
    assert receiving_on(datetime(2027, 3, 4, 10, 0)) is True


def test_the_transition_opens_2027_with_it():
    from services.transition_2027 import opening_settings
    row = opening_settings({'gold_cost_from': None, 'receiving_from': None}, opens_on=date(2027, 1, 1))
    assert row['gold_cost_from'] == date(2027, 1, 1)
    assert row['receiving_from'] == date(2027, 1, 1)


def _invoice(**kw):
    inv = Invoice(invoice_type='شراء', invoice_type_id=uuid.uuid4().int % 10**8, date=datetime(2027, 1, 2),
                  total=0.0, **kw)
    db.session.add(inv)
    db.session.flush()
    return inv


def test_a_document_carries_its_stage_its_key_and_its_lines_supplier_weight():
    inv = _invoice(receiving_stage='received', request_key='k-1')
    db.session.add(InvoiceItem(invoice_id=inv.id, name='بناجر', quantity=1, price=0.0, karat=21, weight=216.3,
                               supplier_weight=216.4))
    db.session.flush()
    assert (inv.receiving_stage, inv.request_key) == ('received', 'k-1')
    assert InvoiceItem.query.filter_by(invoice_id=inv.id).one().supplier_weight == 216.4


def test_a_key_is_one_document():
    _invoice(request_key='k-2')
    with pytest.raises(IntegrityError):
        with db.session.begin_nested():
            _invoice(request_key='k-2')
