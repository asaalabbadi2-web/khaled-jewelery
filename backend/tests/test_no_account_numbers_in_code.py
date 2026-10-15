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
A literal counts when it is a number of the chart (3 digits or more), a
prefix search ('2310%', startswith('21')), or -- from CHART-002 release 5 --
any digit string compared with or searched in an account number, or held in
a constant named as a root, parent, number or prefix.
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


DIGITS = re.compile(r'^\d[\d.]*%?$')
LOOKUPS = {'like', 'ilike', 'notlike', 'in_', 'notin_', 'startswith', 'endswith'}
NAMED = re.compile(r'(ROOT|NUMBER|PARENT|ACCOUNT|PREFIX)', re.I)


def _digit_constants(node):
    """The digit strings in *node*: a constant, or a tuple/list/set of them."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str) and DIGITS.match(node.value):
        return [node]
    if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
        return [e for e in node.elts if isinstance(e, ast.Constant) and isinstance(e.value, str)
                and DIGITS.match(e.value)]
    return []


def _numbers_in(tree, source, numbers) -> set:
    """Each literal that names an account by its number, once: a number of the
    chart anywhere; a prefix search ('2310%', startswith('21')); and -- the
    gate saw neither until CHART-002 release 5 -- any digit string compared
    with, or searched in, an account number (== / filter_by / like / in_), or
    held in a constant named as a root, a parent, a number or a prefix (the
    groups '4', '51', '74' and numbers outside the 2027 chart: 5113, 71100...)."""
    found = set()

    def add(nodes):
        found.update((n.lineno, n.col_offset) for n in nodes)

    def mentions_number(expr):
        return any((isinstance(n, ast.Attribute) and 'account_number' in n.attr)
                   or (isinstance(n, ast.Name) and 'account_number' in n.id) for n in ast.walk(expr))

    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if node.value in numbers or re.fullmatch(r'\d{2,8}%', node.value):
                add([node])
        elif isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in LOOKUPS and node.args:
                if func.attr == 'startswith' or mentions_number(func.value):
                    for arg in node.args:
                        add(_digit_constants(arg))
            for kw in node.keywords:
                if kw.arg == 'account_number':
                    add(_digit_constants(kw.value))
        elif isinstance(node, ast.Compare):
            sides = [node.left, *node.comparators]
            if any(mentions_number(side) for side in sides):
                for side in sides:
                    add(_digit_constants(side))
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            names = [t.id for t in targets if isinstance(t, ast.Name)]
            if node.value is not None and any(NAMED.search(n) and n.isupper() for n in names):
                add(_digit_constants(node.value))
    return found


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
                source = fh.read()
            try:
                tree = ast.parse(source)
            except SyntaxError:
                continue
            n = len(_numbers_in(tree, source, numbers))
            if n:
                counts[rel] = n
    return counts


def test_no_new_account_number_in_the_code():
    with open(BASELINE, encoding='utf-8') as fh:
        caps = json.load(fh)
    over = {f: (n, caps.get(f, 0)) for f, n in count_by_file().items() if n > caps.get(f, 0)}
    assert not over, ('account numbers written in the code -- ask for the account by its role '
                      '(accounting.mappings): ' + ', '.join(f'{f}: {n} (cap {c})' for f, (n, c) in sorted(over.items())))
