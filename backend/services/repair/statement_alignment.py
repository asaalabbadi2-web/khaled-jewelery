"""A cash safe's statement brought to its ledger, document by document (stage 4, the owner 3 Oct 2026).

The owner: the main cash box, the Riyadh bank and mada match reality in the
ledger; their statements (SafeBoxTransaction) drifted -- payments keyed to the
wrong invoice, rows written twice or never (SAFEBOX_SUBLEDGER_DRIFT). The
statement follows the ledger; the ledger is not touched.

Per document -- an invoice (its entries, its payments and their vouchers under
one key), a voucher, or any other reference -- the difference between what the
statement and the ledger say becomes one statement row, dated at the
document's first movement, so the statement's running balance is right on
every day and not only at the end. Counting is the nightly check's
(services/safebox_subledger.py): manual entries and shift settlements count on
neither side.

Idempotent per safe: a safe that already has alignment rows is done. dry_run
(the default) writes nothing.
"""
import json

from sqlalchemy import text

from models import AuditLog, SafeBox, SafeBoxTransaction, db

ALIGNMENT = 'stage4_statement_alignment'

_BY_DOCUMENT = text("""
with box as (select id sid, account_id from safe_box where id = :sid),
sb as (
  select coalesce(t.invoice_id::text,
                  case when t.ref_type='invoice_payment' then (select p.invoice_id::text from invoice_payment p
                       where p.id=coalesce(t.invoice_payment_id,t.ref_id)) end,
                  case when t.ref_type in ('voucher','voucher_reversal') then (select case when v.reference_type='invoice'
                       then v.reference_id::text else 'voucher:'||v.id end from voucher v where v.id=t.ref_id) end,
                  t.ref_type||':'||coalesce(t.ref_id::text,'')) k,
         sum(case when t.direction='in' then 1 else -1 end*coalesce(t.amount_cash,0)) amt, min(t.created_at) d
  from safe_box_transaction t, box
  where t.safe_box_id=box.sid and lower(trim(coalesce(t.ref_type,''))) not in ('shift_closing_settlement','journal_entry')
  group by 1),
gl as (
  select case when je.reference_type in ('invoice','invoice_payments') then je.reference_id::text
              when je.reference_type='invoice_payment' then (select p.invoice_id::text from invoice_payment p
                   where p.id=je.reference_id)
              when je.reference_type in ('voucher','voucher_reversal') then coalesce((select case when
                   v.reference_type='invoice' then v.reference_id::text else 'voucher:'||v.id end from voucher v
                   where v.id=je.reference_id), 'voucher:'||je.reference_id)
              else coalesce(je.reference_type,'')||':'||coalesce(je.reference_id::text,'') end k,
         sum(coalesce(l.cash_debit,0)-coalesce(l.cash_credit,0)) amt, min(je.date) d
  from journal_entry_line l join journal_entry je on je.id=l.journal_entry_id, box
  where l.account_id=box.account_id and coalesce(je.is_posted,true) and not coalesce(je.is_deleted,false)
    and not coalesce(je.is_draft,false) and not coalesce(l.is_deleted,false)
    and lower(trim(coalesce(je.reference_type,''))) not in ('','manual','journal_entry')
  group by 1)
select coalesce(sb.k,gl.k) k, coalesce(sb.amt,0) statement, coalesce(gl.amt,0) ledger,
       least(coalesce(sb.d,gl.d), coalesce(gl.d,sb.d)) d
from sb full join gl on gl.k=sb.k
where abs(coalesce(sb.amt,0)-coalesce(gl.amt,0)) > 0.005
order by 4, 1
""")


def _ref_id(key: str):
    tail = key.rsplit(':', 1)[-1]
    return int(tail) if tail.isdigit() else None


def statement_differences(safe_box_id: int) -> list:
    rows = db.session.execute(_BY_DOCUMENT, {'sid': int(safe_box_id)}).all()
    return [{'key': r.k, 'statement': round(float(r.statement), 2), 'ledger': round(float(r.ledger), 2),
             'add': round(float(r.ledger) - float(r.statement), 2), 'date': r.d} for r in rows]


def align_statement(safe_box_id: int, *, by: str, dry_run: bool = True) -> dict:
    box = db.session.get(SafeBox, int(safe_box_id))
    if box is None or not box.account_id:
        raise ValueError(f'safe {safe_box_id} has no account')
    if SafeBoxTransaction.query.filter_by(safe_box_id=box.id, ref_type=ALIGNMENT).first() is not None:
        return {'safe_box': box.id, 'name': box.name, 'done': True}
    diffs = statement_differences(box.id)
    plan = {'safe_box': box.id, 'name': box.name, 'documents': len(diffs),
            'net': round(sum(d['add'] for d in diffs), 2),
            'largest': [{k: d[k] for k in ('key', 'statement', 'ledger', 'add')}
                        for d in sorted(diffs, key=lambda d: -abs(d['add']))[:8]]}
    if dry_run or not diffs:
        plan['written'] = False
        return plan
    for d in diffs:
        db.session.add(SafeBoxTransaction(
            safe_box_id=box.id, ref_type=ALIGNMENT, ref_id=_ref_id(d['key']),
            direction='in' if d['add'] > 0 else 'out', amount_cash=abs(d['add']), created_at=d['date'],
            notes=(f"مواءمة الكشف مع الأستاذ — {d['key']}: الكشف {d['statement']:,.2f} "
                   f"والأستاذ {d['ledger']:,.2f}")[:500],
            created_by=by))
    db.session.flush()
    plan['written'] = True
    AuditLog.log_action(user_name=by, action='stage4_statement_alignment', entity_type='SafeBox',
                        entity_id=box.id, entity_number=box.name,
                        details=json.dumps(plan, ensure_ascii=False, default=str))
    return plan
