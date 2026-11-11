"""invoice_item.original_invoice_item_id: a return's line keeps the line it returns.

Revision ID: 20261111_return_line_original
Revises: 20261109_piece_tag

The link was checked when a return was saved and thrown away, so what remained
of a line after its returns could not be read (the return audit, 11 Nov 2026).

Impact: invoice_item.original_invoice_item_id, nullable, FK to invoice_item.id,
indexed: every row today NULL; returns saved from now on carry it. Nothing
existing read or changed. Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261111_return_line_original'
down_revision = '20261109_piece_tag'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('invoice_item', sa.Column('original_invoice_item_id', sa.Integer(), nullable=True))
    op.create_foreign_key('fk_invoice_item_original_invoice_item', 'invoice_item', 'invoice_item',
                          ['original_invoice_item_id'], ['id'], ondelete='SET NULL')
    op.create_index('ix_invoice_item_original_invoice_item_id', 'invoice_item', ['original_invoice_item_id'])


def downgrade():
    op.drop_index('ix_invoice_item_original_invoice_item_id', table_name='invoice_item')
    op.drop_constraint('fk_invoice_item_original_invoice_item', 'invoice_item', type_='foreignkey')
    op.drop_column('invoice_item', 'original_invoice_item_id')
