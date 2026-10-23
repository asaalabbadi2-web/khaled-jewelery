"""
je_adapter.py
=============
طبقة التكيّف بين je_engine_v2 (Python نقي) وroutes.py (Flask/SQLAlchemy).

الوظائف:
  - apply_je_to_db()       — تحوّل JELine إلى create_dual_journal_entry
  - sale_je_for_invoice()   — يبني قيد البيع من متغيرات الفاتورة
  - purchase_je_for_invoice()       — يبني قيد الشراء من مورد
  - customer_purchase_je_for_invoice() — يبني قيد شراء من عميل
  - sale_return_je_for_invoice()    — يبني قيد مرتجع البيع
  - purchase_return_je_for_invoice() — يبني قيد مرتجع شراء من مورد
"""

from __future__ import annotations

from decimal import Decimal
from typing import Dict, Optional

from je_engine_v2 import (
    AccountMap,
    PartyAccounts,
    WeightByKarat,
    JournalEntry as EngineJE,
    build_sale_je,
    build_purchase_je,
    build_supplier_purchase_je,
    build_send_to_supplier_je,
    build_sale_return_je,
    build_purchase_return_je,
)


# ─────────────────────────────────────────────────────────────────────────────
# Helper
# ─────────────────────────────────────────────────────────────────────────────

def _d(v, default="0") -> Decimal:
    if v is None:
        return Decimal(default)
    try:
        return Decimal(str(v))
    except Exception:
        return Decimal(default)


def _weights_from_gold_by_karat(gold_by_karat: Dict) -> WeightByKarat:
    """يحوّل {karat_str: weight_float} → WeightByKarat."""
    return WeightByKarat.from_dict({
        str(k): v for k, v in (gold_by_karat or {}).items()
    })


# ─────────────────────────────────────────────────────────────────────────────
# AccountMap builders
# ─────────────────────────────────────────────────────────────────────────────

def _build_account_map(
    *,
    get_mapping_fn,           # get_account_id_for_mapping(op_type, key) from routes.py
    inventory_accounts: Dict,  # {karat_str: account_id}
    cash_account_id: int,      # حساب الذمم / الصندوق المستخدم في الفاتورة
    invoice_type: str,
    gold_type: str = "new",
) -> AccountMap:
    """
    يبني AccountMap من دوال الربط المحاسبي الموجودة في routes.py.
    القيم الغير مستخدمة في نوع الفاتورة تُرسل بـ 0 (مقبول لأن الـ engine لا يلمسها).
    """
    def _m(op, key):
        v = get_mapping_fn(op, key)
        return int(v) if v else 0

    # حسابات الإيراد والتكلفة
    if gold_type == 'scrap':
        sales_acc = _m('بيع', 'sales_gold_scrap') or _m('بيع', 'sales_gold_new') or _m('بيع', 'revenue')
    else:
        sales_acc = _m('بيع', 'sales_gold_new') or _m('بيع', 'revenue')

    purchases_acc = (
        _m('شراء', 'purchases')
        or _m('شراء', 'purchases_gold')
        or _m('شراء من عميل', 'purchases')
        or _m('شراء من عميل', 'purchases_gold')
    )
    mfg_wage_acc = (
        _m(invoice_type, 'manufacturing_wage')
        or _m('شراء', 'manufacturing_wage')
        or _m('بيع', 'manufacturing_wage')
        or purchases_acc
    )
    sales_returns_acc = (
        _m('مرتجع بيع', 'sales_returns')
        or _m('مرتجع بيع', 'revenue')
        or sales_acc
    )
    purchase_returns_acc = (
        _m('مرتجع شراء', 'purchase_returns')
        or _m('مرتجع شراء (مورد)', 'purchase_returns')
        or purchases_acc
    )
    vat_payable = _m('بيع', 'vat_payable') or None
    vat_receivable = (
        _m('شراء', 'vat_receivable')
        or _m('شراء من عميل', 'vat_receivable')
        or None
    )

    return AccountMap(
        purchases_account_id=purchases_acc or 0,
        sales_account_id=sales_acc or 0,
        manufacturing_wage_account_id=mfg_wage_acc or 0,
        sales_returns_account_id=sales_returns_acc or 0,
        purchase_returns_account_id=purchase_returns_acc or 0,
        inventory_account_18k=int(inventory_accounts.get('18') or 0),
        inventory_account_21k=int(inventory_accounts.get('21') or 0),
        inventory_account_22k=int(inventory_accounts.get('22') or 0),
        inventory_account_24k=int(inventory_accounts.get('24') or 0),
        cash_account_id=int(cash_account_id) if cash_account_id else 0,
        vat_payable_account_id=int(vat_payable) if vat_payable else None,
        vat_receivable_account_id=int(vat_receivable) if vat_receivable else None,
    )


