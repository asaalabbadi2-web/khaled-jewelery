"""item.coded_wage: a piece coded from the stock on hand carries its own wage (ADR-096 §4, ت4; the owner, 19 Nov 2026).

Revision ID: 20261119_piece_coded_wage
Revises: 20261119_coding_from

Impact:
- adds item.coded_wage, nullable, NULL on every row: no item's meaning
  changes -- a receipt's piece reads its invoice, a catalogue item is no piece;
- drops stock_coding.wage_per_gram: a batch takes no wage now. A batch that
  held one hands it to its pieces first, each round(wage per gram x weight, 2),
  so no piece loses its wage. The copy of production of 19 Nov 2026 holds no
  batch and no piece (verified on ref_1119_0050).

Downgrade: stock_coding.wage_per_gram is added back, each batch its pieces'
wages over their grams (zero with no piece), and item.coded_wage is dropped.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261119_piece_coded_wage'
down_revision = '20261119_coding_from'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('item', sa.Column('coded_wage', sa.Float(), nullable=True))
    op.execute("""
        UPDATE item SET coded_wage = ROUND(CAST(sc.wage_per_gram * item.weight AS numeric), 2)
        FROM stock_coding sc
        WHERE item.coding_id = sc.id AND item.coded_wage IS NULL
    """)
    op.drop_column('stock_coding', 'wage_per_gram')


def downgrade():
    op.add_column('stock_coding', sa.Column('wage_per_gram', sa.Float(), nullable=True))
    op.execute("""
        UPDATE stock_coding SET wage_per_gram = COALESCE((
            SELECT SUM(i.coded_wage) / NULLIF(SUM(i.weight), 0) FROM item i WHERE i.coding_id = stock_coding.id), 0)
    """)
    op.alter_column('stock_coding', 'wage_per_gram', nullable=False)
    op.drop_column('item', 'coded_wage')
