"""stock_count_on_the_books: the count writes the books (ADR-045 C1)

SCHEMA + DATA, written once.

A count session read its expected weights from the old inventory ledger and
its approval wrote the difference there alone; the books never knew. Now a
session counts one stock safe (or every one), its lines carry their
location, and its approval writes a posted difference entry against two
roles of the accounting mapping (the owner, 13 Oct 2026):

- inventory_count_shortage -> «خسارة الوزن (الفقد)» (5220, its weight twin 75220);
- inventory_count_surplus  -> «زيادة جرد», a new account under «إيرادات أخرى»
  (42): 450, its weight twin 7450 under 742 -- created here when absent.

Idempotent: columns added if missing; the accounts and the roles only where
absent; a chart without 42/742/5220 is reported and left (the approval then
refuses: the roles are set in the accounting mapping first).

IMPACT: three nullable columns, the count line's uniqueness widened to its
location, at most two accounts and two mapping rows. No entry, balance or
existing row changes (0 count sessions on the 12 Oct copy). Downgrade drops
the columns and restores the uniqueness; the accounts and roles stay (an
account is never deleted -- stop it if unwanted).

Revision ID: 20261013_stock_count_on_the_books
Revises: 20261013_stock_line_allocation
Create Date: 2026-10-13
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261013_stock_count_on_the_books'
down_revision = '20261013_stock_line_allocation'
branch_labels = None
depends_on = None


def _columns(bind, table):
    return {c['name'] for c in sa.inspect(bind).get_columns(table)}


def _account_id(bind, number):
    return bind.execute(sa.text('SELECT id FROM account WHERE account_number = :n'), {'n': number}).scalar()


def _role(bind, role, account_id, now):
    if bind.execute(sa.text("SELECT 1 FROM accounting_mapping WHERE operation_type = 'افتراضي' AND account_type = :r"),
                    {'r': role}).scalar():
        return False
    bind.execute(sa.text(
        "INSERT INTO accounting_mapping (operation_type, account_type, account_id, description, is_active, "
        "created_by, created_at) VALUES ('افتراضي', :r, :a, :d, true, 'migration', :now)"),
        {'r': role, 'a': account_id, 'd': 'ADR-045 C1', 'now': now})
    return True


def upgrade():
    bind = op.get_bind()
    now = datetime(2026, 10, 13)

    session_cols = _columns(bind, 'inventory_count_session')
    if 'safe_box_id' not in session_cols:
        op.add_column('inventory_count_session', sa.Column('safe_box_id', sa.Integer(),
                                                           sa.ForeignKey('safe_box.id'), nullable=True))
        op.create_index('ix_inventory_count_session_safe_box_id', 'inventory_count_session', ['safe_box_id'])
    if 'entry_id' not in session_cols:
        op.add_column('inventory_count_session', sa.Column('entry_id', sa.Integer(),
                                                           sa.ForeignKey('journal_entry.id'), nullable=True))
    if 'safe_box_id' not in _columns(bind, 'inventory_count_line'):
        op.add_column('inventory_count_line', sa.Column('safe_box_id', sa.Integer(),
                                                        sa.ForeignKey('safe_box.id'), nullable=True))
        op.drop_constraint('uq_inventory_count_line_bucket', 'inventory_count_line', type_='unique')
        op.create_unique_constraint('uq_inventory_count_line_bucket', 'inventory_count_line',
                                    ['session_id', 'safe_box_id', 'category_id', 'karat'])

    other, other_w, loss = _account_id(bind, '42'), _account_id(bind, '742'), _account_id(bind, '5220')
    if not (other and other_w and loss):
        print('[stock_count_on_the_books] 42, 742 or 5220 missing: accounts and roles left to the accounting mapping')
        return
    surplus = _account_id(bind, '450')
    if surplus is None:
        insert = sa.text(
            "INSERT INTO account (account_number, name, type, transaction_type, tracks_weight, parent_id, "
            "balance_cash, balance_18k, balance_21k, balance_22k, balance_24k, is_active) "
            "VALUES (:n, :name, 'Revenue', :tt, :w, :p, 0, 0, 0, 0, 0, true) RETURNING id")
        surplus = bind.execute(insert, {'n': '450', 'name': 'زيادة جرد', 'tt': 'cash', 'w': False, 'p': other}).scalar()
        twin = bind.execute(insert, {'n': '7450', 'name': 'زيادة جرد وزني', 'tt': 'gold', 'w': True, 'p': other_w}).scalar()
        bind.execute(sa.text('UPDATE account SET memo_account_id = :t WHERE id = :a'), {'t': twin, 'a': surplus})
        bind.execute(sa.text('UPDATE account SET memo_account_id = :a WHERE id = :t'), {'t': twin, 'a': surplus})
        print('[stock_count_on_the_books] created 450 «زيادة جرد» and 7450')
    made = [r for r, a in (('inventory_count_shortage', loss), ('inventory_count_surplus', surplus))
            if _role(bind, r, a, now)]
    print(f'[stock_count_on_the_books] roles set: {made}')


def downgrade():
    op.drop_constraint('uq_inventory_count_line_bucket', 'inventory_count_line', type_='unique')
    op.drop_column('inventory_count_line', 'safe_box_id')
    op.create_unique_constraint('uq_inventory_count_line_bucket', 'inventory_count_line',
                                ['session_id', 'category_id', 'karat'])
    op.drop_column('inventory_count_session', 'entry_id')
    op.drop_index('ix_inventory_count_session_safe_box_id', 'inventory_count_session')
    op.drop_column('inventory_count_session', 'safe_box_id')
