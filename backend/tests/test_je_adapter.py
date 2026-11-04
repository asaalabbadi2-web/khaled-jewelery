"""
test_je_adapter.py
==================
اختبارات وحدة لـ je_adapter.py
التحقق من:
1. بناء AccountMap بشكل صحيح
2. بناء PartyAccounts من كائن Account
3. تحويل JELine → create_dual_journal_entry (mock)
4. sale_je_for_invoice يُنشئ القيود الصحيحة
"""

import pytest
from decimal import Decimal
from unittest.mock import MagicMock, patch, call

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from je_adapter import (
    _build_account_map,
    _build_party_accounts,
    apply_je_to_db,
    _weights_from_gold_by_karat,
    weight_entries_for_party,
)
from je_engine_v2 import WeightByKarat, JELine, JournalEntry as EngineJE


# ─────────────────────────────────────────────────────────────────────────────
# Fixtures / helpers
# ─────────────────────────────────────────────────────────────────────────────


def _mock_mapping(op_type, key, overrides=None):
    """
    دالة mock بديلة لـ get_account_id_for_mapping.
    """
    _defaults = {
        ('بيع', 'sales_gold_new'): 4100,
        ('بيع', 'sales_gold_scrap'): 4110,
        ('بيع', 'vat_payable'): 2400,
        ('بيع', 'manufacturing_wage'): 5200,
        ('مرتجع بيع', 'sales_returns'): 4200,
        ('شراء', 'purchases'): 5100,
        ('شراء', 'manufacturing_wage'): 5200,
        ('شراء', 'vat_receivable'): 1500,
        ('مرتجع شراء', 'purchase_returns'): 5300,
        ('افتراضي', 'gold_cost_of_sales_weight'): 75210,
    }
    d = {**_defaults, **(overrides or {})}
    return d.get((op_type, key))


def _make_account(
    account_id,
    name='حساب تجريبي',
    memo_account_id=None,
    tracks_weight=False,
    account_number='1200',
):
    acc = MagicMock()
    acc.id = account_id
    acc.name = name
    acc.memo_account_id = memo_account_id
    acc.tracks_weight = tracks_weight
    acc.account_number = account_number
    return acc


# ─────────────────────────────────────────────────────────────────────────────
# _weights_from_gold_by_karat
# ─────────────────────────────────────────────────────────────────────────────


class TestWeightsFromGoldByKarat:
    def test_basic_single_karat(self):
        w = _weights_from_gold_by_karat({'21': 10.5})
        assert w.k21 == Decimal('10.5')
        assert w.k18 == Decimal('0')

    def test_multi_karat(self):
        w = _weights_from_gold_by_karat({'18': 5.0, '21': 7.25, '22': 3.0, '24': 1.0})
        assert w.k18 == Decimal('5.0')
        assert w.k21 == Decimal('7.25')
        assert w.k22 == Decimal('3.0')
        assert w.k24 == Decimal('1.0')

    def test_empty_dict(self):
        w = _weights_from_gold_by_karat({})
        assert w.total() == Decimal('0')

    def test_none_dict(self):
        w = _weights_from_gold_by_karat(None)
        assert w.total() == Decimal('0')


# ─────────────────────────────────────────────────────────────────────────────
# _build_party_accounts
# ─────────────────────────────────────────────────────────────────────────────


class TestBuildPartyAccounts:
    def test_with_memo_account(self):
        acc = _make_account(100, name='عميل', memo_account_id=700)
        party = _build_party_accounts(acc)
        assert party.financial_account_id == 100
        assert party.weight_account_id == 700
        assert party.party_name == 'عميل'

    def test_without_memo_account(self):
        """يستخدم نفس الحساب المالي كحساب وزني"""
        acc = _make_account(200, name='مورد', memo_account_id=None)
        party = _build_party_accounts(acc)
        assert party.financial_account_id == 200
        assert party.weight_account_id == 200


# ─────────────────────────────────────────────────────────────────────────────
# _build_account_map
# ─────────────────────────────────────────────────────────────────────────────


