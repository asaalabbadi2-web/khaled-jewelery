# ADR-027: دفعات الذهب المقدَّمة للمورد وتخصيصها (Gold Advance & Allocation)

**Status:** ⚠️ **Superseded in part by [ADR-028](ADR-028-supplier-gold-position-attribution.md)**
**Date:** 2026-09-24
**Sprint:** ERP — Invoice Payment Status Audit, Phase 15

> **تنبيه قبل القراءة.** اكتشاف Phase 16A أثبت على بيانات إنتاج حقيقية أن
> النموذج التشغيلي الموصوف هنا منفصل عن الدفتر بنحو 9 أضعاف (31,407 g مُسجَّلة
> مقابل 3,446 g حقيقية)، لأن الآلية اليومية الفعلية للتسوية (115 قسيمة دفع يدوي
> غير موسومة) لم تكن مرئية له. البنود المنسوخة: **auto-FIFO**،
> **`weight_remaining_main_karat` كرصيد مخزَّن**، **`GoldAllocation` كنموذج
> تسوية المورد**، و**`manual_allocate` كـoverride**. ما يبقى قائمًا: Single
> Writer، append-only، عزل الموردين، `reference_type='gold_advance'`،
> `InvoiceGoldObligation` بدل `InvoiceKaratLine`/`InvoiceItem`، ولا backfill
> تاريخي. الجدول الكامل لما نُسخ وما بقي في ADR-028 §«ما يُنسخ من ADR-027».

---

## Policy or Law?

> **This field is mandatory. No ADR merges without an answer.**

**Classification:** Both

| | تعريف | هذا القرار |
|---|---|---|
| **Law** | لا يجوز أن يتغيّر — انتهاكه يُسقط ضماناً. يُكتب كـ invariant مُختبَر. | الترحيل حصراً عبر `GoldAllocationService` (Single Writer) · `GoldAllocation` append-only · auto-FIFO بنفس العيار فقط · لا Allocation قبل نجاح الترحيل المحاسبي · العزل بين الموردين مُثبَت لا مُفترَض |
| **Policy** | يتغيّر بتغيّر العالم أو التشغيل — يُخزَّن كبيانات أو متغير نشر. | حدود cross-karat allocation المستقبلية (غير موجودة بعد) · صلاحيات `gold_advances.*` |

**أين يعيش هذا القرار؟**
- [x] **كود مُختبَر** — الـ invariants في `services/gold_allocation_service.py` + `tests/test_gold_allocation_service.py` + `tests/test_gold_advance_allocation_schema.py` + `tests/test_gold_advance_allocation_integration.py`
- [x] **بيانات / إعداد** — لا شيء بعد؛ لا سياسة قابلة للتعديل الحيّ في هذا القرار (بعكس SAD)

---

## Context

سلسلة تدقيق طويلة (Phases 11-14 من نفس المشروع) أثبتت أن `Invoice.total` لفواتير
`شراء` (مورد مسجَّل) يخلط قيمة الذهب المرجعية (ليست التزاماً نقدياً) بالتزام
نقدي حقيقي، وأن التزام الذهب الحقيقي على المورد (`المورد دائن بالذهب`) يُرحَّل
فعلياً إلى حساب مذكرة المورد الوزني — لكن **لا توجد آلية تربط سداد ذهب لاحق
بفاتورة شراء محددة**. 79% من سندات سداد الذهب الحقيقية (Phase 12E) لا تحمل أي
ربط بفاتورة.

القرار التجاري (Phase 12F) ميّز بين حالتين:
1. **سداد فاتورة** — يُسدَّد التزام فاتورة قائم، ربط إلزامي.
2. **دفعة مقدَّمة (Advance)** — ذهب يُدفَع للمورد قبل وجود فاتورة محددة تُنسَب
   إليها — مفهوم تجاري مشروع (رصيد دائن غير مخصَّص)، لا خطأ إدخال.

---

## Decision

**1. مصدر الـ Advance هو `Voucher.reference_type='gold_advance'`، لا `voucher_type` جديد.**

`voucher_type` (`receipt`/`payment`/`adjustment`) يصف **طبيعة الحركة**.
`reference_type` هو المميّز الدلالي **الموجود فعلاً** لغرض السند — تماماً كما
يميّز `'invoice'` مسار تسوية الفاتورة اليوم. إعادة استخدامه ليست اختصاراً، بل
هي المفصل الصحيح المطابق للنمط القائم. `Voucher.reference_type` عمود
`String(20)` بلا قيد CHECK على مستوى القاعدة — قيمة جديدة لا تكلّف شيئاً
مخططياً.

