"""The settlement alarm fires when a card payment is overdue by ITS method's schedule.

It used to ask "how long since the last auto-settlement?" with a 3-hour
threshold (SCHED-004). On the 29 Sep 2026 copy the 200 auto-settlements since
April are about a day apart -- median gap 23.7 h, longest quiet spell 96.6 h
(weekly methods, days without card sales) -- so 3 h fired on 142 of 199 gaps,
and no threshold told a quiet day from a stopped scheduler: 72 h would still
have fired 5 times and let a real stoppage run three days.

The owner's decision (29 Sep 2026): alarm when a payment has reached its
settlement day -- read from its payment method's own schedule, the same
reading the scheduler settles by -- and is still unsettled a grace period after
that day began. Since ADR-037 (6 Oct 2026) that day is the deposit day
(services/settlement_schedule.py, read through method_dues). The grace is policy
(SETTLEMENT_OVERDUE_GRACE_HOURS, default 6: the scheduler runs every 2 hours).

Run:
    python -m pytest tests/test_settlement_overdue_alarm.py -v
"""
import inspect
import uuid
from datetime import datetime, timedelta

import pytest

from app import app as flask_app
import clearing_settlement_scheduler as css
from clearing_settlement_scheduler import (
    ClearingSettlementScheduler,
    overdue_grace_hours,
    overdue_settlements,
)
from models import (
    Account,
    Invoice,
    InvoicePayment,
    PaymentMethod,
    ReconciliationFinding,
    SafeBox,
    SettlementLine,
    Voucher,
    db,
)


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:8]


# Wednesday 23 Sep 2026 (weekday 2).
WED = datetime(2026, 9, 23)


def _method(**schedule):
    acc = Account(account_number=f'8{_uid()[:5]}', name=f'مقاصة {_uid()}', type='Asset')
    db.session.add(acc)
    db.session.flush()
    box = SafeBox(name=f'مقاصة {_uid()}', safe_type='clearing', account_id=acc.id, is_active=True)
    db.session.add(box)
    db.session.flush()
    pm = PaymentMethod(name=f'بطاقة {_uid()}', payment_type='mada', default_safe_box_id=box.id,
                       is_active=True, auto_settlement_enabled=True, **schedule)
    db.session.add(pm)
    db.session.flush()
    return pm


def _paid(pm, amount, at, invoice_status='paid'):
    inv = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع', date=at,
                  total=amount, amount_paid=amount, status=invoice_status, is_posted=True)
    db.session.add(inv)
    db.session.flush()
    ip = InvoicePayment(invoice_id=inv.id, payment_method_id=pm.id, amount=amount,
                        net_amount=amount, created_at=at)
    db.session.add(ip)
    db.session.flush()
    return inv, ip


def _overdue(pm, now, grace=6):
    return [f for f in overdue_settlements(now, grace) if f.subject_key == f'payment_method:{pm.id}']


