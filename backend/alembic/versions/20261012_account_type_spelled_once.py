"""account_type_spelled_once: an account's type is one of five, however a writer spelled it (CHART-UI-1)

DATA, on evidence.

The employee custody and advance helpers wrote type 'asset' (lowercase): nine
accounts on the 10 Oct production copy -- the employees' cash and gold custody
accounts and their parent 1100001 -- matched no type filter and showed no
Arabic type. The model now spells the five types one way on every write
(Account._validate_type); this sets the rows written before it.

Idempotent: only a row whose type is one of the five in another case.

IMPACT: account.type on those rows only ('asset' -> 'Asset', ...). No entry,
balance or report total changes. Downgrade: nothing to undo (the spelling is
not restored).

Revision ID: 20261012_account_type_spelled_once
Revises: 20261011_vat_return
Create Date: 2026-10-12
"""
from alembic import op
import sqlalchemy as sa

revision = '20261012_account_type_spelled_once'
down_revision = '20261011_vat_return'
branch_labels = None
depends_on = None

TYPES = ('Asset', 'Liability', 'Equity', 'Revenue', 'Expense')


def upgrade():
    bind = op.get_bind()
    for t in TYPES:
        changed = bind.execute(sa.text('UPDATE account SET type = :t WHERE lower(type) = lower(:t) AND type <> :t'),
                               {'t': t}).rowcount
        if changed:
            print(f'[account_type_spelled_once] {changed} account(s) -> {t}')


def downgrade():
    pass
