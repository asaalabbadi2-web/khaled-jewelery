#!/usr/bin/env python
# -*- coding: utf-8 -*-

"""Employee account naming helpers.

Goal: make all accounts that are auto-generated when creating an employee
clearly distinguishable in journal entry pickers by prefixing the account type.

Examples:
- ح/سلف الموظف فلان
- ح/ذمم الموظف فلان - رواتب
- ح/عهدة نقدية الموظف فلان
"""

from typing import Optional


def employee_personal_account_name(employee_name: str) -> str:
	return f"ح/حساب الموظف {employee_name}".strip()


def employee_advance_account_name(employee_name: str) -> str:
	return f"ح/سلف الموظف {employee_name}".strip()


def employee_payable_account_name(
	employee_name: str,
	*,
	category_ar: str,
) -> str:
	# category_ar examples: "رواتب", "مكافآت", "أخرى"
	base = f"ح/ذمم الموظف {employee_name}".strip()
	cat = (category_ar or '').strip()
	return f"{base} - {cat}" if cat else base


def employee_cash_custody_account_name(employee_label: str) -> str:
	# employee_label can include code e.g. "فلان (EMP-2026-0001)"
	return f"ح/عهدة نقدية الموظف {employee_label}".strip()


def employee_gold_custody_account_name(employee_label: str) -> str:
	return f"ح/عهدة ذهب الموظف {employee_label}".strip()


def employee_cash_safe_name(employee_name: str) -> str:
	return f"عهدة نقدية الموظف {employee_name}".strip()


def employee_gold_safe_name(employee_name: str) -> str:
	return f"عهدة ذهب الموظف {employee_name}".strip()


def group_account_name(kind: str) -> str:
	"""Return Arabic group-account display names used during auto-creation."""
	k = (kind or '').strip().lower()
	if k == 'employees':
		return 'حساب الموظفين'
	if k == 'employee_advances':
		return 'حساب سلف الموظفين'
	if k == 'employee_payables_salary':
		return 'حساب ذمم الموظفين - رواتب'
	if k == 'employee_payables_bonus':
		return 'حساب ذمم الموظفين - مكافآت'
	if k == 'employee_payables_other':
		return 'حساب ذمم الموظفين - أخرى'
	if k == 'employee_cash_custody':
		return 'حساب عهدة نقدية الموظفين'
	if k == 'employee_gold_custody':
		return 'حساب عهدة ذهب الموظفين'
	return kind


def legacy_or_current_names(
	*,
	current: str,
	legacy: Optional[str] = None,
) -> list:
	out = []
	c = (current or '').strip()
	if c:
		out.append(c)
	l = (legacy or '').strip() if legacy else ''
	if l and l not in out:
		out.append(l)
	return out
