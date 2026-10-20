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


def _party(voucher):
    if voucher.party_type == 'customer' and voucher.customer_id:
        return db.session.get(Customer, voucher.customer_id)
    if voucher.party_type == 'supplier' and voucher.supplier_id:
        return db.session.get(Supplier, voucher.supplier_id)
    return None


def party_accounts(voucher):
    """The accounts a customer or supplier voucher's party line may be on;
    None for any other party, which names its account itself."""
    if voucher.party_type not in _AGGREGATE_ROLE:
        return None
    party = _party(voucher)
    account_id = party and (party.account_id or party.account_category_id)
    if not account_id:
        mapping = AccountingMapping.query.filter_by(
            operation_type='سندات', account_type=_AGGREGATE_ROLE[voucher.party_type], is_active=True,
        ).first()
        account_id = mapping.account_id if mapping else None
    if not account_id:
        return set()
    account = db.session.get(Account, account_id)
    twin = getattr(account, 'memo_account_id', None)
    return {int(account_id)} | ({int(twin)} if twin else set())


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
