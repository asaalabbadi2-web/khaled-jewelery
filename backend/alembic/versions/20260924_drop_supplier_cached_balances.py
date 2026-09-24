"""drop the cached supplier cash/gold balance columns

A supplier's balance is derived from the ledger, not stored. These five columns
existed "to speed up queries" and were incremented in place by
create_dual_journal_entry() on every posting that resolved a supplier:

    supplier.balance_gold_21k += (weight_21k_debit - weight_21k_credit)

Measured on real production before this migration: **24 suppliers diverging
from the ledger, 21,121.06 g absolute** (worst: supplier 14 at 6,612.88 g,
supplier 7 at 2,139.98 g). Drift was structural — every GL write that bypassed
that helper, every write with an unresolved supplier_id, and every reversal or
deletion widened the gap, while the canonical reader
(services/party_live_balances.compute_live_supplier_balances, declared
`Single Source` in supplier_settlement_adjustment_service.py) read the journal
with additional rules of its own. Three separate endpoints were answering the
same question differently, and /suppliers/<id>/weight-summary was multiplying
the stale weights by live gold prices into monetary valuations.

This is the third cache drift in this codebase (Invoice.amount_paid, then
InvoiceGoldObligation.weight_remaining_main_karat, then this), so the fix is
deletion rather than a better writer. Guarded by
backend/tests/test_supplier_balance_is_derived_ratchet.py.

NOT dropped, deliberately:
  - supplier.gold_balance_weight / gold_balance_cash_equivalent — a different
    quantity, the gold-costing subsystem in supplier_gold_service.py, which
    both writes and reads them and is internally consistent.
  - the identically-named columns on customer and office — same defect, their
    own consumers, an explicitly deferred decision.

The JSON keys balance_cash / balance_gold_18k..24k are UNCHANGED on the wire:
routes/suppliers.py fills them from the canonical function, so
frontend/lib/screens/suppliers_screen.dart needs no change.

Irreversible in substance: downgrade() re-creates the columns but cannot
restore their values, and those values were wrong. Take a database backup
before upgrading if you want them for forensics.

Revision ID: 20260924_drop_supplier_cached_balances
Revises: 20260923_gold_advance_allocation
Create Date: 2026-09-24
"""
from alembic import op
import sqlalchemy as sa

revision = '20260924_drop_supplier_cached_balances'
down_revision = '20260923_gold_advance_allocation'
branch_labels = None
depends_on = None

CACHED_COLUMNS = (
    'balance_cash',
    'balance_gold_18k',
    'balance_gold_21k',
    'balance_gold_22k',
    'balance_gold_24k',
)


def _supplier_columns(conn):
    return {c['name'] for c in sa.inspect(conn).get_columns('supplier')}


def upgrade():
    conn = op.get_bind()
    existing = _supplier_columns(conn)
    for column in CACHED_COLUMNS:
        if column in existing:
            op.drop_column('supplier', column)


def downgrade():
    conn = op.get_bind()
    existing = _supplier_columns(conn)
    for column in CACHED_COLUMNS:
        if column not in existing:
            op.add_column(
                'supplier',
                sa.Column(column, sa.Float(), nullable=True, server_default='0'),
            )
