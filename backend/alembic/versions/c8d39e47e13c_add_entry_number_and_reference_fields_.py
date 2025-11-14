"""add_entry_number_and_reference_fields_to_journal_entry

Revision ID: c8d39e47e13c
Revises: 7ff60cdf8f40
Create Date: 2025-10-11 08:36:42.534092

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c8d39e47e13c'
down_revision: Union[str, Sequence[str], None] = '7ff60cdf8f40'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # إضافة الحقول الجديدة لجدول journal_entry
    op.add_column('journal_entry', sa.Column('entry_number', sa.String(50), nullable=True, unique=True))
    op.add_column('journal_entry', sa.Column('reference_type', sa.String(50), nullable=True))
    op.add_column('journal_entry', sa.Column('reference_id', sa.Integer(), nullable=True))
    op.add_column('journal_entry', sa.Column('created_by', sa.String(100), nullable=True))
    
    # توليد أرقام القيود للقيود الموجودة
    connection = op.get_bind()
    entries = connection.execute(sa.text("SELECT id, date FROM journal_entry ORDER BY date, id")).fetchall()
    
    for idx, entry in enumerate(entries, start=1):
        entry_id = entry[0]
        entry_date = entry[1]
        # استخراج السنة من التاريخ
        year = entry_date[:4] if isinstance(entry_date, str) else str(entry_date.year)
        entry_number = f'JE-{year}-{idx:05d}'
        connection.execute(
            sa.text("UPDATE journal_entry SET entry_number = :num WHERE id = :id"),
            {"num": entry_number, "id": entry_id}
        )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column('journal_entry', 'created_by')
    op.drop_column('journal_entry', 'reference_id')
    op.drop_column('journal_entry', 'reference_type')
    op.drop_column('journal_entry', 'entry_number')
