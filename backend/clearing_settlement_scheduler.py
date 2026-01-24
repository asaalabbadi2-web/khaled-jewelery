"""Automatic clearing settlements scheduler.

Creates clearing settlement vouchers (Clearing → Bank) for payment methods that
opt in via PaymentMethod auto-settlement settings.

Important notes:
- We currently auto-create settlements with fee_amount=0.0.
  If a payment method uses commission_timing='settlement' and has commission_rate > 0,
  we skip it to avoid silently missing commission entries.
- Due calculation is based on SafeBoxTransaction ledger:
  invoice_payment transactions up to a cutoff date minus previous clearing_settlement
  voucher outs (FIFO-style approximation).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from threading import Thread

import schedule
from sqlalchemy import case, func

from models import db, PaymentMethod, SafeBoxTransaction, Voucher


@dataclass
class _DueAmounts:
    payments_up_to_cutoff: float
    settled_total: float
    due_amount: float


class ClearingSettlementScheduler:
    def __init__(self, app):
        self.app = app
        self.is_running = False

    def _compute_due_amount(self, safe_box_id: int, cutoff_dt: datetime) -> _DueAmounts:
        # Sum invoice payments up to cutoff
        payments_signed = func.coalesce(
            func.sum(
                case(
                    (SafeBoxTransaction.direction == 'in', SafeBoxTransaction.amount_cash),
                    else_=-SafeBoxTransaction.amount_cash,
                )
            ),
            0.0,
        )

        payments_up_to_cutoff = (
            db.session.query(payments_signed)
            .filter(
                SafeBoxTransaction.safe_box_id == safe_box_id,
                SafeBoxTransaction.ref_type == 'invoice_payment',
                SafeBoxTransaction.created_at <= cutoff_dt,
            )
            .scalar()
            or 0.0
        )

        # Sum previous clearing settlements (including reversals) to avoid double-settling.
        settled_signed = func.coalesce(
            func.sum(
                case(
                    (SafeBoxTransaction.direction == 'out', SafeBoxTransaction.amount_cash),
                    else_=-SafeBoxTransaction.amount_cash,
                )
            ),
            0.0,
        )

        settled_total = (
            db.session.query(settled_signed)
            .join(Voucher, Voucher.id == SafeBoxTransaction.ref_id)
            .filter(
                SafeBoxTransaction.safe_box_id == safe_box_id,
                SafeBoxTransaction.ref_type.in_(['voucher', 'voucher_reversal']),
                Voucher.reference_type == 'clearing_settlement',
            )
            .scalar()
            or 0.0
        )

        due_amount = float(payments_up_to_cutoff or 0.0) - float(settled_total or 0.0)
        return _DueAmounts(
            payments_up_to_cutoff=float(payments_up_to_cutoff or 0.0),
            settled_total=float(settled_total or 0.0),
            due_amount=float(due_amount or 0.0),
        )

    def process_due_settlements(self):
        with self.app.app_context():
            from routes import _create_clearing_settlement_voucher

            today = date.today()
            weekday = today.weekday()  # 0=Mon .. 6=Sun

            methods = (
                PaymentMethod.query
                .filter_by(is_active=True, auto_settlement_enabled=True)
                .all()
            )

            if not methods:
                print('[ClearingSettlementScheduler] No enabled payment methods')
                return

            for pm in methods:
                try:
                    # Basic config
                    if not pm.default_safe_box_id:
                        continue
                    if not pm.settlement_bank_safe_box_id:
                        continue

                    clearing_sb = pm.default_safe_box
                    bank_sb = pm.settlement_bank_safe_box
                    if not clearing_sb or not bank_sb:
                        continue
                    if not getattr(clearing_sb, 'is_active', True) or not getattr(bank_sb, 'is_active', True):
                        continue

                    if (clearing_sb.safe_type or '').strip().lower() != 'clearing':
                        continue
                    if (bank_sb.safe_type or '').strip().lower() != 'bank':
                        continue

                    schedule_type = (pm.settlement_schedule_type or 'days').strip().lower()

                    # Determine if this method is due to run today, and compute cutoff.
                    cutoff_days = int(pm.settlement_days or 0)
                    if schedule_type == 'weekday':
                        if pm.settlement_weekday is None:
                            continue
                        try:
                            configured_weekday = int(pm.settlement_weekday)
                        except Exception:
                            continue
                        if configured_weekday < 0 or configured_weekday > 6:
                            continue
                        if configured_weekday != weekday:
                            continue
                        # Default weekly: settle up to yesterday (or more if settlement_days>0)
                        cutoff_days = max(cutoff_days, 1)
                    else:
                        schedule_type = 'days'

                    cutoff_date = today - timedelta(days=max(cutoff_days, 0))
                    cutoff_dt = datetime.combine(cutoff_date, time.max)

                    due = self._compute_due_amount(pm.default_safe_box_id, cutoff_dt)
                    gross_amount = round(max(0.0, due.due_amount), 2)

                    # Nothing due
                    if gross_amount < 0.01:
                        continue

                    # Cap to current clearing balance for safety
                    try:
                        clearing_balance = float(getattr(getattr(clearing_sb, 'account', None), 'balance_cash', 0.0) or 0.0)
                    except Exception:
                        clearing_balance = 0.0

                    if clearing_balance <= 0.0:
                        continue
                    if gross_amount > clearing_balance:
                        gross_amount = round(clearing_balance, 2)

                    if gross_amount < 0.01:
                        continue

                    # Fee policy: we currently only auto-settle with fee=0.0
                    try:
                        timing = str(getattr(pm, 'commission_timing', 'invoice') or 'invoice').strip().lower()
                    except Exception:
                        timing = 'invoice'
                    if timing == 'settlement' and float(getattr(pm, 'commission_rate', 0.0) or 0.0) > 0:
                        print(
                            f"[ClearingSettlementScheduler] Skipping PM#{pm.id} ({pm.name}): commission_timing=settlement requires fee handling"
                        )
                        continue

                    reference_number = f"AUTO-PM-{pm.id}-{today.isoformat()}"
                    description = (
                        f"تسوية تلقائية لمستحقات التحصيل: {pm.name} "
                        f"({clearing_sb.name} → {bank_sb.name})"
                    )

                    try:
                        result = _create_clearing_settlement_voucher(
                            clearing_safe_box_id=clearing_sb.id,
                            bank_safe_box_id=bank_sb.id,
                            gross_amount=gross_amount,
                            fee_amount=0.0,
                            settlement_dt=datetime.now(),
                            reference_number=reference_number,
                            created_by='scheduler',
                            fee_account_id=None,
                            description_override=description,
                            notes='auto_settlement',
                            ensure_unique_reference=True,
                        )
                        # If the helper reports it was skipped (idempotent), don't commit anything.
                        if result.get('skipped'):
                            db.session.rollback()
                            continue

                        db.session.commit()
                        print(
                            f"[ClearingSettlementScheduler] ✓ Settled {gross_amount:.2f} for PM#{pm.id} ({pm.name})"
                        )
                    except Exception as exc:
                        db.session.rollback()
                        print(
                            f"[ClearingSettlementScheduler] ❌ Failed PM#{pm.id} ({pm.name}): {exc}"
                        )

                except Exception as exc:
                    db.session.rollback()
                    print(f"[ClearingSettlementScheduler] ❌ Unexpected error for PM#{getattr(pm, 'id', '?')}: {exc}")

    def setup_schedule(self):
        # Run once per day at 04:10.
        schedule.every().day.at('04:10').do(self.process_due_settlements)
        print('[ClearingSettlementScheduler] ✓ Auto settlement scheduled daily at 04:10')

    def start(self):
        if self.is_running:
            print('[ClearingSettlementScheduler] already running')
            return

        self.setup_schedule()
        self.is_running = True

        def run_scheduler():
            while self.is_running:
                schedule.run_pending()
                # Check every minute
                import time as _time

                _time.sleep(60)

        thread = Thread(target=run_scheduler, daemon=True)
        thread.start()
        print('[ClearingSettlementScheduler] 🚀 started')

    def stop(self):
        self.is_running = False
        schedule.clear()
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
