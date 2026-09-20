"""add source_voucher_id to journal_entry_line

Fixes a reversal bug: when several vouchers post into one shared/consolidated
JournalEntry (add_invoice_payment's per-invoice consolidation — see
_add_payment_lines_to_consolidated_je), cancelling any ONE of those vouchers
reversed EVERY line of the shared entry, including other vouchers' payments.
This column lets a voucher's cancellation reverse only its own lines.

Nullable, no backfill: every existing line predates this column and stays
NULL, which _reverse_voucher_journal_entry treats as "reverse the whole
entry" — the historically-correct behaviour for every JE that was never
part of a consolidation in the first place. Only newly-created consolidated
lines carry the tag.

Revision ID: 20260920_add_source_voucher_id
Revises: 20260916_supplier_settlement_adjustment
Create Date: 2026-09-20
"""
from alembic import op
import sqlalchemy as sa

revision = '20260920_add_source_voucher_id'
down_revision = '20260916_supplier_settlement_adjustment'
branch_labels = None
depends_on = None


def upgrade():
    conn = op.get_bind()
    inspector = sa.inspect(conn)

    # Idempotent: db.create_all() at application boot may have already
    # created this column from the model before this migration ever runs
    # (the established pattern in this repo — see ADR-023 / the SAD
    # migration's own PRE-CHECK for the same reason).
    columns = {c['name'] for c in inspector.get_columns('journal_entry_line')}
    has_column = 'source_voucher_id' in columns

    foreign_keys = inspector.get_foreign_keys('journal_entry_line')
    has_fk = any(
        fk.get('referred_table') == 'voucher'
        and fk.get('constrained_columns') == ['source_voucher_id']
        for fk in foreign_keys
    )

    with op.batch_alter_table('journal_entry_line', schema=None) as batch_op:
        if not has_column:
            batch_op.add_column(sa.Column('source_voucher_id', sa.Integer(), nullable=True))
        if not has_fk:
            batch_op.create_foreign_key(
                'fk_jel_source_voucher',
                'voucher',
                ['source_voucher_id'],
                ['id'],
            )

    print(
        f"[source_voucher_id migration] column existed={has_column}, "
        f"fk existed={has_fk} — nothing backfilled, no existing row touched."
    )


def downgrade():
    with op.batch_alter_table('journal_entry_line', schema=None) as batch_op:
        batch_op.drop_constraint('fk_jel_source_voucher', type_='foreignkey')
        batch_op.drop_column('source_voucher_id')