def _build_party_accounts(account_obj) -> PartyAccounts:
    """
    يبني PartyAccounts من كائن Account (SQLAlchemy).
    الحساب الوزني = memo_account_id إن وُجد، وإلا نفس الحساب المالي.
    """
    fin_id = account_obj.id
    weight_id = getattr(account_obj, 'memo_account_id', None) or fin_id
    name = getattr(account_obj, 'name', '') or ''
    return PartyAccounts(
        financial_account_id=int(fin_id),
        weight_account_id=int(weight_id),
        party_name=str(name),
    )


# ─────────────────────────────────────────────────────────────────────────────
# DB Persistence
# ─────────────────────────────────────────────────────────────────────────────

def _resolve_weight_account_id(account_id: int) -> int:
    """
    يُعيد الحساب الوزني (transaction_type='gold') المناسب لتسجيل قيود الوزن.

    ترتيب الأولوية:
    1. إذا كان الحساب نفسه من نوع 'gold' → استخدمه مباشرة.
    2. إذا كان لديه memo_account_id يشير لحساب 'gold' → استخدم الـ memo.
    3. بحث عكسي: ابحث عن حساب 'gold' يشير إلى هذا الحساب.
    4. fallback: أعد الحساب الأصلي.

    Note: نستخدم transaction_type='gold' وليس tracks_weight لأن بعض SafeBox
    accounts تحمل tracks_weight=True لكنها مالية (cash) وليست وزنية.
    """
    try:
        from models import Account as _Account  # noqa: local import
        acc = _Account.query.get(account_id)
        if acc:
            # Already a gold/weight account — use as-is.
            if (getattr(acc, 'transaction_type', 'cash') or 'cash').lower() == 'gold':
                return account_id

            # Forward link: memo_account_id pointing to a gold account.
            memo_id = getattr(acc, 'memo_account_id', None)
            if memo_id:
                memo_acc = _Account.query.get(int(memo_id))
                if memo_acc and (getattr(memo_acc, 'transaction_type', 'cash') or 'cash').lower() == 'gold':
                    return int(memo_id)

            # Reverse lookup: find a gold account that points to this one.
            reverse = (
                _Account.query
                .filter(_Account.memo_account_id == account_id)
                .filter_by(transaction_type='gold')
                .first()
            )
            if reverse:
                return int(reverse.id)
    except Exception:
        pass
    return account_id


def apply_je_to_db(
    engine_je: EngineJE,
    journal_entry_id: int,
    *,
    customer_id: Optional[int] = None,
    supplier_id: Optional[int] = None,
):
    """
    يكتب قيود je_engine_v2 إلى قاعدة البيانات عبر create_dual_journal_entry.
    يجب استدعاؤه داخل سياق Flask.
    """
    from dual_system_helpers import create_dual_journal_entry  # noqa: local import

    for line in engine_je.lines:
        if line.is_weight_account:
            # تحقق من كل القيم الوزنية — إذا كانت كلها صفراً تخطّ السطر
            w_vals = (
                float(line.weight_debit_18k), float(line.weight_credit_18k),
                float(line.weight_debit_21k), float(line.weight_credit_21k),
                float(line.weight_debit_22k), float(line.weight_credit_22k),
                float(line.weight_debit_24k), float(line.weight_credit_24k),
            )
            if all(v == 0.0 for v in w_vals):
                continue

            resolved_id = _resolve_weight_account_id(line.account_id)
            create_dual_journal_entry(
                journal_entry_id=journal_entry_id,
                account_id=resolved_id,
                weight_18k_debit=float(line.weight_debit_18k),
                weight_18k_credit=float(line.weight_credit_18k),
                weight_21k_debit=float(line.weight_debit_21k),
                weight_21k_credit=float(line.weight_credit_21k),
                weight_22k_debit=float(line.weight_debit_22k),
                weight_22k_credit=float(line.weight_credit_22k),
                weight_24k_debit=float(line.weight_debit_24k),
                weight_24k_credit=float(line.weight_credit_24k),
                description=line.description,
                customer_id=customer_id,
                supplier_id=supplier_id,
                apply_golden_rule=False,  # je_engine_v2 ensures correctness already
            )
        else:
            create_dual_journal_entry(
                journal_entry_id=journal_entry_id,
                account_id=line.account_id,
                cash_debit=float(line.cash_debit),
                cash_credit=float(line.cash_credit),
                description=line.description,
                customer_id=customer_id,
                supplier_id=supplier_id,
                apply_golden_rule=False,
            )


