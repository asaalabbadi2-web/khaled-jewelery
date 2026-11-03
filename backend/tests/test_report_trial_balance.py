"""The trial balance: one service, the counted lines, a period's last day whole, said in the reports' contract (REPORTS ت0-3, ADR-083).

On the 4 Nov tree the trial balance with a period never answered: its route
filtered on `JournalEntry.entry_date`, a column the model does not have, so
any date the screen sent raised. It read the posted lines by its own filters,
and its end date cut at that day's midnight. Now:

  - services/reports/trial_balance.py reads the lines counted_line_filters
    counts -- the one definition the stored balance and the statements read;
  - a period's end day counts whole;
  - the route answers the reports' contract (services/reports/contract.py),
    with the old keys alongside until the screen moves to the shell (ت1).

Run:
    python -m pytest tests/test_report_trial_balance.py -v
"""
import datetime as dt
import uuid

import pytest
from flask import g

from app import app as flask_app
from models import Account, JournalEntry, db

D = dt.datetime


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(name):
    account = Account(account_number=f'93{uuid.uuid4().int % 10**8:08d}', name=name, type='Asset')
    db.session.add(account)
    db.session.flush()
    return account


def _entry(when, debit, credit, amount, *, posted=True, draft=False, deleted=False, grams=0.0, karat=21):
    from dual_system_helpers import create_dual_journal_entry
    entry = JournalEntry(date=when, description='ميزان', entry_type='عادي', is_posted=posted, is_draft=draft,
                         is_deleted=deleted, created_by='t')
    db.session.add(entry)
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=debit.id, cash_debit=amount,
                              apply_golden_rule=False, **{f'debit_{karat}k': grams})
    create_dual_journal_entry(journal_entry_id=entry.id, account_id=credit.id, cash_credit=amount,
                              apply_golden_rule=False, **{f'credit_{karat}k': grams})
    db.session.flush()


def _get(url, headers):
    g.pop('current_user', None)
    resp = flask_app.test_client().get(url, headers=headers)
    return resp.status_code, resp.get_json(silent=True) or {}


@pytest.fixture
def books():
    a, b = _account('ميزان أ'), _account('ميزان ب')
    _entry(D(2041, 5, 3, 10), a, b, 100.0)
    _entry(D(2041, 5, 31, 15, 30), a, b, 40.0)              # the period's last day, in the afternoon
    _entry(D(2041, 6, 1, 9), a, b, 7.0)                       # after it
    _entry(D(2041, 5, 10), a, b, 1000.0, draft=True)          # not counted
    _entry(D(2041, 5, 11), a, b, 2000.0, posted=False)        # not counted
    _entry(D(2041, 5, 12), a, b, 3000.0, deleted=True)        # not counted
    db.session.commit()                                        # a savepoint under the fence
    return a, b


def _row(body, account):
    return next(r for r in body['rows'] if r['account_id'] == account.id)


def test_a_period_s_trial_balance_answers_and_its_last_day_counts_whole(auth_headers, books):
    a, b = books
    code, body = _get('/api/trial_balance?start_date=2041-05-01&end_date=2041-05-31', auth_headers)
    assert code == 200, body
    assert _row(body, a)['cash_debit'] == pytest.approx(140.0), 'the 3rd and the 31st at 15:30, not June'
    assert _row(body, b)['cash_credit'] == pytest.approx(140.0)


def test_it_reads_the_lines_the_balances_count():
    from services.reports.trial_balance import trial_balance
    a = _account('ميزان ج')
    b = _account('ميزان د')
    _entry(D(2041, 7, 2), a, b, 5.0)
    _entry(D(2041, 7, 3), a, b, 50.0, draft=True)
    report = trial_balance(start=dt.date(2041, 7, 1), end=dt.date(2041, 7, 31), now=D(2041, 8, 1))
    row = next(r for r in report.rows if r['account_id'] == a.id)
    assert row['cash_debit'] == pytest.approx(5.0), 'a draft is not counted'


