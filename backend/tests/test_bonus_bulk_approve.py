"""
test_bonus_bulk_approve.py
==========================
اختبارات Phase 1 — إصلاح bulk_approve.

الاختبارات الأربعة:
  1. نجاح كامل: جميع المكافآت المعلقة تُعتمد مع قيودها المحاسبية.
  2. فشل جزئي: مكافأة بحالة خاطئة تفشل دون إيقاف بقية الدفعة.
  3. Double-approval: اعتماد مكافأة مرتين — المرة الثانية تُعيد خطأ 'wrong_status'.
  4. القيد المحاسبي: كل اعتماد ناجح يُنشئ سند BAPP-{id} مع سطرين (Dr/Cr).

بنية الاختبار:
  - يُنشئ حسابات محاسبية حقيقية (5401 مصروف، 2310 مستحق) لكي تجد
    _find_bonus_expense_account و_find_bonus_payable_account ما يبحثان عنه.
  - يُنشئ EmployeeBonus مباشرة في DB — بدون استدعاء HTTP.
  - يستدعي _approve_single_bonus وbulk_approve_bonuses مباشرة.
"""

import pytest
from datetime import date, datetime

from app import app
from models import (
    db,
    Account,
    Employee,
    BonusRule,
    EmployeeBonus,
    Voucher,
    VoucherAccountLine,
)


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield



# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope='module')
def bonus_accounts():
    """
    يضمن وجود حساب مصروف المكافآت (5401) وحساب المستحق (2310)
    اللذَين تبحث عنهما _find_bonus_expense_account / _find_bonus_payable_account.
    """
    with app.app_context():
        if not Account.query.filter_by(account_number='5401').first():
            db.session.add(Account(
                account_number='5401',
                name='مصروف مكافآت الموظفين',
                type='Expense',
                tracks_weight=False,
            ))
        if not Account.query.filter_by(account_number='2310').first():
            db.session.add(Account(
                account_number='2310',
                name='مكافآت مستحقة للموظفين',
                type='Liability',
                tracks_weight=False,
            ))
        db.session.commit()
    yield


@pytest.fixture
def pending_bonus(bonus_accounts):
    """ينشئ مكافأة معلقة واحدة ويُعيد معرفها."""
    with app.app_context():
        emp = Employee.query.first()
        assert emp, "يجب أن يكون هناك موظف مُهيَّأ في conftest"
        bonus = EmployeeBonus(
            employee_id=emp.id,
            bonus_type='fixed',
            amount=500.0,
            status='pending',
            period_start=date(2026, 7, 1),
            period_end=date(2026, 7, 31),
            created_at=datetime.now(),
        )
        db.session.add(bonus)
        db.session.commit()
        return bonus.id


@pytest.fixture
def two_pending_bonuses(bonus_accounts):
    """ينشئ مكافأتَين معلقتَين ويُعيد قائمة معرفاتهما."""
    with app.app_context():
        emp = Employee.query.first()
        ids = []
        for amount in (300.0, 700.0):
            b = EmployeeBonus(
                employee_id=emp.id,
                bonus_type='fixed',
                amount=amount,
                status='pending',
                period_start=date(2026, 7, 1),
                period_end=date(2026, 7, 31),
                created_at=datetime.now(),
            )
            db.session.add(b)
            db.session.flush()
            ids.append(b.id)
        db.session.commit()
        return ids


@pytest.fixture
def mixed_bonuses(bonus_accounts):
    """
    ينشئ ثلاث مكافآت:
      - واحدة pending   (يجب أن تنجح)
      - واحدة approved  (يجب أن تفشل بـ wrong_status)
      - واحدة rejected  (يجب أن تفشل بـ wrong_status)
    """
    with app.app_context():
        emp = Employee.query.first()
        result = {}
        for status, amount in [('pending', 400.0), ('approved', 900.0), ('rejected', 200.0)]:
            b = EmployeeBonus(
                employee_id=emp.id,
                bonus_type='fixed',
                amount=amount,
                status=status,
                period_start=date(2026, 7, 1),
                period_end=date(2026, 7, 31),
                created_at=datetime.now(),
            )
            db.session.add(b)
            db.session.flush()
            result[status] = b.id
        db.session.commit()
        return result


# ── Tests ─────────────────────────────────────────────────────────────────────

