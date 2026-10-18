"""card_methods_receive_only: a card's way to pay receives, never pays out (17 Oct 2026)

DATA ONLY.

A method whose safe is a clearing safe keeps only «بيع» and «مرتجع بيع» in its
applicable_invoice_types (services/payment_method_policy). Measured on the 16
Oct production copy: مدى، فيزا/ماستر، تابي، تمارا list «شراء»، «مرتجع شراء»
and «مرتجع شراء (مورد)» too, and no card payment was ever made on any of them
-- every card payment is a sale's. A method with no list (every type) gets
the two.

IMPACT: none on invoices or entries. Downgrade restores nothing it cannot
know: the lists before are in this upgrade's print.

Revision ID: 20261018_card_methods_receive_only
Revises: 20261016_link_settlements_group
Create Date: 2026-10-18
"""
import json

from alembic import op
import sqlalchemy as sa

revision = '20261018_card_methods_receive_only'
down_revision = '20261016_link_settlements_group'
branch_labels = None
depends_on = None

KEEP = ('بيع', 'مرتجع بيع')


def _types(raw):
    if raw is None:
        return None
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return None
    return list(raw) if isinstance(raw, (list, tuple)) else None


def restrict_card_methods(bind):
    """Returns {method id: (types before, types after)} for the methods changed."""
    rows = bind.execute(sa.text(
        """
        SELECT p.id, p.applicable_invoice_types
          FROM payment_method p
          JOIN safe_box s ON s.id = p.default_safe_box_id
         WHERE lower(trim(s.safe_type)) = 'clearing'
         ORDER BY p.id
        """
    )).fetchall()
    changed = {}
    for row in rows:
        before = _types(row.applicable_invoice_types)
        after = [t for t in (before if before is not None else KEEP) if t in KEEP] or list(KEEP)
        if before != after:
            bind.execute(sa.text('UPDATE payment_method SET applicable_invoice_types = CAST(:t AS JSON) WHERE id = :id'),
                         {'t': json.dumps(after, ensure_ascii=False), 'id': row.id})
            changed[row.id] = (before, after)
    return changed


def upgrade():
    changed = restrict_card_methods(op.get_bind())
    for method_id, (before, after) in changed.items():
        print(f'[card_methods_receive_only] payment_method {method_id}: {before} -> {after}')


def downgrade():
    pass
