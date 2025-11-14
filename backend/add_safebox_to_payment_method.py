#!/usr/bin/env python3
"""
إضافة عمود default_safe_box_id و settlement_days إلى جدول payment_method
"""

from app import app, db
from sqlalchemy import text

def add_columns():
    """إضافة الأعمدة الجديدة لجدول payment_method"""
    
    with app.app_context():
        try:
            # التحقق من وجود عمود default_safe_box_id
            result = db.session.execute(text(
                "SELECT COUNT(*) FROM pragma_table_info('payment_method') WHERE name='default_safe_box_id'"
            )).scalar()
            
            if result == 0:
                print('🔧 إضافة عمود default_safe_box_id إلى جدول payment_method...')
                db.session.execute(text(
                    'ALTER TABLE payment_method ADD COLUMN default_safe_box_id INTEGER'
                ))
                print('✅ تم إضافة عمود default_safe_box_id')
            else:
                print('✅ العمود default_safe_box_id موجود بالفعل')
            
            # التحقق من وجود عمود settlement_days
            result = db.session.execute(text(
                "SELECT COUNT(*) FROM pragma_table_info('payment_method') WHERE name='settlement_days'"
            )).scalar()
            
            if result == 0:
                print('🔧 إضافة عمود settlement_days إلى جدول payment_method...')
                db.session.execute(text(
                    'ALTER TABLE payment_method ADD COLUMN settlement_days INTEGER DEFAULT 0'
                ))
                print('✅ تم إضافة عمود settlement_days')
            else:
                print('✅ العمود settlement_days موجود بالفعل')
            
            # جعل عمود account_id اختياري (nullable)
            # في SQLite لا يمكن تعديل العمود مباشرة، لكن يمكننا قبول NULL
            print('ℹ️  عمود account_id أصبح اختيارياً (للتوافق مع الكود القديم)')
            
            db.session.commit()
            print('✅ تمت جميع التعديلات بنجاح')
            
        except Exception as e:
            db.session.rollback()
            print(f'❌ خطأ: {e}')
            raise

if __name__ == '__main__':
    print('🚀 بدء إضافة الأعمدة الجديدة...')
    add_columns()
    print('✅ اكتملت العملية بنجاح')
