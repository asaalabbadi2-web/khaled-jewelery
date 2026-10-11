"""Deactivating an account -- it keeps its entries and takes no new one (ADR-043, phase 1).

The owner (11 Oct 2026, ADR-043): an account no longer needed (2210, after
stage-4 item 22; the weight twins of accounts with no weight, CHART-001) stays
in the tree, the statements and the reports, and takes no new entry. The
session guard (models.py) and the database trigger (account_status_trigger.py)
refuse a new line on it from any writer.

An account is not deactivated while a posting could still reach it: a
balance (cash or any karat, of the counted lines); a line of an entry not
posted yet (posting it adds no line, so no guard would see it); a line of a
pending voucher; an active child; an active mapping (the postings ask the
mapping); a safe box; a customer, supplier, office or employee; a system
setting. Each refusal names its reason.
"""
from __future__ import annotations

import json

from sqlalchemy import func, or_

from accounting.balances import counted_line_filters
from models import (Account, AccountDeactivated, AccountingMapping, AuditLog, Customer, Employee, JournalEntry,
                    JournalEntryLine, Office, SafeBox, Settings, Supplier, Voucher, VoucherAccountLine, db)

__all__ = ['AccountDeactivated', 'NotDeactivatable', 'activate_account', 'deactivate_account']

KARATS = ('18k', '21k', '22k', '24k')


class NotDeactivatable(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _account(account_id) -> Account:
    account = db.session.get(Account, account_id)
    if account is None:
        raise NotDeactivatable('ACCOUNT_NOT_FOUND', 'الحساب غير موجود')
    return account


def _why_not(account: Account) -> NotDeactivatable | None:
    i = account.id
    sums = [func.coalesce(func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit), 0.0)] + [
        func.coalesce(func.sum(getattr(JournalEntryLine, f'debit_{k}') - getattr(JournalEntryLine, f'credit_{k}')), 0.0)
        for k in KARATS]
    row = (db.session.query(*sums).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
           .filter(*counted_line_filters(), JournalEntryLine.account_id == i).one())
    if abs(float(row[0])) > 0.005 or any(abs(float(v)) > 0.0005 for v in row[1:]):
        return NotDeactivatable('HAS_BALANCE', 'لا يُوقف حساب له رصيد: يُصفَّر بقيد أولًا')
    pending = (db.session.query(JournalEntryLine.id).join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
               .filter(JournalEntryLine.account_id == i, JournalEntryLine.is_deleted.is_(False),
                       JournalEntry.is_deleted.is_(False), JournalEntry.is_posted.is_(False)).first())
    if pending:
        return NotDeactivatable('HAS_UNPOSTED_ENTRY', 'لا يُوقف حساب عليه قيد لم يُرحَّل بعد')
    if (db.session.query(VoucherAccountLine.id).join(Voucher, Voucher.id == VoucherAccountLine.voucher_id)
            .filter(VoucherAccountLine.account_id == i, Voucher.status == 'pending').first()):
        return NotDeactivatable('HAS_PENDING_VOUCHER', 'لا يُوقف حساب عليه سند معلّق')
    if Account.query.filter(Account.parent_id == i, Account.is_active.is_(True)).first():
        return NotDeactivatable('HAS_ACTIVE_CHILDREN', 'لا يُوقف حساب له حسابات فرعية نشطة')
    if AccountingMapping.query.filter_by(account_id=i, is_active=True).first():
        return NotDeactivatable('HAS_ACCOUNTING_MAPPING', 'لا يُوقف حساب مستخدم في ربط محاسبي')
    if SafeBox.query.filter_by(account_id=i).first():
        return NotDeactivatable('IS_SAFEBOX_ACCOUNT', 'لا يُوقف حساب مرتبط بخزينة')
    if (Customer.query.filter(or_(Customer.account_id == i, Customer.account_category_id == i)).first()
            or Supplier.query.filter(or_(Supplier.account_id == i, Supplier.account_category_id == i)).first()
            or Office.query.filter_by(account_category_id=i).first()
            or Employee.query.filter_by(account_id=i).first()):
        return NotDeactivatable('HAS_ENTITY_LINK', 'لا يُوقف حساب مرتبط بعميل أو مورد أو مكتب أو موظف')
    settings = Settings.query.first()
    if settings and i in (settings.stones_pending_account_id, settings.stones_display_revenue_account_id):
        return NotDeactivatable('HAS_SYSTEM_CONFIG', 'لا يُوقف حساب مستخدم في إعدادات النظام')
    return None


def _audit(account: Account, action: str, by: str, now):
    db.session.add(AuditLog(user_name=by, action=action, entity_type='account', entity_id=account.id,
                            entity_number=account.account_number, success=True,
                            details=json.dumps({'account': account.account_number, 'name': account.name, 'at': now},
                                               ensure_ascii=False, default=str)))


def deactivate_account(account_id: int, *, by: str, now) -> Account:
    account = _account(account_id)
    if account.is_active is False:
        return account
    refused = _why_not(account)
    if refused is not None:
        raise refused
    account.is_active = False
    _audit(account, 'account_deactivated', by, now)
    db.session.flush()
    return account


def activate_account(account_id: int, *, by: str, now) -> Account:
    account = _account(account_id)
    if account.is_active is not False:
        return account
    account.is_active = True
    _audit(account, 'account_activated', by, now)
    db.session.flush()
    return account
