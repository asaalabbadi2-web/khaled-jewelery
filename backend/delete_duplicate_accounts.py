#!/usr/bin/env python
# -*- coding: utf-8 -*-
import sys, os
backend_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(backend_dir)
sys.path.insert(0, parent_dir)

from backend.app import app
from backend.models import db, Account

with app.app_context():
    # حذف الحسابات المكررة
    accounts = Account.query.filter(Account.account_number.in_(['1310000', '1310001'])).all()
    for acc in accounts:
        print(f'حذف: {acc.account_number} - {acc.name}')
        db.session.delete(acc)
    db.session.commit()
    print('✅ تم الحذف')
