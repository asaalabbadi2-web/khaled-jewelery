"""Gold safes: the statement follows the ledger, one ledger correction, and two
rows that copy manual entries (stage-4 items 12, 13 and 15; the owner, 12 Oct 2026).

**Item 13 -- the statement follows the ledger.** The owner: the gold safes
match reality, and their balance is the ledger's (services/live_balances.py).
Their statements (SafeBoxTransaction) drifted -- the display safe (30): 78
supplier purchases posted with no row, 17 reservation purchases with a row and
no entry, sales whose row outweighed their entry, a deleted invoice's row, a
«تسوية تاريخية» row of 13 Jun on the statement alone; Al-Junaih (41): its own
13 Jun row. Per document, karat by karat, the difference becomes a statement
row dated at the document's first movement -- a row in for the karats the
statement lacks, a row out for those it has too much of -- as the cash safes'
statements were aligned (statement_alignment.py). The ledger is not touched.
Counting is the nightly check's (services/safebox_subledger.py): shift
settlements and manual entries count on neither side.

**Item 12 -- invoice 992 purchased twice.** BUY-2026-081 bought 59.6 g of
21k scrap once; its entry (JE-2026-01480) put it into the main scrap safe, and
the manual JE-2026-01881 «استلام كسر ذهب مفقود» put it in again against the
purchases (7512). The main scrap safe matches reality (the owner): the second
credit to the purchases is the error, and the gold came from the reserve scrap
safe. One entry, dated as the manual one: debit 7512, credit 71310002 -- the
main scrap safe untouched (entries.py protects it).

**Rows that copy a manual entry.** A manual entry writes no statement row by
design, and the nightly check leaves it out on both sides. Two rows copy one
anyway, under another type, and the check counts them: the main scrap safe's
second row of 992 (JE-2026-01881) and Al-Raqi's 396.6 g (JE-2026-00120
«ذهب محتجز لدى مكتب الراقي», a row typed 'opening_balance'). Their balances
are their whole ledgers' and match reality (the owner: Al-Raqi holds 396.6 g);
the findings are accepted, each with its entry -- nothing is written. A first
plan put Al-Raqi's grams into the ledger again; the rehearsal on the 11 Oct
backup showed its balance doubling to 793.2 g, and it was dropped.

Each step is idempotent and says what it would do; dry_run (the default)
writes nothing.
"""
import json

from sqlalchemy import text

from models import Account, AuditLog, Invoice, JournalEntry, SafeBox, SafeBoxTransaction, db
from services.repair.entries import write_entry

ALIGNMENT = 'stage4_gold_statement_alignment'
DUPLICATE_ENTRY = 'JE-2026-01881'
DUPLICATE_FIX = 'stage4_duplicate_purchase'
DUPLICATE_GRAMS_21K = 59.6
KARATS = ('18k', '21k', '22k', '24k')
GRAM = 0.0005


class NotAsMeasured(ValueError):
    pass


# Per document: the statement's grams and the ledger's, karat by karat. A
# document is an invoice (its rows, its entries, its vouchers' entries), a
# voucher, or any other reference. Counting as the nightly check counts.
_BY_DOCUMENT = text("""
with box as (select id sid, account_id from safe_box where id = :sid),
sb as (
  select coalesce(t.invoice_id::text,
                  case when t.ref_type in ('invoice_gold', 'invoice_gold_reversal') then t.ref_id::text end,
                  case when t.ref_type in ('voucher', 'voucher_reversal') then (select case when v.reference_type = 'invoice'
                       then v.reference_id::text else 'voucher:' || v.id end from voucher v where v.id = t.ref_id) end,
                  coalesce(t.ref_type, '') || ':' || coalesce(t.ref_id::text, '')) k,
         sum(case when t.direction = 'in' then 1 else -1 end * coalesce(t.weight_18k, 0)) w18,
         sum(case when t.direction = 'in' then 1 else -1 end * coalesce(t.weight_21k, 0)) w21,
         sum(case when t.direction = 'in' then 1 else -1 end * coalesce(t.weight_22k, 0)) w22,
         sum(case when t.direction = 'in' then 1 else -1 end * coalesce(t.weight_24k, 0)) w24,
         min(t.created_at) d
  from safe_box_transaction t
  left join journal_entry mj on t.ref_type = 'journal_entry' and mj.id = t.ref_id
  cross join box
  where t.safe_box_id = box.sid
    and lower(trim(coalesce(t.ref_type, ''))) <> 'shift_closing_settlement'
    and not (t.ref_type = 'journal_entry'
             and lower(trim(coalesce(mj.reference_type, ''))) in ('', 'manual', 'journal_entry'))
  group by 1),
gl as (
  select case when je.reference_type in ('invoice', 'invoice_payments') then je.reference_id::text
              when je.reference_type = 'invoice_payment' then (select p.invoice_id::text from invoice_payment p
                   where p.id = je.reference_id)
              when je.reference_type in ('voucher', 'voucher_reversal') then coalesce((select case when
                   v.reference_type = 'invoice' then v.reference_id::text else 'voucher:' || v.id end from voucher v
                   where v.id = je.reference_id), 'voucher:' || je.reference_id)
              else coalesce(je.reference_type, '') || ':' || coalesce(je.reference_id::text, '') end k,
         sum(coalesce(l.debit_18k, 0) - coalesce(l.credit_18k, 0)) w18,
         sum(coalesce(l.debit_21k, 0) - coalesce(l.credit_21k, 0)) w21,
         sum(coalesce(l.debit_22k, 0) - coalesce(l.credit_22k, 0)) w22,
         sum(coalesce(l.debit_24k, 0) - coalesce(l.credit_24k, 0)) w24,
         min(je.date) d
  from journal_entry_line l join journal_entry je on je.id = l.journal_entry_id cross join box
  where l.account_id = box.account_id and coalesce(je.is_posted, true) and not coalesce(je.is_deleted, false)
    and not coalesce(je.is_draft, false) and not coalesce(l.is_deleted, false)
    and lower(trim(coalesce(je.reference_type, ''))) not in ('', 'manual', 'journal_entry')
  group by 1)
select coalesce(sb.k, gl.k, '') k,
       coalesce(gl.w18, 0) - coalesce(sb.w18, 0) a18, coalesce(gl.w21, 0) - coalesce(sb.w21, 0) a21,
       coalesce(gl.w22, 0) - coalesce(sb.w22, 0) a22, coalesce(gl.w24, 0) - coalesce(sb.w24, 0) a24,
       least(coalesce(sb.d, gl.d), coalesce(gl.d, sb.d)) d
from sb full join gl on gl.k = sb.k
""")


