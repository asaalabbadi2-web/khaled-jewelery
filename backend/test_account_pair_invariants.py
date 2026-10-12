"""اختبارات تكاملية لضمان أن علاقة Account.memo_account_id تبقى محكومة دائماً:
كل إنشاء/تعديل يمر عبر account_pair_service فقط، والحارس على مستوى ORM
يرفض ما يتجاوزها، وأن التصنيف المشترك (account_pair_invariants.classify --
نفس الدالة التي يستخدمها audit_account_memo_invariants.py على الإنتاج
وrepair_all_memo_account_links.py للإصلاح) لا يُخرج أي مخالفة بعد أي عملية
إنشاء أو ربط أو فسخ.

السياق: حادثة حساب #1213 (مكتب تسكير فورية واشخاص) تراكمت شهوراً دون أن
يُلاحَظ أحد أن قيدها المالي يشير لحساب متروك بدل الحساب الوزني الصحيح --
لأنه لم يكن هناك أي اختبار يفحص هذه العلاقة. هذا الملف يمنع عودة هذا الصنف
من الخلل صمتاً: أي موضع كتابة (33 موضعاً رُحِّلت جميعها، أو أي موضع جديد
مستقبلي) يتجاوز account_pair_service سيُظهر أثره هنا فوراً، قبل النشر.

استخدام account_pair_invariants.classify() هنا (لا نسخة منفصلة من منطق
الفحص) مقصود: لو اختلف معيار "ما يُعتبر مخالفة" بين الاختبارات وأداة
التدقيق المستخدمة على الإنتاج، يفقد الاختباران قيمتهما الحقيقية.
"""

import pytest

from app import app
from models import db, Account, Supplier, Customer, Office
from party_account_service import ensure_supplier_accounts, ensure_customer_accounts
from office_account_service import ensure_office_account
from employee_account_helpers import create_employee_account, get_or_create_employee_payables_accounts
from account_pair_service import link_accounts, unlink_account, AccountPairLinkError
from account_pair_invariants import classify as _classify


def _no_violations(all_accounts) -> bool:
    """True فقط لو لم توجد أي مخالفة إطلاقاً (لا HIGH قابل للإصلاح، ولا
    MANUAL يحتاج مراجعة) -- نفس القواعد الخمس المستخدمة في
    audit_account_memo_invariants.py وrepair_all_memo_account_links.py
    (كليهما يستوردان account_pair_invariants.classify، لا نسخة محلية)."""
    return len(_classify(all_accounts)['decisions']) == 0


def _ensure_account_number(number, *, name, acc_type, tracks_weight=False):
    acc = Account.query.filter_by(account_number=str(number)).first()
    if acc:
        return acc
    acc = Account(
        account_number=str(number), name=name, type=acc_type,
        transaction_type='cash', tracks_weight=tracks_weight,
    )
    db.session.add(acc)
    db.session.flush()
    return acc


def test_new_supplier_account_pair_is_valid_and_audit_clean():
    """إنشاء مورد جديد عبر ensure_supplier_accounts (المسار الحقيقي
    المستخدم في offices_routes.py وغيره) يجب أن يولّد زوجاً صحيحاً
    (ثنائي الاتجاه، أنواع مختلفة)، ولا يُخرج التدقيق أي مخالفة بعده."""
    with app.app_context():
        supplier_root = _ensure_account_number(
            '2100-T1', name='حسابات موردو ذهب اختبار', acc_type='Liability'
        )
        supplier = Supplier(
            supplier_code='S-PAIRTEST-001', name='مورد اختبار ربط',
            account_category_id=supplier_root.id,
        )
        db.session.add(supplier)
        db.session.flush()

        ensure_supplier_accounts(supplier)
        db.session.commit()

        financial = db.session.get(Account, supplier.account_id)
        assert financial is not None
        weight = db.session.get(Account, financial.memo_account_id)
        assert weight is not None, "الحساب المالي الجديد يجب أن يملك memo_account_id"
        assert weight.memo_account_id == financial.id, "الربط يجب أن يكون ثنائي الاتجاه"
        assert bool(financial.tracks_weight) != bool(weight.tracks_weight), "النوعان يجب أن يختلفا"

        assert _no_violations(Account.query.all()), "التدقيق يجب أن يكون نظيفاً تماماً بعد إنشاء مورد جديد"


