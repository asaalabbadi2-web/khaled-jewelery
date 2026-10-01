"""
test_dual_distribution_parity.py
=====================================
اختبارات التكافؤ بين مسارَي التوزيع:
  1. مسار القيود اليدوية   → journals.py → distribute_lines()
  2. مسار الفواتير/السندات → dual_system_helpers.py → distribute_line()

يتحقق هذا الملف من أن نفس المُدخَلات تنتج نفس سطور القيد عبر كلا المسارين.
أي انحراف = خلل في أحد المسارَين؛ الكشف هنا يمنع حدوث الخلل صمتاً في الإنتاج.

القانون الصفري: هذا الملف هو "الشاهد الأحمر" على أن dual_distribution_service
هو المصدر الوحيد لمنطق التوزيع — ممنوع تكرار هذا المنطق في أي ملف آخر.
"""
from __future__ import annotations

from datetime import date

import pytest

from app import app
from dual_distribution_service import (
    CASH_FIELDS,
    GOLD_FIELDS,
    distribute_line,
    distribute_lines,
)
from dual_system_helpers import create_dual_journal_entry
from models import Account, JournalEntry, JournalEntryLine, db
from tests.cleanup import purge  # UNPOST-001 U3: cleanup of posted rows is a purge

# ─── حسابات الاختبار ─────────────────────────────────────────────────────────
# نختار أرقاماً بعيدة عن أي نطاق مستخدم في البيانات الأساسية أو اختبارات أخرى.
_CASH_NUM     = '3891'   # حساب نقدي (cash)
_GOLD_NUM     = '73891'  # حساب وزني موازٍ (gold / 7xxx)
_UNLINKED_NUM = '3892'   # حساب بدون موازٍ



def _client():
    """A test client signed in as the seeded admin. The routes are protected,
    and the tests run with the development bypass off (TEST-002)."""
    from auth_decorators import generate_token
    from models import User
    with app.app_context():
        token = generate_token(User.query.filter_by(username='admin').first())
    client = app.test_client()
    client.environ_base['HTTP_AUTHORIZATION'] = f'Bearer {token}'
    return client

@pytest.fixture(scope='module')
def pair_ids():
    """ينشئ زوج حسابات مرتبط (نقدي ↔ وزني) مرة واحدة لكل الوحدة."""
    from account_pair_service import link_accounts

    with app.app_context():
        cash = Account.query.filter_by(account_number=_CASH_NUM).first()
        if not cash:
            cash = Account(
                account_number=_CASH_NUM, name='اختبار توزيع - نقدي',
                type='Asset', transaction_type='cash', tracks_weight=False,
            )
            db.session.add(cash)
            db.session.flush()

        gold = Account.query.filter_by(account_number=_GOLD_NUM).first()
        if not gold:
            gold = Account(
                account_number=_GOLD_NUM, name='اختبار توزيع - وزني',
                type='Asset', transaction_type='gold', tracks_weight=True,
            )
            db.session.add(gold)
            db.session.flush()

        if cash.memo_account_id != gold.id:
            link_accounts(cash, gold, created_by='test_parity_fixture')

        unlinked = Account.query.filter_by(account_number=_UNLINKED_NUM).first()
        if not unlinked:
            unlinked = Account(
                account_number=_UNLINKED_NUM, name='اختبار توزيع - بدون موازٍ',
                type='Asset', transaction_type='cash', tracks_weight=False,
            )
            db.session.add(unlinked)
            db.session.flush()

        db.session.commit()
        return {'cash_id': cash.id, 'gold_id': gold.id, 'unlinked_id': unlinked.id}


# ─── مساعدات ─────────────────────────────────────────────────────────────────

def _je_lines_summary(je_id: int) -> dict[int, dict[str, float]]:
    """تعيد قيم سطور القيد مُفهرسة بمعرف الحساب.
    يُستخدم للمقارنة بين مسارَي journals.py و create_dual_journal_entry."""
    _fields = (
        'cash_debit', 'cash_credit',
        'debit_18k', 'credit_18k',
        'debit_21k', 'credit_21k',
        'debit_22k', 'credit_22k',
        'debit_24k', 'credit_24k',
    )
    summary: dict[int, dict[str, float]] = {}
    for ln in JournalEntryLine.query.filter_by(journal_entry_id=je_id).all():
        acc_id = ln.account_id
        if acc_id not in summary:
            summary[acc_id] = {f: 0.0 for f in _fields}
        for f in _fields:
            summary[acc_id][f] += float(getattr(ln, f, 0) or 0)
    return summary


