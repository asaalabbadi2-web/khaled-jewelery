"""
je_engine_v2.py
===============
محرك توليد القيود المحاسبية — النموذج النظيف v2

المبادئ الجوهرية:
- المخزون = جرام فقط، لا قيمة مالية داخل القيود
- المشتريات تستقبل الريال عند الشراء
- المبيعات تستقبل الريال عند البيع
- لا حسابات جسر (bridge)
- الموردون: حساب مالي (ريال) + حساب وزني (جرام) — مستقلان
- تكلفة البيع (COGS) في التقارير فقط، لا داخل القيود

هيكل الحسابات المطلوب:
────────────────────────────────────────────────────────────
النوع         | الرقم المقترح | الغرض
────────────────────────────────────────────────────────────
مشتريات ذهب  | 5100          | تكلفة الذهب المشترى (مالي)
مبيعات ذهب   | 4100          | إيراد الذهب المباع (مالي)
أجور مصنعية  | 5200          | تكلفة الأجور (مالي)
مخزون 21     | 71310         | وزن مخزون عيار 21 (وزني فقط)
مخزون 18     | 71300         | وزن مخزون عيار 18 (وزني فقط)
مخزون 22     | 71320         | وزن مخزون عيار 22 (وزني فقط)
مخزون 24     | 71330         | وزن مخزون عيار 24 (وزني فقط)
مورد مالي    | 2200-xxxx     | الالتزام النقدي للمورد (ريال)
مورد وزني    | 72200-xxxx    | الالتزام الوزني للمورد (جرام)
عميل مالي    | 1200-xxxx     | ذمة العميل (ريال)
────────────────────────────────────────────────────────────

كل دالة تُعيد قائمة من JELine (data class نقية) 
لا تتصل بقاعدة البيانات — قابلة للاختبار مستقلاً.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal, ROUND_HALF_UP
from typing import Dict, List, Optional


# ─────────────────────────────────────────────
# Data Structures
# ─────────────────────────────────────────────

SUPPORTED_KARATS = (18, 21, 22, 24)


@dataclass
class WeightByKarat:
    """وزن الذهب موزعاً على العيارات (جرام)."""
    k18: Decimal = Decimal("0")
    k21: Decimal = Decimal("0")
    k22: Decimal = Decimal("0")
    k24: Decimal = Decimal("0")

    @classmethod
    def from_dict(cls, d: Dict) -> "WeightByKarat":
        def _d(v) -> Decimal:
            if v is None:
                return Decimal("0")
            return Decimal(str(v)).quantize(Decimal("0.001"), rounding=ROUND_HALF_UP)
        return cls(
            k18=_d(d.get("18") or d.get("k18", 0)),
            k21=_d(d.get("21") or d.get("k21", 0)),
            k22=_d(d.get("22") or d.get("k22", 0)),
            k24=_d(d.get("24") or d.get("k24", 0)),
        )

    def total(self) -> Decimal:
        return self.k18 + self.k21 + self.k22 + self.k24

    def as_dict(self) -> Dict[int, Decimal]:
        return {18: self.k18, 21: self.k21, 22: self.k22, 24: self.k24}

    def is_empty(self) -> bool:
        return self.total() == Decimal("0")


@dataclass
class AccountRef:
    """مرجع حساب (id + نوع: مالي أو وزني)."""
    account_id: int
    is_weight: bool = False   # True = حساب وزني (memo), False = حساب مالي
    label: str = ""


@dataclass
class JELine:
    """
    سطر قيد محاسبي واحد.

    القاعدة:
    - حسابات مالية: تحمل cash_debit أو cash_credit فقط (weight = 0)
    - حسابات وزنية: تحمل weight_debit أو weight_credit فقط (cash = 0)
    - لا يجمع السطر الواحد نقداً ووزناً معاً
    """
    account_id: int
    is_weight_account: bool
    # قيم مالية (ريال)
    cash_debit: Decimal = Decimal("0")
    cash_credit: Decimal = Decimal("0")
    # قيم وزنية (جرام) — موزعة على العيارات
    weight_debit_18k: Decimal = Decimal("0")
    weight_debit_21k: Decimal = Decimal("0")
    weight_debit_22k: Decimal = Decimal("0")
    weight_debit_24k: Decimal = Decimal("0")
    weight_credit_18k: Decimal = Decimal("0")
    weight_credit_21k: Decimal = Decimal("0")
    weight_credit_22k: Decimal = Decimal("0")
    weight_credit_24k: Decimal = Decimal("0")
    description: str = ""

    # ─── validation ───
    def __post_init__(self):
        has_cash = self.cash_debit != 0 or self.cash_credit != 0
        has_weight = any([
            self.weight_debit_18k, self.weight_debit_21k,
            self.weight_debit_22k, self.weight_debit_24k,
            self.weight_credit_18k, self.weight_credit_21k,
            self.weight_credit_22k, self.weight_credit_24k,
        ])
        if has_cash and has_weight:
            raise ValueError(
                f"JELine للحساب {self.account_id}: لا يمكن دمج قيم مالية ووزنية في سطر واحد."
            )
        if has_cash and self.is_weight_account:
            raise ValueError(
                f"JELine للحساب {self.account_id}: الحساب وزني لكن السطر يحمل قيماً مالية."
            )
        if has_weight and not self.is_weight_account:
            raise ValueError(
                f"JELine للحساب {self.account_id}: الحساب مالي لكن السطر يحمل قيماً وزنية."
            )


@dataclass
class JournalEntry:
    """قيد محاسبي كامل — قائمة سطور مع التحقق من التوازن."""
    description: str
    lines: List[JELine] = field(default_factory=list)

    def add(self, line: JELine):
        self.lines.append(line)

    def cash_balance(self) -> Decimal:
        """يجب أن يساوي صفر في القيد المتوازن."""
        total_debit = sum(l.cash_debit for l in self.lines)
        total_credit = sum(l.cash_credit for l in self.lines)
        return total_debit - total_credit

    def weight_balance(self, karat: int) -> Decimal:
        """التوازن الوزني لعيار محدد — يجب أن يساوي صفر."""
        fd = f"weight_debit_{karat}k"
        fc = f"weight_credit_{karat}k"
        debit = sum(getattr(l, fd) for l in self.lines)
        credit = sum(getattr(l, fc) for l in self.lines)
        return debit - credit

    def is_balanced(self, tolerance: Decimal = Decimal("0.001")) -> bool:
        if abs(self.cash_balance()) > tolerance:
            return False
        for k in SUPPORTED_KARATS:
            if abs(self.weight_balance(k)) > tolerance:
                return False
        return True

    def assert_balanced(self):
        cb = self.cash_balance()
        if abs(cb) > Decimal("0.01"):
            raise AssertionError(
                f"القيد غير متوازن نقدياً: فارق = {cb} ريال\n{self._summary()}"
            )
        for k in SUPPORTED_KARATS:
            wb = self.weight_balance(k)
            if abs(wb) > Decimal("0.001"):
                raise AssertionError(
                    f"القيد غير متوازن وزنياً (عيار {k}): فارق = {wb} جرام\n{self._summary()}"
                )

    def _summary(self) -> str:
        lines = [f"  {'الحساب':<10} {'مدين نقد':>12} {'دائن نقد':>12} {'وصف'}"]
        for l in self.lines:
            lines.append(
                f"  {l.account_id:<10} {l.cash_debit:>12.2f} {l.cash_credit:>12.2f}  {l.description}"
            )
        return "\n".join(lines)


# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

def _d(v, default="0") -> Decimal:
    """تحويل آمن إلى Decimal."""
    if v is None:
        return Decimal(default)
    try:
        return Decimal(str(v))
    except Exception:
        return Decimal(default)


def _cash_debit(account_id: int, amount: Decimal, desc: str) -> JELine:
    return JELine(account_id=account_id, is_weight_account=False,
                  cash_debit=amount, description=desc)


def _cash_credit(account_id: int, amount: Decimal, desc: str) -> JELine:
    return JELine(account_id=account_id, is_weight_account=False,
                  cash_credit=amount, description=desc)


def _weight_debit(account_id: int, weights: WeightByKarat, desc: str) -> JELine:
    return JELine(
        account_id=account_id, is_weight_account=True,
        weight_debit_18k=weights.k18,
        weight_debit_21k=weights.k21,
        weight_debit_22k=weights.k22,
        weight_debit_24k=weights.k24,
        description=desc,
    )


def _weight_credit(account_id: int, weights: WeightByKarat, desc: str) -> JELine:
    return JELine(
        account_id=account_id, is_weight_account=True,
        weight_credit_18k=weights.k18,
        weight_credit_21k=weights.k21,
        weight_credit_22k=weights.k22,
        weight_credit_24k=weights.k24,
        description=desc,
    )


# ─────────────────────────────────────────────
# Account Map (يُمرَّر من الخارج — لا hardcoding)
# ─────────────────────────────────────────────

@dataclass
class AccountMap:
    """
    خريطة الحسابات المطلوبة لتوليد القيود.
    كل الحقول إلزامية ما لم يُشَر إلى عدم ذلك.
    """
    # ── حسابات الإيراد / التكلفة (مالية) ──
    purchases_account_id: int          # مشتريات ذهب (مدين عند الشراء)
    sales_account_id: int              # مبيعات ذهب (دائن عند البيع)
    manufacturing_wage_account_id: int  # أجور مصنعية (مدين)
    sales_returns_account_id: int      # مردودات مبيعات (مدين عند المرتجع)
    purchase_returns_account_id: int   # مردودات مشتريات (دائن عند مرتجع الشراء)

    # ── مخزون (وزني فقط، مفصول بالعيار) ──
    inventory_account_18k: int         # مخزون عيار 18 (وزني)
    inventory_account_21k: int         # مخزون عيار 21 (وزني)
    inventory_account_22k: int         # مخزون عيار 22 (وزني)
    inventory_account_24k: int         # مخزون عيار 24 (وزني)

    # ── خزائن (مالية) ──
    cash_account_id: int               # الصندوق / البنك

    # ── ضريبة (مالي، اختياري) ──
    vat_receivable_account_id: Optional[int] = None   # ضريبة شراء ذمم
    vat_payable_account_id: Optional[int] = None      # ضريبة بيع التزام

    def inventory_for_karat(self, karat: int) -> int:
        mapping = {
            18: self.inventory_account_18k,
            21: self.inventory_account_21k,
            22: self.inventory_account_22k,
            24: self.inventory_account_24k,
        }
        acc = mapping.get(karat)
        if not acc:
            raise ValueError(f"لا يوجد حساب مخزون وزني لعيار {karat}")
        return acc


# ─────────────────────────────────────────────
# مراجع الطرف (مورد / عميل)
# ─────────────────────────────────────────────

@dataclass
class PartyAccounts:
    """
    حسابات الطرف (مورد أو عميل).
    كل طرف له حسابان مستقلان تماماً:
    - مالي: يسجل الريال
    - وزني: يسجل الجرام
    """
    financial_account_id: int    # حساب مالي (ريال)
    weight_account_id: int       # حساب وزني (جرام) — memo
    party_name: str = ""


# ─────────────────────────────────────────────
# 1. شراء نقدي (من عميل أو سوق)
# ─────────────────────────────────────────────

def _require_vat(account_id, role):
    """A VAT amount is never dropped for want of its account (ADR-043 rule 4)."""
    if not account_id:
        raise ValueError(f'ضريبة بلا حساب مربوط ({role}): لا يُرحَّل القيد')


def build_purchase_je(
    *,
    accounts: AccountMap,
    party: PartyAccounts,              # البائع (العميل الذي يبيع ذهبه)
    gold_cash: Decimal,                # قيمة الذهب بالريال
    wage_cash: Decimal,                # أجور المصنعية بالريال
    vat_gold: Decimal,                 # ضريبة الذهب
    vat_wage: Decimal,                 # ضريبة الأجور
    weights: WeightByKarat,            # الأوزان الفعلية بالجرام
    cash_paid: Decimal,                # النقد المدفوع فعلاً من الخزينة
    description: str = "شراء ذهب",
) -> JournalEntry:
    """
    قيد شراء ذهب (من عميل / شراء نقدي):

        مدين: مشتريات ذهب          SAR (gold_cash)
        مدين: أجور مصنعية          SAR (wage_cash)
        مدين: ض.ق.م. مدفوعة       SAR (vat_gold + vat_wage) [إن وجدت]
        مدين: مخزون وزني (عيار X)  grams +  ← يدخل المخزون
        دائن: صندوق/بنك            SAR (cash_paid)
        دائن: [حساب مورد مالي]     SAR (المتبقي — إن لم يُدفع نقداً كاملاً)
        دائن: حساب وزني الطرف      grams -  ← يخرج الذهب من الطرف (سجل)
    """
    je = JournalEntry(description=description)

    total_cost = gold_cash + wage_cash + vat_gold + vat_wage
    total_cost = total_cost.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    cash_paid = cash_paid.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

    # ── مدين: التكاليف المالية ──
    if gold_cash > 0:
        je.add(_cash_debit(accounts.purchases_account_id, gold_cash, f"{description} - مشتريات ذهب"))
    if wage_cash > 0:
        je.add(_cash_debit(accounts.manufacturing_wage_account_id, wage_cash, f"{description} - أجور مصنعية"))
    if (vat_gold + vat_wage) > 0:
        _require_vat(accounts.vat_receivable_account_id, 'vat_receivable')
        je.add(_cash_debit(accounts.vat_receivable_account_id, vat_gold + vat_wage, f"{description} - ض.ق.م."))

    # ── مدين: مخزون وزني (جرام يدخل) ──
    for karat, weight in weights.as_dict().items():
        if weight > 0:
            inv_acc = accounts.inventory_for_karat(karat)
            w = WeightByKarat.from_dict({str(karat): weight})
            je.add(_weight_debit(inv_acc, w, f"{description} - مخزون عيار {karat}"))

    # ── دائن: خزينة (نقد يخرج) ──
    if cash_paid > 0:
        je.add(_cash_credit(accounts.cash_account_id, cash_paid, f"{description} - صرف نقدي"))

    # ── دائن: ذمة مالية للطرف (المتبقي غير المدفوع نقداً) ──
    remaining_payable = total_cost - cash_paid
    if remaining_payable > Decimal("0.01"):
        je.add(_cash_credit(party.financial_account_id, remaining_payable,
                            f"{description} - ذمة للطرف [{party.party_name}]"))
    elif remaining_payable < Decimal("-0.01"):
        # دفع أكثر من المستحق → مدين للطرف (دفعة مقدمة)
        je.add(_cash_debit(party.financial_account_id, -remaining_payable,
                           f"{description} - دفعة مقدمة للطرف [{party.party_name}]"))

    # ── دائن: حساب وزني الطرف (جرام يخرج من الطرف — سجل) ──
    if not weights.is_empty():
        je.add(_weight_credit(party.weight_account_id, weights,
                              f"{description} - ذهب خرج من [{party.party_name}]"))

    je.assert_balanced()
    return je


# ─────────────────────────────────────────────
# 2. شراء من مورد (Supplier Invoice)
# ─────────────────────────────────────────────

def build_supplier_purchase_je(
    *,
    accounts: AccountMap,
    supplier: PartyAccounts,
    gold_cash: Decimal,
    wage_cash: Decimal,
    vat_gold: Decimal,
    vat_wage: Decimal,
    weights: WeightByKarat,
    cash_paid_now: Decimal = Decimal("0"),  # ما دُفع فوراً عند إنشاء الفاتورة
    description: str = "شراء من مورد",
) -> JournalEntry:
    """
    قيد شراء من مورد:

        مدين: مشتريات ذهب              SAR (gold_cash + vat_gold)
        مدين: أجور مصنعية              SAR (wage_cash + vat_wage)
        مدين: مخزون وزني (عيار X)      grams +
        دائن: مورد مالي                SAR (الإجمالي - ما دُفع فوراً)
        دائن: صندوق                    SAR (cash_paid_now) [إن وجد]
        دائن: مورد وزني                grams (ما يستحقه المورد وزناً)
    """
    je = JournalEntry(description=description)

    total_financial = gold_cash + vat_gold + wage_cash + vat_wage
    total_financial = total_financial.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

    # ── مدين: مشتريات ──
    if gold_cash + vat_gold > 0:
        je.add(_cash_debit(accounts.purchases_account_id, gold_cash + vat_gold,
                           f"{description} - مشتريات ذهب + ض.ق.م."))
    if wage_cash + vat_wage > 0:
        je.add(_cash_debit(accounts.manufacturing_wage_account_id, wage_cash + vat_wage,
                           f"{description} - أجور مصنعية + ض.ق.م."))

    # ── مدين: مخزون وزني ──
    for karat, weight in weights.as_dict().items():
        if weight > 0:
            inv_acc = accounts.inventory_for_karat(karat)
            w = WeightByKarat.from_dict({str(karat): weight})
            je.add(_weight_debit(inv_acc, w, f"{description} - مخزون عيار {karat}"))

    # ── دائن: صندوق (ما دُفع فوراً) ──
    if cash_paid_now > 0:
        je.add(_cash_credit(accounts.cash_account_id, cash_paid_now,
                            f"{description} - دفعة فورية"))

    # ── دائن: مورد مالي (الباقي) ──
    supplier_financial_payable = total_financial - cash_paid_now
    if supplier_financial_payable > Decimal("0.01"):
        je.add(_cash_credit(supplier.financial_account_id, supplier_financial_payable,
                            f"{description} - ذمة للمورد [{supplier.party_name}]"))

    # ── دائن: مورد وزني ──
    if not weights.is_empty():
        je.add(_weight_credit(supplier.weight_account_id, weights,
                              f"{description} - ذهب للمورد وزناً [{supplier.party_name}]"))

    je.assert_balanced()
    return je


# ─────────────────────────────────────────────
# 2.5 إرسال ذهب للمورد (Send to Supplier / Manufacturing)
# ─────────────────────────────────────────────

def build_send_to_supplier_je(
    *,
    supplier: PartyAccounts,
    weights: WeightByKarat,          # الوزن المُرسَل للمورد
    inventory_account_id: int,       # حساب المخزون الوزني المصدر (عيار المُرسَل)
    description: str = "إرسال ذهب للمورد",
) -> JournalEntry:
    """
    قيد إرسال الذهب للمورد (للتصنيع أو المقايضة):

        مدين: مورد وزني  [72200-x]    grams +  ← الجسر يُشحن (المورد مدين بالوزن)
        دائن: مخزون وزني [71310/...]   grams -  ← الذهب يغادر مخزوننا

    قيد وزني بحت — لا قيود مالية.
    يُسوَّى لاحقاً عبر build_supplier_purchase_je عند استلام المصنوعات.
    """
    je = JournalEntry(description=description)

    if weights.is_empty():
        raise ValueError("لا يمكن إنشاء قيد إرسال بدون أوزان")

    # ── مدين: مورد وزني (الجسر يُشحن) ──
    je.add(_weight_debit(supplier.weight_account_id, weights,
                         f"{description} - ذهب يُرسل للمورد [{supplier.party_name}]"))

    # ── دائن: مخزون وزني (يغادر المخزون) ──
    je.add(_weight_credit(inventory_account_id, weights,
                          f"{description} - ذهب يخرج من المخزون للمورد"))

    je.assert_balanced()
    return je


# ─────────────────────────────────────────────
# 3. بيع
# ─────────────────────────────────────────────

def build_sale_je(
    *,
    accounts: AccountMap,
    customer: PartyAccounts,
    sale_cash: Decimal,              # سعر البيع بالريال
    vat: Decimal,                    # ضريبة القيمة المضافة
    weights: WeightByKarat,          # الأوزان المباعة
    cash_received: Decimal,          # النقد المستلم فعلاً
    description: str = "بيع ذهب",
) -> JournalEntry:
    """
    قيد بيع ذهب:

        مدين: صندوق/بنك              SAR (cash_received)
        مدين: عميل مالي              SAR (المتبقي غير المستلم — آجل)
        دائن: مبيعات ذهب             SAR (sale_cash)
        دائن: ض.ق.م. مستحقة         SAR (vat) [إن وجدت]
        دائن: مخزون وزني (عيار X)    grams - ← يخرج من المخزون
        مدين: عميل وزني              grams + ← سجل ما حصل عليه العميل
    """
    je = JournalEntry(description=description)

    total_receivable = sale_cash + vat
    total_receivable = total_receivable.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

    # ── مدين: صندوق (نقد مستلم) ──
    if cash_received > 0:
        je.add(_cash_debit(accounts.cash_account_id, cash_received,
                           f"{description} - استلام نقدي"))

    # ── مدين: ذمة عميل (الآجل) ──
    remaining_receivable = total_receivable - cash_received
    if remaining_receivable > Decimal("0.01"):
        je.add(_cash_debit(customer.financial_account_id, remaining_receivable,
                           f"{description} - ذمة على العميل [{customer.party_name}]"))
    elif remaining_receivable < Decimal("-0.01"):
        # استلام أكثر → دائن للعميل
        je.add(_cash_credit(customer.financial_account_id, -remaining_receivable,
                            f"{description} - رصيد زائد للعميل [{customer.party_name}]"))

    # ── دائن: مبيعات ──
    je.add(_cash_credit(accounts.sales_account_id, sale_cash, f"{description} - إيراد مبيعات"))

    # ── دائن: ض.ق.م. ──
    if vat > 0:
        _require_vat(accounts.vat_payable_account_id, 'vat_payable')
        je.add(_cash_credit(accounts.vat_payable_account_id, vat, f"{description} - ض.ق.م."))

    # ── دائن: مخزون وزني (جرام يخرج) ──
    for karat, weight in weights.as_dict().items():
        if weight > 0:
            inv_acc = accounts.inventory_for_karat(karat)
            w = WeightByKarat.from_dict({str(karat): weight})
            je.add(_weight_credit(inv_acc, w, f"{description} - مخزون عيار {karat} يخرج"))

    # ── مدين: عميل وزني (ذهب تم تسليمه للعميل) ──
    if not weights.is_empty():
        je.add(_weight_debit(customer.weight_account_id, weights,
                             f"{description} - ذهب مُسلَّم للعميل [{customer.party_name}]"))

    je.assert_balanced()
    return je


# ─────────────────────────────────────────────
# 4. مرتجع بيع
# ─────────────────────────────────────────────

def build_sale_return_je(
    *,
    accounts: AccountMap,
    customer: PartyAccounts,
    return_cash: Decimal,
    vat: Decimal,
    weights: WeightByKarat,
    cash_refunded: Decimal,
    description: str = "مرتجع بيع",
) -> JournalEntry:
    """
    قيد مرتجع بيع — عكس قيد البيع:

        مدين: مردودات مبيعات         SAR
        مدين: ض.ق.م. مستحقة         SAR (عكس)
        مدين: مخزون وزني             grams + (يعود للمخزون)
        دائن: صندوق                  SAR (cash_refunded)
        دائن: عميل مالي              SAR (المتبقي)
        دائن: عميل وزني              grams - (يُعاد للمخزون)
    """
    je = JournalEntry(description=description)

    total_return = return_cash + vat
    total_return = total_return.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

    # ── مدين: مردودات مبيعات ──
    je.add(_cash_debit(accounts.sales_returns_account_id, return_cash,
                       f"{description} - مردودات مبيعات"))
    if vat > 0:
        _require_vat(accounts.vat_payable_account_id, 'vat_payable')
        je.add(_cash_debit(accounts.vat_payable_account_id, vat,
                           f"{description} - عكس ض.ق.م."))

    # ── مدين: مخزون وزني (يعود) ──
    for karat, weight in weights.as_dict().items():
        if weight > 0:
            inv_acc = accounts.inventory_for_karat(karat)
            w = WeightByKarat.from_dict({str(karat): weight})
            je.add(_weight_debit(inv_acc, w, f"{description} - مخزون عيار {karat} يعود"))

    # ── دائن: صندوق (استرداد نقدي) ──
    if cash_refunded > 0:
        je.add(_cash_credit(accounts.cash_account_id, cash_refunded,
                            f"{description} - رد نقدي للعميل"))

    # ── دائن: ذمة عميل (المتبقي كرصيد له) ──
    remaining = total_return - cash_refunded
    if remaining > Decimal("0.01"):
        je.add(_cash_credit(customer.financial_account_id, remaining,
                            f"{description} - رصيد للعميل [{customer.party_name}]"))

    # ── دائن: عميل وزني (عكس الذهب المُسلّم للعميل) ──
    if not weights.is_empty():
        je.add(_weight_credit(customer.weight_account_id, weights,
                              f"{description} - عكس ذهب العميل [{customer.party_name}]"))

    je.assert_balanced()
    return je


# ─────────────────────────────────────────────
# 5. مرتجع شراء من مورد
# ─────────────────────────────────────────────

def build_purchase_return_je(
    *,
    accounts: AccountMap,
    supplier: PartyAccounts,
    return_cash: Decimal,
    vat: Decimal,
    weights: WeightByKarat,
    cash_received_back: Decimal = Decimal("0"),
    description: str = "مرتجع شراء مورد",
) -> JournalEntry:
    """
    قيد مرتجع شراء من مورد — عكس قيد الشراء:

        مدين: مورد مالي              SAR (تقليص الالتزام)
        مدين: مورد وزني              grams (يخرج اليزام الوزني)
        دائن: مردودات مشتريات        SAR
        دائن: مخزون وزني             grams - (يخرج من المخزون)
        دائن: صندوق                  SAR (cash_received_back)
    """
    je = JournalEntry(description=description)

    total_return = return_cash + vat
    total_return = total_return.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)

    # ── مدين: مورد مالي (صافي التقليص بعد طرح ما استُرد نقداً) ──
    payable_reduction = total_return - cash_received_back
    if payable_reduction > Decimal("0.01"):
        je.add(_cash_debit(supplier.financial_account_id, payable_reduction,
                           f"{description} - تقليص ذمة المورد [{supplier.party_name}]"))

    # ── مدين: صندوق (نقد يدخل إلينا من المورد) ──
    if cash_received_back > Decimal("0.01"):
        je.add(_cash_debit(accounts.cash_account_id, cash_received_back,
                           f"{description} - استرداد نقدي من المورد"))

    # ── مدين: مورد وزني (يخرج الالتزام الوزني) ──
    if not weights.is_empty():
        je.add(_weight_debit(supplier.weight_account_id, weights,
                             f"{description} - تقليص وزن المورد [{supplier.party_name}]"))

    # ── دائن: مردودات مشتريات ──
    je.add(_cash_credit(accounts.purchase_returns_account_id, return_cash,
                        f"{description} - مردودات مشتريات"))
    if vat > 0:
        _require_vat(accounts.vat_receivable_account_id, 'vat_receivable')
        je.add(_cash_credit(accounts.vat_receivable_account_id, vat,
                            f"{description} - عكس ض.ق.م."))

    # ── دائن: مخزون وزني (يخرج من المخزون) ──
    for karat, weight in weights.as_dict().items():
        if weight > 0:
            inv_acc = accounts.inventory_for_karat(karat)
            w = WeightByKarat.from_dict({str(karat): weight})
            je.add(_weight_credit(inv_acc, w, f"{description} - مخزون عيار {karat} يخرج"))

    je.assert_balanced()
    return je


# ─────────────────────────────────────────────
# 6. سداد مورد بذهب (Gold Settlement)
# ─────────────────────────────────────────────

def build_gold_settlement_je(
    *,
    accounts: AccountMap,
    supplier: PartyAccounts,
    weights: WeightByKarat,          # الوزن المُسدَّد (يخرج من خزينتنا للمورد)
    cash_equivalent: Decimal,        # القيمة النقدية المكافئة (لتسوية الذمة المالية)
    gold_safe_weight_account_id: int,  # الحساب الوزني للخزينة الذهبية
    description: str = "سداد مورد بذهب",
) -> JournalEntry:
    """
    سداد الالتزام للمورد بالذهب:

        مدين: مورد مالي              SAR (تقليص الذمة المالية بالقيمة المكافئة)
        مدين: مورد وزني              grams (تقليص الالتزام الوزني)
        دائن: خزينة ذهبية (وزني)     grams (يخرج الذهب من خزيننا)
        دائن: مشتريات / فروق أسعار   SAR (إغلاق الفارق بين سعر الشراء والتسوية)

    ملاحظة: cash_equivalent مشتق من: وزن × سعر السوق الحالي
    """
    je = JournalEntry(description=description)

    # ── مدين: تقليص التزام المورد (مالي) ──
    je.add(_cash_debit(supplier.financial_account_id, cash_equivalent,
                       f"{description} - تقليص ذمة المورد مالياً [{supplier.party_name}]"))

    # ── مدين: تقليص التزام المورد (وزني) ──
    je.add(_weight_debit(supplier.weight_account_id, weights,
                         f"{description} - تقليص ذهب المورد [{supplier.party_name}]"))

    # ── دائن: خزينة ذهبية (يخرج الذهب) ──
    je.add(_weight_credit(gold_safe_weight_account_id, weights,
                          f"{description} - ذهب يخرج من خزيننا"))

    # ── دائن: حساب مالي مقابل (يغلق الفارق) ──
    je.add(_cash_credit(accounts.purchases_account_id, cash_equivalent,
                        f"{description} - تسوية قيمة الذهب المُسدَّد"))

    je.assert_balanced()
    return je
