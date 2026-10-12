"""Stage 4's last decisions (the owner, 12 Oct 2026). Each step is idempotent,
works only as measured on the 12 Oct backup (pre-37528747, after that day's
repairs), and says what it would do; dry_run (the default) writes nothing.

- purchases_paid_by_unnamed_vouchers -- «الشراءان 64 و149 مدفوعان كاملًا»: the
  rest of each was paid by a voucher that named no invoice (their suppliers'
  balances are zero); a payment row links it -- no entry.
- cash_customer_cleared -- «لا توجد أي مديونية لعميل النقدي»: what the screen
  showed as its debt (79,356.82), invoice by invoice, is cleared against the
  temporary cash box at the invoice's date (the main cash box matches reality:
  what would have moved it moves its temporary twin, the owner's rule of 3 Oct)
  -- invoice 61's payment was written twice, by its own entry and by
  PV-2026-00035. The eight April returns, split between the parent 1200
  (tagged #8) and 925, net to zero; their 1200 side moves to 925 -- no cash.
- cash_customer_duplicates -- «موافق»: the 20 other «عميل نقدي» records, all at
  zero, stop with their accounts; #8 stays the one.
- temp_bank_statement -- «مع توصيتك»: the temporary bank's statement follows its
  ledger (AV-2026-00210, 3,700).
- accept_rounding -- item 1 closed; PV-2026-01293's 0.01 g is rounding.
- accept_old_weight_column -- «تركه وتسجيله»: the 16 entries of 12 Feb - 14 Apr
  whose weight-equivalent column is unbalanced are accepted; the nightly
  ENTRY_WEIGHT_UNBALANCED names any new one.
"""
import json

from sqlalchemy import text

from models import (
    Account, AuditLog, Customer, Invoice, InvoicePayment, JournalEntry, PaymentMethod, SafeBox, Voucher,
    VoucherAccountLine, db,
)
from services.repair.entries import write_entry

CENT = 0.005
CASH_CUSTOMER_CLEARED = 'stage4_cash_customer_cleared'
CASH_CUSTOMER_ACCOUNT = '1200000'
TEMP_CASH = '1100002'
TEMP_BANK = '1110001'


class NotAsMeasured(ValueError):
    pass


def _account(number) -> Account:
    a = Account.query.filter_by(account_number=number).first()
    if a is None:
        raise NotAsMeasured(f'account {number} not found')
    return a


def _audit(by, action, entity_type, entity_id, details):
    db.session.add(AuditLog(user_name=by, action=action, entity_type=entity_type, entity_id=entity_id,
                            success=True, details=json.dumps(details, ensure_ascii=False, default=str)))


# ── purchases 64 and 149 ──

# {invoice id: the voucher that paid its rest}
PAID_BY_UNNAMED = {640: 'PV-2026-00149', 2558: 'PV-2026-00846'}


def _method_of(voucher) -> PaymentMethod:
    """The payment method whose safe the voucher paid from (its cash credit line)."""
    credit = (VoucherAccountLine.query.filter_by(voucher_id=voucher.id, line_type='credit', amount_type='cash')
              .order_by(VoucherAccountLine.id).first())
    safe = credit and SafeBox.query.filter_by(account_id=credit.account_id).first()
    method = safe and PaymentMethod.query.filter_by(default_safe_box_id=safe.id).order_by(PaymentMethod.id).first()
    if method is None:
        raise NotAsMeasured(f'{voucher.voucher_number}: no payment method for the safe it paid from')
    return method


