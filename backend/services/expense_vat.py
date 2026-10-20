"""An operating expense paid with a tax invoice carries its VAT (the owner, 20 Oct 2026).

The voucher screen sends what was paid on the expense, whole, and the tax
invoice: {'amount', 'supplier_name', 'supplier_tax_number', 'invoice_number',
'invoice_date'}. Here it is checked and split: the expense line becomes what
was paid less the VAT; the VAT a debit of its own on the account the policy
names for the voucher's day (ADR-043 rule 1, services/vat_policy) -- input VAT
while it is recovered, else «ضريبة القيمة المضافة غير القابلة للاسترداد».

Refused:
  - on anything but a payment to «آخر» on an operating expense (52);
  - without the tax invoice: the supplier's name and VAT number, the invoice's
    number and date -- a VAT claim stands on it;
  - a VAT number that is not 15 digits, 3 first and last;
  - a VAT above the rate's share of what was paid (a cent's rounding allowed).
"""
from __future__ import annotations

import re
from datetime import date, datetime

from models import Settings, VoucherExpenseVat, db

OPERATING_EXPENSES_ROLE = 'operating_expenses_root'
TAX_NUMBER = re.compile(r'^3\d{13}3$')
CENT = 0.01


class ExpenseVatRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _operating_expense_ids() -> set[int]:
    from accounting.chart_tree import subtree_ids
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    root = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, OPERATING_EXPENSES_ROLE)
    return set(subtree_ids(root)) if root else set()


def _rate() -> float:
    settings = Settings.query.first()
    return float(getattr(settings, 'tax_rate', None) or 0.15)


def _day(raw) -> date | None:
    try:
        return date.fromisoformat(str(raw)[:10])
    except ValueError:
        return None


def split_expense_vat(voucher, lines: list[dict], vat: dict) -> tuple[list[dict], dict]:
    """The voucher's lines with the VAT split off its expense line, and the
    invoice to keep -- or ExpenseVatRefused."""
    from services.vat_policy import input_vat_account, policy_on

    side = [ln for ln in lines if ln.get('line_type') == 'debit']
    expense = side[0] if len(side) == 1 else None
    if (voucher.voucher_type != 'payment' or voucher.party_type != 'other' or expense is None
            or expense.get('amount_type') != 'cash'
            or int(expense['account_id']) not in _operating_expense_ids()):
        raise ExpenseVatRefused('expense_vat_operating_expenses_only',
                                'ضريبة المصروف تُسجَّل على سند صرف لمصروف تشغيلي وحده')

    invoice = {k: str(vat.get(k) or '').strip()
               for k in ('supplier_name', 'supplier_tax_number', 'invoice_number', 'invoice_date')}
    if not all(invoice.values()) or _day(invoice['invoice_date']) is None:
        raise ExpenseVatRefused('expense_vat_needs_tax_invoice',
                                'الضريبة تُسجَّل بفاتورتها الضريبية: اسم المورد ورقمه الضريبي '
                                'ورقم الفاتورة وتاريخها')
    if not TAX_NUMBER.match(invoice['supplier_tax_number']):
        raise ExpenseVatRefused('expense_vat_bad_tax_number',
                                'الرقم الضريبي 15 رقمًا، أوله 3 وآخره 3')

    amount = round(float(vat.get('amount') or 0), 2)
    paid = round(float(expense['amount'] or 0), 2)
    rate = _rate()
    ceiling = round(paid * rate / (1 + rate), 2)
    if amount <= 0 or amount > ceiling + CENT:
        raise ExpenseVatRefused('expense_vat_above_rate',
                                f'الضريبة {amount:.2f} أكبر من حصتها ({ceiling:.2f}) مما دُفع ({paid:.2f})')

    day = voucher.date.date() if isinstance(voucher.date, datetime) else voucher.date
    vat_account = input_vat_account(day, operation_type='شراء')
    split = [dict(ln) for ln in lines]
    split[lines.index(expense)]['amount'] = round(paid - amount, 2)
    split.append({'account_id': vat_account, 'line_type': 'debit', 'amount_type': 'cash', 'amount': amount,
                  'description': f"ضريبة فاتورة {invoice['invoice_number']} — {invoice['supplier_name']}"})
    return split, {**invoice, 'invoice_date': _day(invoice['invoice_date']), 'amount': amount,
                   'recoverable': policy_on(day).input_vat_recoverable, 'vat_account_id': vat_account}


def keep_invoice(voucher, invoice: dict | None, *, by: str, now: datetime) -> None:
    """The voucher's tax invoice, replacing the one it had."""
    VoucherExpenseVat.query.filter_by(voucher_id=voucher.id).delete()
    if invoice:
        db.session.add(VoucherExpenseVat(voucher_id=voucher.id, created_by=by, created_at=now, **invoice))
