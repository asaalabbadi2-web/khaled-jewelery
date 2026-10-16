"""Categories put in order (ADR-045 B, the owner, 14 Oct 2026).

Measured on the 12 Oct copy: a karat as text, one in Arabic-Indic digits
(«٢١» -- read as no number); no way to stop a category; a used category
deleted by its items alone (698 invoice lines and the delete only counted
items); one duplicate; customer scrap purchases with no category at all.
The owner: Latin digits; every category names its karat and its karat is
fixed once used -- manual entry must not mistake one karat for another; a
group derived from the name, never typed; a «كسر» category per karat given
to every customer scrap purchase line; stop, never delete, what is used.

Run:
    python -m pytest tests/test_categories.py -v
"""
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Category, Invoice, InvoiceItem, Item, db


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def _uid():
    return uuid.uuid4().hex[:6]


def _word():
    """A category name's random part, letters only: a hex uid holding «18»,
    «22» or «24» names a karat, and the route rightly refuses a name naming
    another karat than its category's (1 run in ~10 failed on it)."""
    return _uid().translate(str.maketrans('0123456789', 'ghijklmnop'))


def _client():
    return flask_app.test_client()


def _category(name=None, karat='21', **kw):
    c = Category(name=name or f'عقد {_word()} {karat}', karat=karat, **kw)
    db.session.add(c)
    db.session.flush()
    return c


def _used(category):
    invoice = Invoice(invoice_type_id=int(_uid(), 16), invoice_type='بيع', date=datetime(2026, 10, 14),
                      total=0.0, is_posted=False)
    db.session.add(invoice)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=invoice.id, category_id=category.id, name='قطعة', quantity=1,
                               price=0.0, karat=21.0, weight=3.0))
    db.session.flush()


class TestTheNameAndTheKarat:

    def test_a_category_needs_its_karat(self, app, auth_headers):
        resp = _client().post('/api/categories', headers=auth_headers, json={'name': f'خاتم {_word()}'})
        assert resp.status_code == 400

    def test_digits_are_latin_and_the_name_carries_its_karat(self, app, auth_headers):
        base = f'خاتم {_word()}'
        resp = _client().post('/api/categories', headers=auth_headers, json={'name': base, 'karat': '٢١'})
        assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
        body = resp.get_json()
        assert (body['name'], body['karat']) == (f'{base} 21', '21')

    def test_a_name_naming_another_karat_is_refused(self, app, auth_headers):
        resp = _client().post('/api/categories', headers=auth_headers,
                              json={'name': f'خاتم {_word()} ١٨', 'karat': '21'})
        assert resp.status_code == 400

    def test_an_unknown_karat_is_refused(self, app, auth_headers):
        resp = _client().post('/api/categories', headers=auth_headers, json={'name': f'خاتم {_word()}', 'karat': '19'})
        assert resp.status_code == 400

    def test_the_karat_of_a_used_category_is_fixed(self, app, auth_headers):
        used, free = _category(), _category()
        _used(used)
        refused = _client().put(f'/api/categories/{used.id}', headers=auth_headers, json={'karat': '18'})
        assert refused.status_code == 400
        moved = _client().put(f'/api/categories/{free.id}', headers=auth_headers,
                              json={'karat': '18', 'name': free.name.rsplit(' ', 1)[0]})
        assert moved.status_code == 200, moved.get_data(as_text=True)[:300]
        assert moved.get_json()['karat'] == '18' and moved.get_json()['name'].endswith(' 18')

    @pytest.mark.parametrize('name,karat,group', [
        ('عقد ذهب (ناعم) 21', '21', 'عقد ذهب (ناعم)'),
        ('سلسال عيار 22', '22', 'سلسال'),
        ('سبايك ذهب عيار 24', '24', 'سبايك ذهب'),
        ('بنجرة ذهب 21', '21', 'بنجرة ذهب'),
    ])
    def test_the_group_is_derived_from_the_name(self, app, name, karat, group):
        from services.categories import group_name
        assert group_name(name, karat) == group


class TestStopNotDelete:

    def test_a_used_category_is_not_deleted(self, app, auth_headers):
        """The delete counted items only: 698 invoice lines and no item went to the FK."""
        cat = _category()
        _used(cat)
        resp = _client().delete(f'/api/categories/{cat.id}', headers=auth_headers)
        assert resp.status_code == 409
        assert db.session.get(Category, cat.id) is not None

    def test_an_unused_category_is_deleted(self, app, auth_headers):
        cat = _category()
        assert _client().delete(f'/api/categories/{cat.id}', headers=auth_headers).status_code == 200

    def test_a_stopped_category_is_offered_to_no_one(self, app, auth_headers):
        cat = _category()
        assert _client().put(f'/api/categories/{cat.id}', headers=auth_headers,
                             json={'is_active': False}).status_code == 200
        offered = {c['id'] for c in _client().get('/api/categories', headers=auth_headers).get_json()}
        everything = {c['id'] for c in _client().get('/api/categories?include_inactive=1',
                                                     headers=auth_headers).get_json()}
        assert cat.id not in offered and cat.id in everything