def test_new_customer_account_pair_is_valid_and_audit_clean():
    """نفس الضمان لمسار العميل (ensure_customer_accounts)."""
    with app.app_context():
        category = _ensure_account_number(
            '1200-T1', name='حسابات العملاء اختبار', acc_type='Asset'
        )
        customer = Customer(
            customer_code='C-PAIRTEST-001', name='عميل اختبار ربط',
            account_category_id=category.id,
        )
        db.session.add(customer)
        db.session.flush()

        ensure_customer_accounts(customer)
        db.session.commit()

        financial = db.session.get(Account, customer.account_id)
        assert financial is not None
        if financial.memo_account_id is not None:
            weight = db.session.get(Account, financial.memo_account_id)
            assert weight is not None
            assert weight.memo_account_id == financial.id
            assert bool(financial.tracks_weight) != bool(weight.tracks_weight)

        assert _no_violations(Account.query.all())


def test_new_office_account_pair_is_valid_and_audit_clean():
    """نفس الضمان لمسار المكتب (ensure_office_account -> _ensure_memo_account_for_office_account)."""
    with app.app_context():
        office = Office(office_code='O-PAIRTEST-001', name='مكتب اختبار ربط')
        db.session.add(office)
        db.session.flush()

        financial = ensure_office_account(office, auto_commit=True)

        assert financial is not None
        assert financial.memo_account_id is not None, "الحساب المالي للمكتب يجب أن يملك memo_account_id"
        weight = db.session.get(Account, financial.memo_account_id)
        assert weight is not None
        assert weight.memo_account_id == financial.id, "الربط يجب أن يكون ثنائي الاتجاه"
        assert bool(financial.tracks_weight) != bool(weight.tracks_weight)

        assert _no_violations(Account.query.all())


def test_new_employee_account_pair_is_valid_and_audit_clean():
    """ensure_memo_for_account (عبر create_employee_account) كانت تضبط
    fin_account.memo_account_id فقط، بلا أي تحديث لمؤشر الحساب الوزني نفسه
    -- السبب الجذري لعشرات حالات one_way_link لحسابات الموظفين المكتشفة
    على الإنتاج (راجع repair_all_memo_account_links.py)."""
    with app.app_context():
        account = create_employee_account('موظف اختبار ربط', department='administration')
        db.session.commit()

        assert account.memo_account_id is not None, "الحساب الشخصي للموظف يجب أن يملك memo_account_id"
        weight = db.session.get(Account, account.memo_account_id)
        assert weight is not None
        assert weight.memo_account_id == account.id, "الربط يجب أن يكون ثنائي الاتجاه"
        assert bool(account.tracks_weight) != bool(weight.tracks_weight)

        assert _no_violations(Account.query.all())


def test_new_employee_payables_accounts_are_valid_and_audit_clean():
    """حسابات ذمم الموظفين (2400/2410/2420/2310) نقدية: لا توأم وزني لها
    (CHART-001، المالك 12 أكتوبر 2026: «صحح الجميع» -- صُنع 26 توأمًا لم
    يُستعمل أيٌّ منها)، والتدقيق نظيف بعدها كما قبلها."""
    with app.app_context():
        accounts = get_or_create_employee_payables_accounts('موظف اختبار ذمم')
        db.session.commit()

        assert len(accounts) > 0
        for acc in accounts:
            assert acc.memo_account_id is None, f"#{acc.id} نقدي: لا توأم وزني"
            assert not acc.tracks_weight

        assert _no_violations(Account.query.all())


def test_link_accounts_rejects_self_reference():
    """account_pair_service.link_accounts يجب أن يرفض ربط حساب بنفسه."""
    with app.app_context():
        acc = _ensure_account_number('TEST-SELFREF', name='حساب اختبار self', acc_type='Asset')
        db.session.commit()
        with pytest.raises(AccountPairLinkError):
            link_accounts(acc, acc, created_by='pytest')


