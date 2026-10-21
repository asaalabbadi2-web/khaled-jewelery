"""The damaged wage goes to its role's account, and the entry is the server's before it is saved (ت2).

The owner (21 Oct 2026): the damaged wage stays typed until 2027 -- no sound
average to suggest it from (the wage inventory 1320 stands at -13,306.56: sales
release it at a category's fixed wage, the owner's decision is to leave that
to the 2027 pieces). Its account was chosen from every expense account each
time: on the 17 Oct copy three meltings put it on two accounts (510 twice,
5200 once). Now it is a role in «الربط المحاسبي», chosen once; unmapped, a
melting with a wage is refused saying where it is set.

And the confirmation showed a summary the screen built. As for the clearing
settlement (ADR-050 §3): POST /melting-renewal/preview builds the voucher with
the same code, reads its lines and rolls everything back -- no voucher, no
number, no safe row stays; it refuses as the operation refuses.

Run:
    python -m pytest tests/test_melting_wage_role_and_preview.py -v
"""
import uuid

import pytest

import routes.system as system_routes
from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE
from models import AccountingMapping, SafeBoxTransaction, Voucher, VoucherAccountLine, db
from tests.test_melting_and_renewal_go_one_way import _account, _holds, _post, _safe

ROLE = 'melting_damaged_wage'


@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    yield


@pytest.fixture
def capitalized(monkeypatch):
    inventory = _account('9', 'مخزون أجور المصنعية', type='Asset')
    monkeypatch.setattr(system_routes, 'wages_are_capitalized', lambda mode: True)
    monkeypatch.setattr(system_routes, '_get_manufacturing_wage_inventory_account_id', lambda: inventory.id)
    return inventory


def _map_role():
    account = _account('5', 'مصنعية تالفة', type='Expense')
    db.session.add(AccountingMapping(operation_type=DEFAULT_MAPPING_OPERATION_TYPE, account_type=ROLE,
                                     account_id=account.id, is_active=True))
    db.session.flush()
    return account


def _melting(src, dst, **extra):
    return {'operation_type': 'melting', 'from_safe_box_id': src.id, 'to_safe_box_id': dst.id,
            'lines': [{'karat': 21, 'gold_weight': 2.0}], **extra}


def test_the_wage_goes_to_its_roles_account_not_the_one_sent(auth_headers, capitalized):
    role_account = _map_role()
    elsewhere = _account('5', 'حساب أُرسل', type='Expense')
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 21, 10.0)
    resp = _post(auth_headers, _melting(src, dst, damage_wage_amount=100.0, damage_wage_account_id=elsewhere.id))
    assert resp.status_code == 201, resp.get_data(as_text=True)[:300]
    lines = VoucherAccountLine.query.filter_by(voucher_id=resp.get_json()['voucher']['id'], amount_type='cash').all()
    assert sorted((l.line_type, l.account_id, l.amount) for l in lines) == sorted([
        ('debit', role_account.id, 100.0), ('credit', capitalized.id, 100.0)])


def test_a_wage_with_its_role_unmapped_is_refused_saying_where(auth_headers, capitalized):
    AccountingMapping.query.filter_by(account_type=ROLE).delete()
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 21, 10.0)
    resp = _post(auth_headers, _melting(src, dst, damage_wage_amount=100.0))
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'account_not_mapped'
    assert 'الربط المحاسبي' in resp.get_json()['message']
    assert SafeBoxTransaction.query.filter_by(safe_box_id=src.id, ref_type='voucher').count() == 0


def _preview(headers, body):
    from flask import g
    from app import app as flask_app
    from tests.test_melting_and_renewal_go_one_way import with_categories   # each line its category (ت3)
    g.pop('current_user', None)
    return flask_app.test_client().post('/api/melting-renewal/preview', headers=headers, json=with_categories(body))


def test_the_preview_is_what_is_posted_and_leaves_nothing(auth_headers, capitalized):
    _map_role()
    src, dst = _safe('showroom'), _safe('scrap')
    _holds(src, 21, 10.0)
    body = _melting(src, dst, damage_wage_amount=100.0)
    # The world stands before the preview: its rollback is the request's, and a
    # request finds nothing pending (behind the fence a commit is a savepoint).
    db.session.commit()
    vouchers_before = Voucher.query.count()

    shown = _preview(auth_headers, body)
    assert shown.status_code == 200, shown.get_data(as_text=True)[:300]
    preview = shown.get_json()
    assert preview['preview'] is True
    assert Voucher.query.count() == vouchers_before
    assert SafeBoxTransaction.query.filter_by(safe_box_id=src.id, ref_type='voucher').count() == 0

    posted = _post(auth_headers, body)
    assert posted.status_code == 201, posted.get_data(as_text=True)[:300]
    rows = VoucherAccountLine.query.filter_by(voucher_id=posted.get_json()['voucher']['id']).all()

    def said(l):
        return (l['side'], l['account_id'], l['amount_type'], l['amount'], l['karat'])
    assert sorted(map(said, preview['lines'])) == sorted(
        (r.line_type, r.account_id, r.amount_type, round(float(r.amount), 3), r.karat) for r in rows)
    assert all(l['account_number'] and l['account_name'] for l in preview['lines'])


def test_the_preview_refuses_as_the_operation_refuses(auth_headers):
    src, dst = _safe('scrap'), _safe('showroom')     # a melting the wrong way
    _holds(src, 21, 10.0)
    resp = _preview(auth_headers, _melting(src, dst))
    assert resp.status_code == 400
    assert resp.get_json()['error'] == 'operation_direction_refused'
