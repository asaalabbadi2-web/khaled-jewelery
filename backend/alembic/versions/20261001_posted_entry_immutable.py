"""journal_entry: a posted entry is never deleted, nor soft-deleted (UNPOST-001 U3)

The owner's rule (1 Oct 2026): a posted entry is corrected by a reversing
entry, never deleted; a document's entry goes only with its document. A
trigger holds it against every code path -- raw SQL and TRUNCATE included --
save a system reset inside journal_entry_guard.system_purge(). The SQL lives in
backend/posted_entry_trigger.py, shared with the test database's DDL.

Existing rows are not touched. Posted entries that are already soft-deleted
stay as they are (the trigger stops a NEW soft delete of a posted entry).
Idempotent: CREATE OR REPLACE / DROP IF EXISTS.

Revision ID: 20261001_posted_entry_immutable
Revises: 20261001_inventory_ledger_cycle
Create Date: 2026-10-01
"""
import os
import sys

from alembic import op

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from posted_entry_trigger import DROP_SQL, INSTALL_SQL  # noqa: E402

revision = '20261001_posted_entry_immutable'
down_revision = '20261001_inventory_ledger_cycle'
branch_labels = None
depends_on = None


def upgrade():
    if op.get_bind().dialect.name != 'postgresql':
        return
    op.execute(INSTALL_SQL)


def downgrade():
    if op.get_bind().dialect.name != 'postgresql':
        return
    op.execute(DROP_SQL)
