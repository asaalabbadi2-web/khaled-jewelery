"""settlement_state_service.py
===============================
نقطة القراءة الوحيدة لـ"كم سُوِّي من هذه الدفعة فعلاً" -- يستبدل 10 نسخاً
متطابقة من `SUM(SettlementLine.amount_settled) GROUP BY invoice_payment_id`
كانت موزَّعة بين routes.py وclearing_settlement_scheduler.py (انظر
PAYMENT_LIFECYCLE_ARCHITECTURE.md لتفاصيل الاكتشاف الكامل).

تنبيه مهم -- استثناء واحد متعمَّد، غير موحَّد بعد (انظر التعليق الكامل
INTENTIONAL DIVERGENCE في routes.py حول السطر 31097):
  routes.py (عند إنشاء سند تسوية جديد، حادثة الإنتاج AV-2026-00133) يفلتر
  بشرط `Voucher.status == 'approved'` -- الموضع الوحيد من أصل 10 الذي يفعل
  ذلك. تحقّق إنتاجي (2026-06-30، diagnose_cancelled_settlement_impact.py)
  أثبت أن هذا فرق حقيقي وليس تكراراً تافهاً: سند تسوية مُلغى
  (cancel_voucher لا يحذف SettlementLine المرتبط به) يجعل الـ9 مواضع
  الأخرى تعتبر الدفعة "مسوّاة" للأبد رغم أن المال لم يتحرك -- أثر فعلي
  مؤكَّد: 9 دفعات، 27,820 ريال، عبر 4 سندات ملغاة على الإنتاج.

  ما تُرجعه هذه الدوال حالياً (get_settled_amounts/get_settled_amount) هو
  "Raw Settled Amount" -- مجموع كل SettlementLine بلا فلتر، مطابق تماماً
  لسلوك الـ9 مواضع قبل هذا الترحيل (لا تغيير وظيفي). "Effective Settled
  Amount" (مجموع السندات المعتمدة فقط -- ما يطابق الواقع الاقتصادي فعلياً
  حسب بيانات الإنتاج) **لا توجد بعد كدالة هنا**؛ قرار تعميمها على الـ10
  مواضع معلَّق، بانتظار حسم العمل مع المستخدم.

  تحديث 2026-07-01: الإصلاح الجذري نُفِّذ في cancel_voucher() -- تحذف الآن
  صفوف SettlementLine عند إلغاء سند تسوية مقاصة، فلا تنشأ بيانات أيتام
  جديدة. هذا يجعل get_settled_amounts() (بلا فلتر) مكافئاً فعلياً
  لـget_effective_settled_amounts() لأي إلغاء مستقبلي. الصفوف التاريخية
  الأيتام (AV-130/131/132 من مايو 2026) لا تزال موجودة في قاعدة البيانات
  وتحتاج تنظيفاً يدوياً منفصلاً -- بعده تبقى get_settled_amounts() وحدها
  كافية ولا حاجة لدالة get_effective variant.
"""

from __future__ import annotations

from sqlalchemy import func

from models import db, SettlementLine

SETTLEMENT_EPSILON = 0.005


def get_settled_amounts(invoice_payment_ids: list[int]) -> dict[int, float]:
    """إجمالي amount_settled لكل invoice_payment_id، عبر كل السندات بلا أي
    فلتر على حالتها (مطابق للسلوك الحالي في كل المواضع غير المستثناة أعلاه)."""
    ids = [i for i in (invoice_payment_ids or []) if i is not None]
    if not ids:
        return {}
    rows = (
        db.session.query(
            SettlementLine.invoice_payment_id,
            func.coalesce(func.sum(SettlementLine.amount_settled), 0.0),
        )
        .filter(SettlementLine.invoice_payment_id.in_(ids))
        .group_by(SettlementLine.invoice_payment_id)
        .all()
    )
    return {r[0]: float(r[1]) for r in rows}


def get_settled_amount(invoice_payment_id: int) -> float:
    """نسخة مفردة من get_settled_amounts لموضع واحد فقط."""
    return get_settled_amounts([invoice_payment_id]).get(invoice_payment_id, 0.0)


def is_locked(invoice_payment_id: int) -> bool:
    """True لو أي مبلغ من هذه الدفعة دخل تسوية فعلية (بغض النظر عن حالة
    السند -- مطابق لحارس routes.py:9266-9281 الحالي حرفياً)."""
    return get_settled_amount(invoice_payment_id) > SETTLEMENT_EPSILON


# ======================================================================
# A settled payment is put right through its settlement (31 Oct 2026)
# ======================================================================

def settlements_holding(voucher_id: int) -> list[str]:
    """The live settlement vouchers holding a payment *voucher_id* records, by
    number -- none for a voucher that is not a payment's, or whose payments'
    settlements were cancelled (their lines are removed then; the historical
    orphans of a cancelled settlement do not hold).

    The owner, 31 Oct 2026: «إلغاء سند التسوية أولًا ثم التصحيح، وليس سند
    الدفعة» -- cancelling a settled payment's voucher drove the 31 Oct copy's
    Mada to -7,200 and its cash customer into a debt he had paid."""
    from models import InvoicePayment, SafeBoxTransaction, Voucher
    payment_ids = {p.id for p in InvoicePayment.query.filter_by(source_voucher_id=voucher_id)}
    payment_ids |= {t.invoice_payment_id for t in SafeBoxTransaction.query.filter(
        SafeBoxTransaction.ref_type == 'invoice_payment', SafeBoxTransaction.ref_id == voucher_id,
        SafeBoxTransaction.invoice_payment_id.isnot(None))}
    if not payment_ids:
        return []
    rows = (db.session.query(Voucher.voucher_number)
            .join(SettlementLine, SettlementLine.voucher_id == Voucher.id)
            .filter(SettlementLine.invoice_payment_id.in_(payment_ids),
                    Voucher.status != 'cancelled')
            .distinct().order_by(Voucher.voucher_number).all())
    return [number for (number,) in rows]


def settled_payment_message(action: str, settlements: list[str]) -> str:
    """The one wording for "the payment is in a settlement", for every path."""
    held = '، '.join(settlements) if settlements else 'سند تسوية'
    return (f'لا يمكن {action} دفعة دخلت تسوية مع البنك ({held}). '
            'ألغِ سند التسوية أولًا، ثم صحّح، ثم تُسوّى من جديد.')
