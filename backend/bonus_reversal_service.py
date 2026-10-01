"""
bonus_reversal_service.py
=========================
الخدمة الوحيدة المسؤولة عن عكس المكافآت وكتابة سندات BREV-*.

السياسة المعتمدة (Phase 2 — اجتماع 2026-08-03):
  • approved → reversed: مسموح، ينشئ BREV-{id} (Dr 2310 / Cr 5401)
  • paid    → reversed: محظور حالياً — يُعيد كود 'paid_bonus_reversal_policy_not_configured'
    سبب: القرار المحاسبي (استرداد / خصم من راتب / غيره) لم يُحدَّد بعد.
  • أي حالة أخرى: كود 'wrong_status'

الاستدعاء المسموح:
  - من route POST /bonuses/{id}/reverse فقط.
  - لا يُستدعى من Posting Pipeline أبداً.
"""

from __future__ import annotations

from datetime import date, datetime

from sqlalchemy.exc import IntegrityError

from models import (
    Account,
    EmployeeBonus,
    Employee,
    Voucher,
    VoucherAccountLine,
    db,
)


# ── Account lookup helpers (مطابق للمنطق في bonus_routes.py) ─────────────────

def _find_bonus_expense_account() -> Account | None:
    """حساب 5401 — مصروف مكافآت الموظفين."""
    from app import app
    expense_number = app.config.get('BONUS_EXPENSE_ACCOUNT_NUMBER', '5401')
    acct = Account.query.filter_by(account_number=expense_number).first()
    if acct:
        return acct
    return (
        Account.query
        .filter(
            Account.name.ilike('%مصروف مكافأ%'),
            Account.type == 'Expense',
        )
        .first()
    )


def _find_bonus_payable_account(employee: Employee | None = None) -> Account | None:
    """حساب 2310xxx — مكافآت مستحقة للموظف."""
    if employee:
        specific = (
            Account.query
            .filter(
                Account.account_number.like('2310%'),
                Account.name.like(f'%{employee.name}%'),
            )
            .first()
        )
        if specific:
            return specific
    return Account.query.filter_by(account_number='2310').first()


# ── Main service ──────────────────────────────────────────────────────────────

class BonusReversalService:
    """
    استخدام:
        ok, payload = BonusReversalService.reverse(bonus_id, reversed_by, reason)
    """

    @staticmethod
    def reverse(
        bonus_id: int,
        reversed_by: str,
        reason: str | None = None,
    ) -> tuple[bool, dict]:
        """
        Returns:
            (True,  {'voucher_number', 'voucher_id', 'amount'})
            (False, {'error', 'code', ...})

        Codes:
            not_found                              — المكافأة غير موجودة
            paid_bonus_reversal_policy_not_configured — مكافأة مدفوعة (محظور)
            wrong_status                           — حالة غير قابلة للعكس
            duplicate_voucher                      — سند BREV موجود مسبقاً
            missing_expense_account                — حساب 5401 غير موجود
            missing_payable_account                — حساب 2310 غير موجود
            exception                              — خطأ غير متوقع
        """
        try:
            bonus: EmployeeBonus | None = (
                EmployeeBonus.query.with_for_update().get(bonus_id)
            )
            if bonus is None:
                return False, {'error': 'المكافأة غير موجودة', 'code': 'not_found'}

            if bonus.status == 'paid':
                return False, {
                    'error': (
                        'لا يمكن عكس مكافأة مدفوعة. '
                        'القرار المحاسبي (استرداد / خصم / غيره) لم يُحدَّد بعد.'
                    ),
                    'code': 'paid_bonus_reversal_policy_not_configured',
                }

            if bonus.status != 'approved':
                return False, {
                    'error': f'لا يمكن عكس مكافأة بحالة "{bonus.status}"',
                    'code': 'wrong_status',
                }

            # ── Idempotency guard ─────────────────────────────────────────
            voucher_number = f'BREV-{bonus.id}'
            existing = Voucher.query.filter_by(voucher_number=voucher_number).first()
            if existing:
                return False, {
                    'error': f'سند العكس موجود مسبقاً برقم {voucher_number}',
                    'code': 'duplicate_voucher',
                    'voucher_id': existing.id,
                }

            # ── Account resolution ────────────────────────────────────────
            expense_account = _find_bonus_expense_account()
            if not expense_account:
                return False, {
                    'error': 'لم يُعثر على حساب مصروف المكافآت (5401)',
                    'code': 'missing_expense_account',
                }

            employee = Employee.query.get(bonus.employee_id)
            emp_name = employee.name if employee else str(bonus.employee_id)

            payable_account = _find_bonus_payable_account(employee)
            if not payable_account:
                return False, {
                    'error': f'لم يُعثر على حساب مكافآت مستحقة للموظف ({emp_name})',
                    'code': 'missing_payable_account',
                }

            # ── Reversal voucher: Dr 2310 / Cr 5401 ──────────────────────
            # (عكس قيد الاعتماد: كان Dr 5401 / Cr 2310)
            voucher = Voucher(
                voucher_number=voucher_number,
                voucher_type='adjustment',
                date=date.today(),
                description=f"عكس مكافأة {emp_name} - {bonus.bonus_type}",
                status='approved',
                created_by=reversed_by,
                approved_by=reversed_by,
                amount_cash=float(bonus.amount or 0.0),
                party_type='employee',
                employee_id=bonus.employee_id,
                party_name=emp_name,
                receiver_name=emp_name,
                reference_type='bonus',
                reference_id=bonus.id,
                reference_number=f'BONUS-{bonus.id}',
            )
            db.session.add(voucher)
            db.session.flush()

            db.session.add(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=payable_account.id,
                line_type='debit',
                amount_type='cash',
                description=f"عكس استحقاق مكافأة {emp_name}",
                amount=bonus.amount,
            ))
            db.session.add(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=expense_account.id,
                line_type='credit',
                amount_type='cash',
                description=f"عكس مصروف مكافأة {emp_name}",
                amount=bonus.amount,
            ))

            # ── Journal Entry ─────────────────────────────────────────────
            # Born approved, so its entry is posted with it; a failure fails the
            # reversal (V0, owner 1 Oct 2026) -- never an approved voucher without one.
            from routes import post_entry_of_approved_voucher
            post_entry_of_approved_voucher(voucher, posted_by=reversed_by)

            # ── State transition ──────────────────────────────────────────
            bonus.reverse(reversed_by=reversed_by, reason=reason)

            try:
                db.session.commit()
            except IntegrityError:
                db.session.rollback()
                ev = Voucher.query.filter_by(voucher_number=voucher_number).first()
                if ev:
                    return False, {
                        'error': f'سند العكس موجود مسبقاً (race condition): {voucher_number}',
                        'code': 'duplicate_voucher',
                        'voucher_id': ev.id,
                    }
                raise

            return True, {
                'voucher_number': voucher_number,
                'voucher_id': voucher.id,
                'amount': bonus.amount,
            }

        except Exception as exc:
            db.session.rollback()
            import traceback
            traceback.print_exc()
            return False, {'error': str(exc), 'code': 'exception'}
