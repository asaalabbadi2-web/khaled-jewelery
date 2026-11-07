"""inventory_count_return: a closed count sent back to counting (رفض العدّ).

Revision ID: 20261108_inventory_count_return
Revises: 20261107_opening_revaluation

Impact: one new, empty table -- per return of a closed count session, who
returned it, when, why, and its lines' counts as they stood. Nothing existing
read or changed. Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261108_inventory_count_return'
down_revision = '20261107_opening_revaluation'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'inventory_count_return',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('session_id', sa.Integer(),
                  sa.ForeignKey('inventory_count_session.id', ondelete='CASCADE'), nullable=False),
        sa.Column('returned_by', sa.String(100), nullable=False),
        sa.Column('returned_at', sa.DateTime(), nullable=False),
        sa.Column('reason', sa.Text(), nullable=False),
        sa.Column('counts', sa.JSON(), nullable=False),
    )
    op.create_index('ix_inventory_count_return_session_id', 'inventory_count_return', ['session_id'])


def downgrade():
    op.drop_index('ix_inventory_count_return_session_id', table_name='inventory_count_return')
    op.drop_table('inventory_count_return')
