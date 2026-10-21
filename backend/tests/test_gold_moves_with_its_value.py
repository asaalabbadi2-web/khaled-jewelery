"""Gold crossing between the pools carries its value (ADR-042 phase 3, step 4; ت6).

The owner (21 Oct 2026): «اتفق مع توصياتك بجميع القرارات». From the day the
settings name, the gold an entry moves that no writer valued gets its value
(services/gold_cost_postings.value_the_gold):

  - between the pools, at the average of the pool it leaves: a melting (the
    worked's), a renewal (the scrap's), a supplier's worked gold for gold (the
    scrap's: the gold owed is paid from the scrap). Entering a short pool, the
    short is covered first and the difference said;
  - a melting's stones out to their expense, a renewal's in from their
    revenue: at the worked's average, on the riyal side of the role;
  - gold out to a party (an advance, a drawing) at its pool's average onto
    «ذهب لدى الأطراف»; back at the value it left with (step 5, the owner's
    decision 7); to an account of no known nature, refused by name.
With no day set, nothing is valued: 2026 posts as ever. The replay reads it.

Run:
    python -m pytest tests/test_gold_moves_with_its_value.py -v
"""
import uuid
from datetime import date, datetime

import pytest

from accounting.chart_tree import role_account_id
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from models import Account, AccountingMapping, JournalEntry, JournalEntryLine, Settings, Voucher, db
from services.gold_cost import pool_state, replay
from services.gold_cost_postings import GoldCostRefused, value_the_gold
from tests.test_gold_cost import _child, _entry, _role_twin
from tests.test_gold_cost import _account as _tree_account
from tests.test_melting_and_renewal_classify import _category, _post
from tests.test_melting_and_renewal_go_one_way import _account, _holds, _safe
from tests.test_supplier_purchase_stones import _post as _post_invoice, _purchase, supplier  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


def _from(day):
    Settings.query.first().gold_cost_from = day
    db.session.flush()


def _map(role, account):
    row = AccountingMapping.query.filter_by(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=role).first()
    if row is None:
        row = AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=role)
        db.session.add(row)
    row.account_id, row.is_active = account.id, True
    db.session.flush()
    return account


def _weight_child(root_role, name):
    """A weight account under a group's weight side -- an expense's, a revenue's."""
    account = _child(_role_twin(root_role), name)
    account.tracks_weight = True
    db.session.flush()
    return account


@pytest.fixture
def roles():
    return {
        'exchange': _map('gold_exchange_difference', _account('529', 'فروق تبادل', type='Expense')),
        'stones_out': _map('melting_stones_expense', _weight_child('operating_expenses_root', 'فصوص التكسير وزني')),
        'stones_in': _map('renewal_stones_revenue', _weight_child('revenue_root', 'إيراد فصوص التجديد وزني')),
    }


def _valued(name, value):
    """Give *name*'s pool *value* in all, whatever weight the test database holds."""
    stock = db.session.get(Account, role_account_id('gold_inventory_new' if name == 'worked' else 'gold_inventory_scrap'))
    dv = value - pool_state(name).value
    je = JournalEntry(entry_number=f'JE-GM-{uuid.uuid4().hex[:8]}', date=datetime(2026, 9, 2), description='قيمة',
                      entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    other = _child(_tree_account('1100'), 'مقابل GM')
    db.session.add_all([
        JournalEntryLine(journal_entry_id=je.id, account_id=stock.id, **({'cash_debit': dv} if dv > 0 else {'cash_credit': -dv})),
        JournalEntryLine(journal_entry_id=je.id, account_id=other.id, **({'cash_credit': dv} if dv > 0 else {'cash_debit': -dv})),
    ])
    db.session.flush()


def _cash(entry_id, account_id):
    return round(sum(float(l.cash_debit or 0) - float(l.cash_credit or 0) for l in JournalEntryLine.query.filter_by(
        journal_entry_id=entry_id, account_id=account_id, is_deleted=False)), 2)


def _voucher_entry(resp):
    assert resp.status_code == 201, resp.get_data(as_text=True)[:400]
    return db.session.get(Voucher, resp.get_json()['voucher']['id']).journal_entry_id


WORKED, SCRAP = (lambda: role_account_id('gold_inventory_new')), (lambda: role_account_id('gold_inventory_scrap'))


def _melting(src, dst, category, gold, stones):
    return {'operation_type': 'melting', 'from_safe_box_id': src.id, 'to_safe_box_id': dst.id,
            'lines': [{'karat': 21, 'gold_weight': gold, 'stones_weight': stones, 'category_id': category.id}]}


def test_with_no_day_set_a_melting_moves_no_value(auth_headers, roles):
    _from(None)
    sets, _ = _category('طقم', 21), _category('كسر', 21, scrap=True)
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 21, 40.0)
    entry = _voucher_entry(_post(auth_headers, _melting(src, dst, sets, 27.3, 6.7)))
    assert _cash(entry, WORKED()) == 0 and _cash(entry, SCRAP()) == 0


