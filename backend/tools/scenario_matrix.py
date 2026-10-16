"""The scenario matrix: every operation a CHART release can touch, run through the
real routes on a production copy -- the same on two copies, one per code version.

The owner, 14 Oct 2026: «لا تدفع كل اصدارات CHART حتى تختبرها على نسخة من الانتاج
بجميع السيناريوهات التي يمكن ان تمر عليها وتتجاوزه بنجاح». Run it with each
version's code against its own restored copy, then compare the two outputs:

    PYTHONPATH=<backend of version A> DATABASE_URL=postgresql:///<copy A> \\
        python tools/scenario_matrix.py --out a.json
    PYTHONPATH=<backend of version B> DATABASE_URL=postgresql:///<copy B> \\
        python tools/scenario_matrix.py --out b.json
    python tools/scenario_matrix.py --compare a.json b.json

What a scenario records: the HTTP status, and the entries it wrote -- summed per
account NUMBER (ids differ between copies), cash and the four karats; the
accounts it created (number, parent's number, name). Never dates, ids or
descriptions. Each scenario runs whatever happened before it: a failure is a
row, not the end of the run. Nothing here names an account: every party, safe
and payment method is read from the copy.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
import uuid
from datetime import date, datetime

COLS = ('cash_debit', 'cash_credit', 'debit_18k', 'credit_18k', 'debit_21k', 'credit_21k',
        'debit_22k', 'credit_22k', 'debit_24k', 'credit_24k')
OUNCE = 4150.0


def _r(x):
    return round(float(x or 0.0), 2)


class Matrix:
    def __init__(self, app):
        from models import Account, JournalEntry, db
        self.app, self.db = app, db
        self.client = app.test_client()
        self.rows = {}
        self.headers = self._login()
        self.Account, self.JournalEntry = Account, JournalEntry

    # ── setup ────────────────────────────────────────────────────────────
    def _login(self):
        from models import User, db
        user = User.query.filter_by(username='scenario_matrix').first()
        if user is None:
            user = User(username='scenario_matrix', full_name='مصفوفة السيناريوهات', is_admin=True, is_active=True)
            db.session.add(user)
        user.set_password('Scenario-2026!')
        db.session.commit()
        resp = self.app.test_client().post('/api/auth/login', json={'username': 'scenario_matrix',
                                                                    'password': 'Scenario-2026!'})
        body = resp.get_json() or {}
        token = body.get('token') or body.get('access_token') or (body.get('data') or {}).get('token')
        if not token:
            raise SystemExit(f'login failed: {resp.status_code} {resp.get_data(as_text=True)[:200]}')
        return {'Authorization': f'Bearer {token}'}

    # ── recording ────────────────────────────────────────────────────────
    def _marks(self):
        from sqlalchemy import func
        db = self.db
        return (db.session.query(func.coalesce(func.max(self.JournalEntry.id), 0)).scalar(),
                db.session.query(func.coalesce(func.max(self.Account.id), 0)).scalar())

    def _since(self, marks):
        from models import JournalEntryLine
        db = self.db
        db.session.expire_all()
        je_mark, acc_mark = marks
        lines = (db.session.query(JournalEntryLine, self.Account.account_number)
                 .join(self.JournalEntry, self.JournalEntry.id == JournalEntryLine.journal_entry_id)
                 .join(self.Account, self.Account.id == JournalEntryLine.account_id)
                 .filter(self.JournalEntry.id > je_mark, JournalEntryLine.is_deleted.is_(False),
                         self.JournalEntry.is_deleted.is_(False)).all())
        by_account = {}
        for line, number in lines:
            row = by_account.setdefault(str(number), {c: 0.0 for c in COLS})
            for c in COLS:
                row[c] += float(getattr(line, c, 0.0) or 0.0)
        entries = {n: {c: _r(v) for c, v in row.items() if _r(v)} for n, row in sorted(by_account.items())}
        made = []
        for acc in self.Account.query.filter(self.Account.id > acc_mark).order_by(self.Account.id).all():
            parent = db.session.get(self.Account, acc.parent_id) if acc.parent_id else None
            made.append({'number': acc.account_number, 'parent': parent.account_number if parent else None,
                         'name': acc.name})
        return {'entries': {n: v for n, v in entries.items() if v}, 'accounts_created': made}

    def run(self, name, fn):
        marks = self._marks()
        try:
            status, extra = fn()
        except Exception as exc:   # a failure is a row, not the end of the run
            self.db.session.rollback()
            status, extra = 'exception', {'error': f'{type(exc).__name__}: {exc}',
                                          'where': traceback.format_exc(limit=3)[-600:]}
        row = {'status': status, **self._since(marks), **(extra or {})}
        self.rows[name] = row
        print(f'{name:40} {status}', flush=True)
        return row

    def post(self, url, payload=None):
        resp = self.client.post(url, headers=self.headers, json=payload or {})
        return resp.status_code, resp.get_json(silent=True) or {}

    # ── the world, read from the copy ────────────────────────────────────
    def world(self):
        from models import Customer, Employee, GoldPrice, PaymentMethod, SafeBox, Supplier, db
        import gold_price
        import routes.pricing as pricing
        gold_price.fetch_gold_price = lambda *a, **k: None          # no internet: one price on both copies
        pricing.fetch_gold_price = lambda *a, **k: None
        db.session.add(GoldPrice(price=OUNCE, date=datetime.utcnow()))
        cash_pm = PaymentMethod.query.filter_by(payment_type='cash', is_active=True).order_by(PaymentMethod.id).first()
        card_box = (SafeBox.query.filter_by(safe_type='clearing', is_active=True).order_by(SafeBox.id).first())
        card_pm = PaymentMethod(payment_type='visa', name=f'بطاقة مصفوفة {uuid.uuid4().hex[:4]}', commission_rate=2.0,
                                is_active=True,
                                default_safe_box_id=card_box.id if card_box else cash_pm.default_safe_box_id)
        db.session.add(card_pm)
        holder = (Employee.query.filter(Employee.gold_safe_box_id.isnot(None), Employee.is_active.is_(True))
                  .order_by(Employee.id).first())
        payroll_employee = (Employee.query.filter(Employee.salary > 0, Employee.is_active.is_(True))
                            .order_by(Employee.id).first())
        db.session.commit()
        cash_box = db.session.get(SafeBox, cash_pm.default_safe_box_id)
        from models import is_cash_customer
        named = next(c for c in Customer.query.order_by(Customer.id).all() if not is_cash_customer(c))
        settlement_pm = (PaymentMethod.query.filter(PaymentMethod.is_active.is_(True),
                                                    PaymentMethod.commission_rate > 0)
                         .order_by(PaymentMethod.id).first())
        return {'customer': Customer.query.order_by(Customer.id).first(), 'named_customer': named,
                'settlement_pm': settlement_pm,
                'supplier': Supplier.query.filter(Supplier.account_id.isnot(None)).order_by(Supplier.id).first(),
                'cash_pm': cash_pm, 'card_pm': card_pm, 'holder': holder,
                'payroll_employee': payroll_employee, 'cash_box': cash_box}

    # ── payloads (the shapes of the suite's own worlds) ──────────────────
    @staticmethod
    def sale(w, *, price=1000.0, payments=None, customer=None):
        paid = sum(p['amount'] for p in (payments or []))
        return {'customer_id': (customer or w['customer']).id, 'invoice_type': 'بيع', 'gold_type': 'new',
                'employee_id': w['holder'].id, 'date': datetime.now().isoformat(), 'total': price,
                'total_weight': 2.0, 'total_tax': 0.0, 'total_cost': 0.0, 'amount_paid': paid,
                'payments': payments or [],
                'items': [{'name': 'سلسال مصفوفة', 'karat': 21, 'weight': 2.0, 'price': price, 'net': price,
                           'quantity': 1, 'wage': 10.0, 'selling_price': price, 'discount_amount': 0.0}]}

    @staticmethod
    def scrap_purchase(w, *, gold_type='scrap', price=100.0):
        return {'customer_id': w['customer'].id, 'invoice_type': 'شراء من عميل', 'gold_type': gold_type,
                'transaction_type': 'buy', 'employee_id': w['holder'].id,
                'scrap_holder_employee_id': w['holder'].id, 'safe_box_id': w['cash_pm'].default_safe_box_id,
                'date': datetime.now().isoformat(), 'total': price, 'total_weight': 0.5, 'total_cost': price,
                'total_tax': 0.0, 'amount_paid': price,
                'payments': [{'payment_method_id': w['cash_pm'].id, 'amount': price}],
                'items': [{'name': 'كسر مصفوفة', 'karat': 18, 'weight': 0.5, 'standing_weight': 0.5,
                           'stones_weight': 0.0, 'price': price, 'net': price, 'quantity': 1}]}

    @staticmethod
    def supplier_purchase(w, wage=200.0):
        gold, vat = 3675.0, round(wage * 0.15, 2)
        return {'invoice_type': 'شراء', 'supplier_id': w['supplier'].id, 'gold_type': 'new',
                'date': datetime.now().isoformat(), 'total': gold + wage + vat, 'total_tax': vat,
                'gold_subtotal': gold, 'wage_subtotal': wage, 'wage_tax_total': vat, 'gold_tax_total': 0.0,
                'settlement_method': 'credit', 'amount_paid': 0.0,
                'items': [{'name': 'سلسال مورد مصفوفة', 'karat': 21, 'weight': 10.0, 'quantity': 1,
                           'manufacturing_wage_per_gram': wage / 10.0}]}

    # ── every party's balance, by the readers (step 4b2) ─────────────────
    def balances(self, *, documents):
        """Each customer's and supplier's live balance -- and, with *documents*,
        its list row and its statement and ledger in full (only before the
        scenarios: after them, the new entries' ids and times differ by copy)."""
        from models import Customer, Supplier
        from services.party_live_balances import compute_live_customer_balances, compute_live_supplier_balances

        def get(url):
            resp = self.client.get(url, headers=self.headers)
            return [resp.status_code, resp.get_json(silent=True)]

        customers = Customer.query.order_by(Customer.id).all()
        suppliers = Supplier.query.order_by(Supplier.id).all()
        live_c, live_s = compute_live_customer_balances(customers), compute_live_supplier_balances(suppliers)
        out = {'customers': {c.customer_code: {k: _r(v) for k, v in live_c.get(c.id, {}).items()} for c in customers},
               'suppliers': {s.supplier_code: {k: _r(v) for k, v in live_s.get(s.id, {}).items()} for s in suppliers}}
        if documents:
            out['customer_list'] = get('/api/customers')
            out['supplier_list'] = get('/api/suppliers')
            out['customer_statements'] = {c.customer_code: get(f'/api/customers/{c.id}/statement') for c in customers}
            out['supplier_statements'] = {s.supplier_code: get(f'/api/suppliers/{s.id}/statement') for s in suppliers}
            out['supplier_ledgers'] = {s.supplier_code: get(f'/api/suppliers/{s.id}/ledger') for s in suppliers}
        return 200, {'balances': out}

    # ── the reports that read the chart's groups, in full (release 5) ──────
    def reports(self):
        """Each report a CHART release can reclassify, as served -- and the gold
        cost replay and its transition plan, as computed -- before the scenarios."""
        import dataclasses

        def plain(value):
            if dataclasses.is_dataclass(value):
                value = dataclasses.asdict(value)
            if isinstance(value, dict):
                return {str(k): plain(v) for k, v in value.items()}
            if isinstance(value, (list, tuple, set)):
                return [plain(v) for v in value]
            if isinstance(value, float):
                return round(value, 2)
            if isinstance(value, (date, datetime)):
                return value.isoformat()
            return value

        def get(url):
            resp = self.client.get(url, headers=self.headers)
            return [resp.status_code, resp.get_json(silent=True)]

        year = 'start_date=2026-01-01&end_date=2026-12-31'
        docs = {name: get(url) for name, url in (
            ('income_statement', f'/api/reports/income_statement?{year}'),
            ('gold_income_statement', f'/api/reports/income-statement/gold?{year}'),
            ('gram_profit', f'/api/reports/gram_profit?{year}'),
            ('analytics_summary', f'/api/analytics/summary?{year}'),
            ('inventory_reconciliation', '/api/reports/inventory_reconciliation?date=2026-10-12'),
            ('bridge_balance_monitor', '/api/reports/bridge-balance-monitor'),
            ('admin_dashboard', '/api/dashboard/admin'))}
        try:
            from services.gold_cost import gross_by_month, ledger_weights, replay
            from services.gold_cost_books import plan_transition
            r = replay(opening_price=350.0, since=date(2026, 1, 1))
            docs['gold_cost'] = plain({'months': r.months, 'pools': r.pools, 'others': len(r.others),
                                       'ledger': ledger_weights(), 'gross': gross_by_month(r),
                                       'transition': plan_transition(opening_price=350.0, at=date(2026, 10, 1),
                                                                     since=date(2026, 1, 1))['lines']})
        except Exception as exc:  # recorded, so the two copies compare on it too
            self.db.session.rollback()
            docs['gold_cost'] = f'{type(exc).__name__}: {exc}'
        return 200, {'documents': docs}

    # ── the scenarios ────────────────────────────────────────────────────
    def all(self):
        from models import EmployeeBonus, InvoiceItem, Settings, db
        self.run('party_balances_before', lambda: self.balances(documents=True))
        self.run('reports_before', self.reports)
        w = self.world()
        settings = Settings.query.first()
        settings.allow_partial_invoice_payments = True
        db.session.commit()
        made = {}

        def invoice(name, payload):
            def go():
                code, body = self.post('/api/invoices', payload() if callable(payload) else payload)
                made[name] = body if code == 201 else None
                return code, ({'detail': body.get('detail') or body.get('error')} if code != 201 else {})
            return self.run(name, go)

        invoice('sale_cash', lambda: self.sale(w, payments=[{'payment_method_id': w['cash_pm'].id, 'amount': 1000.0}]))
        invoice('sale_card_settled_later',
                lambda: self.sale(w, payments=[{'payment_method_id': w['settlement_pm'].id, 'amount': 1000.0}]))
        # A card sale whose screen sends the commission it estimates. Before
        # COMMISSION-1 the method took it at the invoice and the sale was refused
        # (its revenue net of it, 23 short); since, nothing of it is posted here.
        invoice('sale_card_commission_at_invoice',
                lambda: self.sale(w, payments=[{'payment_method_id': w['card_pm'].id, 'amount': 1000.0,
                                                'commission_amount': 20.0, 'commission_vat': 3.0}]))
        invoice('sale_on_credit', lambda: self.sale(w, customer=w['named_customer']))
        invoice('scrap_purchase_from_customer', lambda: self.scrap_purchase(w))
        invoice('new_gold_purchase_from_customer', lambda: self.scrap_purchase(w, gold_type='new'))
        invoice('supplier_purchase', lambda: self.supplier_purchase(w))

        def sales_return():
            sale = made.get('sale_cash')
            if not sale:
                return 'skipped: no sale', {}
            item = sale['items'][0]
            return self.post('/api/invoices', {
                'invoice_type': 'مرتجع بيع', 'customer_id': w['customer'].id, 'original_invoice_id': sale['id'],
                'gold_type': 'new', 'branch_id': sale.get('branch_id'), 'date': sale['date'], 'total': 1000.0,
                'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': 1000.0,
                'payments': [{'payment_method_id': w['cash_pm'].id, 'amount': 1000.0}],
                'items': [{'name': item['name'], 'karat': item['karat'], 'weight': 2.0, 'quantity': 1,
                           'price': 1000.0, 'net': 1000.0, 'wage': 0, 'tax': 0,
                           'original_invoice_item_id': item['id']}]})[0], {}
        self.run('sales_return', sales_return)

        def customer_purchase_return():
            buy = made.get('scrap_purchase_from_customer')
            if not buy:
                return 'skipped: no purchase', {}
            item = buy['items'][0]
            return self.post('/api/invoices', {
                'invoice_type': 'مرتجع شراء', 'customer_id': w['customer'].id, 'original_invoice_id': buy['id'],
                'gold_type': 'scrap', 'date': buy['date'], 'total': 100.0, 'total_weight': 0.5, 'total_tax': 0.0,
                'amount_paid': 100.0, 'safe_box_id': w['cash_pm'].default_safe_box_id,
                'payments': [{'payment_method_id': w['cash_pm'].id, 'amount': 100.0}],
                'items': [{'name': item['name'], 'karat': 18, 'weight': 0.5, 'quantity': 1, 'price': 100.0,
                           'net': 100.0, 'original_invoice_item_id': item['id']}]})[0], {}
        self.run('customer_purchase_return', customer_purchase_return)

        def supplier_return():
            buy = made.get('supplier_purchase')
            if not buy:
                return 'skipped: no purchase', {}
            item = InvoiceItem.query.filter_by(invoice_id=buy['id']).first()
            gold, wage, vat = 3675.0, 200.0, 30.0
            return self.post('/api/invoices', {
                'invoice_type': 'مرتجع شراء (مورد)', 'supplier_id': w['supplier'].id,
                'original_invoice_id': buy['id'], 'gold_type': 'new', 'date': datetime.now().isoformat(),
                'total': gold + wage + vat, 'total_tax': vat, 'gold_subtotal': gold, 'wage_subtotal': wage,
                'wage_tax_total': vat, 'gold_tax_total': 0.0, 'vat_applied': True,
                'items': [{'name': 'سلسال مورد مصفوفة', 'karat': 21, 'weight': 10.0, 'quantity': 1,
                           'manufacturing_wage_per_gram': 20.0, 'original_invoice_item_id': item.id}]})[0], {}
        self.run('supplier_return', supplier_return)

        # vouchers: a cash receipt from the customer, a cash payment to the supplier
        cust_acc = w['customer'].account_id
        supp_acc = w['supplier'].account_id
        cash_acc = w['cash_box'].account_id
        for name, payload in (
            ('voucher_cash_receipt', {'voucher_type': 'receipt', 'date': date.today().isoformat(),
                                      'party_type': 'customer', 'customer_id': w['customer'].id, 'account_lines': [
                {'account_id': cash_acc, 'line_type': 'debit', 'amount_type': 'cash', 'amount': 500.0},
                {'account_id': cust_acc, 'line_type': 'credit', 'amount_type': 'cash', 'amount': 500.0}]}),
            ('voucher_cash_payment', {'voucher_type': 'payment', 'date': date.today().isoformat(),
                                      'party_type': 'supplier', 'supplier_id': w['supplier'].id, 'account_lines': [
                {'account_id': supp_acc, 'line_type': 'debit', 'amount_type': 'cash', 'amount': 300.0},
                {'account_id': cash_acc, 'line_type': 'credit', 'amount_type': 'cash', 'amount': 300.0}]}),
        ):
            self.run(name, lambda p=payload: (self.post('/api/vouchers', p)[0], {}))

        # payroll: accrued, paid from a named safe account, and paid naming none
        e = w['payroll_employee']

        def payroll(mark_with_account, month):
            def go():
                code, body = self.post('/api/payroll', {'employee_id': e.id, 'month': month, 'year': 2030,
                                                        'basic_salary': 1000.0, 'status': 'pending'})
                if code not in (200, 201):
                    return f'create {code}', {'detail': body.get('error')}
                pid = body.get('id') or (body.get('payroll') or {}).get('id')
                # Approval posts the accrual (as the screen does).
                resp = self.client.put(f'/api/payroll/{pid}', headers=self.headers, json={'status': 'approved'})
                body = resp.get_json(silent=True) or {}
                if resp.status_code != 200 or not body.get('accrual_posted'):
                    return f'approve {resp.status_code}', {'detail': body.get('accrual_warning') or body.get('error')}
                pay = {'payment_account_id': cash_acc} if mark_with_account else {}
                code, body = self.post(f'/api/payroll/{pid}/mark-paid', pay)
                return code, ({'detail': body.get('error')} if code != 200 else {})
            return go
        self.run('payroll_paid_from_a_named_account', payroll(True, 1))
        self.run('payroll_paid_naming_no_account', payroll(False, 2))

        # bonuses: approved, paid from the cash safe, another reversed
        def bonus(status):
            b = EmployeeBonus(employee_id=e.id, bonus_type='fixed', amount=250.0, status=status,
                              period_start=date(2026, 9, 1), period_end=date(2026, 9, 30), created_at=datetime.now())
            db.session.add(b)
            db.session.commit()
            return b.id

        def approve_and_pay():
            from bonus_routes import _approve_single_bonus
            bid = bonus('pending')
            ok, payload = _approve_single_bonus(bid, 'scenario_matrix')
            if not ok:
                return 'approve failed', {'detail': str(payload)[:300]}
            db.session.commit()
            code, body = self.post(f'/api/bonuses/{bid}/pay', {'safe_box_id': w['cash_box'].id,
                                                                'payment_method': 'cash'})
            return code, ({'detail': body.get('message') or body.get('error')} if code != 200 else {})
        self.run('bonus_approved_and_paid', approve_and_pay)

        def approve_and_reverse():
            from bonus_routes import _approve_single_bonus
            from bonus_reversal_service import BonusReversalService
            bid = bonus('pending')
            ok, payload = _approve_single_bonus(bid, 'scenario_matrix')
            if not ok:
                return 'approve failed', {'detail': str(payload)[:300]}
            db.session.commit()
            ok, payload = BonusReversalService.reverse(bid, 'scenario_matrix', 'مصفوفة')
            db.session.commit()
            return ('ok' if ok else 'reverse failed'), ({} if ok else {'detail': str(payload)[:300]})
        self.run('bonus_approved_and_reversed', approve_and_reverse)

        def bonus_first_for_employee_without_account():
            from bonus_routes import _approve_single_bonus
            from models import Employee
            bare = None
            for cand in Employee.query.order_by(Employee.id).all():
                names = [a.name for a in self.Account.query.filter(self.Account.name.like(f'%{cand.name}%مكافآت%')).all()]
                if not names:
                    bare = cand
                    break
            if bare is None:
                return 'skipped: every employee has a bonus account', {}
            b = EmployeeBonus(employee_id=bare.id, bonus_type='fixed', amount=100.0, status='pending',
                              period_start=date(2026, 9, 1), period_end=date(2026, 9, 30), created_at=datetime.now())
            db.session.add(b)
            db.session.commit()
            ok, payload = _approve_single_bonus(b.id, 'scenario_matrix')
            db.session.commit()
            return ('ok' if ok else 'approve failed'), ({} if ok else {'detail': str(payload)[:300]})
        self.run('bonus_for_an_employee_with_no_bonus_account', bonus_first_for_employee_without_account)

        # a scrap sale, paid in cash (the scrap sale screen's shape) -- the scrap sales role
        invoice('scrap_sale_paid', lambda: {
            'customer_id': w['customer'].id, 'invoice_type': 'بيع', 'transaction_type': 'sell', 'gold_type': 'scrap',
            'employee_id': w['holder'].id, 'date': datetime.now().isoformat(), 'total': 1000.0,
            'total_weight': 2.0, 'total_cost': 0.0, 'total_tax': 0.0, 'amount_paid': 1000.0,
            'payments': [{'payment_method_id': w['cash_pm'].id, 'amount': 1000.0}],
            'items': [{'name': 'كسر مصفوفة', 'karat': 21, 'weight': 2.0, 'price': 1000.0, 'net': 1000.0,
                       'quantity': 1, 'wage': 0, 'selling_price': 1000.0}]})

        # a whole count of the main scrap safe: half a gram short on its first line
        def count():
            from models import SafeBox
            box = (SafeBox.query.filter_by(stock_location='scrap', is_active=True).order_by(SafeBox.id).first())
            code, s = self.post('/api/inventory/count', {'safe_box_id': box.id, 'blind': False})
            if code != 201:
                return f'open {code}', {'detail': s.get('error')}
            sid = s['id']
            for i, line in enumerate(s.get('lines') or []):
                counted = float(line.get('expected_weight') or 0.0) - (0.5 if i == 0 else 0.0)
                resp = self.client.put(f'/api/inventory/count/{sid}/entry', headers=self.headers, json={
                    'category_id': line.get('category_id'), 'karat': line.get('karat'), 'counted_weight': counted})
                if resp.status_code != 200:
                    return f'entry {resp.status_code}', {'detail': (resp.get_json(silent=True) or {}).get('error')}
            code, body = self.post(f'/api/inventory/count/{sid}/close', {})
            if code != 200:
                return f'close {code}', {'detail': body.get('error')}
            code, body = self.post(f'/api/inventory/count/{sid}/approve', {'reason_code': 'COUNT_ERROR'})
            return code, ({'detail': body.get('error')} if code != 200 else {})
        self.run('inventory_count_approved', count)

        # an office reservation, then its settlement -- a purchase from the office
        def office():
            from models import Office
            o = Office.query.filter_by(active=True).order_by(Office.id).first()
            code, body = self.post('/api/office-reservations', {
                'office_id': o.id, 'weight': 5.0, 'karat': 21, 'price_per_gram': 400.0,
                'execution_price_per_gram': 400.0, 'paid_amount': 0})
            if code not in (200, 201):
                return f'reserve {code}', {'detail': body.get('error')}
            rid = body.get('id') or (body.get('reservation') or {}).get('id')
            code, body = self.post(f'/api/office-reservations/{rid}/settle', {'execution_price_per_gram': 400.0})
            return code, ({'detail': body.get('error') or body.get('message')} if code != 200 else {})
        self.run('office_reservation_settled', office)

        # the karat-difference commission, earned and paid, and the 24k net-gold
        # settlement's commission -- on a supplier's purchase and on a payment voucher
        invoice('supplier_purchase_karat_diff_earned',
                lambda: {**self.supplier_purchase(w), 'karat_diff_earn_total': 50.0})
        invoice('supplier_purchase_karat_diff_paid',
                lambda: {**self.supplier_purchase(w), 'karat_diff_pay_total': 40.0})
        invoice('supplier_purchase_gold24k_settled',
                lambda: {**self.supplier_purchase(w), 'gold24k_settlement': True, 'gold24k_weight': 10.0,
                         'gold24k_commission_per_gram': 5.0, 'gold24k_commission_total': 50.0})
        cash_line = {'account_id': cash_acc, 'line_type': 'credit', 'amount_type': 'cash', 'amount': 200.0}
        supplier_line = {'account_id': supp_acc, 'line_type': 'debit', 'amount_type': 'cash', 'amount': 200.0}
        for name, extra in (('voucher_karat_diff_paid', {'karat_diff_pay_total': 25.0}),
                            ('voucher_karat_diff_earned', {'karat_diff_earn_total': 15.0}),
                            ('voucher_gold24k_settled', {'gold24k_settlement': True, 'gold24k_weight': 6.0,
                                                         'gold24k_commission_per_gram': 5.0,
                                                         'gold24k_commission_total': 30.0})):
            self.run(name, lambda e=extra: (self.post('/api/vouchers', {
                'voucher_type': 'payment', 'date': date.today().isoformat(), 'party_type': 'supplier',
                'supplier_id': w['supplier'].id, 'account_lines': [supplier_line, cash_line], **e})[0], {}))

        # the weight closing executed as a purchase (not an office's) against one
        # sale's order -- the others held for it -- and that sale then returned,
        # reversing the cost it had settled
        invoice('sale_for_weight_closing',
                lambda: self.sale(w, payments=[{'payment_method_id': w['cash_pm'].id, 'amount': 1000.0}]))

        def weight_closing_executed():
            from accounting.voucher_engine import _generate_journal_entry_number
            from models import JournalEntry, WeightClosingOrder
            sale = made.get('sale_for_weight_closing')
            if not sale:
                return 'skipped: no sale', {}
            others = (WeightClosingOrder.query.filter(WeightClosingOrder.status.in_(['open', 'partially_closed']),
                                                      WeightClosingOrder.invoice_id != sale['id']).all())
            held = {o.id: o.status for o in others}
            for o in others:
                o.status = 'held_by_matrix'
            je = JournalEntry(entry_number=_generate_journal_entry_number(), date=datetime.now(),
                              description='تنفيذ تسكير — مصفوفة', entry_type='عادي', is_posted=True,
                              created_by='scenario_matrix')
            db.session.add(je)
            db.session.commit()
            try:
                code, body = self.post('/api/weight-closing/cash-settlement', {
                    'source_invoice_id': sale['id'], 'cash_amount': 400.0, 'price_per_gram': 400.0,
                    'execution_type': 'purchase_scrap', 'journal_entry_id': je.id})
                db.session.commit()
            finally:
                for o in WeightClosingOrder.query.filter(WeightClosingOrder.id.in_(list(held))).all():
                    o.status = held[o.id]
                db.session.commit()
            if code == 404:     # gone with the stored engine (ADR-048 phase 3a): the difference is expected
                return 'removed: ADR-048 phase 3a', {}
            return code, {'consumed': _r(body.get('weight_consumed')), 'executions': body.get('executions_created')}
        self.run('weight_closing_executed_as_purchase', weight_closing_executed)

        def executed_sale_returned():
            sale = made.get('sale_for_weight_closing')
            if not sale:
                return 'skipped: no sale', {}
            item = sale['items'][0]
            return self.post('/api/invoices', {
                'invoice_type': 'مرتجع بيع', 'customer_id': w['customer'].id, 'original_invoice_id': sale['id'],
                'gold_type': 'new', 'branch_id': sale.get('branch_id'), 'date': sale['date'], 'total': 1000.0,
                'total_weight': 2.0, 'total_tax': 0.0, 'amount_paid': 1000.0,
                'payments': [{'payment_method_id': w['cash_pm'].id, 'amount': 1000.0}],
                'items': [{'name': item['name'], 'karat': item['karat'], 'weight': 2.0, 'quantity': 1,
                           'price': 1000.0, 'net': 1000.0, 'wage': 0, 'tax': 0,
                           'original_invoice_item_id': item['id']}]})[0], {}
        self.run('sales_return_of_a_weight_closed_sale', executed_sale_returned)

        # a new customer, supplier and office, through their routes (step 4b)
        self.run('customer_created', lambda: (self.post('/api/customers', {
            'name': 'عميل مصفوفة', 'phone': '0500000001'})[0], {}))
        self.run('supplier_created', lambda: (self.post('/api/suppliers', {'name': 'مورد مصفوفة'})[0], {}))
        self.run('office_created', lambda: (self.post('/api/offices', {'name': 'مكتب مصفوفة'})[0], {}))

        # a purchase paid at creation from a supplier whose linked weight twin is
        # not numbered «7 + its number» -- read from the copy, none named here
        def paid_purchase_odd_twin():
            from models import Supplier
            odd = None
            for s in Supplier.query.filter(Supplier.account_id.isnot(None)).order_by(Supplier.id).all():
                own = db.session.get(self.Account, s.account_id)
                twin = db.session.get(self.Account, own.memo_account_id) if own and own.memo_account_id else None
                # The twin rule, written here: the matrix runs older code too, which
                # has no accounting/twins.py (tests/test_twin_rule_in_one_place.py names it).
                if twin is not None and twin.account_number != f'7{own.account_number}':
                    odd = s
                    break
            if odd is None:
                return 'skipped: no such supplier', {}
            cash = 200.0 + 30.0   # the wage and its VAT: the gold is owed in gold
            code, body = self.post('/api/invoices', {
                **self.supplier_purchase({**w, 'supplier': odd}), 'settlement_method': 'cash',
                'amount_paid': cash, 'safe_box_id': w['cash_pm'].default_safe_box_id,
                'payments': [{'payment_method_id': w['cash_pm'].id, 'amount': cash,
                              'safe_box_id': w['cash_pm'].default_safe_box_id}]})
            return code, ({'detail': body.get('detail') or body.get('error') or body.get('message')}
                          if code != 201 else {})
        self.run('supplier_purchase_paid_odd_twin', paid_purchase_odd_twin)

        # a new employee, through the route
        self.run('employee_created', lambda: (self.post('/api/employees', {
            'name': 'موظف مصفوفة', 'employee_code': 'E-MATRIX-1', 'salary': 3000})[0], {}))

        self.run('party_balances_after', lambda: self.balances(documents=False))

        # reports that read accounts by role or number
        for name, url in (('report_income_statement', '/api/reports/income_statement?start_date=2026-01-01&end_date=2026-12-31'),
                          ('report_admin_dashboard', '/api/dashboard/admin'),
                          ('report_trial_balance', '/api/trial_balance'),
                          ('report_bonus_payables', '/api/bonuses/payables-report'),
                          ('report_gold_trial_balance', '/api/reports/gold-weight-trial-balance?start_date=2026-01-01&end_date=2026-12-31')):
            self.run(name, lambda u=url: (self.client.get(u, headers=self.headers).status_code, {}))
        return self.rows


def _timeless(value):
    """A document without the moments it was produced at (a statement's QR is
    stamped when served): two runs a second apart are the same document."""
    if isinstance(value, dict):
        return {k: _timeless(v) for k, v in value.items() if not str(k).endswith(('issued_at', 'generated_at'))}
    if isinstance(value, list):
        return [_timeless(v) for v in value]
    return value


def compare(a_path, b_path):
    a, b = json.load(open(a_path, encoding='utf-8')), json.load(open(b_path, encoding='utf-8'))
    for rows in (a, b):
        for row in rows.values():
            for key in ('balances', 'documents'):
                if key in row:
                    row[key] = _timeless(row[key])
    same = differ = 0
    for name in a:
        if name not in b:
            print(f'{name}: missing in {b_path}')
            continue
        ra, rb = a[name], b[name]
        keys = ('status', 'entries', 'accounts_created', 'balances', 'documents')
        if all(ra.get(k) == rb.get(k) for k in keys):
            same += 1
            print(f'SAME   {name}  ({ra["status"]})')
            continue
        differ += 1
        print(f'DIFFER {name}')
        for k in keys:
            if ra.get(k) != rb.get(k):
                print(f'   {k}:\n     A {json.dumps(ra.get(k), ensure_ascii=False)[:900]}\n'
                      f'     B {json.dumps(rb.get(k), ensure_ascii=False)[:900]}')
        for k in ('detail', 'error'):
            if ra.get(k) or rb.get(k):
                print(f'   {k}: A={ra.get(k)!s:.300} | B={rb.get(k)!s:.300}')
    print(f'\n{same} same, {differ} differ, of {len(a)}')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--out')
    parser.add_argument('--compare', nargs=2)
    args = parser.parse_args()
    if args.compare:
        compare(*args.compare)
        return
    sys.path.insert(0, os.getcwd())
    from app import app
    app.config['TESTING'] = True
    with app.app_context():
        rows = Matrix(app).all()
    with open(args.out, 'w', encoding='utf-8') as fh:
        json.dump(rows, fh, ensure_ascii=False, indent=1, default=str)


if __name__ == '__main__':
    main()
