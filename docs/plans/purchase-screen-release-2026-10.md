# شاشة فاتورة الشراء وما معها: خطة الدفع والنشر

**التاريخ:** 2026-10-07 · **الفرع:** `claude/purchase-invoice-screen-ux-063943` (انطلق من `26f65ce0`، وهو `main` على `origin` و`gitlab`)
**المرجع:** ADR-038 (الثيم) · ADR-039 (معالجة الأجور) · PURCHASE-UX-1..4 · PURCHASE-VAT-1 · Known Gaps (§4.6)

## الإصدارات

CI في GitLab يبني صورة لرأس كل دفعة إلى `main` وحده (`feedback-one-release-per-push`)، فكل إصدار يُدفع وحده بالترتيب.

| الإصدار | الإيداعات | المحتوى | ترحيل قاعدة بيانات |
|---|---|---|---|
| ١ | `3d4848b2` | الثيم: ألوان التطبيق من ثيم واحد، كل دور معرّف، وحارسان (ADR-038) | لا |
| ٢ | `3d0850e3` | شاشة الشراء ١: «جاهز» حين يقبل الخادم وحده، والشريط السفلي، وحفظ واحد في كل مرة، وسؤال الخروج | لا |
| ٣ | `803be839` · `528eaa1c` · `7cb9d1cc` | الأجور تتبع إعداد الشركة في الشراء والبيع، والإصدار يصحّح إعداد الإنتاج و156 فاتورة بالدليل (ADR-039) | **نعم**: `20261006_wage_mode_matches_books` (بيانات فقط) |
| ٤ | `32efe151` · `898218f4` · `77a55685` · `09846914` · `ba449664` | الضريبة من الرقم الضريبي للمورد على وجه الفاتورة، والأوزان اليدوية، والمستحق بالكلمات، والفاصلة العربية «٫»، والملخّص الواحد، والوثائق | **نعم**: `20261006_invoice_vat_applied` (عمود جديد، بلا تعبئة) |
| ٥ | `bc80f35a` | ضريبة المبيعات إعداد واحد للشركة بدل مفتاح كل جهاز، وملف الخطة هذا (SALES-VAT-1) | **نعم**: `20261007_sales_vat_setting` (عمود، ويُضبط «لا» بالدليل) |
| ٦ | رأس الفرع | مرتجع المورد يعكس الشراء سطرًا بسطر: لا نقد لقيمة الذهب، والأجور وضريبتها تُعكس حيث رحّلها الشراء (RETURN-WAGE-1) | لا |

**الإصدار ٣ لا يُفصل:** `803be839` وحده يجعل مشتريات الشركة تُحمَّل على المصروفات حتى يصل تصحيح الإعداد في `528eaa1c`.

## الدفع

بيد المالك؛ نظام الأذونات أوقف دفع الوكيل. كل أمر من أي مكان، و`-C` يشير إلى نسخة العمل.

```
# ١
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push origin 3d4848b2:refs/heads/main
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push gitlab 3d4848b2:refs/heads/main
# ٢
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push origin 3d0850e3:refs/heads/main
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push gitlab 3d0850e3:refs/heads/main
# ٣
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push origin 7cb9d1cc:refs/heads/main
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push gitlab 7cb9d1cc:refs/heads/main
# ٤
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push origin ba449664:refs/heads/main
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push gitlab ba449664:refs/heads/main
# ٥
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push origin bc80f35a:refs/heads/main
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push gitlab bc80f35a:refs/heads/main
# ٦ — رأس الفرع
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push origin claude/purchase-invoice-screen-ux-063943:refs/heads/main
git -C /Users/salehalabbadi/yasargold/.claude/worktrees/purchase-invoice-screen-ux-063943 push gitlab claude/purchase-invoice-screen-ux-063943:refs/heads/main
```

خطوط البناء لا تُلغى إن تلتها دفعة (لا `interruptible` في `.gitlab-ci.yml`)، فكل دفعة تبني صورتها. والصورة لا تُبنى من إيداع أحمر في الاختبارات، فيُتحقق من خطّ كل إصدار قبل نشره.

