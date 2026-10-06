"""
test_allocation_service_invariant.py
======================================
اختبارات تكامل للـ invariant الأساسي في AllocationService.allocate():

    أي Voucher بـ gross_amount > 0 لا يمكن حفظه بدون SettlementLines
    تغطيه بالكامل — أو تُرفع ValueError وتُلغى العملية.

الحالات الأربع:
  1. gross_amount > 0 + قائمة IP صحيحة كافية   → نجاح، sum(SL) == gross_amount
  2. gross_amount > 0 + قائمة فارغة              → ValueError، لا SL تُكتب
  3. IPs لا تكفي لتغطية gross_amount            → ValueError، لا SL تُكتب
  4. gross_amount = 0                             → نجاح، لا SL تُنشأ (noop)

كان هذا الملف في جذر backend/ خارج testpaths، فلم تشغّله البوابة، وفشلت
حالاته الأربع منذ APPROVED-ENTRY-001: كان يبني السند 'approved' بلا قيد،
وهذه حالة لا يقبلها حارس journal_entry_guard. التخصيص لا يقرأ حالة السند
الذي يُخصَّص له، فالسند هنا 'pending' — بيانات صالحة بلا قيد ولا ترحيل.

يعمل داخل db_fence: لا شيء يبقى في قاعدة الاختبار بعده.

Run:
    python -m pytest tests/test_allocation_service_invariant.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import (
    db,
    Invoice,
    InvoicePayment,
    PaymentMethod,
    SettlementLine,
    Voucher,
)
from allocation_service import AllocationService


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid() -> str:
    return uuid.uuid4().hex[:8]


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _minimal_env(total: float = 0.0):
    """PaymentMethod + Invoice — الحد الأدنى المطلوب لإنشاء InvoicePayment."""
    pm = PaymentMethod(
        payment_type='receivable',
        name=f'Test-PM-{_uid()}',
        commission_rate=0.0,
        commission_fixed_amount=0.0,
        commission_timing='settlement',
        auto_settlement_enabled=False,
        is_active=True,
    )
    db.session.add(pm)
    # invoice_type_id فريد لتجاوز UniqueConstraint('invoice_type', 'invoice_type_id')
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع',
                  date=datetime.now(), total=total)
    db.session.add(inv)
    db.session.flush()
    return pm, inv


def _make_ip(pm_id: int, inv_id: int, amount: float) -> InvoicePayment:
    ip = InvoicePayment(
        invoice_id=inv_id,
        payment_method_id=pm_id,
        amount=amount,
        net_amount=amount,  # commission_rate=0 → net == gross
    )
    db.session.add(ip)
    db.session.flush()
    return ip


def _make_voucher(gross: float) -> Voucher:
    v = Voucher(
        voucher_number=f'T-ALLOC-{_uid()}',
        voucher_type='receipt',
        date=datetime.now(),
        amount_cash=gross,
        status='pending',
        created_by='pytest',
    )
    db.session.add(v)
    db.session.flush()
    return v


def _sl_sum(voucher_id: int) -> float:
    result = (
        db.session.query(db.func.coalesce(db.func.sum(SettlementLine.amount_settled), 0.0))
        .filter(SettlementLine.voucher_id == voucher_id)
        .scalar()
    )
    return float(result or 0.0)


# ---------------------------------------------------------------------------
# الحالة 1: قائمة IP كافية → نجاح كامل
# ---------------------------------------------------------------------------

def test_allocate_success_sum_equals_gross():
    """IPs (600 + 400) تغطي gross=1000 → sum(SettlementLines) == 1000."""
    pm, inv = _minimal_env(total=1000.0)
    ip1 = _make_ip(pm.id, inv.id, 600.0)
    ip2 = _make_ip(pm.id, inv.id, 400.0)
    v = _make_voucher(1000.0)

    plan = AllocationService().allocate(
        voucher=v,
        invoice_payment_ids=[ip1.id, ip2.id],
        gross_amount=1000.0,
    )
    db.session.flush()

    assert abs(_sl_sum(v.id) - 1000.0) < 0.01, (
        f'sum(SettlementLines) = {_sl_sum(v.id):.2f} ≠ 1000'
    )
    assert plan.unallocated_remainder < 0.01
    assert SettlementLine.query.filter_by(voucher_id=v.id).count() == 2


# ---------------------------------------------------------------------------
# الحالة 2: قائمة فارغة + gross > 0 → ValueError
# ---------------------------------------------------------------------------

def test_allocate_empty_ip_list_raises():
    """قائمة IP فارغة مع gross=500 → ValueError قبل أي كتابة في DB."""
    _minimal_env()
    v = _make_voucher(500.0)

    with pytest.raises(ValueError, match='settlement_line_coverage_mismatch'):
        AllocationService().allocate(
            voucher=v,
            invoice_payment_ids=[],
            gross_amount=500.0,
        )

    # validate() رُفعت قبل أي db.session.add() داخل allocate()
    assert SettlementLine.query.filter_by(voucher_id=v.id).count() == 0


# ---------------------------------------------------------------------------
# الحالة 3: IPs لا تكفي → ValueError
# ---------------------------------------------------------------------------

def test_allocate_insufficient_ips_raises():
    """IP واحد بقيمة 300 لا يغطي gross=700 → ValueError."""
    pm, inv = _minimal_env(total=300.0)
    ip = _make_ip(pm.id, inv.id, 300.0)
    v = _make_voucher(700.0)

    with pytest.raises(ValueError, match='settlement_line_coverage_mismatch'):
        AllocationService().allocate(
            voucher=v,
            invoice_payment_ids=[ip.id],
            gross_amount=700.0,
        )

    assert SettlementLine.query.filter_by(voucher_id=v.id).count() == 0


# ---------------------------------------------------------------------------
# الحالة 4: gross = 0 → noop مقبول
# ---------------------------------------------------------------------------

def test_allocate_zero_gross_creates_no_lines():
    """gross_amount=0 مع قائمة فارغة → ينجح دون إنشاء أي SettlementLine."""
    _minimal_env()
    v = _make_voucher(0.0)

    plan = AllocationService().allocate(
        voucher=v,
        invoice_payment_ids=[],
        gross_amount=0.0,
    )
    db.session.flush()

    assert SettlementLine.query.filter_by(voucher_id=v.id).count() == 0
    assert plan.unallocated_remainder < 0.01
