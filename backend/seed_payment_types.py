"""
تعبئة جدول أنواع وسائل الدفع بالبيانات الافتراضية
"""
import sys
import os

# إضافة المسار الحالي
sys.path.insert(0, os.path.dirname(__file__))

from app import app, db
from models import PaymentType

def seed_payment_types():
    """إضافة أنواع وسائل الدفع الافتراضية"""
    
    payment_types_data = [
        # البطاقات البنكية
        {'code': 'mada', 'name_ar': 'مدى', 'name_en': 'Mada', 'icon': '💳', 'category': 'card', 'sort_order': 1},
        {'code': 'visa', 'name_ar': 'فيزا', 'name_en': 'Visa', 'icon': '💳', 'category': 'card', 'sort_order': 2},
        {'code': 'mastercard', 'name_ar': 'ماستركارد', 'name_en': 'Mastercard', 'icon': '💳', 'category': 'card', 'sort_order': 3},
        {'code': 'amex', 'name_ar': 'أمريكان إكسبريس', 'name_en': 'American Express', 'icon': '💳', 'category': 'card', 'sort_order': 4},
        
        # المحافظ الإلكترونية
        {'code': 'apple_pay', 'name_ar': 'Apple Pay', 'name_en': 'Apple Pay', 'icon': '📱', 'category': 'mobile_wallet', 'sort_order': 5},
        {'code': 'stc_pay', 'name_ar': 'STC Pay', 'name_en': 'STC Pay', 'icon': '📱', 'category': 'mobile_wallet', 'sort_order': 6},
        {'code': 'urpay', 'name_ar': 'يور باي', 'name_en': 'UrPay', 'icon': '📱', 'category': 'mobile_wallet', 'sort_order': 7},
        
        # اشتر الآن وادفع لاحقاً (BNPL)
        {'code': 'tamara', 'name_ar': 'تمارا', 'name_en': 'Tamara', 'icon': '🛍️', 'category': 'bnpl', 'sort_order': 8},
        {'code': 'tabby', 'name_ar': 'تابي', 'name_en': 'Tabby', 'icon': '🛍️', 'category': 'bnpl', 'sort_order': 9},
        
        # النقد
        {'code': 'cash', 'name_ar': 'نقداً', 'name_en': 'Cash', 'icon': '💵', 'category': 'cash', 'sort_order': 10},
        
        # العملات الرقمية (مثال)
        {'code': 'crypto', 'name_ar': 'عملات رقمية', 'name_en': 'Cryptocurrency', 'icon': '₿', 'category': 'crypto', 'sort_order': 11},
    ]
    
    with app.app_context():
        for pt_data in payment_types_data:
            # تحقق من عدم وجود النوع مسبقاً
            existing = PaymentType.query.filter_by(code=pt_data['code']).first()
            if not existing:
                payment_type = PaymentType(**pt_data)
                db.session.add(payment_type)
                print(f"✅ تمت إضافة: {pt_data['name_ar']} ({pt_data['code']})")
            else:
                print(f"⏭️  موجود مسبقاً: {pt_data['name_ar']} ({pt_data['code']})")
        
        db.session.commit()
        print("\n🎉 تم إنشاء جدول أنواع وسائل الدفع بنجاح!")
        print("📋 لإضافة نوع جديد:")
        print("   POST /api/payment-types")
        print("   {'code': 'new_type', 'name_ar': 'الاسم', 'icon': '🎯', 'category': 'card'}")

if __name__ == '__main__':
    seed_payment_types()
