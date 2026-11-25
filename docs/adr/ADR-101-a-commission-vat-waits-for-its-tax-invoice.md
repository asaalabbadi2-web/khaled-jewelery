# ADR-101: ضريبة العمولة تنتظر فاتورتها الضريبية الشهرية

**Status:** Accepted by the owner on 25 Nov 2026.
- Their request: «الفواتير الضريبية», the sixth phase of ADR-100.
- On where the commission's VAT waits until its invoice: «حساب انتظار».
- On whether September's invoices were in the Q3 return: «نعم دخلت».
- On the plan: «ابدأ».

**Date:** 2026-11-25

---

## Policy or Law?

**Classification:** Both

| | |
|---|---|
| **Law** | <ul><li>For a method that issues monthly tax invoices, from its first month, the commission's VAT is never claimed before its invoice. A settlement's VAT and a deposit's VAT difference go to the method's pending account, which is outside the return. The one place this is read is `commission_vat_account_on`, and it overrides any account chosen.</li><li>An invoice that is entered is claimed on its date. Its VAT moves from the pending account to input VAT (or to non-recoverable VAT, by the policy of that day) through its own voucher.</li><li>At each invoice, whatever the pending account holds beyond the VAT still waiting is the rounding, and it goes to the commission. The VAT still waiting is:<ul><li>the VAT the settlements booked for orders of months not yet invoiced;</li><li>plus each deposit difference's share of those orders, by what it settled;</li><li>less the VAT still to come from unsettled orders of invoiced months.</li></ul>The bank is never touched.</li><li>Each method has one invoice per month. Cancelling its voucher undoes it, and the month waits again.</li><li>An invoice is refused when:<ul><li>its method issues none;</li><li>its month is before the first;</li><li>its month is already invoiced;</li><li>it is dated before its month's last day, or after today;</li><li>it has no number;</li><li>the VAT number is not 15 digits starting and ending with 3;</li><li>its VAT differs from the rate's share of its fee by more than `VAT_ROUNDING_ALLOWED` (1.00).</li></ul></li><li>No company's name decides anything. The same scan as ADR-100 enforces this.</li></ul> |
| **Policy** | <ul><li>`payment_method.tax_invoice_from` is the month the company's invoices start. It is set in the payment method screen («تُصدر الشركة فاتورة ضريبية شهرية بعمولاتها»).</li><li>`COMMISSION_TAX_INVOICE_GRACE_DAYS` (15) is the number of days after a month ends before the nightly check asks for its invoice.</li></ul> |

**Where it lives:**
- **Law:**
  - `backend/services/commission_tax_invoice.py`.
  - `routes/clearing.commission_vat_account_on`, which takes the method.
  - `/clearing/tax-invoices*`.
  - The release in `routes/vouchers.cancel_voucher`.
  - `books_invariants.check_missing_commission_tax_invoices`.
- **Data:**
  - The `commission_tax_invoice` table.
  - `payment_method.tax_invoice_from` and `commission_vat_pending_account_id`.
  - Migration `20261125_commission_tax_invoice`, which changes no data.

---

## Context

An installment company issues one tax invoice a month, covering the commissions of the orders made in it:
- Tamara's October invoice, number 92819528, dated 1 Nov, is 2,694.62 plus 404.19 VAT.
- Tabby's October invoice, INV-M-KSA-158133, dated 31 Oct, is 3,293.80 plus 494.07 VAT.

The input VAT stands on these invoices. The settlement, however, booked each commission's VAT on input VAT on the day its deposit was due, which caused two problems:
- **The timing differed.** October's books held 432.25 of the two invoices' 898.26. Part of October's orders was deposited in November.
- **A claim was made twice.** The VAT of September's last orders, deposited in October, was claimed again in Q4. The Q3 return had already filed September's invoices (the owner: «نعم دخلت»).

ADR-089 requires the return's input VAT to be the books', so the books must hold the invoices.

## Decision

1. **The method's setting (policy).** `tax_invoice_from` is the month the company issues monthly tax invoices from. It is empty for every method until the owner sets it.
2. **The VAT waits (law).**
   - From that month, `commission_vat_account_on(day, payment_method=…)` gives the method's pending account. It is made once, beside the input VAT, and named «ضريبة عمولات <الوسيلة> بانتظار الفاتورة الضريبية».
   - The settlement and the deposit confirmation post their VAT there.
   - It is not among the return's input VAT accounts.
