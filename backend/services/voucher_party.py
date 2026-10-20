"""A voucher's party line is on the party's own account (the voucher screen review, 20 Oct 2026).

The screen sends the balancing line; the server decides whether it may stand.
For a customer or supplier voucher every line on the party's side -- credit on
a receipt, debit on a payment -- that is not a safe is on the party's account,
or on that account's weight twin, where a gold line posts. The party's account
is its own; one without falls back on its category, then on the aggregate the
«الربط المحاسبي» maps for vouchers -- the order the screen has always used.
"""
from models import Account, AccountingMapping, Customer, SafeBox, Supplier, db

_AGGREGATE_ROLE = {'customer': 'customers', 'supplier': 'suppliers'}


def party_account_id(party_type, customer_id=None, supplier_id=None):
    """The account a customer's or supplier's line is written on: its own,
    else its category, else the aggregate mapped for vouchers. None for any
    other party, or one with no account to write."""
    if party_type not in _AGGREGATE_ROLE:
        return None
    party = (db.session.get(Customer, customer_id) if party_type == 'customer' and customer_id else
             db.session.get(Supplier, supplier_id) if party_type == 'supplier' and supplier_id else None)
    account_id = party and (party.account_id or party.account_category_id)
    if not account_id:
        mapping = AccountingMapping.query.filter_by(
            operation_type='سندات', account_type=_AGGREGATE_ROLE[party_type], is_active=True,
        ).first()
        account_id = mapping.account_id if mapping else None
    return int(account_id) if account_id else None


def party_accounts(voucher):
    """The accounts a customer or supplier voucher's party line may be on;
    None for any other party, which names its account itself."""
    if voucher.party_type not in _AGGREGATE_ROLE:
        return None
    account_id = party_account_id(voucher.party_type, voucher.customer_id, voucher.supplier_id)
    if not account_id:
        return set()
    account = db.session.get(Account, account_id)
    twin = getattr(account, 'memo_account_id', None)
    return {int(account_id)} | ({int(twin)} if twin else set())


class PartyHasNoAccount(ValueError):
    pass


def _f(value, default):
    try:
        return float(value) if value is not None else default
    except (TypeError, ValueError):
        return default


def write_party_lines(*, voucher_type, party_type, customer_id, supplier_id, lines):
    """*lines* with the party's side written, where it was not sent: one cash
    line for the cash, one gold line a karat with its gross, net and stones --
    the lines the voucher screen used to send. Sent, they are left as they are
    (the old screens; stray_party_lines judges them)."""
    if party_type not in _AGGREGATE_ROLE or voucher_type not in ('receipt', 'payment'):
        return lines
    side = 'credit' if voucher_type == 'receipt' else 'debit'
    if any(str(ln.get('line_type') or '').strip().lower() == side for ln in lines):
        return lines
    account_id = party_account_id(party_type, customer_id, supplier_id)
    if not account_id:
        raise PartyHasNoAccount(party_type)
    cash = 0.0
    gold = {}
    for ln in lines:
        kind = str(ln.get('amount_type') or '').strip().lower()
        amount = _f(ln.get('amount'), 0.0)
        if kind == 'cash':
            cash += amount
        elif kind == 'gold' and ln.get('karat'):
            net = _f(ln.get('net_weight'), amount)
            stones = _f(ln.get('stones_weight'), 0.0)
            g = gold.setdefault(_f(ln['karat'], 0.0), {'amount': 0.0, 'gross': 0.0, 'net': 0.0, 'stones': 0.0})
            g['amount'] += amount
            g['net'] += net
            g['stones'] += stones
            g['gross'] += _f(ln.get('gross_weight'), net + stones)
    written = []
    if cash > 0:
        written.append({'account_id': account_id, 'line_type': side, 'amount_type': 'cash', 'amount': cash,
                        'description': 'نقد'})
    for karat, g in gold.items():
        written.append({'account_id': account_id, 'line_type': side, 'amount_type': 'gold', 'amount': g['amount'],
                        'karat': karat, 'gross_weight': g['gross'], 'net_weight': g['net'],
                        'stones_weight': g['stones'], 'description': f'ذهب عيار {int(karat)}'})
    return [*lines, *written]


def stray_party_lines(voucher, lines):
    """The lines on the party's side that are on neither a safe nor the party's account."""
    allowed = party_accounts(voucher)
    if allowed is None:
        return []
    side = 'credit' if voucher.voucher_type == 'receipt' else 'debit'
    on_side = [ln for ln in lines if str(ln.get('line_type') or '').strip().lower() == side]
    ids = {int(ln['account_id']) for ln in on_side if ln.get('account_id') is not None}
    safes = {sid for (sid,) in db.session.query(SafeBox.account_id).filter(SafeBox.account_id.in_(ids))} if ids else set()
    return [ln for ln in on_side if int(ln['account_id']) not in allowed | safes]
