"""Automatic clearing settlements scheduler.

Settles, for each payment method that opts in (auto_settlement_enabled), every
deposit that has reached the bank by the method's schedule -- one voucher per
deposit, dated the deposit day (ADR-037; services/settlement_schedule.py is
the one reading of the schedule). What a method holds is read from its
payments through settleable_payments_query and the approved settlement lines
(method_open_payments). The overdue alarm reads the same (overdue_settlements).
"""

from __future__ import annotations

import os as _os
import signal as _signal
import threading as _threading
from datetime import date, datetime, time, timedelta
from threading import Thread

import schedule
from sqlalchemy import func

from models import db, Invoice, PaymentMethod, Voucher, InvoicePayment
from services.gold_allocation_service import RETRACTED_INVOICE_STATUSES
from services.invoice_payment_state_service import payment_voucher_not_cancelled
from services.live_balances import live_balances_by_account_ids
from settlement_state_service import get_settled_amounts
from allocation_repair_service import AllocationRepairService


def settleable_payments_query(safe_box_id: int):
    """Payments into *safe_box_id* that can still be settled.

    EVERY selection of settleable payments starts here -- the scheduler's
    amount (_compute_due_for_day) and its payments (_get_unsettled_ip_ids_*),
    the settlement screen's pending list, and the manual-settlement check in
    routes/clearing.py. The first version of this fix corrected two of those
    and missed the amount, 30 lines away: the scheduler then computed 6,530.00
    due against 4,380.00 of payments and refused to settle at all. A payment is NOT settleable when:
      - its creating voucher was cancelled -- the rule InvoicePaymentStateService
        already applies, reused rather than restated; or
      - its invoice was retracted (RETRACTED_INVOICE_STATUSES). Needed on its
        own: rejecting an invoice resets its receipt voucher to 'pending', not
        'cancelled', so the voucher rule alone misses exactly that case.
    Deliberately NOT the full "standing invoice" test (posted and not
    retracted): an unposted invoice awaiting approval can carry a real card
    payment, and that money does arrive at the bank.

    Incident: AV-2026-00436 settled 6,530.00 for 4,380.00 of real Mada
    payments -- rejected invoice 3123's 2,150.00 was selected by method and
    time alone. See tests/test_clearing_settlement_excludes_dead_payments.py.
    """
    return (
        InvoicePayment.query
        .join(PaymentMethod, PaymentMethod.id == InvoicePayment.payment_method_id)
        .join(Invoice, Invoice.id == InvoicePayment.invoice_id)
        .outerjoin(Voucher, Voucher.id == InvoicePayment.source_voucher_id)
        .filter(
            PaymentMethod.default_safe_box_id == safe_box_id,
            payment_voucher_not_cancelled(),
            func.lower(func.coalesce(Invoice.status, '')).notin_(
                list(RETRACTED_INVOICE_STATUSES)),
        )
    )



# ======================================================================
# What the books say a method holds (ADR-037)
# ======================================================================

def method_open_payments(pm) -> list:
    """(invoice_payment_id, sale day, open amount) for *pm*'s settleable payments
    -- through settleable_payments_query, the one rule -- less what approved
    settlement lines already settled. The scheduler settles from it and the
    overdue alarm alarms from it: one reading."""
    if not pm.default_safe_box_id:
        return []
    ips = (settleable_payments_query(pm.default_safe_box_id)
           .filter(InvoicePayment.payment_method_id == pm.id)
           .all())
    settled = get_settled_amounts([ip.id for ip in ips])
    out = []
    for ip in ips:
        rest = round(float(ip.amount or 0.0) - settled.get(ip.id, 0.0), 2)
        if rest > 0.005 and ip.created_at is not None:
            out.append((ip.id, ip.created_at.date(), rest))
    return out


def public_holidays() -> frozenset:
    """The public holiday calendar (policy: the owner enters it)."""
    from models import PublicHoliday
    return frozenset(h.holiday_date for h in PublicHoliday.query.all())


