"""race_honour: the months an employee led the race, and the periods they reached their goal (24 Oct 2026)

SCHEMA, ADDITIVE.

race_honour -- one row per (employee, kind, period, period_start): kind
               'leader' for a month led by points, 'goal' for a closed period
               of the employee's own goal that reached its target. Kept when
               the period closes (the owner, bonus study م3هـ: «سجل محفوظ»),
               so a later change of the race's settings does not rewrite it.

IMPACT: a new, empty table. Nothing reads it but the race card's counters,
which show none until it is filled: after deploy, the owner fills the past
with tools/repair/race_honours.py (dry run, then --apply). Downgrade drops it.

Revision ID: 20261024_race_honour
Revises: 20261024_bonus_rule_tiers
Create Date: 2026-10-24
"""
from alembic import op
import sqlalchemy as sa

revision = '20261024_race_honour'
down_revision = '20261024_bonus_rule_tiers'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        'race_honour',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('employee_id', sa.Integer(), sa.ForeignKey('employee.id'), nullable=False),
        sa.Column('kind', sa.String(10), nullable=False),
        sa.Column('period', sa.String(10), nullable=False),
        sa.Column('period_start', sa.Date(), nullable=False),
        sa.Column('period_end', sa.Date(), nullable=False),
        sa.Column('value', sa.Float(), nullable=False),
        sa.Column('target', sa.Float(), nullable=True),
        sa.Column('recorded_at', sa.DateTime(), nullable=False),
        sa.UniqueConstraint('employee_id', 'kind', 'period', 'period_start', name='uq_race_honour_once'),
        sa.CheckConstraint("kind IN ('leader', 'goal')", name='ck_race_honour_kind'),
    )
    op.create_index('ix_race_honour_employee_id', 'race_honour', ['employee_id'])


def downgrade():
    op.drop_index('ix_race_honour_employee_id', table_name='race_honour')
    op.drop_table('race_honour')
