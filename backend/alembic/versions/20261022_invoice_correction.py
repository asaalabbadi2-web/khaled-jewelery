"""invoice_correction: a posted invoice's line corrected, by the difference (22 Oct 2026)

SCHEMA, ADDITIVE.

invoice_correction -- one row per correction of a posted invoice's line (its
karat, weight or price entered wrong): the line corrected in place, the
difference posted as one entry dated the day, and here what was (before),
what is (after), why, who and when. The owner, 22 Oct 2026
(docs/plans/invoice-correction-study.md).

IMPACT: a new empty table; no existing row, invoice or entry is touched.
Downgrade drops it -- with the record of what each correction changed (the
corrected lines and their entries stay).

Revision ID: 20261022_invoice_correction
Revises: 20261021_settings_gold_cost_from
Create Date: 2026-10-22
"""
from alembic import op
import sqlalchemy as sa

revision = '20261022_invoice_correction'
down_revision = '20261021_settings_gold_cost_from'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'invoice_correction',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('invoice_id', sa.Integer(), sa.ForeignKey('invoice.id'), nullable=False),
        sa.Column('invoice_item_id', sa.Integer(), sa.ForeignKey('invoice_item.id'), nullable=True),
        sa.Column('journal_entry_id', sa.Integer(), sa.ForeignKey('journal_entry.id'), nullable=True),
        sa.Column('safe_box_id', sa.Integer(), sa.ForeignKey('safe_box.id'), nullable=True),
        sa.Column('reason', sa.Text(), nullable=False),
        sa.Column('before', sa.JSON(), nullable=False),
        sa.Column('after', sa.JSON(), nullable=False),
        sa.Column('cash_delta', sa.Float(), nullable=False, server_default='0'),
        sa.Column('created_by', sa.String(100), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
    )
    op.create_index('ix_invoice_correction_invoice_id', 'invoice_correction', ['invoice_id'])


def downgrade():
    op.drop_index('ix_invoice_correction_invoice_id', table_name='invoice_correction')
    op.drop_table('invoice_correction')
