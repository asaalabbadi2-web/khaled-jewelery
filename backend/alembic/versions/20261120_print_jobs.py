"""label_printer, print_job, print_attempt; piece_tag's generation and attempt; a label's history kept (ADR-097 ط1).

Revision ID: 20261120_print_jobs
Revises: 20261120_wage_allocation

Impact: three new empty tables; two columns on piece_tag -- generation 0 on
every row (the tags before ADR-097 are generation 0 by its law: their value
is today's format, unchanged) and attempt_id NULL (mounted by hand). And a
trigger on piece_tag, print_job and print_attempt: no row deleted, a stopped
tag and a finished attempt not changed, outside a system purge. No row's
meaning changes. Downgrade drops the trigger, the columns and the tables.
"""
import os
import sys

from alembic import op
import sqlalchemy as sa

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from piece_label_trigger import DROP_SQL, INSTALL_SQL, TABLE_SQL  # noqa: E402

revision = '20261120_print_jobs'
down_revision = '20261120_wage_allocation'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'label_printer',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('name', sa.String(100), nullable=False, unique=True),
        sa.Column('host', sa.String(255), nullable=False),
        sa.Column('port', sa.Integer(), nullable=False, server_default='9100'),
        sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('font_installed_at', sa.DateTime(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('created_by', sa.String(100), nullable=True),
    )
    op.create_table(
        'print_job',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('item_id', sa.Integer(), sa.ForeignKey('item.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('printer_id', sa.Integer(), sa.ForeignKey('label_printer.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('kind', sa.String(10), nullable=False),
        sa.Column('reason', sa.String(200), nullable=True),
        sa.Column('request_key', sa.String(100), nullable=False, unique=True),
        sa.Column('status', sa.String(20), nullable=False, server_default='pending'),
        sa.Column('requested_by', sa.String(100), nullable=True),
        sa.Column('requested_at', sa.DateTime(), nullable=False),
        sa.Column('completed_at', sa.DateTime(), nullable=True),
        sa.CheckConstraint("kind IN ('first', 'reprint')", name='ck_print_job_kind'),
        sa.CheckConstraint("status IN ('pending', 'printing', 'verifying', 'completed', 'failed', "
                           "'needs_attention')", name='ck_print_job_status'),
        sa.CheckConstraint("kind <> 'reprint' OR length(trim(coalesce(reason, ''))) > 0",
                           name='ck_print_job_reprint_reason'),
    )
    op.create_index('ix_print_job_item_id', 'print_job', ['item_id'])
    op.create_table(
        'print_attempt',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('job_id', sa.Integer(), sa.ForeignKey('print_job.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('generation', sa.Integer(), nullable=False),
        sa.Column('epc', sa.String(24), nullable=False, unique=True),
        sa.Column('started_by', sa.String(100), nullable=True),
        sa.Column('started_at', sa.DateTime(), nullable=False),
        sa.Column('sent_at', sa.DateTime(), nullable=True),
        sa.Column('read_value', sa.String(64), nullable=True),
        sa.Column('printed', sa.Boolean(), nullable=True),
        sa.Column('printed_at', sa.DateTime(), nullable=True),
        sa.Column('written', sa.Boolean(), nullable=True),
        sa.Column('verified', sa.Boolean(), nullable=True),
        sa.Column('verified_at', sa.DateTime(), nullable=True),
        sa.Column('error_code', sa.String(50), nullable=True),
        sa.Column('error_message', sa.String(300), nullable=True),
        sa.Column('resolution', sa.String(20), nullable=True),
        sa.Column('resolved_by', sa.String(100), nullable=True),
        sa.Column('finished_at', sa.DateTime(), nullable=True),
    )
    op.create_index('ix_print_attempt_job_id', 'print_attempt', ['job_id'])
    op.add_column('piece_tag', sa.Column('generation', sa.Integer(), nullable=False, server_default='0'))
    op.add_column('piece_tag', sa.Column('attempt_id', sa.Integer(),
                                         sa.ForeignKey('print_attempt.id', ondelete='RESTRICT'), nullable=True))
    op.execute(INSTALL_SQL)
    for table in ('piece_tag', 'print_job', 'print_attempt'):
        op.execute(TABLE_SQL[table])


def downgrade():
    op.execute(DROP_SQL)
    op.drop_column('piece_tag', 'attempt_id')
    op.drop_column('piece_tag', 'generation')
    op.drop_table('print_attempt')
    op.drop_table('print_job')
    op.drop_table('label_printer')
