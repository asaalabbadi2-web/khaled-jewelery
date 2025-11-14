"""
إضافة صلاحيات السندات
Add Voucher Permissions
"""

from app import app, db
from models import Permission, Role

def add_voucher_permissions():
    """إضافة صلاحيات السندات"""
    
    with app.app_context():
        voucher_permissions = [
            {
                'code': 'voucher.view',
                'name': 'View Vouchers',
                'name_ar': 'عرض السندات',
                'description': 'القدرة على عرض السندات',
                'category': 'vouchers'
            },
            {
                'code': 'voucher.create',
                'name': 'Create Voucher',
                'name_ar': 'إنشاء سند',
                'description': 'القدرة على إنشاء سندات جديدة',
                'category': 'vouchers'
            },
            {
                'code': 'voucher.edit',
                'name': 'Edit Voucher',
                'name_ar': 'تعديل سند',
                'description': 'القدرة على تعديل السندات',
                'category': 'vouchers'
            },
            {
                'code': 'voucher.delete',
                'name': 'Delete Voucher',
                'name_ar': 'حذف سند',
                'description': 'القدرة على حذف السندات',
                'category': 'vouchers'
            },
            {
                'code': 'voucher.approve',
                'name': 'Approve Voucher',
                'name_ar': 'الموافقة على السندات',
                'description': 'القدرة على الموافقة على السندات أو رفضها',
                'category': 'vouchers'
            },
            {
                'code': 'voucher.cancel',
                'name': 'Cancel Voucher',
                'name_ar': 'إلغاء سند',
                'description': 'القدرة على إلغاء السندات',
                'category': 'vouchers'
            }
        ]
        
        added_count = 0
        
        for perm_data in voucher_permissions:
            # فحص إذا كانت الصلاحية موجودة
            existing = Permission.query.filter_by(code=perm_data['code']).first()
            
            if not existing:
                permission = Permission(**perm_data)
                db.session.add(permission)
                added_count += 1
                print(f"✅ تمت إضافة: {perm_data['name_ar']} ({perm_data['code']})")
            else:
                print(f"⏭️  موجودة مسبقاً: {perm_data['name_ar']} ({perm_data['code']})")
        
        db.session.commit()
        
        print(f"\n✅ تمت إضافة {added_count} صلاحية جديدة")
        
        # إضافة الصلاحيات للأدمن
        admin_role = Role.query.filter_by(name='admin').first()
        if admin_role:
            for perm_data in voucher_permissions:
                perm = Permission.query.filter_by(code=perm_data['code']).first()
                if perm and not admin_role.has_permission(perm_data['code']):
                    admin_role.add_permission(perm)
            
            db.session.commit()
            print(f"✅ تمت إضافة جميع صلاحيات السندات لدور Admin")

if __name__ == '__main__':
    add_voucher_permissions()