def purchases_paid_by_unnamed_vouchers(*, by: str, now, dry_run: bool = True, measured=None) -> list:
    """Each purchase gets the payment rows of the vouchers that paid it: the ones
    naming it (their amount set amount_paid once, with no row -- a recompute
    would say «unpaid») and the one that named nothing -- together its total."""
    from services.invoice_payment_state_service import InvoicePaymentStateService
    out = []
    for invoice_id, number in (measured or PAID_BY_UNNAMED).items():
        invoice = db.session.get(Invoice, int(invoice_id))
        unnamed = Voucher.query.filter_by(voucher_number=number).first()
        if invoice is None or unnamed is None or unnamed.status != 'approved':
            raise NotAsMeasured(f'invoice {invoice_id} / {number}: not as measured')
        if InvoicePayment.query.filter_by(source_voucher_id=unnamed.id).first():
            out.append({'invoice_id': invoice.id, 'voucher': number, 'done': True})
            continue
        if InvoicePayment.query.filter_by(invoice_id=invoice.id).first():
            raise NotAsMeasured(f'invoice {invoice_id} has payment rows: not as measured')
        named = (Voucher.query.filter_by(reference_type='invoice', reference_id=invoice.id, status='approved',
                                         voucher_type='payment').order_by(Voucher.id).all())
        vouchers = named + [unnamed]
        total = round(sum(float(v.amount_cash or 0) for v in vouchers), 2)
        if abs(total - float(invoice.total or 0)) > CENT:
            raise NotAsMeasured(f'invoice {invoice_id}: vouchers {total}, total {invoice.total}')
        step = {'invoice_id': invoice.id, 'voucher': number, 'amount': round(float(unnamed.amount_cash or 0), 2),
                'vouchers': {v.voucher_number: round(float(v.amount_cash or 0), 2) for v in vouchers},
                'written': False}
        out.append(step)
        if dry_run:
            continue
        for v in vouchers:
            amount = round(float(v.amount_cash or 0), 2)
            db.session.add(InvoicePayment(invoice_id=invoice.id, payment_method_id=_method_of(v).id, amount=amount,
                                          net_amount=amount, source_voucher_id=v.id, created_at=v.date))
        db.session.flush()
        state = InvoicePaymentStateService().recompute(invoice)
        step['written'], step['status'] = True, state.status
        _audit(by, 'stage4_purchase_paid_by_unnamed_voucher', 'invoice', invoice.id, step)
    db.session.flush()
    return out


# ── the cash customer ──

_REMAINDERS = text("""
select coalesce(case when je.reference_type in ('invoice', 'invoice_payments') then je.reference_id end,
                case when je.reference_type = 'invoice_payment' then (select p.invoice_id from invoice_payment p
                     where p.id = je.reference_id) end,
                case when je.reference_type in ('voucher', 'voucher_reversal') then (select case when
                     v.reference_type = 'invoice' then v.reference_id end from voucher v where v.id = je.reference_id) end,
                case when je.reference_type = :cleared then je.reference_id end) inv_id,
       sum(l.cash_debit - l.cash_credit) net
from journal_entry_line l join journal_entry je on je.id = l.journal_entry_id
where l.account_id = :acc and coalesce(je.is_posted, true) and not coalesce(je.is_deleted, false)
  and not coalesce(l.is_deleted, false)
group by 1
""")


def cash_customer_remainders(account_id: int) -> dict:
    """{invoice id: what is left on the cash customer for it} -- its entries,
    payments and the vouchers naming it; nonzero only."""
    return {int(r.inv_id): round(float(r.net), 2)
            for r in db.session.execute(_REMAINDERS, {'acc': int(account_id), 'cleared': CASH_CUSTOMER_CLEARED}).all()
            if r.inv_id is not None and abs(float(r.net)) > CENT}


# What the screen showed as the cash customer's debt (79,356.82 -- the reader
# counts its own account 925 and the lines tagged to it on the parent 1200):
# {invoice id: its remainder} -- cleared against the temporary cash box.
CASH_CUSTOMER_REMAINDERS = {
    61: 54956.82,     # شراء من عميل #1 (17 فبراير): دُفع مرتين — قيد الفاتورة وPV-2026-00035
    616: 20000.00,    # بيع #360 (19 مارس)
    2068: 4400.00,    # بيع #938 (26 يونيو)
}
# The April returns posted the customer's side to the parent 1200 (tagged #8)
# and the cash to 925: each nets to zero for the customer, split over two
# accounts. {invoice id: its remainder on 925} -- moved to 925 from 1200, no cash.
PARENT_SPLIT = {
    895: -630.00, 946: 3000.00, 954: -6090.00, 991: -29600.00,
    1032: 2800.00, 1035: 12550.00, 1080: -950.00, 1082: -400.00,
}
PARENT_ACCOUNT = '1200'


