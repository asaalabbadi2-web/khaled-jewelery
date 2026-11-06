"""opening_reconciliation: the approval's entry of the year's differences from its figures (ADR-044, TR-4).

Revision ID: 20261107_opening_reconciliation
Revises: 20261107_opening_waiting

Impact: one nullable column on opening_approval (added by 20261106, empty on
production), a key to journal_entry. Nothing else read or changed. Downgrade
drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261107_opening_reconciliation'
down_revision = '20261107_opening_waiting'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('opening_approval', sa.Column('reconciliation_entry_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_opening_approval_reconciliation_entry', 'opening_approval', 'journal_entry',
                          ['reconciliation_entry_id'], ['id'])


def downgrade():
    op.drop_constraint('fk_opening_approval_reconciliation_entry', 'opening_approval', type_='foreignkey')
    op.drop_column('opening_approval', 'reconciliation_entry_id')