الوزن الحقيقي المدفوع للمورد يُقرأ من سطور `VoucherAccountLine` الخاصة
بالسند: `amount_type='gold' AND line_type='debit'` — اتجاه مُثبَت تجريبياً من
بيانات إنتاج حقيقية (سند #21 → JE#70، `debit_18k=90.8`، "طرف السداد": المدين
يُخفّض حساب الالتزام Liability، مطابقاً لاتجاه تسوية حقيقية سابقة).

**2. `InvoiceGoldObligation` هو دفتر الالتزام المُطبَّع الوحيد — وليس `InvoiceKaratLine` ولا `InvoiceItem` مباشرة.**

اكتُشف أثناء التنفيذ (Phase 15A-Correction) أن فواتير الشراء الحقيقية تُسجَّل
عبر مصدرين مختلفين بلا رابط بينهما: `InvoiceKaratLine` (33/180 فاتورة حقيقية،
18.3%) أو `InvoiceItem` (147/180، 81.7%). تصميم أول اعتمد عموداً مباشراً على
`InvoiceKaratLine` وحدها — كان أعمى عن 81.7% من الفواتير الحقيقية.

`InvoiceGoldObligation` (صف واحد لكل `(invoice_id, karat)`) يُطبِّع من أي
المصدرين — **الأولوية لـ`InvoiceKaratLine` إن وُجدت، وإلا `InvoiceItem`**
(وزن × كمية، مع الرجوع لعيار/وزن الصنف المرتبط `Item` عند خلوّ حقلَي
`InvoiceItem` نفسيهما). أُثبِت تجريبياً (Phase 15A-Discovery.2، بلا حالة
واحدة غامضة): الفواتير الأربع التي تحمل المصدرين معاً لهما إجمالي متطابق تماماً
لكل عيار — تكرار لنفس الحقيقة، لا التزامان مستقلان؛ لذلك الأولوية لا تُضاعف
شيئاً.

**مستوى الالتزام الحقيقي محاسبياً هو (فاتورة × عيار)، لا (سطر × عيار)**:
القيد الفعلي لفاتورة 52 يُرحِّل سطر ائتمان واحد لكل عيار على مستوى الفاتورة
كاملة، لا سطراً لكل صنف/سطر — `InvoiceGoldObligation` يطابق هذه الحبيبة
تماماً.

**3. `GoldAllocation` لا يشير مباشرة إلى `InvoiceKaratLine` ولا `InvoiceItem`.**

`GoldAllocation.obligation_id` يشير حصراً إلى `InvoiceGoldObligation`. هذا
يفصل "كيف سُجِّلت الفاتورة" (شأن إدخال) عن "دفتر التخصيص" — فإن ظهر مصدر ثالث
لتسجيل الفواتير مستقبلاً، يكفي تحديث `create_gold_obligations_for_invoice`
فقط؛ لا مساس بـ`GoldAllocation` ولا بمنطق المطابقة.

**4. auto-FIFO يُطابق بنفس العيار فقط — قرار مُثبَّت كتابياً، لا افتراض تقني.**

```
Advance 21K
   ↓
Invoices with remaining 21K obligations فقط
```

لا يحدث تحويل تلقائي مثل `Advance 21K → Invoice 18K` حتى مع وجود تحويل رياضي
ممكن إلى العيار الرئيسي. **الدلالة أوضح من الفائدة الحسابية**: الدفعة بعيارها
الأصلي تُغلق التزاماً من نفس العيار. تسوية عبر عيارات مختلفة **موجودة فعلاً في
النظام** عبر آلية أخرى (`karat_diff_*`/`_create_and_post_karat_diff_entries_
for_voucher`) حيث **إنسان يقرر رسم الفرق النقدي وقت إنشاء السند** — اختراع هذا
الرسم تلقائياً داخل محرك المطابقة كان سيتجاوز نطاق خدمة مطابقة/تسجيل بحتة.