def test_a_melting_moves_its_value_at_the_worked_average_and_writes_off_its_stones(auth_headers, roles):
    _from(date(2026, 1, 1))
    sets, _ = _category('طقم', 21), _category('كسر', 21, scrap=True)
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 21, 40.0)
    _holds(dst, 21, 50.0 - min(pool_state('scrap').weight, 0.0))    # the scrap pool not short
    _valued('worked', pool_state('worked').weight * 500.0)          # the worked at 500 a gram
    _valued('scrap', pool_state('scrap').weight * 400.0)
    entry = _voucher_entry(_post(auth_headers, _melting(src, dst, sets, 27.3, 6.7)))
    assert _cash(entry, WORKED()) == pytest.approx(-(27.3 + 6.7) * 500.0)
    assert _cash(entry, SCRAP()) == pytest.approx(27.3 * 500.0), 'the gold at the worked average'
    assert _cash(entry, roles['stones_out'].id) == pytest.approx(6.7 * 500.0), 'the stones written off at it'


def test_a_renewal_moves_its_value_at_the_scrap_average_and_its_stones_are_gained(auth_headers, roles):
    _from(date(2026, 1, 1))
    sets, _ = _category('طقم', 21), _category('كسر', 21, scrap=True)
    src, dst = _safe('scrap'), _safe('showroom')
    _holds(src, 21, 30.0 - min(pool_state('scrap').weight, 0.0), stones=6.7)
    _holds(dst, 21, 50.0 - min(pool_state('worked').weight, 0.0))  # the worked pool not short
    _valued('scrap', pool_state('scrap').weight * 400.0)            # the scrap at 400 a gram
    _valued('worked', pool_state('worked').weight * 500.0)
    worked = pool_state('worked')
    body = {'operation_type': 'renewal', 'from_safe_box_id': src.id, 'to_safe_box_id': dst.id,
            'lines': [{'karat': 21, 'gold_weight': 27.3, 'stones_weight': 6.7, 'category_id': sets.id}]}
    entry = _voucher_entry(_post(auth_headers, body))
    assert _cash(entry, SCRAP()) == pytest.approx(-27.3 * 400.0), 'the gold at the scrap average'
    # the stones at the worked average once the renewed gold is in
    after_gold = (worked.value + 27.3 * 400.0) / (worked.weight + 27.3)
    assert _cash(entry, roles['stones_in'].id) == pytest.approx(-round(6.7 * after_gold, 2), abs=0.01)
    assert _cash(entry, WORKED()) == pytest.approx(27.3 * 400.0 + round(6.7 * after_gold, 2), abs=0.01)


def _crafted(lines):
    je = JournalEntry(entry_number=f'JE-GM-{uuid.uuid4().hex[:8]}', date=datetime(2026, 10, 21, 10),
                      description='اختبار', entry_type='عادي', is_posted=True, is_draft=False, created_by='t')
    db.session.add(je)
    db.session.flush()
    for account, cols in lines:
        db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, description='t', **cols))
    db.session.flush()
    return je


