"""وظيفة التسوية الشهرية لمشتريات الذهب.

تعمل في أول يوم من كل شهر عند 06:00 (توقيت الخادم).
تستدعي services.gold_acquisition_reconciliation.compute للشهر المنصرم،
وتُنشئ SystemAlert إن تجاوز التباين العتبة المحددة.

عتبة التنبيه (ALERT_THRESHOLD_SAR):
  الحد الأدنى 50 ريال — يمتص فروق التقريب على الأرقام الصغيرة.
  على أحجام أكبر: عدِّل إلى max(50, avg_buy_numerator * 0.005) عند الحاجة.

التصنيف: OPTIONAL — خرابه يُعيق الرقابة لا تدفق المال.
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timedelta
from threading import Thread

import schedule



ALERT_THRESHOLD_SAR: float = 50.0  # ريال — انظر تعليق الملف


class GoldAcquisitionReconciliationScheduler:
    RUN_AT = "06:00"  # توقيت الخادم؛ بعد نسخة الليل (02:00)

    def __init__(self, app):
        self.app = app
        self.is_running = False
        self._scheduler = schedule.Scheduler()

    # ── منطق التسوية ──────────────────────────────────────────────────────────

    def _run(self) -> dict:
        """تسوية الشهر المنصرم. يُستدعى داخل app context."""
        from models import GoldPrice, SystemAlert, db
        from services.gold_acquisition_reconciliation import compute
        from utils import get_main_karat

        today = datetime.now().date()
        last_month_end = today.replace(day=1) - timedelta(days=1)
        start_dt = datetime(last_month_end.year, last_month_end.month, 1)
        end_dt = datetime(last_month_end.year, last_month_end.month, last_month_end.day) + timedelta(days=1)
        period_label = last_month_end.strftime('%Y-%m')

        result = compute(start_dt, end_dt)
        discrepancy = result['discrepancy']
        unlinked = result['je_path']['unlinked_gold_cash']
        numerator = result['avg_buy_path']['avg_buy_numerator']

        # عتبة قابلة للضبط: الحد الأدنى 50 ريال أو 0.5% من البسط أيّهما أكبر
        threshold = max(ALERT_THRESHOLD_SAR, numerator * 0.005)

        # ── D-1(2b) بيانات المراقبة — تُسجَّل في كل تشغيل لتعيير حارس المعقولية
        denominator = result['avg_buy_path'].get('avg_buy_denominator', 0.0)
        tag = '[GoldAcquisitionReconciliation]'
        if denominator and denominator > 0:
            avg_buy_per_gram = numerator / denominator
            main_karat = get_main_karat()
            latest_price = (
                GoldPrice.query
                .filter(GoldPrice.date < end_dt)
                .order_by(GoldPrice.date.desc())
                .first()
            )
            if latest_price:
                from pricing.office_price import row_gram_price
                ref_sar_gram_mk = row_gram_price(latest_price, main_karat)
                ratio = avg_buy_per_gram / ref_sar_gram_mk if ref_sar_gram_mk else None
                prefix = (
                    f"{tag} [D-1(2b) obs] period={period_label} "
                    f"avg_buy_per_gram={avg_buy_per_gram:.4f} "
                    f"ref_sar_gram_mk={ref_sar_gram_mk:.4f} "
                )
                suffix = f"ratio={ratio:.4f}" if ratio is not None else "ref_sar_gram_mk=0"
                print(prefix + suffix)
            else:
                print(f"{tag} [D-1(2b) obs] period={period_label} — لا سعر ذهب متاح للفترة")
        else:
            print(f"{tag} [D-1(2b) obs] period={period_label} — denominator=0 (لا مشتريات في الفترة)")

        if abs(discrepancy) <= threshold:
            return {'period': period_label, 'alerted': False, 'discrepancy': discrepancy}

        # حدِّد الشدة: القيود غير المرتبطة أخطر من الفواتير بلا ترحيل
        if unlinked > threshold:
            severity = 'critical'
            title = f'تجاوز مسار اقتناء الذهب — {period_label}'
            message = (
                f'{unlinked:,.2f} ريال خرجت لاقتناء ذهب عبر قيود يدوية '
                f'خارج نظام الفواتير ({period_label}). '
                f'راجع je_path.unlinked_gold_cash في تقرير التسوية.'
            )
        else:
            severity = 'warning'
            title = f'تباين تسوية مشتريات الذهب — {period_label}'
            message = (
                f'التباين = {discrepancy:+,.2f} ريال للشهر {period_label}. '
                f'{"فواتير بلا قيود مُرحَّلة." if discrepancy < 0 else "قيود تفوق الفواتير."}'
            )

        alert = SystemAlert(
            alert_type='gold_acquisition_reconciliation',
            severity=severity,
            title=title,
            message=message,
            entity_type='GoldAcquisitionReconciliation',
            entity_number=period_label,
            details=json.dumps(result, ensure_ascii=False),
            created_by='gold_acquisition_reconciliation_scheduler',
        )
        db.session.add(alert)
        db.session.commit()

        return {'period': period_label, 'alerted': True, 'severity': severity, 'discrepancy': discrepancy}

    # ── وظيفة الجدول ─────────────────────────────────────────────────────────

    def reconciliation_job(self) -> None:
        if datetime.now().day != 1:
            return  # تعمل فقط في أول يوم من الشهر

        tag = '[GoldAcquisitionReconciliation]'
        with self.app.app_context():
            try:
                outcome = self._run()
                if outcome.get('alerted'):
                    print(
                        f"{tag} تنبيه {outcome['severity']} — "
                        f"الفترة={outcome['period']}, التباين={outcome['discrepancy']:+,.2f} ريال"
                    )
                else:
                    print(f"{tag} نظيف — الفترة={outcome.get('period')}, التباين={outcome.get('discrepancy', 0):+,.2f}")
            except Exception as exc:
                print(f"{tag} خطأ غير متوقع: {exc}")

    # ── تمديد الحلقة ─────────────────────────────────────────────────────────

    def _loop(self) -> None:
        while self.is_running:
            self._scheduler.run_pending()
            time.sleep(30)

    def start(self) -> None:
        if self.is_running:
            return
        self.is_running = True
        self._scheduler.every().day.at(self.RUN_AT).do(self.reconciliation_job).tag(
            'gold_acquisition_reconciliation'
        )
        thread = Thread(
            target=self._loop,
            name='GoldAcquisitionReconciliationScheduler',
            daemon=True,
        )
        thread.start()
        print(
            f'[GoldAcquisitionReconciliationScheduler] بدأ — '
            f'يعمل يومياً عند {self.RUN_AT} (ينفِّذ التسوية في اليوم الأول من الشهر فقط)'
        )


def start_gold_acquisition_reconciliation_scheduler(app):
    scheduler = GoldAcquisitionReconciliationScheduler(app)
    scheduler.start()
    return scheduler