def _assert_summaries_equal(a: dict, b: dict, *, msg: str = '') -> None:
    prefix = f'[{msg}] ' if msg else ''
    assert set(a.keys()) == set(b.keys()), (
        f'{prefix}اختلاف في مجموعة الحسابات: {set(a.keys())} ≠ {set(b.keys())}'
    )
    for acc_id in a:
        for field, val in a[acc_id].items():
            assert abs(val - b[acc_id][field]) < 0.001, (
                f'{prefix}acc={acc_id} field={field}: {val} ≠ {b[acc_id][field]}'
            )


# ─── 1. اختبارات الوحدة — distribute_line() ──────────────────────────────────

class TestDistributeLineUnit:
    """يختبر distribute_line() مباشرة لكل حالة ممكنة."""

    def test_cash_with_gold_values_splits(self, pair_ids):
        """نقدي + وزن → الوزن يذهب للحساب الوزني الموازي، النقد يبقى."""
        with app.app_context():
            line = {'account_id': pair_ids['cash_id'], 'cash_debit': 500.0, 'debit_21k': 3.0}
            result = distribute_line(line)

        assert len(result) == 2
        cash_part = next(r for r in result if r['account_id'] == pair_ids['cash_id'])
        gold_part  = next(r for r in result if r['account_id'] == pair_ids['gold_id'])

        assert cash_part['cash_debit'] == 500.0
        assert cash_part.get('debit_21k', 0) == 0, 'الوزن يجب ألا يبقى في الحساب النقدي'
        assert gold_part['debit_21k'] == 3.0
        assert gold_part.get('cash_debit', 0) == 0, 'النقد يجب ألا ينتقل للحساب الوزني'

    def test_cash_only_no_split(self, pair_ids):
        """نقدي + نقد فقط → لا توزيع."""
        with app.app_context():
            line = {'account_id': pair_ids['cash_id'], 'cash_debit': 800.0}
            result = distribute_line(line)

        assert len(result) == 1
        assert result[0]['account_id'] == pair_ids['cash_id']
        assert result[0]['cash_debit'] == 800.0

    def test_gold_with_cash_values_splits(self, pair_ids):
        """وزني + نقد → النقد يذهب للحساب النقدي الموازي، الوزن يبقى."""
        with app.app_context():
            line = {'account_id': pair_ids['gold_id'], 'cash_credit': 1500.0, 'credit_24k': 5.0}
            result = distribute_line(line)

        assert len(result) == 2
        gold_part = next(r for r in result if r['account_id'] == pair_ids['gold_id'])
        cash_part = next(r for r in result if r['account_id'] == pair_ids['cash_id'])

        assert gold_part['credit_24k'] == 5.0
        assert gold_part.get('cash_credit', 0) == 0
        assert cash_part['cash_credit'] == 1500.0
        assert cash_part.get('credit_24k', 0) == 0

    def test_gold_only_no_split(self, pair_ids):
        """وزني + وزن فقط → لا توزيع."""
        with app.app_context():
            line = {'account_id': pair_ids['gold_id'], 'debit_18k': 2.5}
            result = distribute_line(line)

        assert len(result) == 1
        assert result[0]['account_id'] == pair_ids['gold_id']

    def test_no_memo_account_no_split(self, pair_ids):
        """حساب بدون موازٍ → لا توزيع مهما كانت القيم."""
        with app.app_context():
            line = {'account_id': pair_ids['unlinked_id'], 'cash_debit': 100.0, 'debit_21k': 1.0}
            result = distribute_line(line)

        assert len(result) == 1
        assert result[0] == line

    def test_cash_gold_only_cash_part_dropped(self, pair_ids):
        """نقدي + وزن فقط (لا نقد) → السطر الأصلي يُحذف لأنه أصبح فارغاً."""
        with app.app_context():
            line = {'account_id': pair_ids['cash_id'], 'debit_22k': 4.0}
            result = distribute_line(line)

        assert len(result) == 1
        assert result[0]['account_id'] == pair_ids['gold_id']
        assert result[0]['debit_22k'] == 4.0

    def test_karat_isolation_no_cross_contamination(self, pair_ids):
        """قيم عياريات متعددة على حساب نقدي → تنتقل كلها للموازي بدون خلط."""
        with app.app_context():
            line = {
                'account_id': pair_ids['cash_id'],
                'cash_debit': 200.0,
                'debit_18k': 1.5,
                'credit_21k': 0.5,
            }
            result = distribute_line(line)

        assert len(result) == 2
        gold_part = next(r for r in result if r['account_id'] == pair_ids['gold_id'])
        assert gold_part['debit_18k'] == 1.5
        assert gold_part['credit_21k'] == 0.5
        for f in CASH_FIELDS:
            assert gold_part.get(f, 0) == 0, f'الحساب الوزني يجب ألا يحمل {f}'


