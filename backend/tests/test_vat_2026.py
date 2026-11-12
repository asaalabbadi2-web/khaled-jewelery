"""VAT in the 2026 books as it was filed (ADR-089).

The owner (12 Nov 2026): output VAT per quarter debits the sales; input VAT
is what the books lack against the accountant's statement; each quarter
closes into the net payable. The laws:
  - every figure of the plan derives from the filed returns: the output
    entry is the sales VAT less the returns' VAT, the input entry the
    statement less what the books hold, the closing the return's due;
  - the owner's identity holds: what the books hold of input VAT plus what
    was paid equals what the quarter takes off the profit;
  - each entry balances; it names no account the plan does not;
  - the shared writer resolves an account by its role and refuses a role
    that is not mapped; refuses when a period's movement differs from the
    plan's; makes an account under its parent's role, of its own type.

Run:
    python -m pytest tests/test_vat_2026.py -v
"""
import copy
import datetime as dt
import uuid

import pytest

from app import app as flask_app
from models import Account, AccountingMapping, JournalEntry, JournalEntryLine, db
from services.repair.planned_entries import PlanRefused, write_plan
from services.repair.vat_2026 import load

NOW = dt.datetime(2026, 11, 12, 10, 0)


def _cash(entry, account, side):
    return round(sum(float((line.get(side) or {}).get('cash', 0)) for line in entry['lines']
                     if line['account'] == account), 2)


def test_every_figure_derives_from_the_filed_returns():
    figures = load()
    returns = figures['returns']
    by_quarter = {}
    for e in figures['entries']:
        if 'quarter' in e:
            by_quarter.setdefault(e['quarter'], {})[e['kind']] = e
    assert set(by_quarter) == set(returns)
    for q, r in returns.items():
        output = round(r['sales_vat'] - r['returns_vat'], 2)
        diff = round(r['input_vat'] - r['recorded_input'] - r['recorded_pos'], 2)
        ret, close = by_quarter[q]['return'], by_quarter[q]['close']
        assert _cash(ret, 'vat_out', 'cr') == output, q
        assert _cash(ret, 'vat_in', 'dr') == diff, q
        assert _cash(close, 'vat_out', 'dr') == output, q
        assert _cash(close, 'vat_in', 'cr') == round(r['recorded_input'] + diff, 2), q
        assert _cash(close, 'vat_pos', 'cr') == r['recorded_pos'], q
        net = _cash(close, 'vat_net', 'cr') - _cash(close, 'vat_net', 'dr')
        assert abs(net - r['due']) < 0.01, (q, net, r['due'])
    # what the books hold, by the plan's own guard, is what the derivation used
    periods = {(p['account'], p['from']): p['cash'] for p in figures['expect_period']}
    assert [periods[('vat_in', f)] for f in ('2025-12-01', '2026-04-01', '2026-07-01')] == \
        [returns[q]['recorded_input'] for q in ('Q1-2026', 'Q2-2026', 'Q3-2026')]
    assert [periods[('vat_pos', f)] for f in ('2025-12-01', '2026-04-01', '2026-07-01')] == \
        [returns[q]['recorded_pos'] for q in ('Q1-2026', 'Q2-2026', 'Q3-2026')]


def test_the_owners_identity_and_the_profit():
    figures = load()
    r = figures['returns']
    # «ما بقي علينا = المسجّل في ضريبة المدخلات + ضرائب الربع الأول والثاني والثالث»
    q = ('Q1-2026', 'Q2-2026', 'Q3-2026')
    recorded = sum(r[k]['recorded_input'] + r[k]['recorded_pos'] for k in q)
    dues = sum(r[k]['due'] for k in q)
    output = sum(r[k]['sales_vat'] - r[k]['returns_vat'] for k in q)
    diff = sum(r[k]['input_vat'] - r[k]['recorded_input'] - r[k]['recorded_pos'] for k in q)
    assert round(recorded + dues, 2) == round(output - diff, 2) == 52404.41
    # the plan's effect on the year's profit, from its own lines
    profit = 0.0
    for e in figures['entries']:
        for line in e['lines']:
            if line['account'] in figures['profit_accounts']:
                profit -= float((line.get('dr') or {}).get('cash', 0)) - float((line.get('cr') or {}).get('cash', 0))
    assert round(profit, 2) == figures['expect_profit_change'] == -50224.45


def test_each_entry_balances_and_names_only_the_plans_accounts():
    figures = load()
    known = set(figures['accounts']) | {m['key'] for m in figures['made_accounts']}
    for e in figures['entries']:
        dr = sum(float((l.get('dr') or {}).get('cash', 0)) for l in e['lines'])
        cr = sum(float((l.get('cr') or {}).get('cash', 0)) for l in e['lines'])
        assert abs(dr - cr) < 0.005, e['key']
        assert {l['account'] for l in e['lines']} <= known, e['key']
        assert dt.date.fromisoformat(e['date']).year == 2026, e['key']
    assert not figures.get('protected_allowed'), 'no protected account: the cash box and bank are corrected through 370'


# ── the shared writer's new parts, on a small world ──────────────────