## النشر: إصدار واحد كل مرة (`docs/runbooks/release-rehearsal.md`)

الوسم أول ثمانية أحرف من رأس الإصدار: `3d4848b2`، ثم `3d0850e3`، ثم `7cb9d1cc`، ثم `ba449664`، ثم `bc80f35a`، ثم رأس الفرع عند الدفع.

1. على الخادم: `.\update-prod.bat -Tag <tag> -Backup` — يتحقق من الصورتين، ويأخذ نسخة، ويطبع أمر التمرين.
2. على الماك: أمر التمرين المطبوع (`backend/tools/rehearse_release.py`). لا نشر إلا على **أخضر**.
3. على الخادم: `.\update-prod.bat -Tag <tag> -Deploy -Rehearsed`. التراجع: `.\update-prod.bat -Tag <الوسم السابق> -Deploy -Rollback`.

### ما يُتحقق منه

| الإصدار | في التمرين | بعد النشر |
|---|---|---|
| ١ | أخضر | الشريط والأزرار بالذهبي البرونزي، والحدود خافتة، في الوضعين |
| ٢ | أخضر | شريط الحالة السفلي في فاتورة الشراء؛ الرجوع من فاتورة فيها أصناف يسأل |
| ٣ | يطبع الترحيل `expense -> inventory (156 posted purchase lines capitalized wages)` و`156 purchase snapshots now say inventory` | الإعدادات: معالجة الأجور «رسملة»؛ فاتورة شراء جديدة تُدخل أجورها في 1320 |
| ٤ | يضيف `vat_applied`؛ كل الفواتير بلا قيمة فيه | مفتاح «بضريبة / بلا ضريبة» على الفاتورة، وقسم الأوزان اليدوية، والملخّص الواحد |
| ٥ | يطبع الترحيل `[sales_vat_setting] True -> False (50 recent taxable sales read)` | الإعدادات: «ضريبة على المبيعات» موقوفة؛ فاتورة بيع جديدة بلا ضريبة من أي جهاز، ولا مفتاح ضريبة في نافذة إعدادات البيع |
| ٦ | أخضر | مرتجع مورد جديد: مدين المورد بالأجور وضريبتها، ودائن 1320 و1400، ولا شيء على 1300 أو 2100 |

تمرّن الوكيل على الترحيلين على نسخة 6 أكتوبر (`ref_1006`): الترقية والتراجع وإعادة الترقية سليمة، بالأرقام أعلاه.

## على المالك خارج الشيفرة

- **الأرقام الضريبية:** تُدخل في شاشة المورد للشركات المسجّلة، وإلا بدأت فواتيرها «بلا ضريبة». لا أحد من الموردين العشرين له رقم اليوم. حسب الفواتير هي تقريبًا: بن شيهون (نواعم، سوبرات، بناجر)، وشركة طيبة، وجوهرة الرباط، والجوهرة الأنيقة، وشركة سما الذهب، وفورناين، وشركة مصاغ. يمكن إدخالها قبل الإصدار ٤.
- **رصيد 1320 السالب** (−72,960.02): مقصود، ويُحوَّل إلى الإيرادات بقيد (WAGE-INV-1).

## ما يبقى بعد هذا

1. ~~مفتاح «بلا ضريبة» في شاشتَي البيع~~ — قِيس: البيع بلا ضريبة منذ 1 مايو، مقصود؛ صار إعدادًا للشركة (الإصدار ٥، SALES-VAT-1).
2. ~~RETURN-WAGE-1~~ — المرتجع يعكس الشراء سطرًا بسطر (الإصدار ٦). يبقى تصحيح أرصدة المرتجعات الخمس القديمة على 1300 و2100 و1320 و1400: إصلاح بيانات.
3. محوّل الأرقام الثاني (`utils/arabic_number_formatter.dart`) لا يقرأ «٫».
4. PURCHASE-CASH-1: دفعات الشراء تُقارن بالالتزام النقدي لا بالإجمالي (كامن ما دام الدفع الجزئي مفعّلًا).
5. إدخال أصناف الشراء بجدول بدل نافذة لكل صنف.