def gold_statement_differences(safe_box_id: int) -> list:
    """[{'key', 'add': {karat: grams the statement lacks (+) or has too much of (-)}, 'date'}]."""
    out = []
    for r in db.session.execute(_BY_DOCUMENT, {'sid': int(safe_box_id)}).all():
        add = {k: round(float(getattr(r, f'a{k[:-1]}')), 6) for k in KARATS}
        if any(abs(v) >= GRAM for v in add.values()):
            out.append({'key': r.k, 'add': add, 'date': r.d})
    return sorted(out, key=lambda d: (d['date'], d['key']))


def _ref_id(key: str):
    tail = key.rsplit(':', 1)[-1]
    return int(tail) if tail.isdigit() else None


def align_gold_statement(safe_box_id: int, *, by: str, dry_run: bool = True) -> dict:
    box = db.session.get(SafeBox, int(safe_box_id))
    if box is None or not box.account_id:
        raise NotAsMeasured(f'safe {safe_box_id} has no account')
    if SafeBoxTransaction.query.filter_by(safe_box_id=box.id, ref_type=ALIGNMENT).first() is not None:
        return {'safe_box': box.id, 'name': box.name, 'done': True}
    diffs = gold_statement_differences(box.id)
    net = {k: round(sum(d['add'][k] for d in diffs), 3) for k in KARATS}
    plan = {'safe_box': box.id, 'name': box.name, 'documents': len(diffs), 'net_grams': net, 'written': False,
            'largest': [{'key': d['key'], **{k: round(v, 3) for k, v in d['add'].items() if abs(v) >= GRAM}}
                        for d in sorted(diffs, key=lambda d: -sum(abs(v) for v in d['add'].values()))[:10]]}
    if dry_run or not diffs:
        return plan
    for d in diffs:
        invoice_id = int(d['key']) if d['key'].isdigit() and db.session.get(Invoice, int(d['key'])) else None
        for direction, sign in (('in', 1), ('out', -1)):
            weights = {f'weight_{k}': round(v * sign, 6) for k, v in d['add'].items() if v * sign >= GRAM}
            if not weights:
                continue
            db.session.add(SafeBoxTransaction(
                safe_box_id=box.id, ref_type=ALIGNMENT, ref_id=invoice_id or _ref_id(d['key']),
                invoice_id=invoice_id, direction=direction, created_at=d['date'], created_by=by,
                notes=f'مواءمة كشف الذهب مع الأستاذ — {d["key"] or "بلا مرجع"}'[:500], **weights))
    db.session.flush()
    plan['written'] = True
    AuditLog.log_action(user_name=by, action=ALIGNMENT, entity_type='SafeBox', entity_id=box.id,
                        entity_number=box.name, details=json.dumps(plan, ensure_ascii=False, default=str))
    return plan


def _account(number) -> Account:
    a = Account.query.filter_by(account_number=number).first()
    if a is None:
        raise NotAsMeasured(f'account {number} not found')
    return a


