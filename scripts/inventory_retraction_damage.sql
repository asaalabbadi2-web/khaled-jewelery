-- inventory_retraction_damage.sql — what invoice retraction has already done.
--
-- The retraction guard (backend/services/invoice_retraction_guard.py) stops
-- NEW damage from reject / unpost / delete / voucher cancel. This measures the
-- damage already in the books, so no correction is designed on a ledger of
-- unknown state. Each section names the mechanism it measures; the incident
-- document explains them.
--
-- Contract: prints FACTS only. Nothing here raises: damage exists, and this
-- file's job is to show how much, not to fail. Every section should shrink to
-- empty as corrections land; a section that grows means a path is still open.
--
-- Run (read-only — the whole file runs in a READ ONLY transaction):
--   psql -v ON_ERROR_STOP=1 -f scripts/inventory_retraction_damage.sql
--
-- Measured first on the post-incident production copy, 2026-09-28.

\set ON_ERROR_STOP on
\timing off
\pset pager off
BEGIN TRANSACTION READ ONLY;

\echo '── 1. Unpost → re-post: receipts the safe-box statement no longer counts ──'
-- Unpost reversed each linked voucher's safe-box rows; re-post re-approved the
-- voucher and re-posted its JE but never wrote the rows back. The receipt is in
-- the GL and missing from the statement. (1641, 1779, 2204, 2478.)
SELECT v.reference_id                                                AS invoice,
       sb.name                                                       AS safe_box,
       count(DISTINCT v.id)                                          AS receipts,
       round(sum(CASE WHEN t.ref_type = 'voucher_reversal'
                      THEN CASE WHEN t.direction = 'in' THEN t.amount_cash ELSE -t.amount_cash END
                      ELSE 0 END)::numeric, 2)                       AS cash_reversed
  FROM voucher v
  JOIN invoice i              ON i.id = v.reference_id AND i.is_posted
  JOIN safe_box_transaction t ON t.ref_id = v.id AND t.ref_type = 'voucher_reversal'
  JOIN safe_box sb            ON sb.id = t.safe_box_id
 WHERE v.reference_type = 'invoice' AND v.status = 'approved'
 GROUP BY 1, 2
 ORDER BY 1, 2;

\echo '── 2. Unpost → re-post: gold the statement shows leaving vs the invoice ──'
-- Re-post writes invoice_gold again beside the creation-time sale movement.
SELECT i.id                                                          AS invoice,
       i.invoice_type,
       round(i.total_weight::numeric, 3)                             AS invoice_weight,
       round(sum(CASE WHEN t.direction = 'out' THEN 1 ELSE -1 END
                 * (t.weight_18k + t.weight_21k + t.weight_22k + t.weight_24k))::numeric, 3)
                                                                     AS statement_gold_out
  FROM invoice i
  JOIN safe_box_transaction t ON t.invoice_id = i.id AND t.ref_type LIKE 'invoice%gold%'
 WHERE i.is_posted
   AND i.id IN (SELECT entity_id FROM audit_logs
                 WHERE entity_type = 'invoice' AND action = 'unpost' AND success)
 GROUP BY 1, 2, 3
HAVING abs(abs(sum(CASE WHEN t.direction = 'out' THEN 1 ELSE -1 END
                   * (t.weight_18k + t.weight_21k + t.weight_22k + t.weight_24k)))
           - coalesce(i.total_weight, 0)) > 0.01
 ORDER BY 1;

\echo '── 3. Posted invoices whose linked payment is not approved ──────────────'
-- Left 'pending' by an unpost the re-post did not re-approve (991, 992).
SELECT i.id AS invoice, i.invoice_type, v.voucher_number, v.status
  FROM voucher v
  JOIN invoice i ON i.id = v.reference_id AND i.is_posted
 WHERE v.reference_type = 'invoice' AND v.status NOT IN ('approved', 'cancelled')
 ORDER BY 1, 3;

\echo '── 4. Posted ledger entries whose document is gone (the 7413 class) ─────'
-- Delete removed the document and left an entry that still counts in the GL.
SELECT j.id, j.entry_number, j.reference_type, j.reference_id, j.created_at::date AS created,
       round(coalesce((SELECT sum(l.cash_debit) FROM journal_entry_line l
                        WHERE l.journal_entry_id = j.id AND NOT l.is_deleted), 0)::numeric, 2)
                                                                     AS cash_debit
  FROM journal_entry j
 WHERE j.is_posted AND NOT j.is_deleted
   AND (   (j.reference_type IN ('invoice', 'invoice_payments')
            AND (j.reference_id IS NULL
                 OR NOT EXISTS (SELECT 1 FROM invoice i WHERE i.id = j.reference_id)))
        OR (j.reference_type IN ('voucher', 'voucher_reversal')
            AND NOT EXISTS (SELECT 1 FROM voucher v WHERE v.id = j.reference_id)))
 ORDER BY j.id;

