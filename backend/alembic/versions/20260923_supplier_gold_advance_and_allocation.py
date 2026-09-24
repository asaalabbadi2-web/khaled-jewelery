"""supplier gold advance and allocation (Phase 16C contract — schema only)

Phase 12F/14 of the invoice-payment audit: a gold payment to a supplier not
tied to a specific invoice is a Supplier Gold Advance, which may later be
attributed to a purchase invoice's gold obligation via an EXPLICIT
GoldAllocation. This migration adds ONLY the data contract: no route or
trigger-wiring logic is migrated here (that lives in application code).

PHASE 16C (this file was corrected before ever reaching a production
database — the commit carrying its first version was never pushed):
neither supplier_gold_advance nor invoice_gold_obligation carries a
weight_remaining_main_karat column. Phase 16A measured the original stored
balance drifting to 31,407g against a real GL position of 3,446g, because the
dominant real settlement mechanism (115 untagged manual gold-payment
vouchers) never wrote to it. Remaining weight is now DERIVED
(gold_allocation_service.advance_remaining /
obligation_attributed_remaining), and the authoritative supplier position
comes from the GL via compute_live_supplier_balances(). invoice_gold_
obligation is therefore an immutable record of the ORIGINAL gross obligation.

CORRECTION (same day, before this ever reached a real database — see project
memory): the first version of this migration added
invoice_karat_line.weight_remaining_main_karat and had GoldAllocation
reference invoice_karat_line directly. Phase 15A-Discovery.2 proved that is
wrong: real 'شراء' purchase invoices record their own gold weight through
EITHER InvoiceKaratLine (33/180 real invoices) OR InvoiceItem (147/180) —
never a third way — and the 4 invoices carrying both have identical
per-karat totals in each (duplicates, not two obligations). A per-line
balance column cannot represent that — the actual accounting-level
obligation is (invoice, karat), not (line, karat): the real GL itself posts
one memo-account credit per invoice per karat, never one per line/item
(verified directly against invoice #52's own JournalEntry). This version
replaces that design with invoice_gold_obligation, normalized from whichever
source recorded it.

Karat representation rule (see the model docstrings for the full reasoning,
proven via the real karat_diff_* mechanism already in posting_routes.py):
obligations and settlements each keep their own REAL karat; only a running
BALANCE is main-karat-equivalent, because subtracting across differing
karats is only possible in a common unit.

- supplier_gold_advance: new table. One row per (source voucher, karat) —
  mirrors VoucherAccountLine's own one-row-per-karat convention.
- invoice_gold_obligation: new table. One row per (invoice, karat), for
  'شراء' invoices only. Backfilled for existing invoices by normalizing
  InvoiceKaratLine (if any exist for that invoice) or else InvoiceItem
  (weight * quantity, falling back to the linked Item's own karat/weight
  when the InvoiceItem's own fields are blank) — the exact precedence the
  existing GL-posting code already uses (posting_routes.py). This is
  populating a new ledger's known starting state from data that already
  unambiguously exists, not inventing a historical attribution — the "no
  backfill" precedent this engagement otherwise follows is about
  attribution that cannot be known, not a deterministic aggregate of
  present, unambiguous source rows.
- gold_allocation: new table. Append-only match between one advance and one
  invoice_gold_obligation.

No ondelete clause on any new FK, matching invoice_karat_line.invoice_id's
own existing (unspecified) FK — deletion of Advance/Obligation/Allocation
rows is a deliberate service-level action (Phase 15C), never an implicit DB
cascade.

Revision ID: 20260923_gold_advance_allocation
Revises: 20260920_add_payment_method_id_or
Create Date: 2026-09-23
"""
from alembic import op
import sqlalchemy as sa

revision = '20260923_gold_advance_allocation'
down_revision = '20260920_add_payment_method_id_or'
branch_labels = None
depends_on = None


