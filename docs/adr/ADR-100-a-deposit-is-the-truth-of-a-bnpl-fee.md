# ADR-100: عمولة تمارا وتابي تُقدَّر من خطة الطلب، ويصحّحها الإيداع

**Status:** Accepted by the owner on 24 Nov 2026.
- They verified the deposits order by order: «تابي تضيف … ليس من كل عملية بل من كل إيداع» and «1,650 … الخطة 4 دفعات».
- Their decision: «موافق ابدأ الخطه».
- And: «لا تخص ما وجدته لكل وسيله بل اجعلها شامله لمثل هكذا وسائل ويتم ضبطها في الاعدادات». No rule names a company; each is a method's setting, and a test refuses a company's name in the computation.

**Date:** 2026-11-24

---

## Policy or Law?

**Classification:** Both

| | |
|---|---|
| **Law** | <ul><li>A **sale** by a method with plans names its plan from that method's list. The server refuses otherwise, before anything is written (`installments_required` / `installments_unknown`).</li><li>The rate is kept on the payment, as it was.</li><li>A payment's commission is computed one way only: the rate plus the fixed amount, rounded half-up to the halala (Decimal), then its VAT, half-up.</li><li>A settlement's commission is:<ul><li>for a method computed per order: the sum of its payments' commissions, each at its kept rate, and the same for the VAT;</li><li>otherwise: one commission on the total, as before;</li><li>in both cases, plus the fee per deposit, once.</li></ul></li><li>A confirmed deposit posts the difference from what reached the bank between the bank and the commission and its VAT, dated the deposit day. No approved voucher is edited.</li><li>A settlement is confirmed once.</li><li>A confirmed settlement is not cancelled while its confirmation stands.</li><li>A difference beyond the allowed amount is refused without a note.</li></ul> |
| **Policy** | <ul><li>A method's settings, for any method of the kind, entered in the payment method screen:<ul><li>`plans` (installments → rate)</li><li>`commission_fixed_amount`</li><li>`deposit_fixed_fee`</li><li>`commission_per_order`</li><li>`commission_rounding` (`half_up` / `half_even`)</li><li>`commission_refundable_rate` (the part refunded on a return, rounded apart with each part's VAT)</li><li>`deposit_confirmation_required`</li><li>`deposit_difference_allowed` (default 10)</li></ul></li><li>The nightly check's grace days and start date: `DEPOSIT_CONFIRMATION_GRACE_DAYS` (3) and `DEPOSIT_CONFIRMATION_FROM` (2026-10-01).</li></ul>Tamara changed its rates at least once in 2026. |

**Where it lives:**
- **Law:**
  - `backend/accounting/payment_commission.py`: `plan_rate`, `payment_commission`, `settlement_commission`, `commission_vat`.
  - `clearing_settlement_scheduler.settlement_charge`.
  - `services/clearing_deposit.py`.
  - The guard in `routes/vouchers.cancel_voucher`.
- **Data:**
  - The `payment_method_plan` table.
  - The `payment_method` columns.
  - The `clearing_deposit` and `clearing_deposit_settlement` tables.

---

## Context

This was checked on 24 Nov 2026 against Riyad Bank's 2026 statements (1 Jan – 23 Nov) and the backup of 24 Nov.

**Tamara**
- 24 of 25 deposits match to the halala: 77 orders. Each order is charged 5.99% or 6.99% plus 1.50, and its commission and VAT are rounded on their own, half-up.
- The owner confirmed the plans of 16 orders:
  - 6 installments: 5.99%.
  - 3 and 4 installments: 6.99%.
  - One exception: the order of 1,650 on 17 Sep was on 4 installments and was charged 5.99%. The deposit allows no other split.
- **So the plan does not determine the rate with certainty.**
- The deposit of 25 Mar (7,050.42) is about 1,213 of sales more than the Tamara payments recorded before it.