\echo '── 5. Safe-box rows whose voucher is gone ───────────────────────────────'
SELECT t.id, sb.name AS safe_box, t.ref_type, t.ref_id, t.direction,
       round(t.amount_cash::numeric, 2) AS cash, t.created_at::date AS created
  FROM safe_box_transaction t
  JOIN safe_box sb ON sb.id = t.safe_box_id
 WHERE t.ref_type IN ('voucher', 'voucher_reversal')
   AND NOT EXISTS (SELECT 1 FROM voucher v WHERE v.id = t.ref_id)
 ORDER BY t.id;

\echo '── 6. Reversals that mirrored ANOTHER payment (id collision, 638) ──────'
-- A payment-keyed row whose number equals the cancelled voucher's, reversed
-- although that payment never named the voucher.
SELECT r.ref_id AS voucher, o.invoice_payment_id AS payment_reversed, ip.invoice_id AS its_invoice,
       sb.name AS safe_box, o.direction AS original_direction,
       round(o.amount_cash::numeric, 2) AS cash, r.created_at::date AS reversed_on
  FROM safe_box_transaction r
  JOIN safe_box_transaction o ON o.ref_id = r.ref_id AND o.ref_type = 'invoice_payment'
                             AND o.invoice_payment_id = o.ref_id
                             AND o.safe_box_id = r.safe_box_id
                             AND abs(o.amount_cash - r.amount_cash) < 0.005
                             AND o.direction <> r.direction
  JOIN invoice_payment ip ON ip.id = o.invoice_payment_id
  JOIN safe_box sb        ON sb.id = o.safe_box_id
 WHERE r.ref_type = 'voucher_reversal'
   AND coalesce(ip.source_voucher_id, -1) <> r.ref_id
 ORDER BY 1;

\echo '── 7. Exposure: payment-keyed rows sharing a number with another voucher ─'
-- Closed for cancel_voucher by the guard release; kept here to show the size
-- of what any other reader of ref_id alone would still get wrong.
SELECT count(*) AS rows_exposed
  FROM safe_box_transaction t
 WHERE t.ref_type = 'invoice_payment' AND t.ref_id = t.invoice_payment_id
   AND EXISTS (SELECT 1 FROM voucher v WHERE v.id = t.ref_id)
   AND NOT EXISTS (SELECT 1 FROM invoice_payment ip
                    WHERE ip.id = t.invoice_payment_id AND ip.source_voucher_id = t.ref_id);

\echo '── 8. Shared entries whose lines cannot be split by voucher ─────────────'
-- cancel_voucher now refuses one of these; they are corrected by a counter
-- document, never by cancelling a single voucher.
WITH shared AS (
  SELECT v.journal_entry_id AS je, count(*) AS vouchers
    FROM voucher v
   WHERE v.journal_entry_id IS NOT NULL
   GROUP BY 1 HAVING count(*) > 1)
SELECT count(*) AS entries, sum(s.vouchers) AS vouchers,
       min(j.created_at)::date AS first, max(j.created_at)::date AS last
  FROM shared s
  JOIN journal_entry j ON j.id = s.je
 WHERE NOT EXISTS (SELECT 1 FROM journal_entry_line l
                    WHERE l.journal_entry_id = s.je AND l.source_voucher_id IS NOT NULL);

\echo '── 9. Reviewer hypotheses, measured ─────────────────────────────────────'
SELECT 'payments whose creating voucher no longer stands' AS check_,
       count(*) AS rows_
  FROM invoice_payment ip
  JOIN voucher v ON v.id = ip.source_voucher_id
 WHERE v.status NOT IN ('approved', 'cancelled')
UNION ALL
SELECT 'attributions whose voucher is not approved', count(*)
  FROM voucher_invoice_gold_attribution a
  LEFT JOIN voucher v ON v.id = a.voucher_id
 WHERE coalesce(v.status, '<gone>') <> 'approved'
UNION ALL
SELECT 'own movements orphaned by a deleted invoice (SET NULL)', count(*)
  FROM safe_box_transaction t
 WHERE t.invoice_id IS NULL
   AND t.ref_type IN ('invoice', 'invoice_sale_gold_movement', 'invoice_gold',
                      'invoice_gold_reversal', 'invoice_scrap_receipt',
                      'invoice_scrap_return', 'invoice_scrap_sale')
   AND NOT EXISTS (SELECT 1 FROM invoice i WHERE i.id = t.ref_id);

\echo '── 10. Every unpost ever, by what became of the invoice ─────────────────'
SELECT CASE WHEN i.id IS NULL THEN 'deleted afterwards'
            WHEN i.is_posted  THEN 're-posted'
            ELSE 'still unposted: ' || coalesce(i.status, '') END AS outcome,
       count(*) AS invoices
  FROM (SELECT DISTINCT entity_id FROM audit_logs
         WHERE entity_type = 'invoice' AND action = 'unpost' AND success) u
  LEFT JOIN invoice i ON i.id = u.entity_id
 GROUP BY 1
 ORDER BY 1;

ROLLBACK;
