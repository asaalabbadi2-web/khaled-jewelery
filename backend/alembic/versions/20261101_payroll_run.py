"""payroll_run: a month's payroll, one document (PAYROLL-2, M2b)

SCHEMA, additive. The owner, 1 Nov 2026 («اودع وابدأ» to the monthly run): a
month is drafted from the salary structures, reviewed, approved with one
accrual and paid in a batch -- five entries and five accruals a month were
kept by hand. One regular run a month (a partial unique index: a cancelled
run is not counted); each entry says its run and what it was drafted from.

Impact: one new table, two payroll columns (NULL on every legacy entry); the
payroll's unique (employee, month, year) becomes a partial unique index over
the entries not cancelled -- a cancelled entry holds no month, so a cancelled
run is drafted again. Every standing entry on the 31 Oct copy is unique by it.
Idempotent: the boot's create_all and schema guard may come first (ADR-023's
pattern). Downgrade drops what it added.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261101_payroll_run'
down_revision = '20261101_payroll_structures'
branch_labels = None
depends_on = None


def upgrade():
    inspector = sa.inspect(op.get_bind())
    if not inspector.has_table('payroll_run'):
        op.create_table(
            'payroll_run',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('month', sa.Integer(), nullable=False),
            sa.Column('year', sa.Integer(), nullable=False),
            sa.Column('kind', sa.String(20), nullable=False, server_default='regular'),
            sa.Column('status', sa.String(20), nullable=False, server_default='draft'),
            sa.Column('policy_snapshot', sa.Text(), nullable=True),
            sa.Column('notes', sa.Text(), nullable=True),
            sa.Column('created_by', sa.String(100), nullable=True),
            sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
            sa.Column('approved_by', sa.String(100), nullable=True),
            sa.Column('approved_at', sa.DateTime(), nullable=True),
        )
    if 'uq_payroll_run_month' not in {i['name'] for i in sa.inspect(op.get_bind()).get_indexes('payroll_run')}:
        op.create_index('uq_payroll_run_month', 'payroll_run', ['month', 'year', 'kind'], unique=True,
                        postgresql_where=sa.text("status <> 'cancelled'"))
    columns = {c['name'] for c in sa.inspect(op.get_bind()).get_columns('payroll')}
    if 'payroll_run_id' not in columns:
        op.add_column('payroll', sa.Column('payroll_run_id', sa.Integer(), sa.ForeignKey('payroll_run.id'),
                                           nullable=True))
    elif not any(fk['referred_table'] == 'payroll_run'
                 for fk in sa.inspect(op.get_bind()).get_foreign_keys('payroll')):
        # the boot's schema guard adds a bare column -- its key is added here
        op.create_foreign_key('fk_payroll_payroll_run_id', 'payroll', 'payroll_run',
                              ['payroll_run_id'], ['id'])
    if 'breakdown' not in columns:
        op.add_column('payroll', sa.Column('breakdown', sa.Text(), nullable=True))
    if 'ix_payroll_payroll_run_id' not in {i['name'] for i in sa.inspect(op.get_bind()).get_indexes('payroll')}:
        op.create_index('ix_payroll_payroll_run_id', 'payroll', ['payroll_run_id'])


    if 'uq_payroll_employee_month' not in {i['name'] for i in sa.inspect(op.get_bind()).get_indexes('payroll')}:
        op.create_index('uq_payroll_employee_month', 'payroll', ['employee_id', 'month', 'year'], unique=True,
                        postgresql_where=sa.text("status <> 'cancelled'"))
    if '_employee_month_year_uc' in {c['name'] for c in sa.inspect(op.get_bind()).get_unique_constraints('payroll')}:
        op.drop_constraint('_employee_month_year_uc', 'payroll', type_='unique')


def downgrade():
    # Refused by the database when a month holds a cancelled entry and a standing one.
    op.create_unique_constraint('_employee_month_year_uc', 'payroll', ['employee_id', 'month', 'year'])
    op.drop_index('uq_payroll_employee_month', table_name='payroll')
    op.drop_index('ix_payroll_payroll_run_id', table_name='payroll')
    op.drop_column('payroll', 'breakdown')
    op.drop_column('payroll', 'payroll_run_id')
    op.drop_index('uq_payroll_run_month', table_name='payroll_run')
    op.drop_table('payroll_run')
