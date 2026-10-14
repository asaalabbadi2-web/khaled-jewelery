"""core_roles: the gold's cost of sales by its role, in cash and in weight (CHART-002 step 2)

DATA, written once. The postings asked for two accounts by number: 521
«تكلفة مبيعات الذهب» (a return reverses the gold's cost on it) and 7521
«تكلفة مبيعات الذهب وزني» (a purchase's weight falls back on it when its safe
has no weight twin). They become the default roles gold_cost_of_sales and
gold_cost_of_sales_weight, mapped to the same accounts -- nothing posts
differently. A role already mapped, or whose account is missing, is left
alone. Idempotent.

Impact: rows in accounting_mapping only (created_by 'CHART-002'); downgrade
removes exactly these two roles' rows.
"""
from datetime import datetime

from alembic import op
import sqlalchemy as sa

revision = '20261014_core_roles'
down_revision = '20261014_roles_mapped'
branch_labels = None
depends_on = None

DEFAULT_OPERATION = 'افتراضي'
ROLES = (('gold_cost_of_sales', '521'), ('gold_cost_of_sales_weight', '7521'))


def upgrade():
    bind = op.get_bind()
    made = []
    for role, number in ROLES:
        if bind.execute(sa.text('SELECT 1 FROM accounting_mapping WHERE operation_type = :o AND account_type = :r '
                                'AND is_active'), {'o': DEFAULT_OPERATION, 'r': role}).first():
            continue
        account_id = bind.execute(sa.text('SELECT id FROM account WHERE account_number = :n'), {'n': number}).scalar()
        if not account_id:
            continue
        bind.execute(sa.text(
            'INSERT INTO accounting_mapping (operation_type, account_type, account_id, is_active, created_by, '
            'created_at) VALUES (:o, :r, :a, true, :m, :t)'),
            {'o': DEFAULT_OPERATION, 'r': role, 'a': account_id, 'm': 'CHART-002', 't': datetime.utcnow()})
        made.append(f'{role}->{number}')
    print(f'[core_roles] {made}')


def downgrade():
    op.get_bind().execute(sa.text(
        "DELETE FROM accounting_mapping WHERE created_by = 'CHART-002' AND operation_type = :o "
        "AND account_type IN ('gold_cost_of_sales', 'gold_cost_of_sales_weight')"), {'o': DEFAULT_OPERATION})
