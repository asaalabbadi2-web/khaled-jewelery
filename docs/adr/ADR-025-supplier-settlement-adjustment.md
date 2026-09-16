# ADR-025: تسوية فروقات حسابات الموردين (SAD)

**Status:** Accepted
**Date:** 2026-09-16
**Sprint:** ERP — Supplier Settlement

---

## Policy or Law?

> **This field is mandatory. No ADR merges without an answer.**

**Classification:** Both

| | تعريف | هذا القرار |
|---|---|---|
| **Law** | لا يجوز أن يتغيّر — انتهاكه يُسقط ضماناً. يُكتب كـ invariant مُختبَر. | اتجاه القيد يُشتق من الرصيد ويُثبَت بالتصفير · الترحيل حصراً عبر Voucher pipeline · لا تعديل مباشر لأي رصيد · العكس وثيقة جديدة لا تعديل |
| **Policy** | يتغيّر بتغيّر العالم أو التشغيل — يُخزَّن كبيانات أو متغير نشر. | حدود التسوية (tolerance · period_cap · review_threshold) · حسابات GL للتسوية |

**أين يعيش هذا القرار؟**
- [x] **كود مُختبَر** — الـ invariants في `services/supplier_settlement_adjustment_service.py` + `tests/test_supplier_settlement_adjustment.py`
- [x] **بيانات / إعداد** — `supplier_settlement_policy` (مؤرَّخة الصلاحية) + `AccountingMapping` بـ `operation_type='تسوية_مورد'`

*الـ invariant كود، والمعاملات بيانات.*

---

## Context

بعد اكتمال تصفية حساب المورد يبقى أحياناً رصيد صغير جداً: فروقات تقريب، فروقات
تسوية نهائية، فروقات وزن، أو تنازل مورد موثّق. لم تكن هناك آلية رسمية لإغلاقه،
والبديل الصامت — تعديل الرصيد يدوياً — يكسر القاعدة الأساسية بأن
`JournalEntry/JournalEntryLine` هو مصدر الحقيقة المحاسبي الوحيد.

الخطر الحقيقي ليس الفرق الصغير، بل أن تتحوّل الآلية إلى زرّ لتصفير حسابات
الموردين، فتُخفي أخطاء تسوية حقيقية أو قيوداً ناقصة خلف مصروف/إيراد «تسوية».

سؤال إضافي فرضه الكود: `compute_live_supplier_balances()` تُرجع
`SUM(debit) − SUM(credit)`، أي أن **الموجب يعني أن المورد مدين لنا** والسالب يعني
أننا مدينون له. المواصفة الأولية وصفت الإشارة بالعكس بينما كانت القيود نفسها
صحيحة — وهذا بالضبط نوع الالتباس الذي يجعل مطوّراً لاحقاً «يصحّح» الكود في
الاتجاه الخاطئ فيُضاعف الرصيد بدل إغلاقه.

---

## Decision

**1. الوثيقة مستقلة ولا تكتب محاسبة بنفسها.**
`SupplierSettlementAdjustment` وثيقة بدورة حياة
`draft → approved → posted → reversed` (و`cancelled` قبل الترحيل). الأثر المحاسبي
يُنتَج حصراً عبر المسار القانوني القائم:

```
SupplierSettlementAdjustment
      → Voucher + VoucherAccountLine
      → create_journal_entry_from_voucher()
      → JournalEntry + JournalEntryLine
```

الخدمة **orchestrator** لا Posting Engine. لا `JournalEntry` ولا `JournalEntryLine`
تُكتب منها مباشرة، ولا يُمسّ أي عمود رصيد: لا `Account.balance_*`، ولا
`Supplier.balance_*`، ولا `Supplier.gold_balance_*`.

**2. مصدر الرصيد واحد.**
`compute_live_supplier_balances()` المبنية على `JournalEntryLine` هي المصدر
الوحيد للأهلية واللقطة. الأعمدة المشتقّة لا تُقرأ ولا تُكتب.
`SupplierGoldTransaction` خارج النطاق صراحةً (نظام أمانات ذهب منفصل).

