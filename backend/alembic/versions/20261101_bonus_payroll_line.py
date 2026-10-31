"""bonus_payroll_line: an approved bonus paid inside the month's run (PAYROLL-4)

SCHEMA, additive. The owner, 1 Nov 2026 (decision 4, «المكافآت: ما تنصح به
أنت»): an approved bonus is paid with the salary, in the run -- its expense
was written when approved (5401 / the employee's bonus payable); the run's
accrual moves it to his salary payable and the line's voucher pays it. The
«add to payroll» that marked a bonus paid with no entry stays removed.

Impact: one employee_bonus column, NULL on all. Idempotent (the boot's schema
guard may come first, ADR-023's pattern). Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261101_bonus_payroll_line'
down_revision = '20261101_payroll_advances_contributions'
branch_labels = None
depends_on = None


def upgrade():
    inspector = sa.inspect(op.get_bind())
    columns = {c['name'] for c in inspector.get_columns('employee_bonus')}
    if 'payroll_id' not in columns:
        op.add_column('employee_bonus', sa.Column('payroll_id', sa.Integer(), sa.ForeignKey('payroll.id'),
                                                  nullable=True))
    elif not any(fk['referred_table'] == 'payroll' for fk in inspector.get_foreign_keys('employee_bonus')):
        op.create_foreign_key('fk_employee_bonus_payroll_id', 'employee_bonus', 'payroll', ['payroll_id'], ['id'])
    if 'ix_employee_bonus_payroll_id' not in {i['name'] for i in sa.inspect(op.get_bind()).get_indexes('employee_bonus')}:
        op.create_index('ix_employee_bonus_payroll_id', 'employee_bonus', ['payroll_id'])


def downgrade():
    op.drop_index('ix_employee_bonus_payroll_id', table_name='employee_bonus')
    op.drop_column('employee_bonus', 'payroll_id')
