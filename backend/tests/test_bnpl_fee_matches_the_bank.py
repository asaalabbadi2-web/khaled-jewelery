"""What Tamara and Tabby deduct is computed as the bank received it (ADR-100).

The owner, 24 Nov 2026: «تحقق من تطابق خصم تمارا وتابي وما هي الآلية». The
2026 Riyad Bank statement against the payments of the backup of 24 Nov:
- Tamara, 24 of its 25 deposits to the halala: each order its plan's rate
  (5.99 % or 6.99 %) and 1.50, its commission and VAT rounded on its own, half
  up. The plans the owner checked in Tamara's portal: 6 installments at 5.99 %,
  3 and 4 at 6.99 % -- and one 4 at 5.99 % (1,650 on 17 Sep, its deposit allows
  no other split): a plan does not decide its rate for sure; the deposit does.
- Tabby, «ليس من كل عملية بل من كل إيداع»: 6.99 % and 1.50 an order, and its
  «Payout fee» of 6.00 a deposit (its settlement reports of 26 Oct, 2 and 9
  Nov). It splits the rate into a refundable 4.99 % and a non-refundable 2 %,
  each rounded half to even, and the VAT on each part -- set on the method
  (commission_rounding, commission_refundable_rate), its deposits to the
  halala. Nothing here is a company's name: the owner, «اجعلها شاملة لمثل
  هكذا وسائل ويتم ضبطها في الإعدادات» -- the deposit's
  confirmation books the bank's.
The system took a flat 6.078 % on the settlement's total, rounded by round()
on a float: 290.94 of Tamara's and 348.59 of Tabby's commission never booked.

Run:
    python -m pytest tests/test_bnpl_fee_matches_the_bank.py -v
"""
from decimal import Decimal
from types import SimpleNamespace

import pytest

import accounting.payment_commission as pc

# (bank day, what reached the bank, [(order, its plan's rate)]) -- the Riyad
# Bank statement and the invoice payments of the backup of 24 Nov 2026.
TAMARA_DEPOSITS = [
    ('2026-03-10', 3858.94, [(2600, 5.99), (1000, 5.99), (550, 5.99)]),
    ('2026-03-24', 3288.97, [(2386, 5.99), (1150, 5.99)]),
    ('2026-04-21', 2536.77, [(800, 5.99), (950, 5.99), (980, 5.99)]),
    ('2026-05-05', 12447.97, [(380, 5.99), (1800, 5.99), (3000, 5.99), (2200, 5.99), (5000, 5.99), (1000, 5.99)]),
    ('2026-05-12', 8185.70, [(895, 5.99), (7900, 5.99)]),
    ('2026-05-31', 7679.97, [(8250, 5.99)]),
    ('2026-06-16', 9440.46, [(1400, 5.99), (950, 5.99), (1050, 5.99), (750, 5.99), (4900, 5.99), (1100, 5.99)]),
    ('2026-06-23', 5864.30, [(6300, 5.99)]),
    ('2026-06-30', 7121.30, [(7650, 5.99)]),
    ('2026-07-07', 16796.25, [(950, 6.99), (780, 6.99), (1000, 6.99), (15350, 5.99)]),
    ('2026-07-21', 2791.62, [(3000, 5.99)]),
    ('2026-07-28', 4645.78, [(3000, 5.99), (1050, 6.99), (970, 6.99)]),
    ('2026-08-04', 19001.50, [(1900, 6.99), (2568, 6.99), (16000, 5.99)]),
    ('2026-08-11', 12687.64, [(6000, 5.99), (7630, 5.99)]),
    ('2026-08-18', 2791.62, [(3000, 5.99)]),
    ('2026-09-01', 25171.66, [(1250, 6.99), (400, 6.99), (1550, 6.99), (1250, 6.99), (2650, 5.99), (20000, 5.99)]),
    ('2026-09-08', 9295.40, [(920, 6.99), (6700, 5.99), (2380, 5.99)]),
    ('2026-09-15', 35783.89, [(2850, 6.99), (14472, 5.99), (21150, 5.99)]),
    ('2026-09-22', 2634.69, [(650, 6.99), (1650, 5.99), (550, 6.99)]),
    ('2026-09-29', 3351.40, [(2000, 6.99), (1300, 6.99), (350, 6.99)]),
    ('2026-10-06', 18525.74, [(13400, 5.99), (6500, 5.99)]),
    ('2026-10-13', 12771.45, [(4320, 5.99), (9400, 5.99)]),
    ('2026-11-03', 26280.50, [(1146, 6.99), (1246, 6.99), (370, 6.99), (12300, 5.99), (10000, 5.99),
                              (250, 6.99), (3000, 6.99)]),
    ('2026-11-10', 16946.79, [(1456, 6.99), (1970, 6.99), (1178, 5.99), (8900, 5.99), (1550, 6.99),
                              (500, 6.99), (865, 6.99), (350, 6.99), (1550, 6.99)]),
]