def test_it_says_the_reports_contract(auth_headers, books):
    a, _ = books
    code, body = _get('/api/trial_balance?start_date=2041-05-01&end_date=2041-05-31', auth_headers)
    assert code == 200, body
    assert body['id'] == 'trial_balance' and body['basis'] == 'posted_entries'
    assert body['period'] == {'start': '2041-05-01', 'end': '2041-05-31'}
    assert {c['key'] for c in body['columns']} >= {'account_number', 'account_name', 'cash_debit', 'cash_credit',
                                                  'gold_debit', 'gold_credit'}
    assert _row(body, a)['drill'] == {'kind': 'account', 'id': a.id}, 'every line opens its account'
    assert {c['key'] for c in body['columns'] if c['signed']} == {'cash_balance', 'gold_balance'}, 'balances, by sign'
    checks = {c['key']: c['ok'] for c in body['checks']}
    assert checks == {'cash_balanced': True, 'gold_balanced': True}
    assert body['read_at']
    # the old keys, until the screen reads the contract (REPORTS ت1)
    assert body['trial_balance'] == body['rows'] and body['count'] == len(body['rows'])


def test_the_karat_detail_keeps_each_karat():
    from services.reports.trial_balance import trial_balance
    a, b = _account('ميزان هـ'), _account('ميزان و')
    _entry(D(2041, 8, 2), a, b, 0.0, grams=3.5)
    report = trial_balance(start=dt.date(2041, 8, 1), end=dt.date(2041, 8, 31), karat_detail=True,
                           now=D(2041, 9, 1))
    row = next(r for r in report.rows if r['account_id'] == a.id)
    assert row['debit_21k'] == pytest.approx(3.5) and row['balance_21k'] == pytest.approx(3.5)


def test_a_bad_date_is_refused_by_name(auth_headers):
    code, body = _get('/api/trial_balance?end_date=31-05-2041', auth_headers)
    assert code == 400 and body.get('error') == 'invalid_date'


def test_its_totals_are_summed_whole_and_rounded_once():
    """On the 2 Nov copy October summed account by account, each step rounded
    to the milligram, came 0.002 g apart -- a period balanced in its entries
    said unbalanced -- the main karat's grams of other karats are not whole
    milligrams. Six credits of 0.001 g of 18 against one debit of 0.006 g:
    rounded at each step they part; summed whole, balanced."""
    from services.reports.trial_balance import trial_balance
    a = _account('ميزان ز')
    for i in range(6):
        _entry(D(2041, 9, 2 + i), a, _account(f'ميزان {i}'), 0.0, grams=0.001, karat=18)
    report = trial_balance(start=dt.date(2041, 9, 1), end=dt.date(2041, 9, 30), now=D(2041, 10, 1))
    assert {c.key: c.ok for c in report.checks}['gold_balanced'] is True


def test_under_an_account_it_is_that_subtree_and_its_twins_only(auth_headers):
    """The balance sheet's group opens the trial balance of its accounts (REPORTS
    ت2-1): under an account, its subtree and their weight twins -- nothing else."""
    from services.reports.trial_balance import trial_balance
    group = _account('مجموعة ميزان')
    twin = _account('توأم ميزان')
    child = Account(account_number=f'93{uuid.uuid4().int % 10**8:08d}', name='ابن ميزان', type='Asset',
                    parent_id=group.id, memo_account_id=twin.id)
    db.session.add(child)
    db.session.flush()
    outside = _account('خارج ميزان')
    _entry(D(2041, 10, 2), child, outside, 30.0)
    _entry(D(2041, 10, 3), twin, outside, 0.0, grams=1.0)
    report = trial_balance(end=dt.date(2041, 10, 31), under=group.id, now=D(2041, 11, 1))
    assert {r['account_id'] for r in report.rows} == {child.id, twin.id}
    code, body = _get(f'/api/trial_balance?end_date=2041-10-31&under={group.id}', auth_headers)
    assert code == 200 and {r['account_id'] for r in body['rows']} == {child.id, twin.id}