def _assert_no_stale_phase15_schema(inspector, existing_tables):
    """Fail LOUDLY if this database carries the pre-Phase-16C shape.

    The table-existence guards below exist so a partially-migrated database
    can be brought forward, but a guard that silently skips creation would
    leave a WRONG schema in place and report success. Two shapes must never
    pass: gold_allocation.invoice_karat_line_id (the abandoned Phase 15A
    design, found present in a local copy), and a supplier_gold_advance or
    invoice_gold_obligation that still carries weight_remaining_main_karat
    (the mutable balance Phase 16C removed). Both mean the database needs a
    deliberate manual reconciliation, not an automatic pass-through.
    """
    if 'gold_allocation' in existing_tables:
        cols = {c['name'] for c in inspector.get_columns('gold_allocation')}
        if 'invoice_karat_line_id' in cols:
            raise RuntimeError(
                'stale_schema:gold_allocation.invoice_karat_line_id exists — this '
                'database carries the abandoned Phase 15A design. Drop '
                'gold_allocation (and invoice_gold_obligation / '
                'supplier_gold_advance if present) before upgrading.'
            )
        if 'obligation_id' not in cols:
            raise RuntimeError(
                'stale_schema:gold_allocation exists without obligation_id — '
                'unexpected shape, refusing to continue.'
            )

    for table in ('supplier_gold_advance', 'invoice_gold_obligation'):
        if table in existing_tables:
            cols = {c['name'] for c in inspector.get_columns(table)}
            if 'weight_remaining_main_karat' in cols:
                raise RuntimeError(
                    f'stale_schema:{table}.weight_remaining_main_karat exists — '
                    'this database predates Phase 16C (which removed the stored '
                    'balance). Drop the Phase 15 tables before upgrading.'
                )


def upgrade():
    conn = op.get_bind()
    inspector = sa.inspect(conn)
    existing_tables = set(inspector.get_table_names())

    _assert_no_stale_phase15_schema(inspector, existing_tables)

    # --- supplier_gold_advance -------------------------------------------------
    if 'supplier_gold_advance' not in existing_tables:
        op.create_table(
            'supplier_gold_advance',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('supplier_id', sa.Integer(), sa.ForeignKey('supplier.id'), nullable=False),
            sa.Column('source_voucher_id', sa.Integer(), sa.ForeignKey('voucher.id'), nullable=False),
            sa.Column('karat', sa.Float(), nullable=False),
            sa.Column('weight', sa.Float(), nullable=False),
            sa.Column('created_at', sa.DateTime(), server_default=sa.func.now()),
            sa.UniqueConstraint('source_voucher_id', 'karat', name='_gold_advance_voucher_karat_uc'),
        )
        op.create_index(
            'ix_supplier_gold_advance_supplier_id', 'supplier_gold_advance', ['supplier_id']
        )
        op.create_index(
            'ix_supplier_gold_advance_source_voucher_id', 'supplier_gold_advance', ['source_voucher_id']
        )

    # --- invoice_gold_obligation -------------------------------------------------
    if 'invoice_gold_obligation' not in existing_tables:
        op.create_table(
            'invoice_gold_obligation',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('invoice_id', sa.Integer(), sa.ForeignKey('invoice.id'), nullable=False),
            sa.Column('karat', sa.Float(), nullable=False),
            sa.Column('weight', sa.Float(), nullable=False),
            sa.Column('created_at', sa.DateTime(), server_default=sa.func.now()),
            sa.UniqueConstraint('invoice_id', 'karat', name='_invoice_gold_obligation_invoice_karat_uc'),
        )
        op.create_index(
            'ix_invoice_gold_obligation_invoice_id', 'invoice_gold_obligation', ['invoice_id']
        )

    # --- gold_allocation --------------------------------------------------------
    if 'gold_allocation' not in existing_tables:
        op.create_table(
            'gold_allocation',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column(
                'advance_id', sa.Integer(),
                sa.ForeignKey('supplier_gold_advance.id'), nullable=False,
            ),
            sa.Column(
                'obligation_id', sa.Integer(),
                sa.ForeignKey('invoice_gold_obligation.id'), nullable=False,
            ),
            sa.Column('weight_applied_main_karat', sa.Float(), nullable=False),
            sa.Column('created_at', sa.DateTime(), server_default=sa.func.now()),
        )
        op.create_index(
            'ix_gold_allocation_advance_id', 'gold_allocation', ['advance_id']
        )
        op.create_index(
            'ix_gold_allocation_obligation_id', 'gold_allocation', ['obligation_id']
        )

    _backfill_invoice_gold_obligations(conn)