def _parent_lines(parent_id: int, customer_id: int, invoice_id: int) -> float:
    from models import JournalEntryLine
    rows = (db.session.query(JournalEntryLine.cash_debit, JournalEntryLine.cash_credit)
            .join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
            .filter(JournalEntryLine.account_id == parent_id, JournalEntryLine.customer_id == customer_id,
                    JournalEntryLine.is_deleted.is_(False), JournalEntry.is_deleted.is_(False),
                    JournalEntry.is_posted.is_(True),
                    JournalEntry.reference_id == invoice_id,
                    JournalEntry.reference_type.in_(['invoice', CASH_CUSTOMER_CLEARED])).all())
    return round(sum(float(d or 0) - float(c or 0) for d, c in rows), 2)


def cash_customer_cleared(*, by: str, now, dry_run: bool = True, measured=None, split=None,
                          customer_id: int = 8) -> dict:
    customer, temp_cash, parent = _account(CASH_CUSTOMER_ACCOUNT), _account(TEMP_CASH), _account(PARENT_ACCOUNT)
    measured = CASH_CUSTOMER_REMAINDERS if measured is None else measured
    split = PARENT_SPLIT if split is None else split
    if JournalEntry.query.filter(JournalEntry.reference_type == CASH_CUSTOMER_CLEARED,
                                 JournalEntry.reference_id.in_(list(measured) + list(split) or [-1]),
                                 JournalEntry.is_deleted.is_(False)).first():
        return {'done': True}
    now_left = cash_customer_remainders(customer.id)
    off = {i: (now_left.get(i, 0.0), m) for i, m in {**measured, **split}.items()
           if abs(now_left.get(i, 0.0) - m) > CENT}
    off.update({i: ('1200', _parent_lines(parent.id, customer_id, i), -m) for i, m in split.items()
                if abs(_parent_lines(parent.id, customer_id, i) + m) > CENT})
    if off:
        raise NotAsMeasured(f'the cash customer is not as measured: {off}')
    plan = {'cleared': len(measured), 'cleared_total': round(sum(measured.values()), 2),
            'moved_from_parent': len(split), 'written': False}
    if dry_run:
        return plan
    written = []
    for invoice_id, amount in {**measured, **split}.items():
        invoice = db.session.get(Invoice, invoice_id)
        label = f'{invoice.invoice_type} #{invoice.invoice_type_id}'
        to_cash = invoice_id in measured
        description = (f'تصفية رصيد العميل النقدي — {label}: لا مديونية (المالك، 12 أكتوبر 2026)' if to_cash else
                       f'نقل طرف العميل النقدي من الحساب الأب 1200 إلى حسابه — {label}')
        customer_side = {'cash_credit': amount} if amount > 0 else {'cash_debit': -amount}
        other_side = {'cash_debit': amount} if amount > 0 else {'cash_credit': -amount}
        other = ({'account_id': temp_cash.id} if to_cash else {'account_id': parent.id, 'customer_id': customer_id})
        entry = write_entry(
            date=invoice.date, description=description, reference_type=CASH_CUSTOMER_CLEARED,
            reference_id=invoice.id, reference_number=label,
            lines=[{'account_id': customer.id, 'customer_id': customer_id, 'description': description, **customer_side},
                   {**other, 'description': description, **other_side}],
            by=by, now=now, prefix='COR', safe_rows=True)
        written.append(entry.entry_number)
    plan['written'] = written
    _audit(by, CASH_CUSTOMER_CLEARED, 'account', customer.id, plan)
    db.session.flush()
    return plan


