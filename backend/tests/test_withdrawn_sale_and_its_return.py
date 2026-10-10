"""A withdrawn sale stays withdrawn, and a return takes back what its sale gave
(the owner, 10 Oct 2026, on 3303 and 3300).

3303 -- a sale unposted then rejected, re-entered as 3304 -- was withdrawn
correctly in its entries, its receipt and its inventory ledger, but:
  - its weight-closing order stayed open (with 2821's 5,700 g and 3123's
    3.457 g): purchases close gold against open orders oldest first and book
    its cost of sale -- against sales that never were;
  - the posting screen listed it and posted it again (on a copy: a second
    sale of the gold re-entered in 3304, 2,500 owed with no receipt);
  - unposting or rejecting asked about payments only, never about gold
    already closed against the sale.

3300 -- the return of sale 2535 -- reversed the entry and the money, but:
  - its lines carried no category (the screen sends the original line's id,
    not its category): the gold went back to no category, and the category
    weight it came from stayed short -- every sale return since April;
  - the performance race and the points bonus count sales only: a return
    took nothing back. The owner: it takes the sale's points back in the
    return's own period, from the one who sold; bonuses already paid stay.

Run:
    python -m pytest tests/test_withdrawn_sale_and_its_return.py -v
"""
import uuid

import pytest

from app import app as flask_app
from models import (CategoryWeightMovement, Category, Employee, Invoice, InvoiceItem,
                    WeightClosingExecution, WeightClosingOrder, db)
from tests.retraction_world import _create, unposting_allowed, world  # noqa: F401 (fixtures)
from tests.test_return_within_its_original import _paid_sale, _post, _return_of


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _client():
    return flask_app.test_client()


def _order_of(invoice_id):
    db.session.expire_all()
    return WeightClosingOrder.query.filter_by(invoice_id=invoice_id).first()


def _rejected_sale(headers, world):
    sale = _create(headers, world, 'sale_on_credit', held=True)
    resp = _client().post(f"/api/invoices/{sale['id']}/reject", headers=headers, json={'reason': 'سعر خطأ'})
    assert resp.status_code == 200, resp.get_json()
    return sale


def _executed(order, grams=0.5):
    db.session.add(WeightClosingExecution(order_id=order.id, execution_type='purchase_scrap',
                                          weight_main_karat=grams, price_per_gram=400.0))
    order.executed_weight_main_karat = grams
    db.session.flush()


# ── a rejected sale: its order, its posting ─────────────────────────────

def test_rejecting_a_sale_cancels_its_weight_closing_order(auth_headers, world):
    sale = _create(auth_headers, world, 'sale_on_credit', held=True)
    assert _order_of(sale['id']).status == 'open'

    _client().post(f"/api/invoices/{sale['id']}/reject", headers=auth_headers, json={'reason': 'x'})

    order = _order_of(sale['id'])
    assert order.status == 'cancelled'
    assert float(order.remaining_weight_main_karat) == 0.0


def test_a_rejected_invoice_is_not_awaiting_posting(auth_headers, world):
    sale = _rejected_sale(auth_headers, world)
    listed = _client().get('/api/invoices/unposted', headers=auth_headers).get_json()['invoices']
    assert sale['id'] not in {i['id'] for i in listed}


@pytest.mark.parametrize('door', ['post', 'batch', 'approve', 'approve_large_discount'])
def test_a_rejected_invoice_is_never_posted_again(auth_headers, world, door):
    sale = _rejected_sale(auth_headers, world)
    client = _client()
    if door == 'post':
        resp = client.post(f"/api/invoices/post/{sale['id']}", headers=auth_headers, json={})
    elif door == 'batch':
        resp = client.post('/api/invoices/post-batch', headers=auth_headers, json={'invoice_ids': [sale['id']]})
    elif door == 'approve':
        resp = client.post(f"/api/invoices/{sale['id']}/approve", headers=auth_headers, json={})
    else:
        resp = client.post(f"/api/invoices/approve-large-discount/{sale['id']}", headers=auth_headers, json={})
    if door != 'batch':
        assert resp.status_code == 409, resp.get_json()
        assert resp.get_json()['error'] == 'invoice_retracted'
    db.session.expire_all()
    assert db.session.get(Invoice, sale['id']).is_posted is False