def _party_and_role():
    """An employee's gold account, on the assets' weight side (a party), and
    «ذهب لدى الأطراف» mapped."""
    _map('gold_with_parties', _account('175', 'ذهب لدى الأطراف (قيمة)', type='Asset'))
    return _weight_child('assets_root', 'موظف وزني GM')


def test_gold_out_to_a_party_leaves_at_the_pool_average_onto_gold_with_parties(roles):
    _from(date(2026, 1, 1))
    employee = _party_and_role()
    scrap = _safe('scrap')
    _holds(scrap, 21, 20.0 - min(pool_state('scrap').weight, 0.0))
    _valued('scrap', pool_state('scrap').weight * 400.0)
    je = _crafted([(db.session.get(Account, scrap.account_id), {'credit_21k': 5}), (employee, {'debit_21k': 5})])
    value_the_gold(je.id, description='سلفة ذهب')
    with_parties = AccountingMapping.query.filter_by(account_type='gold_with_parties').one().account_id
    assert _cash(je.id, with_parties) == pytest.approx(2000.0)
    assert _cash(je.id, SCRAP()) == pytest.approx(-2000.0)


def test_gold_back_from_a_party_comes_at_the_value_it_left_with(roles):
    _from(date(2026, 1, 1))
    employee = _party_and_role()
    scrap = _safe('scrap')
    scrap_account = db.session.get(Account, scrap.account_id)
    _holds(scrap, 21, 20.0 - min(pool_state('scrap').weight, 0.0))
    _valued('scrap', pool_state('scrap').weight * 400.0)
    out = _crafted([(scrap_account, {'credit_21k': 5}), (employee, {'debit_21k': 5})])
    value_the_gold(out.id, description='سلفة ذهب')                        # 5 g at 400: 2,000
    _valued('scrap', pool_state('scrap').weight * 450.0)                  # the scrap's average moves to 450
    back = _crafted([(scrap_account, {'debit_21k': 2}), (employee, {'credit_21k': 2})])
    value_the_gold(back.id, description='رد سلفة')
    with_parties = AccountingMapping.query.filter_by(account_type='gold_with_parties').one().account_id
    assert _cash(back.id, with_parties) == pytest.approx(-800.0), 'at 400, as it left -- not 450'
    assert _cash(back.id, SCRAP()) == pytest.approx(800.0)


def test_gold_back_from_a_party_that_was_given_none_is_refused(roles):
    _from(date(2026, 1, 1))
    employee = _party_and_role()
    scrap = _safe('scrap')
    _holds(scrap, 21, 20.0 - min(pool_state('scrap').weight, 0.0))
    _valued('scrap', pool_state('scrap').weight * 400.0)
    je = _crafted([(db.session.get(Account, scrap.account_id), {'debit_21k': 2}), (employee, {'credit_21k': 2})])
    with pytest.raises(GoldCostRefused) as refused:
        value_the_gold(je.id, description='ذهب من طرف')
    assert refused.value.code == 'gold_cost_party_has_no_valued_gold'


def test_gold_to_an_account_of_no_known_nature_is_refused(roles):
    _from(date(2026, 1, 1))
    scrap = _safe('scrap')
    _holds(scrap, 21, 10.0 - min(pool_state('scrap').weight, 0.0))
    _valued('scrap', pool_state('scrap').weight * 400.0)
    stray = _account('79', 'حساب وزني بلا مجموعة', type='Asset', tracks_weight=True)
    je = _crafted([(db.session.get(Account, scrap.account_id), {'credit_21k': 5}), (stray, {'debit_21k': 5})])
    with pytest.raises(GoldCostRefused) as refused:
        value_the_gold(je.id, description='؟')
    assert refused.value.code == 'gold_cost_counter_not_built'


