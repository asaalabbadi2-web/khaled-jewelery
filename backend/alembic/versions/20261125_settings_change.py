"""Every change of a setting is recorded, and the record is append-only (ADR-102).

Revision ID: 20261125_settings_change
Revises: 20261125_commission_tax_invoice

Impact -- no data changes: a new table, settings_change (empty), and its
trigger refusing UPDATE, DELETE and TRUNCATE outside a system purge. The
settings row itself is not touched; a key never changed has version 0.
Downgrade drops the trigger and the table -- and with it the record of every
change made since: export it first if it is to be kept.
"""
import os
import sys

from alembic import op
import sqlalchemy as sa

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from settings_change_trigger import DROP_SQL, INSTALL_SQL  # noqa: E402

revision = '20261125_settings_change'
down_revision = '20261125_commission_tax_invoice'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'settings_change',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('changed_at', sa.DateTime(), nullable=False),
        sa.Column('actor', sa.String(120), nullable=False),
        sa.Column('actor_type', sa.String(16), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=True),
        sa.Column('source_ip', sa.String(64), nullable=True),
        sa.Column('user_agent', sa.String(300), nullable=True),
        sa.Column('device_label', sa.String(120), nullable=True),
        sa.Column('request_id', sa.String(40), nullable=False),
        sa.Column('key', sa.String(80), nullable=False),
        sa.Column('level', sa.Integer(), nullable=False),
        sa.Column('old_value', sa.Text(), nullable=True),
        sa.Column('new_value', sa.Text(), nullable=True),
        sa.Column('reason', sa.Text(), nullable=True),
    )
    op.create_index('ix_settings_change_key', 'settings_change', ['key'])
    op.create_index('ix_settings_change_request_id', 'settings_change', ['request_id'])
    op.execute(INSTALL_SQL)


def downgrade():
    op.execute(DROP_SQL)
    op.drop_index('ix_settings_change_request_id', table_name='settings_change')
    op.drop_index('ix_settings_change_key', table_name='settings_change')
    op.drop_table('settings_change')