def test_the_one_posting_refuses_a_rejected_invoice_whoever_calls_it(auth_headers, world):
    from posting_routes import post_invoice_document
    sale = _rejected_sale(auth_headers, world)
    with pytest.raises(ValueError):
        post_invoice_document(db.session.get(Invoice, sale['id']), 'someone')


# ── gold already closed: a return, not a retraction ─────────────────────

@pytest.mark.parametrize('path', ['/api/invoices/unpost/{id}', '/api/invoices/{id}/unpost', 'batch'])
def test_unposting_is_refused_when_gold_was_closed_against_the_sale(auth_headers, unposting_allowed,
                                                                      world, path):
    sale = _create(auth_headers, world, 'sale_on_credit', held=False)
    _executed(_order_of(sale['id']))
    if path == 'batch':
        resp = _client().post('/api/invoices/unpost-batch', headers=auth_headers,
                              json={'invoice_ids': [sale['id']]})
    else:
        resp = _client().post(path.format(id=sale['id']), headers=auth_headers, json={})
    assert resp.status_code == 409, resp.get_json()
    db.session.expire_all()
    assert db.session.get(Invoice, sale['id']).is_posted is True


def test_rejecting_is_refused_when_gold_was_closed_against_the_sale(auth_headers, world):
    sale = _create(auth_headers, world, 'sale_on_credit', held=True)
    _executed(_order_of(sale['id']))
    resp = _client().post(f"/api/invoices/{sale['id']}/reject", headers=auth_headers, json={'reason': 'x'})
    assert resp.status_code == 409
    assert resp.get_json()['error'] == 'has_closing_executions'
    db.session.expire_all()
    assert db.session.get(Invoice, sale['id']).status != 'rejected'


def test_a_purchase_closes_no_gold_against_a_sale_that_does_not_stand(auth_headers, world):
    """Only orders of posted, standing sales are consumed -- not one awaiting
    approval, not one rejected -- whatever is older in the queue."""
    from accounting.weight_closing import _auto_consume_weight_closing
    held = _create(auth_headers, world, 'sale_on_credit', held=True)
    rejected = _rejected_sale(auth_headers, world)
    order = _order_of(rejected['id'])
    order.status = 'open'                      # as 2821, 3123, 3303 were left
    order.remaining_weight_main_karat = order.total_weight_main_karat
    db.session.flush()
    standing = _create(auth_headers, world, 'sale_on_credit', held=False)

    _auto_consume_weight_closing(None, weight_override=100.0, price_per_gram=400.0)

    assert float(_order_of(held['id']).executed_weight_main_karat or 0) == 0.0
    assert float(_order_of(rejected['id']).executed_weight_main_karat or 0) == 0.0
    assert float(_order_of(standing['id']).executed_weight_main_karat or 0) > 0.0


# ── a return: its categories ────────────────────────────────────────────

def _category():
    cat = Category(name=f'صنف {uuid.uuid4().hex[:6]}')
    db.session.add(cat)
    db.session.flush()
    return cat


def _categorised_sale(headers, world, cat):
    from tests.retraction_world import _payload
    payload = _payload(world, 'sale_on_credit', held=False)
    payload['items'][0]['category_id'] = cat.id
    payload['total_cost'] = 0.0
    payload['amount_paid'] = payload['total']
    payload['payments'] = [{'payment_method_id': world['pm'].id, 'amount': payload['total']}]
    resp = _post(headers, payload)
    assert resp.status_code == 201, resp.get_json()
    return resp.get_json()


def test_a_returned_line_takes_its_category_from_the_original(auth_headers, world):
    cat = _category()
    sale = _categorised_sale(auth_headers, world, cat)

    ret = _post(auth_headers, _return_of(world, sale, total=1000.0))   # sends no category, as the screen

    assert ret.status_code == 201, ret.get_json()
    ret_id = ret.get_json()['id']
    assert [i.category_id for i in InvoiceItem.query.filter_by(invoice_id=ret_id)] == [cat.id]
    moved = CategoryWeightMovement.query.filter_by(invoice_id=ret_id).all()
    assert [(m.category_id, round(m.weight_delta_grams, 3)) for m in moved] == [(cat.id, 2.0)], \
        'the category gets its weight back'


