"""bonus_rule_tiers: a bonus rule is data -- its measure, period and tiers (24 Oct 2026)

SCHEMA, ADDITIVE, and DATA on the points rules.

bonus_rule.measure  -- points | sales | sold_weight | count (the one measure, ADR-058)
bonus_rule.period   -- daily | weekly | monthly
bonus_rule.tiers    -- [{"from": n, "per_unit": v} | {"from": n, "amount": v}], ascending;
                       all the measure is paid at the tier it reached (the owner,
                       24 Oct 2026: «كل النقاط بسعر شريحتها»).

DATA: the owner, 24 Oct 2026 -- the live rule «الهدف الشهري» «تُنقل كما هي».
A rule of points paid per point (rule_type points_based, bonus_type
points_per_unit) that inherits the race's points (points_source NULL) becomes
a tiered rule: measure points, its period (its points_period: today ->
daily, week -> weekly, else monthly), one tier from its min_points (0 when
none) at its bonus_value per point. Its cap, scope and validity stay. On the
23 Oct copy: rule 1, from 1,000 at 2.5, monthly, six employees -- rehearsed to
pay July to September as it paid. Any other rule is left as it is.

IMPACT: three nullable columns; the converted rows' rule_type and bonus_type.
No bonus, entry or line changes: a bonus keeps its rule_snapshot. Downgrade
turns a converted rule back (one tier, per unit, the race's points) and drops
the columns; a rule made tiered after this cannot go back and is refused.
"""
import json

from alembic import op
import sqlalchemy as sa

revision = '20261024_bonus_rule_tiers'
down_revision = '20261023_invoice_scrap_buy_price_at_sale'
branch_labels = None
depends_on = None

PERIODS = {'today': 'daily', 'week': 'weekly', 'month': 'monthly'}
BACK = {v: k for k, v in PERIODS.items()}


def _json(value):
    if value is None or isinstance(value, (dict, list)):
        return value
    return json.loads(value)


def upgrade():
    op.add_column('bonus_rule', sa.Column('measure', sa.String(20), nullable=True))
    op.add_column('bonus_rule', sa.Column('period', sa.String(10), nullable=True))
    op.add_column('bonus_rule', sa.Column('tiers', sa.JSON(), nullable=True))
    bind = op.get_bind()
    rows = bind.execute(sa.text(
        "SELECT id, name, bonus_value, conditions FROM bonus_rule "
        "WHERE rule_type = 'points_based' AND bonus_type = 'points_per_unit' AND points_source IS NULL")).fetchall()
    for row in rows:
        conditions = _json(row.conditions) or {}
        tiers = [{'from': float(conditions.get('min_points') or 0), 'per_unit': float(row.bonus_value or 0)}]
        period = PERIODS.get(conditions.get('points_period'), 'monthly')
        bind.execute(sa.text(
            "UPDATE bonus_rule SET rule_type = 'tiered', bonus_type = 'tiers', measure = 'points', "
            "period = :period, tiers = CAST(:tiers AS JSON) WHERE id = :id"),
            {'period': period, 'tiers': json.dumps(tiers), 'id': row.id})
        print(f'[bonus_rule_tiers] rule {row.id} «{row.name}»: {period}, tiers {tiers}')


def downgrade():
    bind = op.get_bind()
    rows = bind.execute(sa.text(
        "SELECT id, name, measure, period, tiers FROM bonus_rule WHERE rule_type = 'tiered'")).fetchall()
    for row in rows:
        tiers = _json(row.tiers) or []
        if row.measure != 'points' or len(tiers) != 1 or 'per_unit' not in tiers[0]:
            raise RuntimeError(f'bonus_rule_tiers: rule {row.id} «{row.name}» is not one per-point tier of points '
                               '-- it cannot be a points rule again')
        conditions = {'min_points': tiers[0]['from'], 'points_period': BACK.get(row.period, 'month')}
        bind.execute(sa.text(
            "UPDATE bonus_rule SET rule_type = 'points_based', bonus_type = 'points_per_unit', "
            "bonus_value = :value, conditions = CAST(:conditions AS JSON) WHERE id = :id"),
            {'value': tiers[0]['per_unit'], 'conditions': json.dumps(conditions), 'id': row.id})
    op.drop_column('bonus_rule', 'tiers')
    op.drop_column('bonus_rule', 'period')
    op.drop_column('bonus_rule', 'measure')