@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def world(app, db_fence):
    tag = uuid.uuid4().hex[:6]

    def account(name, kind='Asset'):
        a = Account(account_number=f'8{uuid.uuid4().int % 10**7:07d}', name=f'{name} {tag}', type=kind,
                    transaction_type='cash', tracks_weight=False)
        db.session.add(a)
        db.session.flush()
        return a

    out, net, parent = account('vat out', 'Liability'), account('vat net', 'Liability'), account('expenses', 'Expense')
    for role, a in ((f'test_vat_out_{tag}', out), (f'test_parent_{tag}', parent)):
        db.session.add(AccountingMapping(operation_type='افتراضي', account_type=role, account_id=a.id, is_active=True))
    je = JournalEntry(entry_number=f'JE-V-{tag}', date=dt.datetime(2026, 2, 10), description='seed', entry_type='عادي',
                      is_posted=True, created_by='t')
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=net.id, cash_debit=50.0, description='seed'))
    db.session.flush()
    figures = {
        'reference_type': f'vat_test_{tag}',
        'accounts': {'vat_out': {'role': f'test_vat_out_{tag}'}, 'vat_net': {'number': net.account_number, 'name': net.name}},
        'made_accounts': [{'key': 'recovered', 'name': f'recovered {tag}', 'parent_role': f'test_parent_{tag}', 'type': 'Expense'}],
        'expect_period': [{'account': 'vat_net', 'from': '2026-01-01', 'to': '2026-03-31', 'cash': 50.0}],
        'entries': [{'key': 'V1', 'date': '2026-03-31', 'type': 'تصحيح', 'description': 'ضريبة',
                     'lines': [{'account': 'recovered', 'dr': {'cash': 10.0}}, {'account': 'vat_out', 'cr': {'cash': 10.0}}]}],
    }
    return {'figures': figures, 'out': out, 'parent': parent}


def test_a_role_resolves_and_an_unmapped_role_is_refused(world):
    done = write_plan(world['figures'], by='t', now=NOW)
    assert done['accounts']['vat_out'].id == world['out'].id
    figures = copy.deepcopy(world['figures'])
    figures['accounts']['vat_out'] = {'role': 'no_such_role_anywhere'}
    figures['reference_type'] += '_b'
    with pytest.raises(PlanRefused, match='no_such_role_anywhere'):
        write_plan(figures, by='t', now=NOW)


def test_a_period_other_than_the_plans_is_refused_and_nothing_written(world):
    figures = copy.deepcopy(world['figures'])
    figures['expect_period'][0]['cash'] = 49.0
    with pytest.raises(PlanRefused, match='vat_net 2026-01-01'):
        write_plan(figures, by='t', now=NOW)
    assert JournalEntry.query.filter_by(reference_type=figures['reference_type']).count() == 0


def test_a_made_account_is_of_its_type_under_its_role_with_a_twin(world):
    done = write_plan(world['figures'], by='t', now=NOW)
    made = done['accounts']['recovered']
    assert made.parent_id == world['parent'].id and made.type == 'Expense' and made.memo_account_id
    assert done['made']['recovered']['made'] is True


# ── the amendment: the net VAT as an expense the weight profit reads ──

def _expense_figures():
    import os
    from services.repair.vat_2026 import load as load_figures
    return load_figures(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                     'services', 'repair', 'vat_2026_expense.json'))


def test_each_quarters_net_vat_becomes_the_expense_and_the_profit_does_not_move():
    vat, reclass = load(), _expense_figures()
    r = vat['returns']
    by_key = {e['key']: e for e in reclass['entries']}
    for quarter, key in (('Q1-2026', 'XQ1-2026'), ('Q2-2026', 'XQ2-2026'), ('Q3-2026', 'XQ3-2026')):
        q = r[quarter]
        net = round((q['sales_vat'] - q['returns_vat']) - (q['input_vat'] - q['recorded_input'] - q['recorded_pos']), 2)
        assert _cash(by_key[key], 'vat_expense', 'dr') == net, quarter
    q4 = r['Q4-2025']
    assert _cash(by_key['XQ4-2025'], 'vat_refund', 'cr') == round(-q4['due'], 2) == 23159.96
    # the four quarters' net VAT, as the cash profit took it: the owner's 29,244.45
    total = sum(_cash(e, 'vat_expense', 'dr') for e in reclass['entries']) - _cash(by_key['XQ4-2025'], 'vat_refund', 'cr')
    assert round(total, 2) == 29244.45
    profit = 0.0
    for e in reclass['entries']:
        dr = sum(float((l.get('dr') or {}).get('cash', 0)) for l in e['lines'])
        cr = sum(float((l.get('cr') or {}).get('cash', 0)) for l in e['lines'])
        assert abs(dr - cr) < 0.005, e['key']
        for line in e['lines']:
            if line['account'] in reclass['profit_accounts']:
                profit -= float((line.get('dr') or {}).get('cash', 0)) - float((line.get('cr') or {}).get('cash', 0))
    assert round(profit, 2) == reclass['expect_profit_change'] == 0.0
    # each reclass is dated as its quarter's return: the weight profit nets a day's marked lines
    return_dates = {e['quarter']: e['date'] for e in vat['entries'] if e.get('kind') == 'return'}
    assert [by_key[k]['date'] for k in ('XQ4-2025', 'XQ1-2026', 'XQ2-2026', 'XQ3-2026')] == \
        [return_dates[q] for q in ('Q4-2025', 'Q1-2026', 'Q2-2026', 'Q3-2026')]


def test_a_made_account_is_marked_in_the_gram_profit_when_the_owner_says_so(world):
    figures = copy.deepcopy(world['figures'])
    parent = world['parent']
    figures['made_accounts'] = [{'key': 'recovered', 'name': f'refund {uuid.uuid4().hex[:6]}', 'type': 'Revenue',
                                 'parent': {'number': parent.account_number, 'name': parent.name},
                                 'include_in_gram_profit': True}]
    figures['reference_type'] += '_m'
    made = write_plan(figures, by='t', now=NOW)['accounts']['recovered']
    assert made.parent_id == parent.id and made.type == 'Revenue' and made.include_in_gram_profit is True