**Tabby**, from its settlement reports of 26 Oct, 2 Nov and 9 Nov (received 24 Nov):
- 6.99% on every plan (3, 5, 7 and 11 months seen), plus 1.50 per order.
- A «Payout fee» of 6.00, plus 0.90 VAT, per deposit. Its note: charged when «transferred total amount is less than certain and you use any payout cycle except month».
- Tabby splits the rate into a **refundable 4.99%** and a **non-refundable 2%**. Each part is rounded half to even, and so is the VAT on each part. With that, the three deposits match exactly.
- Our single rounding (half-up on the whole) comes within three halalas of it.
- Tabby's October tax invoice (3,293.80 + 494.07 VAT) equals October's orders by their date, 3,287.80, plus the payout of 26 Oct, 6.00.
- Still unexplained:
  - The deposit of 5 Oct, 1.00 away without a payout fee. There is no report for it.
  - The bank's 10,983.07 on 26 Oct, against the report's 10,979.07 (4.00 more).

**Tamara's October tax invoice** (2,694.62 + 404.19 VAT = 3,098.81) equals, to the halala, its October orders' commissions by this formula.

**The system before this**
- Tamara was set to a flat 6.078% with no fixed amount. Tabby had no fee per deposit.
- `round()` on a float broke the half-up rounding: 198.715 + 1.50 came out as 200.71. That alone made 8 of Tamara's 25 deposits fail to match.
- The settlement booked its computed net and never compared it with the bank. On the matched deposits it understated Tamara's commission by 290.94 and Tabby's by 348.59.

## Decision

1. **The method's plans (policy).**
   - A payment method may carry plans, each a number of installments and its rate.
   - A method without plans keeps its single rate.
   - The fixed amount per order stays (`commission_fixed_amount`).
   - The fee per deposit (`deposit_fixed_fee`) is new, before VAT.
   - `commission_per_order` says whether the company computes each order on its own (installment companies) or one commission on the settlement total (card networks, as the bank line shows).
   - `commission_rounding` and `commission_refundable_rate`: how the company rounds. One company (Tabby) splits 6.99% into a refundable 4.99% and 2%, each rounded half to even with each part's VAT. Set so, its three reported deposits match to the halala.
   - The migration changes no data: every method computes as before until the owner sets it.

2. **The plan on the payment (law).**
   - A sale by a method with plans carries `installments` from the method's list, otherwise it is refused.
   - The cashier reads the plan on the payment terminal, where the customer's choice shows (the owner). A plan is said as Arabic counts it: «12 دفعة», not «12 دفعات» (`installments_label`, `PaymentFee.installmentsLabel`).
   - The rate is kept on the payment (frozen). Changing a plan's rate later re-prices nothing paid.
   - A **return** refunded through the method names no plan and takes the method's base rate. The fee on a return is not known: Known Gaps BNPL-RETURN-001.
   - Re-reading a payment (correcting its method, or splitting the remainder) keeps its rate.

3. **One computation**, in `accounting/payment_commission.py`.
   - The sale's estimate, the settlement, and the flexible plan's minimum (`due_deposits` now takes the payments, not their total and count) all use it.
   - `routes/clearing.commission_vat` delegates to it.
   - The screens use the same arithmetic in whole halalas (`payment_fee.dart`).

4. **Deposit confirmation (law; the deposit is the truth).**
   - The accountant picks one or more settlement vouchers of the method that came in one bank credit, and enters what arrived and the date from the statement.
   - Expected is the sum of the vouchers' bank lines. The difference (expected − received) is split into commission and VAT (15/115 at 15%), with the VAT going to the account the VAT policy names on that day (`commission_vat_account_on`, the one reading shared with the settlement).
   - It is posted by a single `adjustment` voucher (`reference_type='clearing_deposit'`):
     - A shortfall debits the commission and its VAT and credits the bank.
     - An excess is the reverse.
   - A difference beyond `deposit_difference_allowed` needs a note.
   - No order is required between the settlement date and the deposit date. AV-2026-00491 was dated 14 Oct and the bank received it on 13 Oct.
   - A settlement in a standing confirmation cannot be cancelled. Cancelling the difference voucher deletes the confirmation. A confirmation with no difference is undone with `DELETE /clearing/deposits/<id>`.

5. **The report.** `UNCONFIRMED_DEPOSIT` in the nightly check covers a settlement of a method that requires confirmation, dated from `DEPOSIT_CONFIRMATION_FROM` on, whose deposit day passed more than the grace days ago. The check does not fix anything.

