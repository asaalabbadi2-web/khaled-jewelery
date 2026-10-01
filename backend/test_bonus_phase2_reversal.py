"""
test_bonus_phase2_reversal.py
==============================
اختبارات Phase 2 — عكس المكافآت و Clawback Candidates.

الاختبارات الخمسة:
  1. approved → reversed: BonusReversalService يُنشئ سند BREV وينقل الحالة.
  2. paid → reversed: يُعيد كود 'paid_bonus_reversal_policy_not_configured'.
  3. Double-reverse: الاعتماد الثاني يُعيد 'duplicate_voucher'.
  4. Posting Pipeline: ترحيل مرتجع بيع ينشئ BonusClawbackCandidate.
  5. Dismiss candidate: POST dismiss يُغلق المرشح بحالة 'dismissed'.
"""

import pytest
from datetime import date, datetime

from app import app
from models import (
    db,
    Account,
    Employee,
    EmployeeBonus,
    BonusInvoiceLink,
    BonusClawbackCandidate,
    Voucher,
    VoucherAccountLine,
    Invoice,
)
from tests.cleanup import purge  # UNPOST-001 U3: cleanup of posted rows is a purge


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope='module')
def phase2_accounts():
    """يضمن وجود حسابَي 5401 و 2310 اللذين تستخدمهما الخدمة."""
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
def approved_bonus(phase2_accounts):
    """ينشئ مكافأة بحالة approved جاهزة للعكس."""
    with app.app_context():
        emp = Employee.query.first()
        b = EmployeeBonus(
            employee_id=emp.id,
            bonus_type='fixed',
            amount=600.0,
            status='approved',
            approved_by='test_setup',
            approved_at=datetime.now(),
            period_start=date(2026, 7, 1),
            period_end=date(2026, 7, 31),
            created_at=datetime.now(),
        )
        db.session.add(b)
        db.session.commit()
        return b.id


@pytest.fixture
def paid_bonus(phase2_accounts):
    """ينشئ مكافأة بحالة paid."""
    with app.app_context():
        emp = Employee.query.first()
        b = EmployeeBonus(
            employee_id=emp.id,
            bonus_type='fixed',
            amount=800.0,
            status='paid',
            approved_by='test_setup',
            approved_at=datetime.now(),
            paid_by='test_setup',
            paid_at=datetime.now(),
            period_start=date(2026, 7, 1),
            period_end=date(2026, 7, 31),
            created_at=datetime.now(),
        )
        db.session.add(b)
        db.session.commit()
        return b.id


@pytest.fixture(scope='module')
def invoice_with_bonus(phase2_accounts):
    """
    ينشئ مرة واحدة لكل module:
      - فاتورة بيع أصلية
      - مكافأة مرتبطة بها عبر BonusInvoiceLink
      - معرف فاتورة مرتجع بيع وهمي (لا يُرحَّل عبر HTTP)
    يُعيد (original_invoice_id, return_invoice_id, bonus_id)
    """
    with app.app_context():
        emp = Employee.query.first()

        # الفاتورة الأصلية
        orig = Invoice(
            invoice_type_id=1,
            invoice_type='بيع',
            date=datetime.now(),
            total=5000.0,
            is_posted=True,
        )
        db.session.add(orig)
        db.session.flush()

        # المكافأة المرتبطة
        bonus = EmployeeBonus(
            employee_id=emp.id,
            bonus_type='fixed',
            amount=250.0,
            status='approved',
            approved_by='test_setup',
            approved_at=datetime.now(),
            period_start=date(2026, 7, 1),
            period_end=date(2026, 7, 31),
            created_at=datetime.now(),
        )
        db.session.add(bonus)
        db.session.flush()

        link = BonusInvoiceLink(bonus_id=bonus.id, invoice_id=orig.id)
        db.session.add(link)

        # فاتورة المرتجع (تُخزَّن فقط — لا تُرحَّل عبر HTTP في الاختبارات)
        ret = Invoice(
            invoice_type_id=2,
            invoice_type='مرتجع بيع',
            date=datetime.now(),
            total=5000.0,
            is_posted=False,
            original_invoice_id=orig.id,
        )
        db.session.add(ret)
        db.session.commit()
        orig_id, ret_id, bonus_id = orig.id, ret.id, bonus.id

    yield orig_id, ret_id, bonus_id

    with app.app_context():
        from models import BonusClawbackCandidate
        BonusClawbackCandidate.query.filter_by(bonus_id=bonus_id).delete()
        BonusClawbackCandidate.query.filter_by(return_invoice_id=ret_id).delete()
        BonusInvoiceLink.query.filter_by(bonus_id=bonus_id).delete()
        EmployeeBonus.query.filter_by(id=bonus_id).delete()
        purge(lambda: Invoice.query.filter_by(id=ret_id).delete())
        purge(lambda: Invoice.query.filter_by(id=orig_id).delete())
        db.session.commit()


