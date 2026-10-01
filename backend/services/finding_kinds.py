"""What each reconciliation finding means -- the one place that says it.

The jobs write findings by kind (services/books_invariants.py, the clearing
and safe-box schedulers); the screen «نتائج الفحص الليلي» shows them. The
screen does not invent what a kind means: GET /api/reconciliation/findings
carries, for each kind it returns, this title, explanation and rank.

rank: the standing risk first (the roadmap: «الخطر القائم أولًا») -- what is
wrong in the posted books now, then money that is not moving, then what is
distorted but not posted, then disagreements between two ledgers, then the
records of what a job wrote, and the retired alarm last.
tests/test_finding_kinds.py fails on a kind any job writes without an entry.
"""
from __future__ import annotations

from typing import Optional

KIND_INFO: dict = {
    'POSTED_ENTRY_OF_UNPOSTED_INVOICE': {
        'rank': 10,
        'title_ar': 'قيد مرحّل لفاتورة غير مرحّلة',
        'explanation_ar': 'قيد يُحتسب في كل الأرصدة والتقارير لفاتورة مرفوضة أو لم تُعتمد بعد — أي لعملية لم تحدث. '
                          'مثاله قيد الفاتورة المرفوضة 2821 الذي رحّله حفظ الإعدادات في 28 سبتمبر.',
    },
    'ORPHAN_POSTED_ENTRY': {
        'rank': 20,
        'title_ar': 'قيد مرحّل بلا مستند',
        'explanation_ar': 'قيد يُحتسب في الأرصدة ومستنده (فاتورة أو سند) لم يعد موجودًا، فلا يمكن عكسه من مستنده أبدًا.',
    },
    'OVERDUE_SETTLEMENT': {
        'rank': 30,
        'title_ar': 'تسوية بطاقات متأخرة',
        'explanation_ar': 'دفعات بطاقة حلّ موعد تسويتها حسب جدول وسيلة الدفع ولم تُسوَّ بعد المهلة: المال لم ينتقل من حساب المقاصة إلى البنك.',
    },
    'UNPOSTED_ENTRY_IN_LIMBO': {
        'rank': 40,
        'title_ar': 'قيد معلّق لمستند منتهٍ',
        'explanation_ar': 'قيد غير مرحّل وليس مسودة لمستند انتهى أمره (مرفوض أو محذوف أو مرحّل): بعض الأرصدة تحتسبه وبعضها لا.',
    },
    'GOLD_ATTRIBUTION_MISSING': {
        'rank': 50,
        'title_ar': 'ذهب مدفوع غير منسوب لفاتورة',
        'explanation_ar': 'سند سدّد ذهبًا لمورد دون أن يُنسب إلى الفاتورة التي يسددها، فرصيد المورد بالعيار لا يعرف ماذا سُدّد.',
    },
    'SAFEBOX_SUBLEDGER_DRIFT': {
        'rank': 60,
        'title_ar': 'كشف الخزينة يخالف دفترها',
        'explanation_ar': 'رصيد الخزينة من حركاتها يختلف عن رصيد حسابها في دفتر الأستاذ؛ أحدهما لا يعكس الواقع.',
    },
    'SAFEBOX_GOLD_DRIFT': {
        'rank': 65,
        'title_ar': 'ذهب الخزينة في حركاتها يخالف دفترها',
        'explanation_ar': 'وزن عيارٍ في خزينة ذهب من حركاتها يختلف عمّا رحّلته القيود على حسابها؛ كاتبٌ سجّل الذهب في أحدهما دون الآخر. '
                          'القيود اليدوية (كالرصيد الافتتاحي) لا تُحتسب في أيّ من الجانبين.',
    },
    'VOUCHER_ENTRY_UNPOSTED_ON_POSTED_INVOICE': {
        'rank': 70,
        'title_ar': 'قيد سند غير مرحّل لفاتورة مرحّلة',
        'explanation_ar': 'كانت مهمة تسوية الخزائن ترحّله بصمت؛ صارت تُبلّغ عنه فقط، ويبقى قرار ترحيله لك.',
    },
    'SAFEBOX_ROW_BACKFILLED': {
        'rank': 80,
        'title_ar': 'حركة خزينة أضافتها المهمة الليلية',
        'explanation_ar': 'سجلّ لما كتبته مهمة تسوية الخزائن في كشف الخزينة، ليكون ظاهرًا لا صامتًا. للمراجعة.',
    },
    'STALE_SETTLEMENT': {
        'rank': 90,
        'title_ar': 'إنذار التسويات القديم (متقاعد)',
        'explanation_ar': 'الإنذار القديم الذي كان يقيس الوقت منذ آخر تسوية؛ استُبدل بتسوية البطاقات المتأخرة في 29 سبتمبر وتبقى صفوفه سجلًّا.',
    },
}

_SUBJECTS = {
    'journal_entry': 'قيد رقم',
    'safe_box': 'خزينة رقم',
    'voucher': 'سند رقم',
    'payment_method': 'وسيلة دفع رقم',
    'invoice': 'فاتورة رقم',
}


def subject_label(subject_key: Optional[str]) -> str:
    """'journal_entry:6641' -> 'قيد رقم 6641'."""
    if not subject_key:
        return '—'
    kind, _, ident = subject_key.partition(':')
    prefix = _SUBJECTS.get(kind)
    ident, _, karat = ident.partition(':')        # 'safe_box:30:21k' -- a karat of a safe
    if prefix and ident and karat.endswith('k'):
        return f'{prefix} {ident} — عيار {karat[:-1]}'
    return f'{prefix} {ident}' if prefix and ident else subject_key