def duplicate_purchase_992(*, by: str, now, dry_run: bool = True) -> dict:
    main, reserve, purchases = _account('71310000'), _account('71310002'), _account('7512')
    manual = JournalEntry.query.filter_by(entry_number=DUPLICATE_ENTRY).first()
    if manual is None or manual.is_deleted or not manual.is_posted:
        raise NotAsMeasured(f'{DUPLICATE_ENTRY} is not a posted entry')
    if JournalEntry.query.filter_by(reference_type=DUPLICATE_FIX, reference_id=manual.id, is_deleted=False).first():
        return {'entry': DUPLICATE_ENTRY, 'done': True}
    live = [l for l in manual.lines if not l.is_deleted]
    by_account = {l.account_id: l for l in live}
    as_measured = (
        len(live) == 2 and set(by_account) == {main.id, purchases.id}
        and abs(float(by_account[main.id].debit_21k or 0) - DUPLICATE_GRAMS_21K) < GRAM
        and abs(float(by_account[purchases.id].credit_21k or 0) - DUPLICATE_GRAMS_21K) < GRAM
        and not any(float(getattr(l, c) or 0) for l in live
                    for c in ('cash_debit', 'cash_credit', 'debit_18k', 'credit_18k', 'debit_22k', 'credit_22k',
                              'debit_24k', 'credit_24k')))
    if not as_measured:
        raise NotAsMeasured(f'{DUPLICATE_ENTRY} is not 59.6 g 21k into 71310000 against 7512')
    plan = {'entry': DUPLICATE_ENTRY, 'date': manual.date, 'grams_21k': DUPLICATE_GRAMS_21K,
            'debit': '7512', 'credit': '71310002', 'written': False}
    if dry_run:
        return plan
    description = f'تصحيح: شراء الفاتورة 992 مكرر في {DUPLICATE_ENTRY} — الذهب من الكسر الاحتياطي لا من شراء ثانٍ'
    weight_type = by_account[main.id].weight_type
    entry = write_entry(
        date=manual.date, description=description, reference_type=DUPLICATE_FIX, reference_id=manual.id,
        reference_number=DUPLICATE_ENTRY,
        lines=[{'account_id': purchases.id, 'description': 'إلغاء الشراء المكرر', 'weight_type': weight_type,
                'debit_21k': DUPLICATE_GRAMS_21K},
               {'account_id': reserve.id, 'description': 'الذهب من الكسر الاحتياطي', 'weight_type': weight_type,
                'credit_21k': DUPLICATE_GRAMS_21K}],
        by=by, now=now, prefix='COR', safe_rows=True)
    plan['written'] = entry.entry_number
    db.session.add(AuditLog(user_name=by, action=DUPLICATE_FIX, entity_type='journal_entry', entity_id=entry.id,
                            success=True, details=json.dumps(plan, ensure_ascii=False, default=str)))
    db.session.flush()
    return plan


# {safe's account number: (the manual entry its row copies, karat, grams)} -- measured on the 11 Oct backup.
MANUAL_COPIES = {
    '71310000': (DUPLICATE_ENTRY, '21k', DUPLICATE_GRAMS_21K),   # صندوق الكسر الرئيسي: الفاتورة 992 مرتين
    '72100017': ('JE-2026-00120', '21k', 396.6),                 # مكتب الراقي: ذهب محتجز لديه
}


def accept_manual_copies(*, by: str, now, dry_run: bool = True, copies=None) -> list:
    """Accept each safe's finding that is a row copying a manual entry -- only as measured."""
    from services.books_invariants import SAFEBOX_GOLD_DRIFT, check_safebox_gold_drift, accept_finding
    facts = {f.subject_key: f for f in check_safebox_gold_drift()}
    out = []
    for number, (entry_number, karat, grams) in (copies or MANUAL_COPIES).items():
        safe = SafeBox.query.filter_by(account_id=_account(number).id).first()
        manual = JournalEntry.query.filter_by(entry_number=entry_number, is_deleted=False).first()
        if safe is None or manual is None:
            raise NotAsMeasured(f'{number}: no safe, or no {entry_number}')
        key = f'safe_box:{safe.id}:{karat}'
        fact = facts.get(key)
        if fact is None:
            out.append({'safe_box': safe.id, 'subject': key, 'nothing_to_accept': True})
            continue
        if abs(float(fact.metric) - grams) > GRAM:
            raise NotAsMeasured(f'{key}: {fact.metric} g, measured {grams} g')
        step = {'safe_box': safe.id, 'name': safe.name, 'subject': key, 'grams': grams, 'entry': entry_number}
        out.append(step)
        if not dry_run:
            accept_finding(SAFEBOX_GOLD_DRIFT, key, by=by, now=now, reason=(
                f'صفّ في الكشف ينسخ القيد اليدوي {entry_number} ({grams} جم عيار {karat[:-1]})، والفحص يستبعد '
                'القيود اليدوية من الجهتين. الرصيد هو الأستاذ كاملًا ويطابق الواقع (المالك، 12 أكتوبر 2026).'))
    return out
