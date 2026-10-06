"""invoice_vat_applied: a supplier purchase records its VAT decision (PURCHASE-VAT-1, the owner 6 Oct 2026)

ADDITIVE: invoice.vat_applied BOOLEAN NULL.

Purchases with and without VAT are intentional; until now the decision was a
switch kept on the device and the invoice kept only a zero tax. From this
release the purchase screen sends the decision (starting from the supplier's
tax number) and the invoice records it.

No backfill: past invoices recorded no decision, so they stay NULL rather
than have one inferred from their tax.

IMPACT: none on existing rows or postings. Downgrade drops the column.

Revision ID: 20261006_invoice_vat_applied
Revises: 20261006_wage_mode_matches_books
Create Date: 2026-10-06
"""
from alembic import op
import sqlalchemy as sa

revision = '20261006_invoice_vat_applied'
down_revision = '20261006_wage_mode_matches_books'
branch_labels = None
depends_on = None


def upgrade():
    columns = {c['name'] for c in sa.inspect(op.get_bind()).get_columns('invoice')}
    if 'vat_applied' not in columns:
        op.add_column('invoice', sa.Column('vat_applied', sa.Boolean(), nullable=True))


def downgrade():
    columns = {c['name'] for c in sa.inspect(op.get_bind()).get_columns('invoice')}
    if 'vat_applied' in columns:
        op.drop_column('invoice', 'vat_applied')
