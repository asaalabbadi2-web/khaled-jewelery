"""Stage 4, the ledger package: every correction the owner decided, in one run (3 Oct 2026).

Each step names what it corrects by its stable number (entry, voucher,
invoice), checks it is still in the state that was measured on the 2 Oct
copy, and corrects it by an entry (services/repair/entries.py) -- never by
editing or deleting a posted row. The main cash box, the Riyadh bank and the
clearing settlement accounts are not touched: their temporary twins carry what
would have moved them.

Every step is idempotent (a second run finds nothing to do), writes one audit
row, and in a dry run (the default) writes nothing and says what it would do.
A step whose subject is no longer as measured is refused, not guessed at.
"""
import json
from datetime import datetime

from models import AuditLog, Customer, JournalEntry, Voucher, db
from services.repair.entries import (
    mirrored_lines, reverse_entry, reversed_already, substitute_ids, write_entry,
)
from services.repair.rejected_invoice_reversal import reverse_rejected_invoice

# What was measured and decided -- data, not law (the owner, 3 Oct 2026).
REJECTED_INVOICES = (2821, 3123)
DUPLICATE_PAYMENT_ENTRIES = {
    # the orphan entry : the invoice the payment was re-entered with
    'PAY-1450-ALL-20260519182409': 1496,
    'PAY-1982-ALL-20260619201614': 2012,
    'PAY-3027-ALL-20260915212831': 3032,
}
DUPLICATE_SALARY_VOUCHER = 'PV-2026-00098'      # February's transfer, recorded twice
DELETED_PAYOUT_VOUCHER = 'PV-2026-00336'        # April's payout, its entry deleted on 6 May
RECEIPT_WITHOUT_ENTRY = 'RV-2026-00182'         # approved, never posted; invoice 252's remainder
VOUCHERS_TO_APPROVE = ('RV-2026-00494', 'PV-2026-00241', 'PV-2026-00242')  # their entries are posted
# Cash safes whose statement follows their ledger, by their account (the owner: «اصلحها ان كان لا يؤثر على
# حسابات الاستاذ»): the main cash box, the Riyadh bank, mada.
STATEMENTS_TO_ALIGN = ('1100000', '1110000', '1500000')
ACCEPTED_ORPHANS = {
    'JE-2026-00851': 'حقيقي: عملية تمارا دخلت البنك ورصيد تمارا سليم، وسندها 526 محذوف (المالك، 3 أكتوبر 2026)',
}


class NotAsMeasured(ValueError):
    """The subject is no longer in the state the decision was made on."""


def _entry(number) -> JournalEntry:
    e = JournalEntry.query.filter_by(entry_number=number).first()
    if e is None:
        raise NotAsMeasured(f'entry {number} not found')
    return e


def _voucher(number) -> Voucher:
    v = Voucher.query.filter_by(voucher_number=number).first()
    if v is None:
        raise NotAsMeasured(f'voucher {number} not found')
    return v


def _live_posted(entry_id) -> bool:
    e = db.session.get(JournalEntry, entry_id) if entry_id else None
    return bool(e and e.is_posted and not e.is_deleted)


def _voucher_reversed(voucher_id) -> bool:
    return db.session.query(JournalEntry.id).filter(
        JournalEntry.reference_type == 'voucher_reversal', JournalEntry.reference_id == voucher_id,
        JournalEntry.is_posted.is_(True), JournalEntry.is_deleted.is_(False)).first() is not None


def _audit(by, step, entity_type, entity_id, number, plan):
    AuditLog.log_action(user_name=by, action=f'stage4_{step}', entity_type=entity_type, entity_id=entity_id,
                        entity_number=str(number), details=json.dumps(plan, ensure_ascii=False, default=str))


# ── steps ────────────────────────────────────────────────────────────────────

def rejected_invoices(*, by, dry_run=True, invoice_ids=REJECTED_INVOICES):
    reason = 'فاتورة مرفوضة رحّل قيدها حفظ الإعدادات (SETTINGS-001)'
    return [reverse_rejected_invoice(i, by=by, reason=reason, dry_run=dry_run) for i in invoice_ids]


