"""Every `from <local module> import <name>` in the backend names something that exists.

The July 2026 routes migration (c1195c4 .. 0232533) moved functions out of the
`routes` package. Imports made at module level broke loudly and were fixed the
same day. Imports made INSIDE a function -- lazily, to dodge a circular import --
only fail when that function runs, and nothing ran them:

- backup_scheduler.py imported _create_sqlite_backup_to_file from `routes`:
  every scheduled backup since has raised ImportError, been caught, and
  printed one log line (BACKUP-001).
- posting_routes.post_invoice imported the karat-difference and 24k settlement
  entry builders from `routes`: posting has silently skipped those entries
  ever since (invoice 3020: a 307.37 commission never recorded).

This test imports every local module named in a `from ... import ...` anywhere
in the backend -- at module level or inside a function -- and checks that each
imported name is there. A function moved tomorrow is caught the day it moves.

Run:
    python -m pytest tests/test_local_imports_resolve.py -v
"""
import ast
import importlib
import os
import pathlib

import pytest

BACKEND = pathlib.Path(__file__).resolve().parents[1]
SKIP_DIRS = {'venv', '.venv', '__pycache__', '.pytest_db', 'node_modules', 'migrations', '_archived', 'devtools'}

# (file, imported name) -> why it is allowed to stay broken.
KNOWN_BROKEN = {
    ('tools/maintenance/fix_voucher_safebox_transactions_and_posting.py', '_is_manual_like_journal_entry'):
        'retired: a data-mutating repair script, broken since the July migration; '
        'not revived without review (the UNPOST-001 / REPAIR-001 class of writer)',
    ('tools/migration/setup_mappings_simple.py', 'Config'):
        'retired: an old setup script for a config class that no longer exists',
    ('test_settings_singleton.py', 'create_app'):
        'dead: defined inside another test function, so pytest never collects it',
}


def _local_top_level():
    names = {p.stem for p in BACKEND.glob('*.py')}
    names |= {p.name for p in BACKEND.iterdir() if p.is_dir() and (p / '__init__.py').exists()}
    return names


def unresolved_imports():
    """[(relative file, line, module, name)] for imported names that do not exist."""
    local = _local_top_level()
    found = []
    for root, dirs, files in os.walk(BACKEND):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if not name.endswith('.py'):
                continue
            path = pathlib.Path(root) / name
            try:
                tree = ast.parse(path.read_text(encoding='utf-8', errors='ignore'))
            except SyntaxError:
                continue
            rel = str(path.relative_to(BACKEND))
            for node in ast.walk(tree):
                if not isinstance(node, ast.ImportFrom) or node.level or not node.module:
                    continue
                if node.module.split('.')[0] not in local:
                    continue
                try:
                    module = importlib.import_module(node.module)
                except Exception:
                    found.append((rel, node.lineno, node.module, '*'))
                    continue
                for alias in node.names:
                    if alias.name == '*' or hasattr(module, alias.name):
                        continue
                    try:
                        importlib.import_module(f'{node.module}.{alias.name}')
                    except Exception:
                        found.append((rel, node.lineno, node.module, alias.name))
    return found


def test_every_imported_name_exists(app_context):
    broken = [f'{rel}:{line}  from {mod} import {name}'
              for rel, line, mod, name in unresolved_imports() if (rel, name) not in KNOWN_BROKEN]
    assert broken == [], (
        'imports that fail when they run -- point them at where the name lives now:\n  '
        + '\n  '.join(broken))


def test_the_known_broken_list_has_no_stale_entries(app_context):
    still = {(rel, name) for rel, _line, _mod, name in unresolved_imports()}
    stale = sorted(k for k in KNOWN_BROKEN if k not in still)
    assert stale == [], f'entries that now resolve (or are gone) -- remove them: {stale}'


@pytest.fixture
def app_context():
    """Boot once, as the application does, before importing its modules."""
    from app import app
    with app.app_context():
        yield
