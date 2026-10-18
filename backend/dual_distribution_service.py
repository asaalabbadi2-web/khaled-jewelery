"""dual_distribution_service.py
================================
محرك التوزيع المركزي الوحيد لتوجيه القيم النقدية والوزنية إلى الحسابات الصحيحة.

المبدأ الذهبي (القاعدة 66 من المواصفات):
  نقدية → الحساب المالي
  وزن   → الحساب الوزني (7xxx)

يُستخدم هذا الملف في جميع مسارات القيود:
  - القيود اليدوية   (journals.py)
  - الفواتير         (dual_system_helpers.py → create_dual_journal_entry)
  - السندات          (dual_system_helpers.py → create_dual_journal_entry)

لا يجوز تكرار منطق التوزيع خارج هذا الملف.

بنية السطر (dict):
  {
    'account_id': int,
    'cash_debit': float, 'cash_credit': float,
    'debit_18k': float, 'credit_18k': float,
    'debit_21k': float, 'credit_21k': float,
    'debit_22k': float, 'credit_22k': float,
    'debit_24k': float, 'credit_24k': float,
    ...أي حقول أخرى يمررها المُستدعي (تُحفظ دون تعديل)
  }
"""

from __future__ import annotations

import logging

_log = logging.getLogger(__name__)

# ─── حقول القيم ───────────────────────────────────────────────────────────────
GOLD_FIELDS: tuple[str, ...] = (
    'debit_18k', 'credit_18k',
    'debit_21k', 'credit_21k',
    'debit_22k', 'credit_22k',
    'debit_24k', 'credit_24k',
)
CASH_FIELDS: tuple[str, ...] = ('cash_debit', 'cash_credit')
ALL_VALUE_FIELDS: tuple[str, ...] = GOLD_FIELDS + CASH_FIELDS


def _has_values(line: dict, fields: tuple[str, ...]) -> bool:
    return any(line.get(f, 0) for f in fields)


def _zero_fields(line: dict, fields: tuple[str, ...]) -> dict:
    """يُعيد نسخة من السطر مع تصفير الحقول المحددة (لا يُعدّل الأصل)."""
    result = dict(line)
    for f in fields:
        result[f] = 0
    return result


def distribute_line(line: dict) -> list[dict]:
    """توزيع سطر واحد على الحسابين الصحيحين.

    القواعد:
    - لا memo_account_id → إعادة [السطر] كما هو.
    - حساب نقدي (cash) + قيم وزنية + موازٍ وزني (gold):
        الأوزان → سطر جديد للحساب الوزني
        النقد   → يبقى في السطر الأصلي
        السطر الأصلي يُحذف إن أصبح فارغاً تماماً.
    - حساب وزني (gold) + قيم نقدية + موازٍ نقدي (cash):
        النقد   → سطر جديد للحساب النقدي
        الأوزان → تبقى في السطر الأصلي
        السطر الأصلي يُحذف إن أصبح فارغاً تماماً.
    - لا تضاعف أي قيمة — قبل التوزيع وبعده المجموع الكلي متطابق.
    - العيار محفوظ دائماً (لا دمج ولا تحويل).
    - حقول غير قيمية (description, customer_id, ...) تُنقل للسطر الأصلي فقط.

    Returns: list من 0..2 سطر.
    """
    from models import Account

    acc_id = line.get('account_id')
    if not acc_id:
        return [line]

    acc = Account.query.get(acc_id)
    if not acc or not acc.memo_account_id:
        return [line]

    memo_acc = Account.query.get(acc.memo_account_id)
    if not memo_acc:
        return [line]

    acc_type = (acc.transaction_type or '').lower()
    memo_type = (memo_acc.transaction_type or '').lower()

    has_gold = _has_values(line, GOLD_FIELDS)
    has_cash = _has_values(line, CASH_FIELDS)

    if acc_type == 'cash' and memo_type == 'gold' and has_gold:
        # الأوزان → الحساب الوزني الموازي
        gold_line = {'account_id': acc.memo_account_id}
        for f in GOLD_FIELDS:
            gold_line[f] = line.get(f, 0)
        for f in CASH_FIELDS:
            gold_line[f] = 0

        # الحساب النقدي الأصلي: أصفر الأوزان، يبقى فقط إن له نقد
        cash_line = _zero_fields(line, GOLD_FIELDS)
        output = []
        if _has_values(cash_line, ALL_VALUE_FIELDS):
            output.append(cash_line)
        output.append(gold_line)
        return output

    elif acc_type == 'gold' and memo_type == 'cash' and has_cash:
        # النقد → الحساب النقدي الموازي
        cash_line = {'account_id': acc.memo_account_id}
        for f in CASH_FIELDS:
            cash_line[f] = line.get(f, 0)
        for f in GOLD_FIELDS:
            cash_line[f] = 0

        # الحساب الوزني الأصلي: أصفر النقد، يبقى فقط إن له أوزان
        gold_line = _zero_fields(line, CASH_FIELDS)
        output = []
        if _has_values(gold_line, ALL_VALUE_FIELDS):
            output.append(gold_line)
        output.append(cash_line)
        return output

    # لا توزيع مطلوب
    return [line]


def distribute_lines(lines: list[dict]) -> list[dict]:
    """يطبّق distribute_line() على قائمة أسطر كاملة.

    يُوزَّع كل سطر ولو كان الموازي في القائمة: الحساب النقدي لا يحمل وزنًا
    (ولا الوزني نقدًا)، فلا «قرار صريح» يُحترم بإبقائه عليه. كان التوزيع يتوقّف
    حين يجد الموازي، فبقيت 1,677.171 غ عيار 21 من قيد المعايرة JE-2026-06478 على
    الحساب النقدي 2100001 (17 أكتوبر 2026). Idempotent: السطر الموزَّع لا يبقى
    عليه ما يُنقل.
    """
    existing_ids: set[int] = {
        line['account_id'] for line in lines if line.get('account_id')
    }

    result: list[dict] = []
    extra: list[dict] = []

    for line in lines:
        acc_id = line.get('account_id')
        if not acc_id:
            result.append(line)
            continue

        from models import Account
        acc = Account.query.get(acc_id)
        # لا memo → لا توزيع
        if not acc or not acc.memo_account_id:
            result.append(line)
            continue

        distributed = distribute_line(line)

        for d in distributed:
            d_id = d.get('account_id')
            if d_id == acc_id:
                result.append(d)
            else:
                extra.append(d)
                existing_ids.add(d_id)

    return result + extra
