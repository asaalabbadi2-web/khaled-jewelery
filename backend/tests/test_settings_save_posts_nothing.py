"""Saving the settings screen posts nothing (SETTINGS-001).

PUT /settings posted, on every save with voucher_auto_post or auto_post_entries
on (both are, in production), EVERY unposted journal entry referencing an
invoice or a voucher, as 'system', without looking at its document. On
28 Sep 2026 06:40 one save posted the entries of two REJECTED sales: invoice
2821's put 5,700 g of 21k out of display inventory and 102,600 of wages into
the books, and the year's weight profit fell from 2,248 g to 2,029 g. The next
save would have posted the entry of any invoice awaiting approval.

A setting says how FUTURE documents are posted. It never posts existing ones:
an entry is posted by its document's own posting (post_invoice_document,
voucher approval), which knows whether the document stands.

Run:
    python -m pytest tests/test_settings_save_posts_nothing.py -v
"""
import uuid
from datetime import datetime

from app import app as flask_app
from models import Invoice, JournalEntry, Settings, Voucher, db


def _uid():
    return uuid.uuid4().hex[:8]


def test_a_settings_save_posts_no_entry(auth_headers):
    with flask_app.app_context():
        from routes.system import _get_settings_singleton
        existed = Settings.query.first() is not None
        settings = _get_settings_singleton(create_if_missing=True)
        was = (settings.voucher_auto_post, settings.auto_post_entries)
        settings.voucher_auto_post = True
        settings.auto_post_entries = True
        rejected = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع', date=datetime.now(),
                           total=5700.0, amount_paid=0.0, status='rejected', is_posted=False)
        waiting = Invoice(invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='بيع', date=datetime.now(),
                          total=4150.0, amount_paid=4150.0, status='paid', is_posted=False)
        voucher = Voucher(voucher_number=f'V-{_uid()}', voucher_type='receipt', date=datetime.now(),
                          status='pending', created_by='t', amount_cash=10.0, created_at=datetime.now())
        db.session.add_all([rejected, waiting, voucher])
        db.session.flush()
        entries = [JournalEntry(entry_number=f'JE-T-{_uid()}', date=datetime.now(), description='t',
                                reference_type=rt, reference_id=rid, is_posted=False, is_draft=False,
                                created_by='t')
                   for rt, rid in (('invoice', rejected.id), ('invoice', waiting.id), ('voucher', voucher.id))]
        db.session.add_all(entries)
        db.session.commit()
        ids = [e.id for e in entries]
        invoice_ids, voucher_id = [rejected.id, waiting.id], voucher.id
    try:
        resp = flask_app.test_client().put('/api/settings', headers=auth_headers,
                                           json={'backup_retention_count': 7})
        assert resp.status_code == 200, resp.get_data(as_text=True)[:300]
        with flask_app.app_context():
            posted = [je.id for je in JournalEntry.query.filter(JournalEntry.id.in_(ids)).all() if je.is_posted]
            assert posted == [], 'a settings save posted entries it has no business posting'
    finally:
        with flask_app.app_context():
            JournalEntry.query.filter(JournalEntry.id.in_(ids)).delete(synchronize_session=False)
            Invoice.query.filter(Invoice.id.in_(invoice_ids)).delete(synchronize_session=False)
            Voucher.query.filter_by(id=voucher_id).delete(synchronize_session=False)
            s = Settings.query.first()
            if existed:
                s.voucher_auto_post, s.auto_post_entries = was
            else:
                db.session.delete(s)   # leave no settings row for the tests after this one
            db.session.commit()


def test_the_settings_route_holds_no_posting():
    import inspect
    from routes import system
    src = inspect.getsource(system.update_settings)
    assert 'is_posted = True' not in src
