"""Lazurde's VAT paid in gold leaves the dealings ledger (ADR-089, the owner 12 Nov 2026).

The 163.1 g bought for Lazurde's wages (PV-2026-00847) paid 141.82 g of
wages -- the Riyadh partners' -- and 21.28 g of VAT, which the opening repair
left in «دفتر التعامل الوزني» until the VAT work. The laws:
  - what moves is what the opening repair left: the ledger's 974.10 g less
    what it moved out of it (200 + 416 + 336.82);
  - it moves to the scrap purchases' weight twin, where its riyals are, so
    neither profit moves: no profit account is named, and the entry balances
    karat by karat;
  - the tool expects the ledger at exactly that, and leaves it at zero.

Run:
    python -m pytest tests/test_lazurde_vat_gold.py -v
"""
import json
import os

REPAIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'services', 'repair')


def _load(name):
    with open(os.path.join(REPAIR, name), encoding='utf-8') as fh:
        return json.load(fh)


def test_what_moves_is_what_the_opening_repair_left_in_the_ledger():
    opening, lz = _load('opening_2026.json'), _load('lazurde_vat_gold.json')
    moved_out = sum(float((line.get('cr') or {}).get('21k', 0)) for e in opening['entries'] for line in e['lines']
                    if line['account'] == 'dealings_w')
    left = round(opening['expect_before']['dealings_w']['21k'] - moved_out, 2)
    assert left == opening['expect_after']['dealings_w']['21k'] == 21.28
    (entry,) = lz['entries']
    debit = sum(float((l.get('dr') or {}).get('21k', 0)) for l in entry['lines'])
    credit = sum(float((l.get('cr') or {}).get('21k', 0)) for l in entry['lines'] if l['account'] == 'dealings_w')
    assert round(debit, 2) == round(credit, 2) == left
    assert lz['expect_before']['dealings_w']['21k'] == left
    assert all(v == 0.0 for v in lz['expect_after']['dealings_w'].values())


def test_neither_profit_moves_and_each_karat_balances():
    lz = _load('lazurde_vat_gold.json')
    assert lz['profit_accounts'] == [] and lz['expect_profit_change'] == 0.0
    assert lz['accounts']['scrap_purchases_w']['name'].endswith('وزني'), 'a weight twin: no riyals move'
    for entry in lz['entries']:
        for col in ('cash', '18k', '21k', '22k', '24k'):
            dr = sum(float((l.get('dr') or {}).get(col, 0)) for l in entry['lines'])
            cr = sum(float((l.get('cr') or {}).get(col, 0)) for l in entry['lines'])
            assert abs(dr - cr) < 0.0005, (entry['key'], col)
        assert entry['date'] == '2026-07-31', 'the day it was given (PV-2026-00847)'
