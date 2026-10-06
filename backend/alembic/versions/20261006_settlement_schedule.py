"""settlement_schedule: a settlement is dated the day its money reaches the bank (ADR-037, the owner 6 Oct 2026)

ADDITIVE, plus one reading of four existing columns.

Adds to payment_method:
  - bank_weekend_days   VARCHAR(20) NOT NULL DEFAULT ''   -- '4,5' = Friday, Saturday
  - skip_public_holidays BOOLEAN    NOT NULL DEFAULT false
and the table public_holiday (holiday_date UNIQUE, name).

Reads the existing schedule columns the way services/settlement_schedule.py
does from now on -- the batch and its deposit day -- converting each method so
it keeps the days it ran on:

  - a weekly method (settlement_schedule_type 'weekday'): settlement_weekday
    was the settlement day, run deposit_delay_days later on payments up to
    max(settlement_days, 1) + delay days before the run. Now settlement_weekday
    is the batch's last day and the deposit a fixed weekday: the run's.
    Tamara: settlement Saturday + 4 -> batch ends Friday, deposit Wednesday.
  - a daily method with a fixed deposit weekday ran once a week on that
    weekday, on payments up to settlement_days before it: it is a weekly
    batch. Tabby: Monday, 1 day -> batch ends Sunday, deposit Monday.
  - a daily method with a deposit after N days keeps its N: Mada 1.

IMPACT: what changes is the voucher's DATE -- from the sale day (daily) or the
run (weekly) to the deposit day -- and Tabby's settlement becomes one voucher
per Monday instead of one per sale day. The minimum is not touched (the owner
sets Tabby's to 0 for its fixed plan in the screen). Downgrade drops the two
columns and the table; the converted readings are not restored.

Revision ID: 20261006_settlement_schedule
Revises: 20261003_finding_acceptance
Create Date: 2026-10-06
"""
from alembic import op
import sqlalchemy as sa

revision = '20261006_settlement_schedule'
down_revision = '20261003_finding_acceptance'
branch_labels = None
depends_on = None


def convert(schedule_type, settlement_days, settlement_weekday, deposit_type, deposit_delay, deposit_weekday):
    """The legacy columns -> the new reading of the same columns, or None
    when the row reads the same under both (a daily method deposited after N days)."""
    schedule_type = (schedule_type or 'days').strip().lower()
    deposit_type = (deposit_type or 'days').strip().lower()
    sd = int(settlement_days or 0)
    delay = int(deposit_delay or 0)
    if schedule_type == 'weekday' and settlement_weekday is not None:
        if deposit_type == 'weekday' and deposit_weekday is not None:
            run, lag = int(deposit_weekday), max(sd, 1)
        else:
            run, lag = (int(settlement_weekday) + delay) % 7, max(sd, 1) + delay
        return {'settlement_schedule_type': 'weekday', 'settlement_weekday': (run - lag) % 7,
                'deposit_schedule_type': 'weekday', 'deposit_weekday': run, 'deposit_delay_days': 0}
    if schedule_type == 'days' and deposit_type == 'weekday' and deposit_weekday is not None:
        run = int(deposit_weekday)
        return {'settlement_schedule_type': 'weekday', 'settlement_weekday': (run - max(sd, 1)) % 7,
                'deposit_schedule_type': 'weekday', 'deposit_weekday': run, 'deposit_delay_days': 0}
    return None


def upgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    existing = {c['name'] for c in inspector.get_columns('payment_method')}
    if 'bank_weekend_days' not in existing:
        op.add_column('payment_method', sa.Column('bank_weekend_days', sa.String(20), nullable=False,
                                                  server_default=''))
    if 'skip_public_holidays' not in existing:
        op.add_column('payment_method', sa.Column('skip_public_holidays', sa.Boolean(), nullable=False,
                                                  server_default=sa.false()))
    if 'public_holiday' not in inspector.get_table_names():
        op.create_table(
            'public_holiday',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('holiday_date', sa.Date(), nullable=False),
            sa.Column('name', sa.String(100), nullable=False),
            sa.Column('created_at', sa.DateTime(), server_default=sa.func.now()),
        )
        op.create_index('ix_public_holiday_holiday_date', 'public_holiday', ['holiday_date'], unique=True)

    rows = bind.execute(sa.text(
        'SELECT id, settlement_schedule_type, settlement_days, settlement_weekday, '
        'deposit_schedule_type, deposit_delay_days, deposit_weekday FROM payment_method')).fetchall()
    for r in rows:
        new = convert(r[1], r[2], r[3], r[4], r[5], r[6])
        if new is None:
            continue
        bind.execute(sa.text(
            'UPDATE payment_method SET settlement_schedule_type = :settlement_schedule_type, '
            'settlement_weekday = :settlement_weekday, deposit_schedule_type = :deposit_schedule_type, '
            'deposit_weekday = :deposit_weekday, deposit_delay_days = :deposit_delay_days WHERE id = :id'),
            dict(new, id=r[0]))


def downgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if 'public_holiday' in inspector.get_table_names():
        op.drop_index('ix_public_holiday_holiday_date', table_name='public_holiday')
        op.drop_table('public_holiday')
    existing = {c['name'] for c in inspector.get_columns('payment_method')}
    for name in ('skip_public_holidays', 'bank_weekend_days'):
        if name in existing:
            op.drop_column('payment_method', name)