**3. الاتجاه لا يُكتب كقاعدة وصفية، بل يُثبَت.**
المستخدم لا يختار «إيراد» أو «مصروف». الاتجاه يُشتق من إشارة الرصيد كما يُرجعها
الدفتر (موجب = مدين):

| الرصيد | المعنى | القيد |
|---|---|---|
| `> 0` | المورد مدين لنا | `Dr Settlement Expense / Cr Supplier` |
| `< 0` | نحن مدينون للمورد | `Dr Supplier / Cr Settlement Income` |

وفوق ذلك — وهو الأهم — **post-condition** من هويتين، يُنفَّذ بعد الترحيل القانوني
على الرصيد الحيّ من `compute_live_supplier_balances()`:

| | الهوية | أين تُطبَّق |
|---|---|---|
| **1** | `balance_after == balance_before + signed_effect` | كل ترحيل: التسوية **والعكس** |
| **2** | `balance_after == 0` | التسوية فقط |

الهوية 1 هي الأصل: الاكتفاء بفحص «الرصيد صار صفراً» يمكن أن يمرّ بالمصادفة في
حالات لم يتحرك فيها الدفتر بالأثر المقصود أصلاً. إثبات الحساب يُثبت أن أثر
التسوية نفسها كان `-residual` بالضبط.

وتُطبَّق الهويتان على **كل عيار بالجرام** كما تُطبَّقان على النقد بالريال. العيار
الذي لم يُسوَّ أثره المتوقع صفر — وبهذا يُلتقط أي تسرّب وزني من تسوية نقدية.

الهوية 2 منفصلة عمداً لأن **العكس يُعيد فتح الرصيد قصداً** — فحص «صفر» عليه يكون
الفحص الخاطئ تماماً. وهذا هو المكسب الملموس من الفصل: مسار `reverse()` صار
محمياً بـ Law 0 وهو ما لم يكن ممكناً بفحص التصفير وحده.

الدقة: `CASH_EPSILON=0.01` و`WEIGHT_EPSILON=0.001`. أي خرق يرفع
`SettlementInvariantViolation` — وهو يحمل `balance_before` و`balance_after`
و`expected_after` كحقول، فيُبرهَن الخرق رقمياً لا بقراءة نص — فتُلغى العملية
بالكامل. لو انعكس الاتجاه لكبر الرصيد بدل أن يُغلق، ولسقط الاختبار.

**4. إعادة الفحص عند الترحيل هي الحَكَم.**
فحص الـ draft إرشادي فقط. `post()` يقفل الصف (`SELECT FOR UPDATE`)، يعيد قراءة
الرصيد، يعيد تنفيذ كل فحوص الأهلية، ثم يقارن باللقطة. أي انزياح يُعيد الوثيقة إلى
`draft` ولا يكتب شيئاً — ولا تُحدَّث اللقطة تلقائياً ولا يُعدَّل المبلغ ولا يُنشأ
قيد تعويضي؛ `recalculate()` صريح هو الطريق الوحيد.

وعند الإرجاع إلى `draft` **يُلغى الاعتماد** (`approved_by/at/by_manager`): الاعتماد
مُنح لرصيد لم يعد قائماً، فلا يُحتفظ به صامتاً. إعادة الترحيل تمرّ باعتماد جديد
صريح للرقم المُعاد حسابه.

بالمقابل، فشل أهلية لا علاقة له باللقطة (نشاط مورد جديد مثلاً) **يُبقي الوثيقة
معتمدة**: لقطتها ما زالت صحيحة والعائق في مكان آخر.

**5. لا حذف ولا تعديل لوثيقة مرحّلة.**
التصحيح يتم بوثيقة جديدة تحمل `reversal_of_id`، والأصل ينتقل إلى `reversed`.
`voucher_id` و`reversal_of_id` كلاهما `UNIQUE` — قاعدة البيانات نفسها ترفض
ترحيلاً مزدوجاً أو عكساً مزدوجاً حتى لو تجاوز أحدهم القفل.

