"""opening_figures: a year's opening figures and their approval (ADR-044, TR-2).

Revision ID: 20261106_opening_figures
Revises: 20261103_gold_deduction_as_purchase_return
Create Date: 2026-11-06

Impact: two new tables, nothing existing changed. opening_figure holds, per
account, the figure the manager enters for the new year's opening -- counted,
from a statement, a reconciliation -- with its source, who entered it and
when; opening_approval locks a year's figures once the owner approves them.
Read by tools/transition_2027.py on 1 January. Downgrade drops both.
"""
import sqlalchemy as sa
from alembic import op

revision = '20261106_opening_figures'
down_revision = '20261103_gold_deduction_as_purchase_return'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'opening_figure',
        sa.Column('id', sa.Integer, primary_key=True),
        sa.Column('year', sa.Integer, nullable=False, index=True),
        sa.Column('account_id', sa.Integer, sa.ForeignKey('account.id'), nullable=False),
        sa.Column('actual_cash', sa.Float, nullable=False, server_default='0'),
        sa.Column('actual_18k', sa.Float, nullable=False, server_default='0'),
        sa.Column('actual_21k', sa.Float, nullable=False, server_default='0'),
        sa.Column('actual_22k', sa.Float, nullable=False, server_default='0'),
        sa.Column('actual_24k', sa.Float, nullable=False, server_default='0'),
        sa.Column('source', sa.String(20), nullable=False),
        sa.Column('treatment', sa.String(10), nullable=True),
        sa.Column('note', sa.String(300), nullable=True),
        sa.Column('entered_by', sa.String(100), nullable=False),
        sa.Column('entered_at', sa.DateTime, nullable=False),
        sa.UniqueConstraint('year', 'account_id', name='uq_opening_figure_year_account'),
    )
    op.create_table(
        'opening_approval',
        sa.Column('year', sa.Integer, primary_key=True),
        sa.Column('approved_by', sa.String(100), nullable=False),
        sa.Column('approved_at', sa.DateTime, nullable=False),
    )


def downgrade():
    op.drop_table('opening_approval')
    op.drop_table('opening_figure')
