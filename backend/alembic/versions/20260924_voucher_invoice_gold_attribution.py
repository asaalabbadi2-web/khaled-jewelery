"""voucher -> invoice gold attribution, and the frozen historical boundary

Phase A of the invoice settlement-state work. Recording WHICH invoice a gold
payment settles, at the moment of payment, because it cannot be recovered
afterwards: Phase 16B found that 0 of 113 real gold vouchers ever named an
invoice in their description while 64% used running-account language, and that
at payment time only 11 of 124 had a single candidate invoice (19 had 21 or
more). Attribution is information to capture, never to infer.

Two tables:

- voucher_invoice_gold_attribution — one row per (voucher, invoice) settlement
  slice, keeping the REAL karat and weight alongside the main-karat-equivalent.
  Both are needed: Phase 16A found 8 of 34 real settlements paid a karat the
  invoice never contained, so flattening to the equivalent would destroy the
  fact that 18k was handed over against a 21k obligation. Only the equivalent
  is used to balance against an obligation.

- gold_attribution_boundary — ONE row, written here, never recomputed. It
  freezes the highest voucher id that existed when attribution became recorded.
  At or below it, invoice attribution may be DERIVED from
  Voucher.reference_type='invoice' plus the GL (Phase 12E "mechanism A", 34 real
  vouchers). Above it, only the attribution table counts, so a voucher can
  never have two competing answers.

  Why a captured id and not a date: the system allows back-dating an invoice or
  a voucher, so a date boundary would misclassify new documents as historical.
  Why not recompute MAX(id) per read: that would silently advance the line and
  re-open the derivation for vouchers that are supposed to carry rows.

Note on Voucher.reference_type: 'invoice' is deliberately NOT retired. An audit
found seven production consumers relying on it for the CASH side — above all
services/invoice_payment_state_service.py (payment-state sync) and
routes/vouchers.py's cancel path (the AV-2026-00223 reversal) — plus a
scheduler. It means "this voucher pays this invoice", which stays true. Only
one new value is introduced by the application layer, 'gold_supplier', for a
payment the employee declares to be a general supplier settlement with no
invoice attribution at all — a legitimate outcome, and the shape of 81% of the
historical data.

This migration creates schema and captures one boundary value. It attributes
nothing and backfills no history.

Revision ID: 20260924_voucher_invoice_gold_attr
Revises: 20260924_drop_supplier_cached_balances
Create Date: 2026-09-24
"""
from alembic import op
import sqlalchemy as sa

revision = '20260924_voucher_invoice_gold_attr'
down_revision = '20260924_drop_supplier_cached_balances'
branch_labels = None
depends_on = None


def upgrade():
    conn = op.get_bind()
    existing = set(sa.inspect(conn).get_table_names())

    if 'voucher_invoice_gold_attribution' not in existing:
        op.create_table(
            'voucher_invoice_gold_attribution',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('voucher_id', sa.Integer(), sa.ForeignKey('voucher.id'), nullable=False),
            sa.Column('invoice_id', sa.Integer(), sa.ForeignKey('invoice.id'), nullable=False),
            sa.Column('karat', sa.Float(), nullable=False),
            sa.Column('weight', sa.Float(), nullable=False),
            sa.Column('weight_main_karat', sa.Float(), nullable=False),
            sa.Column('created_at', sa.DateTime(), server_default=sa.func.now()),
            sa.Column('created_by', sa.String(length=100), nullable=True),
        )
        op.create_index(
            'ix_voucher_invoice_gold_attr_voucher_id',
            'voucher_invoice_gold_attribution', ['voucher_id'],
        )
        op.create_index(
            'ix_voucher_invoice_gold_attr_invoice_id',
            'voucher_invoice_gold_attribution', ['invoice_id'],
        )

    if 'gold_attribution_boundary' not in existing:
        op.create_table(
            'gold_attribution_boundary',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('max_historical_voucher_id', sa.Integer(), nullable=False),
            sa.Column('captured_at', sa.DateTime(), server_default=sa.func.now()),
            sa.Column('note', sa.String(length=255), nullable=True),
        )

    # Capture the boundary exactly once. A re-run must never move it.
    already = conn.execute(
        sa.text('SELECT COUNT(*) FROM gold_attribution_boundary')
    ).scalar()
    if not already:
        max_voucher_id = conn.execute(
            sa.text('SELECT COALESCE(MAX(id), 0) FROM voucher')
        ).scalar()
        conn.execute(
            sa.text(
                'INSERT INTO gold_attribution_boundary '
                '(max_historical_voucher_id, captured_at, note) '
                'VALUES (:mx, now(), :note)'
            ),
            {
                'mx': int(max_voucher_id or 0),
                'note': 'vouchers at or below this id may have invoice gold '
                        'attribution derived from reference_type=invoice + GL; '
                        'above it, only voucher_invoice_gold_attribution counts',
            },
        )


def downgrade():
    conn = op.get_bind()
    existing = set(sa.inspect(conn).get_table_names())

    if 'voucher_invoice_gold_attribution' in existing:
        op.drop_index(
            'ix_voucher_invoice_gold_attr_invoice_id',
            table_name='voucher_invoice_gold_attribution',
        )
        op.drop_index(
            'ix_voucher_invoice_gold_attr_voucher_id',
            table_name='voucher_invoice_gold_attribution',
        )
        op.drop_table('voucher_invoice_gold_attribution')

    if 'gold_attribution_boundary' in existing:
        op.drop_table('gold_attribution_boundary')