def settlement_fee(pm, gross_amount: float, transaction_count: int) -> float:
    """The commission a settlement of *gross_amount* over *transaction_count*
    payments carries -- 0 unless the method takes its commission at settlement."""
    timing = str(getattr(pm, 'commission_timing', 'invoice') or 'invoice').strip().lower()
    if timing != 'settlement':
        return 0.0
    rate = float(getattr(pm, 'commission_rate', 0.0) or 0.0)
    fixed = float(getattr(pm, 'commission_fixed_amount', 0.0) or 0.0)
    if rate <= 0.0 and fixed <= 0.0:
        return 0.0
    return round((gross_amount * rate / 100.0) + (fixed * max(transaction_count, 1)), 2)


def net_reaching_the_bank(pm):
    """(gross, count) -> what reaches the bank: gross less the commission and
    its VAT, as the settlement voucher computes them."""
    from routes.clearing import commission_vat

    def net(gross, count):
        fee = settlement_fee(pm, gross, count)
        return round(gross - fee - commission_vat(fee), 2)
    return net


def method_dues(pm, as_of: date, holidays=None) -> list:
    """The deposits *pm* has received by *as_of*, by its schedule (ADR-037)."""
    from services.settlement_schedule import due_deposits, schedule_of, validate
    return due_deposits(validate(schedule_of(pm)), method_open_payments(pm), as_of,
                        net_reaching_the_bank(pm), public_holidays() if holidays is None else holidays)


# ======================================================================
# The overdue alarm (SCHED-004)
# ======================================================================

OVERDUE_KIND = 'OVERDUE_SETTLEMENT'
OVERDUE_SOURCE = 'clearing_settlement_scheduler'
_DEFAULT_GRACE_HOURS = 6.0
_LOOKBACK_DAYS = 14   # a weekly method's last settlement day is at most 7 days back


def _local_now() -> datetime:
    """The scheduler's clock: settlement days are local days (date.today())."""
    return datetime.now()


def overdue_grace_hours() -> float:
    """POLICY, not law: how long after a settlement day begins its due payments
    may stay unsettled. The scheduler runs every 2 hours; 6 = three missed runs."""
    try:
        return max(float(_os.getenv('SETTLEMENT_OVERDUE_GRACE_HOURS', _DEFAULT_GRACE_HOURS)), 0.0)
    except ValueError:
        return _DEFAULT_GRACE_HOURS


def overdue_settlements(now: datetime, grace_hours: float) -> list:
    """One fact per payment method holding a deposit that should have been settled.

    A deposit is overdue when its day -- by the method's schedule, the reading
    the scheduler settles by (method_dues) -- began more than *grace_hours* ago
    and its payments are still unsettled. A day without card sales, a weekly
    batch before its deposit day and a flexible plan still below its minimum
    raise nothing. Read-only.
    """
    from services.books_invariants import Fact
    from services.settlement_schedule import ScheduleInvalid

    as_of = (now - timedelta(hours=grace_hours)).date()
    holidays = public_holidays()
    facts = []
    methods = (PaymentMethod.query
               .filter_by(is_active=True, auto_settlement_enabled=True)
               .order_by(PaymentMethod.id).all())
    for pm in methods:
        if not pm.default_safe_box_id:
            continue
        try:
            dues = method_dues(pm, as_of, holidays)
        except ScheduleInvalid:
            continue
        if not dues:
            continue
        amount = round(sum(d.gross for d in dues), 2)
        facts.append(Fact(OVERDUE_KIND, f'payment_method:{pm.id}', amount, {
            'payment_method': pm.name,
            'due_day': dues[0].deposit_date.isoformat(),
            'cutoff': dues[-1].close_date.isoformat(),
            'payments': sum(len(d.payments) for d in dues),
            'oldest_payment_at': min(d.first_sale_day for d in dues).isoformat(),
            'grace_hours': grace_hours,
        }))
    return facts


