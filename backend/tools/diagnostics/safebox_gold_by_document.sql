-- SAFEBOX-001 S0: each gold safe's statement (safe_box_transaction) against its
-- general-ledger account, per karat, broken down by the document that wrote each side.
-- READ ONLY (a temp table). Run on a restored copy:  psql -d <copy> -f this_file
-- side: ledger_only = a statement row with no GL line; gl_only = a GL line with no statement row;
-- both = both sides wrote, amounts differ. d* = statement minus GL, grams.
drop table if exists _g;
create temp table _g as
with sb as (
  select t.safe_box_id sb,
    case when t.ref_type in ('voucher','voucher_reversal') then 'voucher:'||t.ref_id
         when t.invoice_id is not null then 'invoice:'||t.invoice_id
         when t.ref_type like 'invoice%' or t.ref_type='hist_gold_recon_invoice_reversal' then 'invoice:'||t.ref_id
         when t.ref_type in ('journal_entry','je_correction') and rj.id is not null then
              case when rj.reference_type in ('voucher','voucher_reversal') then 'voucher:'||rj.reference_id
                   when rj.reference_type in ('invoice','invoice_payments') then 'invoice:'||rj.reference_id
                   else coalesce(nullif(rj.reference_type,''),'manual')||':'||coalesce(rj.reference_id::text, rj.id::text) end
         else t.ref_type||':'||coalesce(t.ref_id::text,'-') end doc,
    string_agg(distinct t.ref_type, ',') names,
    sum(case when direction='in' then 1 else -1 end*coalesce(weight_18k,0)) w18,
    sum(case when direction='in' then 1 else -1 end*coalesce(weight_21k,0)) w21,
    sum(case when direction='in' then 1 else -1 end*coalesce(weight_22k,0)) w22,
    sum(case when direction='in' then 1 else -1 end*coalesce(weight_24k,0)) w24
  from safe_box_transaction t join safe_box s on s.id=t.safe_box_id and s.safe_type='gold'
  left join journal_entry rj on rj.id=t.ref_id and t.ref_type in ('journal_entry','je_correction') group by 1,2),
gl as (
  select s.id sb,
    case when je.reference_type in ('voucher','voucher_reversal') then 'voucher:'||je.reference_id
         when je.reference_type in ('invoice','invoice_payments') then 'invoice:'||je.reference_id
         when v.id is not null then 'voucher:'||v.id
         else coalesce(nullif(je.reference_type,''),'manual')||':'||coalesce(je.reference_id::text, je.id::text) end doc,
    string_agg(distinct coalesce(nullif(je.reference_type,''),'manual'), ',') jnames,
    sum(coalesce(l.debit_18k,0)-coalesce(l.credit_18k,0)) w18, sum(coalesce(l.debit_21k,0)-coalesce(l.credit_21k,0)) w21,
    sum(coalesce(l.debit_22k,0)-coalesce(l.credit_22k,0)) w22, sum(coalesce(l.debit_24k,0)-coalesce(l.credit_24k,0)) w24
  from safe_box s join journal_entry_line l on l.account_id=s.account_id and not coalesce(l.is_deleted,false)
  join journal_entry je on je.id=l.journal_entry_id and je.is_posted and not coalesce(je.is_deleted,false)
  left join voucher v on v.journal_entry_id=je.id and je.reference_type not in ('voucher','voucher_reversal','invoice','invoice_payments')
  where s.safe_type='gold' group by 1,2)
select coalesce(sb.sb,gl.sb) sb, coalesce(sb.doc,gl.doc) doc, sb.names, gl.jnames,
  coalesce(sb.w18,0)-coalesce(gl.w18,0) d18, coalesce(sb.w21,0)-coalesce(gl.w21,0) d21,
  coalesce(sb.w22,0)-coalesce(gl.w22,0) d22, coalesce(sb.w24,0)-coalesce(gl.w24,0) d24,
  case when gl.doc is null then 'ledger_only' when sb.doc is null then 'gl_only' else 'both' end side
from sb full join gl on gl.sb=sb.sb and gl.doc=sb.doc;
delete from _g where abs(d18)<0.001 and abs(d21)<0.001 and abs(d22)<0.001 and abs(d24)<0.001;
select sb, side, split_part(doc,':',1) doc_kind, coalesce(names,'-') sbt_names, coalesce(jnames,'-') je_names, count(*) docs,
  round(sum(d18)::numeric,2) d18, round(sum(d21)::numeric,2) d21, round(sum(d22)::numeric,2) d22, round(sum(d24)::numeric,2) d24
from _g group by 1,2,3,4,5 order by 1, abs(sum(d18))+abs(sum(d21))+abs(sum(d22))+abs(sum(d24)) desc;