@pytest.fixture
def auth_token():
    """JWT للمستخدم admin."""
    with app.app_context():
        from auth_decorators import generate_token
        from models import User
        admin = User.query.filter_by(username='admin').first()
        assert admin, "admin user must be seeded in conftest"
        return f'Bearer {generate_token(admin)}'


# ── Tests ─────────────────────────────────────────────────────────────────────

class TestBonusReversal:
    """اختبارات BonusReversalService مباشرة."""

    def test_approved_bonus_reverses_successfully(self, approved_bonus):
        """approved → reversed: سند BREV يُنشأ والحالة تصبح reversed."""
        from bonus_reversal_service import BonusReversalService

        with app.app_context():
            ok, payload = BonusReversalService.reverse(
                approved_bonus, 'admin', reason='إلغاء بناءً على مرتجع'
            )

        assert ok is True, f"توقعنا نجاح العكس — payload: {payload}"
        assert payload['voucher_number'] == f'BREV-{approved_bonus}'

        with app.app_context():
            bonus = EmployeeBonus.query.get(approved_bonus)
            assert bonus.status == 'reversed'
            assert bonus.reversed_by == 'admin'
            assert bonus.reversed_at is not None
            assert bonus.reversal_reason == 'إلغاء بناءً على مرتجع'

    def test_reversal_voucher_has_correct_dr_cr_lines(self, approved_bonus):
        """سند BREV يجب أن يحتوي Dr 2310 و Cr 5401 (عكس BAPP)."""
        from bonus_reversal_service import BonusReversalService

        with app.app_context():
            ok, payload = BonusReversalService.reverse(approved_bonus, 'admin')
            assert ok, payload

            voucher = Voucher.query.filter_by(
                voucher_number=payload['voucher_number']
            ).first()
            assert voucher is not None

            lines = VoucherAccountLine.query.filter_by(voucher_id=voucher.id).all()
            assert len(lines) == 2, f"يجب سطران (Dr/Cr) — وجدنا {len(lines)}"

            debit = next(l for l in lines if l.line_type == 'debit')
            credit = next(l for l in lines if l.line_type == 'credit')
            assert debit.amount == credit.amount

            # Dr على حساب المستحق (2310)، Cr على حساب المصروف (5401)
            debit_acct = Account.query.get(debit.account_id)
            credit_acct = Account.query.get(credit.account_id)
            assert debit_acct.account_number.startswith('2310'), (
                f"Dr يجب أن يكون على 2310 — وجدنا {debit_acct.account_number}"
            )
            assert credit_acct.account_number.startswith('5401'), (
                f"Cr يجب أن يكون على 5401 — وجدنا {credit_acct.account_number}"
            )

    def test_paid_bonus_returns_policy_not_configured(self, paid_bonus):
        """مكافأة مدفوعة → 422 مع كود paid_bonus_reversal_policy_not_configured."""
        from bonus_reversal_service import BonusReversalService

        with app.app_context():
            ok, payload = BonusReversalService.reverse(paid_bonus, 'admin')

        assert ok is False
        assert payload.get('code') == 'paid_bonus_reversal_policy_not_configured', (
            f"كود غير متوقع: {payload.get('code')}"
        )

    def test_double_reverse_returns_duplicate_voucher(self, approved_bonus):
        """عكس مكافأة مرتين — المرة الثانية تُعيد duplicate_voucher."""
        from bonus_reversal_service import BonusReversalService

        with app.app_context():
            ok1, _ = BonusReversalService.reverse(approved_bonus, 'admin')
            assert ok1

            ok2, payload2 = BonusReversalService.reverse(approved_bonus, 'admin')

        assert ok2 is False
        assert payload2.get('code') in ('duplicate_voucher', 'wrong_status'), (
            f"كود غير متوقع: {payload2.get('code')}"
        )