`manual_allocate()` (تخصيص يدوي صريح) **لا يحمل هذا القيد** — هو المسار الذي
يُسجَّل فيه التطابق الوزني لتسوية عبر-عيارات **بعد** أن يكون إنسان قد قرر الرسم
في مكان آخر. دعم cross-karat التلقائي، إن أُريد مستقبلاً، **قرار مستقل بذاته**
— لا سلوك مخفي داخل FIFO.

**5. الرصيد يُقاس بالعيار الرئيسي المكافئ؛ الالتزام والسداد يُسجَّلان بعيارهما الأصلي.**

```
SupplierGoldAdvance                    InvoiceGoldObligation
├── karat, weight     (حقيقي)          ├── karat, weight     (حقيقي)
└── weight_remaining_main_karat        └── weight_remaining_main_karat

GoldAllocation
├── advance_id → obligation_id
└── weight_applied_main_karat          (يُخفِّض كلا الرصيدين أعلاه)
```

القاعدة: **الطرح بين عيارين مختلفين لا يُمكن حسابه إلا بوحدة مشتركة** —
مُثبَتة بالآلية القائمة فعلاً (`karat_diff_*`) التي تجسّر فرق العيار برسم نقدي
عبر نفس مبدأ التحويل. لا يُنشأ محرك تحويل ثانٍ — الآلة الوحيدة
`pricing/karat_service.py::convert_to_main_karat(weight, karat)`.

**6. دورة حياة الـ Allocation: Plan → Apply، بلا `validate()` منفصل.**

`GoldAllocationService` يُحاكي شكل `AllocationService` (المرجع الفني) عمداً —
`build_plan_for_advance`/`build_plan_for_obligation` (حساب نقي) →
`apply_plan` (كتابة، append-only) → `auto_allocate_for_*` (الاثنان معاً) →
`manual_allocate` (كتابة مباشرة واحدة، بلا خطة متعددة الأسطر) → `unallocate`
(حذف عند الإلغاء). **لا `validate()` قبل الكتابة** كما في `AllocationService`:
ذاك يحمي شرط "التغطية الكاملة إلزامية"؛ التخصيص الجزئي مع رصيد مفتوح هو
**النتيجة الطبيعية المقصودة** هنا (Phase 14)، فلا شيء يستوجب رفضه مسبقاً.

الـIdempotency خاصية تصميم لا حارساً إضافياً: كل حساب يُعاد قراءته من
`weight_remaining_main_karat` الحيّ، لا من عدّاد قابل للانحراف — نفس مبدأ
`AllocationService.build_allocation_plan()`.

**7. الانعكاس (Reversal) والعزل بين الموردين.**

إلغاء سند Advance يُحرِّر كل `GoldAllocation` تخصّه (`routes/vouchers.py`،
يطابق حرفياً سابقة `reference_type == 'clearing_settlement'` ونفس منطق حادثة
AV-2026-00223: ترك تخصيص يتيم بعد الإلغاء يُخفي رصيداً حقيقياً عن أي جدولة/تقرير
لاحق). مرتجع شراء يُحرِّر التزامات الفاتورة الأصلية عبر
`reverse_gold_allocations_for_invoice` (يطابق تسمية/دور
`reverse_weight_closing_executions_for_invoice` الموجودة، لكنه غير مربوط بها —
مسار مرتجع الشراء العادي لم يكن يستدعي أي آلية انعكاس مكافئة من قبل).

**العزل بين الموردين** مضمون في المسارات التلقائية ببنية الاستعلام نفسها
(`Invoice.supplier_id == advance.supplier_id`)، لكن `manual_allocate` يأخذ
مُعرِّفات مباشرة من مستدعٍ خارجي — اكتُشف أثناء بناء الـroutes (15C) أنه **لم
يكن يتحقق من تطابق المورد إطلاقاً**. أُضيف تحقق صريح يرفع `supplier_mismatch`
قبل أي كتابة.

**8. لا Backfill للتاريخ.**

289 سند ذهب حقيقي سابق لهذا القرار (Phase 12E) — لا واحد منها يحمل
`reference_type='gold_advance'` (قيمة جديدة لم تكن موجودة). حارس
`sync_gold_advance_after_voucher_approval` (`if voucher.reference_type !=
'gold_advance': return`) يكفي وحده لإبقاء التاريخ خارج النظام الجديد تماماً —
مُثبَت باختبار مباشر يبني سنداً بشكل تاريخي حقيقي (`reference_type=None`، وزن
ذهب حقيقي) ويؤكد صفر صفوف `SupplierGoldAdvance` تُنشأ منه.

