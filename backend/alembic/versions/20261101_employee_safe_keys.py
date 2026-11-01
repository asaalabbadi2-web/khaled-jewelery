"""employee_safe_keys: the employee's safe and scheme links held by foreign keys (EMP-1, ش0)

SCHEMA, additive. On the 1 Nov copy the cash custody of صالح (safe 40) and
يوسف (safe 54) named safes that are no more: the model declared the keys, the
database never had them (the boot's schema guard adds a bare column). The keys
are added NOT VALID -- every new write is held, the rows already there are not
checked, for tools/repair/employee_access_cleanup.py clears the two dead links
after the deploy (VALIDATE CONSTRAINT may follow).

Impact: three foreign keys on employee, where absent. Downgrade drops them.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261101_employee_safe_keys'
down_revision = '20261101_bonus_payroll_line'
branch_labels = None
depends_on = None

KEYS = (('employee_gold_safe_box_id_fkey', 'gold_safe_box_id', 'safe_box'),
        ('employee_cash_safe_box_id_fkey', 'cash_safe_box_id', 'safe_box'),
        ('employee_contribution_scheme_id_fkey', 'contribution_scheme_id', 'contribution_scheme'))


def upgrade():
    held = {tuple(fk['constrained_columns']) for fk in sa.inspect(op.get_bind()).get_foreign_keys('employee')}
    for name, column, table in KEYS:
        if (column,) not in held:
            op.execute(f'ALTER TABLE employee ADD CONSTRAINT {name} FOREIGN KEY ({column}) '
                       f'REFERENCES {table} (id) NOT VALID')


def downgrade():
    for name, _, _ in KEYS:
        op.execute(f'ALTER TABLE employee DROP CONSTRAINT IF EXISTS {name}')
