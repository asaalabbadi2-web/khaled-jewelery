"""bangle_item_category: «بنجرة» (I-000016) takes its category «بنجرة ذهب 21» (ADR-045 B)

DATA, written once. The owner, 14 Oct 2026 («أي توصية توصي بها نفّذها»).

I-000016 «بنجرة» (21k, 0.1 g) has no category and is used in an invoice, so it
cannot be deleted, and an item has no stop flag. Its category exists:
«بنجرة ذهب 21» (karat 21, active). The item takes it -- only from where it was
found (no category), so a re-run moves nothing. Invoice lines keep their own
category; the stock allocations already written are not touched.

Impact: one item row's category_id; no entry, balance or allocation.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261014_bangle_item_category'
down_revision = '20261014_categories_in_order'
branch_labels = None
depends_on = None

ITEM = 'I-000016'
TARGET = 'بنجرة ذهب 21'


def upgrade():
    bind = op.get_bind()
    row = bind.execute(sa.text('SELECT id, karat, category_id FROM item WHERE item_code = :c'),
                       {'c': ITEM}).fetchone()
    target = bind.execute(sa.text('SELECT id, karat FROM category WHERE name = :n'), {'n': TARGET}).fetchone()
    moved = False
    if (row is not None and target is not None and row.category_id is None
            and int(float(row.karat or 0)) == int(float(target.karat or 0))):
        bind.execute(sa.text('UPDATE item SET category_id = :t WHERE id = :i'), {'t': target.id, 'i': row.id})
        moved = True
    print(f'[bangle_item_category] {ITEM} -> {TARGET}: {"moved" if moved else "nothing to do"}')


def downgrade():
    bind = op.get_bind()
    bind.execute(sa.text(
        'UPDATE item SET category_id = NULL WHERE item_code = :c '
        'AND category_id = (SELECT id FROM category WHERE name = :n)'), {'c': ITEM, 'n': TARGET})
