"""Each posting key its own scope (D2, the owner, 26 Nov 2026; ADR-104).

voucher_auto_post and auto_post_entries were ORed where a voucher's entry is
built (accounting/voucher_engine.create_journal_entry_from_voucher): either
one on, the entry was posted as it was built. But every path that approves a
voucher posts the entries it builds itself -- an approved voucher's entry
stands posted, by law (ADR-035, V0 addendum; journal_entry_guard) -- so the OR
decided nothing a setting may decide, and made the voucher key read as if it
posted vouchers, which it never alone did. The laws:
  - the builder reads no posting setting: what posts a voucher's entry is
    its approval;
  - voucher_auto_post decides one thing: the system admin's own voucher is
    approved -- and so posted -- when it is created; off, it waits for an
    approver like any other, whatever auto_post_entries says;
  - auto_post_entries decides manual entries alone
    (tests/test_manual_entry_auto_post.py).

Run:
    python -m pytest tests/test_each_posting_key_its_own.py -v
"""
import ast
from pathlib import Path

import pytest

from models import JournalEntry, Settings, Voucher, db
from tests.voucher_world import create, vworld  # noqa: F401 (fixture)

ENGINE = Path(__file__).resolve().parents[1] / 'accounting' / 'voucher_engine.py'


@pytest.fixture(autouse=True)
def fenced(app, db_fence):
    yield


def _keys(voucher_auto_post, auto_post_entries):
    row = Settings.query.first() or Settings()
    row.voucher_auto_post = voucher_auto_post
    row.auto_post_entries = auto_post_entries
    db.session.add(row)
    db.session.flush()


def test_the_voucher_entry_builder_reads_no_posting_setting():
    tree = ast.parse(ENGINE.read_text(encoding='utf-8'))
    builder = next(n for n in ast.walk(tree)
                   if isinstance(n, ast.FunctionDef) and n.name == 'create_journal_entry_from_voucher')
    said = {n.value for n in ast.walk(builder) if isinstance(n, ast.Constant) and isinstance(n.value, str)}
    assert not said & {'voucher_auto_post', 'auto_post_entries'}, \
        "a voucher's entry is posted by its approval, not by a posting setting"


def test_the_entries_key_does_not_approve_the_admins_voucher(auth_headers, vworld):
    _keys(voucher_auto_post=False, auto_post_entries=True)
    vid = create(auth_headers, vworld, 'cash_receipt')
    db.session.expire_all()
    voucher = db.session.get(Voucher, vid)
    assert voucher.status == 'pending', 'the voucher key off: it waits for an approver'
    assert voucher.journal_entry_id is None


@pytest.mark.parametrize('shape', ('cash_receipt', 'gold_payment'))
def test_the_voucher_key_alone_approves_and_posts_the_admins_voucher(auth_headers, vworld, shape):
    _keys(voucher_auto_post=True, auto_post_entries=False)
    vid = create(auth_headers, vworld, shape)
    db.session.expire_all()
    voucher = db.session.get(Voucher, vid)
    assert voucher.status == 'approved'
    entry = db.session.get(JournalEntry, voucher.journal_entry_id)
    assert entry is not None and entry.is_posted and not entry.is_draft, 'approved: its entry stands posted'
