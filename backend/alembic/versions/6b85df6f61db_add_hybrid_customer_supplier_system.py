"""add_hybrid_customer_supplier_system

Revision ID: 6b85df6f61db
Revises: ce5f89bda013
Create Date: 2025-10-10 02:22:51.700183

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '6b85df6f61db'
down_revision: Union[str, Sequence[str], None] = 'ce5f89bda013'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema - Add hybrid customer/supplier system."""
    
    # Add new columns to customer table
    with op.batch_alter_table('customer', schema=None) as batch_op:
        batch_op.add_column(sa.Column('customer_code', sa.String(length=10), nullable=True))
        batch_op.add_column(sa.Column('account_category_id', sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column('balance_cash', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.add_column(sa.Column('balance_gold_18k', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.add_column(sa.Column('balance_gold_21k', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.add_column(sa.Column('balance_gold_22k', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.add_column(sa.Column('balance_gold_24k', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.create_index('ix_customer_customer_code', ['customer_code'], unique=True)
        batch_op.create_foreign_key('fk_customer_account_category', 'account', ['account_category_id'], ['id'])
    
    # Add new columns to supplier table
    with op.batch_alter_table('supplier', schema=None) as batch_op:
        batch_op.add_column(sa.Column('supplier_code', sa.String(length=10), nullable=True))
        batch_op.add_column(sa.Column('account_category_id', sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column('balance_cash', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.add_column(sa.Column('balance_gold_18k', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.add_column(sa.Column('balance_gold_21k', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.add_column(sa.Column('balance_gold_22k', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.add_column(sa.Column('balance_gold_24k', sa.Float(), nullable=True, server_default='0.0'))
        batch_op.add_column(sa.Column('notes', sa.Text(), nullable=True))
        batch_op.add_column(sa.Column('active', sa.Boolean(), nullable=True, server_default='1'))
        batch_op.add_column(sa.Column('created_at', sa.DateTime(), nullable=True, server_default=sa.func.now()))
        batch_op.create_index('ix_supplier_supplier_code', ['supplier_code'], unique=True)
        batch_op.create_foreign_key('fk_supplier_account_category', 'account', ['account_category_id'], ['id'])
    
    # Add customer_id and supplier_id to journal_entry_line table
    with op.batch_alter_table('journal_entry_line', schema=None) as batch_op:
        batch_op.add_column(sa.Column('customer_id', sa.Integer(), nullable=True))
        batch_op.add_column(sa.Column('supplier_id', sa.Integer(), nullable=True))
        batch_op.create_foreign_key('fk_journal_entry_line_customer', 'customer', ['customer_id'], ['id'])
        batch_op.create_foreign_key('fk_journal_entry_line_supplier', 'supplier', ['supplier_id'], ['id'])
    
    # Generate customer codes for existing customers
    from code_generator import generate_customer_code, generate_supplier_code
    connection = op.get_bind()
    
    # Get existing customers
    customers = connection.execute(sa.text("SELECT id FROM customer WHERE customer_code IS NULL")).fetchall()
    for idx, (customer_id,) in enumerate(customers, start=1):
        code = f"C-{idx:06d}"
        connection.execute(
            sa.text("UPDATE customer SET customer_code = :code WHERE id = :id"),
            {"code": code, "id": customer_id}
        )
    
    # Get existing suppliers
    suppliers = connection.execute(sa.text("SELECT id FROM supplier WHERE supplier_code IS NULL")).fetchall()
    for idx, (supplier_id,) in enumerate(suppliers, start=1):
        code = f"S-{idx:06d}"
        connection.execute(
            sa.text("UPDATE supplier SET supplier_code = :code WHERE id = :id"),
            {"code": code, "id": supplier_id}
        )
    
    # Now make customer_code and supplier_code NOT NULL
    with op.batch_alter_table('customer', schema=None) as batch_op:
        batch_op.alter_column('customer_code', nullable=False)
    
    with op.batch_alter_table('supplier', schema=None) as batch_op:
        batch_op.alter_column('supplier_code', nullable=False)


def downgrade() -> None:
    """Downgrade schema - Remove hybrid system."""
    
    # Remove columns from journal_entry_line
    with op.batch_alter_table('journal_entry_line', schema=None) as batch_op:
        batch_op.drop_constraint('fk_journal_entry_line_customer', type_='foreignkey')
        batch_op.drop_constraint('fk_journal_entry_line_supplier', type_='foreignkey')
        batch_op.drop_column('supplier_id')
        batch_op.drop_column('customer_id')
    
    # Remove columns from supplier
    with op.batch_alter_table('supplier', schema=None) as batch_op:
        batch_op.drop_constraint('fk_supplier_account_category', type_='foreignkey')
        batch_op.drop_index('ix_supplier_supplier_code')
        batch_op.drop_column('balance_gold_24k')
        batch_op.drop_column('balance_gold_22k')
        batch_op.drop_column('balance_gold_21k')
        batch_op.drop_column('balance_gold_18k')
        batch_op.drop_column('balance_cash')
        batch_op.drop_column('account_category_id')
        batch_op.drop_column('supplier_code')
    
    # Remove columns from customer
    with op.batch_alter_table('customer', schema=None) as batch_op:
        batch_op.drop_constraint('fk_customer_account_category', type_='foreignkey')
        batch_op.drop_index('ix_customer_customer_code')
        batch_op.drop_column('balance_gold_24k')
        batch_op.drop_column('balance_gold_22k')
        batch_op.drop_column('balance_gold_21k')
        batch_op.drop_column('balance_gold_18k')
        batch_op.drop_column('balance_cash')
        batch_op.drop_column('account_category_id')
        batch_op.drop_column('customer_code')
