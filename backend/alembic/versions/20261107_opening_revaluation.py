"""opening_revaluation: the close's market price and its revaluation entry (ADR-044, TR-4b).

Revision ID: 20261107_opening_revaluation
Revises: 20261107_opening_reconciliation

Impact: two nullable columns on opening_approval (added by 20261106, empty on
production) -- the count day's market price and a key to the entry that
values the stock at it. Nothing else read or changed. Downgrade drops them.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261107_opening_revaluation'
down_revision = '20261107_opening_reconciliation'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('opening_approval', sa.Column('market_price', sa.Float(), nullable=True))
    op.add_column('opening_approval', sa.Column('revaluation_entry_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_opening_approval_revaluation_entry', 'opening_approval', 'journal_entry',
                          ['revaluation_entry_id'], ['id'])


def downgrade():
    op.drop_constraint('fk_opening_approval_revaluation_entry', 'opening_approval', type_='foreignkey')
    op.drop_column('opening_approval', 'revaluation_entry_id')
    op.drop_column('opening_approval', 'market_price')
