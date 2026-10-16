"""link_settlements_group: «تسويات وفروقات» (34) and its weight twin (734) are linked (the owner, 16 Oct 2026)

DATA ONLY. On the 15 Oct 2026 copy both groups exist, unlinked; under them
360 «تسوية الأرصدة الافتتاحية» and 7360 are linked -- the children paired,
their parents not, against the rule the code keeps (a weight account's parent
is the twin of its financial account's parent). So an account added under 34
got no weight twin: asked for one, it was refused («الحساب الأب بلا حساب وزني
مربوط»). The owner: link them.

Refused, changing nothing, when either is missing, is of the wrong kind (34
financial, 734 weight), or is linked to another account, or another account
points at either. Idempotent: already linked to each other, nothing to do.

Impact: account.memo_account_id on these two rows. No entry, line or balance
changes. Downgrade unlinks them only if they are linked to each other.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261016_link_settlements_group'
down_revision = '20261015_commission_at_settlement'
branch_labels = None
depends_on = None

FINANCIAL, WEIGHT = '34', '734'


def _pair(bind):
    rows = {r.account_number: r for r in bind.execute(sa.text(
        'SELECT id, account_number, tracks_weight, memo_account_id FROM account '
        'WHERE account_number IN (:f, :w)'), {'f': FINANCIAL, 'w': WEIGHT})}
    return rows.get(FINANCIAL), rows.get(WEIGHT)


def upgrade():
    bind = op.get_bind()
    fin, wt = _pair(bind)
    if fin is None or wt is None:
        print(f'[link_settlements_group] {FINANCIAL} or {WEIGHT} not in this chart -- nothing to link')
        return
    if fin.memo_account_id == wt.id and wt.memo_account_id == fin.id:
        print('[link_settlements_group] already linked')
        return
    if fin.tracks_weight or not wt.tracks_weight:
        raise RuntimeError(f'link_settlements_group: {FINANCIAL} must be financial and {WEIGHT} weight')
    if fin.memo_account_id or wt.memo_account_id:
        raise RuntimeError(f'link_settlements_group: {FINANCIAL} or {WEIGHT} is linked to another account')
    pointing = bind.execute(sa.text('SELECT account_number FROM account WHERE memo_account_id IN (:a, :b)'),
                            {'a': fin.id, 'b': wt.id}).fetchall()
    if pointing:
        raise RuntimeError(f'link_settlements_group: {[r.account_number for r in pointing]} point at them')
    bind.execute(sa.text('UPDATE account SET memo_account_id = :w WHERE id = :f'), {'w': wt.id, 'f': fin.id})
    bind.execute(sa.text('UPDATE account SET memo_account_id = :f WHERE id = :w'), {'w': wt.id, 'f': fin.id})
    print(f'[link_settlements_group] linked {FINANCIAL} <-> {WEIGHT}')


def downgrade():
    bind = op.get_bind()
    fin, wt = _pair(bind)
    if fin is not None and wt is not None and fin.memo_account_id == wt.id and wt.memo_account_id == fin.id:
        bind.execute(sa.text('UPDATE account SET memo_account_id = NULL WHERE id IN (:f, :w)'),
                     {'f': fin.id, 'w': wt.id})