**6. لا أرقام حسابات في الكود.**
الحسابات تُشتق عبر `AccountingMapping` بـ `operation_type='تسوية_مورد'` وأربعة
`account_type`:

| `account_type` | الاستخدام |
|---|---|
| `supplier_settlement_expense` | الطرف المقابل لتسوية نقدية موجبة |
| `supplier_settlement_income` | الطرف المقابل لتسوية نقدية سالبة |
| `supplier_weight_settlement_expense` | الطرف المقابل لتسوية وزن موجبة |
| `supplier_weight_settlement_income` | الطرف المقابل لتسوية وزن سالبة |

غياب أي ربط مطلوب يرفع `MissingAccountingMappingError` — **لا حساب افتراضي في
التسويات**.

**7-أ. وحدة قياس الوزن في السياسات هي العيار الرئيسي.**

> SAD retains weight residuals by original karat for accounting and audit
> purposes, while tolerance and monthly cumulative caps are measured using the
> equivalent weight in the system's configured Main Karat.

> Main-Karat conversion is a measurement normalization for eligibility and
> policy limits, not a monetary valuation and not a replacement of the
> original-karat memo posting.

الجرامات على عيارات مختلفة ليست الكمية نفسها، فلا تُجمع خامًا أبداً. التحويل يتم
بالآلة القانونية الوحيدة في المشروع:

```python
pricing/karat_service.py :: convert_to_main_karat(weight, karat)
```

وهي تحلّ العيار الرئيسي داخلياً من `Settings.main_karat`. **لم يُنشأ محرك تحويل
ثانٍ**، ولا تُكتب المعادلة يدوياً في SAD.

| يُقاس بالعيار الرئيسي | يبقى بالعيار الأصلي |
|---|---|
| `tolerance_weight` | اللقطة (`balance_before_weight`) |
| `period_cap_weight` | المبالغ المرحّلة (`posted_amount_weight`) |
| أهلية وجود رصيد وزني | سطور القيد وأعمدة العيارات |
| — | Law 0 (يُثبَت على كل عيار أصلي) |
| — | العكس (يعكس كل عيار بوزنه الأصلي) |

**الجمع بالمقدار لا بالإشارة:** رصيدان متعاكسان لا يتقاصّان عند قياس الحدّ —
الشطب يستهلك مخصّصه في الاتجاهين، وإلا لمرّ زوج تسويات كبير متعاكس من حدّ صغير
واستهلك صفراً من السقف.

**العيار الرئيسي لا يغيّر الحساب الموازي ولا عمود العيار.** لا يُنشأ قيد إضافي
بسبب التحويل، ولا يُدمج متعدد العيارات في سطر واحد.

**7-ب. الحدود سياسة مؤرَّخة الصلاحية.**
`supplier_settlement_policy` تحمل `tolerance_cash/weight`،
`period_cap_cash/weight`، `review_threshold_cash`، مع `effective_from/to`.
تُقرأ **Live لحظة `post()`** (الحدّ النافذ وقت القرار المحاسبي هو الحاكم — §13)،
ثم يُجمَّد `policy_id` على الوثيقة للتدقيق. السقف التراكمي يُحسب لكل
`supplier + شهر ميلادي (YYYY-MM)`؛ وإذا تغيّرت السياسة داخل الشهر فالسقف النافذ
لحظة الترحيل يُطبَّق على إجمالي الفترة كاملة. الوثيقة المعكوسة — والوثيقة العاكسة —
لا تستهلكان من السقف، لأن أثرهما الصافي صفر.

**8. حد المراجعة ليس حدّاً كمّياً آخر.**
رصيد يتجاوز `review_threshold_cash` (ابتدائياً 500 SAR) يُرفض برفض مُسمّى
`SupplierAccountReviewRequiredError` — ليس «تسوية أكبر»، بل حقيقة محاسبية غير
مُفسَّرة تُحوَّل إلى مراجعة حساب المورد. يُرفع عند `create_draft` و`post()` معاً.

