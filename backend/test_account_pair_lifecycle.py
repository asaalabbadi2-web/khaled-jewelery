"""
test_account_pair_lifecycle.py  —  P3: Lifecycle Tests
=======================================================
يختبر دورة الحياة الكاملة لنظام الحسابات المزدوجة.

نطاق الأرقام المحجوز لهذا الملف:
  3870 / 73870  —  زوج أ (توزيع مزدوج + أرصدة)
  3871 / 73871  —  زوج ب (الطرف المقابل)
  3872 / 73872  —  remove→recreate→relink
  3873 / 73873  —  رفض الإزالة (موازي له JE lines)
  3876 / 73876  —  رفض الإزالة (موازي له أبناء)
  3874 / 73874  —  UNIQUE constraint (PostgreSQL فقط)
  3875 / 73875  —  ON DELETE SET NULL (PostgreSQL فقط)

مبدأ: كل اختبار مستقل — لا اعتماد على حالة من اختبار سابق.
"""
from __future__ import annotations

import datetime
import os

import pytest

from app import app
from models import Account, AuditLog, JournalEntry, JournalEntryLine, db
from tests.cleanup import purge  # UNPOST-001 U3: cleanup of posted rows is a purge

_IS_POSTGRES = os.getenv('PYTEST_ALLOW_REAL_DB', '').strip() in ('1', 'true', 'yes')


# ─── مساعدات ─────────────────────────────────────────────────────────────────


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

def _make_account(number: str, name: str, *, transaction_type: str = 'cash',
                  tracks_weight: bool = False, parent_id: int | None = None) -> Account:
    acc = Account(
        account_number=number, name=name, type='Asset',
        transaction_type=transaction_type, tracks_weight=tracks_weight,
        parent_id=parent_id,
        balance_cash=0.0, balance_18k=0.0, balance_21k=0.0,
        balance_22k=0.0, balance_24k=0.0,
    )
    db.session.add(acc)
    db.session.flush()
    return acc


def _link(cash_acc: Account, gold_acc: Account) -> None:
    from account_pair_service import link_accounts
    link_accounts(cash_acc, gold_acc, created_by='lifecycle_test')


def _get_or_create_pair(cash_num: str, gold_num: str,
                        cash_name: str, gold_name: str):
    """يجلب زوجاً مرتبطاً أو ينشئه. يعيد (cash, gold) بعد commit."""
    cash = Account.query.filter_by(account_number=cash_num).first()
    gold = Account.query.filter_by(account_number=gold_num).first()
    needs_link = False
    if cash is None:
        cash = _make_account(cash_num, cash_name)
        needs_link = True
    if gold is None:
        gold = _make_account(gold_num, gold_name,
                             transaction_type='gold', tracks_weight=True)
        needs_link = True
    if needs_link or cash.memo_account_id != gold.id:
        _link(cash, gold)
    db.session.commit()
    return cash, gold


def _wipe_accounts(*numbers: str) -> None:
    """يحذف الحسابات بأرقامها — يُفسخ الربط أولاً لتجنب FK violations.

    And the entries earlier tests posted on them first: SQLite does not enforce
    foreign keys, PostgreSQL refuses to delete an account its lines still name
    (TEST-001)."""
    from models import JournalEntry, JournalEntryLine
    accs = Account.query.filter(Account.account_number.in_(numbers)).all()
    ids = [a.id for a in accs]
    if ids:
        entry_ids = [r[0] for r in db.session.query(JournalEntryLine.journal_entry_id)
                     .filter(JournalEntryLine.account_id.in_(ids)).distinct().all()]
        if entry_ids:
            JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entry_ids)).delete(
                synchronize_session=False)
            purge(lambda: JournalEntry.query.filter(JournalEntry.id.in_(entry_ids)).delete(synchronize_session=False))
            db.session.flush()
    for a in accs:
        a.memo_account_id = None
        db.session.add(a)
    db.session.flush()
    for a in accs:
        db.session.delete(a)
    db.session.commit()


def _create_je_via_api(client, lines: list[dict], *, is_draft: bool = False) -> int:
    payload = {
        'description': 'lifecycle-test',
        'date': datetime.date.today().isoformat(),
        'is_draft': is_draft,
        'lines': lines,
    }
    r = client.post('/api/journal_entries', json=payload)
    assert r.status_code == 201, f'JE POST فشل: {r.get_json()}'
    return r.get_json()['id']


