# ADR-078: ملف الموظف لا يكتب ما تملكه وثيقة أخرى، وتُضاف المسودة ولا تُعاد

**Status:** Accepted. قال المالك في 2 نوفمبر 2026: «اعتمد». وافق على مراجعة تجربة الموارد البشرية، وعلى قراريها: حذف «الراتب الأساسي» و«تاريخ الإنهاء» و«الحالة نشطة» من نافذة التعديل. هذه المرحلة ط1 من `docs/plans/hr-ux-redesign-2026-11.md`.
**Date:** 2026-11-02
**Sprint:** HR-UX ط1

---

## Policy or Law?

**Classification:** Law

| | |
|---|---|
| **Law** | ١. **راتب الموظف** يُكتب من هيكل راتبه وحده. إن وصل إلى ملفه راتب يختلف عمّا فيه، يُرفض الطلب كله (`salary_is_the_structure`). ٢. **تاريخ ترك العمل** يُكتب من تسوية نهاية الخدمة وحدها. إن وصل تاريخ يختلف عمّا في الملف، يُرفض (`termination_is_the_settlement`). ٣. **المسودة تُضاف إليها الأسطر ولا تُعاد:** الموظف الذي أُصلح وضعه بعد إنشائها يُضاف بقواعد الإنشاء نفسها، وتبقى الأسطر الأخرى كما رُوجعت. المسير المعتمد لا يُضاف إليه سطر. ٤. **تاريخ بدء الهيكل الجديد** يقترحه الخادم: الشهر الذي يلي آخر راتب معتمد للموظف، وإن لم يوجد راتب معتمد فتاريخ تعيينه، وإلا أول الشهر الجاري. |
| **Policy** | — |

---

## Context

**ما وُجد في الكود يوم 2 نوفمبر:**
- **«الراتب الأساسي» في نافذة التعديل:** كان يعرض `employee.salary`، وهو الإجمالي الذي يكتبه الهيكل (`_follow_in_the_file`). كان تعديله يُحفظ، لكن المسير لا يقرؤه، فيصبح للراتب رقمان.
- **«تاريخ الإنهاء» في النافذة نفسها:** كان يغيّر دخول الموظف المسير دون تسوية (ADR-076).
- **«يبدأ من» في الهيكل الجديد:** كان افتراضيه أول الشهر الجاري. يقرأ المسير الهيكل الساري في آخر يوم من شهره، فخرج الموظف من مسير أكتوبر.
- **«خارج المسير»:** إضافة هيكل لم تكن تُدخل الموظف المسودة. كان الحل الوحيد إلغاء المسودة، فتضيع إضافات الأسطر وخصوماتها.

## Decision

- **الخادم:**
  - `services/employee_access.refuse_owned_elsewhere` (القانونان 1 و2)، ويستدعيه مسارا إنشاء الموظف وتعديله.
  - `services/payroll_run.add_line` ومساره `POST /payroll/runs/<id>/lines` (القانون 3).
  - `services/payroll_policy.suggested_from`، ويعود في `GET /employees/<id>/salary-structures` باسم `suggested_from` (القانون 4).
- **الواجهة:**
  - خرج من نافذة التعديل الراتب وتاريخ الإنهاء ومفتاح الحالة، وصار تاريخ التعيين بحقل التاريخ (`DateField`).
  - صار «يبدأ من» من الخادم.
  - «أضف إلى المسودة» متاح من «خارج المسير»، وتُحدَّث المسودة بعد تعديل بيانات الراتب.
  - النافذة تُنبّه إلى ما لم يُحفظ قبل إغلاقها، ويُطلب تأكيد قبل حذف الهيكل.
  - قائمتا الخزائن صارتا `isExpanded`، لأن الاختبار كشف أنهما تتجاوزان عرض النافذة.

## Witnesses

كل شاهد شوهد أحمر على الكود السابق، ثم أخضر:

- `backend/tests/test_employee_access_and_audit.py::test_his_salary_and_his_leaving_date_are_not_written_by_his_file_s_edit`
- `backend/tests/test_payroll_run.py::test_one_put_right_is_added_to_the_draft_and_the_reviewed_lines_stay`
- `backend/tests/test_payroll_structures_and_policy.py::test_a_new_structure_is_offered_from_the_first_month_still_open_to_it`
- `frontend/test/employee_form_dialog_test.dart`
- `frontend/test/employee_payroll_dialog_test.dart`
- `frontend/test/payroll_run_journey_test.dart` (أضيفت إليه «أضف إلى المسودة»)
