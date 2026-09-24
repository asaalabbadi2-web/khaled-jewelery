"""per-reason settlement ceilings, in cash and gold-equivalent

A settlement difference is not one kind of decision. The parent policy carries a
single `tolerance_cash`, applied to every reason alike, so a DOCUMENTED_SUPPLIER_
WAIVER — a deliberate business act — was refused by a rounding limit of 5 SAR.
That is why most real residuals could not be settled at all, and why the limit
looked arbitrary: it was the right limit for the wrong set of decisions.

This table gives each reason its own ceilings in BOTH dimensions the business
settles in: cash in riyals, and gold as main-karat-equivalent weight (the unit the
tolerance check already used, and the only one in which karats can be compared).

It covers all THREE gates, not one. Raising only the tolerance was not enough: a
waiver given a 25,000 ceiling was still refused by a 500 review threshold and a 50
monthly cap, because those two gates read the policy's global numbers directly. The
optional columns are nullable — NULL means "use the global" — so a reason may raise
one gate and leave the others exactly as they are.

Rows hang off an effective-dated policy rather than carrying dates of their own,
so the parent's rule still governs history: correcting a limit closes the policy
and inserts a new one, never edits a row a posted settlement relied on.

BEHAVIOUR IS UNCHANGED BY THIS MIGRATION. It creates the table and seeds nothing.
SupplierSettlementPolicy.limits_for_reason() falls back to the global limits when
a reason has no row, so every reason keeps exactly the ceiling it had until
finance sets a different one — deliberately, because these are business numbers
and not mine to invent.

Revision ID: 20260925_settlement_reason_limits
Revises: 20260924_invoice_gold_tracked
Create Date: 2026-09-25
"""
from alembic import op
import sqlalchemy as sa

revision = '20260925_settlement_reason_limits'
down_revision = '20260924_invoice_gold_tracked'
branch_labels = None
depends_on = None


# The three gates a reason may redefine beyond its own tolerance. NULLABLE on
# purpose: NULL means "use the policy's global value", which is what makes this
# migration behaviour-neutral. A non-null default would have silently given every
# reason a number nobody chose.
OPTIONAL_CEILINGS = (
    'review_threshold_cash',
    'period_cap_cash',
    'period_cap_weight_main_karat',
)


def upgrade():
    conn = op.get_bind()
    inspector = sa.inspect(conn)

    if 'supplier_settlement_reason_limit' in set(inspector.get_table_names()):
        # Converge instead of assuming: this table was created by an earlier form
        # of this same migration on databases that ran it before the optional
        # ceilings existed. Skipping outright would leave those schemas short of
        # three columns the model now reads.
        existing = {
            col['name']
            for col in inspector.get_columns('supplier_settlement_reason_limit')
        }
        for column in OPTIONAL_CEILINGS:
            if column not in existing:
                op.add_column(
                    'supplier_settlement_reason_limit',
                    sa.Column(column, sa.Float(), nullable=True),
                )
        return

    op.create_table(
        'supplier_settlement_reason_limit',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column(
            'policy_id', sa.Integer(),
            sa.ForeignKey('supplier_settlement_policy.id'), nullable=False,
        ),
        sa.Column('reason_code', sa.String(length=50), nullable=False),
        sa.Column('tolerance_cash', sa.Float(), nullable=False),
        sa.Column('tolerance_weight_main_karat', sa.Float(), nullable=False),
        *[sa.Column(name, sa.Float(), nullable=True) for name in OPTIONAL_CEILINGS],
        sa.Column(
            'requires_manager_approval', sa.Boolean(),
            nullable=False, server_default='false',
        ),
        sa.UniqueConstraint('policy_id', 'reason_code', name='_settlement_reason_limit_uc'),
    )
    op.create_index(
        'ix_settlement_reason_limit_policy_id',
        'supplier_settlement_reason_limit', ['policy_id'],
    )


def downgrade():
    conn = op.get_bind()
    if 'supplier_settlement_reason_limit' not in set(sa.inspect(conn).get_table_names()):
        return
    op.drop_index(
        'ix_settlement_reason_limit_policy_id',
        table_name='supplier_settlement_reason_limit',
    )
    op.drop_table('supplier_settlement_reason_limit')
