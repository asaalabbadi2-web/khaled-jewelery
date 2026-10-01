"""Who may change a posted state: the writers of 1 Oct 2026, frozen (UNPOST-001 U4).

The owner's decision (option 1): the list of the code that changes `is_posted`
on an existing record -- an entry or an invoice -- is frozen here. A new
writer fails this test until it is added to WRITERS on purpose, in review; a
writer that goes must leave the list too, so the list only shrinks. Nothing
is refused at run time: journal_entry_guard holds invoices' and vouchers'
entries already (ADR-035); this holds everything else from growing unseen.

What counts as a write: `x.is_posted = ...`, `setattr(x, 'is_posted', ...)`,
`.update({'is_posted': ...})`, and SQL text that sets is_posted. A record born
posted -- `JournalEntry(..., is_posted=True)` -- is a birth, not a change, and
is not counted. Tests and migrations are not counted.

Run:
    python -m pytest tests/test_posting_writers_ratchet.py -v
"""
import ast
import re
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'tests', 'venv', 'alembic', 'migrations', '_archived', 'graphify-out', 'backups',
             '__pycache__', 'instance', 'temp_pdfs'}
SQL_WRITE = re.compile(r'\bUPDATE\b.*\bSET\b.*\bis_posted\b', re.IGNORECASE | re.DOTALL)

# file::function -> how many writes it holds. Frozen 2026-10-01.
WRITERS = {
    # the sanctioned operations
    'posting_routes.py::post_invoice_document': 1,
    'posting_routes.py::post_invoice_document._post_entry': 1,
    'posting_routes.py::unpost_invoice_document': 2,
    'posting_routes.py::approve_voucher': 2,
    'posting_routes.py::approve_vouchers_batch': 1,
    'posting_routes.py::post_journal_entry': 1,
    'posting_routes.py::post_journal_entries_batch': 1,
    'posting_routes.py::unpost_journal_entry': 1,
    'posting_routes.py::unpost_journal_entries_batch': 1,
    'routes/invoices.py::add_invoice': 6,
    'routes/invoices.py::reject_invoice': 1,
    'routes/journals.py::add_journal_entry': 1,
    'routes/journals.py::delete_journal_entry': 1,
    'routes/journals.py::soft_delete_journal_entry': 1,
    'routes/vouchers.py::approve_voucher': 2,
    'routes/vouchers.py::create_voucher': 1,
    'accounting/voucher_engine.py::create_journal_entry_from_voucher': 1,
    'accounting/voucher_engine.py::post_entry_of_approved_voucher': 1,
    'services/supplier_settlement_adjustment_service.py::SupplierSettlementAdjustmentService._build_and_post_voucher': 1,
    # repair tools -- for REPAIR-001 (stage 4), not grown meanwhile
    'posting_routes.py::sync_orphan_journal_entries': 2,
    'routes/safe_boxes.py::repair_safe_box_transactions': 1,
    'devtools/post_unposted_imported_invoices.py::main': 2,
    'devtools/repair_safebox_transactions.py::run': 1,
    'tools/maintenance/fix_production_je.py::diagnose': 1,
}


def _writes(tree):
    out = []

    def walk(node, scope):
        for child in ast.iter_child_nodes(node):
            inner = scope
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                inner = f'{scope}.{child.name}' if scope else child.name
            here = inner or '<module>'
            if isinstance(child, (ast.Assign, ast.AugAssign, ast.AnnAssign)):
                targets = child.targets if isinstance(child, ast.Assign) else [child.target]
                if any(isinstance(t, ast.Attribute) and t.attr == 'is_posted' for t in targets):
                    out.append(here)
            elif isinstance(child, ast.Call):
                f = child.func
                if (isinstance(f, ast.Name) and f.id == 'setattr' and len(child.args) > 1
                        and isinstance(child.args[1], ast.Constant) and child.args[1].value == 'is_posted'):
                    out.append(here)
                elif (isinstance(f, ast.Attribute) and f.attr == 'update' and child.args
                        and isinstance(child.args[0], ast.Dict)
                        and any(isinstance(k, ast.Constant) and k.value == 'is_posted' for k in child.args[0].keys)):
                    out.append(here)
            elif (isinstance(child, ast.Constant) and isinstance(child.value, str)
                    and SQL_WRITE.search(child.value)):
                out.append(here)
            walk(child, inner)

    walk(tree, '')
    return out


def scan(root: Path = BACKEND) -> dict:
    found = {}
    for path in sorted(root.rglob('*.py')):
        rel = path.relative_to(root)
        if set(rel.parts[:-1]) & SKIP_DIRS or rel.name.startswith('test_') or rel.name == 'conftest.py':
            continue
        for scope in _writes(ast.parse(path.read_text(encoding='utf-8'))):
            key = f'{rel.as_posix()}::{scope}'
            found[key] = found.get(key, 0) + 1
    return found


def test_no_writer_of_a_posted_state_appears_or_grows_unseen():
    found = scan()
    new = {k: v for k, v in found.items() if v > WRITERS.get(k, 0)}
    assert not new, (
        f'new writers of is_posted: {new}. A posted state changes through its document\'s '
        'operation (post_invoice_document, unpost_invoice_document, the voucher approval...). '
        'If this one is sanctioned, add it to WRITERS in review.')


def test_a_writer_that_goes_leaves_the_list():
    found = scan()
    stale = {k: v for k, v in WRITERS.items() if found.get(k, 0) < v}
    assert not stale, f'these no longer write is_posted (or write less): {stale} -- shrink WRITERS'


def test_the_scanner_sees_every_kind_of_write(tmp_path):
    (tmp_path / 'tool.py').write_text(
        "def a(je):\n    je.is_posted = False\n"
        "def b(je):\n    setattr(je, 'is_posted', True)\n"
        "def c(q):\n    q.update({'is_posted': False})\n"
        "def d(s):\n    s.execute('UPDATE journal_entry SET is_posted = false WHERE id = 1')\n"
        "def born():\n    return dict(is_posted=True)\n",
        encoding='utf-8')
    assert scan(tmp_path) == {'tool.py::a': 1, 'tool.py::b': 1, 'tool.py::c': 1, 'tool.py::d': 1}