def test_link_accounts_rejects_same_type():
    """لا يجوز ربط حسابين من نفس قيمة tracks_weight."""
    with app.app_context():
        a = _ensure_account_number('TEST-SAMETYPE-A', name='حساب اختبار نوع أ', acc_type='Asset', tracks_weight=False)
        b = _ensure_account_number('TEST-SAMETYPE-B', name='حساب اختبار نوع ب', acc_type='Asset', tracks_weight=False)
        db.session.commit()
        with pytest.raises(AccountPairLinkError):
            link_accounts(a, b, created_by='pytest')


def test_orm_guard_rejects_direct_self_reference_assignment():
    """الحارس على مستوى @validates (models.py) يجب أن يرفض حتى لو لم
    يُستخدَم account_pair_service إطلاقاً -- خط الدفاع الثاني."""
    with app.app_context():
        acc = _ensure_account_number('TEST-ORMGUARD', name='حساب اختبار حارس ORM', acc_type='Asset')
        db.session.commit()
        with pytest.raises(ValueError):
            acc.memo_account_id = acc.id


def test_orm_guard_rejects_link_to_deprecated_account():
    """الحارس يرفض ربط أي حساب بحساب موسوم متروك، بغض النظر عن المسار."""
    with app.app_context():
        target = _ensure_account_number(
            'TEST-DEPTARGET', name='حساب اختبار وزني', acc_type='Asset', tracks_weight=True
        )
        deprecated = _ensure_account_number(
            'TEST-DEPSRC', name='حساب اختبار متروك [غير مستخدم -- مكرر]',
            acc_type='Asset', tracks_weight=False,
        )
        db.session.commit()
        with pytest.raises(ValueError):
            target.memo_account_id = deprecated.id


def test_link_and_unlink_round_trip_stays_audit_clean():
    """ربط ثم فسخ، مع تدقيق نظيف بعد كل خطوة -- لا حالة وسيطة فاسدة."""
    with app.app_context():
        a = _ensure_account_number('TEST-RT-A', name='حساب اختبار ذهاب وعود أ', acc_type='Asset', tracks_weight=False)
        b = _ensure_account_number('TEST-RT-B', name='حساب اختبار ذهاب وعود ب', acc_type='Asset', tracks_weight=True)
        db.session.commit()

        link_accounts(a, b, created_by='pytest')
        db.session.commit()
        assert a.memo_account_id == b.id
        assert b.memo_account_id == a.id
        assert _no_violations(Account.query.all())

        unlink_account(a, created_by='pytest')
        db.session.commit()
        assert a.memo_account_id is None
        assert b.memo_account_id is None
        assert _no_violations(Account.query.all())


def test_link_accounts_resolves_pre_existing_duplicate_target():
    """يكرر حادثة #1213 محلياً: حساب متروك يحمل ربطاً سابقاً (بيانات قديمة
    من قبل وجود الحارس، محاكاة عبر SQL مباشر -- بالضبط كما حدث فعلياً على
    الإنتاج، ولا يمكن إعادة إنشائها الآن عبر الخدمة أو ORM بسبب الحارس
    نفسه). ربط حساب آخر صحيح بنفس الهدف يجب أن يفسخ المتروك تلقائياً."""
    with app.app_context():
        target = _ensure_account_number(
            'TEST-DUPTARGET', name='حساب اختبار الهدف المشترك', acc_type='Asset', tracks_weight=True
        )
        deprecated = _ensure_account_number(
            'TEST-DUPDEP', name='حساب اختبار قديم للهدف', acc_type='Asset', tracks_weight=False
        )
        real = _ensure_account_number(
            'TEST-DUPREAL', name='حساب اختبار صحيح للهدف', acc_type='Asset', tracks_weight=False
        )
        db.session.commit()

        db.session.execute(db.text(
            "UPDATE account SET name = name || ' [غير مستخدم -- مكرر]' WHERE id = :id"
        ), {'id': deprecated.id})
        db.session.execute(db.text(
            'UPDATE account SET memo_account_id = :tid WHERE id = :did'
        ), {'tid': target.id, 'did': deprecated.id})
        db.session.commit()
        db.session.expire_all()

        link_accounts(real, target, created_by='pytest')
        db.session.commit()

        db.session.refresh(deprecated)
        assert deprecated.memo_account_id is None, "الحساب المتروك يجب أن يُفسَخ ربطه تلقائياً"
        assert real.memo_account_id == target.id
        assert target.memo_account_id == real.id
        assert _no_violations(Account.query.all())


