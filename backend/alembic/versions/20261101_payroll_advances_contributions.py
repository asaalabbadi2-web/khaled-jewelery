"""payroll_advances_contributions: advance plans and the contribution wage (PAYROLL-3)

SCHEMA, additive. The owner, 1 Nov 2026: «طبّق النظام الأفضل والأشمل» -- the
run's accrual at the gross, a credit for each deduction -- and «طبّق النظام
المتكامل والأرقام دعها عليّ» for the contributions. An advance the books hold
(the employee's advance account, 104,000 on the 31 Oct copy) is repaid by a
plan of installments taken in the run; the contributions are reckoned on the
wage registered for them, which the owner enters.

Impact: one new table; one employee column, NULL on all. Idempotent (the
boot's create_all and schema guard may come first, ADR-023's pattern).
Downgrade drops what it added.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261101_payroll_advances_contributions'
down_revision = '20261101_payroll_run'
branch_labels = None
depends_on = None


def upgrade():
    inspector = sa.inspect(op.get_bind())
    if not inspector.has_table('employee_advance_plan'):
        op.create_table(
            'employee_advance_plan',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('employee_id', sa.Integer(), sa.ForeignKey('employee.id'), nullable=False, index=True),
            sa.Column('amount', sa.Float(), nullable=False),
            sa.Column('installment', sa.Float(), nullable=False),
            sa.Column('start_month', sa.Integer(), nullable=False),
            sa.Column('start_year', sa.Integer(), nullable=False),
            sa.Column('consent', sa.Boolean(), nullable=False, server_default=sa.false()),
            sa.Column('consent_note', sa.Text(), nullable=True),
            sa.Column('status', sa.String(20), nullable=False, server_default='active'),
            sa.Column('notes', sa.Text(), nullable=True),
            sa.Column('created_by', sa.String(100), nullable=True),
            sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
        )
    if 'contribution_wage' not in {c['name'] for c in inspector.get_columns('employee')}:
        op.add_column('employee', sa.Column('contribution_wage', sa.Float(), nullable=True))


def downgrade():
    op.drop_column('employee', 'contribution_wage')
    op.drop_table('employee_advance_plan')
