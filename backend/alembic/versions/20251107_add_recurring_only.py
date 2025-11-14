"""add recurring journal system only

Revision ID: 20251107_add_recurring_only
Revises: 4e6c2a3d1f8b
Create Date: 2025-11-07 21:30:00

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '20251107_add_recurring_only'
down_revision = '4e6c2a3d1f8b'
branch_labels = None
depends_on = None


def upgrade():
    # إضافة حقل recurring_template_id لجدول journal_entry
    with op.batch_alter_table('journal_entry', schema=None) as batch_op:
        batch_op.add_column(
            sa.Column('recurring_template_id', sa.Integer(), nullable=True)
        )
        batch_op.create_foreign_key(
            'fk_journal_entry_recurring_template',
            'recurring_journal_template',
            ['recurring_template_id'],
            ['id']
        )

    # إنشاء جدول قوالب القيود الدورية
    op.create_table(
        'recurring_journal_template',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('name', sa.String(length=200), nullable=False),
        sa.Column('description', sa.String(length=500), nullable=True),
        sa.Column('frequency', sa.String(length=50), nullable=False),
        sa.Column('interval', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('start_date', sa.DateTime(), nullable=False),
        sa.Column('end_date', sa.DateTime(), nullable=True),
        sa.Column('next_run_date', sa.DateTime(), nullable=False),
        sa.Column('preferred_day_of_month', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('is_active', sa.Boolean(), nullable=False, server_default='1'),
        sa.Column('auto_create', sa.Boolean(), nullable=False, server_default='1'),
        sa.Column('last_created_date', sa.DateTime(), nullable=True),
        sa.Column('total_created', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.Column('created_by', sa.String(length=100), nullable=True),
        sa.PrimaryKeyConstraint('id')
    )

    # إنشاء جدول خطوط القيود الدورية
    op.create_table(
        'recurring_journal_line',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('template_id', sa.Integer(), nullable=False),
        sa.Column('account_id', sa.Integer(), nullable=False),
        sa.Column('cash_debit', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('cash_credit', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('debit_18k', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('credit_18k', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('debit_21k', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('credit_21k', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('debit_22k', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('credit_22k', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('debit_24k', sa.Float(), nullable=False, server_default='0.0'),
        sa.Column('credit_24k', sa.Float(), nullable=False, server_default='0.0'),
        sa.ForeignKeyConstraint(['template_id'], ['recurring_journal_template.id'], ),
        sa.ForeignKeyConstraint(['account_id'], ['account.id'], ),
        sa.PrimaryKeyConstraint('id')
    )


def downgrade():
    # حذف الجداول
    op.drop_table('recurring_journal_line')
    op.drop_table('recurring_journal_template')

    # إزالة الحقل من journal_entry
    with op.batch_alter_table('journal_entry', schema=None) as batch_op:
        batch_op.drop_constraint('fk_journal_entry_recurring_template', type_='foreignkey')
        batch_op.drop_column('recurring_template_id')
