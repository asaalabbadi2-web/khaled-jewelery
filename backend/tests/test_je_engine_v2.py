"""
tests/test_je_engine_v2.py
===========================
اختبارات محرك القيود v2 — تعمل بدون Flask أو قاعدة بيانات
تشغيل: pytest tests/test_je_engine_v2.py -v
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from decimal import Decimal
import pytest

from je_engine_v2 import (
    AccountMap,
    PartyAccounts,
    WeightByKarat,
    JELine,
    build_purchase_je,
    build_supplier_purchase_je,
    build_send_to_supplier_je,
    build_sale_je,
    build_sale_return_je,
    build_purchase_return_je,
    build_gold_settlement_je,
)


# ─────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────

@pytest.fixture
def accounts():
    return AccountMap(
        purchases_account_id=5100,
        sales_account_id=4100,
        manufacturing_wage_account_id=5200,
        sales_returns_account_id=4200,
        purchase_returns_account_id=5300,
        inventory_account_18k=71300,
        inventory_account_21k=71310,
        inventory_account_22k=71320,
        inventory_account_24k=71330,
        cash_account_id=1100,
        vat_receivable_account_id=1500,
        vat_payable_account_id=2500,
        sold_weight_account_id=75210,
    )


@pytest.fixture
def supplier():
    return PartyAccounts(
        financial_account_id=22001,
        weight_account_id=72001,
        party_name="مورد الذهب",
    )


@pytest.fixture
def customer():
    return PartyAccounts(
        financial_account_id=12001,
        weight_account_id=72100,
        party_name="عميل",
    )


@pytest.fixture
def weights_21():
    return WeightByKarat.from_dict({"21": "10.500"})


@pytest.fixture
def weights_multi():
    return WeightByKarat.from_dict({"21": "8.000", "18": "3.500"})


# ─────────────────────────────────────────────
# Tests: WeightByKarat
# ─────────────────────────────────────────────

class TestWeightByKarat:
    def test_from_dict_basic(self):
        w = WeightByKarat.from_dict({"21": "10.5", "18": "3.2"})
        assert w.k21 == Decimal("10.500")
        assert w.k18 == Decimal("3.200")
        assert w.k22 == Decimal("0")

    def test_total(self):
        w = WeightByKarat.from_dict({"21": "10", "18": "5"})
        assert w.total() == Decimal("15")

    def test_is_empty(self):
        assert WeightByKarat().is_empty()
        assert not WeightByKarat.from_dict({"21": "1"}).is_empty()


# ─────────────────────────────────────────────
# Tests: JELine validation
# ─────────────────────────────────────────────

class TestJELineValidation:
    def test_cannot_mix_cash_and_weight(self):
        with pytest.raises(ValueError, match="لا يمكن دمج"):
            JELine(
                account_id=71310,
                is_weight_account=True,
                cash_debit=Decimal("100"),
                weight_debit_21k=Decimal("5"),
            )

    def test_cash_on_weight_account_rejected(self):
        with pytest.raises(ValueError, match="الحساب وزني"):
            JELine(
                account_id=71310,
                is_weight_account=True,
                cash_debit=Decimal("100"),
            )

    def test_weight_on_financial_account_rejected(self):
        with pytest.raises(ValueError, match="الحساب مالي"):
            JELine(
                account_id=5100,
                is_weight_account=False,
                weight_debit_21k=Decimal("5"),
            )

    def test_valid_cash_line(self):
        line = JELine(account_id=5100, is_weight_account=False,
                      cash_debit=Decimal("1000"))
        assert line.cash_debit == Decimal("1000")

    def test_valid_weight_line(self):
        line = JELine(account_id=71310, is_weight_account=True,
                      weight_debit_21k=Decimal("5.5"))
        assert line.weight_debit_21k == Decimal("5.5")


# ─────────────────────────────────────────────
# Tests: شراء نقدي
# ─────────────────────────────────────────────

class TestPurchaseJE:
    def test_cash_purchase_balanced(self, accounts, customer, weights_21):
        je = build_purchase_je(
            accounts=accounts,
            party=customer,
            gold_cash=Decimal("5000"),
            wage_cash=Decimal("200"),
            vat_gold=Decimal("250"),
            vat_wage=Decimal("10"),
            weights=weights_21,
            cash_paid=Decimal("5460"),
        )
        assert je.is_balanced(), f"غير متوازن: نقد={je.cash_balance()}"

    def test_purchase_with_deferred_payment(self, accounts, customer, weights_21):
        """دفع جزئي — الباقي ذمة على الطرف"""
        je = build_purchase_je(
            accounts=accounts,
            party=customer,
            gold_cash=Decimal("5000"),
            wage_cash=Decimal("0"),
            vat_gold=Decimal("0"),
            vat_wage=Decimal("0"),
            weights=weights_21,
            cash_paid=Decimal("3000"),
        )
        assert je.is_balanced()
        # يجب أن يوجد سطر دائن لحساب الطرف المالي
        party_credit = [l for l in je.lines
                        if l.account_id == customer.financial_account_id and l.cash_credit > 0]
        assert len(party_credit) == 1
        assert party_credit[0].cash_credit == Decimal("2000")

    def test_purchase_weight_enters_inventory(self, accounts, customer, weights_21):
        """التحقق من دخول الوزن للمخزون"""
        je = build_purchase_je(
            accounts=accounts,
            party=customer,
            gold_cash=Decimal("5000"),
            wage_cash=Decimal("0"),
            vat_gold=Decimal("0"),
            vat_wage=Decimal("0"),
            weights=weights_21,
            cash_paid=Decimal("5000"),
        )
        inv_lines = [l for l in je.lines
                     if l.account_id == accounts.inventory_account_21k]
        assert len(inv_lines) == 1
        assert inv_lines[0].weight_debit_21k == Decimal("10.500")

    def test_purchase_multi_karat_balanced(self, accounts, customer, weights_multi):
        je = build_purchase_je(
            accounts=accounts,
            party=customer,
            gold_cash=Decimal("8000"),
            wage_cash=Decimal("300"),
            vat_gold=Decimal("400"),
            vat_wage=Decimal("15"),
            weights=weights_multi,
            cash_paid=Decimal("8715"),
        )
        assert je.is_balanced()

    def test_no_weight_on_financial_accounts(self, accounts, customer, weights_21):
        """التأكد من أن لا حساب مالي يحمل وزناً"""
        je = build_purchase_je(
            accounts=accounts,
            party=customer,
            gold_cash=Decimal("5000"),
            wage_cash=Decimal("0"),
            vat_gold=Decimal("0"),
            vat_wage=Decimal("0"),
            weights=weights_21,
            cash_paid=Decimal("5000"),
        )
        for line in je.lines:
            if not line.is_weight_account:
                assert line.weight_debit_21k == Decimal("0"), \
                    f"حساب مالي {line.account_id} يحمل وزناً!"


# ─────────────────────────────────────────────
# Tests: شراء من مورد
# ─────────────────────────────────────────────

class TestSupplierPurchaseJE:
    def test_supplier_purchase_balanced(self, accounts, supplier, weights_21):
        je = build_supplier_purchase_je(
            accounts=accounts,
            supplier=supplier,
            gold_cash=Decimal("10000"),
            wage_cash=Decimal("500"),
            vat_gold=Decimal("500"),
            vat_wage=Decimal("25"),
            weights=weights_21,
            cash_paid_now=Decimal("0"),
        )
        assert je.is_balanced()

    def test_supplier_purchase_with_partial_payment(self, accounts, supplier, weights_21):
        je = build_supplier_purchase_je(
            accounts=accounts,
            supplier=supplier,
            gold_cash=Decimal("10000"),
            wage_cash=Decimal("500"),
            vat_gold=Decimal("0"),
            vat_wage=Decimal("0"),
            weights=weights_21,
            cash_paid_now=Decimal("3000"),
        )
        assert je.is_balanced()

    def test_no_cash_on_inventory_accounts(self, accounts, supplier, weights_21):
        """المخزون لا يحمل ريالاً في النموذج الجديد"""
        je = build_supplier_purchase_je(
            accounts=accounts,
            supplier=supplier,
            gold_cash=Decimal("10000"),
            wage_cash=Decimal("0"),
            vat_gold=Decimal("0"),
            vat_wage=Decimal("0"),
            weights=weights_21,
        )
        inventory_ids = {
            accounts.inventory_account_18k,
            accounts.inventory_account_21k,
            accounts.inventory_account_22k,
            accounts.inventory_account_24k,
        }
        for line in je.lines:
            if line.account_id in inventory_ids:
                assert line.cash_debit == Decimal("0"), \
                    f"مخزون {line.account_id} يحمل ريالاً ({line.cash_debit})!"
                assert line.cash_credit == Decimal("0"), \
                    f"مخزون {line.account_id} يحمل ريالاً دائناً ({line.cash_credit})!"

    def test_supplier_weight_credit_recorded(self, accounts, supplier, weights_21):
        """الالتزام الوزني للمورد يُسجَّل"""
        je = build_supplier_purchase_je(
            accounts=accounts,
            supplier=supplier,
            gold_cash=Decimal("10000"),
            wage_cash=Decimal("0"),
            vat_gold=Decimal("0"),
            vat_wage=Decimal("0"),
            weights=weights_21,
        )
        supplier_weight_lines = [l for l in je.lines
                                  if l.account_id == supplier.weight_account_id]
        assert len(supplier_weight_lines) == 1
        assert supplier_weight_lines[0].weight_credit_21k == Decimal("10.500")


# ─────────────────────────────────────────────
# Tests: بيع
# ─────────────────────────────────────────────

class TestSaleJE:
    def test_sale_balanced(self, accounts, customer, weights_21):
        je = build_sale_je(
            accounts=accounts,
            customer=customer,
            sale_cash=Decimal("6000"),
            vat=Decimal("300"),
            weights=weights_21,
            cash_received=Decimal("6300"),
        )
        assert je.is_balanced()

    def test_sale_deferred(self, accounts, customer, weights_21):
        """بيع آجل جزئياً"""
        je = build_sale_je(
            accounts=accounts,
            customer=customer,
            sale_cash=Decimal("6000"),
            vat=Decimal("0"),
            weights=weights_21,
            cash_received=Decimal("3000"),
        )
        assert je.is_balanced()
        customer_debit = [l for l in je.lines
                          if l.account_id == customer.financial_account_id and l.cash_debit > 0]
        assert len(customer_debit) == 1
        assert customer_debit[0].cash_debit == Decimal("3000")

    def test_inventory_decreases_on_sale(self, accounts, customer, weights_21):
        je = build_sale_je(
            accounts=accounts,
            customer=customer,
            sale_cash=Decimal("6000"),
            vat=Decimal("0"),
            weights=weights_21,
            cash_received=Decimal("6000"),
        )
        inv_lines = [l for l in je.lines if l.account_id == accounts.inventory_account_21k]
        assert len(inv_lines) == 1
        assert inv_lines[0].weight_credit_21k == Decimal("10.500"), "المخزون لم يتقلص"

    def test_no_weight_on_financial_sale_accounts(self, accounts, customer, weights_21):
        je = build_sale_je(
            accounts=accounts,
            customer=customer,
            sale_cash=Decimal("6000"),
            vat=Decimal("0"),
            weights=weights_21,
            cash_received=Decimal("6000"),
        )
        for line in je.lines:
            if not line.is_weight_account:
                total_weight = (
                    line.weight_debit_18k + line.weight_debit_21k +
                    line.weight_debit_22k + line.weight_debit_24k +
                    line.weight_credit_18k + line.weight_credit_21k +
                    line.weight_credit_22k + line.weight_credit_24k
                )
                assert total_weight == Decimal("0"), \
                    f"حساب مالي {line.account_id} يحمل وزناً!"


# ─────────────────────────────────────────────
# Tests: مرتجع بيع
# ─────────────────────────────────────────────

class TestSaleReturnJE:
    def test_sale_return_balanced(self, accounts, customer, weights_21):
        je = build_sale_return_je(
            accounts=accounts,
            customer=customer,
            return_cash=Decimal("6000"),
            vat=Decimal("300"),
            weights=weights_21,
            cash_refunded=Decimal("6300"),
        )
        assert je.is_balanced()

    def test_inventory_returns_on_sale_return(self, accounts, customer, weights_21):
        je = build_sale_return_je(
            accounts=accounts,
            customer=customer,
            return_cash=Decimal("6000"),
            vat=Decimal("0"),
            weights=weights_21,
            cash_refunded=Decimal("6000"),
        )
        inv_lines = [l for l in je.lines if l.account_id == accounts.inventory_account_21k]
        assert len(inv_lines) == 1
        assert inv_lines[0].weight_debit_21k == Decimal("10.500"), "المخزون لم يُعَد"


# ─────────────────────────────────────────────
# Tests: مرتجع شراء مورد
# ─────────────────────────────────────────────

class TestPurchaseReturnJE:
    def test_purchase_return_balanced(self, accounts, supplier, weights_21):
        je = build_purchase_return_je(
            accounts=accounts,
            supplier=supplier,
            return_cash=Decimal("5000"),
            vat=Decimal("0"),
            weights=weights_21,
            cash_received_back=Decimal("0"),
        )
        assert je.is_balanced()

    def test_purchase_return_with_cash_back(self, accounts, supplier, weights_21):
        je = build_purchase_return_je(
            accounts=accounts,
            supplier=supplier,
            return_cash=Decimal("5000"),
            vat=Decimal("250"),
            weights=weights_21,
            cash_received_back=Decimal("2000"),
        )
        assert je.is_balanced()


# ─────────────────────────────────────────────
# Tests: إرسال ذهب للمورد
# ─────────────────────────────────────────────

class TestSendToSupplierJE:
    def test_balanced(self, supplier, weights_21):
        je = build_send_to_supplier_je(
            supplier=supplier,
            weights=weights_21,
            inventory_account_id=71310,
        )
        assert je.is_balanced()

    def test_weight_only_no_cash(self, supplier, weights_21):
        """القيد وزني بحت — لا يجب أن يحمل أي ريال."""
        je = build_send_to_supplier_je(
            supplier=supplier,
            weights=weights_21,
            inventory_account_id=71310,
        )
        for line in je.lines:
            assert line.cash_debit == 0, f"حساب {line.account_id} يحمل ريالاً مديناً"
            assert line.cash_credit == 0, f"حساب {line.account_id} يحمل ريالاً دائناً"

    def test_supplier_weight_debited(self, supplier, weights_21):
        """المورد الوزني يُشحن (مدين) بالوزن المُرسَل."""
        je = build_send_to_supplier_je(
            supplier=supplier,
            weights=weights_21,
            inventory_account_id=71310,
        )
        supplier_line = next(l for l in je.lines if l.account_id == supplier.weight_account_id)
        assert supplier_line.weight_debit_21k == weights_21.k21

    def test_inventory_weight_credited(self, supplier, weights_21):
        """المخزون الوزني يُخصم (دائن) بنفس الوزن."""
        je = build_send_to_supplier_je(
            supplier=supplier,
            weights=weights_21,
            inventory_account_id=71310,
        )
        inv_line = next(l for l in je.lines if l.account_id == 71310)
        assert inv_line.weight_credit_21k == weights_21.k21

    def test_empty_weights_raises(self, supplier):
        """أوزان فارغة يجب أن ترفع ValueError."""
        with pytest.raises(ValueError):
            build_send_to_supplier_je(
                supplier=supplier,
                weights=WeightByKarat(),
                inventory_account_id=71310,
            )


# ─────────────────────────────────────────────
# Tests: سداد مورد بذهب
# ─────────────────────────────────────────────

class TestGoldSettlementJE:
    def test_gold_settlement_balanced(self, accounts, supplier, weights_21):
        je = build_gold_settlement_je(
            accounts=accounts,
            supplier=supplier,
            weights=weights_21,
            cash_equivalent=Decimal("5250"),
            gold_safe_weight_account_id=79000,
        )
        assert je.is_balanced()


# ─────────────────────────────────────────────
# Tests: التحقق من المبدأ الأساسي
# ─────────────────────────────────────────────

class TestCoreInvariant:
    """
    المبدأ الأساسي: لا حساب مالي يحمل وزناً، لا حساب وزني يحمل ريالاً.
    """
    FINANCIAL_ACCOUNTS = {5100, 4100, 5200, 4200, 5300, 1100, 1500, 2500,
                          22001, 12001}
    WEIGHT_ACCOUNTS = {71300, 71310, 71320, 71330, 72001, 72100, 79000}

    def _get_all_jes(self, accounts, supplier, customer, weights_21, weights_multi):
        return [
            build_purchase_je(accounts=accounts, party=customer,
                               gold_cash=Decimal("5000"), wage_cash=Decimal("200"),
                               vat_gold=Decimal("250"), vat_wage=Decimal("10"),
                               weights=weights_21, cash_paid=Decimal("5460")),
            build_supplier_purchase_je(accounts=accounts, supplier=supplier,
                                        gold_cash=Decimal("10000"), wage_cash=Decimal("500"),
                                        vat_gold=Decimal("0"), vat_wage=Decimal("0"),
                                        weights=weights_21),
            build_sale_je(accounts=accounts, customer=customer,
                          sale_cash=Decimal("6000"), vat=Decimal("0"),
                          weights=weights_21, cash_received=Decimal("6000")),
            build_sale_return_je(accounts=accounts, customer=customer,
                                  return_cash=Decimal("6000"), vat=Decimal("0"),
                                  weights=weights_21, cash_refunded=Decimal("6000")),
            build_purchase_return_je(accounts=accounts, supplier=supplier,
                                      return_cash=Decimal("5000"), vat=Decimal("0"),
                                      weights=weights_21),
            build_gold_settlement_je(accounts=accounts, supplier=supplier,
                                      weights=weights_21, cash_equivalent=Decimal("5250"),
                                      gold_safe_weight_account_id=79000),
            build_send_to_supplier_je(supplier=supplier,
                                      weights=weights_21,
                                      inventory_account_id=71310),
        ]

    def test_all_jes_balanced(self, accounts, supplier, customer,
                               weights_21, weights_multi):
        for je in self._get_all_jes(accounts, supplier, customer,
                                    weights_21, weights_multi):
            assert je.is_balanced(), f"{je.description} غير متوازن"

    def test_no_weight_on_financial_accounts(self, accounts, supplier, customer,
                                              weights_21, weights_multi):
        for je in self._get_all_jes(accounts, supplier, customer,
                                    weights_21, weights_multi):
            for line in je.lines:
                if line.account_id in self.FINANCIAL_ACCOUNTS:
                    has_weight = any([
                        line.weight_debit_18k, line.weight_debit_21k,
                        line.weight_debit_22k, line.weight_debit_24k,
                        line.weight_credit_18k, line.weight_credit_21k,
                        line.weight_credit_22k, line.weight_credit_24k,
                    ])
                    assert not has_weight, \
                        f"قيد [{je.description}]: الحساب المالي {line.account_id} يحمل وزناً!"

    def test_no_cash_on_weight_accounts(self, accounts, supplier, customer,
                                         weights_21, weights_multi):
        for je in self._get_all_jes(accounts, supplier, customer,
                                    weights_21, weights_multi):
            for line in je.lines:
                if line.account_id in self.WEIGHT_ACCOUNTS:
                    assert line.cash_debit == Decimal("0"), \
                        f"قيد [{je.description}]: الحساب الوزني {line.account_id} يحمل ريالاً مديناً!"
                    assert line.cash_credit == Decimal("0"), \
                        f"قيد [{je.description}]: الحساب الوزني {line.account_id} يحمل ريالاً دائناً!"
