"""add audit log table

Revision ID: 20251111_audit_log
Revises: 
Create Date: 2025-11-11 00:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '20251111_audit_log'
down_revision = None  # سيتم تحديثه تلقائياً
branch_labels = None
depends_on = None


def upgrade():
    # إنشاء جدول audit_logs
    op.create_table(
        'audit_logs',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=True),
        sa.Column('user_name', sa.String(length=100), nullable=False),
        sa.Column('action', sa.String(length=50), nullable=False),
        sa.Column('entity_type', sa.String(length=50), nullable=False),
        sa.Column('entity_id', sa.Integer(), nullable=False),
        sa.Column('entity_number', sa.String(length=50), nullable=True),
        sa.Column('timestamp', sa.DateTime(), nullable=False),
        sa.Column('ip_address', sa.String(length=45), nullable=True),
        sa.Column('user_agent', sa.String(length=255), nullable=True),
        sa.Column('details', sa.Text(), nullable=True),
        sa.Column('success', sa.Boolean(), nullable=False),
        sa.Column('error_message', sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint('id')
    )
    
    # إنشاء الفهارس
    op.create_index('idx_audit_user_name', 'audit_logs', ['user_name'])
    op.create_index('idx_audit_action', 'audit_logs', ['action'])
    op.create_index('idx_audit_entity', 'audit_logs', ['entity_type', 'entity_id'])
    op.create_index('idx_audit_timestamp', 'audit_logs', ['timestamp'])
    op.create_index('idx_audit_entity_number', 'audit_logs', ['entity_number'])


def downgrade():
    # حذف الفهارس
    op.drop_index('idx_audit_entity_number', table_name='audit_logs')
    op.drop_index('idx_audit_timestamp', table_name='audit_logs')
    op.drop_index('idx_audit_entity', table_name='audit_logs')
    op.drop_index('idx_audit_action', table_name='audit_logs')
    op.drop_index('idx_audit_user_name', table_name='audit_logs')
    
    # حذف الجدول
    op.drop_table('audit_logs')