def _backfill_invoice_gold_obligations(conn):
    """Normalize every existing 'شراء' invoice's gold weight into
    invoice_gold_obligation rows. Safe to re-run: skips any invoice that
    already has at least one row (mirrors create_gold_obligations_for_
    invoice's own idempotency check in application code).

    Precedence per invoice (Phase 15A-Discovery.2, exhaustively verified
    against real production data — zero non-deterministic cases found):
      1. InvoiceKaratLine rows, if any exist for this invoice — used
         exclusively.
      2. Otherwise InvoiceItem rows: weight * quantity, falling back to the
         linked Item's own karat/weight when the InvoiceItem's own fields
         are blank (a real code path, not exercised in the production
         sample checked, handled here defensively).
    Karat is rounded to the nearest int, defaulting to 21 for anything
    unmapped — matching the existing aggregation convention in
    posting_routes.py exactly.

    ELIGIBILITY (Phase 16C): office_id IS NULL is applied here as raw SQL,
    mirroring gold_allocation_service.is_gold_obligation_eligible() — the one
    definition both paths must agree on. Phase 16A proved at code level that
    an office-reservation settlement invoice posts CASH ONLY to the GL, so an
    obligation row for it would be a phantom (29 such rows / 5,521.81g were
    created in a local copy by the pre-16C version of this backfill; no
    production database ever ran it).
    """
    already_seeded = {
        row[0] for row in conn.execute(
            sa.text('SELECT DISTINCT invoice_id FROM invoice_gold_obligation')
        ).fetchall()
    }

    purchase_invoice_ids = [
        row[0] for row in conn.execute(
            sa.text(
                "SELECT id FROM invoice "
                "WHERE invoice_type = 'شراء' AND office_id IS NULL"
            )
        ).fetchall()
        if row[0] not in already_seeded
    ]
    if not purchase_invoice_ids:
        return

    karat_line_rows = conn.execute(
        sa.text(
            'SELECT invoice_id, karat, weight_grams FROM invoice_karat_line '
            'WHERE invoice_id = ANY(:ids)'
        ),
        {'ids': purchase_invoice_ids},
    ).fetchall()
    invoices_with_karat_lines = {r[0] for r in karat_line_rows}

    by_invoice_karat: dict[tuple[int, int], float] = {}

    for invoice_id, karat, weight_grams in karat_line_rows:
        if not weight_grams or weight_grams <= 0:
            continue
        k = int(round(float(karat or 21)))
        key = (invoice_id, k)
        by_invoice_karat[key] = by_invoice_karat.get(key, 0.0) + float(weight_grams)

    items_invoice_ids = [
        iid for iid in purchase_invoice_ids if iid not in invoices_with_karat_lines
    ]
    if items_invoice_ids:
        item_rows = conn.execute(
            sa.text(
                'SELECT ii.invoice_id, ii.karat, ii.weight, ii.quantity, '
                '       it.karat AS item_karat, it.weight AS item_weight '
                'FROM invoice_item ii '
                'LEFT JOIN item it ON it.id = ii.item_id '
                'WHERE ii.invoice_id = ANY(:ids)'
            ),
            {'ids': items_invoice_ids},
        ).fetchall()

        for invoice_id, karat, weight, quantity, item_karat, item_weight in item_rows:
            effective_karat = karat if karat not in (None, 0) else item_karat
            effective_weight = weight if weight not in (None, 0) else item_weight
            if not effective_weight or effective_weight <= 0:
                continue
            k = int(round(float(effective_karat or 21)))
            qty = quantity if quantity and quantity > 0 else 1
            key = (invoice_id, k)
            by_invoice_karat[key] = by_invoice_karat.get(key, 0.0) + float(effective_weight) * float(qty)

    for (invoice_id, karat), weight in by_invoice_karat.items():
        weight = round(weight, 3)
        if weight <= 0:
            continue
        conn.execute(
            sa.text(
                'INSERT INTO invoice_gold_obligation '
                '(invoice_id, karat, weight, created_at) '
                'VALUES (:invoice_id, :karat, :weight, now())'
            ),
            {
                'invoice_id': invoice_id,
                'karat': karat,
                'weight': weight,
            },
        )


def downgrade():
    op.drop_index('ix_gold_allocation_obligation_id', table_name='gold_allocation')
    op.drop_index('ix_gold_allocation_advance_id', table_name='gold_allocation')
    op.drop_table('gold_allocation')

    op.drop_index('ix_invoice_gold_obligation_invoice_id', table_name='invoice_gold_obligation')
    op.drop_table('invoice_gold_obligation')

    op.drop_index('ix_supplier_gold_advance_source_voucher_id', table_name='supplier_gold_advance')
    op.drop_index('ix_supplier_gold_advance_supplier_id', table_name='supplier_gold_advance')
    op.drop_table('supplier_gold_advance')
