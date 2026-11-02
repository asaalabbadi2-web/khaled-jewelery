"""gold_deduction_as_purchase_return: the gold clearing's role, mapped yesterday, removed (ADR-082 revised, 3 Nov 2026)

DATA. A gold advance taken from the salary in riyals is booked as a purchase
return (513 / 7513, the role «مرتجع شراء / purchase_returns» already mapped),
not through «وسيط تسوية الذهب» 1720 / 71720: on the 2 Nov copy that clearing
holds 2025's opening residue (-21,181 riyals, +48.14 g) and grams left in it
would read as gold the shop holds. The role 20261102_gold_settlement_clearing_role
mapped is no one's now.

Removes exactly the row that migration wrote (created_by 'PAY-GOLD'); a row
mapped by hand is left. Idempotent.

Impact: at most one row out of accounting_mapping. No account, entry or
balance changes. Downgrade maps it again as that migration did.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261103_gold_deduction_as_purchase_return'
down_revision = '20261102_gold_settlement_clearing_role'
branch_labels = None
depends_on = None

ROLE = 'gold_settlement_clearing'
MARK = 'PAY-GOLD'


def upgrade():
    op.get_bind().execute(sa.text('DELETE FROM accounting_mapping WHERE account_type = :r AND created_by = :m'),
                          {'r': ROLE, 'm': MARK})


def downgrade():
    bind = op.get_bind()
    if bind.execute(sa.text("SELECT 1 FROM accounting_mapping WHERE operation_type = 'افتراضي' "
                            'AND account_type = :r AND is_active'), {'r': ROLE}).first() is not None:
        return
    account_id = bind.execute(sa.text("SELECT id FROM account WHERE account_number = '1720'")).scalar()
    if account_id:
        bind.execute(sa.text(
            'INSERT INTO accounting_mapping (operation_type, account_type, account_id, is_active, created_by, created_at) '
            "VALUES ('افتراضي', :r, :a, true, :m, :t)"), {'r': ROLE, 'a': account_id, 'm': MARK, 't': datetime.utcnow()})
