"""
نظام الجدولة التلقائية للمكافآت
==========================================
المجدول هو المصدر الوحيد للاحتساب الرسمي للمكافآت.

دورة الحياة:
  Scheduler يحسب → EmployeeBonus(pending) → إدارة تعتمد → BAPP-{id} → محاسب يدفع → BPAY-{id}

لا يُنشئ المجدول أي قيد محاسبي. لا يعتمد تلقائياً.
كل تشغيل يُسجَّل في bonus_calculation_log.
"""

import schedule
import time
from threading import Thread
from datetime import datetime, date, timedelta
from calendar import monthrange
from bonus_calculator import BonusCalculator


def _write_log(app, period_type, period_start, period_end, bonuses=None, error=None):
    """يكتب سجل التشغيل في bonus_calculation_log — non-fatal."""
    try:
        with app.app_context():
            from models import db, BonusCalculationLog
            if error:
                log = BonusCalculationLog(
                    period_type=period_type,
                    period_start=period_start,
                    period_end=period_end,
                    bonus_count=0,
                    total_amount=0.0,
                    status='failed',
                    message=str(error)[:500],
                )
            else:
                pending = [b for b in (bonuses or []) if b.status == 'pending']
                log = BonusCalculationLog(
                    period_type=period_type,
                    period_start=period_start,
                    period_end=period_end,
                    bonus_count=len(pending),
                    total_amount=round(sum(b.amount for b in pending), 4),
                    status='success',
                    message=(
                        f'تم احتساب مكافآت {period_type}، '
                        f'وهناك {len(pending)} مكافأة بانتظار الاعتماد.'
                        if pending else 'لا توجد مكافآت جديدة لهذه الفترة.'
                    ),
                )
            db.session.add(log)
            db.session.commit()
    except Exception as _log_err:
        print(f'[BonusScheduler] ⚠️ فشل كتابة سجل التشغيل: {_log_err}')