class TestScrap:

    @staticmethod
    def _scrap(karat='21'):
        name = f'كسر {karat}'
        found = Category.query.filter_by(name=name).first()
        if found is None:
            found = _category(name=name, karat=karat, is_scrap=True)
        found.is_scrap, found.is_active = True, True
        db.session.flush()
        return found

    def test_a_customer_scrap_line_gets_its_karat_scrap_category(self, app):
        from services.categories import assign_scrap_categories
        scrap = self._scrap('21')
        invoice = Invoice(invoice_type_id=int(_uid(), 16), invoice_type='شراء من عميل', gold_type='scrap',
                          date=datetime(2026, 10, 14), total=0.0, is_posted=False)
        db.session.add(invoice)
        db.session.flush()
        line = InvoiceItem(invoice_id=invoice.id, name='كسر', quantity=1, price=0.0, karat=21.0, weight=4.0)
        kept = InvoiceItem(invoice_id=invoice.id, name='خاتم', quantity=1, price=0.0, karat=21.0, weight=2.0,
                           category_id=_category().id)
        db.session.add_all([line, kept])
        db.session.flush()
        assign_scrap_categories(invoice)
        assert line.category_id == scrap.id
        assert kept.category_id != scrap.id, 'a line with a category keeps it'

    def test_a_sale_is_not_given_scrap(self, app):
        from services.categories import assign_scrap_categories
        self._scrap('21')
        invoice = Invoice(invoice_type_id=int(_uid(), 16), invoice_type='بيع', date=datetime(2026, 10, 14),
                          total=0.0, is_posted=False)
        db.session.add(invoice)
        db.session.flush()
        line = InvoiceItem(invoice_id=invoice.id, name='قطعة', quantity=1, price=0.0, karat=21.0, weight=4.0)
        db.session.add(line)
        db.session.flush()
        assign_scrap_categories(invoice)
        assert line.category_id is None

    def test_a_purchase_item_lives_in_its_karat_scrap_category(self, app, auth_headers):
        """POST /purchase-items failed on every call (an unimported barcode
        generator) after creating a karat-less «أصناف الشراء» category."""
        scrap = self._scrap('18')
        name = f'كسر خواتم {_word()}'
        resp = _client().post('/api/purchase-items', headers=auth_headers, json={'name': name, 'karat': '18'})
        assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
        assert Item.query.filter_by(name=name).one().category_id == scrap.id
        listed = {i['name'] for i in _client().get('/api/purchase-items', headers=auth_headers).get_json()}
        assert name in listed
        assert Category.query.filter_by(name='أصناف الشراء').first() is None


def test_posting_a_customer_scrap_purchase_classifies_its_scrap(app):
    """The scrap enters its stock under «كسر 21», not «بلا تصنيف»."""
    from models import Account, JournalEntry, JournalEntryLine, SafeBox
    from posting_routes import post_invoice_document
    from services.stock_ledger import stock_balances
    scrap = TestScrap._scrap('21')
    account = Account(account_number=f'9{_uid()}', name=f'عهدة {_uid()}', type='Asset', tracks_weight=True)
    db.session.add(account)
    db.session.flush()
    box = SafeBox(name=f'عهدة {_uid()}', safe_type='gold', account_id=account.id, is_active=True,
                  stock_location='custody')
    db.session.add(box)
    invoice = Invoice(invoice_type_id=int(_uid(), 16), invoice_type='شراء من عميل', gold_type='scrap',
                      date=datetime(2026, 10, 14), total=0.0, is_posted=False, posted_by='t')
    db.session.add(invoice)
    db.session.flush()
    db.session.add(InvoiceItem(invoice_id=invoice.id, name='كسر', quantity=1, price=0.0, karat=21.0, weight=4.0))
    je = JournalEntry(entry_number=f'JE-K-{_uid()}', date=datetime(2026, 10, 14), description='شراء كسر',
                      entry_type='عادي', is_posted=False, is_draft=True, created_by='t',
                      reference_type='invoice', reference_id=invoice.id)
    db.session.add(je)
    db.session.flush()
    db.session.add(JournalEntryLine(journal_entry_id=je.id, account_id=account.id, debit_21k=4.0, description='كسر'))
    db.session.flush()
    post_invoice_document(invoice, 't')
    db.session.flush()
    held = {(r['category_id'], r['karat']): r['grams'] for r in stock_balances() if r['safe_box_id'] == box.id}
    assert held == {(scrap.id, 21): 4.0}
