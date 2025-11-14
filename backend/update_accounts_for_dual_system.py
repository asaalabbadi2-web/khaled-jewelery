"""
تحديث الحسابات لتفعيل النظام المزدوج
"""
from app import app, db
from models import Account

def update_accounts_for_dual_system():
    with app.app_context():
        # الحسابات التي تتعامل مع الوزن
        accounts_to_track_weight = [
            # حسابات المخزون (عيار 18، 21، 22، 24)
            '22',  # مخزون عيار 24
            '23',  # مخزون عيار 22
            '24',  # مخزون عيار 21
            '25',  # مخزون عيار 18
            # حسابات المبيعات
            '55',  # مبيعات ذهب جديد
            '56',  # مبيعات كسر وتسكير
            # حسابات المشتريات
            '95',  # مشتريات كسر وتسكير
            # حساب تكلفة المبيعات
            '83',  # تكلفة المبيعات
        ]
        
        updated_count = 0
        for acc_number in accounts_to_track_weight:
            account = Account.query.filter_by(account_number=acc_number).first()
            if account:
                account.tracks_weight = True
                updated_count += 1
                print(f'✅ تم تفعيل تتبع الوزن للحساب: {acc_number} - {account.name}')
            else:
                print(f'⚠️  الحساب غير موجود: {acc_number}')
        
        db.session.commit()
        print(f'\n✅ تم تحديث {updated_count} حساب لتتبع الوزن!')
        
        # عرض الحسابات المحدثة
        print('\n📊 الحسابات التي تتتبع الوزن:')
        tracked_accounts = Account.query.filter_by(tracks_weight=True).all()
        for acc in tracked_accounts:
            print(f'  - {acc.account_number}: {acc.name}')

if __name__ == '__main__':
    update_accounts_for_dual_system()