# ─── 2. اختبارات idempotency — distribute_lines() ────────────────────────────

class TestDistributeLinesIdempotency:
    """distribute_lines() لا تُكرر التوزيع إذا كان الزوج موجوداً مسبقاً."""

    def test_both_sides_present_no_extra_distribution(self, pair_ids):
        """كلا الحسابَين مُدرجَان صراحةً → لا توزيع إضافي."""
        with app.app_context():
            lines = [
                {'account_id': pair_ids['cash_id'], 'cash_debit': 100.0, 'debit_21k': 2.0},
                {'account_id': pair_ids['gold_id'], 'credit_21k': 2.0},
            ]
            result = distribute_lines(lines)

        ids = [r['account_id'] for r in result]
        assert ids.count(pair_ids['cash_id']) <= 1
        assert ids.count(pair_ids['gold_id']) <= 1
        assert len(result) == 2

    def test_single_mixed_line_gets_distributed(self, pair_ids):
        """سطر واحد بقيم مختلطة على حساب نقدي → يُوزَّع تلقائياً."""
        with app.app_context():
            lines = [
                {'account_id': pair_ids['cash_id'], 'cash_debit': 50.0, 'debit_24k': 1.0},
            ]
            result = distribute_lines(lines)

        assert len(result) == 2
        account_ids = {r['account_id'] for r in result}
        assert pair_ids['cash_id'] in account_ids
        assert pair_ids['gold_id'] in account_ids

    def test_unlinked_account_passes_through_unchanged(self, pair_ids):
        """حساب بدون موازٍ يمر دون تعديل."""
        with app.app_context():
            lines = [
                {'account_id': pair_ids['unlinked_id'], 'cash_debit': 300.0, 'debit_21k': 2.0},
            ]
            result = distribute_lines(lines)

        assert len(result) == 1
        assert result[0] == lines[0]


# ─── 3. اختبارات التكافؤ (parity) بين المسارَين ─────────────────────────────

