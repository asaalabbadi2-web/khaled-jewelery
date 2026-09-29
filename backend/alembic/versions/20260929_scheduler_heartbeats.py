"""scheduler_heartbeats: "I am alive", written by the scheduler, read by the backend

The settlement alarm runs inside the scheduler container, so that container's
death raised nothing (SCHED-004). The scheduler now writes one row per
scheduler -- 'erp-scheduler' each minute, 'clearing_settlement' each wake --
and the backend keeps a critical 'scheduler_down' alert open in the bell while
one is silent (services/scheduler_heartbeat.py).

ADDITIVE AND BEHAVIOUR-NEUTRAL: one new table, no change to any existing one,
no backfill. Idempotent: backend/app.py runs db.create_all() at import, so the
table may already exist when this runs.

Revision ID: 20260929_scheduler_heartbeats
Revises: 20260928_rf_subject
Create Date: 2026-09-29
"""
from alembic import op
import sqlalchemy as sa

revision = '20260929_scheduler_heartbeats'
down_revision = '20260928_rf_subject'
branch_labels = None
depends_on = None

TABLE = 'scheduler_heartbeats'


def upgrade():
    inspector = sa.inspect(op.get_bind())
    if TABLE in set(inspector.get_table_names()):
        return
    op.create_table(
        TABLE,
        sa.Column('name', sa.String(length=50), primary_key=True),
        sa.Column('beat_at', sa.DateTime(), nullable=False),
        sa.Column('pid', sa.Integer(), nullable=True),
        sa.Column('host', sa.String(length=100), nullable=True),
    )


def downgrade():
    inspector = sa.inspect(op.get_bind())
    if TABLE in set(inspector.get_table_names()):
        op.drop_table(TABLE)
