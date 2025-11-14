#!/usr/bin/env python3
"""
إضافة عمود safe_box_id إلى جدول invoice
"""

from app import app, db
from sqlalchemy import text

def add_safe_box_column():
    """إضافة عمود safe_box_id لجدول invoice"""
    
    with app.app_context():
        try:
            # التحقق من وجود العمود
            result = db.session.execute(text(
                "SELECT COUNT(*) FROM pragma_table_info('invoice') WHERE name='safe_box_id'"
            )).scalar()
            
            if result > 0:
                print('✅ العمود safe_box_id موجود بالفعل في جدول invoice')
                return
            
            # إضافة العمود
            print('🔧 إضافة عمود safe_box_id إلى جدول invoice...')
            db.session.execute(text(
                'ALTER TABLE invoice ADD COLUMN safe_box_id INTEGER'
            ))
            
            # إضافة Foreign Key (SQLite يتطلب إعادة بناء الجدول لإضافة FK)
            # لكن يمكننا تركه بدون FK constraint لأن SQLAlchemy ستديره
            
            db.session.commit()
            print('✅ تم إضافة عمود safe_box_id بنجاح')
            
        except Exception as e:
            db.session.rollback()
            print(f'❌ خطأ: {e}')
            raise

if __name__ == '__main__':
    print('🚀 بدء إضافة عمود safe_box_id...')
    add_safe_box_column()
    print('✅ اكتملت العملية بنجاح')