class TestDistributionParity:
    """
    نفس المُدخَل → نفس توزيع القيد عبر كلا المسارَين:
      create_dual_journal_entry (dual_system_helpers.py) ← مسار الفواتير/السندات
      journals.py POST endpoint                          ← مسار القيود اليدوية
    """

    def _via_helper(self, cash_id: int, **kwargs) -> dict:
        """ينشئ قيداً عبر create_dual_journal_entry، يعيد ملخص السطور، يتراجع."""
        with app.app_context():
            je = JournalEntry(date=date.today(), description='parity-helper')
            db.session.add(je)
            db.session.flush()
            create_dual_journal_entry(journal_entry_id=je.id, account_id=cash_id, **kwargs)
            db.session.flush()
            summary = _je_lines_summary(je.id)
            db.session.rollback()
        return summary

    def _via_api(self, cash_id: int, client, **line_fields) -> dict:
        """ينشئ قيداً عبر POST /api/journal_entries (مسودة)، يعيد ملخص السطور، يُنظّف."""
        payload = {
            'description': 'parity-api',
            'date': date.today().isoformat(),
            'is_draft': True,
            'lines': [{'account_id': cash_id, **line_fields}],
        }
        r = client.post('/api/journal_entries', json=payload)
        assert r.status_code == 201, f'journals POST فشل: {r.get_json()}'
        je_id = r.get_json()['id']
        with app.app_context():
            summary = _je_lines_summary(je_id)
            JournalEntryLine.query.filter_by(journal_entry_id=je_id).delete()
            purge(lambda: JournalEntry.query.filter_by(id=je_id).delete())
            db.session.commit()
        return summary

    def test_parity_cash_with_weight(self, pair_ids):
        """نقدي + وزن: كلا المسارَين يُنتجان نفس التوزيع."""
        cash_id = pair_ids['cash_id']

        helper = self._via_helper(
            cash_id,
            cash_debit=500.0,
            weight_21k_debit=3.0,
        )

        with _client() as c:
            api = self._via_api(cash_id, c, cash_debit=500.0, debit_21k=3.0)

        _assert_summaries_equal(helper, api, msg='نقدي+وزن')

        # تحقق صريح من القيم المتوقعة
        assert helper[cash_id]['cash_debit'] == pytest.approx(500.0)
        assert helper[pair_ids['gold_id']]['debit_21k'] == pytest.approx(3.0)
        assert helper[cash_id].get('debit_21k', 0) == pytest.approx(0.0)

    def test_parity_pure_cash_no_split(self, pair_ids):
        """نقدي فقط: كلا المسارَين لا يُجريان توزيعاً."""
        cash_id = pair_ids['cash_id']
        gold_id = pair_ids['gold_id']

        helper = self._via_helper(cash_id, cash_debit=750.0)
        assert gold_id not in helper, 'المسار المساعد لا يُوزّع النقد للحساب الوزني'

        with _client() as c:
            api = self._via_api(cash_id, c, cash_debit=750.0)
        assert gold_id not in api, 'مسار journals.py لا يُوزّع النقد للحساب الوزني'

        _assert_summaries_equal(helper, api, msg='نقدي-فقط')

    def test_parity_cash_with_weight_multiple_karats(self, pair_ids):
        """نقدي + عياريات متعددة: التوزيع متطابق عبر المسارَين."""
        cash_id = pair_ids['cash_id']

        helper = self._via_helper(
            cash_id,
            cash_debit=1000.0,
            weight_18k_debit=1.5,
            weight_21k_debit=2.0,
            weight_24k_debit=0.75,
        )

        with _client() as c:
            api = self._via_api(
                cash_id, c,
                cash_debit=1000.0,
                debit_18k=1.5,
                debit_21k=2.0,
                debit_24k=0.75,
            )

        _assert_summaries_equal(helper, api, msg='عياريات-متعددة')

        gold_id = pair_ids['gold_id']
        for field, expected in [('debit_18k', 1.5), ('debit_21k', 2.0), ('debit_24k', 0.75)]:
            assert helper[gold_id][field] == pytest.approx(expected), f'helper: {field}'
            assert api[gold_id][field]    == pytest.approx(expected), f'api: {field}'

    def test_parity_gold_only_no_split(self, pair_ids):
        """وزن فقط على حساب نقدي (صفر نقد): السطر الأصلي يُحذف، متطابق عبر المسارَين."""
        cash_id = pair_ids['cash_id']
        gold_id = pair_ids['gold_id']

        # المسار المساعد يستقبل account_id=cash_id لكن القيم وزنية فقط
        helper = self._via_helper(cash_id, weight_22k_credit=4.0)

        with _client() as c:
            api = self._via_api(cash_id, c, credit_22k=4.0)

        # لا يجب أن يظهر الحساب النقدي (لا قيمة نقدية)
        assert cash_id not in helper, f'الحساب النقدي يجب أن يُحذف من ملخص helper: {helper}'
        assert cash_id not in api,    f'الحساب النقدي يجب أن يُحذف من ملخص api: {api}'
        assert gold_id in helper
        assert gold_id in api
        assert helper[gold_id]['credit_22k'] == pytest.approx(4.0)
        assert api[gold_id]['credit_22k']    == pytest.approx(4.0)

    def test_parity_unlinked_account_passes_through(self, pair_ids):
        """حساب بدون موازٍ: كلا المسارَين لا يُجريان توزيعاً."""
        unlinked_id = pair_ids['unlinked_id']

        helper = self._via_helper(unlinked_id, cash_debit=200.0)

        with _client() as c:
            api = self._via_api(unlinked_id, c, cash_debit=200.0)

        _assert_summaries_equal(helper, api, msg='بدون-موازٍ')
        assert unlinked_id in helper
        assert helper[unlinked_id]['cash_debit'] == pytest.approx(200.0)
