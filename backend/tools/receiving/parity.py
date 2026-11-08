"""Received then completed against posted whole: everything a purchase leaves, compared (ADR-087, R1's gate).

The owner's gate for R1 (8 Nov 2026): not the totals -- the accounts debited
and credited, the weights by karat, the VAT, the category allocation, the
supplier's cash and gold, his gold obligations, the safe's rows, the invoice's
figures and payment state, the purchases report and the nightly checks. For
each shape of purchase, on a restored copy (DATABASE_URL), the same request
is posted whole in one transaction and received then completed in another,
each on its own copy of the same database, in the same order, saved; then
the two compared part by part.

    DATABASE_URL=postgresql:///<copy-a> python tools/receiving/parity.py --way whole    --out whole.json    --supplier-id N --category-21 C21 --category-18 C18
    DATABASE_URL=postgresql:///<copy-b> python tools/receiving/parity.py --way received --out received.json --supplier-id N --category-21 C21 --category-18 C18
    python tools/receiving/parity.py --compare whole.json received.json

Never on a reference (ref_*) database itself: copy it first (the app's start
creates tables, feedback_never_run_app_on_reference).
"""
import argparse
import json
import os
import sys
from collections import Counter
from datetime import datetime

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))

KARATS = (18, 21, 22, 24)


def shapes(supplier_id, c21, c18):
    def base(**kw):
        return {'invoice_type': 'شراء', 'gold_type': 'new', 'supplier_id': supplier_id,
                'date': datetime.now().isoformat(), 'settlement_method': 'credit', 'amount_paid': 0.0, **kw}
    return {
        "the screen's: 12.5 g of 21k at 18, its wage VAT": base(
            vat_applied=True, total=4852.5, total_tax=33.75, wage_tax_total=33.75, gold_tax_total=0.0,
            manufacturing_wage_cash=225.0, wage_subtotal=225.0, gold_subtotal=4593.75,
            items=[{'name': 'بناجر', 'karat': 21, 'weight': 12.5, 'quantity': 1, 'wage_per_gram': 18.0,
                    'manufacturing_wage_per_gram': 18.0, 'wage_total': 225.0, 'category_id': c21}],
            supplier_gold_lines=[{'karat': 21, 'weight': 12.5}]),
        'two karats, two lines, no VAT': base(
            vat_applied=False, total=0.0, total_tax=0.0, wage_tax_total=0.0, gold_tax_total=0.0,
            manufacturing_wage_cash=3846.8, wage_subtotal=3846.8, gold_subtotal=0.0,
            items=[{'name': 'بناجر', 'karat': 21, 'weight': 216.4, 'quantity': 1, 'wage_per_gram': 12.0,
                    'manufacturing_wage_per_gram': 12.0, 'wage_total': 2596.8, 'category_id': c21},
                   {'name': 'طقم', 'karat': 18, 'weight': 50.0, 'quantity': 1, 'wage_per_gram': 25.0,
                    'manufacturing_wage_per_gram': 25.0, 'wage_total': 1250.0, 'category_id': c18}],
            supplier_gold_lines=[{'karat': 21, 'weight': 216.4}, {'karat': 18, 'weight': 50.0}]),
    }


def measure(invoice_id, supplier_id):
    from models import (Invoice, InvoiceGoldObligation, JournalEntry, JournalEntryLine, SafeBoxTransaction,
                        StockLineAllocation, db)
    from services.gold_allocation_service import corrected_weight
    entries = [e.id for e in JournalEntry.query.filter_by(reference_type='invoice', reference_id=invoice_id,
                                                          is_deleted=False)]
    lines = JournalEntryLine.query.filter(JournalEntryLine.journal_entry_id.in_(entries or [-1]),
                                          JournalEntryLine.is_deleted.is_(False)).all()
    inv = db.session.get(Invoice, invoice_id)
    rows = SafeBoxTransaction.query.filter(SafeBoxTransaction.ref_id == invoice_id,
                                           SafeBoxTransaction.ref_type.like('invoice%')).all()
    return {
        'lines': Counter((l.account.account_number, round(l.cash_debit or 0, 2), round(l.cash_credit or 0, 2),
                          *(round(getattr(l, f'{s}_{k}k') or 0, 3) for s in ('debit', 'credit') for k in KARATS))
                         for l in lines),
        'allocation': Counter((a.karat, a.category_id, round(a.grams, 3)) for a in StockLineAllocation.query.filter(
            StockLineAllocation.journal_entry_line_id.in_([l.id for l in lines] or [-1]))),
        'obligations': sorted((o.karat, corrected_weight(o)) for o in InvoiceGoldObligation.query.filter_by(
            invoice_id=invoice_id)),
        'safe_rows': Counter((r.safe_box_id, r.direction, r.ref_type,
                              *(round(getattr(r, f'weight_{k}k') or 0, 3) for k in KARATS)) for r in rows),
        'invoice': {f: round(float(getattr(inv, f) or 0), 2) for f in
                    ('total', 'total_tax', 'wage_subtotal', 'wage_tax_total', 'gold_subtotal', 'total_weight',
                     'payment_gold_weight')} | {'status': inv.status, 'is_posted': inv.is_posted,
                                                'gold_settlement_tracked': inv.gold_settlement_tracked},
    }