# ─────────────────────────────────────────────────────────────────────────────
# Invoice-level builders  (called from add_invoice in routes.py)
# ─────────────────────────────────────────────────────────────────────────────

def sale_je_for_invoice(
    *,
    journal_entry_id: int,
    invoice_type: str,
    gold_type: str,
    get_mapping_fn,
    inventory_accounts: Dict,
    gold_by_karat: Dict,
    sales_account_id: int,
    vat_payable_account_id: Optional[int],
    ar_account_id: int,          # حساب الذمم (party_account.id)
    customer_account_obj,        # كائن Account للعميل
    total_cash: float,           # إجمالي الفاتورة (مع الضريبة)
    total_tax: float,            # قيمة الضريبة
    customer_id: Optional[int] = None,
    stones_sales_account_id: Optional[int] = None,
    stones_cash: float = 0.0,    # stones sold by their value (ADR-050 ت6ج), out of the sale
):
    """
    ينشئ قيد البيع الكامل ويحفظه في DB.

    الفكرة:
      cash_received = total_cash  →  المبلغ كله عبر حساب الذمم (AR)
      الخزائن تُعالَج في سندات القبض (Phase 1) المنشأة سابقاً.
    """
    accounts = _build_account_map(
        get_mapping_fn=get_mapping_fn,
        inventory_accounts=inventory_accounts,
        cash_account_id=ar_account_id,
        invoice_type=invoice_type,
        gold_type=gold_type,
    )
    # Override with precise values already resolved in routes.py
    accounts.sales_account_id = int(sales_account_id) if sales_account_id else accounts.sales_account_id
    if vat_payable_account_id:
        accounts.vat_payable_account_id = int(vat_payable_account_id)

    customer_party = _build_party_accounts(customer_account_obj)

    weights = _weights_from_gold_by_karat(gold_by_karat)
    sale_cash = _d(total_cash) - _d(total_tax)  # مبيعات بدون الضريبة
    vat = _d(total_tax)
    cash_received = _d(total_cash)              # كل المبلغ يذهب لحساب الذمم

    je = build_sale_je(
        accounts=accounts,
        customer=customer_party,
        sale_cash=sale_cash,
        vat=vat,
        weights=weights,
        cash_received=cash_received,
        description=f"بيع ذهب {'كسر' if gold_type == 'scrap' else 'جديد'}",
        stones_sales_account_id=stones_sales_account_id,
        stones_cash=_d(stones_cash),
    )

    apply_je_to_db(je, journal_entry_id, customer_id=customer_id)


def purchase_je_for_invoice(
    *,
    journal_entry_id: int,
    invoice_type: str,
    gold_type: str,
    get_mapping_fn,
    inventory_accounts: Dict,
    gold_by_karat: Dict,
    purchases_account_id: int,
    mfg_wage_account_id: Optional[int],
    vat_receivable_account_id: Optional[int],
    ar_account_id: int,          # حساب ذمم المورد / العميل البائع
    party_account_obj,
    gold_cash: float,            # قيمة الذهب (بدون ضريبة)
    wage_cash: float,
    vat_gold: float,
    vat_wage: float,
    cash_paid: float,            # ما دُفع فعلاً من الخزينة
    supplier_id: Optional[int] = None,
    customer_id: Optional[int] = None,
):
    """
    قيد شراء من عميل (شراء كسر أو جديد من عميل يبيع ذهبه).
    يُستخدَم لـ: 'شراء من عميل'
    """
    accounts = _build_account_map(
        get_mapping_fn=get_mapping_fn,
        inventory_accounts=inventory_accounts,
        cash_account_id=ar_account_id,
        invoice_type=invoice_type,
        gold_type=gold_type,
    )
    if purchases_account_id:
        accounts.purchases_account_id = int(purchases_account_id)
    if mfg_wage_account_id:
        accounts.manufacturing_wage_account_id = int(mfg_wage_account_id)
    if vat_receivable_account_id:
        accounts.vat_receivable_account_id = int(vat_receivable_account_id)

    party = _build_party_accounts(party_account_obj)

    weights = _weights_from_gold_by_karat(gold_by_karat)

    je = build_purchase_je(
        accounts=accounts,
        party=party,
        gold_cash=_d(gold_cash),
        wage_cash=_d(wage_cash),
        vat_gold=_d(vat_gold),
        vat_wage=_d(vat_wage),
        weights=weights,
        cash_paid=_d(cash_paid),
        description="شراء ذهب من عميل",
    )

    apply_je_to_db(je, journal_entry_id,
                   customer_id=customer_id, supplier_id=supplier_id)


