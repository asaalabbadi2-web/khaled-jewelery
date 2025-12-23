#!/usr/bin/env python3
"""
سكريبت حساب المكافآت التلقائية
==========================================
يتم تشغيله شهرياً عبر Cron Job أو Task Scheduler

الاستخدام:
    python process_bonuses.py [--month YYYY-MM] [--auto-approve]

مثال:
    python process_bonuses.py --month 2025-12 --auto-approve
"""

import sys
import os
from datetime import datetime, date
from calendar import monthrange
import argparse

# إضافة مسار المشروع إلى Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import app
from bonus_calculator import BonusCalculator


def get_month_range(year, month):
    """الحصول على نطاق تواريخ شهر محدد"""
    start_date = date(year, month, 1)
    
    # آخر يوم من الشهر
    last_day = monthrange(year, month)[1]
    end_date = date(year, month, last_day)
    
    return start_date, end_date


def main():
    """معالجة المكافآت الشهرية"""
    parser = argparse.ArgumentParser(description='حساب المكافآت التلقائية للموظفين')
    parser.add_argument(
        '--month',
        type=str,
        help='الشهر بصيغة YYYY-MM (افتراضي: الشهر الماضي)',
        default=None
    )
    parser.add_argument(
        '--auto-approve',
        action='store_true',
        help='اعتماد المكافآت تلقائياً'
    )
    
    args = parser.parse_args()
    
    # تحديد الفترة
    if args.month:
        try:
            year, month = map(int, args.month.split('-'))
            period_start, period_end = get_month_range(year, month)
        except ValueError:
            print("❌ خطأ: صيغة الشهر غير صحيحة. استخدم YYYY-MM")
            return 1
    else:
        # افتراضياً: الشهر الماضي
        today = date.today()
        if today.month == 1:
            last_month_year = today.year - 1
            last_month_month = 12
        else:
            last_month_year = today.year
            last_month_month = today.month - 1
        
        period_start, period_end = get_month_range(last_month_year, last_month_month)
    
    print(f"{'='*60}")
    print(f"حساب المكافآت - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*60}\n")
    print(f"الفترة: من {period_start} إلى {period_end}")
    print(f"اعتماد تلقائي: {'نعم' if args.auto_approve else 'لا'}\n")
    
    with app.app_context():
        try:
            # حساب المكافآت
            bonuses = BonusCalculator.calculate_all_bonuses_for_period(
                period_start=period_start,
                period_end=period_end,
                auto_approve=args.auto_approve
            )
            
            if bonuses:
                total_amount = sum(b.amount for b in bonuses)
                
                print(f"\n✓ تم حساب {len(bonuses)} مكافأة بنجاح:")
                print(f"{'-'*60}")
                
                # تجميع حسب نوع المكافأة
                by_type = {}
                for bonus in bonuses:
                    if bonus.bonus_type not in by_type:
                        by_type[bonus.bonus_type] = {'count': 0, 'amount': 0.0}
                    by_type[bonus.bonus_type]['count'] += 1
                    by_type[bonus.bonus_type]['amount'] += bonus.amount
                
                for bonus_type, stats in by_type.items():
                    print(f"  • {bonus_type}: {stats['count']} مكافأة - {stats['amount']:.2f} ريال")
                
                print(f"\nإجمالي المكافآت: {total_amount:.2f} ريال")
                print(f"الحالة: {'معتمدة' if args.auto_approve else 'معلقة (تحتاج اعتماد)'}")
            else:
                print("ℹ️  لم يتم حساب أي مكافآت (لا موظفون مؤهلون أو لا قواعد نشطة)")
            
            print(f"\n{'='*60}")
            print(f"اكتملت العملية بنجاح")
            print(f"{'='*60}\n")
            
            return 0
            
        except Exception as e:
            print(f"\n❌ خطأ في حساب المكافآت: {e}")
            import traceback
            traceback.print_exc()
            return 1


if __name__ == '__main__':
    sys.exit(main())
