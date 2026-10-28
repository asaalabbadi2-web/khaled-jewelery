"""office_price_terms: the gold price is the closing office's, not the world ounce's (OFFICE-PRICE-1)

SCHEMA, additive. The owner, 28 Oct 2026: «نحن نقوم بالتسكير حسب سعر مكاتب
التسكير ... اسعار الاساس للمبيعات والمشتريات يجب ان يكون بنفس تسعيرة المكاتب»,
then «احسب العلاقة التي تولد السعر في مكتب الديوان وتطبقها على سعرنا», and
the terms are the settings' (option A).

Dewan Al Dahab's price, read from its own page (28 Oct 2026):
  24k a kilo = (ounce + main fees + custom fees) x 32.148 x 3.75
  21k a gram = the kilo / 1143 - 0.75;  18k = the kilo / 1333 - 1
and 22k from 21k (the owner). The fees then: 1.35 and 43 dollars an ounce.

settings: the four terms, defaulting to Dewan's today -- the owner edits them.
gold_price: the terms each price was saved with (a day's price is a fact,
frozen; §13). Every row already there keeps them empty: it is priced as it
was, by the ounce.

Impact: eight columns with server defaults or NULL; no row rewritten.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261029_office_price_terms'
down_revision = '20261027_invoice_stones_totals'
branch_labels = None
depends_on = None

TERMS = (
    ('office_main_fees_usd', '1.35'),
    ('office_custom_fees_usd', '43'),
    ('office_discount_21', '0.75'),
    ('office_discount_18', '1'),
)


def upgrade():
    for name, default in TERMS:
        op.add_column('settings', sa.Column(name, sa.Float(), nullable=False, server_default=default))
        op.add_column('gold_price', sa.Column(name, sa.Float(), nullable=True))


def downgrade():
    for name, _ in TERMS:
        op.drop_column('gold_price', name)
        op.drop_column('settings', name)