def cash_customer_duplicates(*, by: str, now, dry_run: bool = True, ids=None) -> dict:
    """The «عميل نقدي» records other than the one (#8), each at zero, stopped with
    their accounts -- whichever of the two is still active (on production the
    records were stopped already, 12 Oct backup; their 20 accounts were not)."""
    from models import CASH_CUSTOMER_NAMES
    from services.account_status import NotDeactivatable, deactivate_account
    from services.party_live_balances import compute_live_customer_balances
    if ids is None:
        records = Customer.query.filter(Customer.name.in_(list(CASH_CUSTOMER_NAMES))).order_by(Customer.id).all()
        if not records or records[0].id != 8 or records[0].active is False:
            raise NotAsMeasured('the cash customer is not #8')
        records = records[1:]
    else:
        records = Customer.query.filter(Customer.id.in_(list(ids))).all()
    balances = compute_live_customer_balances(records)
    for c in records:
        b = balances.get(c.id, {})
        if any(abs(float(v or 0)) > CENT for v in b.values()):
            raise NotAsMeasured(f'customer #{c.id} has a balance: {b}')
    customers = [c for c in records if c.active is not False]
    accounts = [c for c in records if c.account_id and db.session.get(Account, c.account_id).is_active is not False]
    plan = {'customers': [c.id for c in customers], 'accounts': [c.account_id for c in accounts], 'written': False}
    if not customers and not accounts:
        return {'done': True}
    if dry_run:
        return plan
    for c in customers:
        c.active = False
    db.session.flush()
    kept = {}
    for c in accounts:
        try:
            deactivate_account(c.account_id, by=by, now=now)
        except NotDeactivatable as refused:
            # e.g. #16: the draft payment entry of rejected invoice 3123 (JE-2026-05978)
            kept[c.id] = str(refused)
    plan['written'] = True
    plan['accounts_kept'] = kept
    _audit(by, 'stage4_cash_customer_duplicates', 'customer', records[0].id if records else None, plan)
    db.session.flush()
    return plan


def temp_bank_statement(*, by: str, dry_run: bool = True) -> dict:
    from services.repair.statement_alignment import align_statement
    safe = SafeBox.query.filter_by(account_id=_account(TEMP_BANK).id).first()
    if safe is None:
        raise NotAsMeasured('no safe on the temporary bank')
    return align_statement(safe.id, by=by, dry_run=dry_run)


# Accepted, only as measured: {kind: {subject: metric}}
ROUNDING = {'GOLD_ATTRIBUTION_MISSING': {'voucher:4515': 0.01}}
OLD_WEIGHT_COLUMN = {'count': 16, 'grams': -5537.326, 'through': '2026-04-14'}


def accept_rounding(*, by: str, now, dry_run: bool = True) -> list:
    from services.books_invariants import CHECKS, accept_finding
    out = []
    for kind, subjects in ROUNDING.items():
        facts = {f.subject_key: f for f in CHECKS[kind]()}
        for key, metric in subjects.items():
            fact = facts.get(key)
            if fact is None:
                out.append({'subject': key, 'nothing_to_accept': True})
                continue
            if abs(float(fact.metric) - metric) > 0.0005:
                raise NotAsMeasured(f'{key}: {fact.metric}, measured {metric}')
            out.append({'subject': key, 'metric': metric})
            if not dry_run:
                accept_finding(kind, key, by=by, now=now,
                               reason='فرق تقريب (0.01 غ) — البند 1 أُغلق (المالك، 12 أكتوبر 2026)')
    return out


def accept_old_weight_column(*, by: str, now, dry_run: bool = True) -> dict:
    from services.books_invariants import ENTRY_WEIGHT_UNBALANCED, accept_finding, check_entries_weight_unbalanced
    old = [f for f in check_entries_weight_unbalanced() if f.detail['date'] <= OLD_WEIGHT_COLUMN['through']]
    grams = round(sum(float(f.metric) for f in old), 3)
    if len(old) != OLD_WEIGHT_COLUMN['count'] or abs(grams - OLD_WEIGHT_COLUMN['grams']) > 0.005:
        raise NotAsMeasured(f'{len(old)} old entries, {grams} g -- measured 16, -5,537.326')
    plan = {'entries': len(old), 'grams': grams, 'written': False}
    if dry_run:
        return plan
    for f in old:
        accept_finding(ENTRY_WEIGHT_UNBALANCED, f.subject_key, by=by, now=now, reason=(
            'عمود الوزن المكافئ في قيد قديم (12 فبراير – 14 أبريل) — العيارات متوازنة؛ تُرك بقرار المالك '
            '(12 أكتوبر 2026: «تركه وتسجيله»)'))
    plan['written'] = True
    return plan