def test_a_transfer_into_a_short_pool_covers_it_first(roles):
    _from(date(2026, 1, 1))
    showroom, scrap = _safe('showroom'), _safe('scrap')
    # the scrap 4 g short, at 100; the worked at 500
    _holds(showroom, 21, 10.0)
    s = pool_state('scrap')
    _crafted([(db.session.get(Account, scrap.account_id), {'credit_21k': s.weight + 4} if s.weight + 4 > 0
               else {'debit_21k': -(s.weight + 4)}), (_child(_tree_account('7139'), 'مقابل GM'), {})])
    _valued('scrap', -400.0)
    _valued('worked', pool_state('worked').weight * 500.0)
    assert pool_state('scrap').weight == pytest.approx(-4.0)
    # 10 g of worked gold back to the scrap (a melting, as a crafted entry): 4 cover the short
    je = _crafted([(db.session.get(Account, showroom.account_id), {'credit_21k': 10}),
                   (db.session.get(Account, scrap.account_id), {'debit_21k': 10})])
    written = value_the_gold(je.id, description='تحويل')
    assert written['transfer']['value'] == pytest.approx(5000.0)
    assert written['transfer']['difference'] == pytest.approx(4 * (500 - 100))
    assert _cash(je.id, roles['exchange'].id) == pytest.approx(1600.0)
    assert _cash(je.id, SCRAP()) == pytest.approx(3400.0)


def test_an_entry_its_writer_valued_is_left_as_it_is(roles):
    _from(date(2026, 1, 1))
    scrap = _safe('scrap')
    stock = db.session.get(Account, SCRAP())
    je = _crafted([(db.session.get(Account, scrap.account_id), {'debit_21k': 5}),
                   (_child(_tree_account('7512'), 'مشتريات وزني GM'), {'credit_21k': 5}),
                   (stock, {'cash_debit': 2000}), (_child(_tree_account('1100'), 'صندوق GM'), {'cash_credit': 2000})])
    assert value_the_gold(je.id, description='شراء') == {}
    assert _cash(je.id, SCRAP()) == pytest.approx(2000.0)


def test_the_replay_reads_a_melting_and_its_stones_as_they_are_written(roles):
    """In 2032, alone: 100 g worked at 500, 30 g scrap at 400; 34 g melted --
    27.3 g of gold to the scrap at 500, 6.7 g of stones written off at 500; then
    10 g across and 5 g bought in one entry. The ledger and the replay agree."""
    b = {'showroom': _safe('showroom'), 'scrap': _safe('scrap'),
         'twin': _child(_tree_account('7512'), 'مشتريات وزني 2032 GM'),
         'cash': _child(_tree_account('1100'), 'صندوق 2032 GM')}
    show, scr = (db.session.get(Account, b['showroom'].account_id), db.session.get(Account, b['scrap'].account_id))
    wv, sv = db.session.get(Account, WORKED()), db.session.get(Account, SCRAP())
    stones_riyal = roles['stones_out']          # a «both» account: its own riyal side
    _entry(1, [(show, {'debit_21k': 100}), (b['twin'], {'credit_21k': 100}),
               (wv, {'cash_debit': 50000}), (b['cash'], {'cash_credit': 50000})])
    _entry(2, [(scr, {'debit_21k': 30}), (b['twin'], {'credit_21k': 30}),
               (sv, {'cash_debit': 12000}), (b['cash'], {'cash_credit': 12000})])
    _entry(3, [(show, {'credit_21k': 34}), (scr, {'debit_21k': 27.3}), (roles['stones_out'], {'debit_21k': 6.7}),
               (wv, {'cash_credit': 17000}), (sv, {'cash_debit': 13650}), (stones_riyal, {'cash_debit': 3350})])
    # one entry crossing 10 g at the worked's 500 and buying 5 g of scrap for 2,000:
    # what the scrap's stock is written, less the crossing, is the price
    _entry(4, [(show, {'credit_21k': 10}), (scr, {'debit_21k': 15}), (b['twin'], {'credit_21k': 5}),
               (wv, {'cash_credit': 5000}), (sv, {'cash_debit': 7000}), (b['cash'], {'cash_credit': 2000})])

    r = replay(opening_price=0.0, since=date(2032, 1, 1), until=date(2032, 2, 1))
    assert r.others == []
    month = r.months['2032-01']
    assert (month.transfers_g, month.expense_g) == (pytest.approx(37.3), pytest.approx(-6.7))
    assert (month.purchases_g, month.purchases_value) == (pytest.approx(135), pytest.approx(64000))
    jan, feb = datetime(2032, 1, 1), datetime(2032, 2, 1)
    for name in ('worked', 'scrap'):
        a, z = pool_state(name, until=jan), pool_state(name, until=feb)
        assert z.weight - a.weight == pytest.approx(r.pools[name].weight), name
        assert z.value - a.value == pytest.approx(r.pools[name].value), name


