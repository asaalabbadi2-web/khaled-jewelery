"""CHART-001: the chart put in order (the owner, 12 Oct 2026: «صحح الجميع»).

Measured on the 12 Oct backup (pre-37528747, after that day's repairs). No
entry is written and no balance moves: accounts change place, name, type or
state. Each step is idempotent and says what it would do; dry_run (the
default) writes nothing.

- move: 2310 (employees' bonuses payable) and 2320 (end-of-service provision)
  sat under 230 «ضريبة القيمة المضافة المستحقة»; they move with their
  children, numbered as they are, to 24 «أرصدة دائنة أخرى» (the code finds the
  bonus accounts by the prefix 2310). 2310 is named for what it holds.
- zakat: 235 «الزكاة المستحقة» under 23 (59 «الزكاة» / 590 exist).
- twins: the weight twins of the families that never hold gold -- input VAT
  (14), collections (15), tax liabilities and bonuses (23), employee payables
  (24) -- stop, through the deactivation service (it refuses one with a
  balance); one that ever carried a line is kept and named. Leaves first.
- types: 72 «الخصوم وزني» a liability, 74 «الإيرادات وزني» a revenue; 510 never
  carried gold and the code creates it cash -- not a weight account.
"""
import json

from models import Account, AuditLog, JournalEntryLine, db

STEPS = ('move', 'zakat', 'twins', 'types')
MOVED = ('2310', '2320')
BONUSES_NAME = 'مكافآت مستحقة للموظفين'
ZAKAT = ('235', 'الزكاة المستحقة')
NO_GOLD_FAMILIES = ('14', '15', '23', '24')


def _num(number):
    return Account.query.filter_by(account_number=number).first()


def _move(dry_run):
    target = _num('24')
    if target is None:
        raise ValueError('account 24 not found')
    moved = [n for n in MOVED if _num(n) is not None and _num(n).parent_id != target.id]
    renamed = _num('2310') is not None and _num('2310').name != BONUSES_NAME
    plan = {'moved': moved, 'to': '24', 'renamed_2310': renamed}
    if not dry_run:
        for n in moved:
            _num(n).parent_id = target.id
        if renamed:
            _num('2310').name = BONUSES_NAME
    return plan


def _zakat(dry_run):
    number, name = ZAKAT
    if _num(number) is not None:
        return {'created': False, 'exists': True}
    parent = _num('23')
    if parent is None:
        raise ValueError('account 23 not found')
    if not dry_run:
        db.session.add(Account(account_number=number, name=name, type='Liability', transaction_type='cash',
                               tracks_weight=False, parent_id=parent.id))
    return {'created': number, 'under': '23'}


def _used(account_id) -> bool:
    return db.session.query(JournalEntryLine.id).filter(JournalEntryLine.account_id == account_id).first() is not None


def _twins(by, now, dry_run):
    from services.account_status import NotDeactivatable, deactivate_account
    financial = [a for a in Account.query.filter(Account.memo_account_id.isnot(None)).all()
                 if str(a.account_number).startswith(NO_GOLD_FAMILIES)]
    targets, kept_used = {}, []
    for f in financial:
        twin = db.session.get(Account, f.memo_account_id)
        if twin is None or not str(twin.account_number).startswith('7') or twin.is_active is False:
            continue
        if _used(twin.id):
            kept_used.append(twin.account_number)
            continue
        targets[twin.id] = twin
    # And whatever unused account sits below one -- an orphan weight account with
    # no financial twin (72300000, a salary's, under the sales-VAT twin) would
    # otherwise hold its parents active.
    frontier = list(targets.values())
    while frontier:
        parent = frontier.pop()
        for child in Account.query.filter(Account.parent_id == parent.id, Account.is_active.isnot(False)).all():
            if child.id in targets:
                continue
            if _used(child.id):
                kept_used.append(child.account_number)
                continue
            targets[child.id] = child
            frontier.append(child)
    # Leaves first: deepest twins before their parents.
    def depth(a):
        d, p = 0, a.parent_id
        while p:
            d, p = d + 1, getattr(db.session.get(Account, p), 'parent_id', None)
        return d
    ordered = sorted(targets.values(), key=lambda a: -depth(a))
    plan = {'stopping': [a.account_number for a in ordered], 'kept_used': kept_used, 'refused': {}}
    if dry_run:
        return plan
    for a in ordered:
        try:
            deactivate_account(a.id, by=by, now=now)
        except NotDeactivatable as refused:
            plan['refused'][a.account_number] = str(refused)
    return plan


def _types(dry_run):
    changes = {}
    for number, wanted in (('72', 'Liability'), ('74', 'Revenue')):
        a = _num(number)
        if a is not None and a.type != wanted:
            changes[number] = f'{a.type} -> {wanted}'
            if not dry_run:
                a.type = wanted
    wages = _num('510')
    if wages is not None and wages.tracks_weight:
        if _used_gold(wages.id):
            raise ValueError('510 carried gold: not as measured')
        changes['510'] = 'tracks_weight -> False'
        if not dry_run:
            wages.tracks_weight = False
    return changes


def _used_gold(account_id) -> bool:
    cols = [getattr(JournalEntryLine, f'{side}_{k}') for side in ('debit', 'credit')
            for k in ('18k', '21k', '22k', '24k', 'weight')]
    return db.session.query(JournalEntryLine.id).filter(
        JournalEntryLine.account_id == account_id,
        db.or_(*[db.func.coalesce(c, 0) != 0 for c in cols])).first() is not None


def apply(*, by: str, now, dry_run: bool = True, steps=None) -> dict:
    steps = steps or STEPS
    out = {}
    if 'move' in steps:
        out['move'] = _move(dry_run)
    if 'zakat' in steps:
        out['zakat'] = _zakat(dry_run)
    if 'twins' in steps:
        out['twins'] = _twins(by, now, dry_run)
    if 'types' in steps:
        out['types'] = _types(dry_run)
    db.session.flush()
    if not dry_run:
        db.session.add(AuditLog(user_name=by, action='chart_001', entity_type='account', entity_id=0, success=True,
                                details=json.dumps(out, ensure_ascii=False, default=str)))
        db.session.flush()
    return out