def _je_lines_for(je_id: int) -> dict[int, dict]:
    result: dict[int, dict] = {}
    for ln in JournalEntryLine.query.filter_by(journal_entry_id=je_id).all():
        result[ln.account_id] = {
            'cash_debit':  float(ln.cash_debit  or 0),
            'cash_credit': float(ln.cash_credit or 0),
            'debit_21k':   float(ln.debit_21k   or 0),
            'credit_21k':  float(ln.credit_21k  or 0),
        }
    return result


# ─── 1. التوزيع المزدوج والأرصدة ─────────────────────────────────────────────

class TestDualDistributionAndBalances:
    """يثبت أن الوزن يُوزَّع للموازي تلقائياً والأرصدة تتحدث بعد القيد المنشور."""

    def test_gold_fields_routed_to_parallel_account(self):
        """معاملة على حساب نقدي بقيم وزنية → تُوزَّع للموازي، الحساب النقدي يحتفظ بالنقد فقط."""
        with app.app_context():
            _wipe_accounts('3870', '73870', '3871', '73871')
            cash_a, gold_a = _get_or_create_pair(
                '3870', '73870', 'دورة حياة - نقدي أ', 'دورة حياة - وزني أ')
            cash_b, gold_b = _get_or_create_pair(
                '3871', '73871', 'دورة حياة - نقدي ب', 'دورة حياة - وزني ب')
            cash_a_id = cash_a.id
            gold_a_id = gold_a.id
            cash_b_id = cash_b.id
            gold_b_id = gold_b.id

        with _client() as c:
            je_id = _create_je_via_api(c, lines=[
                {'account_id': cash_a_id, 'cash_debit': 500.0, 'debit_21k': 3.0},
                {'account_id': cash_b_id, 'cash_credit': 500.0, 'credit_21k': 3.0},
            ])

        with app.app_context():
            lines = _je_lines_for(je_id)
            # النقدي أ: نقد فقط
            assert cash_a_id in lines
            assert lines[cash_a_id]['cash_debit']  == pytest.approx(500.0)
            assert lines[cash_a_id]['debit_21k']   == pytest.approx(0.0), \
                'الوزن يجب أن يُنقَل للموازي لا يبقى في النقدي'
            # الوزني أ: وزن فقط
            assert gold_a_id in lines, 'سطر الوزني أ غائب — التوزيع فشل'
            assert lines[gold_a_id]['debit_21k']   == pytest.approx(3.0)
            assert lines[gold_a_id]['cash_debit']  == pytest.approx(0.0)
            # النقدي ب: نقد فقط
            assert cash_b_id in lines
            assert lines[cash_b_id]['cash_credit'] == pytest.approx(500.0)
            assert lines[cash_b_id]['credit_21k']  == pytest.approx(0.0)
            # الوزني ب: وزن فقط
            assert gold_b_id in lines, 'سطر الوزني ب غائب'
            assert lines[gold_b_id]['credit_21k']  == pytest.approx(3.0)

    def test_balances_updated_after_posted_je(self):
        """ترحيل القيد (is_posted=True) يُحدِّث أرصدة النقد والوزن بشكل صحيح.

        ملاحظة: is_posted=False افتراضياً عند الإنشاء (الترحيل خطوة مستقلة في هذا النظام).
        يُحاكي الاختبار خطوة الترحيل مباشرةً للتحقق من آلية الحساب.
        """
        from accounting.balances import _recalculate_account_balances_for_accounts

        with app.app_context():
            _wipe_accounts('3870', '73870', '3871', '73871')
            cash_a, gold_a = _get_or_create_pair(
                '3870', '73870', 'دورة حياة - نقدي أ', 'دورة حياة - وزني أ')
            cash_b, _ = _get_or_create_pair(
                '3871', '73871', 'دورة حياة - نقدي ب', 'دورة حياة - وزني ب')
            cash_a_id = cash_a.id
            cash_b_id = cash_b.id

        with _client() as c:
            je_id = _create_je_via_api(c, lines=[
                {'account_id': cash_a_id, 'cash_debit': 200.0, 'debit_21k': 1.0},
                {'account_id': cash_b_id, 'cash_credit': 200.0, 'credit_21k': 1.0},
            ])

        with app.app_context():
            # محاكاة الترحيل: ضع is_posted=True ثم أعد الحساب
            je = JournalEntry.query.get(je_id)
            je.is_posted = True
            db.session.flush()
            lines = JournalEntryLine.query.filter_by(journal_entry_id=je_id).all()
            affected_ids = {ln.account_id for ln in lines}
            _recalculate_account_balances_for_accounts(affected_ids)
            db.session.commit()

            cash_a = Account.query.filter_by(account_number='3870').first()
            gold_a = Account.query.filter_by(account_number='73870').first()
            assert cash_a.balance_cash >= 200.0, \
                f'رصيد النقدي يجب ≥ 200، وجد {cash_a.balance_cash}'
            assert gold_a.balance_21k >= 1.0, \
                f'رصيد الوزن (21k) يجب ≥ 1.0، وجد {gold_a.balance_21k}'
            assert cash_a.balance_21k == pytest.approx(0.0), \
                'الحساب النقدي يجب ألا يكسب رصيداً وزنياً'

    def test_cash_account_never_accumulates_weight_balance(self):
        """الحساب النقدي (tracks_weight=False) لا يكسب رصيداً وزنياً."""
        with app.app_context():
            _wipe_accounts('3870', '73870', '3871', '73871')
            cash_a, _ = _get_or_create_pair(
                '3870', '73870', 'دورة حياة - نقدي أ', 'دورة حياة - وزني أ')
            cash_b, _ = _get_or_create_pair(
                '3871', '73871', 'دورة حياة - نقدي ب', 'دورة حياة - وزني ب')
            cash_a_id = cash_a.id
            cash_b_id = cash_b.id

        with _client() as c:
            _create_je_via_api(c, lines=[
                {'account_id': cash_a_id, 'cash_debit': 100.0, 'debit_21k': 0.5},
                {'account_id': cash_b_id, 'cash_credit': 100.0, 'credit_21k': 0.5},
            ])

        with app.app_context():
            cash_a = Account.query.filter_by(account_number='3870').first()
            assert cash_a.tracks_weight is False
            assert cash_a.balance_21k == pytest.approx(0.0), \
                'الحساب النقدي يجب ألا يحمل رصيداً وزنياً أبداً'

    def test_next_number_endpoint_reports_parent_has_parallel(self):
        """GET /accounts/next-number/<parent> يُشير لوجود الموازي في الأب."""
        with app.app_context():
            _wipe_accounts('3870', '73870')
            _get_or_create_pair('3870', '73870', 'دورة حياة - نقدي أ', 'دورة حياة - وزني أ')

        with _client() as c:
            r = c.get('/api/accounts/next-number/3870')
            assert r.status_code == 200
            body = r.get_json()
            assert body.get('parent_has_parallel') is True
            assert body.get('suggested_parallel_number') is not None


