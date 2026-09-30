"""Every finding a job can write has a name, an explanation and a rank.

The nightly checks and the schedulers write reconciliation_findings, and
until now nobody could read them: the screen «نتائج الفحص الليلي» shows them.
What each kind MEANS is the server's to say, not the screen's to invent: the
listing carries, for every kind it returns, an Arabic title, an explanation
of what it costs the books, and a rank -- the standing risk first (the
roadmap: «الخطر القائم أولًا»). A kind without them would show as a code.

Run:
    python -m pytest tests/test_finding_kinds.py -v
"""
from datetime import datetime

from app import app as flask_app
from models import ReconciliationFinding, db
from services.finding_kinds import KIND_INFO, subject_label


def _every_kind_a_job_writes():
    import clearing_settlement_scheduler as clearing
    import safebox_reconciliation_scheduler as safebox
    from services import books_invariants
    return (set(books_invariants.CHECKS)
            | {clearing.OVERDUE_KIND, 'STALE_SETTLEMENT'}
            | {safebox.VOUCHER_ENTRY_UNPOSTED, safebox.SAFEBOX_ROW_BACKFILLED})


def test_every_kind_has_a_title_an_explanation_and_a_rank():
    for kind in _every_kind_a_job_writes():
        info = KIND_INFO.get(kind)
        assert info, f'{kind} has no description'
        assert info['title_ar'] and info['explanation_ar'] and isinstance(info['rank'], int), kind


def test_the_ranks_put_what_is_wrong_in_the_books_first():
    order = sorted(KIND_INFO, key=lambda k: KIND_INFO[k]['rank'])
    assert order[0] == 'POSTED_ENTRY_OF_UNPOSTED_INVOICE'
    assert order.index('OVERDUE_SETTLEMENT') < order.index('SAFEBOX_SUBLEDGER_DRIFT')
    assert order[-1] == 'STALE_SETTLEMENT', 'the retired alarm goes last'


def test_subjects_read_as_words():
    assert subject_label('journal_entry:6641') == 'قيد رقم 6641'
    assert subject_label('safe_box:38') == 'خزينة رقم 38'
    assert subject_label('voucher:4309') == 'سند رقم 4309'
    assert subject_label('payment_method:11') == 'وسيلة دفع رقم 11'
    assert subject_label(None) == '—'
    assert subject_label('something:else') == 'something:else'


def test_the_listing_carries_the_meaning(auth_headers):
    with flask_app.app_context():
        row = ReconciliationFinding(kind='POSTED_ENTRY_OF_UNPOSTED_INVOICE', source='books_invariants',
                                    subject_key='journal_entry:987654', metric=108300.0,
                                    detail='{"invoice_status": "rejected"}', created_at=datetime.utcnow())
        db.session.add(row)
        db.session.commit()
        row_id = row.id
    try:
        resp = flask_app.test_client().get('/api/reconciliation/findings', headers=auth_headers)
        assert resp.status_code == 200
        data = resp.get_json()
        assert data['kinds']['POSTED_ENTRY_OF_UNPOSTED_INVOICE']['title_ar']
        mine = next(f for f in data['findings'] if f['id'] == row_id)
        assert mine['subject_label'] == 'قيد رقم 987654'
    finally:
        with flask_app.app_context():
            ReconciliationFinding.query.filter_by(id=row_id).delete()
            db.session.commit()