**نقاط الاستدعاء التلقائي (auto-trigger):**

| الحدث | الاستدعاء | الموضع بالضبط |
|---|---|---|
| اعتماد سند `gold_advance` | `sync_gold_advance_after_voucher_approval` | 4 نقاط اعتماد حقيقية: `routes/vouchers.py::approve_voucher`، و`posting_routes.py` (فرع JE موجود مسبقاً + الفرع العادي + الدفعي) — نفس نقاط `sync_invoice_payment_state_after_voucher_approval` بالضبط |
| ترحيل فاتورة `شراء` | `create_gold_obligations_for_invoice` | `routes/invoices.py`، الذيل المشترك بعد `is_posted=True` مباشرة، **وليس** فرع الموافقة المعلَّقة |
| إلغاء سند `gold_advance` | `unallocate(advance_id=...)` | `routes/vouchers.py::cancel_voucher` |
| مرتجع شراء (مورد) | `reverse_gold_allocations_for_invoice` | نفس الذيل المشترك في `routes/invoices.py` |

**عمداً غير مربوط**: فرع `voucher_auto_post` داخل `create_voucher` — مزامنة
`InvoicePayment` الحالية نفسها لا تصله، فجوة سابقة قائمة، ليست من هذا القرار.

---

## Proof

`tests/test_gold_advance_allocation_schema.py` (نماذج/مخطط) ·
`tests/test_gold_allocation_service.py` (26 اختباراً للمحرك + المُطبِّع +
المزامنة + الانعكاس) · `tests/test_gold_advance_allocation_integration.py`
(5 اختبارات HTTP حقيقية عبر `app.test_client()`):

| القانون | الاختبار |
|---|---|
| FIFO بنفس العيار فقط، الأقدم أولاً | `test_fifo_covers_older_invoice_first_then_spills_to_newer` · `test_different_karat_obligation_is_never_touched` |
| تغطية جزئية/كاملة/تجاوز | `test_advance_smaller_than_single_obligation_leaves_it_open` · `test_advance_exceeding_all_open_obligations_leaves_unallocated_remainder` |
| عزل الموردين (تلقائي) | `test_different_supplier_obligation_is_never_touched` |
| Idempotency (تلقائي، مزامنة، مُطبِّع) | `test_calling_twice_does_not_double_allocate` · `test_calling_twice_for_the_same_voucher_creates_nothing_new` · `test_idempotent_second_call_creates_nothing` |
| التخصيص اليدوي: يعبر العيارات، يُرفض عند التجاوز، **يُرفض عند تعارض المورد** | `test_allows_cross_karat_unlike_auto_allocation` · `test_rejects_exceeding_advance_remaining` · `test_rejects_exceeding_invoice_obligation_remaining` · `test_rejects_cross_supplier_override` |
| الانعكاس يُحرِّر ويستعيد الرصيدين | `test_by_advance_id_restores_both_balances_and_deletes_rows` · `test_frees_a_real_allocation_and_restores_both_balances` |
| **لا Backfill للتاريخ** | `test_ignores_a_non_gold_advance_voucher` |
| `InvoiceGoldObligation`: كِلا المصدرين + الأولوية بلا ازدواج عدّ | `test_from_karat_lines` · `test_from_items_only_with_quantity` · `test_item_falls_back_to_linked_item_karat_and_weight_when_blank` · `test_both_sources_present_uses_karat_lines_only_no_double_count` |
| **HTTP حقيقي**: اعتماد سند حقيقي → Advance + تخصيص تلقائي عبر GL فعلي | `TestGoldAdvanceVoucherApprovalWiring::test_approving_a_gold_advance_voucher_creates_and_allocates_it` |
| **HTTP حقيقي**: قوائم + تخصيص يدوي + رفض 400 (تجاوز/تعارض مورد) | `TestGoldAdvancesRoutes::*` |
| **HTTP حقيقي**: إلغاء سند → تحرير التخصيص | `TestReversalWiring::test_cancelling_a_gold_advance_voucher_frees_its_allocation` |

