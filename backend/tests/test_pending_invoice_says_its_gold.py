"""A scrap sale waiting to be posted says it is one (the owner, 29 Oct 2026:
each invoice in its own color). It is stored «بيع» with gold_type 'scrap',
and the lists of what waits sent the type alone: the approvals window drew
it as a sale of new gold."""
import datetime as dt
import uuid

from app import app as flask_app
from models import Invoice, db


def test_a_waiting_scrap_sale_sends_its_gold_type(db_fence, auth_headers):
    inv = Invoice(invoice_type_id=900000 + int(uuid.uuid4().int % 99999), invoice_type='بيع',
                  gold_type='scrap',
                  # Latest of all: the lists return their newest 50.
                  date=dt.datetime(2099, 1, 1), total=10.0, status='unpaid', is_posted=False)
    db.session.add(inv)
    db.session.flush()
    for path, key in (('/api/invoices/pending-post', 'invoices'), ('/api/pending-actions', 'pending_invoices')):
        resp = flask_app.test_client().get(path, headers=auth_headers)
        assert resp.status_code == 200, (path, resp.get_data(as_text=True)[:200])
        rows = [r for r in (resp.get_json().get(key) or []) if r['id'] == inv.id]
        assert rows and rows[0].get('gold_type') == 'scrap', (path, rows)
