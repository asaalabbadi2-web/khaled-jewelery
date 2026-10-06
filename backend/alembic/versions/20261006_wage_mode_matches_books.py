"""wage_mode_matches_books: the wage treatment says what the books did (ADR-039, the owner 6 Oct 2026)

DATA ONLY: one value of one row, under a condition. No schema change.

Until ADR-039 the supplier-purchase posting capitalized wages on the wage
inventory whatever manufacturing_wage_mode said. From ADR-039 the posting
follows the setting. A database whose setting says `expense` while its posted
purchases capitalized wages would, the day this release lands, start expensing
them -- for a company whose rule is to capitalize (the owner's).

So: when the setting is not `inventory` AND posted supplier-purchase entries
debited a wage inventory account (1320 / 1340 / 1350), the setting is
corrected to `inventory` -- the record is made to describe the books; the
treatment is not chosen here. A database with no such entries (a new company)
keeps its setting: there it is a choice, made on the settings screen.

Measured on the 6 Oct production copy: setting `expense`; 156 posted purchase
entries put 541,514.97 on 1320 -> corrected to `inventory`.

IMPACT: from this release, purchases and sales post as they did before it.
Invoices keep their recorded snapshot (158 say `expense` over capitalized
entries -- a data repair for the recovery roadmap, the owner's decision).
Downgrade leaves the value: it describes the books either way.

Revision ID: 20261006_wage_mode_matches_books
Revises: 20261006_settlement_schedule
Create Date: 2026-10-06
"""
from alembic import op
import sqlalchemy as sa

revision = '20261006_wage_mode_matches_books'
down_revision = '20261006_settlement_schedule'
branch_labels = None
depends_on = None

WAGE_INVENTORY_NUMBERS = ('1320', '1340', '1350')


def capitalized_purchase_lines(bind) -> int:
    """Posted supplier-purchase lines that debited a wage inventory account."""
    return int(bind.execute(sa.text(
        """
        SELECT count(*)
          FROM journal_entry_line l
          JOIN journal_entry je ON je.id = l.journal_entry_id
          JOIN account a ON a.id = l.account_id
          JOIN invoice i ON je.reference_type = 'invoice' AND je.reference_id = i.id
         WHERE i.invoice_type = 'شراء'
           AND je.is_posted IS TRUE
           AND COALESCE(je.is_deleted, FALSE) IS FALSE
           AND COALESCE(l.is_deleted, FALSE) IS FALSE
           AND COALESCE(l.cash_debit, 0) > 0
           AND a.account_number IN :numbers
        """
    ).bindparams(sa.bindparam('numbers', expanding=True)),
        {'numbers': list(WAGE_INVENTORY_NUMBERS)}).scalar() or 0)


def correct_wage_mode(bind):
    """Returns (before, after, evidence). Changes the row only on evidence."""
    row = bind.execute(sa.text(
        'SELECT id, manufacturing_wage_mode FROM settings ORDER BY id LIMIT 1'
    )).first()
    if row is None:
        return None, None, 0
    before = (row.manufacturing_wage_mode or '').strip().lower() or None
    if before == 'inventory':
        return before, before, 0
    evidence = capitalized_purchase_lines(bind)
    if evidence == 0:
        return before, before, 0
    bind.execute(sa.text(
        "UPDATE settings SET manufacturing_wage_mode = 'inventory' WHERE id = :id"
    ), {'id': row.id})
    return before, 'inventory', evidence


def upgrade():
    before, after, evidence = correct_wage_mode(op.get_bind())
    print(f'[wage_mode_matches_books] {before} -> {after} '
          f'({evidence} posted purchase lines capitalized wages)')


def downgrade():
    # The corrected value describes the books under either release.
    pass