**التحقق على PostgreSQL حقيقي** (`yasargold_prodcopy`، ترحيل
`20260923_gold_advance_allocation`): upgrade → downgrade → re-upgrade →
استدعاء `upgrade()` مباشرة مرة ثانية متجاوزاً تتبع alembic (idempotency حقيقي
لا بفضل تتبع alembic وحده) — 178/178 فاتورة شراء حقيقية، 186 صفاً (فواتير
متعددة العيار). حساب مُتحقَّق يدوياً: فاتورة 40، 18k وزن=104.38 →
89.468571 بالعيار الرئيسي 21 (104.38×18/21 تماماً).

بوابات أخرى: `clock_guard: PASS` · `erp_seam_ratchet: 8/8 OK` ·
`string_capacity_guard: OK` · `pytest` (`tests/` كاملة): 319 ناجح ·
السويت الافتراضي: 564 ناجح، فشل واحد سابق غير متعلق
(`test_bonus_points_parity.py`، مؤكَّد بدون هذا العمل أيضاً).

---

## Consequences

### Positive

**دَين الذهب الحقيقي للمورد صار قابلاً للتتبّع لكل فاتورة**، لا مجرد رصيد
إجمالي على مستوى المورد — دون أي تعديل على `JournalEntryLine`/دفتر الحسابات
القائم.

**لا مسار ترحيل موازٍ**: الالتزام والسداد يُقرآن من نفس مصادر GL الحالية
(`VoucherAccountLine`, `InvoiceKaratLine`/`InvoiceItem`) دون تكرار منطق
الترحيل.

**الفصل الثلاثي (تسجيل الفاتورة / دفتر الالتزام / التخصيص) يحتوي التغيير
المستقبلي**: مصدر تسجيل ثالث يحتاج تحديث مُطبِّع واحد فقط.

### Watch Out For

**auto-FIFO بنفس العيار فقط قد يترك أرصدة Advance/Obligation مفتوحة رغم وجود
تحويل رياضي ممكن.** هذا مقصود (انظر القرار §4)، لكن يعني أن دفعة 18k لن
تُغلق التزام 21k تلقائياً أبداً مهما طال الوقت — فقط عبر `manual_allocate`
البشري.

**دعم cross-karat التلقائي، إن طُلب مستقبلاً، قرار تجاري مستقل** يستلزم تصميم
رسم الفرق داخل محرك المطابقة نفسه — لا يُفترض أنه امتداد بسيط لما هو قائم.

**لا قفل صفوف (row locking) بعد.** طلبان متزامنان على نفس الـAdvance/الالتزام
غير محميين من سباق حقيقي — مؤجَّل عمداً لحدود المعاملة الفعلية عند التنفيذ،
مُوثَّق في الكود لا مُتجاهَل صامتاً.

**فجوة بيئة اختبار سابقة الوجود، غير مرتبطة بهذا القرار:** إنشاء فاتورة
`شراء` حقيقية عبر `POST /api/invoices` في بيئة اختبار فارغة يصطدم بحساب مذكرة
وزن ناقص من `AccountingMapping` ("No memo account for weight safety-net
posting")، فتُرفض قبل الوصول لهذا الكود أصلاً. مؤكَّد سابق الوجود
(`test_supplier_purchase_return_invoice.py` يفشل لنفس السبب مستقلاً). **لم
يُصلَح عمداً** — إصلاح محاسبي داخل هذه المرحلة لمجرد تمرير اختبار HTTP كان
سيتجاوز النطاق.

**76% من سندات الذهب التاريخية (125 سند حقيقي، Phase 12E) تبقى بلا Advance
أبداً.** لا Backfill — قرار سابق (Phase 12D/12F) يُعاد تأكيده هنا.

---

## Related

- `backend/services/gold_allocation_service.py` — المحرك + المُطبِّع + المزامنة + الانعكاس
- `backend/routes/gold_advances.py` — Thin Controller
- `backend/alembic/versions/20260923_supplier_gold_advance_and_allocation.py` — الجداول الثلاثة
- `backend/allocation_service.py` — المرجع الفني (الشكل، لا الجدول)
- `backend/pricing/karat_service.py` — `convert_to_main_karat()`، آلة التحويل القانونية الوحيدة
- `backend/posting_routes.py::_create_and_post_karat_diff_entries_for_voucher` — تسوية فرق العيار النقدية (مسار منفصل، بشري القرار)
- `backend/accounting/weight_closing.py::reverse_weight_closing_executions_for_invoice` — سابقة تسمية/دور الانعكاس
- ADR-025 — Supplier Settlement Adjustment (المرجع التنظيمي: بنية الملفات/الاختبارات/ADR)