الخطأ **مُهيكل** ليقرأه الـ API/UI بلا تحليل نص:
`supplier_id · current_cash_residual · current_weight_residual · review_threshold ·
reason` (`RESIDUAL_ABOVE_REVIEW_THRESHOLD`)، مع `to_dict()`.

وهو **رفض فقط**: لا Voucher، لا JournalEntry، لا تعديل رصيد، لا إعادة حساب
تلقائية، ولا تخفيض للرصيد. لا يبدأ أي workflow ولا يستحدث دور اعتماد — نظام
Supplier Account Review ميزة منفصلة خارج نطاق هذا القرار.

**أسبقية صريحة:** إذا اجتمع تجاوز حد المراجعة مع رصيد وزني مفتوح، يسبق خطأ
المراجعة لأنه الحقيقة الأكبر، وحمولته تحمل أرقام الوزن أصلاً فلا يُخفى شيء.
الأسبقية تخص التشخيص فقط — كلا المسارين لا يكتب شيئاً.

**9. أسباب مغلقة، و`PURCHASE_DISCOUNT` ليست منها.**
`ROUNDING_DIFFERENCE · FINAL_SETTLEMENT_DIFFERENCE · WEIGHT_DIFFERENCE ·
DOCUMENTED_SUPPLIER_WAIVER · OTHER`. خصم المشتريات الحقيقي له أثر على
المخزون/التكلفة/الضريبة ويجب أن يمرّ بمساره المحاسبي، لا عبر فرق تسوية.
`OTHER` تستلزم ملاحظة مكتوبة واعتماد مدير.

**10. الوزن يُسوَّى بنفس دلالات النقد — عبر الحساب الموازي، وبلا تقييم.**

> Weight residuals are settled using the same settlement semantics as cash
> residuals, but through the supplier's parallel memo/weight accounts, without
> monetary valuation or inventory movement.

قاعدة الاتجاه واحدة للجانبين، تُطبَّق على كل عيار مستقلاً:

| رصيد العيار | القيد |
|---|---|
| `> 0` | `Dr Weight Settlement Expense / Cr Supplier Memo Account` |
| `< 0` | `Dr Supplier Memo Account / Cr Weight Settlement Income` |

الجرام يُغلق بالجرام. لا يُنفَّذ أيٌّ مما يلي تحت أي ظرف:

- تحويل الوزن إلى ريال
- قراءة سعر الذهب (الحالي أو التاريخي) لتقييم الفرق
- استدعاء `GoldCostingService` بأي شكل — `consume_inventory` أو غيره
- تعديل المخزون أو تحميل COGS أو إنشاء Inventory Adjustment
- إنشاء `WeightClosingOrder` أو قيد تقييم
- دمج العيارات في مبلغ واحد أو في وزن مكافئ

**كل عيار أثر مستقل.** سند واحد قد يحمل أربعة أزواج سطور لأربعة عيارات، ولا
تُجمع في أي مرحلة.

**الوصول إلى الحساب الموازي لا يُشتق.** سطر الذهب يحمل معرّف الحساب **المالي**
للمورد، ويتولى `_resolve_account_id_for_amount_type` إعادة توجيهه إلى حساب
المذكرة عبر `Account.memo_account_id` — أي عبر شجرة الحسابات لا بقاعدة رقمية
(بادئة `7` أو غيرها). لا يُكتب `memo_account_id` مباشرة؛ الربط عبر
`account_pair_service.link_accounts()` حصراً.

**وحسابات تسوية الوزن يُتحقق من صلاحيتها للوزن قبل الترحيل:** يُحسب المكان الذي
سينتهي إليه سطر الذهب فعلاً، فإن لم يكن حساباً يتتبع الوزن (`tracks_weight`)
يُرفع `MissingAccountingMappingError` — لأن ترحيل جرامات إلى حساب مالي يعني
ضياعها صامتة.

**11. الواجهة Thin Controller، والصلاحية والهوية من الخادم وحده.**

