"""vat_policy_period: VAT is a dated policy -- inputs recovered, sales charged (ADR-043, phase 4a)

ADDITIVE, plus two rows set on evidence.

The owner (11 Oct 2026): «مسجّلة في المدخلات والمخرجات لا، وهذا وضع مؤقت وليس
دائم». Creates vat_policy_period (effective_from unique, input_vat_recoverable,
sales_vat_charged, note, created_by, created_at) -- an invoice reads the period
in force on its date (services/vat_policy.py) -- and seeds it from the record:

  from the books' start (2000-01-01 here): inputs recovered, sales taxed
  from 2 May 2026, when settings.sales_vat_enabled is off: inputs recovered,
      sales untaxed -- the evening of 1 May the sales stopped carrying VAT
      (SALES-VAT-1, measured on the 6 Oct copy; 20261007_sales_vat_setting
      turned the switch off on that evidence)

Idempotent: the table and the rows only when absent.

IMPACT: none on existing invoices or entries. A sale is taxed by its date's
period instead of today's switch -- the same answer for every sale dated
from 2 May 2026 on. Downgrade drops the table.

Revision ID: 20261011_vat_policy_period
Revises: 20261011_account_is_active
Create Date: 2026-10-11
"""
from alembic import op
import sqlalchemy as sa

revision = '20261011_vat_policy_period'
down_revision = '20261011_account_is_active'
branch_labels = None
depends_on = None

SWITCHED_OFF = '2026-05-02'


def upgrade():
    bind = op.get_bind()
    if 'vat_policy_period' not in sa.inspect(bind).get_table_names():
        op.create_table(
            'vat_policy_period',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('effective_from', sa.Date(), nullable=False),
            sa.Column('input_vat_recoverable', sa.Boolean(), nullable=False, server_default=sa.true()),
            sa.Column('sales_vat_charged', sa.Boolean(), nullable=False, server_default=sa.true()),
            sa.Column('note', sa.String(300), nullable=True),
            sa.Column('created_by', sa.String(100), nullable=True),
            sa.Column('created_at', sa.DateTime(), server_default=sa.func.now()),
        )
        op.create_index('ix_vat_policy_period_effective_from', 'vat_policy_period', ['effective_from'], unique=True)
    if bind.execute(sa.text('SELECT count(*) FROM vat_policy_period')).scalar():
        return
    bind.execute(sa.text(
        "INSERT INTO vat_policy_period (effective_from, input_vat_recoverable, sales_vat_charged, note, created_by) "
        "VALUES ('2000-01-01', true, true, 'from the books: sales taxed, inputs recovered', 'migration')"))
    off = bind.execute(sa.text('SELECT sales_vat_enabled FROM settings ORDER BY id LIMIT 1')).scalar()
    if off is False:
        bind.execute(sa.text(
            "INSERT INTO vat_policy_period (effective_from, input_vat_recoverable, sales_vat_charged, note, created_by) "
            f"VALUES ('{SWITCHED_OFF}', true, false, "
            "'the owner: inputs recovered, sales untaxed -- temporary (11 Oct 2026); untaxed since the evening of 1 May', "
            "'migration')"))
    print('[vat_policy_period] seeded', bind.execute(sa.text(
        'SELECT effective_from, input_vat_recoverable, sales_vat_charged FROM vat_policy_period '
        'ORDER BY effective_from')).fetchall())


def downgrade():
    if 'vat_policy_period' in sa.inspect(op.get_bind()).get_table_names():
        op.drop_index('ix_vat_policy_period_effective_from', table_name='vat_policy_period')
        op.drop_table('vat_policy_period')