def report_today(now):
    from services.reports.purchases_analysis import purchases_analysis
    report = purchases_analysis(now=now, start=now.date(), end=now.date())
    body = json.loads(json.dumps(getattr(report, '__dict__', report), default=str, ensure_ascii=False))
    body.pop('read_at', None)          # the moment it was read, not what it says
    return body


def checks():
    from services.books_invariants import collect_books_facts
    return {kind: sorted(round(float(f.metric or 0), 3) for f in facts) for kind, facts in collect_books_facts().items()}


def run(way, supplier_id, c21, c18):
    """Each shape posted *way* ('whole', or 'received' then completed), saved;
    what each leaves, measured; with the purchases report and the nightly
    checks after all of them."""
    from flask import g
    from app import app
    from auth_decorators import generate_token
    from models import User, db
    from routes.invoices import add_invoice
    now = datetime.now()
    out = {}
    with app.app_context():
        headers = {'Authorization': f'Bearer {generate_token(User.query.filter_by(is_admin=True, is_active=True).first())}'}

        def call(payload, **kw):
            g.pop('current_user', None)
            with app.test_request_context('/api/invoices', method='POST', json=payload, headers=headers):
                rv = add_invoice(**kw)
            resp, status = (rv[0], rv[1]) if isinstance(rv, tuple) else (rv, 201)
            body = resp.get_json()
            if int(status) not in (200, 201):
                raise SystemExit(f'refused {kw}: {body}')
            return (body.get('invoice') or body)['id']

        for name, payload in shapes(supplier_id, c21, c18).items():
            if way == 'whole':
                doc = call(dict(payload))
            else:
                doc = call(dict(payload), posting_part='gold')
                call(dict(payload), posting_part='cash', complete_invoice_id=doc)
            db.session.commit()
            m = measure(doc, supplier_id)
            out[name] = {k: (sorted(map(list, v.items())) if isinstance(v, Counter) else v) for k, v in m.items()}
        out['purchases report, today'] = report_today(now)
        out['nightly checks'] = checks()
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--way', choices=('whole', 'received'))
    ap.add_argument('--out')
    ap.add_argument('--compare', nargs=2, metavar=('WHOLE_JSON', 'RECEIVED_JSON'))
    ap.add_argument('--supplier-id', type=int)
    ap.add_argument('--category-21', type=int)
    ap.add_argument('--category-18', type=int)
    args = ap.parse_args(argv)
    if args.compare:
        whole, received = (json.load(open(f, encoding='utf-8')) for f in args.compare)
        for doc in (whole, received):
            doc.get('purchases report, today', {}).pop('read_at', None)
        failures = 0
        for name in whole:
            parts = whole[name] if isinstance(whole[name], dict) and 'lines' in whole[name] else {'': whole[name]}
            print(f'== {name}')
            for part in parts:
                a = whole[name][part] if part else whole[name]
                b = received[name][part] if part else received[name]
                same = a == b
                failures += not same
                print(f'   {"same     " if same else "DIFFERENT"} {part or "all of it"}')
                if not same:
                    print('      whole:   ', json.dumps(a, ensure_ascii=False, default=str)[:600])
                    print('      received:', json.dumps(b, ensure_ascii=False, default=str)[:600])
        print('PARITY' if not failures else f'{failures} DIFFERENT')
        return 1 if failures else 0
    result = run(args.way, args.supplier_id, args.category_21, args.category_18)
    with open(args.out, 'w', encoding='utf-8') as fh:
        json.dump(result, fh, ensure_ascii=False, default=str, indent=1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