def duplicate_payment_entries(*, by, dry_run=True, entries=None):
    """A payment entry left posted when its invoice was deleted and re-entered:
    the payment counts twice. Reversed at its date; the cash side moves the
    temporary cash box, not the main one."""
    from models import Invoice
    out = []
    for number, reentered in (entries or DUPLICATE_PAYMENT_ENTRIES).items():
        e = _entry(number)
        if reversed_already(e.id):
            out.append({'entry': number, 'done': True})
            continue
        if not e.is_posted or e.is_deleted or db.session.get(Invoice, e.reference_id) is not None:
            raise NotAsMeasured(f'{number} is not a posted entry of a deleted invoice')
        plan = {'entry': number, 'reverse': True, 'reentered_as': reentered,
                'lines': _summary(mirrored_lines(e, substitute=True))}
        if not dry_run:
            rev = reverse_entry(e, by=by, reason=f'دفعة مكررة: أُعيد إدخال الفاتورة برقم {reentered}',
                                substitute=True, safe_rows=True)
            plan['reversal'] = rev.entry_number
            _audit(by, 'reverse_duplicate_payment', 'JournalEntry', e.id, number, plan)
        out.append(plan)
    return out


def duplicate_salary(*, by, dry_run=True, voucher_number=DUPLICATE_SALARY_VOUCHER):
    """February's salary transfer recorded twice (the owner): the second voucher
    is cancelled and its entry reversed at its date through the temporary cash."""
    v = _voucher(voucher_number)
    e = db.session.get(JournalEntry, v.journal_entry_id) if v.journal_entry_id else None
    if v.status == 'cancelled' and _voucher_reversed(v.id):
        return {'voucher': voucher_number, 'done': True}
    if v.status != 'approved' or not _live_posted(v.journal_entry_id):
        raise NotAsMeasured(f'{voucher_number} is not an approved voucher with a posted entry')
    plan = {'voucher': voucher_number, 'cancel': True, 'reverse': e.entry_number,
            'lines': _summary(mirrored_lines(e, substitute=True))}
    if not dry_run:
        reason = 'تحويل راتب فبراير مسجّل مرتين (المالك، 3 أكتوبر 2026)'
        rev = reverse_entry(e, by=by, reason=reason, substitute=True, safe_rows=True, voucher=v)
        v.status, v.cancelled_at, v.cancellation_reason = 'cancelled', datetime.now(), reason
        plan['reversal'] = rev.entry_number
        _audit(by, 'cancel_duplicate_salary', 'Voucher', v.id, voucher_number, plan)
    return plan


def deleted_payout(*, by, dry_run=True, voucher_number=DELETED_PAYOUT_VOUCHER):
    """April's payout was made (the owner) but its entry was deleted: the voucher
    gets its entry again, at its date, the cash side on the temporary cash."""
    v = _voucher(voucher_number)
    if _live_posted(v.journal_entry_id):
        return {'voucher': voucher_number, 'done': True}
    old = db.session.get(JournalEntry, v.journal_entry_id) if v.journal_entry_id else None
    if v.status != 'approved' or old is None or not old.is_deleted:
        raise NotAsMeasured(f'{voucher_number} is not an approved voucher whose entry was deleted')
    lines = mirrored_lines(old, substitute=True, flip=False, include_deleted=True)
    plan = {'voucher': voucher_number, 'repost': old.entry_number, 'lines': _summary(lines)}
    if not dry_run:
        e = write_entry(date=v.date, description=f'{old.description} — أُعيد قيده: حُذف في 6 مايو والصرف تمّ',
                        reference_type='voucher', reference_id=v.id, reference_number=v.voucher_number,
                        lines=lines, by=by)
        v.journal_entry_id = e.id
        plan['entry'] = e.entry_number
        _audit(by, 'repost_deleted_payout', 'Voucher', v.id, voucher_number, plan)
    return plan


def receipt_without_entry(*, by, dry_run=True, voucher_number=RECEIPT_WITHOUT_ENTRY):
    """An approved receipt never posted: its entry, at its date -- the cash on
    the temporary cash box, the customer's account credited."""
    v = _voucher(voucher_number)
    if v.journal_entry_id:
        if _live_posted(v.journal_entry_id):
            return {'voucher': voucher_number, 'done': True}
        raise NotAsMeasured(f'{voucher_number} has an entry that is not posted')
    customer = db.session.get(Customer, v.customer_id) if v.customer_id else None
    if v.status != 'approved' or v.voucher_type != 'receipt' or customer is None or not customer.account_id:
        raise NotAsMeasured(f'{voucher_number} is not an approved customer receipt without an entry')
    amount = round(float(v.amount_cash or 0.0), 2)
    cash = substitute_ids()  # the receipt would have moved the main cash
    main_cash = _account_id('1100000')
    lines = [
        {'account_id': cash.get(main_cash, main_cash), 'cash_debit': amount, 'cash_credit': 0.0, 'description': 'نقد'},
        {'account_id': customer.account_id, 'customer_id': customer.id, 'cash_debit': 0.0, 'cash_credit': amount,
         'description': f'قبض من {customer.name}'},
    ]
    plan = {'voucher': voucher_number, 'post': True, 'lines': _summary(lines)}
    if not dry_run:
        e = write_entry(date=v.date, description=f'RECEIPT - {v.voucher_number}: {v.description or ""}',
                        reference_type='voucher', reference_id=v.id, reference_number=v.voucher_number,
                        lines=lines, by=by)
        v.journal_entry_id = e.id
        plan['entry'] = e.entry_number
        _audit(by, 'post_receipt_without_entry', 'Voucher', v.id, voucher_number, plan)
    return plan