3. **The invoice (law).**
   - The accountant enters:
     - the month;
     - the number and date;
     - the company's VAT number;
     - its fee and VAT as printed.
   - The server compares the invoice with what the month's orders compute to, each at its kept rate (ADR-100), plus the fee per deposit for the settlements dated in the month. The comparison is shown, not enforced.
   - One `adjustment` voucher, dated the invoice's date (`reference_type='commission_invoice'`):
     - debits input VAT by the invoice's VAT and credits the pending account;
     - moves the rounding between the pending account and the commission.
4. **The report.** `MISSING_COMMISSION_TAX_INVOICE` lists a month that has orders and no invoice once its grace has passed. The check fixes nothing.
5. **The fourth quarter, once** (`tools/repair/commission_vat_wait.py`, a dry run by default).
   - For each method that has been set, the VAT its settlements and deposit differences claimed on input VAT from its first month is moved:
     - the share of orders from that month on goes to the pending account;
     - the share of earlier orders goes to «ضريبة مدخلات مستردة من الإقرار», the account that return's input VAT was booked against (ADR-089), because it was claimed twice.
   - There is one entry per month, dated the month's last day (the run's day for the current month).
   - A second run finds the months done.

## Proof

**Backend.** `tests/test_commission_tax_invoice.py` (16 tests):
- the VAT waits, and a method without invoices claims as before;
- the invoice claims its VAT, and its rounding goes to the commission;
- a later month's VAT stays pending;
- a deposit's difference waits;
- the seven refusals write nothing;
- a month has one invoice;
- cancelling the invoice brings its VAT back to wait;
- the month listing;
- the nightly check and its grace;
- the setting is applied from the API;
- the tool: September's share goes to «مستردة», October's waits, and a second run finds it done.

**Shown red:**
- 15 errors before the code existed;
- 6 failures with the waiting disabled;
- 1 failure with the rounding disabled.

The company-name scan of ADR-100 covers the service and the migration.

**Frontend.** `test/commission_tax_invoices_test.dart` (11 tests):
- 3 sizes × 2 themes: nothing overflows, no text vanishes, and no light surface appears in the dark;
- a table on a wide screen, cards on a phone;
- an invoice is previewed by the server, and its figures are sent as typed, with the last invoice's VAT number to start from;
- a cancellation is its voucher's cancel;
- a month is said by its name;
- the setting's month: `taxInvoiceFromJson` is `2026-10-01`, or empty when off.

**Frontend shown red:**
- with the month not sent, the setting test failed;
- with the VAT number not prefilled, the sending test failed.

**Rehearsal on a copy of the 24 Nov backup** (`cti_rehearsal`, after the ADR-100 rehearsal):
- The migration goes up, down and up again.
- Tamara and Tabby were set from October, and the tool was applied. Tamara's October settlements held 179.25 for September's orders, which moved to «مستردة». Everything else moved to waiting (Tamara 617.91, Tabby 721.55).
- The two October invoices were entered:

| | Tamara | Tabby |
|---|---|---|
| Q4 input VAT by the method's documents | 404.19 | 494.07 |
| Equals its invoice | exactly | exactly |
| Rounding moved to the commission | −1.27 | +0.38 |
| Still waiting for November | 214.99 | 227.10 |

- The bank was the same before and after (62,419.22).
- The tool's second run found the months done.
- The nightly check is silent on 25 Nov and lists November for both methods on 20 Dec.

## Consequences

### Positive
- The return's input VAT for these commissions is the companies' invoices, invoice by invoice, as ADR-089 requires.
- The double claim from Q3 is out of Q4.

### Watch Out For
- **After deploy, in this order:**
  1. In the payment method screen, set Tamara and Tabby «من شهر 2026-10».
  2. Run the tool as a dry run, then `--apply`, before October is locked (the period lock refuses an entry in a closed month) and before Q4's return.
  3. Enter October's two invoices from «متابعة التسويات» → «الفواتير الضريبية للعمولات».
  4. Then enter November and December as they arrive.
- Tamara's October invoice is 5.46 above what its orders compute to at their kept rates. The kept rate of October's payments is the old 6.078%; the deposits corrected the totals (ADR-100), and the invoice is the truth of the VAT.
- A method's orders before its first month that are settled later have VAT with no invoice in the system. Their VAT becomes part of the first invoice's rounding. None remain on production after the tool has run.
