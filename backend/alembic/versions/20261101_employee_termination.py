"""employee_termination: an employee's end of service and its final settlement (EMP-5, ش5)

SCHEMA, additive. The owner, 1 Nov 2026 («عند إنهاء الخدمة: هل يحسب النظام
التسوية النهائية ويقيّدها؟ نعم» -- «اودع وابدأ»): stopping an employee was a
flag, nothing settled. One row a termination: its last day and reason, the
settlement frozen on it, its entry and its voucher.

Impact: one new table. Idempotent (the boot's create_all may come first,
ADR-023's pattern). Downgrade drops it.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261101_employee_termination'
down_revision = '20261101_employee_leave'
branch_labels = None
depends_on = None


def upgrade():
    if sa.inspect(op.get_bind()).has_table('employee_termination'):
        return
    op.create_table(
        'employee_termination',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('employee_id', sa.Integer(), sa.ForeignKey('employee.id'), nullable=False, index=True),
        sa.Column('last_day', sa.Date(), nullable=False),
        sa.Column('reason', sa.String(30), nullable=False),
        sa.Column('notes', sa.Text(), nullable=True),
        sa.Column('status', sa.String(20), nullable=False, server_default='approved'),
        sa.Column('settlement', sa.Text(), nullable=True),
        sa.Column('journal_entry_id', sa.Integer(), sa.ForeignKey('journal_entry.id'), nullable=True),
        sa.Column('voucher_id', sa.Integer(), sa.ForeignKey('voucher.id'), nullable=True),
        sa.Column('created_by', sa.String(100), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.Column('paid_at', sa.DateTime(), nullable=True),
    )


def downgrade():
    op.drop_table('employee_termination')
