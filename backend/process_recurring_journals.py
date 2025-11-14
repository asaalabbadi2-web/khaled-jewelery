#!/usr/bin/env python3
"""
سكريبت معالجة القيود الدورية التلقائية
==========================================
يتم تشغيله يومياً عبر Cron Job أو Task Scheduler

الاستخدام:
    python process_recurring_journals.py
"""

import sys
import os
from datetime import datetime

# إضافة مسار المشروع إلى Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import app
from backend.recurring_journal_system import process_recurring_journals


def main():
    """معالجة القيود الدورية المستحقة"""
    print(f"{'='*60}")
    print(f"معالجة القيود الدورية - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*60}\n")
    
    with app.app_context():
        try:
            # معالجة القيود
            created_entries = process_recurring_journals()
            
            if created_entries:
                print(f"\n✓ تم إنشاء {len(created_entries)} قيد دوري بنجاح:")
                print(f"{'-'*60}")
                
                for entry in created_entries:
                    print(f"  • رقم القيد: {entry.entry_number}")
                    print(f"    التاريخ: {entry.date.strftime('%Y-%m-%d')}")
                    print(f"    الوصف: {entry.description}")
                    print(f"    القالب: {entry.recurring_template_id}")
                    print()
            else:
                print("ℹ️  لا توجد قيود دورية مستحقة في الوقت الحالي")
            
            print(f"\n{'='*60}")
            print(f"اكتملت العملية بنجاح")
            print(f"{'='*60}\n")
            
            return 0
            
        except Exception as e:
            print(f"\n✗ خطأ في معالجة القيود الدورية:")
            print(f"  {str(e)}\n")
            import traceback
            traceback.print_exc()
            
            return 1


if __name__ == '__main__':
    exit_code = main()
    sys.exit(exit_code)