def supplier_purchase_je_for_invoice(
    *,
    journal_entry_id: int,
    invoice_type: str,
    gold_type: str,
    get_mapping_fn,
    inventory_accounts: Dict,
    gold_by_karat: Dict,
    purchases_account_id: int,
    mfg_wage_account_id: Optional[int],
    vat_receivable_account_id: Optional[int],
    ar_account_id: int,
    supplier_account_obj,
    gold_cash: float,
    wage_cash: float,
    vat_gold: float,
    vat_wage: float,
    cash_paid_now: float = 0.0,
    supplier_id: Optional[int] = None,
):
    """
    قيد شراء من مورد ('شراء').
    """
    accounts = _build_account_map(
        get_mapping_fn=get_mapping_fn,
        inventory_accounts=inventory_accounts,
        cash_account_id=ar_account_id,
        invoice_type=invoice_type,
        gold_type=gold_type,
    )
    if purchases_account_id:
        accounts.purchases_account_id = int(purchases_account_id)
    if mfg_wage_account_id:
        accounts.manufacturing_wage_account_id = int(mfg_wage_account_id)
    if vat_receivable_account_id:
        accounts.vat_receivable_account_id = int(vat_receivable_account_id)

    supplier = _build_party_accounts(supplier_account_obj)

    weights = _weights_from_gold_by_karat(gold_by_karat)

    je = build_supplier_purchase_je(
        accounts=accounts,
        supplier=supplier,
        gold_cash=_d(gold_cash),
        wage_cash=_d(wage_cash),
        vat_gold=_d(vat_gold),
        vat_wage=_d(vat_wage),
        weights=weights,
        cash_paid_now=_d(cash_paid_now),
        description="شراء من مورد",
    )

    apply_je_to_db(je, journal_entry_id, supplier_id=supplier_id)


def sale_return_je_for_invoice(
    *,
    journal_entry_id: int,
    invoice_type: str,
    gold_type: str,
    get_mapping_fn,
    inventory_accounts: Dict,
    gold_by_karat: Dict,
    sales_returns_account_id: int,
    vat_payable_account_id: Optional[int],
    ar_account_id: int,
    customer_account_obj,
    return_cash: float,
    total_tax: float,
    cash_refunded: float,
    customer_id: Optional[int] = None,
):
    """
    قيد مرتجع بيع.
    """
    accounts = _build_account_map(
        get_mapping_fn=get_mapping_fn,
        inventory_accounts=inventory_accounts,
        cash_account_id=ar_account_id,
        invoice_type=invoice_type,
        gold_type=gold_type,
    )
    if sales_returns_account_id:
        accounts.sales_returns_account_id = int(sales_returns_account_id)
    if vat_payable_account_id:
        accounts.vat_payable_account_id = int(vat_payable_account_id)

    customer = _build_party_accounts(customer_account_obj)
    weights = _weights_from_gold_by_karat(gold_by_karat)

    je = build_sale_return_je(
        accounts=accounts,
        customer=customer,
        return_cash=_d(return_cash) - _d(total_tax),
        vat=_d(total_tax),
        weights=weights,
        cash_refunded=_d(cash_refunded),
        description="مرتجع بيع",
    )

    apply_je_to_db(je, journal_entry_id, customer_id=customer_id)


