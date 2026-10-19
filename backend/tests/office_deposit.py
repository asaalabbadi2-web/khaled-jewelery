"""An office's deposit, as production has it after ADR-052: a weight-only asset
and its safe at the place «deposit», the office supplier's gold safe -- where
a settled reservation's gold is kept."""
import uuid

from models import Account, SafeBox, db


def give_deposit(supplier):
    tag = uuid.uuid4().hex[:6]
    account = Account(account_number=f'7133{uuid.uuid4().int % 10**5:05d}', name=f'ذهب مودع لدى {tag}',
                      type='Asset', transaction_type='gold', tracks_weight=True)
    db.session.add(account)
    db.session.flush()
    safe = SafeBox(name=account.name, safe_type='gold', account_id=account.id, is_active=True,
                   stock_location='deposit')
    db.session.add(safe)
    db.session.flush()
    supplier.default_safe_box_id = safe.id
    db.session.flush()
    return safe


def map_deposit_parent():
    """«ذهب مودع لدى المكاتب» mapped, as the setup tool leaves production (71330):
    a short number -- the generator numbers its children under it."""
    from models import AccountingMapping
    from services.office_deposits import DEPOSIT_PARENT
    AccountingMapping.query.filter_by(account_type=DEPOSIT_PARENT).delete()
    number = next(n for n in (f'79{i:03d}' for i in range(1000))
                  if not Account.query.filter_by(account_number=n).first())
    group = Account(account_number=number, name='ذهب مودع لدى المكاتب وزني', type='Asset',
                    transaction_type='gold', tracks_weight=True)
    db.session.add(group)
    db.session.flush()
    db.session.add(AccountingMapping(operation_type='افتراضي', account_type=DEPOSIT_PARENT, account_id=group.id,
                                     is_active=True))
    db.session.flush()
    return group
