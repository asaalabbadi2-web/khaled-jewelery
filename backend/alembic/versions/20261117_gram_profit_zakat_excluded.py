"""zakat out of gram profit, by the owner's choice -- which the owner may undo (ADR-092)

Gram profit now counts every revenue and expense but trading and what the
owner excludes. Zakat is not an expense of the shop's work: the owner (17 Nov
2026) excludes it, «تستثنى ولكن يكون اختياري» -- a mark on the zakat group,
which the accounts screen switches back. No account holds a zakat expense in
2026 yet (ref_1116); the year-end entries would have lowered gram profit.

Impact: one flag on one account, «59 الزكاة» on production; its children and
their weight twins follow it. Nothing when the account is not there.

Revision ID: 20261117_gram_profit_zakat_excluded
Revises: 20261115_drop_recurring_journals
Create Date: 2026-11-17
"""
import sqlalchemy as sa
from alembic import op

revision = '20261117_gram_profit_zakat_excluded'
down_revision = '20261115_drop_recurring_journals'
branch_labels = None
depends_on = None

ZAKAT_GROUP = "account_number = '59' AND name LIKE '%زكاة%'"


def upgrade():
    op.get_bind().execute(sa.text(f"UPDATE account SET exclude_from_gram_profit = TRUE WHERE {ZAKAT_GROUP}"))


def downgrade():
    op.get_bind().execute(sa.text(f"UPDATE account SET exclude_from_gram_profit = FALSE WHERE {ZAKAT_GROUP}"))
