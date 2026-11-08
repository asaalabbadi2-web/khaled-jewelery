"""receiving: the day receiving works from, a purchase's stage and key, a line's supplier weight (ADR-087).

Revision ID: 20261108_receiving
Revises: 20261108_supplier_invoice_number

Impact: four nullable columns, empty -- no row read or changed:
settings.receiving_from (NULL: never, so 2026 posts as it always has),
invoice.receiving_stage, invoice.request_key (unique), invoice_item.supplier_weight.
Downgrade drops them.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261108_receiving'
down_revision = '20261108_supplier_invoice_number'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('receiving_from', sa.Date(), nullable=True))
    op.add_column('invoice', sa.Column('receiving_stage', sa.String(12), nullable=True))
    op.add_column('invoice', sa.Column('request_key', sa.String(64), nullable=True))
    op.create_unique_constraint('uq_invoice_request_key', 'invoice', ['request_key'])
    op.add_column('invoice_item', sa.Column('supplier_weight', sa.Float(), nullable=True))


def downgrade():
    op.drop_column('invoice_item', 'supplier_weight')
    op.drop_constraint('uq_invoice_request_key', 'invoice', type_='unique')
    op.drop_column('invoice', 'request_key')
    op.drop_column('invoice', 'receiving_stage')
    op.drop_column('settings', 'receiving_from')