`backend/routes/supplier_settlement_adjustments.py` — مسؤول فقط عن المصادقة
والتخويل والتحقق من الطلب واستدعاء الخدمة وتحويل الأخطاء إلى HTTP. لا منطق
محاسبي فيه.

```
POST   /api/suppliers/<id>/settlement-adjustments          إنشاء مسودة
GET    /api/suppliers/<id>/settlement-adjustments          قائمة (?status=)
GET    /api/supplier-settlement-adjustments/<id>
POST   /api/supplier-settlement-adjustments/<id>/recalculate
POST   /api/supplier-settlement-adjustments/<id>/approve
POST   /api/supplier-settlement-adjustments/<id>/post
POST   /api/supplier-settlement-adjustments/<id>/reverse
POST   /api/supplier-settlement-adjustments/<id>/cancel
```

**العميل يرسل `reason_code` و`note` فقط.** أي حقل من
`is_manager · amount · account_id · policy_id · voucher_id · journal_entry_id ·
created_by · approved_by · posted_by · status · direction` يُرفض بـ 400
`client_controlled_field_rejected` — **رفض لا تجاهل**، حتى لا يظن المستدعي أنه
تحكّم بقيمة لم يتحكم بها. الاتجاه والمبالغ والحسابات تشتقها الخدمة من الرصيد الحي.

الإسناد (`created_by/approved_by/posted_by/reversed_by/cancelled_by`) يأتي من
`g.current_user` حصراً. الـ route هو حدّ ADR-015 الزمني: يقرأ الساعة مرة ويحقن
`now` في الخدمة.

**12. الاعتماد الإداري صلاحية، لا دور جديد.**

`is_manager` يُشتق في الخادم:

```python
user.is_admin  or  user.has_permission('supplier_settlement_adjustments.approve_other')
```

أُضيفت سبع صلاحيات إلى `ACCOUNTING_PERMISSIONS` بنفس نمط
`<domain>.<action>` القائم (`journal.post` · `bonus.approve` …):
`view · create · approve · approve_other · post · reverse · cancel`.

لم يُنشأ دور جديد. الأدوار القائمة في `ROLE_PERMISSIONS` استُخدمت كما هي:
**`manager` يحصل على `approve_other`، و`accountant` لا يحصل عليها** — فصار
شرط «السبب OTHER يستلزم مديراً» مُطبَّقاً ببيانات الصلاحيات لا بكود خاص.

---

## Proof

> **Law 0: كل قانون له اختبار يُثبته — وإلا فهو توصية.**

`backend/tests/test_supplier_settlement_adjustment.py` — 54 اختباراً للخدمة، و`test_supplier_settlement_adjustment_api.py` — 22 للواجهة، و`test_auth_bypass_production_guard.py` — 22 لحارس SEC-005:

