"""piece_scan, piece_scan_event, piece_scan_read, piece_scan_expected; settings' scan quiet presses and seconds (ADR-085 ت2).

Revision ID: 20261121_piece_scans
Revises: 20261120_print_jobs

Impact: four new empty tables -- a count of a location's pieces by their
tags: its session and snapshot, what the reader sent as it came, each value
read once with its frozen verdict, the location's pieces with theirs. No
entry, no stock: nothing reads these but the scan's own screens. Two
settings columns with the owner's 3 and 3 (21 Nov 2026) on every row.
Downgrade drops the columns and the tables.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261121_piece_scans'
down_revision = '20261120_print_jobs'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('settings', sa.Column('scan_quiet_presses', sa.Integer(), nullable=False, server_default='3'))
    op.add_column('settings', sa.Column('scan_quiet_seconds', sa.Float(), nullable=False, server_default='3.0'))
    op.create_table(
        'piece_scan',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('safe_box_id', sa.Integer(), sa.ForeignKey('safe_box.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('kind', sa.String(10), nullable=False),
        sa.Column('status', sa.String(10), nullable=False, server_default='open'),
        sa.Column('started_by', sa.String(100), nullable=True),
        sa.Column('started_at', sa.DateTime(), nullable=False),
        sa.Column('places', sa.JSON(), nullable=False),
        sa.Column('presses', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('finished_by', sa.String(100), nullable=True),
        sa.Column('finished_at', sa.DateTime(), nullable=True),
        sa.Column('complete', sa.Boolean(), nullable=True),
        sa.Column('early_reason', sa.String(200), nullable=True),
        sa.CheckConstraint("kind IN ('opening', 'closing', 'check')", name='ck_piece_scan_kind'),
        sa.CheckConstraint("status IN ('open', 'finished', 'abandoned')", name='ck_piece_scan_status'),
    )
    op.create_index('ix_piece_scan_safe_box_id', 'piece_scan', ['safe_box_id'])
    op.create_table(
        'piece_scan_event',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('scan_id', sa.Integer(), sa.ForeignKey('piece_scan.id', ondelete='CASCADE'), nullable=False),
        sa.Column('batch_key', sa.String(64), nullable=False),
        sa.Column('kind', sa.String(10), nullable=False),
        sa.Column('value', sa.String(40), nullable=True),
        sa.Column('press', sa.Integer(), nullable=False),
        sa.Column('at_ms', sa.Integer(), nullable=False),
        sa.Column('received_at', sa.DateTime(), nullable=False),
        sa.CheckConstraint("kind IN ('read', 'button')", name='ck_piece_scan_event_kind'),
    )
    op.create_index('ix_piece_scan_event_scan_id', 'piece_scan_event', ['scan_id'])
    op.create_index('ix_piece_scan_event_batch', 'piece_scan_event', ['scan_id', 'batch_key'])
    op.create_table(
        'piece_scan_read',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('scan_id', sa.Integer(), sa.ForeignKey('piece_scan.id', ondelete='CASCADE'), nullable=False),
        sa.Column('value', sa.String(40), nullable=False),
        sa.Column('first_press', sa.Integer(), nullable=False),
        sa.Column('first_ms', sa.Integer(), nullable=False),
        sa.Column('item_id', sa.Integer(), sa.ForeignKey('item.id', ondelete='RESTRICT'), nullable=True),
        sa.Column('verdict', sa.String(20), nullable=True),
        sa.Column('words', sa.String(300), nullable=True),
        sa.Column('moved', sa.String(200), nullable=True),
        sa.Column('resolved_attempt_id', sa.Integer(), sa.ForeignKey('print_attempt.id', ondelete='RESTRICT'),
                  nullable=True),
        sa.Column('resolved_by', sa.String(100), nullable=True),
        sa.Column('resolved_at', sa.DateTime(), nullable=True),
        sa.UniqueConstraint('scan_id', 'value', name='uq_piece_scan_read_value'),
    )
    op.create_index('ix_piece_scan_read_scan_id', 'piece_scan_read', ['scan_id'])
    op.create_table(
        'piece_scan_expected',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('scan_id', sa.Integer(), sa.ForeignKey('piece_scan.id', ondelete='CASCADE'), nullable=False),
        sa.Column('item_id', sa.Integer(), sa.ForeignKey('item.id', ondelete='RESTRICT'), nullable=False),
        sa.Column('verdict', sa.String(20), nullable=True),
        sa.Column('moved', sa.String(200), nullable=True),
        sa.UniqueConstraint('scan_id', 'item_id', name='uq_piece_scan_expected_item'),
    )
    op.create_index('ix_piece_scan_expected_scan_id', 'piece_scan_expected', ['scan_id'])


def downgrade():
    op.drop_table('piece_scan_expected')
    op.drop_table('piece_scan_read')
    op.drop_table('piece_scan_event')
    op.drop_table('piece_scan')
    op.drop_column('settings', 'scan_quiet_seconds')
    op.drop_column('settings', 'scan_quiet_presses')
