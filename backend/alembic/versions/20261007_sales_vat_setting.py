"""sales_vat_setting: VAT on sales is one company setting (SALES-VAT-1, the owner 7 Oct 2026)

ADDITIVE, plus one value set on evidence.

Adds settings.sales_vat_enabled BOOLEAN NOT NULL DEFAULT true.

From the evening of 1 May 2026 every sale carries no VAT -- intended (the
owner) -- but it rested on a switch kept on each device. From this release the
sales screens read this setting and the server refuses a taxed sale when it is
off. So that the release does not start charging 15 % again before the owner
turns it off, the setting is set off when the most recent sales with a taxable
line (a karat not exempt from VAT) all carry none: the record is made to say
what the business does. Too few such sales, or any taxed one among them, and
it stays on -- a choice for the settings screen.

Measured on the 6 Oct production copy: the 50 most recent such sales carry no
VAT -> off.

IMPACT: none on existing invoices or entries. Downgrade drops the column.

Revision ID: 20261007_sales_vat_setting
Revises: 20261006_invoice_vat_applied
Create Date: 2026-10-07
"""
import json

from alembic import op
import sqlalchemy as sa

revision = '20261007_sales_vat_setting'
down_revision = '20261006_invoice_vat_applied'
branch_labels = None
depends_on = None

SAMPLE = 50


def _exempt_karats(raw):
    try:
        values = json.loads(raw) if isinstance(raw, str) else (raw or [])
        return {int(float(v)) for v in values}
    except Exception:
        return {24}


def correct_sales_vat(bind, sample=SAMPLE):
    """Returns (before, after, sales seen). Turns it off only on evidence."""
    row = bind.execute(sa.text(
        'SELECT id, sales_vat_enabled, vat_exempt_karats FROM settings ORDER BY id LIMIT 1'
    )).first()
    if row is None:
        return None, None, 0
    before = bool(row.sales_vat_enabled)
    if not before:
        return before, before, 0
    exempt = sorted(_exempt_karats(row.vat_exempt_karats)) or [-1]
    recent = bind.execute(sa.text(
        """
        SELECT i.id,
               COALESCE(i.total_tax, 0) AS total_tax,
               SUM(CASE WHEN COALESCE(it.tax, 0) > 0.005 THEN 1 ELSE 0 END) AS taxed_lines
          FROM invoice i
          JOIN invoice_item it ON it.invoice_id = i.id
         WHERE i.invoice_type = 'بيع'
           AND ROUND(CAST(it.karat AS numeric)) NOT IN :exempt
         GROUP BY i.id, i.total_tax
         ORDER BY i.id DESC
         LIMIT :sample
        """
    ).bindparams(sa.bindparam('exempt', expanding=True)),
        {'exempt': exempt, 'sample': sample}).fetchall()
    seen = len(recent)
    untaxed = all(r.total_tax <= 0.005 and r.taxed_lines == 0 for r in recent)
    if seen < sample or not untaxed:
        return before, before, seen
    bind.execute(sa.text('UPDATE settings SET sales_vat_enabled = false WHERE id = :id'),
                 {'id': row.id})
    return before, False, seen


def upgrade():
    bind = op.get_bind()
    columns = {c['name'] for c in sa.inspect(bind).get_columns('settings')}
    if 'sales_vat_enabled' not in columns:
        op.add_column('settings', sa.Column('sales_vat_enabled', sa.Boolean(),
                                            nullable=False, server_default=sa.true()))
    before, after, seen = correct_sales_vat(bind)
    print(f'[sales_vat_setting] {before} -> {after} ({seen} recent taxable sales read)')


def downgrade():
    columns = {c['name'] for c in sa.inspect(op.get_bind()).get_columns('settings')}
    if 'sales_vat_enabled' in columns:
        op.drop_column('settings', 'sales_vat_enabled')
