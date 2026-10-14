"""NAMES-1: every name the server's code uses is defined, and no code hides after a return.

The routes migration (July 2026) left names behind: `case`, `Item`, `String`,
`AccountingMapping` and more were used in modules that no longer imported them.
Python finds out only when the line runs -- so seven reports answered 500 for
three months («نظرة عامة على المبيعات», the sales by customer and by item, the
analytics summary, the customer aging, the bridge accounts monitor, the gold
trial balance by safe), the invoice creator's change was never audited, and the
stock value on the admin dashboard was always empty. Found walking the stock
screens (14 Oct 2026).

Two checks over the live code (everything in backend/ but venv and tests):
  1. pyflakes finds no undefined name, beyond ALLOWED;
  2. no statement follows a return/raise/continue/break in the same block --
     dead code there is not harmless: an import in it makes the name local to
     the whole function (the customer aging failed on `datetime` that way).
"""
import ast
import os

from pyflakes import api as pyflakes_api
from pyflakes import messages as pyflakes_messages

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {'venv', 'tests', '__pycache__', '.pg_backups', 'node_modules'}

# (file, name) -> why it stays undefined; an entry that no longer occurs fails
# the test. Empty: the transactions reset works again on copies now that the
# production lock is a law (RESET-1).
ALLOWED = {}


def _live_files():
    for root, dirs, files in os.walk(BACKEND):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith('.')]
        for name in files:
            if name.endswith('.py') and not name.startswith('test_') and name != 'conftest.py':
                path = os.path.join(root, name)
                yield os.path.relpath(path, BACKEND).replace(os.sep, '/'), path


class _Collect:
    def __init__(self):
        self.messages = []

    def flake(self, message):
        self.messages.append(message)

    def unexpectedError(self, filename, msg):
        self.messages.append(('error', filename, msg))

    def syntaxError(self, filename, msg, lineno, offset, text):
        self.messages.append(('syntax', filename, msg, lineno))


def test_every_name_is_defined():
    found = {}
    errors = []
    for rel, path in _live_files():
        with open(path, encoding='utf-8') as fh:
            source = fh.read()
        report = _Collect()
        pyflakes_api.check(source, rel, report)
        for m in report.messages:
            if isinstance(m, tuple):
                errors.append(m)
            elif isinstance(m, pyflakes_messages.UndefinedName):
                found.setdefault((rel, m.message_args[0]), []).append(m.lineno)
    assert not errors, errors
    unexpected = {k: v for k, v in found.items() if k not in ALLOWED}
    assert not unexpected, 'undefined names: ' + '; '.join(
        f'{f}:{lines} {n}' for (f, n), lines in sorted(unexpected.items()))
    stale = [k for k in ALLOWED if k not in found]
    assert not stale, f'allowed but no longer undefined -- remove from ALLOWED: {stale}'


def test_no_code_after_return():
    dead = []
    for rel, path in _live_files():
        with open(path, encoding='utf-8') as fh:
            tree = ast.parse(fh.read(), rel)
        for node in ast.walk(tree):
            for field in ('body', 'orelse', 'finalbody'):
                block = getattr(node, field, None)
                if not isinstance(block, list):
                    continue
                for stmt, nxt in zip(block, block[1:]):
                    if isinstance(stmt, (ast.Return, ast.Raise, ast.Continue, ast.Break)):
                        dead.append(f'{rel}:{nxt.lineno}')
                        break
    assert not dead, 'unreachable code after return/raise: ' + ', '.join(dead)