# Tabby's deposits, from its settlement reports: 6.99 % and 1.50 an order,
# 6.00 a payout, its two parts of the rate rounded half to even.
TABBY_DEPOSITS = [
    ('2026-10-26', 10979.07, [2150, 9800]),
    ('2026-11-03', 32176.19, [25000, 10000]),
    ('2026-11-09', 19724.94, [316, 10200, 3000, 3400, 4550]),
]


@pytest.fixture(autouse=True)
def vat_at_fifteen(monkeypatch):
    """The bank's VAT, whatever the test database's settings say."""
    monkeypatch.setattr(pc, '_vat_rate', lambda: Decimal('0.15'))


def _tamara(**kw):
    return SimpleNamespace(name='تمارا', commission_rate=6.078, commission_fixed_amount=1.5,
                           deposit_fixed_fee=0.0, commission_per_order=True, plans=[], **kw)


def _tabby():
    return SimpleNamespace(name='تابي', commission_rate=6.99, commission_fixed_amount=1.5,
                           deposit_fixed_fee=6.0, commission_per_order=True, plans=[],
                           commission_rounding='half_even', commission_refundable_rate=4.99)


@pytest.mark.parametrize('day,bank,orders', TAMARA_DEPOSITS, ids=[d for d, _, _ in TAMARA_DEPOSITS])
def test_a_tamara_deposit_is_its_orders_each_by_its_plan_to_the_halala(day, bank, orders):
    assert pc.settlement_net(_tamara(), orders) == pytest.approx(bank, abs=0.001)


@pytest.mark.parametrize('day,bank,orders', TABBY_DEPOSITS, ids=[d for d, _, _ in TABBY_DEPOSITS])
def test_a_tabby_deposit_is_its_orders_and_its_fee_a_deposit(day, bank, orders):
    net = pc.settlement_net(_tabby(), [(a, None) for a in orders])
    assert net == pytest.approx(bank, abs=0.001)


def test_the_fee_a_deposit_is_taken_once_however_many_its_orders():
    pm = _tabby()
    one, _ = pc.settlement_commission(pm, [(1000, None)])
    five, _ = pc.settlement_commission(pm, [(200, None)] * 5)
    assert one == pytest.approx(69.90 + 1.50 + 6.00)
    assert five == pytest.approx(5 * (13.98 + 1.50) + 6.00)


def test_half_up_not_a_float_round():
    """2,850 at 6.99 % and 1.50 is 200.715: the bank took 200.72."""
    fee = pc.payment_commission(_tamara(), 2850, rate=6.99)
    assert fee['commission_amount'] == 200.72
    assert fee['commission_vat'] == 30.11


def test_a_method_on_its_total_is_one_commission_as_before():
    """Mada: one fee on the settlement's total, as the bank's line says it."""
    mada = SimpleNamespace(name='مدى', commission_rate=0.8, commission_fixed_amount=0.0,
                           deposit_fixed_fee=0.0, commission_per_order=False, plans=[])
    fee, vat = pc.settlement_commission(mada, [(23645.00 - 1000, None), (1000, None)])
    assert fee == 189.16 and vat == 28.37
    assert pc.settlement_net(mada, [(23645.00, None)]) == pytest.approx(23427.47, abs=0.001)


# ── the plan a payment names (law) ───────────────────────────────────────────