class TestApproveSingleBonus:
    """اختبارات _approve_single_bonus مباشرة."""

    def test_approves_pending_bonus(self, pending_bonus):
        """مكافأة معلقة تُعتمد: ok=True، حالتها تصبح approved."""
        from bonus_routes import _approve_single_bonus

        with app.app_context():
            ok, payload = _approve_single_bonus(pending_bonus, 'test_user')

        assert ok is True, f"توقعنا نجاح الاعتماد — payload: {payload}"
        assert payload['voucher_number'] == f'BAPP-{pending_bonus}'

        with app.app_context():
            bonus = EmployeeBonus.query.get(pending_bonus)
            assert bonus.status == 'approved'
            assert bonus.approved_by == 'test_user'
            assert bonus.approved_at is not None

    def test_creates_voucher_with_debit_and_credit_lines(self, pending_bonus):
        """كل اعتماد يُنشئ سند BAPP مع سطر Dr (مصروف) وسطر Cr (مستحق)."""
        from bonus_routes import _approve_single_bonus

        with app.app_context():
            ok, payload = _approve_single_bonus(pending_bonus, 'test_user')
            assert ok, payload

            voucher = Voucher.query.filter_by(
                voucher_number=payload['voucher_number']
            ).first()
            assert voucher is not None, "سند BAPP يجب أن يُنشأ"

            lines = VoucherAccountLine.query.filter_by(voucher_id=voucher.id).all()
            assert len(lines) == 2, f"يجب سطران (Dr/Cr)، وجدنا {len(lines)}"

            types = {l.line_type for l in lines}
            assert types == {'debit', 'credit'}, f"أنواع السطور: {types}"

            debit = next(l for l in lines if l.line_type == 'debit')
            credit = next(l for l in lines if l.line_type == 'credit')
            assert debit.amount == credit.amount, "المبلغ يجب أن يتساوى في الطرفين"

    def test_double_approval_returns_wrong_status(self, pending_bonus):
        """اعتماد مكافأة مرتين — المرة الثانية تُعيد code=wrong_status."""
        from bonus_routes import _approve_single_bonus

        with app.app_context():
            ok1, _ = _approve_single_bonus(pending_bonus, 'user1')
            assert ok1

            ok2, payload2 = _approve_single_bonus(pending_bonus, 'user2')

        assert ok2 is False
        assert payload2.get('code') in ('wrong_status', 'duplicate_voucher'), (
            f"توقعنا wrong_status أو duplicate_voucher — code: {payload2.get('code')}"
        )

    def test_missing_bonus_returns_not_found(self, bonus_accounts):
        """معرف غير موجود يُعيد code=not_found."""
        from bonus_routes import _approve_single_bonus

        with app.app_context():
            ok, payload = _approve_single_bonus(999_999_999, 'user')

        assert ok is False
        assert payload.get('code') == 'not_found'


class TestBulkApprove:
    """اختبارات bulk_approve_bonuses عبر test_client مع JWT حقيقي."""

    @pytest.fixture(autouse=True)
    def _token(self):
        """يُنشئ JWT للمستخدم admin لاستخدامه في كل اختبار."""
        with app.app_context():
            from auth_decorators import generate_token
            from models import User
            admin = User.query.filter_by(username='admin').first()
            assert admin, "المستخدم admin يجب أن يكون مُهيَّأً في conftest"
            self._auth_header = {'Authorization': f'Bearer {generate_token(admin)}'}

    def _call_bulk(self, ids: list, approved_by: str = 'admin'):
        """مساعد: POST إلى /api/bonuses/bulk/approve مع auth."""
        with app.test_client() as client:
            resp = client.post(
                '/api/bonuses/bulk/approve',
                json={'ids': ids, 'approved_by': approved_by},
                headers=self._auth_header,
            )
            return resp.get_json()

    def test_full_success_all_approved(self, two_pending_bonuses):
        """دفعة من مكافآت معلقة كلها تُعتمد: approved_count = len(ids)."""
        result = self._call_bulk(two_pending_bonuses)

        assert result['approved_count'] == 2, result
        assert result['failed_count'] == 0, result
        assert len(result['approved']) == 2

        # التحقق من السندات والحالة في DB
        with app.app_context():
            for item in result['approved']:
                bonus = EmployeeBonus.query.get(item['id'])
                assert bonus.status == 'approved', f"bonus {item['id']} لم يُعتمد"
                voucher = Voucher.query.filter_by(
                    voucher_number=item['voucher_number']
                ).first()
                assert voucher is not None, f"سند {item['voucher_number']} غير موجود"

    def test_partial_failure_wrong_status(self, mixed_bonuses):
        """
        دفعة تحتوي pending + approved + rejected:
          - pending تنجح
          - approved و rejected يفشلان بـ wrong_status
          - الدفعة لا تتوقف عند الفشل
        """
        ids = list(mixed_bonuses.values())
        result = self._call_bulk(ids)

        assert result['approved_count'] == 1, (
            f"توقعنا اعتماد 1 فقط (pending) — النتيجة: {result}"
        )
        assert result['failed_count'] == 2, (
            f"توقعنا فشل 2 (approved + rejected) — النتيجة: {result}"
        )

        approved_ids = [a['id'] for a in result['approved']]
        assert mixed_bonuses['pending'] in approved_ids

        failed_codes = [f.get('code') for f in result['failed']]
        for code in failed_codes:
            assert code in ('wrong_status', 'duplicate_voucher'), (
                f"كود غير متوقع: {code}"
            )

    def test_each_approved_bonus_has_je_voucher(self, two_pending_bonuses):
        """كل مكافأة في approved لها سند بسطرَي قيد (Dr + Cr)."""
        result = self._call_bulk(two_pending_bonuses)

        assert result['approved_count'] == 2, result

        with app.app_context():
            for item in result['approved']:
                lines = (
                    VoucherAccountLine.query
                    .join(Voucher)
                    .filter(Voucher.voucher_number == item['voucher_number'])
                    .all()
                )
                assert len(lines) == 2, (
                    f"سند {item['voucher_number']} يجب أن يحتوي سطرَين — وجدنا {len(lines)}"
                )

    def test_empty_ids_returns_400(self, bonus_accounts):
        """قائمة فارغة تُعيد خطأ 400."""
        with app.test_client() as client:
            resp = client.post(
                '/api/bonuses/bulk/approve',
                json={'ids': []},
                headers=self._auth_header,
            )
        assert resp.status_code == 400

    def test_backward_compat_fields_present(self, two_pending_bonuses):
        """حقول التوافق الخلفي (approved_ids, skipped, count) موجودة."""
        result = self._call_bulk(two_pending_bonuses)

        assert 'approved_ids' in result, "approved_ids مطلوب للتوافق الخلفي"
        assert 'skipped' in result, "skipped مطلوب للتوافق الخلفي"
        assert 'count' in result, "count مطلوب للتوافق الخلفي"
        assert result['count'] == result['approved_count']
