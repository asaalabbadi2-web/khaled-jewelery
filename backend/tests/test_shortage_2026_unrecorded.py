"""Two payments of 30 March 2026 out of the safes shortage (ADR-088; the owner, 15 Nov 2026).

«مبالغ تم صرفها ولم تسجل في النظام»: 46,173 «مقدَّمًا عن زكاة 2026» --
zakat on the shop, not on the partners -- and 20,000 the workers' bonuses.
The laws:
  - both come out of «عجز / فائض الخزائن» and nothing else: the cash box and
    the bank are never touched (they were reconciled; the shortage holds it);
  - the advance is not this year's expense yet, nor a debt not yet owed: it
    is an asset, «زكاة مدفوعة مقدَّمًا» under the current assets, until the
    year's zakat is computed and it is set against it (the owner: «هذا يبدوا
    اصح»), so it moves no profit; the bonuses do;
  - the plan's after is its before less its own entries;
  - through the shared writer, on synthetic books: written once, a second run
    writes nothing, and books other than the plan found are refused whole.

Run:
    python -m pytest tests/test_shortage_2026_unrecorded.py -v
"""
import copy
import datetime as dt
import os
import uuid

import pytest

from app import app as flask_app
from models import Account, JournalEntry, JournalEntryLine, db
from services.repair.planned_entries import PlanRefused, balance
from services.repair.vat_2026 import apply, load

NOW = dt.datetime(2026, 11, 15, 10, 0)
FIGURES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       'services', 'repair', 'shortage_2026_unrecorded.json')


def _cash(figures, account, side):
    return round(sum(float((line.get(side) or {}).get('cash', 0)) for e in figures['entries']
                     for line in e['lines'] if line['account'] == account), 2)


def test_the_owners_two_payments_out_of_the_shortage_and_nothing_else():
    figures = load(FIGURES)
    assert [(e['date'], sum(float((l.get('dr') or {}).get('cash', 0)) for l in e['lines'])) for e in figures['entries']] \
        == [('2026-03-30', 46173.0), ('2026-03-30', 20000.0)]
    for e in figures['entries']:
        dr = sum(float((l.get('dr') or {}).get('cash', 0)) for l in e['lines'])
        cr = sum(float((l.get('cr') or {}).get('cash', 0)) for l in e['lines'])
        assert abs(dr - cr) < 0.005, e['key']
        assert [l['account'] for l in e['lines'] if l.get('cr')] == ['safes_shortage'], e['key']
    assert not figures.get('protected_allowed'), 'the cash box and bank are corrected through 370'
    assert _cash(figures, 'safes_shortage', 'cr') == 66173.0


def test_the_zakat_advance_waits_for_the_years_zakat_and_the_bonuses_are_the_profits():
    figures = load(FIGURES)
    assert _cash(figures, 'zakat_prepaid', 'dr') == 46173.0 and _cash(figures, 'zakat_expense', 'dr') == 0.0
    assert figures['made_accounts'] == [{'key': 'zakat_prepaid', 'name': 'زكاة مدفوعة مقدَّمًا', 'type': 'Asset',
                                         'parent': {'number': '11', 'name': 'الأصول المتداولة'}}]
    assert 'zakat_prepaid' not in figures['profit_accounts']
    assert _cash(figures, 'bonuses', 'dr') == 20000.0 and figures['accounts']['bonuses'] == {'role': 'bonus_expense'}
    profit = 0.0
    for e in figures['entries']:
        for line in e['lines']:
            if line['account'] in figures['profit_accounts']:
                profit -= float((line.get('dr') or {}).get('cash', 0)) - float((line.get('cr') or {}).get('cash', 0))
    assert round(profit, 2) == figures['expect_profit_change'] == -20000.0


def test_the_plans_after_is_its_before_less_its_entries():
    figures = load(FIGURES)
    for key, after in figures['expect_after'].items():
        moved = _cash(figures, key, 'dr') - _cash(figures, key, 'cr')
        before = figures['expect_before'].get(key, {'cash': 0.0})['cash']     # a made account starts at nothing
        assert round(before + moved, 2) == after['cash'], key


# ── through the shared writer, on synthetic books ────────────────────

@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def world(app, db_fence):
    """The plan's accounts as new synthetic ones, the shortage seeded at the
    plan's figure; the figures pointed at them by number and name."""
    tag = uuid.uuid4().hex[:6]
    figures = copy.deepcopy(load(FIGURES))
    figures['reference_type'] += f'_{tag}'
    made = {}
    for key, kind in (('safes_shortage', 'Equity'), ('current_assets', 'Asset'),
                      ('zakat_expense', 'Expense'), ('bonuses', 'Expense')):
        a = Account(account_number=f'8{uuid.uuid4().int % 10**7:07d}', name=f'{key} {tag}', type=kind,
                    transaction_type='cash', tracks_weight=False)
        db.session.add(a)
        db.session.flush()
        made[key] = a
        figures['accounts'][key] = {'number': a.account_number, 'name': a.name}
    parent = figures['accounts'].pop('current_assets')
    figures['made_accounts'][0]['parent'] = parent
    je = JournalEntry(entry_number=f'JE-U-{tag}', date=dt.datetime(2026, 10, 16), description='seed',
                      entry_type='عادي', is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=made['safes_shortage'].id,
                                    cash_debit=74238.72, description='seed'))
    db.session.flush()
    return {'figures': figures, 'accounts': made}


def test_written_once_as_the_plan_says_and_a_second_run_writes_nothing(world):
    figures, a = world['figures'], world['accounts']
    result = apply(by='t', now=NOW, figures=figures)
    assert [e['date'] for e in result['entries']] == ['2026-03-30', '2026-03-30']
    assert result['after']['profit_change'] == -20000.0
    assert round(balance(a['safes_shortage'].id)['cash'], 2) == 8065.72
    prepaid = Account.query.filter_by(parent_id=a['current_assets'].id, name='زكاة مدفوعة مقدَّمًا').one()
    assert prepaid.type == 'Asset' and prepaid.memo_account_id
    assert round(balance(prepaid.id)['cash'], 2) == 46173.0
    assert round(balance(a['bonuses'].id, '2026-03-01', '2026-03-31')['cash'], 2) == 20000.0
    count = JournalEntry.query.filter_by(reference_type=figures['reference_type']).count()
    assert count == 2
    assert apply(by='t', now=NOW, figures=figures)['already'] is True
    assert JournalEntry.query.filter_by(reference_type=figures['reference_type']).count() == count


def test_a_shortage_other_than_the_plan_found_is_refused_and_nothing_written(world):
    figures = world['figures']
    figures['expect_before']['safes_shortage']['cash'] = 74000.0
    with pytest.raises(PlanRefused, match='safes_shortage'):
        apply(by='t', now=NOW, figures=figures)
    assert JournalEntry.query.filter_by(reference_type=figures['reference_type']).count() == 0
