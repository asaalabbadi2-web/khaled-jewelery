"""The 2027 database's chart and roles (ADR-044 phase 4, TR-1a).

The template in 2027's approved numbers, each parent and twin by its new
number; the ten accounts the owner kept on 6 Nov in it, the eight he left
out of it; each 2026 role on its account's 2027 number, and a role whose
account 2027 has not said by name. A database that holds an account is not
built into. The whole build runs on an empty database in its rehearsal
(docs/plans/fy2027-transition-tool-discovery.md).

Run:
    python -m pytest tests/test_transition_2027_chart.py -v
"""
import pytest

from services.transition_2027 import TransitionRefused, build_chart_and_roles, chart_rows, numbering, role_rows

LENGTH = {1: 1, 2: 2, 3: 3, 4: 5, 5: 8}
KEPT = ('1330', '290', '450', '460', '5260', '5403', '270', '280', '5404', '5440001')
LEFT = ('370', '2210', '2200000', '2200002', '2200003', '2320000', '1730001', '350')


def test_the_chart_is_the_template_in_2027_numbers():
    rows = chart_rows()
    by = {r['account_number']: r for r in rows}
    assert len(by) == len(rows) == 222
    for r in rows:
        parent = r.get('parent_account_number')
        if parent:
            assert r['account_number'].startswith(parent), r
        twin = r.get('memo_account_number')
        if twin and r['transaction_type'] != 'gold':
            assert twin == '7' + r['account_number'] and by[twin]['memo_account_number'] == r['account_number']
    financial = [r for r in rows if r['transaction_type'] != 'gold']
    assert {len(r['account_number']) for r in financial} <= set(LENGTH.values())


def test_the_ten_kept_are_in_it_and_the_eight_left_are_not():
    new = numbering()
    numbers = {r['account_number'] for r in chart_rows()}
    assert all(new[old] in numbers for old in KEPT)
    assert not any(old in new for old in LEFT)


def test_a_role_goes_to_its_account_s_2027_number_or_is_said():
    new = numbering()
    rows, unmapped = role_rows([('افتراضي', 'salary_expense', '5410', True),
                                ('افتراضي', 'supplier_karat_conversion', '7290', True),
                                ('افتراضي', 'old_role', '370', True)])
    assert rows == [('افتراضي', 'salary_expense', new['5410'], True),
                    ('افتراضي', 'supplier_karat_conversion', new['7290'], True)]
    assert unmapped == [('افتراضي', 'old_role', '370')]


def test_a_database_with_a_chart_is_not_built_into(app, db_fence):
    with pytest.raises(TransitionRefused, match='ليست فارغة'):
        build_chart_and_roles(source_engine=None)