class TestByTheMethodsOwnSchedule:
    def test_a_payment_due_today_waits_for_the_grace(self):
        pm = _method(settlement_schedule_type='days', deposit_delay_days=1)
        _paid(pm, 500.0, WED - timedelta(hours=14))         # Tue 10:00, due Wed
        assert _overdue(pm, WED.replace(hour=5)) == []       # Wed 05:00: still in grace

    def test_after_the_grace_it_is_overdue(self):
        pm = _method(settlement_schedule_type='days', deposit_delay_days=1)
        _, ip = _paid(pm, 500.0, WED - timedelta(hours=14))
        facts = _overdue(pm, WED.replace(hour=7))
        assert len(facts) == 1
        assert facts[0].metric == 500.0
        assert facts[0].detail['due_day'] == '2026-09-23'
        assert facts[0].detail['payments'] == 1

    def test_a_quiet_day_raises_nothing(self):
        """Nothing sold by card: no alarm, however long since the last settlement."""
        pm = _method(settlement_schedule_type='days', deposit_delay_days=1)
        assert _overdue(pm, WED.replace(hour=23)) == []

    def test_a_weekly_method_is_not_overdue_before_its_weekday(self):
        pm = _method(settlement_schedule_type='weekday', settlement_weekday=3,   # batch ends Thursday,
                         deposit_schedule_type='weekday', deposit_weekday=4)    # deposited Friday
        _paid(pm, 800.0, WED - timedelta(hours=14))          # Tuesday
        assert _overdue(pm, WED.replace(hour=12)) == []                          # Wednesday
        assert _overdue(pm, WED + timedelta(days=2, hours=5)) == []              # Friday 05:00
        assert len(_overdue(pm, WED + timedelta(days=2, hours=7))) == 1          # Friday 07:00

    def test_the_deposit_days_move_the_due_day(self):
        pm = _method(settlement_schedule_type='days', deposit_delay_days=3)
        _paid(pm, 300.0, WED - timedelta(hours=14))          # Tuesday: due Friday
        assert _overdue(pm, WED + timedelta(days=1, hours=12)) == []             # Thursday
        assert len(_overdue(pm, WED + timedelta(days=2, hours=7))) == 1          # Friday

    def test_below_the_minimum_settlement_amount_it_is_waiting(self):
        pm = _method(settlement_schedule_type='days', deposit_delay_days=1, min_settlement_amount=1000.0)
        _paid(pm, 500.0, WED - timedelta(hours=14))
        assert _overdue(pm, WED.replace(hour=7)) == []

    def test_a_settled_payment_is_not_overdue_and_a_partial_one_counts_its_rest(self):
        pm = _method(settlement_schedule_type='days', deposit_delay_days=1)
        _, full = _paid(pm, 500.0, WED - timedelta(hours=14))
        _, part = _paid(pm, 400.0, WED - timedelta(hours=13))
        v = Voucher(voucher_number=f'AV-{_uid()}', voucher_type='receipt', date=WED,
                    status='approved', created_by='t', reference_type='clearing_settlement')
        db.session.add(v)
        db.session.flush()
        db.session.add_all([SettlementLine(voucher_id=v.id, invoice_payment_id=full.id, amount_settled=500.0),
                            SettlementLine(voucher_id=v.id, invoice_payment_id=part.id, amount_settled=150.0)])
        db.session.flush()
        facts = _overdue(pm, WED.replace(hour=7))
        assert len(facts) == 1 and facts[0].metric == 250.0

    def test_a_payment_of_a_rejected_invoice_is_never_overdue(self):
        """The ONE settleable rule: a dead payment is never settled, so never late."""
        pm = _method(settlement_schedule_type='days', deposit_delay_days=1)
        _paid(pm, 500.0, WED - timedelta(hours=14), invoice_status='rejected')
        assert _overdue(pm, WED.replace(hour=7)) == []

    def test_another_methods_payments_are_not_counted(self):
        """Two methods may share a clearing box; each is judged by its own schedule."""
        daily = _method(settlement_schedule_type='days', deposit_delay_days=1)
        weekly = _method(settlement_schedule_type='weekday', settlement_weekday=3,
                         deposit_schedule_type='weekday', deposit_weekday=4)
        weekly.default_safe_box_id = daily.default_safe_box_id
        db.session.flush()
        _paid(weekly, 800.0, WED - timedelta(hours=14))
        assert _overdue(daily, WED.replace(hour=7)) == []


class TestTheFinding:
    def _scheduler(self, monkeypatch, now):
        s = ClearingSettlementScheduler(flask_app)
        monkeypatch.setattr(css, '_local_now', lambda: now)
        return s

    def _open(self, pm):
        return ReconciliationFinding.query.filter_by(
            kind='OVERDUE_SETTLEMENT', subject_key=f'payment_method:{pm.id}', resolved_at=None).all()

    def test_it_opens_while_overdue_and_resolves_once_settled(self, monkeypatch):
        pm = _method(settlement_schedule_type='days', deposit_delay_days=1)
        inv, _ = _paid(pm, 500.0, WED - timedelta(hours=14))
        self._scheduler(monkeypatch, WED.replace(hour=7))._emit_overdue_findings()
        assert len(self._open(pm)) == 1

        inv.status = 'rejected'   # the payment stops counting, as a settled one would
        db.session.flush()
        self._scheduler(monkeypatch, WED.replace(hour=9))._emit_overdue_findings()
        assert self._open(pm) == []

    def test_the_elapsed_time_alarm_is_retired(self, monkeypatch):
        stale = ReconciliationFinding(kind='STALE_SETTLEMENT', source='clearing_settlement_scheduler',
                                      detail='old', check_count=68970)
        db.session.add(stale)
        db.session.flush()
        self._scheduler(monkeypatch, WED.replace(hour=7))._emit_overdue_findings()
        assert ReconciliationFinding.query.get(stale.id).resolved_at is not None
        assert not hasattr(ClearingSettlementScheduler, '_emit_stale_finding_if_needed')


class TestOneReadingOfTheSchedule:
    def test_the_scheduler_and_the_alarm_read_the_same_dues_and_restate_nothing(self):
        for fn in (ClearingSettlementScheduler.process_due_settlements, overdue_settlements):
            src = inspect.getsource(fn)
            assert 'method_dues(pm, ' in src, f'{fn.__name__} does not read method_dues'
            for restated in ('settlement_schedule_type', 'deposit_schedule_type', 'deposit_delay_days',
                             'settlement_weekday', 'deposit_weekday', 'min_settlement_amount'):
                assert restated not in src, f'{fn.__name__} reads {restated} itself'


def test_the_grace_is_policy_with_a_default_of_six_hours(monkeypatch):
    monkeypatch.delenv('SETTLEMENT_OVERDUE_GRACE_HOURS', raising=False)
    assert overdue_grace_hours() == 6.0
    monkeypatch.setenv('SETTLEMENT_OVERDUE_GRACE_HOURS', '12')
    assert overdue_grace_hours() == 12.0
    monkeypatch.setenv('SETTLEMENT_OVERDUE_GRACE_HOURS', 'nonsense')
    assert overdue_grace_hours() == 6.0