def test_full_lifecycle_link_unlink_relink_stays_audit_clean():
    """اختبار شامل يثبت خمس خصائص أساسية للعلاقة، لا فقط أن الخدمة "تعمل":

      - Correctness: كل عملية شرعية تنتج حالة سليمة (تدقيق صفري) فوراً.
      - Idempotency: تكرار link_accounts() بنفس الطرفين لا يُغيّر شيئاً.
      - Uniqueness: لا يمكن لحساب أن يملك أكثر من شريك نشط -- إعادة ربط A
        بشريك جديد تفسخ شريكه القديم تلقائياً.
      - Symmetry: الرابط ثنائي الاتجاه دائماً في كل خطوة، بلا استثناء.
      - Convergence: بغض النظر عن تسلسل link/unlink/relink، تعود البيانات
        دائماً لحالة تحقق كل القواعد الخمس.

    التدقيق بعد كل خطوة عبر account_pair_invariants.classify() مباشرة --
    نفس الدالة التي يستخدمها audit_account_memo_invariants.py على
    الإنتاج، لا منطقاً محلياً للاختبار قد ينجرف عنها.
    """
    with app.app_context():
        a = _ensure_account_number('TEST-LC-A', name='حساب اختبار دورة حياة أ', acc_type='Asset', tracks_weight=False)
        b = _ensure_account_number('TEST-LC-B', name='حساب اختبار دورة حياة ب', acc_type='Asset', tracks_weight=True)
        db.session.commit()

        # 1) حالة ابتدائية: حسابان مستقلان بلا ربط -- نظيفة بداهة.
        assert _no_violations(Account.query.all())

        # 2) Correctness + Symmetry: link_accounts(A, B).
        link_accounts(a, b, created_by='pytest_lifecycle')
        db.session.commit()
        assert a.memo_account_id == b.id
        assert b.memo_account_id == a.id
        assert _no_violations(Account.query.all())

        # 3) Idempotency: نفس الاستدعاء مرة ثانية لا يُغيّر شيئاً.
        state_before = (a.memo_account_id, b.memo_account_id)
        link_accounts(a, b, created_by='pytest_lifecycle')
        db.session.commit()
        assert (a.memo_account_id, b.memo_account_id) == state_before
        assert _no_violations(Account.query.all())

        # 4) unlink_account(A) -> كلا الجانبين None، لا أثر متبقٍّ.
        unlink_account(a, created_by='pytest_lifecycle')
        db.session.commit()
        assert a.memo_account_id is None
        assert b.memo_account_id is None
        assert _no_violations(Account.query.all())

        # 5) حساب ثالث C، ثم link_accounts(A, C).
        c = _ensure_account_number('TEST-LC-C', name='حساب اختبار دورة حياة ج', acc_type='Asset', tracks_weight=True)
        db.session.commit()
        link_accounts(a, c, created_by='pytest_lifecycle')
        db.session.commit()
        assert a.memo_account_id == c.id
        assert c.memo_account_id == a.id
        assert _no_violations(Account.query.all())

        # 6) Uniqueness + Convergence: relink -- إعادة ربط A بـB يجب أن
        # يفسخ C تلقائياً (لا يمكن أن يبقى C مرتبطاً بـA بعد أن صار A
        # مرتبطاً بحساب آخر -- علاقة 1:1 محفوظة دائماً).
        link_accounts(a, b, created_by='pytest_lifecycle')
        db.session.commit()
        db.session.refresh(c)
        assert a.memo_account_id == b.id
        assert b.memo_account_id == a.id
        assert c.memo_account_id is None, "Uniqueness: C يجب أن يُفسَخ تلقائياً بعد إعادة ربط A بـB"
        assert _no_violations(Account.query.all())

        # تنظيف نهائي -- يجب أن يبقى التدقيق صفرياً.
        unlink_account(a, created_by='pytest_lifecycle')
        db.session.commit()
        assert _no_violations(Account.query.all())
