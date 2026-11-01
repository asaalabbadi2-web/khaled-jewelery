"""employee_leave: kinds of leave and an employee's leaves (EMP-4, ش4)

SCHEMA, additive, with the owner's kinds. The owner, 1 Nov 2026 («لِمَ لا،
اقتراحك؟» -- «اودع وابدأ»): no leave was kept. Seeded: three kinds, names and
whether paid and accruing only -- السنوية (paid, accrues), المرضية (paid),
بدون أجر (unpaid) -- no days: the owner enters them (the Labour Law's 21, 30
after five years, art. 109; sick art. 117), as he asked of every figure.

Impact: two new tables, three rows in one. Idempotent (the boot's create_all
may come first, ADR-023's pattern); a kind already there is kept. Downgrade
drops the tables.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261101_employee_leave'
down_revision = '20261101_employee_contracts_documents'
branch_labels = None
depends_on = None

KINDS = (('السنوية', True, True), ('المرضية', True, False), ('بدون أجر', False, False))


def upgrade():
    inspector = sa.inspect(op.get_bind())
    if not inspector.has_table('leave_type'):
        op.create_table(
            'leave_type',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('name', sa.String(100), nullable=False, unique=True),
            sa.Column('paid', sa.Boolean(), nullable=False, server_default=sa.true()),
            sa.Column('accrues', sa.Boolean(), nullable=False, server_default=sa.false()),
            sa.Column('days_per_year', sa.Float(), nullable=True),
            sa.Column('longer_after_years', sa.Integer(), nullable=True),
            sa.Column('longer_days_per_year', sa.Float(), nullable=True),
            sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()),
        )
    if not inspector.has_table('employee_leave'):
        op.create_table(
            'employee_leave',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('employee_id', sa.Integer(), sa.ForeignKey('employee.id'), nullable=False, index=True),
            sa.Column('type_id', sa.Integer(), sa.ForeignKey('leave_type.id'), nullable=False, index=True),
            sa.Column('start_date', sa.Date(), nullable=False),
            sa.Column('end_date', sa.Date(), nullable=False),
            sa.Column('days', sa.Integer(), nullable=False),
            sa.Column('status', sa.String(20), nullable=False, server_default='approved'),
            sa.Column('notes', sa.Text(), nullable=True),
            sa.Column('created_by', sa.String(100), nullable=True),
            sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
            sa.Column('decided_by', sa.String(100), nullable=True),
            sa.Column('decided_at', sa.DateTime(), nullable=True),
        )
    bind = op.get_bind()
    for name, paid, accrues in KINDS:
        if bind.execute(sa.text('SELECT 1 FROM leave_type WHERE name = :n'), {'n': name}).first() is None:
            bind.execute(sa.text('INSERT INTO leave_type (name, paid, accrues, is_active) VALUES (:n, :p, :a, :t)'),
                         {'n': name, 'p': paid, 'a': accrues, 't': True})


def downgrade():
    op.drop_table('employee_leave')
    op.drop_table('leave_type')