6. **The commission's tax invoice (by order month)**, a later phase -- built as ADR-101 (25 Nov 2026): the VAT waits on the method's pending account until its month's invoice claims it.
   - Tamara issues a monthly tax invoice for the orders made in that month. September's commission was 4,592.06, the same to the halala as its orders' commissions by this formula. Its VAT is 15% of the month's total (688.81).
   - The accountant will enter each month's invoice. The system compares it with the commissions of that month's orders, and the commissions' input VAT in the return is taken from it.
   - The VAT up to the end of Q3 2026 is settled («تعتبر مسوّاه»). Correction starts at Q4 and does not reopen any earlier quarter.

## Proof

**Backend**
- `tests/test_bnpl_fee_matches_the_bank.py` (36):
  - Tamara's 24 deposits, and Tabby's three reported deposits by its settings (rounding and refundable part), are rebuilt to the halala. Tabby's report is matched line by line.
  - No company's name decides a commission (a scan of the computation, the scheduler, the confirmation and the migration).
  - The fee per deposit is taken once.
  - Rounding is half-up, not `round()`.
  - Mada is one commission on its total.
  - The plan law, the kept rate, and a return without a plan.
  - **Shown red:** 7 failures with `round()` on floats, and 4 failures with the plan law disabled.
- `tests/test_bnpl_plans.py` (7):
  - A sale without a plan, or with an unknown plan, is refused and writes nothing.
  - The plan and its rate are kept.
  - A later payment also names its plan.
  - The settlement charges each payment at its kept rate plus the deposit fee once, after the plan's rate has changed.
  - The plans, the deposit confirmation and its allowed difference, the rounding and the refundable part are set from the settings.
- `tests/test_clearing_deposit_confirmed.py` (8):
  - A shortfall is booked as commission and VAT, and the bank shows what came.
  - An excess reduces the commission.
  - A settlement is confirmed once.
  - A large difference needs its note.
  - Another method's settlement is refused.
  - A confirmed settlement cannot be cancelled.
  - Cancelling the difference voucher unconfirms its settlements.
  - The nightly check reports an unconfirmed deposit.
  - **Shown red:** with the once-check and the cancel guard removed.

**Frontend**
- `test/payment_fee_test.dart`: half-up, the plans, and half to even with a refundable part (Tabby's report line by line). Shown red with truncation.
- `test/payment_plans_test.dart`: choosing a plan, closing without one, the plans editor.
- `test/deposit_confirm_test.dart`: the server's preview, and a reason required beyond the allowed amount.

**Rehearsal on a copy of the 24 Nov backup** (`bnpl_rehearsal`)
- The migration goes up, down and up again.
- Tamara's plans and Tabby's deposit fee are set through the API.
- The 7 Q4 deposits were confirmed from the statement. The bank in the books, 137,408.68, equals the statement exactly.
- Confirming twice is refused. Cancelling a confirmed settlement is refused.
- A Tamara sale without a plan is refused with the owner's wording. With 4 installments it is kept at 6.99% (commission 116.84, VAT 17.53).
- The scheduler charged the three open payments 934.30, each at its kept rate.

## Consequences

### Positive
- From the moment of sale, the invoice's profit is reduced by a commission close to the real one.
- The bank in the books matches the bank as the deposit says. A difference no longer accumulates unseen.

### Watch Out For
- **After deploy, the owner enters in the payment method settings** (nothing is set by the migration):
  - Tamara:
    - its plans (2, 3, 4 at 6.99%; 6, 9, 12 at 5.99%);
    - a fixed amount of 1.50 (production has 0);
    - «لكل طلب وحده» and «يُؤكَّد الإيداع» on.
  - Tabby:
    - a fee per deposit of 6.00;
    - «لكل طلب وحده», «تقريب النصف إلى الزوجي» and «يُؤكَّد الإيداع» on;
    - a refundable part of 4.99.
  - Until then every method computes as before.
- The open payments of 22 Nov (4,200 and 9,200) are settled at their kept rate (6.078%), and their deposit confirmation corrects them.
- Past figures are corrected by a separate decision of the owner:
  - the deposits of Q4 (the rehearsal shows each one's difference);
  - the 3,600 phantom in Tamara's clearing account;
  - the 25 Mar deposit.
- A deposit from Q3 confirmed in Q4 (AV-477, settled 6 Oct for September orders) puts its difference in Q4. Whether to do that is also the owner's decision.
