"""add permissions system tables

Revision ID: 20251111_permissions
Revises: 20251111_audit_log
Create Date: 2025-11-11

"""
from alembic import op
import sqlalchemy as sa
from datetime import datetime


# revision identifiers, used by Alembic.
revision = '20251111_permissions'
down_revision = '20251111_audit_log'
branch_labels = None
depends_on = None


def upgrade():
    # إنشاء جدول المستخدمين
    op.create_table('users',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('username', sa.String(length=50), nullable=False),
        sa.Column('email', sa.String(length=120), nullable=True),
        sa.Column('password_hash', sa.String(length=255), nullable=False),
        sa.Column('full_name', sa.String(length=100), nullable=False),
        sa.Column('is_active', sa.Boolean(), nullable=False, default=True),
        sa.Column('is_admin', sa.Boolean(), nullable=False, default=False),
        sa.Column('phone', sa.String(length=20), nullable=True),
        sa.Column('department', sa.String(length=100), nullable=True),
        sa.Column('position', sa.String(length=100), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False, default=datetime.utcnow),
        sa.Column('updated_at', sa.DateTime(), nullable=True, onupdate=datetime.utcnow),
        sa.Column('last_login', sa.DateTime(), nullable=True),
        sa.Column('password_changed_at', sa.DateTime(), nullable=True),
        sa.Column('created_by', sa.String(length=100), nullable=True),
        sa.PrimaryKeyConstraint('id')
    )
    
    # إنشاء فهارس جدول المستخدمين
    op.create_index('idx_user_username', 'users', ['username'], unique=True)
    op.create_index('idx_user_email', 'users', ['email'], unique=False)
    op.create_index('idx_user_active', 'users', ['is_active'], unique=False)
    
    # إنشاء جدول الأدوار
    op.create_table('roles',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('name', sa.String(length=50), nullable=False),
        sa.Column('name_ar', sa.String(length=100), nullable=False),
        sa.Column('description', sa.Text(), nullable=True),
        sa.Column('is_active', sa.Boolean(), nullable=False, default=True),
        sa.Column('is_system', sa.Boolean(), nullable=False, default=False),
        sa.Column('created_at', sa.DateTime(), nullable=False, default=datetime.utcnow),
        sa.Column('updated_at', sa.DateTime(), nullable=True, onupdate=datetime.utcnow),
        sa.Column('created_by', sa.String(length=100), nullable=True),
        sa.PrimaryKeyConstraint('id')
    )
    
    # إنشاء فهارس جدول الأدوار
    op.create_index('idx_role_name', 'roles', ['name'], unique=True)
    op.create_index('idx_role_active', 'roles', ['is_active'], unique=False)
    
    # إنشاء جدول الصلاحيات
    op.create_table('permissions',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('code', sa.String(length=100), nullable=False),
        sa.Column('name', sa.String(length=100), nullable=False),
        sa.Column('name_ar', sa.String(length=100), nullable=False),
        sa.Column('description', sa.Text(), nullable=True),
        sa.Column('category', sa.String(length=50), nullable=False),
        sa.Column('is_active', sa.Boolean(), nullable=False, default=True),
        sa.Column('created_at', sa.DateTime(), nullable=False, default=datetime.utcnow),
        sa.PrimaryKeyConstraint('id')
    )
    
    # إنشاء فهارس جدول الصلاحيات
    op.create_index('idx_permission_code', 'permissions', ['code'], unique=True)
    op.create_index('idx_permission_category', 'permissions', ['category'], unique=False)
    op.create_index('idx_permission_active', 'permissions', ['is_active'], unique=False)
    
    # إنشاء جدول ربط المستخدمين بالأدوار
    op.create_table('user_roles',
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('role_id', sa.Integer(), nullable=False),
        sa.Column('assigned_at', sa.DateTime(), nullable=True, default=datetime.utcnow),
        sa.Column('assigned_by', sa.String(length=100), nullable=True),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['role_id'], ['roles.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('user_id', 'role_id')
    )
    
    # إنشاء جدول ربط الأدوار بالصلاحيات
    op.create_table('role_permissions',
        sa.Column('role_id', sa.Integer(), nullable=False),
        sa.Column('permission_id', sa.Integer(), nullable=False),
        sa.Column('granted_at', sa.DateTime(), nullable=True, default=datetime.utcnow),
        sa.Column('granted_by', sa.String(length=100), nullable=True),
        sa.ForeignKeyConstraint(['role_id'], ['roles.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['permission_id'], ['permissions.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('role_id', 'permission_id')
    )


def downgrade():
    # حذف الجداول بالترتيب العكسي
    op.drop_table('role_permissions')
    op.drop_table('user_roles')
    
    op.drop_index('idx_permission_active', table_name='permissions')
    op.drop_index('idx_permission_category', table_name='permissions')
    op.drop_index('idx_permission_code', table_name='permissions')
    op.drop_table('permissions')
    
    op.drop_index('idx_role_active', table_name='roles')
    op.drop_index('idx_role_name', table_name='roles')
    op.drop_table('roles')
    
    op.drop_index('idx_user_active', table_name='users')
    op.drop_index('idx_user_email', table_name='users')
    op.drop_index('idx_user_username', table_name='users')
    op.drop_table('users')
