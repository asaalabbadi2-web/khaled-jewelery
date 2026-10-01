"""اختبارات settlement_state_service -- الخدمة التي توحّد قراءة "كم سُوِّي
من هذه الدفعة فعلاً" بدل 10 نسخ متطابقة من نفس الاستعلام كانت موزَّعة بين
routes.py وclearing_settlement_scheduler.py.

هذه الاختبارات تثبت أن سلوك الخدمة مطابق تماماً لما كانت تفعله تلك
المواضع قبل الترحيل (بلا أي فلتر على حالة السند) -- توحيد فقط، لا تغيير
وظيفي. انظر PAYMENT_LIFECYCLE_ARCHITECTURE.md للسياق الكامل، بما فيه
الاستثناء المتعمَّد الوحيد (routes.py:31108) الذي لا تغطيه هذه الخدمة بعد.
"""

from datetime import datetime

from app import app
from models import db, PaymentMethod, Invoice, InvoicePayment, Voucher, SettlementLine
from settlement_state_service import get_settled_amounts, get_settled_amount, is_locked
from tests.voucher_world import stand_posted


def _make_payment_method(name='وسيلة اختبار'):
    pm = PaymentMethod(payment_type='cash', name=name)
    db.session.add(pm)
    db.session.flush()
    return pm


_invoice_type_id_counter = [900000]  # high offset to avoid colliding with other test files' invoice_type_id values


def _make_invoice():
    # (invoice_type, invoice_type_id) is unique together -- each test invoice
    # needs its own invoice_type_id, this field is otherwise irrelevant here.
    _invoice_type_id_counter[0] += 1
    inv = Invoice(invoice_type_id=_invoice_type_id_counter[0], invoice_type='بيع', date=datetime.now(), total=0.0)
    db.session.add(inv)
    db.session.flush()
    return inv


def _make_invoice_payment(amount, pm=None):
    pm = pm or _make_payment_method()
    inv = _make_invoice()
    ip = InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id, amount=amount, net_amount=amount)
    db.session.add(ip)
    db.session.flush()
    return ip


def _make_voucher(number, status='approved'):
    v = Voucher(voucher_number=number, voucher_type='adjustment', date=datetime.now(), status=status)
    db.session.add(v)
    db.session.flush()
    return stand_posted(v) if status == 'approved' else v


def _make_settlement_line(ip, voucher, amount):
    sl = SettlementLine(voucher_id=voucher.id, invoice_payment_id=ip.id, amount_settled=amount)
    db.session.add(sl)
    db.session.flush()
    return sl


def test_get_settled_amounts_empty_input_returns_empty_dict():
    with app.app_context():
        assert get_settled_amounts([]) == {}
        assert get_settled_amounts(None) == {}


def test_get_settled_amount_with_no_settlement_lines_is_zero():
    with app.app_context():
        ip = _make_invoice_payment(1000.0)
        db.session.commit()
        assert get_settled_amount(ip.id) == 0.0
        assert get_settled_amounts([ip.id]) == {}


def test_get_settled_amount_single_line():
    with app.app_context():
        ip = _make_invoice_payment(1000.0)
        v = _make_voucher('TEST-SSS-001')
        _make_settlement_line(ip, v, 400.0)
        db.session.commit()
        assert get_settled_amount(ip.id) == 400.0


def test_get_settled_amount_sums_multiple_lines_same_payment():
    with app.app_context():
        ip = _make_invoice_payment(1000.0)
        v1 = _make_voucher('TEST-SSS-002')
        v2 = _make_voucher('TEST-SSS-003')
        _make_settlement_line(ip, v1, 300.0)
        _make_settlement_line(ip, v2, 250.0)
        db.session.commit()
        assert get_settled_amount(ip.id) == 550.0


def test_get_settled_amounts_bulk_does_not_cross_contaminate_between_payments():
    with app.app_context():
        ip_a = _make_invoice_payment(1000.0)
        ip_b = _make_invoice_payment(2000.0)
        v = _make_voucher('TEST-SSS-004')
        _make_settlement_line(ip_a, v, 100.0)
        _make_settlement_line(ip_b, v, 700.0)
        db.session.commit()

        result = get_settled_amounts([ip_a.id, ip_b.id])
        assert result == {ip_a.id: 100.0, ip_b.id: 700.0}

        # Querying for only one ID must not leak the other's amount.
        assert get_settled_amounts([ip_a.id]) == {ip_a.id: 100.0}


def test_is_locked_true_above_epsilon_false_otherwise():
    with app.app_context():
        unsettled = _make_invoice_payment(500.0)
        settled = _make_invoice_payment(500.0)
        v = _make_voucher('TEST-SSS-005')
        _make_settlement_line(settled, v, 10.0)
        db.session.commit()

        assert is_locked(unsettled.id) is False
        assert is_locked(settled.id) is True


def test_is_locked_respects_epsilon_threshold():
    with app.app_context():
        ip = _make_invoice_payment(500.0)
        v = _make_voucher('TEST-SSS-006')
        # Below the 0.005 epsilon used by the original guard -- must not lock.
        _make_settlement_line(ip, v, 0.001)
        db.session.commit()
        assert is_locked(ip.id) is False


def test_is_locked_counts_settlement_lines_regardless_of_voucher_status():
    """مطابقة متعمَّدة للسلوك الحالي في الـ9 مواضع غير المستثناة: لا فلتر
    على Voucher.status -- حتى سند ملغى لا يزال يُحسَب هنا (هذا بالضبط
    الثقب المكتشف على الإنتاج، موثَّق في PAYMENT_LIFECYCLE_ARCHITECTURE.md،
    لم يُحسَم إصلاحه بعد)."""
    with app.app_context():
        ip = _make_invoice_payment(500.0)
        cancelled_voucher = _make_voucher('TEST-SSS-007', status='cancelled')
        _make_settlement_line(ip, cancelled_voucher, 500.0)
        db.session.commit()
        assert is_locked(ip.id) is True
        assert get_settled_amount(ip.id) == 500.0
