"""payment_types_on_evidence: a scrap purchase's methods are a setting (PAY-TYPES-1, the owner 8 Oct 2026)

DATA ONLY, set on evidence.

The scrap purchase screen showed only cash and transfer by a rule written in
its code; every method's applicable_invoice_types listed «شراء من عميل». From
this release the screen reads the setting and the server holds an invoice to
it, so the setting is made to say what the business does: a method never used
on a scrap purchase («شراء من عميل») loses that type from its list. A method
used on one keeps it; a method with no list (every type) is left alone.

Measured on the 6 Oct production copy: scrap purchases were paid in cash
(761) and by transfer (22) only -> مدى, فيزا/ماستر, تابي, تمارا lose
«شراء من عميل»; the screen shows what it showed.

IMPACT: none on invoices or entries. Downgrade gives «شراء من عميل» back to
every method with a list that lacks it -- this upgrade's, and any the owner
set off since (the upgrade's print names its own).

Revision ID: 20261008_payment_types_on_evidence
Revises: 20261007_sales_vat_setting
Create Date: 2026-10-08
"""
import json

from alembic import op
import sqlalchemy as sa

revision = '20261008_payment_types_on_evidence'
down_revision = '20261007_sales_vat_setting'
branch_labels = None
depends_on = None

SCRAP_PURCHASE = 'شراء من عميل'


def _types(raw):
    if raw is None:
        return None
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except ValueError:
            return None
    return list(raw) if isinstance(raw, (list, tuple)) else None


def correct_scrap_purchase_methods(bind):
    """Returns the ids of the methods that lost «شراء من عميل»."""
    rows = bind.execute(sa.text(
        'SELECT id, applicable_invoice_types FROM payment_method ORDER BY id'
    )).fetchall()
    used = {r.payment_method_id for r in bind.execute(sa.text(
        """
        SELECT DISTINCT p.payment_method_id
          FROM invoice_payment p
          JOIN invoice i ON i.id = p.invoice_id
         WHERE i.invoice_type = :t
        """
    ), {'t': SCRAP_PURCHASE}).fetchall()}
    changed = []
    for r in rows:
        types = _types(r.applicable_invoice_types)
        if not types or SCRAP_PURCHASE not in types or r.id in used:
            continue
        kept = [t for t in types if t != SCRAP_PURCHASE]
        bind.execute(sa.text(
            'UPDATE payment_method SET applicable_invoice_types = CAST(:v AS json) WHERE id = :id'
        ), {'v': json.dumps(kept, ensure_ascii=False), 'id': r.id})
        changed.append(r.id)
    return changed


def upgrade():
    changed = correct_scrap_purchase_methods(op.get_bind())
    print(f'[payment_types_on_evidence] «{SCRAP_PURCHASE}» taken from methods {changed}')


def downgrade():
    # Every listed method without the type gets it back (see IMPACT).
    bind = op.get_bind()
    rows = bind.execute(sa.text(
        'SELECT id, applicable_invoice_types FROM payment_method ORDER BY id'
    )).fetchall()
    for r in rows:
        types = _types(r.applicable_invoice_types)
        if types is None or SCRAP_PURCHASE in types:
            continue
        bind.execute(sa.text(
            'UPDATE payment_method SET applicable_invoice_types = CAST(:v AS json) WHERE id = :id'
        ), {'v': json.dumps(types + [SCRAP_PURCHASE], ensure_ascii=False), 'id': r.id})
