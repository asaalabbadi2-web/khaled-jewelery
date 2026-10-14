"""repair_protection: the accounts no correction touches are marked on the account (CHART-002 step 4c3)

SCHEMA + DATA. The owner's rule (3 Oct 2026, the scrap safe 12 Oct): the main
cash box, the Riyadh bank and the clearing accounts were corrected to match
reality -- no repair entry names them; what would move one moves its
substitute. services/repair/entries.py held them as account numbers, which
2027's renumbering would silently void. The owner, 14 Oct 2026: a mark on the
account.

- account.repair_protected (boolean, default false) and
  account.repair_substitute_id (account, nullable).
- Marked from the list as it stood, frozen here: 1100000 «صندوق النقدية
  الرئيسي» -> 1100002, 1110000 «ح/جاري بنك الرياض» -> 1110001, 340 «فروقات
  تاريخية للمقاصة», 1720 / 71720 «حساب وسيط تسوية الذهب», 71310000 «صندوق
  الكسر الرئيسي وزني» -> 71310002. An account missing is skipped.

Impact: two columns; six accounts marked, three substitutes set. No entry or
balance changes. Downgrade drops the columns.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261014_repair_protection'
down_revision = '20261014_party_groups'
branch_labels = None
depends_on = None

PROTECTED = ('1100000', '1110000', '340', '1720', '71720', '71310000')
SUBSTITUTES = {'1100000': '1100002', '1110000': '1110001', '71310000': '71310002'}


def upgrade():
    op.add_column('account', sa.Column('repair_protected', sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column('account', sa.Column('repair_substitute_id', sa.Integer(), sa.ForeignKey('account.id'),
                                       nullable=True))
    bind = op.get_bind()
    marked = bind.execute(sa.text('UPDATE account SET repair_protected = true WHERE account_number = ANY(:n)'),
                          {'n': list(PROTECTED)}).rowcount
    linked = 0
    for number, substitute in SUBSTITUTES.items():
        linked += bind.execute(sa.text(
            'UPDATE account SET repair_substitute_id = (SELECT id FROM account WHERE account_number = :s) '
            'WHERE account_number = :n AND EXISTS (SELECT 1 FROM account WHERE account_number = :s)'),
            {'n': number, 's': substitute}).rowcount
    print(f'[repair_protection] protected {marked}; substitutes {linked}')


def downgrade():
    op.drop_column('account', 'repair_substitute_id')
    op.drop_column('account', 'repair_protected')