def test_a_returned_line_without_the_original_line_id_matches_by_name_and_karat():
    from datetime import datetime
    from services.return_lines import inherit_original_categories
    cats = [_category() for _ in range(3)]
    original = Invoice(invoice_type_id=int(uuid.uuid4().hex[:5], 16) + 1, invoice_type='بيع',
                       date=datetime.now(), total=100.0, status='paid', is_posted=True)
    db.session.add(original)
    db.session.flush()
    for name, karat, cat in (('تعليقة', 18, cats[0]), ('حلق', 18, cats[1]), ('سوار', 21, cats[2])):
        db.session.add(InvoiceItem(invoice_id=original.id, name=name, karat=karat, weight=1.0,
                                   quantity=1, price=10.0, category_id=cat.id))
    db.session.flush()
    items = [{'name': 'حلق', 'karat': 18}, {'name': 'تعليقة', 'karat': '18'},
             {'name': 'سوار', 'karat': 21, 'category_id': cats[0].id}]

    inherit_original_categories(items, original.id)

    assert [i.get('category_id') for i in items] == [cats[1].id, cats[0].id, cats[0].id], \
        'matched by name and karat; a category the request sends is kept'


# ── a return: its points ────────────────────────────────────────────────

ENGINE = dict(points_source='profit_cash', cash_amount_per_point=50.0, points_per_gram=10.0)


def _seller_and_another():
    other = Employee(name=f'موظف {uuid.uuid4().hex[:6]}', employee_code=f'E-{uuid.uuid4().hex[:6]}')
    db.session.add(other)
    db.session.flush()
    return other


def _sold_by(sale, employee_id):
    """The route takes the seller from the signed-in user; here, who sold is set."""
    db.session.get(Invoice, sale['id']).employee_id = employee_id
    db.session.flush()


def _returned_by(ret, employee_id):
    db.session.get(Invoice, ret['id']).employee_id = employee_id
    db.session.flush()


def test_a_return_takes_back_its_sales_points_in_the_share_it_returns(auth_headers, world):
    from points.engine import compute_invoices_points
    sale = _paid_sale(auth_headers, world)
    half = _post(auth_headers, _return_of(world, sale, total=500.0, weight=1.0)).get_json()
    sale_inv, ret_inv = db.session.get(Invoice, sale['id']), db.session.get(Invoice, half['id'])
    alone = compute_invoices_points([sale_inv], **ENGINE)
    assert alone > 0
    assert compute_invoices_points([ret_inv], **ENGINE) == pytest.approx(-alone / 2)
    assert compute_invoices_points([sale_inv, ret_inv], **ENGINE) == pytest.approx(alone / 2)


def test_the_race_takes_the_points_from_the_one_who_sold(auth_headers, world):
    from metrics.points_metric import PointsMetric
    sale = _paid_sale(auth_headers, world)
    _sold_by(sale, world['holder'].id)
    returner = _seller_and_another()
    ret = _post(auth_headers, _return_of(world, sale, total=1000.0)).get_json()
    _returned_by(ret, returner.id)                           # 1089: sold by 18, returned by 19
    metric = PointsMetric(points_source='profit_cash', cash_amount_per_point=50.0)

    _, _, _, _, before, _, _ = metric._group_and_score([db.session.get(Invoice, sale['id'])], 10.0)
    _, _, _, _, after, _, _ = metric._group_and_score(
        [db.session.get(Invoice, sale['id']), db.session.get(Invoice, ret['id'])], 10.0)

    seller = world['holder'].id
    assert before[seller] > 0
    assert after[seller] == pytest.approx(0.0)
    assert returner.id not in after, 'the one who recorded the return loses nothing'
    assert 'مرتجع بيع' in metric.invoice_types


def test_a_return_counts_in_its_own_period_against_the_seller(auth_headers, world):
    """The bonus and the goals find a seller's returns by the return's date --
    the period it is made in -- and by the original's seller."""
    from datetime import datetime, timedelta
    from points.engine import sale_returns_against
    sale = _paid_sale(auth_headers, world)
    _sold_by(sale, world['holder'].id)
    returner = _seller_and_another()
    ret = _post(auth_headers, _return_of(world, sale, total=1000.0)).get_json()
    _returned_by(ret, returner.id)
    now = datetime.now()
    window = (now - timedelta(days=1), now + timedelta(days=1))

    found = sale_returns_against(lambda o: o.employee_id == world['holder'].id, *window)
    assert ret['id'] in {r.id for r in found}
    assert ret['id'] not in {r.id for r in sale_returns_against(lambda o: o.employee_id == returner.id, *window)}
    assert not sale_returns_against(lambda o: o.employee_id == world['holder'].id,
                                    now + timedelta(days=2), now + timedelta(days=3))
