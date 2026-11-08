"""supplier_invoice_number: the supplier's own invoice number on a purchase (8 Nov 2026).

Revision ID: 20261108_supplier_invoice_number
Revises: 20261108_inventory_count_return

Impact: one nullable column on invoice, empty -- no row is read or changed --
and a partial unique index: one number per supplier among invoices not
retracted (rejected, cancelled), only where a number is written. Downgrade
drops both.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261108_supplier_invoice_number'
down_revision = '20261108_inventory_count_return'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('invoice', sa.Column('supplier_invoice_number', sa.String(50), nullable=True))
    op.create_index('uq_invoice_supplier_invoice_number', 'invoice', ['supplier_id', 'supplier_invoice_number'],
                    unique=True,
                    postgresql_where=sa.text("supplier_invoice_number IS NOT NULL "
                                             "AND coalesce(status, '') NOT IN ('rejected', 'cancelled')"))


def downgrade():
    op.drop_index('uq_invoice_supplier_invoice_number', table_name='invoice')
    op.drop_column('invoice', 'supplier_invoice_number')