def weight_entries_for_party(
    *,
    journal_entry_id: int,
    gold_by_karat: Dict,
    inventory_accounts: Dict,
    party_account_obj,
    direction: str,        # 'purchase'  → debit inventory, credit party
                           # 'sale'      → credit inventory, debit party
    customer_id: Optional[int] = None,
    supplier_id: Optional[int] = None,
    scrap_purchase_gold_safe_account_id: Optional[int] = None,
    party_weight_account_override: Optional[int] = None,
):
    """
    يُنشئ قيود الوزن فقط (بدون نقد) لعملية شراء أو بيع.
    يُستخدم عندما تُعالَج القيود المالية بشكل منفصل في routes.py.

    purchase: مدين حسابات المخزون الوزنية + دائن حساب وزن الطرف
    sale:     دائن حسابات المخزون الوزنية + مدين حساب وزن الطرف
    """
    from dual_system_helpers import create_dual_journal_entry  # noqa

    party = _build_party_accounts(party_account_obj)
    weights = _weights_from_gold_by_karat(gold_by_karat)

    is_purchase = direction == 'purchase'
    debit_side = 'debit' if is_purchase else 'credit'
    credit_side = 'credit' if is_purchase else 'debit'

    # Inventory weight entries (one line per karat)
    for karat, weight in weights.as_dict().items():
        karat_str = str(karat)
        if weight <= 0:
            continue
        # For scrap purchases, use the gold safe account if specified.
        # Always resolve to memo/weight account in case the safe is linked to a financial account.
        if is_purchase and scrap_purchase_gold_safe_account_id:
            inv_acc_id = _resolve_weight_account_id(int(scrap_purchase_gold_safe_account_id))
        else:
            raw_inv_id = int(inventory_accounts.get(karat_str) or 0)
            inv_acc_id = _resolve_weight_account_id(raw_inv_id) if raw_inv_id else 0
        if not inv_acc_id:
            continue
        kw = {f'weight_{karat}k_{debit_side}': float(weight)}
        create_dual_journal_entry(
            journal_entry_id=journal_entry_id,
            account_id=inv_acc_id,
            **kw,
            description=f"{'دخول' if is_purchase else 'خروج'} مخزون وزني عيار {karat}",
            customer_id=customer_id,
            supplier_id=supplier_id,
            apply_golden_rule=False,
        )

    # Party weight account — use override when provided (e.g. purchases weight 7511/7512)
    _party_weight_acc = party_weight_account_override or party.weight_account_id
    if _party_weight_acc:
        for karat, weight in weights.as_dict().items():
            if weight <= 0:
                continue
            kw = {f'weight_{karat}k_{credit_side}': float(weight)}
            create_dual_journal_entry(
                journal_entry_id=journal_entry_id,
                account_id=_party_weight_acc,
                **kw,
                description=f"وزن {'من' if is_purchase else 'إلى'} الطرف [{party.party_name}] عيار {karat}",
                customer_id=customer_id,
                supplier_id=supplier_id,
                apply_golden_rule=False,
            )


def purchase_return_je_for_invoice(
    *,
    journal_entry_id: int,
    invoice_type: str,
    gold_type: str,
    get_mapping_fn,
    inventory_accounts: Dict,
    gold_by_karat: Dict,
    purchase_returns_account_id: int,
    vat_receivable_account_id: Optional[int],
    ar_account_id: int,
    supplier_account_obj,
    return_cash: float,
    total_tax: float,
    cash_received_back: float = 0.0,
    supplier_id: Optional[int] = None,
):
    """
    قيد مرتجع شراء من مورد.
    """
    accounts = _build_account_map(
        get_mapping_fn=get_mapping_fn,
        inventory_accounts=inventory_accounts,
        cash_account_id=ar_account_id,
        invoice_type=invoice_type,
        gold_type=gold_type,
    )
    if purchase_returns_account_id:
        accounts.purchase_returns_account_id = int(purchase_returns_account_id)
    if vat_receivable_account_id:
        accounts.vat_receivable_account_id = int(vat_receivable_account_id)

    supplier = _build_party_accounts(supplier_account_obj)
    weights = _weights_from_gold_by_karat(gold_by_karat)

    je = build_purchase_return_je(
        accounts=accounts,
        supplier=supplier,
        return_cash=_d(return_cash) - _d(total_tax),
        vat=_d(total_tax),
        weights=weights,
        cash_received_back=_d(cash_received_back),
        description="مرتجع شراء من مورد",
    )

    apply_je_to_db(je, journal_entry_id, supplier_id=supplier_id)


def send_to_supplier_je(
    *,
    journal_entry_id: int,
    supplier_account_obj,          # كائن Account للمورد (المالي / الوزني)
    gold_by_karat: Dict,           # {karat_str: weight_float}
    inventory_account_id: int,     # حساب المخزون الوزني المصدر
    supplier_id: Optional[int] = None,
):
    """
    قيد إرسال ذهب للمورد (للتصنيع):
      مدين: مورد وزني   [72200-x]   grams
      دائن: مخزون وزني  [71310/...]  grams
    وزني بحت — لا ريال.
    """
    supplier = _build_party_accounts(supplier_account_obj)
    weights = _weights_from_gold_by_karat(gold_by_karat)

    je = build_send_to_supplier_je(
        supplier=supplier,
        weights=weights,
        inventory_account_id=int(inventory_account_id),
        description="إرسال ذهب للمصنع",
    )

    apply_je_to_db(je, journal_entry_id, supplier_id=supplier_id)
