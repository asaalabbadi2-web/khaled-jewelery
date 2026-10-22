"""2027's approved numbering holds its rule (CHART-002; the owner, 22 Oct 2026: «اعتمد»).

docs/chart/numbering-2027.json is the table the transition applies
(ADR-044). It must be what its generator makes from the template, and the
rule must hold: every template account numbered once, no number twice, a
level's number its fixed length (1, 2, 3, 5, 8 digits), a child's number
beginning with its parent's, a weight twin 7 + its financial number.

Run:
    python -m pytest tests/test_numbering_2027.py -v
"""
import json

from accounting.twins import twin_number
from tools.chart.numbering_2027 import TABLE, TEMPLATE, is_weight, numbering

LENGTH = {1: 1, 2: 2, 3: 3, 4: 5, 5: 8}


def _load():
    with open(TEMPLATE, encoding='utf-8') as fh:
        template = json.load(fh)
    with open(TABLE, encoding='utf-8') as fh:
        table = json.load(fh)['old_to_new']
    return template, table


def test_the_approved_table_is_its_generators():
    template, table = _load()
    assert table == numbering(template)


def test_every_account_once_and_no_number_twice():
    template, table = _load()
    assert set(table) == {a['account_number'] for a in template['accounts']}
    assert len(set(table.values())) == len(table)


def test_a_childs_number_begins_with_its_parents_and_a_level_has_its_length():
    template, table = _load()
    by = {a['account_number']: a for a in template['accounts']}
    for a in template['accounts']:
        old = a['account_number']
        parent = a.get('parent_account_number')
        if parent:
            assert table[old].startswith(table[parent]), (old, table[old], table[parent])
        if not is_weight(a):
            level, node = 1, a
            while node.get('parent_account_number'):
                level, node = level + 1, by[node['parent_account_number']]
            assert len(table[old]) == LENGTH[level], (old, table[old], level)


def test_a_twin_is_seven_and_its_financial_number():
    template, table = _load()
    for a in template['accounts']:
        twin = a.get('memo_account_number')
        if twin and not is_weight(a):
            assert table[twin] == twin_number(table[a['account_number']]), (a['account_number'], twin)
