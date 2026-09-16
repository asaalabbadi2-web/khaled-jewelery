"""Supplier Settlement Adjustment (SAD) — document + effective-dated policy

Revision ID: 20260916_supplier_settlement_adjustment
Revises: 20260908_fix_legacy_transaction_type_both
Create Date: 2026-09-16

─── Impact note ──────────────────────────────────────────────────────────────

WHAT CHANGES
    • New table `supplier_settlement_policy` — effective-dated limits (POLICY,
      editable by finance without a deploy).
    • New table `supplier_settlement_adjustment` — the SAD document itself.
    • One seed row in `supplier_settlement_policy` carrying the initial limits
      from the SAD specification, effective from the moment this migration runs.

WHAT DOES **NOT** CHANGE
    • No existing table is altered. No column is dropped or retyped.
    • No account is created, renamed, or renumbered.
    • No balance is touched: no Account.balance_*, no Supplier.balance_*, no
      Supplier.gold_balance_*, no JournalEntry, no JournalEntryLine.
    • No AccountingMapping row is inserted. The settlement GL accounts are a
      deliberate setup prerequisite — the service raises
      MissingAccountingMappingError rather than posting to a guessed account.

CONTEXT
    Closes small justified residuals left on a supplier's GL-derived balance
    after settlement completes. The document produces its accounting effect
    exclusively through the canonical Voucher pipeline; this schema stores the
    document, its balance snapshot, and its audit trail — never a balance.

IDEMPOTENCY
    Both tables are created only when absent, and the seed row is inserted only
    when the policy table is empty. Safe to re-run.

    The seed is deliberately independent of table creation. The ERP calls
    db.create_all() at boot, so on any database the app has already started
    against, both tables exist before this migration runs. Tying the seed to
    "we just created the table" would silently skip it there, leaving SAD with
    no policy in force and refusing every operation. The condition that matters
    is whether a policy exists — not who created the table.

PRE-CHECK / POST-CHECK
    upgrade() reports the state it found, what it did, and verifies the result
    before returning. An existing non-empty policy table is left untouched: no
    row is duplicated, updated, or deleted.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy import inspect
from sqlalchemy.sql import func


# revision identifiers, used by Alembic.
revision: str = '20260916_supplier_settlement_adjustment'
down_revision: Union[str, Sequence[str], None] = '20260908_fix_legacy_transaction_type_both'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# Initial limits from the SAD specification. These are POLICY: finance changes
# them by closing this row (effective_to) and inserting a successor, never by
# editing history in place.
_SEED_POLICY = {
    'tolerance_cash': 5.00,
    'tolerance_weight': 0.050,
    'period_cap_cash': 50.00,
    'period_cap_weight': 0.500,
    'review_threshold_cash': 500.00,
}


def _policy_row_count(bind) -> int:
    return int(
        bind.execute(sa.text('SELECT COUNT(*) FROM supplier_settlement_policy')).scalar() or 0
    )


def upgrade() -> None:
    bind = op.get_bind()
    inspector = inspect(bind)

    # ── PRE-CHECK ─────────────────────────────────────────────────────────────
    policy_existed = inspector.has_table('supplier_settlement_policy')
    adjustment_existed = inspector.has_table('supplier_settlement_adjustment')
    policies_before = _policy_row_count(bind) if policy_existed else 0
    print(
        f'[SAD migration] PRE-CHECK — policy table: {"exists" if policy_existed else "absent"} '
        f'({policies_before} rows) · adjustment table: '
        f'{"exists" if adjustment_existed else "absent"}'
    )

    if not inspector.has_table('supplier_settlement_policy'):
        op.create_table(
            'supplier_settlement_policy',
            sa.Column('id', sa.Integer(), nullable=False),
            sa.Column('tolerance_cash', sa.Float(), nullable=False),
            sa.Column('tolerance_weight', sa.Float(), nullable=False),
            sa.Column('period_cap_cash', sa.Float(), nullable=False),
            sa.Column('period_cap_weight', sa.Float(), nullable=False),
            sa.Column('review_threshold_cash', sa.Float(), nullable=False),
            sa.Column('effective_from', sa.DateTime(), nullable=False),
            sa.Column('effective_to', sa.DateTime(), nullable=True),
            sa.Column('notes', sa.Text(), nullable=True),
            sa.Column('created_by', sa.String(length=100), nullable=True),
            sa.Column('created_at', sa.DateTime(), nullable=False, server_default=func.now()),
            sa.PrimaryKeyConstraint('id'),
        )
        op.create_index(
            'ix_supplier_settlement_policy_effective_from',
            'supplier_settlement_policy',
            ['effective_from'],
        )
        op.create_index(
            'ix_supplier_settlement_policy_effective_to',
            'supplier_settlement_policy',
            ['effective_to'],
        )

    if not inspector.has_table('supplier_settlement_adjustment'):
        op.create_table(
            'supplier_settlement_adjustment',
            sa.Column('id', sa.Integer(), nullable=False),
            sa.Column('adjustment_number', sa.String(length=50), nullable=False),
            sa.Column(
                'supplier_id',
                sa.Integer(),
                sa.ForeignKey('supplier.id', name='fk_ssa_supplier'),
                nullable=False,
            ),
            sa.Column('status', sa.String(length=20), nullable=False, server_default='draft'),
            sa.Column('reason_code', sa.String(length=50), nullable=False),
            sa.Column('note', sa.Text(), nullable=True),

            # Snapshot captured at draft creation / recalculation
            sa.Column('snapshot_schema_version', sa.Integer(), nullable=False, server_default='1'),
            sa.Column('balance_before_financial', sa.Float(), nullable=False, server_default='0'),
            sa.Column('balance_before_weight', sa.Text(), nullable=True),
            sa.Column('snapshot_captured_at', sa.DateTime(), nullable=True),

            # What was actually posted
            sa.Column('posted_amount_cash', sa.Float(), nullable=True),
            sa.Column('posted_amount_weight', sa.Text(), nullable=True),

            # Policy in force at post() time, frozen for audit
            sa.Column(
                'policy_id',
                sa.Integer(),
                sa.ForeignKey('supplier_settlement_policy.id', name='fk_ssa_policy'),
                nullable=True,
            ),
            sa.Column('period_key', sa.String(length=7), nullable=True),

            # Accounting effect. voucher_id is UNIQUE so the database itself
            # refuses a second posting of the same adjustment.
            sa.Column(
                'voucher_id',
                sa.Integer(),
                sa.ForeignKey('voucher.id', name='fk_ssa_voucher'),
                nullable=True,
            ),
            sa.Column(
                'journal_entry_id',
                sa.Integer(),
                sa.ForeignKey('journal_entry.id', name='fk_ssa_journal_entry'),
                nullable=True,
            ),

            # Reversal chain. UNIQUE: an adjustment is reversed at most once.
            sa.Column(
                'reversal_of_id',
                sa.Integer(),
                sa.ForeignKey('supplier_settlement_adjustment.id', name='fk_ssa_reversal_of'),
                nullable=True,
            ),

            # Audit trail
            sa.Column('created_by', sa.String(length=100), nullable=False),
            sa.Column('created_at', sa.DateTime(), nullable=False, server_default=func.now()),
            sa.Column('approved_by', sa.String(length=100), nullable=True),
            sa.Column('approved_at', sa.DateTime(), nullable=True),
            sa.Column('approved_by_manager', sa.Boolean(), nullable=False, server_default=sa.false()),
            sa.Column('posted_by', sa.String(length=100), nullable=True),
            sa.Column('posted_at', sa.DateTime(), nullable=True),
            sa.Column('reversed_by', sa.String(length=100), nullable=True),
            sa.Column('reversed_at', sa.DateTime(), nullable=True),
            sa.Column('reversal_reason', sa.Text(), nullable=True),
            sa.Column('cancelled_by', sa.String(length=100), nullable=True),
            sa.Column('cancelled_at', sa.DateTime(), nullable=True),
            sa.Column('cancellation_reason', sa.Text(), nullable=True),

            sa.PrimaryKeyConstraint('id'),
            sa.UniqueConstraint('adjustment_number', name='uq_ssa_adjustment_number'),
            sa.UniqueConstraint('voucher_id', name='uq_ssa_voucher_id'),
            sa.UniqueConstraint('reversal_of_id', name='uq_ssa_reversal_of_id'),
        )
        op.create_index(
            'ix_supplier_settlement_adjustment_adjustment_number',
            'supplier_settlement_adjustment',
            ['adjustment_number'],
        )
        op.create_index(
            'ix_supplier_settlement_adjustment_supplier_id',
            'supplier_settlement_adjustment',
            ['supplier_id'],
        )
        op.create_index(
            'ix_supplier_settlement_adjustment_status',
            'supplier_settlement_adjustment',
            ['status'],
        )
        op.create_index(
            'ix_supplier_settlement_adjustment_period_key',
            'supplier_settlement_adjustment',
            ['period_key'],
        )
        op.create_index(
            'idx_ssa_supplier_status',
            'supplier_settlement_adjustment',
            ['supplier_id', 'status'],
        )
        op.create_index(
            'idx_ssa_supplier_period',
            'supplier_settlement_adjustment',
            ['supplier_id', 'period_key'],
        )

    # ── Seed ──────────────────────────────────────────────────────────────────
    # Keyed on "is there a policy?", never on "did we just create the table?".
    # A database the app has already booted against has both tables from
    # db.create_all(); tying the seed to creation would skip it there and leave
    # SAD with no policy in force.
    seeded = False
    policies_now = _policy_row_count(bind)
    if policies_now == 0:
        bind.execute(
            sa.text(
                # created_at is written explicitly rather than left to a default:
                # the model declares it as a client-side ORM default, so a table
                # created by db.create_all() carries NOT NULL with no server
                # DEFAULT and rejects an INSERT that omits it.
                'INSERT INTO supplier_settlement_policy '
                '(tolerance_cash, tolerance_weight, period_cap_cash, period_cap_weight, '
                ' review_threshold_cash, effective_from, created_at, notes, created_by) '
                'VALUES (:tolerance_cash, :tolerance_weight, :period_cap_cash, '
                ' :period_cap_weight, :review_threshold_cash, CURRENT_TIMESTAMP, '
                ' CURRENT_TIMESTAMP, :notes, :created_by)'
            ),
            {
                **_SEED_POLICY,
                'notes': (
                    'القيم الابتدائية من مواصفة SAD. تُغيَّر بإغلاق هذا الصف '
                    '(effective_to) وإدراج صف خلف له، لا بالتعديل في مكانه.'
                ),
                'created_by': 'migration:20260916_supplier_settlement_adjustment',
            },
        )
        seeded = True
    else:
        print(
            f'[SAD migration] policy table already holds {policies_now} row(s) — '
            'left untouched, no seed inserted.'
        )

    # ── POST-CHECK ────────────────────────────────────────────────────────────
    inspector = inspect(bind)
    for table in ('supplier_settlement_policy', 'supplier_settlement_adjustment'):
        if not inspector.has_table(table):
            raise RuntimeError(f'[SAD migration] POST-CHECK failed: {table} is missing.')

    policies_after = _policy_row_count(bind)
    if policies_after < 1:
        raise RuntimeError(
            '[SAD migration] POST-CHECK failed: no SupplierSettlementPolicy in force. '
            'SAD would refuse every operation.'
        )
    if not seeded and policies_after != policies_before:
        raise RuntimeError(
            '[SAD migration] POST-CHECK failed: existing policy rows changed '
            f'({policies_before} → {policies_after}). Migration must not touch them.'
        )

    # ── REPORT ────────────────────────────────────────────────────────────────
    print(
        f'[SAD migration] REPORT — tables: '
        f'policy {"created" if not policy_existed else "pre-existing"}, '
        f'adjustment {"created" if not adjustment_existed else "pre-existing"} · '
        f'policy rows {policies_before} → {policies_after} '
        f'({"seeded initial policy" if seeded else "no seed needed"})'
    )


def downgrade() -> None:
    bind = op.get_bind()
    inspector = inspect(bind)

    if inspector.has_table('supplier_settlement_adjustment'):
        op.drop_table('supplier_settlement_adjustment')
    if inspector.has_table('supplier_settlement_policy'):
        op.drop_table('supplier_settlement_policy')