def _with_plans():
    plans = [SimpleNamespace(installments=n, commission_rate=r)
             for n, r in ((2, 6.99), (3, 6.99), (4, 6.99), (6, 5.99), (9, 5.99), (12, 5.99))]
    return _tamara(), plans


def test_a_payment_by_a_method_with_plans_names_one_of_them():
    pm, plans = _with_plans()
    pm.plans = plans
    with pytest.raises(pc.PlanRefused) as missing:
        pc.payment_commission(pm, 1000)
    assert missing.value.code == 'installments_required'
    with pytest.raises(pc.PlanRefused) as unknown:
        pc.payment_commission(pm, 1000, installments=5)
    assert unknown.value.code == 'installments_unknown'
    six = pc.payment_commission(pm, 1000, installments=6)
    assert (six['installments'], six['commission_rate'], six['commission_amount']) == (6, 5.99, 61.40)
    four = pc.payment_commission(pm, 1000, installments=4)
    assert (four['commission_rate'], four['commission_amount']) == (6.99, 71.40)


def test_a_method_without_plans_takes_its_rate_and_keeps_no_plan():
    fee = pc.payment_commission(_tabby(), 1000, installments=4)
    assert fee['installments'] is None and fee['commission_rate'] == 6.99


def test_a_kept_rate_is_not_re_priced():
    """A plan changed later re-prices nothing paid: the payment's kept rate."""
    pm, plans = _with_plans()
    pm.plans = plans
    assert pc.payment_commission(pm, 1000, rate=5.99)['commission_amount'] == 61.40


def test_a_return_refunded_by_the_method_names_no_plan():
    """A sale names its plan; a return takes the method's rate, as before --
    its fee on a return is not known (Known Gaps, ADR-100)."""
    pm, plans = _with_plans()
    pm.plans = plans
    fee = pc.payment_commission(pm, 1000, required=False)
    assert fee['installments'] is None and fee['commission_rate'] == 6.078
    assert pc.payment_commission(pm, 1000, installments=6, required=False)['commission_rate'] == 5.99


def test_its_report_line_by_line():
    """Tabby's report of 26 Oct: 2,150 -- 107.28 + 43 + 1.50 = 151.78, VAT 22.76."""
    fee = pc.payment_commission(_tabby(), 2150)
    assert (fee['commission_amount'], fee['commission_vat']) == (151.78, 22.76)
    fee = pc.payment_commission(_tabby(), 25000)
    assert (fee['commission_amount'], fee['commission_vat']) == (1749.00, 262.34)


def test_no_companys_name_decides_a_commission():
    """The rules are a method's settings, not its name (the owner, 24 Nov 2026)."""
    import ast
    import pathlib
    backend = pathlib.Path(__file__).resolve().parents[1]
    for rel in ('accounting/payment_commission.py', 'clearing_settlement_scheduler.py',
                'services/clearing_deposit.py', 'alembic/versions/20261124_bnpl_plans.py',
                'services/commission_tax_invoice.py', 'alembic/versions/20261125_commission_tax_invoice.py'):
        tree = ast.parse((backend / rel).read_text())
        docstrings = {id(n.body[0].value) for n in ast.walk(tree)
                      if isinstance(n, (ast.Module, ast.FunctionDef, ast.ClassDef)) and n.body
                      and isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant)}
        named = [n.value for n in ast.walk(tree)
                 if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in docstrings
                 and any(w in n.value.lower() for w in ('tamara', 'tabby', 'تمارا', 'تابي'))]
        assert not named, f'{rel} decides by a name: {named}'


def test_a_plan_is_said_as_arabic_counts_it():
    """The owner, 24 Nov 2026: «12 دفعة وليس 12 دفعات»; the plan read on the terminal."""
    assert [pc.installments_label(n) for n in (1, 2, 3, 10, 11, 12)] == [
        'دفعة واحدة', 'دفعتان', '3 دفعات', '10 دفعات', '11 دفعة', '12 دفعة']
    pm, plans = _with_plans()
    pm.plans = plans
    with pytest.raises(pc.PlanRefused) as refused:
        pc.payment_commission(pm, 1000)
    assert '12 دفعة' in refused.value.message and '12 دفعات' not in refused.value.message
    assert 'جهاز الدفع' in refused.value.message
