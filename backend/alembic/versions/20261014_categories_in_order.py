"""categories_in_order: Latin digits, the karat in the name, stop not delete, scrap per karat (ADR-045 B)

SCHEMA + DATA, written once. The owner, 14 Oct 2026.

- category.is_active (a stopped category is offered to no one; nothing used
  is deleted) and category.is_scrap (its karat's scrap category).
- Karats and names in Latin digits; a name not ending in its karat gets it
  («حلق اسباني» -> «حلق اسباني 18»).
- Stopped: «حلق اسباني ١٨» (the duplicate of «حلق اسباني», less recently
  used -- renamed «حلق اسباني (موقوف) 18», the two would otherwise share a
  name), «أصناف شراء عيار ٢١», «أصناف شراء عيار 18».
- Created when absent: «كسر 18», «كسر 21», «كسر 22», «كسر 24» -- scrap
  categories; a customer scrap purchase line without a category is given its
  karat's (services.categories.assign_scrap_categories).

Idempotent: a rerun finds nothing to do. Measured on the 12 Oct copy: 38
categories, one karat in Arabic-Indic digits («طقم ذهب أبيض ٢١»).

- Items: «ذهب صافي عيار 24» (I-000002) from the stopped «أصناف شراء عيار
  21» to «سبايك ذهب عيار 24»; «خواتم وتر» (I-000003, no category) to «خاتم
  ذهب 21» -- the owner, 14 Oct 2026.

IMPACT: two columns with defaults; category names and karats; three stopped;
up to four new; two items' category. No invoice, entry or balance changes -- invoice lines keep
their category ids. Downgrade drops the two columns (names stay normalized).

Revision ID: 20261014_categories_in_order
Revises: 20261013_stock_count_on_the_books
Create Date: 2026-10-14
"""
import re
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261014_categories_in_order'
down_revision = '20261013_stock_count_on_the_books'
branch_labels = None
depends_on = None

KARATS = ('18', '21', '22', '24')
_DIGITS = str.maketrans('٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789')
STOPPED = {
    'حلق اسباني 18': 'حلق اسباني (موقوف) 18',     # the duplicate (its twin «حلق اسباني» stays)
    'حلق اسباني (موقوف) 18': None,                # already renamed: kept stopped (a re-run after a downgrade)
    'أصناف شراء عيار 21': None,
    'أصناف شراء عيار 18': None,
}


def _latin(text):
    return ' '.join(str(text or '').translate(_DIGITS).split())


def upgrade():
    bind = op.get_bind()
    columns = {c['name'] for c in sa.inspect(bind).get_columns('category')}
    if 'is_active' not in columns:
        op.add_column('category', sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()))
    if 'is_scrap' not in columns:
        op.add_column('category', sa.Column('is_scrap', sa.Boolean(), nullable=False, server_default=sa.false()))

    # Pass 1: stop -- first, so the duplicate frees its name for its twin.
    rows = bind.execute(sa.text('SELECT id, name, karat, is_active FROM category ORDER BY id')).fetchall()
    names = {_latin(r.name) for r in rows}
    stopped = []
    for r in rows:
        name = _latin(r.name)
        if name not in STOPPED or r.is_active is False:
            continue
        if name == 'حلق اسباني 18' and 'حلق اسباني' not in names:
            continue                       # no twin: nothing duplicates it
        new = STOPPED[name] or name
        bind.execute(sa.text('UPDATE category SET is_active = false, name = :n WHERE id = :i'),
                     {'n': new, 'i': r.id})
        stopped.append(new)

    # Pass 2: Latin digits; the karat at the end of the name.
    rows = bind.execute(sa.text('SELECT id, name, karat FROM category ORDER BY id')).fetchall()
    taken = {_latin(r.name) for r in rows}
    renamed = 0
    for r in rows:
        karat = _latin(r.karat)
        if karat.endswith('.0'):
            karat = karat[:-2]
        name = _latin(r.name)
        if karat in KARATS and not re.search(rf'(?<!\d){karat}\s*$', name):
            candidate = f'{name} {karat}'
            if candidate not in taken:
                taken.discard(name)
                name = candidate
                taken.add(name)
        if name != r.name or (karat or None) != r.karat:
            bind.execute(sa.text('UPDATE category SET name = :n, karat = :k WHERE id = :i'),
                         {'n': name, 'k': karat or None, 'i': r.id})
            renamed += 1

    made = []
    for k in KARATS:
        name = f'كسر {k}'
        found = bind.execute(sa.text('SELECT id FROM category WHERE name = :n'), {'n': name}).scalar()
        if found is None:
            bind.execute(sa.text(
                'INSERT INTO category (name, description, karat, is_active, is_scrap, created_at) '
                "VALUES (:n, 'كسر مشترى من العملاء', :k, true, true, :at)"),
                {'n': name, 'k': k, 'at': datetime(2026, 10, 14)})
            made.append(name)
        else:
            bind.execute(sa.text('UPDATE category SET is_scrap = true WHERE id = :i'), {'i': found})
    # Two items given their category (the owner, 14 Oct 2026): a 24k item sat in
    # the stopped «أصناف شراء عيار 21»; a ring had none. Each only from where it
    # was found -- a re-run moves nothing. Invoice lines keep their own category.
    moved = []
    for code, target, found_in in (('I-000002', 'سبايك ذهب عيار 24', 'أصناف شراء عيار 21'),
                                   ('I-000003', 'خاتم ذهب 21', None)):
        row = bind.execute(sa.text(
            'SELECT i.id, c.name AS cat FROM item i LEFT JOIN category c ON c.id = i.category_id '
            'WHERE i.item_code = :c'), {'c': code}).fetchone()
        target_id = bind.execute(sa.text('SELECT id FROM category WHERE name = :n'), {'n': target}).scalar()
        if row is None or target_id is None or (row.cat or None) != found_in:
            continue
        bind.execute(sa.text('UPDATE item SET category_id = :t WHERE id = :i'), {'t': target_id, 'i': row.id})
        moved.append(code)
    print(f'[categories_in_order] renamed {renamed}, stopped {stopped}, created {made}, items moved {moved}')


def downgrade():
    op.drop_column('category', 'is_scrap')
    op.drop_column('category', 'is_active')
