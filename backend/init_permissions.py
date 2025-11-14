#!/usr/bin/env python3
"""
سكريبت تهيئة نظام الصلاحيات
===============================

يقوم بإنشاء:
1. الصلاحيات الافتراضية
2. أدوار افتراضية
3. مستخدم المدير الرئيسي
"""

import sys
import os

# إضافة مسار المشروع
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import app, db
from models import User, Role, Permission

def initialize_permissions():
    """إنشاء الصلاحيات الافتراضية"""
    print("🔐 إنشاء الصلاحيات الافتراضية...")
    
    with app.app_context():
        count = Permission.initialize_default_permissions()
        print(f"✅ تم إنشاء {count} صلاحية جديدة")
        
        # عرض إجمالي الصلاحيات
        total = Permission.query.count()
        print(f"📊 إجمالي الصلاحيات في النظام: {total}")
        
        return count

def create_default_roles():
    """إنشاء الأدوار الافتراضية"""
    print("\n👥 إنشاء الأدوار الافتراضية...")
    
    with app.app_context():
        roles_data = [
            {
                'name': 'admin',
                'name_ar': 'مدير النظام',
                'description': 'صلاحيات كاملة على جميع وظائف النظام',
                'is_system': True,
                'permissions': Permission.query.all()  # جميع الصلاحيات
            },
            {
                'name': 'accountant',
                'name_ar': 'محاسب',
                'description': 'صلاحيات محاسبية شاملة مع القدرة على الترحيل',
                'is_system': True,
                'permissions': Permission.query.filter(
                    Permission.category.in_(['invoices', 'journal', 'reports'])
                ).all()
            },
            {
                'name': 'cashier',
                'name_ar': 'أمين صندوق',
                'description': 'إنشاء وعرض الفواتير فقط',
                'is_system': True,
                'permissions': Permission.query.filter(
                    Permission.code.in_(['invoice.view', 'invoice.create'])
                ).all()
            },
            {
                'name': 'viewer',
                'name_ar': 'مستعرض',
                'description': 'صلاحيات العرض فقط',
                'is_system': True,
                'permissions': Permission.query.filter(
                    Permission.code.like('%.view')
                ).all()
            }
        ]
        
        created_count = 0
        for role_data in roles_data:
            existing = Role.query.filter_by(name=role_data['name']).first()
            if not existing:
                permissions = role_data.pop('permissions')
                role = Role(**role_data, created_by='system')
                role.permissions = permissions
                db.session.add(role)
                created_count += 1
                print(f"  ✅ تم إنشاء دور: {role_data['name_ar']}")
            else:
                print(f"  ⏭️  دور موجود: {role_data['name_ar']}")
        
        try:
            db.session.commit()
            print(f"\n✅ تم إنشاء {created_count} دور جديد")
            
            # عرض إجمالي الأدوار
            total = Role.query.count()
            print(f"📊 إجمالي الأدوار في النظام: {total}")
            
            return created_count
        except Exception as e:
            db.session.rollback()
            print(f"❌ خطأ في إنشاء الأدوار: {e}")
            return 0

def create_admin_user():
    """إنشاء مستخدم المدير الرئيسي"""
    print("\n👤 إنشاء مستخدم المدير الرئيسي...")
    
    with app.app_context():
        existing = User.query.filter_by(username='admin').first()
        if existing:
            print("  ⏭️  المستخدم 'admin' موجود بالفعل")
            return False
        
        # إنشاء المستخدم
        admin = User(
            username='admin',
            email='admin@yasargold.com',
            full_name='مدير النظام',
            is_active=True,
            is_admin=True,
            department='إدارة',
            position='مدير النظام',
            created_by='system'
        )
        admin.set_password('admin123')  # كلمة مرور افتراضية
        
        # إضافة دور المدير
        admin_role = Role.query.filter_by(name='admin').first()
        if admin_role:
            admin.roles.append(admin_role)
        
        db.session.add(admin)
        
        try:
            db.session.commit()
            print("  ✅ تم إنشاء المستخدم: admin")
            print("  🔑 كلمة المرور الافتراضية: admin123")
            print("  ⚠️  يُرجى تغيير كلمة المرور فورًا!")
            return True
        except Exception as e:
            db.session.rollback()
            print(f"  ❌ خطأ في إنشاء المستخدم: {e}")
            return False

def main():
    """التنفيذ الرئيسي"""
    print("=" * 60)
    print("🚀 تهيئة نظام الصلاحيات - Yasar Gold POS")
    print("=" * 60)
    
    # 1. إنشاء الصلاحيات
    permissions_count = initialize_permissions()
    
    # 2. إنشاء الأدوار
    roles_count = create_default_roles()
    
    # 3. إنشاء المستخدم الرئيسي
    admin_created = create_admin_user()
    
    # ملخص
    print("\n" + "=" * 60)
    print("📋 ملخص التهيئة:")
    print("=" * 60)
    print(f"  • الصلاحيات المُنشأة: {permissions_count}")
    print(f"  • الأدوار المُنشأة: {roles_count}")
    print(f"  • مستخدم المدير: {'✅ تم الإنشاء' if admin_created else '⏭️  موجود'}")
    print("=" * 60)
    print("✅ اكتمال التهيئة بنجاح!")
    print("\n💡 معلومات تسجيل الدخول:")
    print("   اسم المستخدم: admin")
    print("   كلمة المرور: admin123")
    print("   ⚠️  يُرجى تغيير كلمة المرور فورًا!\n")

if __name__ == '__main__':
    main()
