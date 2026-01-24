#!/usr/bin/env python3
"""
إصلاح الحسابات اليتيمة (بدون أب) عن طريق ربطها بالآباء المناسبين.

المشكلة: بعض الحسابات أُنشئت بدون parent_id مما يجعلها تظهر كجذور في الشجرة.

الحل: ربط كل حساب بأبيه المنطقي بناءً على رقم الحساب:
- 1111-1119 -> تحت 110 (النقدية والبنوك)
- 5111-5116 -> تحت 51 (مصاريف تشغيلية)
- 1400 -> حذف (حساب قديم)
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from typing import Optional
from app import app, db
from models import Account


def find_logical_parent(account_number: str) -> Optional[int]:
    """Find the logical parent account ID based on account number hierarchy."""
    num = str(account_number)
    
    # Try progressively shorter prefixes to find a parent
    # e.g., 1111 -> try 111 -> 11 -> 1
    for length in range(len(num) - 1, 0, -1):
        prefix = num[:length]
        parent = Account.query.filter_by(account_number=prefix).first()
        if parent:
            return parent.id
    
    return None


def fix_orphan_accounts(dry_run: bool = True) -> dict:
    """Fix accounts that have parent_id=None but should have a parent."""
    
    with app.app_context():
        # Get all accounts with no parent (except true roots: 1, 2, 3, 4, 5, 7x)
        true_roots = {'1', '2', '3', '4', '5', '71', '72', '73', '74', '75'}
        
        orphans = Account.query.filter(Account.parent_id.is_(None)).all()
        orphans = [a for a in orphans if str(a.account_number) not in true_roots]
        
        results = {
            'total_orphans': len(orphans),
            'fixed': [],
            'no_parent_found': [],
            'deleted': [],
            'dry_run': dry_run,
        }
        
        for account in orphans:
            num = str(account.account_number)
            
            # Special case: 1400 is legacy, should be deleted
            if num == '1400':
                if not dry_run:
                    # Check if account has journal entries
                    from models import JournalEntryLine
                    has_entries = JournalEntryLine.query.filter_by(account_id=account.id).first()
                    if has_entries:
                        results['no_parent_found'].append({
                            'account_number': num,
                            'name': account.name,
                            'reason': 'Has journal entries, cannot delete'
                        })
                    else:
                        db.session.delete(account)
                        results['deleted'].append({
                            'account_number': num,
                            'name': account.name
                        })
                else:
                    results['deleted'].append({
                        'account_number': num,
                        'name': account.name,
                        'action': 'would_delete'
                    })
                continue
            
            # Find logical parent
            parent_id = find_logical_parent(num)
            
            if parent_id:
                old_parent = account.parent_id
                if not dry_run:
                    account.parent_id = parent_id
                
                parent_acc = Account.query.get(parent_id)
                results['fixed'].append({
                    'account_number': num,
                    'name': account.name,
                    'old_parent_id': old_parent,
                    'new_parent_id': parent_id,
                    'new_parent_number': parent_acc.account_number if parent_acc else None,
                })
            else:
                results['no_parent_found'].append({
                    'account_number': num,
                    'name': account.name,
                    'reason': 'No matching parent prefix found'
                })
        
        if not dry_run:
            db.session.commit()
            print(f"✅ Committed changes to database")
        
        return results


def print_results(results: dict):
    """Pretty print the results."""
    print(f"\n{'='*60}")
    print(f"إصلاح الحسابات اليتيمة")
    print(f"{'='*60}")
    print(f"الوضع: {'معاينة فقط (dry run)' if results['dry_run'] else 'تم التنفيذ'}")
    print(f"إجمالي الحسابات اليتيمة: {results['total_orphans']}")
    
    if results['fixed']:
        print(f"\n✅ تم إصلاح ({len(results['fixed'])}):")
        for item in results['fixed']:
            print(f"   {item['account_number']} ({item['name']}) -> أب: {item['new_parent_number']}")
    
    if results['deleted']:
        print(f"\n🗑️  تم/سيتم حذف ({len(results['deleted'])}):")
        for item in results['deleted']:
            print(f"   {item['account_number']} ({item['name']})")
    
    if results['no_parent_found']:
        print(f"\n⚠️  لم يتم العثور على أب ({len(results['no_parent_found'])}):")
        for item in results['no_parent_found']:
            print(f"   {item['account_number']} ({item['name']}) - {item.get('reason', '')}")
    
    print(f"\n{'='*60}")


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Fix orphan accounts')
    parser.add_argument('--execute', action='store_true', help='Actually execute changes (default is dry-run)')
    args = parser.parse_args()
    
    dry_run = not args.execute
    
    if not dry_run:
        print("⚠️  سيتم تنفيذ التغييرات فعلياً!")
        confirm = input("هل أنت متأكد؟ (yes/no): ")
        if confirm.lower() != 'yes':
            print("تم الإلغاء.")
            sys.exit(0)
    
    results = fix_orphan_accounts(dry_run=dry_run)
    print_results(results)
    
    if dry_run:
        print("\n💡 لتنفيذ التغييرات، شغّل:")
        print("   python devtools/fix_orphan_accounts.py --execute")