| القانون | الاختبار |
|---|---|
| الاتجاه يُشتق من الإشارة | `test_post_closes_balance_when_supplier_owes_us` · `test_post_closes_balance_when_we_owe_supplier` |
| **Law 0 هوية 1+2** — النقد وكل عيار | `test_law0_arithmetic_identity_holds_for_cash_and_every_karat` |
| **Law 0 هوية 1** على مسار العكس | `test_law0_identity_holds_for_reversal` |
| **شاهد أحمر — الترحيل:** الاتجاه المقلوب يُكبّر الرصيد ويُلتقط | `test_invariant_catches_inverted_direction` |
| **شاهد أحمر — العكس:** مبلغ عكس خاطئ يُلتقط | `test_invariant_catches_wrong_reversal_amount` |
| إعادة الفحص عند الترحيل + عدم الكتابة | `test_snapshot_mismatch_kicks_back_to_draft_and_writes_nothing` · `test_balance_drifting_to_zero_kicks_back_rather_than_dead_ending` |
| الاعتماد اللاغي يُلغى عند الإرجاع | `test_snapshot_kick_back_voids_the_stale_approval` |
| نشاط مورد جديد يمنع الترحيل دون إرجاع | `test_new_supplier_activity_blocks_posting_without_kicking_back` |
| إعادة الحساب صريحة | `test_refresh_snapshot_then_post_succeeds` |
| العكس وثيقة جديدة والأصل لا يُعدَّل | `test_reversal_creates_new_document_and_restores_balance` · `test_posted_adjustment_cannot_be_cancelled` · `test_adjustment_cannot_be_reversed_twice` |
| Idempotency: لا وثائق مكرّرة | `test_repeated_post_creates_no_second_document` · `test_repeated_reverse_creates_no_second_document` |
| السياسة Live + `policy_id` مجمَّد | `test_policy_is_read_live_at_post_time` · `test_policy_id_is_frozen_on_the_document` |
| تغيّر السياسة منتصف الشهر: سقف الشهر كاملاً بلا تجزئة | `test_mid_month_policy_change_applies_whole_month_cap` |
| السقف التراكمي · المعكوس لا يستهلكه · حتمية القياس | `test_period_cap_accumulates_across_adjustments` · `test_reversed_adjustment_does_not_consume_period_cap` · `test_period_consumption_is_deterministic_and_idempotent` |
| حد المراجعة: رفض مُهيكل بلا أي كتابة | `test_residual_above_review_threshold_is_refused` · `test_review_error_carries_structured_payload` · `test_review_refusal_writes_absolutely_nothing` · `test_review_threshold_refusal_at_post_is_typed` |
| لا حساب افتراضي | `test_missing_accounting_mapping_refuses_and_writes_nothing` |
| **الوزن يصل فعلاً لحساب المذكرة وبالاتجاه الصحيح** | `test_weight_only_residual_settles_into_the_memo_account` · `test_negative_weight_residual_reverses_the_direction` |
| النقد والوزن في وثيقة واحدة | `test_cash_and_weight_settle_together_in_one_adjustment` |
| عيارات متعددة، كل عيار مستقل | `test_multiple_karats_each_settle_to_their_own_column` |
| **لا تقييم ولا مخزون ولا COGS** (تجسس يفجّر عند أي استدعاء لـ GoldCostingService) | `test_weight_settlement_has_no_monetary_or_inventory_effect` |
| ربط وزن إلى حساب لا يتتبع الوزن يُرفض | `test_weight_mapping_to_a_non_weight_account_is_refused` |
| **شاهد أحمر — الوزن:** اتجاه وزن مقلوب يُلتقط | `test_invariant_catches_inverted_weight_direction` |
| Law 0 للوزن لكل عيار | `test_law0_identity_holds_for_weight_on_every_settled_karat` |
| تباين لقطة الوزن يمنع الترحيل | `test_weight_snapshot_mismatch_blocks_posting` |
| العكس يعيد النقد والوزن معاً | `test_reversal_restores_cash_and_weight_together` |
| **العيارات لا تُجمع خاماً** | `test_karats_are_never_summed_as_raw_grams` |
| وحدة القياس تتبع `Settings.main_karat` لا ثابتاً | `test_main_karat_equivalent_follows_configured_setting` |
| المتعاكسان لا يتقاصّان | `test_opposite_direction_residuals_do_not_cancel_each_other` |
| الحدّ يُقارن بالمكافئ | `test_tolerance_is_compared_against_the_main_karat_equivalent` · `test_weight_operation_tolerance_blocks_oversized_karat` |
| السقف التراكمي بالمكافئ عبر وثائق سابقة | `test_period_cap_accumulates_in_main_karat_equivalent` · `test_period_cap_mixes_karats_through_the_equivalent` |
| **التحويل لا يمسّ الحساب الموازي ولا عمود العيار** | `test_main_karat_does_not_change_the_posting_account_or_karat_column` |
| عكس متعدد العيارات يُعيد فتح كل عيار بوزنه الأصلي | `test_multi_karat_reversal_reopens_each_original_karat` |
| لا تعديل للأرصدة المشتقّة | `test_denormalised_balances_are_never_touched` |
| `PURCHASE_DISCOUNT` ليست سبباً | `test_purchase_discount_is_not_a_settlement_reason` |

