"""CHART-002: the code asks for an account by its role, never by its number.

2027 opens with clean numbering (the owner, 12 Oct 2026: a child's number
begins with its parent's), in a new database run by the same code as the 2026
archive -- so no number may be written in the code. Measured 14 Oct 2026: 76
account numbers in 42 live files (253 places), 47 prefix searches in 19, the
repair tools beside them; and a fallback that stood a number or a name in for
every unmapped role (24k inventory fell back on 1200, the customers).

This ratchet holds each file at what it has: a new number, or a new file with
one, fails. Each CHART-002 release lowers the caps (core postings -> employees
and bonuses -> safes, scrap and repair tools -> reports and the screens) until
they are all zero. Migrations are history and may name numbers; tests too.
A literal counts when it is a number of the chart (3 digits or more) or a
prefix search ('2310%', startswith('21')).
"""
import ast
import json
import os
import re

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHART = os.path.join(os.path.dirname(BACKEND), 'docs', 'chart', 'chart-of-accounts-2027.json')
BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'account_number_baseline.json')
SKIP_DIRS = {'venv', 'tests', 'alembic', 'devtools', '__pycache__', '.pg_backups', 'node_modules'}


def _chart_numbers():
    def walk(node):
        if isinstance(node, dict):
            if 'account_number' in node:
                yield str(node['account_number'])
            for v in node.values():
                yield from walk(v)
        elif isinstance(node, list):
            for v in node:
                yield from walk(v)
    with open(CHART, encoding='utf-8') as fh:
        return {n for n in walk(json.load(fh)) if len(n) >= 3}


def count_by_file() -> dict:
    numbers = _chart_numbers()
    counts = {}
    for root, dirs, files in os.walk(BACKEND):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith('.')]
        for name in files:
            if not name.endswith('.py') or name.startswith('test_') or name == 'conftest.py':
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, BACKEND).replace(os.sep, '/')
            with open(path, encoding='utf-8') as fh:
                try:
                    tree = ast.parse(fh.read())
                except SyntaxError:
                    continue
            n = 0
            for node in ast.walk(tree):
                if isinstance(node, ast.Constant) and isinstance(node.value, str):
                    if node.value in numbers or re.fullmatch(r'\d{2,8}%', node.value):
                        n += 1
                elif (isinstance(node, ast.Call) and getattr(node.func, 'attr', '') == 'startswith'
                      and node.args and isinstance(node.args[0], ast.Constant)
                      and isinstance(node.args[0].value, str) and node.args[0].value.isdigit()):
                    n += 1
            if n:
                counts[rel] = n
    return counts


def test_no_new_account_number_in_the_code():
    with open(BASELINE, encoding='utf-8') as fh:
        caps = json.load(fh)
    over = {f: (n, caps.get(f, 0)) for f, n in count_by_file().items() if n > caps.get(f, 0)}
    assert not over, ('account numbers written in the code -- ask for the account by its role '
                      '(accounting.mappings): ' + ', '.join(f'{f}: {n} (cap {c})' for f, (n, c) in sorted(over.items())))
