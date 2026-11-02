"""His gold advance, taken from his salary in riyals at the closing price (PAY-GOLD; the owner, 2 Nov 2026).

The owner: «أ،ب معا» -- his gold advance is returned in gold by a weight
receipt voucher (as today), or taken from his salary in riyals; at «سعر
التسكير الآن» (the office's, the day paid), through «وسيط تسوية الذهب»: the
riyals to 1720, the grams from his weight account to 71720 -- riyals waiting
to become gold, read by the weight close as a sale is. The price is frozen on
his line; no more than he owes, of a karat he owes.

Run:
    python -m pytest tests/test_payroll_gold_advance.py -v
"""
import datetime as dt
import json
import uuid

import pytest

from models import Account, JournalEntry, Payroll, Voucher, VoucherAccountLine, db
from tests.test_payroll_run import _accounts, _call, _line, _run, staff  # noqa: F401 (fixture)

PAID = '2041-05-01'
OUNCE = 3000.0


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _account(prefix, name, kind, memo=None):
    account = Account(account_number=f'{prefix}{uuid.uuid4().int % 10**7:07d}', name=name, type=kind,
                      memo_account_id=memo)
    db.session.add(account)
    db.session.flush()
    return account


@pytest.fixture
def gold(staff):
    """He owes 10 g of 21k on his weight account; the clearing pair mapped; the office's price the day before."""
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
    from dual_system_helpers import create_dual_journal_entry
    from models import AccountingMapping, Employee, GoldPrice
    employee = db.session.get(Employee, staff['full'])
    personal = db.session.get(Account, employee.account_id) if employee.account_id else None
    if personal is None:
        personal = _account('96', f'ح/حساب الموظف {employee.name}', 'Asset')
        employee.account_id = personal.id
    if not personal.memo_account_id:
        personal.memo_account_id = _account('796', f'ح/حساب الموظف {employee.name} وزني', 'Asset').id
    clearing = _account('95', 'حساب وسيط تسوية الذهب', 'Asset',
                        memo=_account('795', 'حساب وسيط تسوية الذهب وزني', 'Asset').id)
    AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                      account_type='gold_settlement_clearing').delete()
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE,
                                     account_type='gold_settlement_clearing', account_id=clearing.id, is_active=True))
    scrap_box = _account('794', 'صندوق كسر اختبار وزني', 'Asset')
    advance = JournalEntry(date=dt.datetime(2041, 3, 1, 10), description='صرف سلفة ذهب', entry_type='سند صرف',
                           is_posted=True, posted_at=dt.datetime(2041, 3, 1, 10), posted_by='t', created_by='t')
    db.session.add(advance)
    db.session.flush()
    create_dual_journal_entry(journal_entry_id=advance.id, account_id=personal.memo_account_id, debit_21k=10.0,
                              apply_golden_rule=False)
    create_dual_journal_entry(journal_entry_id=advance.id, account_id=scrap_box.id, credit_21k=10.0,
                              apply_golden_rule=False)
    db.session.add(GoldPrice(price=OUNCE, date=dt.datetime(2041, 4, 30, 15)))
    db.session.add(GoldPrice(price=OUNCE, date=dt.datetime.now() - dt.timedelta(seconds=5)))   # the run's today
    db.session.commit()                                    # a savepoint under the fence
    return {'employee': employee, 'memo': personal.memo_account_id, 'clearing': clearing}


def _rate(karat):
    from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS
    return round(OUNCE / TROY_OZ_TO_GRAMS * SAR_USD_PEG * karat / 24.0, 4)


def _approved(headers):
    run = _run(headers)[1]
    _call('post', f"/api/payroll/runs/{run['id']}/approve", headers)
    return run


def _pay(headers, run, row):
    cash = _accounts(headers)[0]['id']
    lines = [{'payroll_id': e['id'], 'payment_account_id': cash} for e in run['entries']]
    full = next(l for l in lines if l['payroll_id'] == row['payroll_id'])
    full.update(row)
    return cash, _call('post', f"/api/payroll/runs/{run['id']}/pay", headers, {'lines': lines, 'paid_date': PAID})


def test_his_gold_advance_is_taken_in_riyals_at_the_closing_price_through_the_clearing(auth_headers, staff, gold):
    from services.payroll_advances import gold_balance
    run = _approved(auth_headers)
    view = _line(run, staff['full'])
    code, body = _call('get', f"/api/payroll/runs/{run['id']}", auth_headers)
    row = _line(body, staff['full'])
    assert row['gold_advance'] == {'21k': 10.0} and row['gold_rates']['21k'] == pytest.approx(_rate(21)), \
        'what he owes in gold, and its price per gram today -- the server\'s'

    amount = round(4 * _rate(21), 2)
    cash, (code, body) = _pay(auth_headers, run, {'payroll_id': view['id'], 'gold_deduction': {'karat': 21, 'grams': 4}})
    assert code == 200, body
    line = db.session.get(Payroll, view['id'])
    taken = json.loads(line.breakdown)['gold_deduction']
    assert taken == {'karat': 21, 'grams': 4.0, 'price': pytest.approx(_rate(21)), 'amount': amount}, \
        'frozen on his line: the grams, the price, the riyals'
    voucher = db.session.get(Voucher, line.voucher_id)
    legs = {(r.line_type, r.amount_type, r.account_id): r.amount
            for r in VoucherAccountLine.query.filter_by(voucher_id=voucher.id)}
    assert voucher.amount_cash == 8100.0, 'his whole: what left and what was taken'
    assert legs[('credit', 'cash', cash)] == pytest.approx(8100.0 - amount)
    assert legs[('credit', 'cash', gold['clearing'].id)] == amount, 'the riyals to the clearing'
    assert legs[('debit', 'gold', gold['clearing'].memo_account_id)] == 4.0, 'the grams to its weight twin'
    assert legs[('credit', 'gold', gold['memo'])] == 4.0, 'off his gold advance'
    assert gold_balance(gold['employee']) == {'21k': 6.0}


def test_no_more_than_he_owes_of_a_karat_he_owes(auth_headers, staff, gold):
    run = _approved(auth_headers)
    view = _line(run, staff['full'])
    for asked in ({'karat': 21, 'grams': 10.5}, {'karat': 18, 'grams': 1}):
        _, (code, body) = _pay(auth_headers, run, {'payroll_id': view['id'], 'gold_deduction': asked})
        assert (code, body.get('code')) == (409, 'gold_beyond_owed'), (asked, body)
    assert Payroll.query.filter(Payroll.payroll_run_id == run['id'], Payroll.voucher_id.isnot(None)).count() == 0


def test_the_weight_close_reads_it_as_a_sale_at_its_price(auth_headers, staff, gold):
    """Riyals in for grams gone: an opening at the price it was taken at --
    nothing expected at it; what the price does after is ⑤'s."""
    from pricing.gold_price_service import get_main_karat
    from services.weight_position import collect_events
    run = _approved(auth_headers)
    view = _line(run, staff['full'])
    assert _pay(auth_headers, run, {'payroll_id': view['id'], 'gold_deduction': {'karat': 21, 'grams': 4}})[1][0] == 200
    events = collect_events(dt.datetime(2041, 5, 1), dt.datetime(2041, 5, 31, 23, 59))
    (lot,) = [l for l in events.openings if l.ref.startswith('سلفة ذهب')]
    main = get_main_karat()
    assert lot.cash == round(4 * _rate(21), 2) and lot.grams == pytest.approx(4 * 21 / main, abs=1e-6)
    assert lot.price_at_sale == pytest.approx(_rate(main), abs=0.01)