**السياسة:** `supplier_settlement_policy` — يملك تغييرها المالية (finance)، بإغلاق
الصف النافذ (`effective_to`) وإدراج خلف له، لا بالتعديل في مكانه.
**حسابات GL:** `AccountingMapping` — يملكها المحاسبة، وهي شرط تشغيل قبل أول ترحيل.

بوابات أخرى مُشغَّلة: `clock_guard: PASS` (15 عند خط الأساس — لا دين وقت جديد،
الخدمة لا تقرأ الساعة إطلاقاً وتستقبل `now` حقناً وفق ADR-015) ·
`erp_seam_ratchet: OK 8/8` · `pytest: 489 passed · 8 skipped · 1 failed`
(الفشل الوحيد `test_bonus_points_parity.py` سابق لهذا العمل وغير متعلق به —
يفشل منفرداً وعند استبعاد ملف اختبارات SAD، ولم يُمسّ).

---

## Consequences

### Positive

**الفرق الصغير صار وثيقة قابلة للتدقيق** بدل تعديل صامت: من أنشأ، من اعتمد، من
رحّل، بأي سبب، تحت أي سياسة، وبأي قيد.

**اتجاه القيد لا يمكن عكسه صامتاً.** أي تعديل مستقبلي يقلب الإشارة يسقط في
`test_invariant_catches_inverted_direction` قبل أن يصل إلى الدفتر.

**لا مسار ترحيل موازٍ.** الوثيقة تستهلك نفس الـ Voucher pipeline، فترث وسم الطرف،
كشف حساب المورد، الترقيم، وإعادة حساب الأرصدة — بلا نسخة ثانية من منطق الترحيل.

**التحايل بالتقسيم مغلق.** عشر تسويات صغيرة تصطدم بالسقف التراكمي الشهري.

### Watch Out For

**شرط تشغيل قبل أول استخدام:** لا يعمل الترحيل قبل إضافة صفوف `AccountingMapping`
الأربعة. هذا رفض مقصود، لا عطل — والحسابات المقابلة غير موجودة في شجرة الحسابات
بعد، فالأمر **قرار مالي معلّق** لا نقص تنفيذ.

**🔴 P0 — `BYPASS_AUTH_FOR_DEVELOPMENT` يُبطل كل ضمانات التخويل أعلاه.**
مُسجَّل كـ **SEC-005** في `architecture-v1.md §4.6`.

الراية مخصّصة للتطوير وحده، وهي موجودة في `backend/.env` حالياً و`app.py` يحمّلها.
حين تكون مشتعلة: أي طلب `/api/` بلا ترويسة `Authorization` يُخدَم بهوية `admin`،
فيسقط `require_auth` و`require_permission` و`require_admin` وكل ما بُني عليها —
ومنها شرط الاعتماد الإداري للسبب `OTHER` في §12.

**يجب أن تكون مطفأة في الإنتاج.** والتخفيف مزدوج:

1. `_assert_auth_bypass_not_in_production()` ترفع `RuntimeError` عند الإقلاع إذا
   اجتمعت الراية مع `YASAR_ENV/FLASK_ENV = prod|production` — نفس اختيار المنصة
   في Law 7: فشل إقلاع مرئي فوراً خير من واجهة مفتوحة صامتة.
2. الـ `before_request` يفحص الإنتاج استقلالاً فلا يطبّق الالتفاف أصلاً
   (defence in depth).

**وأثرها على الإثبات:** أي اختبار تخويل يُنفَّذ في بيئة الراية فيها مشتعلة **لا
يُثبت شيئاً** عن أمن الإنتاج. لذلك يُطفئها اختبار `401` صراحةً، وكذلك
`tests/test_auth_bypass_production_guard.py`.

الإصلاح النهائي: إزالة الالتفاف كلياً متى توفّر تسجيل دخول محلي مُهيّأ للتطوير.