# ─── 2. remove → recreate → relink ──────────────────────────────────────────

class TestRemoveRecreateRelink:
    """
    دورة كاملة مستقلة: إنشاء زوج → إزالة الموازي → إنشاء موازٍ جديد → ربط.
    يثبت 7 إثباتات: id / تاريخ / رصيد / ربط / audit / توزيع جديد.
    """

    def test_full_cycle(self):
        with app.app_context():
            _wipe_accounts('3872', '73872', '73872B')
            cash = _make_account('3872', 'اختبار relink - نقدي')
            gold = _make_account('73872', 'اختبار relink - وزني',
                                 transaction_type='gold', tracks_weight=True)
            _link(cash, gold)
            db.session.commit()
            cash_id     = cash.id
            old_gold_id = gold.id

        # خطوة 1: إزالة الموازي
        with _client() as c:
            r = c.post(f'/api/accounts/{cash_id}/remove-parallel')
            assert r.status_code == 200, r.get_json()

        with app.app_context():
            primary = Account.query.get(cash_id)
            assert primary is not None,            '① الحساب الأساسي اختفى'
            assert primary.memo_account_id is None, '① الأساسي يجب memo=None بعد الإزالة'
            assert Account.query.get(old_gold_id) is None, '① الموازي القديم يجب حذفه'

        # خطوة 2: إنشاء موازٍ جديد وربطه
        with app.app_context():
            primary = Account.query.get(cash_id)
            new_gold = _make_account('73872B', 'اختبار relink - موازي جديد',
                                     transaction_type='gold', tracks_weight=True)
            new_gold_id = new_gold.id
            _link(primary, new_gold)
            db.session.commit()

        # خطوة 3: 7 إثباتات
        with app.app_context():
            primary  = Account.query.get(cash_id)
            new_gold = Account.query.get(new_gold_id)

            # ② رقم الحساب الجديد مختلف (id قد يتطابق في SQLite بسبب إعادة الاستخدام)
            assert new_gold.account_number == '73872B', '② رقم الحساب الجديد يجب 73872B'
            # ③ الربط صحيح في الاتجاهين
            assert primary.memo_account_id  == new_gold_id, '③ ربط الأساسي → الجديد'
            assert new_gold.memo_account_id == cash_id,     '③ ربط الجديد → الأساسي'
            # ④ رصيد الموازي الجديد صفر
            assert new_gold.balance_cash == pytest.approx(0.0), '④ رصيد نقدي'
            assert new_gold.balance_21k  == pytest.approx(0.0), '④ رصيد 21k'
            # ⑤ لا سطور قيود تاريخية
            je_count = JournalEntryLine.query.filter_by(account_id=new_gold_id).count()
            assert je_count == 0, f'⑤ الحساب الجديد يحمل {je_count} سطراً تاريخياً'
            # ⑥ سجل المراجعة يحتوي الثلاثة أحداث
            logs    = (AuditLog.query
                       .filter_by(entity_type='Account', entity_id=cash_id)
                       .order_by(AuditLog.id.asc()).all())
            actions = [l.action for l in logs]
            assert 'unlink_account_pair'     in actions, f'⑥ سجل الفسخ غائب: {actions}'
            assert 'remove_parallel_account' in actions, f'⑥ سجل الإزالة غائب: {actions}'
            assert 'link_account_pair'       in actions, f'⑥ سجل الربط الجديد غائب: {actions}'

        # ⑦ قيد جديد يُوزَّع للموازي الجديد
        with app.app_context():
            primary  = Account.query.get(cash_id)
            new_gold = Account.query.get(new_gold_id)
            cpart, gold_cpart = _get_or_create_pair(
                '3870', '73870', 'دورة حياة - نقدي أ', 'دورة حياة - وزني أ')
            cpart_id = cpart.id
            gc_id    = gold_cpart.id

        with _client() as c:
            je_id = _create_je_via_api(c, lines=[
                {'account_id': cash_id,   'cash_debit': 300.0, 'debit_21k': 2.0},
                {'account_id': cpart_id,  'cash_credit': 300.0, 'credit_21k': 2.0},
            ])

        with app.app_context():
            lines = _je_lines_for(je_id)
            assert new_gold_id in lines, '⑦ الوزن لم يُوزَّع للموازي الجديد'
            assert lines[new_gold_id]['debit_21k'] == pytest.approx(2.0), '⑦ قيمة الوزن'
            # تأكد أن الحساب الذي حصل على الوزن هو 73872B (لا 73872 المحذوف)
            # في SQLite قد يُعاد استخدام id المحذوف، لذا نتحقق برقم الحساب
            distributed_acc = Account.query.get(new_gold_id)
            assert distributed_acc is not None, '⑦ الحساب الموزَّع إليه غير موجود في DB'
            assert distributed_acc.account_number == '73872B', \
                f'⑦ الوزن وُزِّع لحساب رقمه {distributed_acc.account_number} بدلاً من 73872B'


