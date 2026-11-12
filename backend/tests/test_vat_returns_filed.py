"""The ADR-089 quarters recorded as filed returns (ADR-043 rule 5).

The laws: each row's figures are the plan's own (output = sales less returns,
input, due) and its period the quarter's; it links the quarter's closing
entry; a second run writes nothing; a quarter recorded otherwise is refused;
no row without its closing entry; and once recorded, the return screen
refuses to file the quarter again.

Run:
    python -m pytest tests/test_vat_returns_filed.py -v
"""
import copy
import datetime as dt
import uuid

import pytest

from app import app as flask_app
from models import JournalEntry, VatReturn, db
from services.repair.planned_entries import PlanRefused
from services.repair.vat_2026 import load
from services.repair.vat_returns_filed import filed, quarter_period, record

NOW = dt.datetime(2026, 11, 13, 10, 0)


def test_the_plans_quarters_as_their_returns_say_them():
    rows = {q['quarter']: q for q in filed(load())}
    assert {k: (q['start'], q['end'], q['output_vat'], q['input_vat'], q['net']) for k, q in rows.items()} == {
        'Q4-2025': (dt.date(2025, 10, 1), dt.date(2025, 12, 31), 8281.31, 31441.27, -23159.96),
        'Q1-2026': (dt.date(2026, 1, 1), dt.date(2026, 3, 31), 28716.01, 8436.57, 20279.44),
        'Q2-2026': (dt.date(2026, 4, 1), dt.date(2026, 6, 30), 20782.05, 19662.24, 1119.81),
        'Q3-2026': (dt.date(2026, 7, 1), dt.date(2026, 9, 30), 22286.79, 18149.11, 4137.68)}
    assert quarter_period('Q2-2031') == (dt.date(2031, 4, 1), dt.date(2031, 6, 30))


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def plan(app, db_fence):
    """Two quarters of the plan, far in the future, each with its closing entry."""
    tag = uuid.uuid4().hex[:6]
    figures = copy.deepcopy(load())
    figures['reference_type'] = f'vat_filed_test_{tag}'
    figures['returns'] = {'Q1-2041': figures['returns']['Q1-2026'], 'Q2-2041': figures['returns']['Q2-2026']}
    entries = {}
    for q, day in (('Q1-2041', dt.datetime(2041, 3, 31)), ('Q2-2041', dt.datetime(2041, 6, 30))):
        je = JournalEntry(entry_number=f'JE-VF-{q}-{tag}', date=day, description='close', entry_type='تصحيح',
                          is_posted=True, created_by='t', reference_type=figures['reference_type'],
                          reference_number=f'V{q}-close')
        db.session.add(je)
        db.session.flush()
        entries[q] = je
    return {'figures': figures, 'entries': entries}


def test_each_quarter_is_recorded_once_linked_to_its_closing_entry(plan):
    figures = plan['figures']
    first = record(by='t', now=NOW, figures=figures)
    assert [r['quarter'] for r in first['recorded']] == ['Q1-2041', 'Q2-2041'] and first['already'] == []
    row = VatReturn.query.filter_by(period_start=dt.date(2041, 1, 1)).one()
    assert (row.period_end, row.output_vat, row.input_vat, row.net) == (dt.date(2041, 3, 31), 28716.01, 8436.57,
                                                                        20279.44)
    assert row.journal_entry_id == plan['entries']['Q1-2041'].id
    again = record(by='t', now=NOW, figures=figures)
    assert again == {'recorded': [], 'already': ['Q1-2041', 'Q2-2041']}
    assert VatReturn.query.filter(VatReturn.period_start >= dt.date(2041, 1, 1)).count() == 2


def test_the_screen_refuses_a_recorded_quarter(plan):
    from services.vat_return import VatReturnRefused, file_vat_return
    record(by='t', now=NOW, figures=plan['figures'])
    with pytest.raises(VatReturnRefused) as refused:
        file_vat_return(start=dt.date(2041, 4, 1), end=dt.date(2041, 6, 30), by='t', now=dt.datetime(2041, 8, 1),
                        dry_run=True, filed_output_vat=1, filed_input_vat=0)
    assert refused.value.code == 'PERIOD_OVERLAPS'


def test_a_quarter_recorded_otherwise_is_refused(plan):
    db.session.add(VatReturn(period_start=dt.date(2041, 1, 1), period_end=dt.date(2041, 3, 31), output_vat=1.0,
                             input_vat=0.0, net=1.0, filed_by='t', filed_at=NOW))
    db.session.flush()
    with pytest.raises(PlanRefused, match='Q1-2041'):
        record(by='t', now=NOW, figures=plan['figures'])


def test_no_row_without_its_closing_entry(plan):
    figures = copy.deepcopy(plan['figures'])
    figures['returns']['Q3-2041'] = figures['returns']['Q1-2041']        # booked nowhere
    with pytest.raises(PlanRefused, match='VQ3-2041-close'):
        record(by='t', now=NOW, figures=figures)
    assert VatReturn.query.filter(VatReturn.period_start >= dt.date(2041, 1, 1)).count() == 0