def test_a_suppliers_worked_gold_enters_at_the_scrap_average(auth_headers, roles, supplier):
    """34 g received for gold: the gold owed is paid from the scrap, so the
    worked gold comes in at the scrap's average -- debit 1300, credit 1310."""
    from models import SafeBox
    stock = db.session.get(Account, WORKED())
    SafeBox.query.filter_by(account_id=stock.memo_account_id).first().stock_location = 'showroom'
    _from(date(2026, 1, 1))
    scrap = _safe('scrap')
    _holds(scrap, 21, 100.0 - min(pool_state('scrap').weight, 0.0))
    _valued('scrap', pool_state('scrap').weight * 400.0)
    body = _purchase(supplier, standing=34.0)
    body['items'][0]['karat'] = 21
    body['supplier_gold_lines'] = [{'karat': 21, 'weight': 34.0}]
    resp = _post_invoice(auth_headers, body)
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    entry = JournalEntry.query.filter_by(reference_type='invoice', reference_id=resp.get_json()['id']).first()
    assert _cash(entry.id, WORKED()) == pytest.approx(34 * 400.0)
    assert _cash(entry.id, SCRAP()) == pytest.approx(-34 * 400.0)


def test_the_replay_reads_a_partys_gold_out_and_back_as_it_is_written(roles):
    """In 2032, alone: 20 g of scrap at 400; 5 g out to an employee (2,000);
    10 g more bought at 500 (the average 433.33...); 2 g back -- at 400, as it
    left (800). The ledger and the replay agree."""
    _from(date(2026, 1, 1))
    employee = _party_and_role()
    with_parties = db.session.get(Account, AccountingMapping.query.filter_by(account_type='gold_with_parties')
                                  .one().account_id)
    b = {'scrap': _safe('scrap'), 'twin': _child(_tree_account('7512'), 'مشتريات وزني 2032 GP'),
         'cash': _child(_tree_account('1100'), 'صندوق 2032 GP')}
    scr, sv = db.session.get(Account, b['scrap'].account_id), db.session.get(Account, SCRAP())
    _entry(1, [(scr, {'debit_21k': 20}), (b['twin'], {'credit_21k': 20}),
               (sv, {'cash_debit': 8000}), (b['cash'], {'cash_credit': 8000})])
    _entry(2, [(scr, {'credit_21k': 5}), (employee, {'debit_21k': 5}),
               (with_parties, {'cash_debit': 2000}), (sv, {'cash_credit': 2000})])
    _entry(3, [(scr, {'debit_21k': 10}), (b['twin'], {'credit_21k': 10}),
               (sv, {'cash_debit': 5000}), (b['cash'], {'cash_credit': 5000})])
    _entry(4, [(scr, {'debit_21k': 2}), (employee, {'credit_21k': 2}),
               (sv, {'cash_debit': 800}), (with_parties, {'cash_credit': 800})])

    r = replay(opening_price=0.0, since=date(2032, 1, 1), until=date(2032, 2, 1))
    assert r.others == []
    assert r.months['2032-01'].receivables_value == pytest.approx(-2000 + 800)
    a, z = pool_state('scrap', until=datetime(2032, 1, 1)), pool_state('scrap', until=datetime(2032, 2, 1))
    assert (z.weight - a.weight, z.value - a.value) == (pytest.approx(r.pools['scrap'].weight),
                                                         pytest.approx(r.pools['scrap'].value))
    assert r.pools['scrap'].value == pytest.approx(8000 - 2000 + 5000 + 800)