class ClearingSettlementScheduler:
    def __init__(self, app):
        self.app = app
        self.is_running = False
        self._scheduler = schedule.Scheduler()
        # S3 — interruptible sleep: stop() sets this so the loop wakes immediately
        self._stop_event = _threading.Event()
        # S2 — failure flag: set when the scheduler loop dies unexpectedly;
        #      run_schedulers.main() reads it to decide the process exit code
        self._failed = _threading.Event()
        # S4 — reference kept so run_schedulers.main() can join the thread
        self._thread: Thread | None = None

    def _live_cash_balance_for_safe_box(self, safe_box) -> float:
        account = getattr(safe_box, 'account', None)
        account_id = getattr(account, 'id', None)
        fallback = float(getattr(account, 'balance_cash', 0.0) or 0.0) if account is not None else 0.0
        if account_id is None:
            return fallback
        try:
            live = live_balances_by_account_ids([int(account_id)]).get(int(account_id))
            if isinstance(live, dict):
                return float(live.get('cash') or 0.0)
        except Exception:
            pass
        return fallback

    def process_due_settlements(self, today: date | None = None) -> dict:
        """Settle every deposit that has reached the bank, one voucher each,
        dated the deposit day (ADR-037).

        Returns a diagnostic dict with keys:
          - settled_count: number of settlement vouchers created
          - skipped: list of {pm_id, name, reason} for skipped PMs
          - enabled_methods: total PMs checked
        """
        from services.settlement_schedule import ScheduleInvalid

        result: dict = {
            'settled_count': 0,
            'enabled_methods': 0,
            'skipped': [],
        }
        with self.app.app_context():
            from routes import _create_clearing_settlement_voucher
            from routes.clearing import commission_vat

            today = today or date.today()
            holidays = public_holidays()

            methods = (
                PaymentMethod.query
                .filter_by(is_active=True, auto_settlement_enabled=True)
                .all()
            )
            result['enabled_methods'] = len(methods)

            if not methods:
                print('[ClearingSettlementScheduler] No enabled payment methods')
                return result

            # Track repaired safe boxes so Phase 0 runs at most once per safe box
            # even when multiple PMs share the same clearing safe box.
            _repaired_sb_ids: set[int] = set()

            for pm in methods:
                try:
                    pm_name = getattr(pm, 'name', str(pm.id))

                    def _skip(reason: str):
                        result['skipped'].append({'pm_id': pm.id, 'name': pm_name, 'reason': reason})

                    # Basic config
                    if not pm.default_safe_box_id:
                        _skip('no_clearing_safe_box')
                        continue
                    if not pm.settlement_bank_safe_box_id:
                        _skip('no_bank_safe_box')
                        continue

                    clearing_sb = pm.default_safe_box
                    bank_sb = pm.settlement_bank_safe_box
                    if not clearing_sb or not bank_sb:
                        _skip('safe_box_not_found')
                        continue
                    if not getattr(clearing_sb, 'is_active', True) or not getattr(bank_sb, 'is_active', True):
                        _skip('safe_box_inactive')
                        continue

                    if (clearing_sb.safe_type or '').strip().lower() != 'clearing':
                        _skip(f'clearing_safe_wrong_type:{clearing_sb.safe_type}')
                        continue
                    if (bank_sb.safe_type or '').strip().lower() != 'bank':
                        _skip(f'bank_safe_wrong_type:{bank_sb.safe_type}')
                        continue

                    # ═══ Phase 0: Repair ════════════════════════════════════════
                    # SettlementLine gaps are repaired before anything is read --
                    # the open payments are read from those lines.
                    # Idempotent: find_incomplete_vouchers returns [] if already clean.
                    if clearing_sb.id not in _repaired_sb_ids:
                        _repaired_sb_ids.add(clearing_sb.id)
                        try:
                            _repair_svc = AllocationRepairService()
                            _repair_results = _repair_svc.repair_safe_box(safe_box=clearing_sb)
                            _ok = [r for r in _repair_results if r.is_repaired]
                            _failed = [r for r in _repair_results if not r.is_repaired]
                            if _ok:
                                print(
                                    f'[ClearingSettlementScheduler] 🔧 SB#{clearing_sb.id}:'
                                    f' repaired {len(_ok)} voucher(s): '
                                    + ', '.join(r.voucher_number for r in _ok)
                                )
                            for _r in _failed:
                                print(
                                    f'[ClearingSettlementScheduler] ❌ SB#{clearing_sb.id}:'
                                    f' repair failed for {_r.voucher_number}: {_r.error}'
                                )
                        except Exception as _repair_exc:
                            db.session.rollback()
                            print(
                                f'[ClearingSettlementScheduler] ❌ SB#{clearing_sb.id}:'
                                f' repair phase error: {_repair_exc}'
                            )
                    # ════════════════════════════════════════════════════════════

                    try:
                        dues = method_dues(pm, today, holidays)
                    except ScheduleInvalid as exc:
                        _skip(f'schedule_invalid:{exc}')
                        continue
                    if not dues:
                        _skip('nothing_due')
                        continue

                    balance = self._live_cash_balance_for_safe_box(clearing_sb)
                    for due in dues:
                        gross = due.gross
                        # The ledger must hold what the deposit carries; if not,
                        # something else is wrong -- nothing is settled partly.
                        if gross > balance + 0.01:
                            _skip(f'clearing_balance_below_due:{balance:.2f}<{gross:.2f}')
                            break
                        fee = settlement_fee(pm, gross, len(due.payments))
                        if fee >= gross:
                            _skip(f'fee_exceeds_gross:{fee:.2f}>={gross:.2f}')
                            continue
                        net = round(gross - fee - commission_vat(fee), 2)
                        description = (
                            f"تسوية تلقائية: {pm.name} ({clearing_sb.name} → {bank_sb.name}) — "
                            f"إيداع {due.deposit_date.isoformat()} لمبيعات {due.first_sale_day.isoformat()}"
                            f"{'' if due.first_sale_day == due.close_date else ' إلى ' + due.close_date.isoformat()} "
                            f"(إجمالي {gross:.2f}، عمولة {fee:.2f}، صافي {net:.2f})"
                        )
                        try:
                            voucher_result = _create_clearing_settlement_voucher(
                                clearing_safe_box_id=clearing_sb.id,
                                bank_safe_box_id=bank_sb.id,
                                gross_amount=gross,
                                fee_amount=fee,
                                settlement_dt=datetime.combine(due.deposit_date, time(12, 0)),
                                reference_number=f"AUTO-PM-{pm.id}-B-{due.close_date.isoformat()}",
                                created_by='scheduler',
                                fee_account_id=getattr(pm, 'fee_expense_account_id', None),
                                description_override=description,
                                notes=(f'auto_settlement:batch={due.close_date.isoformat()};'
                                       f'deposit={due.deposit_date.isoformat()}'),
                                ensure_unique_reference=True,
                                invoice_payment_ids=[ip_id for ip_id, _ in due.payments],
                            )
                            if voucher_result.get('skipped'):
                                db.session.rollback()
                                _skip(f'duplicate_reference_skipped:{due.close_date.isoformat()}')
                                continue
                            db.session.commit()
                            balance -= gross
                            result['settled_count'] += 1
                            print(
                                f"[ClearingSettlementScheduler] ✓ Settled {gross:.2f} (fee {fee:.2f})"
                                f" for PM#{pm.id} ({pm.name}) deposit={due.deposit_date.isoformat()}"
                            )
                        except Exception as exc:
                            db.session.rollback()
                            print(f"[ClearingSettlementScheduler] ❌ Failed PM#{pm.id} ({pm.name}): {exc}")
                            _skip(f'voucher_creation_error:{str(exc)[:120]}')
                            break

                except Exception as exc:
                    db.session.rollback()
                    print(f"[ClearingSettlementScheduler] ❌ Unexpected error for PM#{getattr(pm, 'id', '?')}: {exc}")
                    result['skipped'].append({'pm_id': getattr(pm, 'id', '?'), 'name': '?', 'reason': f'unexpected:{str(exc)[:120]}'})

        return result

    def setup_schedule(self):
        # Run every 2 hours so settlements happen throughout the day.
        # process_due_settlements() is idempotent (ensure_unique_reference +
        # SettlementLine tracking) so running more often is safe.
        self._scheduler.every(2).hours.do(self.process_due_settlements)
        print('[ClearingSettlementScheduler] ✓ Auto settlement scheduled every 2 hours')

    # ------------------------------------------------------------------
    # S5 — Business-outcome monitoring
    # ------------------------------------------------------------------

    def _emit_overdue_findings(self) -> dict:
        """Bring the OVERDUE_SETTLEMENT findings in line with what is overdue now:
        one open finding per payment method with overdue payments, resolved once
        they are settled (the ADR-030 lifecycle, reconcile_findings).

        Replaces STALE_SETTLEMENT (SCHED-004): time since the last settlement
        could not tell a day without card sales from a stopped scheduler. Any
        STALE_SETTLEMENT still open is closed here -- the kind is retired.
        """
        from models import ReconciliationFinding
        from services.books_invariants import reconcile_findings

        facts = overdue_settlements(_local_now(), overdue_grace_hours())
        result = reconcile_findings(OVERDUE_KIND, OVERDUE_SOURCE, facts)
        for row in ReconciliationFinding.query.filter_by(kind='STALE_SETTLEMENT', resolved_at=None).all():
            row.resolved_at = datetime.utcnow()
        db.session.commit()
        for fact in facts:
            if fact.subject_key in result['opened'] or fact.subject_key in result['changed']:
                print(
                    f"[ClearingSettlementScheduler] ⚠ OVERDUE_SETTLEMENT {fact.detail['payment_method']}: "
                    f"{fact.metric:.2f} in {fact.detail['payments']} payment(s) due "
                    f"{fact.detail['due_day']}, still unsettled",
                    flush=True,
                )
        return result

    def start(self):
        if self.is_running:
            print('[ClearingSettlementScheduler] already running')
            return

        self.setup_schedule()
        self.is_running = True
        self._stop_event.clear()

        def _beat():
            with self.app.app_context():
                try:
                    from services.scheduler_heartbeat import beat
                    beat('clearing_settlement')
                except Exception as _exc:
                    db.session.rollback()
                    print(f'[ClearingSettlementScheduler] heartbeat failed: {_exc}', flush=True)

        def run_scheduler():
            # Beat first: otherwise the bell read "scheduler down" for the
            # first minute after every start (ADR-033).
            _beat()
            # Run once immediately on startup so we don't wait 2 hours
            # after a container restart / deployment.
            try:
                self.process_due_settlements()
            except Exception as exc:
                print(f'[ClearingSettlementScheduler] ⚠ initial run failed: {exc}')

            # S2: loop wrapped in try/except.  Any unhandled exception here is
            # a fatal event: mark failure, then send SIGTERM so the graceful
            # shutdown path in run_schedulers.main() runs before the process
            # exits with code 1.  os._exit() is NOT called here — it is
            # reserved for the join-timeout case in run_schedulers.main().
            try:
                while self.is_running and not self._stop_event.is_set():  # S3
                    self._scheduler.run_pending()
                    # S3: interruptible wait — stop() sets _stop_event so
                    # the thread wakes immediately instead of sleeping 60s
                    self._stop_event.wait(timeout=60)
                    # S5: the heartbeat, then the overdue alarm, on each cycle
                    if self.is_running and not self._stop_event.is_set():
                        _beat()
                        with self.app.app_context():
                            try:
                                self._emit_overdue_findings()
                            except Exception as _exc:
                                db.session.rollback()
                                print(
                                    f'[ClearingSettlementScheduler] overdue check error: {_exc}',
                                    flush=True,
                                )
            except Exception as exc:
                # S2: graceful-first failure path
                print(
                    f'[ClearingSettlementScheduler] ☠ fatal loop error: {exc}',
                    flush=True,
                )
                self._failed.set()
                _os.kill(_os.getpid(), _signal.SIGTERM)

        # S4: store thread reference so run_schedulers.main() can join it
        self._thread = Thread(target=run_scheduler, daemon=True)
        self._thread.start()
        print('[ClearingSettlementScheduler] 🚀 started')

    def stop(self):
        self.is_running = False
        self._stop_event.set()  # S3: wake sleeping thread immediately
        self._scheduler.clear()
        print('[ClearingSettlementScheduler] stopped')


_scheduler_instance: ClearingSettlementScheduler | None = None


def get_clearing_settlement_scheduler(app):
    global _scheduler_instance
    if _scheduler_instance is None:
        _scheduler_instance = ClearingSettlementScheduler(app)
    return _scheduler_instance


def start_clearing_settlement_scheduler(app):
    scheduler = get_clearing_settlement_scheduler(app)
    scheduler.start()
    return scheduler