class TestBuildAccountMap:
    def test_sale_map(self):
        inv_accounts = {'18': 71300, '21': 71310, '22': 71320, '24': 71330}
        am = _build_account_map(
            get_mapping_fn=_mock_mapping,
            inventory_accounts=inv_accounts,
            cash_account_id=1200,
            invoice_type='بيع',
            gold_type='new',
        )
        assert am.sales_account_id == 4100
        assert am.vat_payable_account_id == 2400
        assert am.inventory_account_21k == 71310
        assert am.cash_account_id == 1200

    def test_scrap_sale_map(self):
        am = _build_account_map(
            get_mapping_fn=_mock_mapping,
            inventory_accounts={'21': 71310},
            cash_account_id=1200,
            invoice_type='بيع',
            gold_type='scrap',
        )
        assert am.sales_account_id == 4110  # sales_gold_scrap

    def test_purchase_map(self):
        am = _build_account_map(
            get_mapping_fn=_mock_mapping,
            inventory_accounts={'21': 71310},
            cash_account_id=2200,
            invoice_type='شراء',
            gold_type='new',
        )
        assert am.purchases_account_id == 5100
        assert am.vat_receivable_account_id == 1500


# ─────────────────────────────────────────────────────────────────────────────
# apply_je_to_db
# ─────────────────────────────────────────────────────────────────────────────


class TestApplyJeToDb:
    def test_cash_debit_line(self):
        je = EngineJE(description='test')
        je.add(JELine(
            account_id=1200,
            is_weight_account=False,
            cash_debit=Decimal('1000'),
        ))

        with patch('dual_system_helpers.create_dual_journal_entry') as mock_cdje:
            apply_je_to_db(je, journal_entry_id=1, customer_id=5)

        mock_cdje.assert_called_once()
        kwargs = mock_cdje.call_args[1]
        assert kwargs['account_id'] == 1200
        assert kwargs['cash_debit'] == 1000.0
        assert kwargs['customer_id'] == 5
        assert kwargs['apply_golden_rule'] is False

    def test_weight_credit_line(self):
        je = EngineJE(description='test')
        je.add(JELine(
            account_id=71310,
            is_weight_account=True,
            weight_credit_21k=Decimal('10.5'),
        ))

        with patch('dual_system_helpers.create_dual_journal_entry') as mock_cdje:
            apply_je_to_db(je, journal_entry_id=2, supplier_id=7)

        mock_cdje.assert_called_once()
        kwargs = mock_cdje.call_args[1]
        assert kwargs['account_id'] == 71310
        assert kwargs['weight_21k_credit'] == 10.5
        assert kwargs['supplier_id'] == 7
        assert kwargs['apply_golden_rule'] is False


# ─────────────────────────────────────────────────────────────────────────────
# weight_entries_for_party
# ─────────────────────────────────────────────────────────────────────────────


class TestWeightEntriesForParty:
    def _run(self, direction):
        gold_by_karat = {'21': 10.0}
        inventory_accounts = {'21': 71310}
        acc = _make_account(1200, name='عميل', memo_account_id=70021)

        with patch('dual_system_helpers.create_dual_journal_entry') as mock_cdje:
            weight_entries_for_party(
                journal_entry_id=99,
                gold_by_karat=gold_by_karat,
                inventory_accounts=inventory_accounts,
                party_account_obj=acc,
                direction=direction,
                customer_id=1,
            )

        return mock_cdje.call_args_list

    def test_purchase_debits_inventory_credits_party(self):
        calls = self._run('purchase')
        assert len(calls) == 2  # 1 inventory debit + 1 party credit
        inv_call = calls[0][1]   # first call → inventory
        party_call = calls[1][1]  # second call → party weight
        assert inv_call['account_id'] == 71310
        assert inv_call['weight_21k_debit'] == 10.0
        assert party_call['account_id'] == 70021
        assert party_call['weight_21k_credit'] == 10.0

    def test_sale_credits_inventory_debits_party(self):
        calls = self._run('sale')
        assert len(calls) == 2
        inv_call = calls[0][1]
        party_call = calls[1][1]
        assert inv_call['account_id'] == 71310
        assert inv_call['weight_21k_credit'] == 10.0
        assert party_call['account_id'] == 70021
        assert party_call['weight_21k_debit'] == 10.0


# ─────────────────────────────────────────────────────────────────────────────
# sale_je_for_invoice (integration-level)
# ─────────────────────────────────────────────────────────────────────────────


