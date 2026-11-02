"""employee_pay_split: a salary paid part by bank, part by cash (PAY-SPLIT)

SCHEMA, additive. The owner, 2 Nov 2026 («نعم ابنها وتضبط من الإعدادات بمبلغ
المحول من البنك والمبلغ النقدي وقابلة للتعديل أثناء خطوة إصدار سند الصرف»,
and «مبلغ ثابت، والباقي بالأخرى»): an employee was paid by one way, the whole
net. Two nullable columns on employee: the way a fixed amount is paid by
('bank' / 'cash') and that amount; the rest of the net is paid by the other
way. NULL: no split, the whole by payment_method.

Impact: two nullable columns, no row written. Idempotent (the boot's
create_all may come first, ADR-023's pattern). Downgrade drops them.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261102_employee_pay_split'
down_revision = '20261101_employee_termination'
branch_labels = None
depends_on = None


def upgrade():
    columns = {c['name'] for c in sa.inspect(op.get_bind()).get_columns('employee')}
    if 'split_method' not in columns:
        op.add_column('employee', sa.Column('split_method', sa.String(10), nullable=True))
    if 'split_amount' not in columns:
        op.add_column('employee', sa.Column('split_amount', sa.Float(), nullable=True))


def downgrade():
    op.drop_column('employee', 'split_amount')
    op.drop_column('employee', 'split_method')
