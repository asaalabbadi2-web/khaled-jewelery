"""A return is taken back before its original (the owner, 31 Oct 2026).

The 31 Oct copy: sale 1785 was unposted at 21:39:17 while its return 12 stood
posted against it -- for 15 seconds a posted return referred to a sale that
was not. The owner: «أوافقك». Every door that unposts or rejects asks the one
guard (posted_returns_of): the posting screen, the invoices route, a batch --
where a return in the same batch is taken back first -- and the rejection.

Run:
    python -m pytest tests/test_a_return_is_taken_back_before_its_original.py -v
"""
from datetime import datetime

import pytest

from models import Invoice, db
from tests.retraction_world import _create, unposting_allowed, world  # noqa: F401 (fixtures)


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _return_of(sale_id: int) -> Invoice:
    ret = Invoice(invoice_type='مرتجع بيع', invoice_type_id=900000 + sale_id, original_invoice_id=sale_id,
                  date=datetime.now(), total=1000.0, is_posted=True, posted_by='t')
    db.session.add(ret)
    db.session.flush()
    return ret


def _post(app, headers, url, body=None):
    from flask import g
    g.pop('current_user', None)
    return app.test_client().post(url, headers=headers, json=body or {})


@pytest.fixture
def sale_and_return(auth_headers, world, unposting_allowed):  # noqa: F811
    sale = _create(auth_headers, world, 'sale_on_credit', held=False)
    return db.session.get(Invoice, sale['id']), _return_of(sale['id'])


@pytest.mark.parametrize('url', ['/api/invoices/{id}/unpost', '/api/invoices/unpost/{id}'])
def test_its_original_waits_for_the_return(app, auth_headers, sale_and_return, url):
    sale, ret = sale_and_return
    refused = _post(app, auth_headers, url.format(id=sale.id))
    assert refused.status_code == 409 and refused.get_json()['error'] == 'has_posted_returns'
    assert 'ألغِ ترحيل المرتجع أولًا' in refused.get_json()['message']
    assert db.session.get(Invoice, sale.id).is_posted, 'nothing was taken back'

    assert _post(app, auth_headers, url.format(id=ret.id)).status_code == 200, 'the return first'
    assert _post(app, auth_headers, url.format(id=sale.id)).status_code == 200, 'then its original'


def test_a_batch_takes_the_return_back_first_or_stops(app, auth_headers, sale_and_return):
    sale, ret = sale_and_return
    alone = _post(app, auth_headers, '/api/invoices/unpost-batch', {'invoice_ids': [sale.id]})
    assert alone.status_code == 409 and 'مرتجع مرحّل' in str(alone.get_json()['blocked'])

    both = _post(app, auth_headers, '/api/invoices/unpost-batch', {'invoice_ids': [sale.id, ret.id]})
    assert both.status_code == 200, both.get_data(as_text=True)[:300]
    assert not db.session.get(Invoice, sale.id).is_posted and not db.session.get(Invoice, ret.id).is_posted


def test_an_original_is_not_rejected_while_its_return_stands(app, auth_headers, sale_and_return):
    """Before this guard an original could be unposted under a posted return;
    rejecting it then must still wait for the return."""
    sale, ret = sale_and_return
    from posting_routes import unpost_invoice_document
    unpost_invoice_document(sale)               # the 31 Oct state: the original unposted, the return posted
    db.session.flush()
    refused = _post(app, auth_headers, f'/api/invoices/{sale.id}/reject', {'reason': 'خطأ'})
    assert refused.status_code == 409, refused.get_data(as_text=True)[:300]
    assert refused.get_json()['error'] == 'has_posted_returns'