def vouchers_to_approve(*, by, dry_run=True, numbers=VOUCHERS_TO_APPROVE):
    """Pending or cancelled while their entry is posted and counts: the status
    follows the books."""
    out = []
    for number in numbers:
        v = _voucher(number)
        if v.status == 'approved':
            out.append({'voucher': number, 'done': True})
            continue
        if not _live_posted(v.journal_entry_id):
            raise NotAsMeasured(f'{number} has no posted entry')
        plan = {'voucher': number, 'from': v.status, 'to': 'approved'}
        if not dry_run:
            v.status, v.approved_by, v.approved_at = 'approved', by, datetime.now()
            v.cancelled_at = v.cancellation_reason = None
            _audit(by, 'approve_voucher_with_posted_entry', 'Voucher', v.id, number, plan)
        out.append(plan)
    return out


def accepted_orphans(*, by, dry_run=True, orphans=None):
    from services.books_invariants import ORPHAN_POSTED_ENTRY, ReconciliationFinding, SOURCE, accept_finding
    out = []
    for number, reason in (orphans or ACCEPTED_ORPHANS).items():
        key = f'journal_entry:{_entry(number).id}'
        row = ReconciliationFinding.query.filter_by(kind=ORPHAN_POSTED_ENTRY, source=SOURCE, subject_key=key,
                                                    resolved_at=None).first()
        if row is not None and row.accepted_at is not None:
            out.append({'entry': number, 'done': True})
            continue
        plan = {'entry': number, 'accept': reason}
        if not dry_run:
            accept_finding(ORPHAN_POSTED_ENTRY, key, by=by, reason=reason)
        out.append(plan)
    return out


def statements_aligned(*, by, dry_run=True, account_numbers=STATEMENTS_TO_ALIGN):
    """Last: the statement follows the ledger as the steps above left it."""
    from models import SafeBox
    from services.repair.statement_alignment import align_statement
    out = []
    for number in account_numbers:
        boxes = SafeBox.query.filter_by(account_id=_account_id(number)).all()
        if len(boxes) != 1:
            raise NotAsMeasured(f'account {number} has {len(boxes)} safes, not one')
        out.append(align_statement(boxes[0].id, by=by, dry_run=dry_run))
    return out


def unposting_allowed(*, by, dry_run=True):
    """The owner lifts the unposting freeze (3 Oct 2026): UNPOST-001's laws are
    green -- one operation for every path, a round trip restores the books."""
    from models import Settings
    row = Settings.query.first()
    if row is None:
        raise NotAsMeasured('no settings row')
    if row.allow_unposting:
        return {'allow_unposting': True, 'done': True}
    plan = {'allow_unposting': {'from': False, 'to': True}}
    if not dry_run:
        row.allow_unposting = True
        _audit(by, 'allow_unposting', 'Settings', row.id, 'allow_unposting', plan)
    return plan


STEPS = (
    ('rejected_invoices', rejected_invoices),
    ('duplicate_payment_entries', duplicate_payment_entries),
    ('duplicate_salary', duplicate_salary),
    ('deleted_payout', deleted_payout),
    ('receipt_without_entry', receipt_without_entry),
    ('vouchers_to_approve', vouchers_to_approve),
    ('accepted_orphans', accepted_orphans),
    ('statements_aligned', statements_aligned),
    ('unposting_allowed', unposting_allowed),
)


def run_package(*, by, dry_run=True, only=None) -> dict:
    """Every step in order. Caller commits -- once, or not at all."""
    return {name: step(by=by, dry_run=dry_run) for name, step in STEPS if not only or name in only}


# ── helpers ──────────────────────────────────────────────────────────────────

def _account_id(number):
    from models import Account
    a = Account.query.filter_by(account_number=number).first()
    if a is None:
        raise NotAsMeasured(f'account {number} not found')
    return a.id


def _summary(lines):
    from models import Account
    names = {a.id: f'{a.account_number} {a.name}' for a in Account.query.filter(
        Account.id.in_([l['account_id'] for l in lines])).all()}
    return [{'account': names.get(l['account_id']), 'debit': round(float(l.get('cash_debit') or 0), 2),
             'credit': round(float(l.get('cash_credit') or 0), 2)} for l in lines]