class BonusScheduler:
    """مجدول المكافآت التلقائي — المصدر الوحيد للاحتساب الرسمي."""

    def __init__(self, app):
        self.app = app
        self.is_running = False
        self._scheduler = schedule.Scheduler()

    def calculate_daily_bonuses(self):
        """حساب المكافآت اليومية."""
        today = date.today()
        period_start = period_end = today - timedelta(days=1)
        with self.app.app_context():
            try:
                print(f'[BonusScheduler] حساب المكافآت اليومية: {period_start}')
                bonuses = BonusCalculator.calculate_all_bonuses_for_period(
                    period_start=period_start,
                    period_end=period_end,
                )
                pending = [b for b in bonuses if b.status == 'pending']
                print(f'[BonusScheduler] ✓ {len(pending)} مكافأة يومية pending')
            except Exception as e:
                bonuses = None
                print(f'[BonusScheduler] ❌ خطأ في المكافآت اليومية: {e}')
                _write_log(self.app, 'daily', period_start, period_end, error=e)
                return
        _write_log(self.app, 'daily', period_start, period_end, bonuses=bonuses)

    def calculate_weekly_bonuses(self):
        """حساب المكافآت الأسبوعية."""
        today = date.today()
        last_monday = today - timedelta(days=today.weekday() + 7)
        period_start = last_monday
        period_end = last_monday + timedelta(days=6)
        with self.app.app_context():
            try:
                print(f'[BonusScheduler] حساب المكافآت الأسبوعية: {period_start} إلى {period_end}')
                bonuses = BonusCalculator.calculate_all_bonuses_for_period(
                    period_start=period_start,
                    period_end=period_end,
                )
                pending = [b for b in bonuses if b.status == 'pending']
                print(f'[BonusScheduler] ✓ {len(pending)} مكافأة أسبوعية pending')
            except Exception as e:
                bonuses = None
                print(f'[BonusScheduler] ❌ خطأ في المكافآت الأسبوعية: {e}')
                _write_log(self.app, 'weekly', period_start, period_end, error=e)
                return
        _write_log(self.app, 'weekly', period_start, period_end, bonuses=bonuses)

    def calculate_monthly_bonuses(self):
        """حساب المكافآت الشهرية."""
        today = date.today()
        if today.month == 1:
            last_month_year, last_month = today.year - 1, 12
        else:
            last_month_year, last_month = today.year, today.month - 1
        period_start = date(last_month_year, last_month, 1)
        period_end = date(last_month_year, last_month, monthrange(last_month_year, last_month)[1])

        with self.app.app_context():
            try:
                print(f'[BonusScheduler] حساب المكافآت الشهرية: {period_start} إلى {period_end}')
                bonuses = BonusCalculator.calculate_all_bonuses_for_period(
                    period_start=period_start,
                    period_end=period_end,
                )
                pending = [b for b in bonuses if b.status == 'pending']
                total = sum(b.amount for b in pending)
                print(f'[BonusScheduler] ✓ {len(pending)} مكافأة شهرية pending بإجمالي {total} ريال')
            except Exception as e:
                bonuses = None
                print(f'[BonusScheduler] ❌ خطأ في المكافآت الشهرية: {e}')
                _write_log(self.app, 'monthly', period_start, period_end, error=e)
                return
        _write_log(self.app, 'monthly', period_start, period_end, bonuses=bonuses)

    def check_pending_bonuses(self):
        """فحص دوري — يطبع عدد المكافآت المعلقة."""
        with self.app.app_context():
            try:
                from models import EmployeeBonus
                pending_count = EmployeeBonus.query.filter_by(status='pending').count()
                if pending_count > 0:
                    print(f'[BonusScheduler] ⚠️ {pending_count} مكافأة معلقة بانتظار الاعتماد')
            except Exception as e:
                print(f'[BonusScheduler] ❌ خطأ في فحص المكافآت المعلقة: {e}')

    def _check_and_calculate_monthly(self):
        """يُشغَّل كل يوم — يُنفّذ الاحتساب فقط في اليوم الأول من الشهر."""
        if date.today().day == 1:
            self.calculate_monthly_bonuses()

    def setup_schedule(self):
        """إعداد جدول المهام."""
        self._scheduler.every().day.at('01:00').do(self.calculate_daily_bonuses)
        self._scheduler.every().monday.at('02:00').do(self.calculate_weekly_bonuses)
        self._scheduler.every().day.at('03:00').do(self._check_and_calculate_monthly)
        self._scheduler.every(6).hours.do(self.check_pending_bonuses)
        print('[BonusScheduler] ✓ جدول المكافآت التلقائية نشط')
        print('[BonusScheduler] - يومية: 01:00 | أسبوعية: الاثنين 02:00 | شهرية: أول الشهر 03:00')

    def start(self):
        """بدء المجدول في خيط daemon."""
        if self.is_running:
            print('[BonusScheduler] المجدول يعمل بالفعل')
            return
        self.setup_schedule()
        self.is_running = True

        def _loop():
            while self.is_running:
                self._scheduler.run_pending()
                time.sleep(60)

        Thread(target=_loop, daemon=True).start()
        print('[BonusScheduler] 🚀 بدأ مجدول المكافآت')

    def stop(self):
        """إيقاف المجدول."""
        self.is_running = False
        self._scheduler.clear()
        print('[BonusScheduler] ⏸️ توقف مجدول المكافآت')

    def run_now(self, task_type='daily'):
        """تشغيل مهمة فوراً — للاختبار والبيئات الاستعراضية."""
        dispatch = {
            'daily':   self.calculate_daily_bonuses,
            'weekly':  self.calculate_weekly_bonuses,
            'monthly': self.calculate_monthly_bonuses,
            'check':   self.check_pending_bonuses,
        }
        fn = dispatch.get(task_type)
        if fn:
            fn()
        else:
            print(f'[BonusScheduler] نوع مهمة غير معروف: {task_type}')


_scheduler_instance = None


def get_bonus_scheduler(app):
    """Singleton — نسخة واحدة فقط من المجدول."""
    global _scheduler_instance
    if _scheduler_instance is None:
        _scheduler_instance = BonusScheduler(app)
    return _scheduler_instance


def start_bonus_scheduler(app):
    scheduler = get_bonus_scheduler(app)
    scheduler.start()
    return scheduler
