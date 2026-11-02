"""gold_settlement_clearing_role: the role a gold advance taken in riyals goes through (PAY-GOLD, 2 Nov 2026)

DATA. The owner, 2 Nov 2026: an employee's gold advance taken from his salary
in riyals goes through «وسيط تسوية الذهب» -- the riyals to 1720, the grams to
its weight twin 71720 (services/payroll_payment). The role is mapped to 1720
(«حساب وسيط تسوية الذهب», memo 71720 on the production copy).

A role already mapped, or no 1720, is left alone (the payment then refuses
by name, `gold_clearing_not_mapped`). Idempotent.

Impact: one row in accounting_mapping (created_by 'PAY-GOLD'). No account,
entry or balance changes. Downgrade removes exactly that row.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261102_gold_settlement_clearing_role'
down_revision = '20261102_employee_pay_split'
branch_labels = None
depends_on = None

DEFAULT_OPERATION = 'افتراضي'
ROLE = 'gold_settlement_clearing'
MARK = 'PAY-GOLD'


def upgrade():
    bind = op.get_bind()
    mapped = bind.execute(sa.text('SELECT 1 FROM accounting_mapping WHERE operation_type = :o AND account_type = :r '
                                  'AND is_active'), {'o': DEFAULT_OPERATION, 'r': ROLE}).first()
    if mapped is not None:
        return
    account_id = bind.execute(sa.text("SELECT id FROM account WHERE account_number = '1720'")).scalar()
    if not account_id:
        return
    bind.execute(sa.text(
        'INSERT INTO accounting_mapping (operation_type, account_type, account_id, is_active, created_by, created_at) '
        'VALUES (:o, :r, :a, true, :m, :t)'),
        {'o': DEFAULT_OPERATION, 'r': ROLE, 'a': account_id, 'm': MARK, 't': datetime.utcnow()})


def downgrade():
    op.get_bind().execute(sa.text('DELETE FROM accounting_mapping WHERE account_type = :r AND created_by = :m'),
                          {'r': ROLE, 'm': MARK})