# ─── 3. رفض الإزالة بوجود تبعيات ────────────────────────────────────────────

class TestRemovalBlockedByDependencies:
    """يثبت أن الإزالة تُرفض بوجود تبعيات، والزوج يبقى سليماً بعد الرفض."""

    def test_parallel_with_je_lines_rejected_409(self):
        """موازٍ له JE lines → 409 PARALLEL_HAS_JE_LINES والزوج يبقى."""
        with app.app_context():
            _wipe_accounts('3873', '73873')
            cash = _make_account('3873', 'اختبار رفض JE - نقدي')
            gold = _make_account('73873', 'اختبار رفض JE - وزني',
                                 transaction_type='gold', tracks_weight=True)
            _link(cash, gold)
            je = JournalEntry(date=datetime.date.today(),
                              description='test-block', is_draft=True)
            db.session.add(je)
            db.session.flush()
            db.session.add(JournalEntryLine(
                journal_entry_id=je.id, account_id=gold.id, debit_21k=3.0))
            db.session.commit()
            cash_id, gold_id = cash.id, gold.id

        with _client() as c:
            r = c.post(f'/api/accounts/{cash_id}/remove-parallel')
            assert r.status_code == 409
            assert r.get_json()['error'] == 'PARALLEL_HAS_JE_LINES'

        with app.app_context():
            cash = Account.query.get(cash_id)
            gold = Account.query.get(gold_id)
            assert cash is not None and gold is not None, 'حساب اختفى بعد الرفض'
            assert cash.memo_account_id == gold_id,  'الرابط المباشر تغيّر'
            assert gold.memo_account_id == cash_id,  'الرابط العكسي تغيّر'
            assert gold.balance_21k == pytest.approx(0.0), 'رصيد الوزن تغيّر (القيد كان مسودة)'

    def test_parallel_with_children_rejected_409(self):
        """موازٍ له حسابات فرعية → 409 PARALLEL_HAS_CHILDREN."""
        with app.app_context():
            _wipe_accounts('3876', '73876', '738760')
            cash = _make_account('3876', 'اختبار رفض أبناء - نقدي')
            gold = _make_account('73876', 'اختبار رفض أبناء - وزني',
                                 transaction_type='gold', tracks_weight=True)
            _link(cash, gold)
            _make_account('738760', 'ابن الوزني',
                          transaction_type='gold', tracks_weight=True, parent_id=gold.id)
            db.session.commit()
            cash_id = cash.id

        with _client() as c:
            r = c.post(f'/api/accounts/{cash_id}/remove-parallel')
            assert r.status_code == 409
            assert r.get_json()['error'] == 'PARALLEL_HAS_CHILDREN'