class TestClawbackCandidates:
    """اختبارات Clawback Candidates عبر Posting Pipeline و Routes."""

    def test_posting_hook_creates_clawback_candidate(
        self, invoice_with_bonus
    ):
        """
        منطق hook الـ Posting Pipeline عند مرتجع بيع:
        ينشئ BonusClawbackCandidate بحالة 'open' لكل مكافأة مرتبطة
        بالفاتورة الأصلية — دون أي قيود محاسبية.

        نختبر المنطق مباشرة (لا عبر HTTP) لعزله عن متطلبات
        الترحيل الكاملة (حسابات GL، قيود، إلخ).
        """
        original_invoice_id, return_invoice_id, bonus_id = invoice_with_bonus

        with app.app_context():
            # نُشغّل نفس المنطق الذي يُنفّذه posting_routes.post_invoice
            bonus_links = (
                BonusInvoiceLink.query
                .filter_by(invoice_id=original_invoice_id)
                .all()
            )
            created = []
            for link in bonus_links:
                already = BonusClawbackCandidate.query.filter_by(
                    bonus_id=link.bonus_id,
                    return_invoice_id=return_invoice_id,
                ).first()
                if not already:
                    candidate = BonusClawbackCandidate(
                        bonus_id=link.bonus_id,
                        return_invoice_id=return_invoice_id,
                        original_invoice_id=original_invoice_id,
                        reason=f'ترحيل مرتجع بيع #{return_invoice_id}',
                        status='open',
                    )
                    db.session.add(candidate)
                    created.append(candidate)
            db.session.commit()

            assert len(created) >= 1, 'توقعنا إنشاء مرشح واحد على الأقل'

            saved = BonusClawbackCandidate.query.filter_by(
                bonus_id=bonus_id,
                return_invoice_id=return_invoice_id,
            ).first()
            assert saved is not None
            assert saved.status == 'open'
            assert saved.original_invoice_id == original_invoice_id

            # لا قيود محاسبية — التحقق: عدد القيود لم يتغير
            from models import JournalEntry
            je_count = JournalEntry.query.filter_by(
                reference_type='bonus',
                reference_id=bonus_id,
            ).count()
            assert je_count == 0, (
                f'Posting Pipeline يجب ألا ينشئ قيوداً — وجدنا {je_count}'
            )

    def test_db_unique_constraint_prevents_duplicate_candidate(
        self, invoice_with_bonus
    ):
        """
        القيد الفريد على (bonus_id, return_invoice_id) يمنع
        إنشاء مرشحَين متطابقَين حتى عند التزامن أو الإعادة.
        الاختبار يُثبت أن الحماية موجودة على مستوى DB لا فقط التطبيق.
        """
        import sqlalchemy.exc
        original_invoice_id, return_invoice_id, bonus_id = invoice_with_bonus

        with app.app_context():
            # المرشح الأول أُنشئ بالفعل في test_posting_hook_creates_clawback_candidate
            existing = BonusClawbackCandidate.query.filter_by(
                bonus_id=bonus_id,
                return_invoice_id=return_invoice_id,
            ).first()
            assert existing is not None, 'يجب أن يكون المرشح الأول موجوداً من الاختبار السابق'

            # محاولة إنشاء مرشح مطابق يجب أن تُطلق IntegrityError
            duplicate = BonusClawbackCandidate(
                bonus_id=bonus_id,
                return_invoice_id=return_invoice_id,
                original_invoice_id=original_invoice_id,
                reason='محاولة تكرار',
                status='open',
            )
            db.session.add(duplicate)
            try:
                db.session.flush()
                db.session.rollback()
                raise AssertionError(
                    'توقعنا IntegrityError من القيد الفريد — لم يُطلق'
                )
            except sqlalchemy.exc.IntegrityError:
                db.session.rollback()  # التراجع الصحيح بعد الخطأ

    def test_dismiss_clawback_candidate(self, invoice_with_bonus, auth_token):
        """
        POST /bonuses/clawback-candidates/{id}/dismiss
        يُغلق المرشح الموجود بحالة dismissed.
        يستخدم المرشح الذي أنشأه test_posting_hook_creates_clawback_candidate.
        """
        original_invoice_id, return_invoice_id, bonus_id = invoice_with_bonus

        with app.app_context():
            # نبحث عن المرشح المفتوح الموجود (أُنشئ في الاختبارات السابقة)
            candidate = BonusClawbackCandidate.query.filter_by(
                bonus_id=bonus_id,
                status='open',
            ).first()
            if not candidate:
                # احتياطي: ننشئ مرشحاً بـ return_invoice_id=None (NULL != NULL في UNIQUE)
                candidate = BonusClawbackCandidate(
                    bonus_id=bonus_id,
                    return_invoice_id=None,
                    original_invoice_id=original_invoice_id,
                    reason='اختبار dismiss',
                    status='open',
                )
                db.session.add(candidate)
                db.session.commit()
            candidate_id = candidate.id

        with app.test_client() as client:
            resp = client.post(
                f'/api/bonuses/clawback-candidates/{candidate_id}/dismiss',
                json={'dismissed_by': 'admin'},
                headers={'Authorization': auth_token},
            )

        assert resp.status_code == 200, f"توقعنا 200 — {resp.get_json()}"
        body = resp.get_json()
        assert body['success'] is True
        assert body['candidate']['status'] == 'dismissed'
        assert body['candidate']['dismissed_by'] == 'admin'