class TestSaleJeForInvoice:
    """
    يختبر أن sale_je_for_invoice يُنشئ القيود الصحيحة.
    يستخدم mocking لـ create_dual_journal_entry.
    """

    def _run_sale(self, total_cash=1150.0, total_tax=150.0, gold_by_karat=None):
        from je_adapter import sale_je_for_invoice

        if gold_by_karat is None:
            gold_by_karat = {'21': 10.0}

        inv_accounts = {'18': 71300, '21': 71310, '22': 71320, '24': 71330}
        party_acc = _make_account(1201, name='عميل أ', memo_account_id=70021)

        with patch('dual_system_helpers.create_dual_journal_entry') as mock_cdje:
            sale_je_for_invoice(
                journal_entry_id=10,
                invoice_type='بيع',
                gold_type='new',
                get_mapping_fn=_mock_mapping,
                inventory_accounts=inv_accounts,
                gold_by_karat=gold_by_karat,
                sales_account_id=4100,
                vat_payable_account_id=2400,
                ar_account_id=1201,
                customer_account_obj=party_acc,
                total_cash=total_cash,
                total_tax=total_tax,
                customer_id=1,
            )

        return mock_cdje.call_args_list

    def test_creates_ar_debit(self):
        calls = self._run_sale()
        debit_cash_calls = [c for c in calls if c[1].get('cash_debit', 0) > 0]
        ar_debit = next(
            (c for c in debit_cash_calls if c[1]['account_id'] == 1201), None
        )
        assert ar_debit is not None, "يجب أن يكون هناك مدين لذمم العميل"
        assert ar_debit[1]['cash_debit'] == 1150.0

    def test_creates_sales_credit(self):
        calls = self._run_sale()
        credit_cash_calls = [c for c in calls if c[1].get('cash_credit', 0) > 0]
        sales_credit = next(
            (c for c in credit_cash_calls if c[1]['account_id'] == 4100), None
        )
        assert sales_credit is not None, "يجب أن يكون هناك دائن لحساب المبيعات"
        assert sales_credit[1]['cash_credit'] == 1000.0  # total_cash - total_tax

    def test_creates_vat_credit(self):
        calls = self._run_sale()
        vat_credit = next(
            (c for c in calls if c[1].get('account_id') == 2400
             and c[1].get('cash_credit', 0) > 0), None
        )
        assert vat_credit is not None, "يجب أن يكون هناك دائن لحساب الضريبة"
        assert vat_credit[1]['cash_credit'] == 150.0

    def test_creates_inventory_weight_credit(self):
        calls = self._run_sale()
        inv_weight_credit = next(
            (c for c in calls
             if c[1].get('account_id') == 71310
             and c[1].get('weight_21k_credit', 0) > 0), None
        )
        assert inv_weight_credit is not None, "يجب أن يكون هناك دائن وزني على مخزون عيار 21"
        assert inv_weight_credit[1]['weight_21k_credit'] == 10.0

    def test_debits_the_cost_of_sales_by_weight_not_the_customer(self):
        """The grams sold are the cost of sales by weight (CUSTGOLD-001)."""
        calls = self._run_sale()
        sold = next(
            (c for c in calls
             if c[1].get('account_id') == 75210
             and c[1].get('weight_21k_debit', 0) > 0), None
        )
        assert sold is not None, "يجب أن يكون هناك مدين وزني على تكلفة مبيعات الذهب وزني"
        assert sold[1]['weight_21k_debit'] == 10.0
        assert not [c for c in calls if c[1].get('account_id') == 70021], "لا وزن على حساب وزن العميل"

    def test_je_is_balanced(self):
        """التحقق أن إجمالي المدين = إجمالي الدائن نقداً"""
        calls = self._run_sale(total_cash=1150.0, total_tax=150.0)
        total_debit = sum(c[1].get('cash_debit', 0) for c in calls)
        total_credit = sum(c[1].get('cash_credit', 0) for c in calls)
        assert abs(total_debit - total_credit) < 0.01, (
            f"القيد غير متوازن: مدين={total_debit}, دائن={total_credit}"
        )

    def test_no_weight_on_financial_account(self):
        """التأكد أن الحسابات المالية لا تحمل أوزاناً"""
        calls = self._run_sale()
        financial_accounts = {1201, 4100, 2400}  # AR, sales, VAT
        weight_keys = [f'weight_{k}k_{d}' for k in [18, 21, 22, 24] for d in ['debit', 'credit']]
        for c in calls:
            acc_id = c[1].get('account_id')
            if acc_id in financial_accounts:
                for wk in weight_keys:
                    val = c[1].get(wk, 0)
                    assert val == 0, (
                        f"حساب مالي {acc_id} يحمل وزناً في {wk}={val}"
                    )

    def test_no_cash_on_weight_account(self):
        """التأكد أن حسابات الوزن لا تحمل قيماً نقدية"""
        calls = self._run_sale()
        weight_accounts = {71300, 71310, 71320, 71330, 70021}
        for c in calls:
            acc_id = c[1].get('account_id')
            if acc_id in weight_accounts:
                cd = c[1].get('cash_debit', 0)
                cc = c[1].get('cash_credit', 0)
                assert cd == 0 and cc == 0, (
                    f"حساب وزني {acc_id} يحمل قيمة نقدية: debit={cd}, credit={cc}"
                )