**الترحيلة تبذر السياسة عند خلو الجدول لا عند إنشائه.** قاعدة أقلع عليها التطبيق
تملك الجدولين مسبقاً من `db.create_all()`؛ ربط البذر بالإنشاء كان سيتخطاه صامتاً
فتبقى SAD بلا سياسة نافذة وترفض كل عملية. وكشف الاختبار أثناء ذلك أن
`created_at` في النموذج `default=` (من جهة ORM) لا `server_default=`، فجدول
`create_all` يرفض إدراجاً لا يذكره — ولذلك تُدرجه الترحيلة صراحةً.

**`review_threshold_cash` ليس قيمة تجميلية.** رفعه يحوّل SAD تدريجياً إلى أداة
شطب. أي تعديل عليه قرار مالي لا تقني.

**حسابا تسوية الوزن شرط تشغيل إضافي.** بجانب حسابي النقد، يلزم ربط
`supplier_weight_settlement_expense` و`supplier_weight_settlement_income`
بحسابات تتتبع الوزن أو مرتبطة بحسابات مذكرة. الربط الخاطئ يُرفض عند الترحيل ولا
يُكتشف متأخراً.

**السقف الوزني مشترك عبر العيارات** بعد التحويل للعيار الرئيسي — وليس سقفاً
مستقلاً لكل عيار. استهلاك بُذل في عيار 24 يُضيّق ما يمكن تسويته في عيار 21 داخل
الشهر نفسه. هذا مقصود: المخصّص الشهري كمية ذهب واحدة، لا أربع كميات منفصلة.

**تغيير `Settings.main_karat` يغيّر معنى الحدود بأثر فوري** على الوثائق غير
المرحّلة: الحدّ نفسه (0.500 مثلاً) يمثل كمية ذهب مختلفة إذا تغيّر العيار الرئيسي.
الوثائق المرحّلة لا تتأثر — أوزانها الخام محفوظة بعياراتها الأصلية. لكن التراكم
الشهري يُعاد حسابه من الخام عند كل فحص، فتغيير العيار الرئيسي في منتصف الشهر
يُعيد تقييم ما استُهلك. لم نُجمّد العيار الرئيسي على الوثيقة لأن ذلك يجعل
التراكم غير قابل للجمع عبر وثائق بعيارات رئيسية مختلفة.

**مسار `Supplier Account Review` غير مبني.** SAD يرفض ويُسمّي الرفض، لكن ما يحدث
بعد التحويل إلى المراجعة ليس ضمن هذه الوثيقة.

**`find_incomplete_vouchers` لم تُستخدم كما اقترحت المواصفة:** توقيعها
`(safe_box=...)` ومحصور بـ `reference_type='clearing_settlement'` — محور
SafeBox/وسيلة دفع لا محور مورد. استُبدل بفحص مكافئ على محور المورد
(`no_pending_vouchers`). أي ربط مستقبلي بين المحورين يحتاج تصميماً مستقلاً.

---

## Related

- `backend/services/supplier_settlement_adjustment_service.py` — الخدمة
- `backend/tests/test_supplier_settlement_adjustment.py` — الإثبات
- `backend/alembic/versions/20260916_supplier_settlement_adjustment.py` — الجدولان
- `backend/accounting/voucher_engine.py` — مسار الترحيل القانوني
- `backend/services/party_live_balances.py` — مصدر الرصيد الوحيد
- `backend/pricing/karat_service.py` — `convert_to_main_karat()`، آلة التحويل القانونية الوحيدة
- `backend/account_pair_service.py` — `link_accounts()`، الكاتب الوحيد لـ `memo_account_id`
- `backend/ACCOUNT_PAIR_ARCHITECTURE.md` — بنية الحسابات الموازية
- ADR-015 — Clock Protocol (حقن `now`)
- ADR-023 — ERP Modernization (هذه ميزة داخلية، ليست لمسة تكامل، فلا صف في Seam Ledger)
- `docs/architecture/architecture-v1.md` §13 — Frozen vs Live (السياسة Live عند الترحيل، `policy_id` مجمَّد)
