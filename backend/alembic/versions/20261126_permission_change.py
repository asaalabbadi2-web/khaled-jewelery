"""Every change of a user's role or permissions is recorded, append-only (ADR-103).

Revision ID: 20261126_permission_change
Revises: 20261125_settings_change

Impact -- no data changes: a new table, permission_change (empty), and its
trigger refusing UPDATE, DELETE and TRUNCATE outside a system purge. The new
permission system.financial_settings lives in the code's catalog
(permissions.py): no account is granted it by this migration -- the system
admin holds every permission by the code, as before. Downgrade drops the
trigger and the table, and with them the record of every grant since.
"""
import os
import sys

from alembic import op
import sqlalchemy as sa

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from append_only_trigger import drop_sql, install_sql  # noqa: E402

revision = '20261126_permission_change'
down_revision = '20261125_settings_change'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'permission_change',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('changed_at', sa.DateTime(), nullable=False),
        sa.Column('actor', sa.String(120), nullable=False),
        sa.Column('actor_user_id', sa.Integer(), nullable=True),
        sa.Column('target_user_id', sa.Integer(), nullable=False),
        sa.Column('target_username', sa.String(120), nullable=True),
        sa.Column('kind', sa.String(16), nullable=False),
        sa.Column('key', sa.String(80), nullable=False),
        sa.Column('old_value', sa.Text(), nullable=True),
        sa.Column('new_value', sa.Text(), nullable=True),
        sa.Column('source_ip', sa.String(64), nullable=True),
    )
    op.create_index('ix_permission_change_target_user_id', 'permission_change', ['target_user_id'])
    op.execute(install_sql('permission_change'))


def downgrade():
    op.execute(drop_sql('permission_change'))
    op.drop_index('ix_permission_change_target_user_id', table_name='permission_change')
    op.drop_table('permission_change')
