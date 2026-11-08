"""ADR-087 R3's gate, through the routes the screens call, on a restored copy.

The owner's gate (ADR-087): three bangles of different weights in a line,
each with its wage (per gram x weight); a bullion line whose wage is given
whole and divided by its weight, each bar its share; no piece sold before
its wage is known. And: coded from stock, its wage by hand; a piece moved by
name and back; a tag mounted from the number and replaced; a piece sold by
its number -- once; its category not sold by weight; the nightly checks as
they were. It writes: on a copy, never a reference nor production.

    createdb -T ref_1105 r3gate
    DATABASE_URL=postgresql:///r3gate alembic upgrade head
    DATABASE_URL=postgresql:///r3gate python tools/receiving/r3_gate.py --showroom 30 --custody 39 --bangles 28

Result of 9 Nov 2026 on a copy of 5 Nov: 24 of 24 (ADR-087, R3's gate).
"""
import argparse
import os
import sys
from datetime import date, datetime

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--showroom', type=int, required=True)
    ap.add_argument('--custody', type=int, required=True)
    ap.add_argument('--bangles', type=int, required=True, help='the bangles category of 21')
    args = ap.parse_args(argv)
    database = os.environ.get('DATABASE_URL', '').rsplit('/', 1)[-1]
    if not database or database.startswith('ref_') or 'khaled' in database or database == 'yasargold':
        raise SystemExit(f'a copy, never a reference nor production: {database or "(none)"}')

    from flask import g
    from app import app
    from auth_decorators import generate_token
    from models import Category, Customer, Employee, InvoiceItem, Item, SafeBox, Settings, Supplier, User, db
    from services.pieces import line_wages, piece_held, piece_location
    from tools.receiving.parity import checks

    R = []

    def check(name, ok, detail=''):
        R.append((name, ok))
        print(('PASS' if ok else 'FAIL'), name, detail)

    with app.app_context():
        s = Settings.query.first(); s.receiving_from = date(2026, 1, 1); db.session.commit()
        admin = User.query.filter_by(is_admin=True, is_active=True).first()
        H = {'Authorization': f'Bearer {generate_token(admin)}'}
        c = app.test_client()
        def call(m, url, **kw):
            g.pop('current_user', None)
            r = getattr(c, m)(url, headers=H, **kw)
            return r.status_code, (r.get_json() or {})
        showroom = SafeBox.query.get(args.showroom); custody = SafeBox.query.get(args.custody)
        bangles = Category.query.get(args.bangles)
        before = checks()
        sup = Supplier.query.filter(Supplier.name.like('%الحبيشي%')).first() or Supplier.query.filter_by(is_active=True).first()
        st, b = call('post', '/api/categories', json={'name': 'سبائك ذهب', 'karat': '24'})
        bars = Category.query.get(b['id']); print('bullion category', st, bars.name)
        for cat in (bangles, bars):
            st, b = call('put', f'/api/categories/{cat.id}', json={'tracking': 'piece'})
            check(f'«{cat.name}» by the piece', st == 200 and b['tracking'] == 'piece')

        # the receipt: two lines
        st, b = call('post', '/api/purchase-receipts', json={'supplier_id': sup.id, 'request_key': 'r3-gate-1',
            'lines': [{'category_id': bangles.id, 'karat': 21, 'weight': 45.0, 'supplier_weight': 45.0},
                      {'category_id': bars.id, 'karat': 24, 'weight': 30.0, 'supplier_weight': 30.0}]})
        receipt = b['invoice']; check('receipt saved', st == 201, receipt.get('invoice_number'))
        st, b = call('get', '/api/pieces/pending')
        lines = {l['category_id']: l for l in b['lines'] if l.get('invoice_id') == receipt['id']}
        check('both lines wait at the station', set(lines) == {bangles.id, bars.id})

        codes = {}
        for cat, weights in ((bangles, (14.37, 15.20, 15.43)), (bars, (10.0, 10.0, 10.0))):
            for i, w in enumerate(weights):
                st, b = call('post', '/api/pieces', json={'line_id': lines[cat.id]['line_id'], 'weight': w,
                                                          'request_key': f'r3g-{cat.id}-{i}'})
                codes.setdefault(cat.id, []).append(b['piece']['item_code'])
            check(f'{cat.name}: three pieces, nothing left', b['line']['rest'] == 0.0 and b['line']['pieces'] == 3,
                  f"{codes[cat.id]} rest {b['line']['rest']}")
            check(f'{cat.name}: wage awaits the invoice', b['piece']['wage'] is None)
        first = Item.query.filter_by(item_code=codes[bangles.id][0]).one()

        # law 8 before the invoice
        cust = Customer.query.filter(Customer.account_id.isnot(None), ~Customer.name.like('%نقد%')).order_by(Customer.id.desc()).first(); print('customer', cust.name); emp = Employee.query.filter_by(is_active=True).first()
        def sell(item, price=4000.0):
            return call('post', '/api/invoices', json={'customer_id': cust.id, 'invoice_type': 'بيع', 'gold_type': 'new',
                'employee_id': emp.id, 'date': datetime.now().isoformat(), 'total': price, 'total_weight': item.weight,
                'total_tax': 0.0, 'total_cost': 1.0, 'amount_paid': 0.0, 'payments': [],
                'items': [{'item_id': item.id, 'name': item.name, 'karat': int(item.karat), 'weight': item.weight,
                           'category_id': item.category_id, 'price': price, 'net': price, 'quantity': 1, 'wage': 0,
                           'selling_price': price}]})
        st, b = sell(first)
        check('3. not sold before its wage is known', st == 400 and b.get('error') == 'piece_wage_unknown', b.get('message'))

        # the invoice completed: bangles 18/g; the bars' wage given whole, 100 -> 100/30 a gram
        bars_per_gram = 100.0 / 30.0
        payload = {'invoice_type': 'شراء', 'gold_type': 'new', 'supplier_id': sup.id, 'date': datetime.now().isoformat(),
                   'settlement_method': 'credit', 'amount_paid': 0.0, 'vat_applied': False, 'total': 0.0, 'total_tax': 0.0,
                   'wage_tax_total': 0.0, 'gold_tax_total': 0.0, 'gold_subtotal': 0.0,
                   'manufacturing_wage_cash': 910.0, 'wage_subtotal': 910.0,
                   'items': [{'name': bangles.name, 'karat': 21, 'weight': 45.0, 'quantity': 1, 'wage_per_gram': 18.0,
                              'manufacturing_wage_per_gram': 18.0, 'wage': 18.0, 'wage_total': 810.0, 'category_id': bangles.id},
                             {'name': bars.name, 'karat': 24, 'weight': 30.0, 'quantity': 1, 'wage_per_gram': bars_per_gram,
                              'manufacturing_wage_per_gram': bars_per_gram, 'wage': bars_per_gram, 'wage_total': 100.0,
                              'category_id': bars.id}],
                   'supplier_gold_lines': [{'karat': 21, 'weight': 45.0}, {'karat': 24, 'weight': 30.0}]}
        st, b = call('post', f"/api/purchase-receipts/{receipt['id']}/complete", json=payload)
        check('invoice completed', st in (200, 201), b.get('error') or b.get('message') or '')

        for cat, expect in ((bangles, [258.66, 273.6, 277.74]), (bars, [33.33, 33.33, 33.34])):
            st, b = call('get', f"/api/pieces/lines/{lines[cat.id]['line_id']}")
            wages = [p['wage'] for p in b['pieces']]
            line = line_wages(db.session.get(InvoiceItem, lines[cat.id]['line_id']))
            name = '1. bangles: each its weight x 18' if cat is bangles else '2. bars: 100 whole / 30 g, each its share'
            check(name, wages == expect, f'{wages}')
            check(f'   law 5: the pieces = the line to the halala ({cat.name})',
                  round(sum(wages), 2) == line['line'] and line['rest'] == 0.0, f"{round(sum(wages), 2)} = {line['line']}")

        # a tag mounted, then replaced
        st, b = call('post', f'/api/pieces/{first.id}/tag', json={}); tag = b.get('tag', {}).get('value')
        check('tag mounted from the number', st == 201 and tag == '4B4A' + f"{int(first.item_code[3:]):020d}", tag)
        st, b = call('post', f'/api/pieces/{first.id}/tag/replace', json={'reason': 'تلفت عند التعليق'})
        st2, b2 = call('get', f'/api/pieces/by-tag/{tag}')
        check('tag replaced, the reader finds the piece', st == 201 and b2['piece']['item_code'] == first.item_code)

        # moved by name to a custody, back by name
        st, b = call('post', '/api/safe-boxes/transfer-voucher', json={'from_safe_box_id': showroom.id,
                     'to_safe_box_id': custody.id, 'weights': {'21k': first.weight}, 'pieces': [first.item_code]})
        check('moved by name to the custody', st == 201 and piece_location(first).id == custody.id,
              (b.get('voucher') or {}).get('voucher_number') or b.get('message'))
        st, b = call('post', '/api/safe-boxes/transfer-voucher', json={'from_safe_box_id': custody.id,
                     'to_safe_box_id': showroom.id, 'weights': {'21k': first.weight}, 'pieces': [first.item_code]})
        check('and back', st == 201 and piece_location(first).id == showroom.id)

        # sold by its number, once
        st, b = sell(first)
        check('sold once its wage is known', st in (200, 201), b.get('error') or '')
        check('   out of the stock', piece_held(first.id) == 0.0, f'held {piece_held(first.id)}')
        st, b = sell(first)
        check('   not sold twice', st == 400 and b.get('error') == 'piece_sold', b.get('message'))
        st, b = call('post', '/api/invoices', json={'customer_id': cust.id, 'invoice_type': 'بيع', 'gold_type': 'new',
            'employee_id': emp.id, 'date': datetime.now().isoformat(), 'total': 4000.0, 'total_weight': 15.0,
            'total_tax': 0.0, 'total_cost': 1.0, 'amount_paid': 0.0, 'payments': [],
            'items': [{'name': bangles.name, 'karat': 21, 'weight': 15.0, 'category_id': bangles.id, 'price': 4000.0,
                       'net': 4000.0, 'quantity': 1, 'wage': 0, 'selling_price': 4000.0}]})
        check('   its category not sold by weight', st == 400 and b.get('error') == 'piece_category_sold_by_piece')

        # coded from stock, its wage by hand
        sal = Category.query.filter(Category.name.like('سلسال 21%')).first()
        call('put', f'/api/categories/{sal.id}', json={'tracking': 'piece'})
        st, b = call('post', '/api/stock-codings', json={'safe_box_id': showroom.id, 'category_id': sal.id,
                                                        'weight': 20.0, 'wage_per_gram': 15.0})
        cid = b['line']['coding_id']
        st, b = call('post', '/api/pieces', json={'coding_id': cid, 'weight': 11.11})
        check('coded from stock, its wage known at once', st == 201 and b['piece']['wage'] == round(15 * 11.11, 2),
              f"{b['piece']['item_code']} {b['piece']['wage']}")

        check('the nightly checks: as they were', checks() == before)
        print('\nRESULT', sum(ok for _, ok in R), 'of', len(R), 'passed')
        return 0 if all(ok for _, ok in R) else 1


if __name__ == '__main__':
    sys.exit(main())
