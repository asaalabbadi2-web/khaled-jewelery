"""A voucher born approved is born with its entry posted -- in every writer (APPROVED-ENTRY-001).

The rule since V1 (ADR-035, V0 addendum; the owner, 1 Oct 2026): an approved
voucher's entry stands posted, held at commit by journal_entry_guard. The
bonus paths and the office-reservation deposit build it with
`post_entry_of_approved_voucher`. Nine others built it with
`create_journal_entry_from_voucher`, which posts only when `voucher_auto_post`
or `auto_post_entries` is on, and marked the voucher approved: with auto-post
off each operation failed at commit (500). Production runs with it on, so it
was latent -- until someone turns it off.

The laws:
  - the gold safe transfer, auto-post off, succeeds and its entry stands posted;
  - who may call `create_journal_entry_from_voucher` is frozen: the posting
    helper itself, the approval paths that post the entry they build, and two
    repair tools (REPAIR-001). Any other writer of an approved voucher calls
    `post_entry_of_approved_voucher`.

Run:
    python -m pytest tests/test_approved_voucher_writers_post_their_entry.py -v
"""
import ast
import uuid
from pathlib import Path

import pytest

from app import app as flask_app
from models import Account, JournalEntry, SafeBox, SafeBoxTransaction, Settings, Voucher, db

BACKEND = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'tests', 'venv', 'alembic', 'migrations', '_archived', 'graphify-out', 'backups',
             '__pycache__', 'instance', 'temp_pdfs'}

# file::function -> calls. Frozen 2026-10-02; the list only shrinks.
CALLERS = {
    'accounting/voucher_engine.py::post_entry_of_approved_voucher': 1,
    # approval paths: they post the entry they build (or its voucher-linked drafts) themselves
    'posting_routes.py::approve_voucher': 1,
    'posting_routes.py::approve_vouchers_batch': 1,
    'routes/vouchers.py::create_voucher': 1,
    'routes/vouchers.py::approve_voucher': 1,
    'services/supplier_settlement_adjustment_service.py::SupplierSettlementAdjustmentService._build_and_post_voucher': 1,
    # repair tools -- for REPAIR-001 (stage 4)
    'tools/maintenance/fix_mada_balance_from_temp_bank_account.py::run': 1,
    'tools/maintenance/fix_misrouted_noncash_payments_to_cash.py::run': 1,
}


def _callers():
    found = {}
    for path in BACKEND.rglob('*.py'):
        rel = path.relative_to(BACKEND)
        if set(rel.parts) & SKIP_DIRS or rel.name.startswith('test_'):
            continue
        try:
            tree = ast.parse(path.read_text(encoding='utf-8'))
        except (SyntaxError, UnicodeDecodeError):
            continue

        def visit(node, scope):
            for child in ast.iter_child_nodes(node):
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    visit(child, scope + [child.name])
                    continue
                if isinstance(child, ast.Call):
                    f = child.func
                    name = f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else None
                    if name == 'create_journal_entry_from_voucher':
                        key = f'{rel.as_posix()}::{".".join(scope)}'
                        found[key] = found.get(key, 0) + 1
                visit(child, scope)
        visit(tree, [])
    return found


def test_who_builds_a_voucher_entry_unposted_is_frozen():
    found = _callers()
    new = {k: v for k, v in found.items() if v > CALLERS.get(k, 0)}
    assert not new, (
        'these build a voucher\'s entry with create_journal_entry_from_voucher, which posts it only '
        'when auto-post is on -- a voucher born approved calls post_entry_of_approved_voucher: '
        + ', '.join(f'{k} ({v})' for k, v in sorted(new.items())))
    gone = sorted(k for k in CALLERS if k not in found)
    assert not gone, f'remove from CALLERS, they no longer call it: {gone}'


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def auto_post_off(app, db_fence):
    row = Settings.query.first() or Settings()
    row.voucher_auto_post = False
    row.auto_post_entries = False
    db.session.add(row)
    db.session.flush()


def _gold_safe(name):
    acc = Account(account_number=f'7{uuid.uuid4().int % 10**7:07d}', name=name, type='Asset', tracks_weight=True)
    db.session.add(acc)
    db.session.flush()
    box = SafeBox(name=f'{name} {uuid.uuid4().hex[:6]}', safe_type='gold', account_id=acc.id, is_active=True)
    db.session.add(box)
    db.session.flush()
    return box


def test_a_gold_safe_transfer_with_auto_post_off_is_born_posted(auth_headers, auto_post_off):
    source, target = _gold_safe('خزينة مصدر'), _gold_safe('خزينة هدف')
    db.session.add(SafeBoxTransaction(safe_box_id=source.id, ref_type='opening', ref_id=0,
                                      direction='in', weight_21k=5.0, created_by='t'))
    db.session.flush()
    resp = flask_app.test_client().post('/api/safe-boxes/transfer-voucher', headers=auth_headers, json={
        'from_safe_box_id': source.id, 'to_safe_box_id': target.id, 'weights': {'21k': 2.0}})
    assert resp.status_code in (200, 201), resp.get_data(as_text=True)[:400]
    voucher = Voucher.query.filter_by(voucher_type='adjustment').order_by(Voucher.id.desc()).first()
    assert voucher.status == 'approved'
    entry = db.session.get(JournalEntry, voucher.journal_entry_id)
    assert entry is not None and entry.is_posted, 'an approved voucher with a draft entry'
