"""Gold paid with a supplier's purchase says which invoice it paid (ADR-028; 9 Nov 2026).

The purchase screen's «سداد ذهب للمورد» writes a payment voucher with the
invoice, approved and posted in the same request -- and wrote no attribution
row. Above the historical boundary that row is the only evidence of whom the
gold paid: the nightly check found PV-2026-01515 and PV-2026-01518 (purchases
214 and 215, 7 Nov) unattributed; 4889 (purchase 208) was attributed by hand
three days after. The attribution is written in the same request, once the
invoice's gold obligations exist -- refused, never skipped, if it cannot be.

Run:
    python -m pytest tests/test_gold_paid_with_purchase_is_attributed.py -v
"""
from app import app as flask_app
from models import Invoice, Voucher, VoucherInvoiceGoldAttribution, db
from services.books_invariants import check_gold_attribution_missing
from tests.test_supplier_purchase_effect import SHAPES, _vat, app, rollback_after_each, world  # noqa: F401


def _bought_paying_gold(headers, world, grams):
    build, _ = SHAPES['items only, no VAT']
    payload = build(world)
    payload.update(settlement_method='barter',
                   gold_settlements=[{'safe_box_id': world['display'].id, 'karat': 21, 'weight': grams}])
    return flask_app.test_client().post('/api/invoices', headers=headers, json=payload)


def test_the_gold_paid_with_the_purchase_is_attributed_to_it(auth_headers, world):
    r = _bought_paying_gold(auth_headers, world, 5.0)
    assert r.status_code == 201, r.get_data(as_text=True)[:400]
    invoice_id = r.get_json()['id']
    voucher = Voucher.query.filter_by(reference_type='invoice', reference_id=invoice_id).one()
    rows = VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).all()
    assert [(r.invoice_id, r.karat, r.weight) for r in rows] == [(invoice_id, 21.0, 5.0)]
    assert not [f for f in check_gold_attribution_missing() if f.subject_key == f'voucher:{voucher.id}'], \
        'the nightly check finds nothing'


def test_paid_in_full_the_purchase_s_gold_is_settled(auth_headers, world):
    r = _bought_paying_gold(auth_headers, world, 20.0)        # the shape's 20 g, all of it
    assert r.status_code == 201, r.get_data(as_text=True)[:400]
    invoice = db.session.get(Invoice, r.get_json()['id'])
    voucher = Voucher.query.filter_by(reference_type='invoice', reference_id=invoice.id).one()
    assert VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).count() == 1


def test_paid_in_another_karat_its_value_is_attributed(auth_headers, world):
    """Purchase 214: owed 258.4 g of 21, paid 226.1 g of 24 -- the same
    main-karat gold. Attributed in its real karat."""
    from tests.test_melting_and_renewal_go_one_way import _holds
    _holds(world['display'], 24, 50.0)
    build, _ = SHAPES['items only, no VAT']
    payload = build(world)
    payload.update(settlement_method='barter',
                   gold_settlements=[{'safe_box_id': world['display'].id, 'karat': 24, 'weight': 17.5}])
    r = flask_app.test_client().post('/api/invoices', headers=auth_headers, json=payload)
    assert r.status_code == 201, r.get_data(as_text=True)[:400]
    voucher = Voucher.query.filter_by(reference_type='invoice', reference_id=r.get_json()['id']).one()
    row = VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).one()
    assert (row.karat, row.weight, round(row.weight_main_karat, 2)) == (24.0, 17.5, 20.0)


def test_the_repair_attributes_what_the_screen_left_unattributed(auth_headers, world):
    """As the 9 Nov backup: a purchase's gold voucher with no attribution row."""
    from services.repair.purchase_gold_attribution import attribute_purchase_gold
    r = _bought_paying_gold(auth_headers, world, 5.0)
    voucher = Voucher.query.filter_by(reference_type='invoice', reference_id=r.get_json()['id']).one()
    VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).delete()     # as the old code left it
    db.session.flush()
    dry = attribute_purchase_gold(by='t')
    assert [a['voucher_id'] for a in dry['attributed']] == [voucher.id]
    assert VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).count() == 0, 'dry: nothing'
    applied = attribute_purchase_gold(by='t', dry_run=False)
    assert applied['attributed'][0]['rows'] == [{'karat': 21.0, 'weight': 5.0, 'main': 5.0}]
    assert attribute_purchase_gold(by='t', dry_run=False)['attributed'] == [], 'a second run: nothing'


def test_a_voucher_of_another_source_is_said_not_touched(auth_headers, world):
    from services.repair.purchase_gold_attribution import attribute_purchase_gold
    r = _bought_paying_gold(auth_headers, world, 5.0)
    voucher = Voucher.query.filter_by(reference_type='invoice', reference_id=r.get_json()['id']).one()
    VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).delete()
    voucher.notes = None                       # a voucher the employee wrote
    db.session.flush()
    result = attribute_purchase_gold(by='t', dry_run=False)
    assert [l['voucher_id'] for l in result['left']] == [voucher.id] and result['attributed'] == []


def test_a_finding_the_owner_accepted_is_left_as_he_decided(auth_headers, world):
    """PV-2026-01293, 0.01 g: accepted as a rounding difference (12 Oct 2026)."""
    from datetime import datetime
    from models import ReconciliationFinding
    from services.repair.purchase_gold_attribution import attribute_purchase_gold
    r = _bought_paying_gold(auth_headers, world, 5.0)
    voucher = Voucher.query.filter_by(reference_type='invoice', reference_id=r.get_json()['id']).one()
    VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).delete()
    db.session.add(ReconciliationFinding(kind='GOLD_ATTRIBUTION_MISSING', subject_key=f'voucher:{voucher.id}',
                                         check_count=1, created_at=datetime(2026, 10, 12), metric=5.0,
                                         accepted_at=datetime(2026, 10, 12), accepted_by='owner',
                                         accepted_reason='تقريب'))
    db.session.flush()
    result = attribute_purchase_gold(by='t', dry_run=False)
    assert result['attributed'] == [] and result['left'][0]['why'].startswith('accepted')
    assert VoucherInvoiceGoldAttribution.query.filter_by(voucher_id=voucher.id).count() == 0
