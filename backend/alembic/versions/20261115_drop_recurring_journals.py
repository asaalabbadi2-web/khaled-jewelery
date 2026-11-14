"""recurring journals gone: the period expenses do their work (ADR-090, phase 11)

«القيود الدورية» wrote an entry from a fixed template: it knew no balance, no
voucher, no lock, no weight. On production it held no template (ref_1114, 14
Nov 2026), no entry pointed at one, and its screen hard-coded a local address
that never reached the server. The period expenses replace it (ADR-090). The
link column on journal_entry -- null in every row -- and the two tables go.

Revision ID: 20261115_drop_recurring_journals
Revises: 20261114_period_lock_pending
Create Date: 2026-11-15
"""
import sqlalchemy as sa
from alembic import op

revision = '20261115_drop_recurring_journals'
down_revision = '20261114_period_lock_pending'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if bind.dialect.name == 'postgresql':
        held = bind.execute(sa.text(
            "SELECT count(*) FROM journal_entry WHERE recurring_template_id IS NOT NULL")).scalar() \
            if 'recurring_template_id' in {c['name'] for c in inspector.get_columns('journal_entry')} else 0
        if held:
            raise RuntimeError(f'{held} entries point at a recurring template: not dropped')
        for name in ('journal_entry_recurring_template_id_fkey', 'fk_journal_entry_recurring_template'):
            op.execute(f'ALTER TABLE journal_entry DROP CONSTRAINT IF EXISTS {name}')
    if 'recurring_template_id' in {c['name'] for c in inspector.get_columns('journal_entry')}:
        op.drop_column('journal_entry', 'recurring_template_id')
    tables = set(inspector.get_table_names())
    if 'recurring_journal_line' in tables:
        op.drop_table('recurring_journal_line')
    if 'recurring_journal_template' in tables:
        op.drop_table('recurring_journal_template')


def downgrade():
    op.create_table(
        'recurring_journal_template',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('name', sa.String(length=200), nullable=False),
        sa.Column('description', sa.String(length=500), nullable=True),
        sa.Column('frequency', sa.String(length=50), nullable=False),
        sa.Column('interval', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('start_date', sa.DateTime(), nullable=False),
        sa.Column('end_date', sa.DateTime(), nullable=True),
        sa.Column('next_run_date', sa.DateTime(), nullable=False),
        sa.Column('preferred_day_of_month', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('auto_create', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('last_created_date', sa.DateTime(), nullable=True),
        sa.Column('total_created', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.Column('created_by', sa.String(length=100), nullable=True),
    )
    op.create_table(
        'recurring_journal_line',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('template_id', sa.Integer(), sa.ForeignKey('recurring_journal_template.id'), nullable=False),
        sa.Column('account_id', sa.Integer(), sa.ForeignKey('account.id'), nullable=False),
        *[sa.Column(c, sa.Float(), nullable=False, server_default='0.0') for c in (
            'cash_debit', 'cash_credit', 'debit_18k', 'credit_18k', 'debit_21k', 'credit_21k',
            'debit_22k', 'credit_22k', 'debit_24k', 'credit_24k')],
    )
    op.add_column('journal_entry', sa.Column('recurring_template_id', sa.Integer(), nullable=True))
    op.create_foreign_key('journal_entry_recurring_template_id_fkey', 'journal_entry',
                          'recurring_journal_template', ['recurring_template_id'], ['id'])
