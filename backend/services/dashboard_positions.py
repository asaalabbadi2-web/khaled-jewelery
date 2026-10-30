"""What is ours and what we owe, for the manager's dashboard (DASH-4).

The owner, 30 Oct 2026 (agreeing to all advised): the dashboard said the
customers' cash we are owed and nothing else. One reading, by the ledger's own
readers -- the parties' live balances (BALANCE-001) and the offices' deposits
(ADR-052) -- in cash and in main-karat grams:

  customers  what they owe us, and what we owe them (their gold we hold)
  suppliers  what we owe them, and what they owe us
  offices    our gold at them
"""
from __future__ import annotations

KARATS = (18, 21, 22, 24)


def _side(balances: dict) -> dict:
    """{owe_us_cash, we_owe_cash, owe_us_gold, we_owe_gold, owe_us_count, we_owe_count}
    from {party: {'cash', '18k', ...}} -- debit balances ours, credit theirs."""
    from pricing.karat_service import convert_to_main_karat
    out = {'owe_us_cash': 0.0, 'we_owe_cash': 0.0, 'owe_us_gold': 0.0, 'we_owe_gold': 0.0,
           'owe_us_count': 0, 'we_owe_count': 0}
    for bal in balances.values():
        cash = float(bal.get('cash') or 0.0)
        grams = sum(convert_to_main_karat(float(bal.get(f'{k}k') or 0.0), k) for k in KARATS)
        if cash > 0.005:
            out['owe_us_cash'] += cash
        elif cash < -0.005:
            out['we_owe_cash'] -= cash
        if grams > 0.0005:
            out['owe_us_gold'] += grams
        elif grams < -0.0005:
            out['we_owe_gold'] -= grams
        if cash > 0.005 or grams > 0.0005:
            out['owe_us_count'] += 1
        if cash < -0.005 or grams < -0.0005:
            out['we_owe_count'] += 1
    return {k: (round(v, 3) if 'gold' in k else round(v, 2) if 'cash' in k else v) for k, v in out.items()}


def positions() -> dict:
    from models import Customer, Supplier
    from offices_routes import _deposits_by_supplier
    from services.party_live_balances import compute_live_customer_balances, compute_live_supplier_balances
    suppliers = Supplier.query.all()
    customers = Customer.query.all()
    deposits = _deposits_by_supplier(suppliers)
    offices = sorted(({'name': d['name'], 'grams': d['main_karat_total']} for d in deposits.values()
                      if abs(d['main_karat_total']) >= 0.0005), key=lambda o: -o['grams'])
    return {
        'customers': _side(compute_live_customer_balances(customers) if customers else {}),
        'suppliers': _side(compute_live_supplier_balances(suppliers) if suppliers else {}),
        'offices_gold': round(sum(o['grams'] for o in offices), 3),
        'offices': offices,
    }