# ─── 4. قيود مستوى DB (PostgreSQL فقط) ───────────────────────────────────────

@pytest.mark.skipif(not _IS_POSTGRES,
                    reason='يحتاج PostgreSQL — شغّل مع PYTEST_ALLOW_REAL_DB=1')
class TestDatabaseConstraints:
    """يثبت أن UNIQUE(memo_account_id) وON DELETE SET NULL يعملان على مستوى DB."""

    def test_unique_constraint_prevents_duplicate_memo_target(self):
        """UNIQUE(memo_account_id): حسابان لا يشيران لنفس الموازي."""
        from sqlalchemy.exc import IntegrityError
        with app.app_context():
            _wipe_accounts('3874', '38741', '73874')
            cash1 = _make_account('3874',  'UNIQUE - نقدي 1')
            cash2 = _make_account('38741', 'UNIQUE - نقدي 2')
            gold  = _make_account('73874', 'UNIQUE - وزني',
                                  transaction_type='gold', tracks_weight=True)
            cash1.memo_account_id = gold.id
            gold.memo_account_id  = cash1.id
            db.session.flush()
            db.session.commit()

            cash2.memo_account_id = gold.id
            try:
                db.session.flush()
                db.session.rollback()
                pytest.fail('UNIQUE constraint لم يرفض duplicate memo_account_id')
            except IntegrityError:
                db.session.rollback()

    def test_on_delete_set_null_clears_pointer_on_direct_delete(self):
        """FK ON DELETE SET NULL: حذف مباشر للحساب يُصفّر الإشارة إليه."""
        with app.app_context():
            _wipe_accounts('3875', '73875')
            cash = _make_account('3875', 'SET NULL - نقدي')
            gold = _make_account('73875', 'SET NULL - وزني',
                                 transaction_type='gold', tracks_weight=True)
            cash.memo_account_id = gold.id
            gold.memo_account_id = cash.id
            db.session.flush()
            db.session.commit()
            cash_id, gold_id = cash.id, gold.id

        with app.app_context():
            gold = Account.query.get(gold_id)
            db.session.delete(gold)
            db.session.commit()

            cash = Account.query.get(cash_id)
            assert cash.memo_account_id is None, \
                'ON DELETE SET NULL لم يُصفّر memo_account_id بعد الحذف المباشر'
