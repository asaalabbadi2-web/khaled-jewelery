"""The supplier's weight beside the weight received (ADR-087 §4; the owner, 8 Nov 2026).

A receipt line says the supplier's weight, from his paper, and the weight
received, on the scale. The stock takes what was received; the supplier is
owed what his paper says; the difference -- within the settings' tolerance
(0.10 g a line at first) -- goes on the count's roles: received more, «زيادة
جرد»; less, «خسارة الوزن (الفقد)». Above it, refused, unless the owner or the
manager (receiving.approve_difference) approves it with a reason. A line that
says no supplier's weight is the weight received: nothing differs, as before.

Run:
    python -m pytest tests/test_receiving_weight_difference.py -v
"""
import uuid

import pytest

from models import Account, InvoiceItem, JournalEntry, JournalEntryLine, Permission, Role, User, db
from tests.test_receiving_completes_one_document import _call, _id
from tests.test_supplier_purchase_effect import SHAPES, app, rollback_after_each, world  # noqa: F401
from tests.test_supplier_purchase_effect import _vat  # noqa: F401
from tests.test_stock_count import roles  # noqa: F401 -- the count's two roles, with weight twins


def _receipt(world, received, supplier=None, **extra):
    build, _ = SHAPES['items only, no VAT']
    payload = build(world)
    payload['items'][0]['weight'] = received
    if supplier is not None:
        payload['items'][0]['supplier_weight'] = supplier
    payload.update(extra)
    return payload


def _grams(invoice_id, account_id):
    lines = (JournalEntryLine.query.join(JournalEntry, JournalEntry.id == JournalEntryLine.journal_entry_id)
             .filter(JournalEntry.reference_type == 'invoice', JournalEntry.reference_id == invoice_id,
                     JournalEntryLine.account_id == account_id, JournalEntryLine.is_deleted.is_(False)).all())
    return round(sum(float(l.debit_21k or 0) - float(l.credit_21k or 0) for l in lines), 3)


def _supplier_twin(world):
    return db.session.get(Account, world['supplier'].account_id).memo_account_id


def _headers_for(*codes):
    from auth_decorators import generate_token
    user = User(username=f'rw_{uuid.uuid4().hex[:6]}', full_name='t', is_active=True, is_admin=False)
    user.set_password('x')
    db.session.add(user)
    role = Role(name=f'rw_{uuid.uuid4().hex[:6]}', name_ar='t', is_active=True)
    db.session.add(role)
    db.session.flush()
    for code in codes:
        perm = Permission.query.filter_by(code=code).first() or Permission(code=code, name=code, name_ar=code,
                                                                             category='t', is_active=True)
        db.session.add(perm)
        role.permissions.append(perm)
    user.roles.append(role)
    db.session.flush()
    return {'Authorization': f'Bearer {generate_token(user)}'}


@pytest.mark.parametrize('received, supplier, role, grams', [
    (20.00, 20.05, 'shortage_w', 0.05),      # received less than his paper: a weight lost
    (20.05, 20.00, 'surplus_w', -0.05),      # received more: a weight gained
])
def test_within_the_tolerance_the_difference_is_the_counts(auth_headers, world, roles, received, supplier, role,
                                                           grams):
    status, body = _call(auth_headers, _receipt(world, received, supplier), posting_part='gold')
    assert status == 201, body
    receipt = _id(body)
    assert _grams(receipt, world['display'].account_id) == received, 'the stock takes what was received'
    assert _grams(receipt, _supplier_twin(world)) == -supplier, 'the supplier is owed his paper'
    assert _grams(receipt, roles[role].id) == grams
    assert InvoiceItem.query.filter_by(invoice_id=receipt).one().supplier_weight == supplier


def test_no_supplier_weight_is_the_weight_received(auth_headers, world, roles):
    status, body = _call(auth_headers, _receipt(world, 20.0), posting_part='gold')
    receipt = _id(body)
    assert _grams(receipt, _supplier_twin(world)) == -20.0
    assert _grams(receipt, roles['shortage_w'].id) == _grams(receipt, roles['surplus_w'].id) == 0.0


def test_above_it_refused_unless_approved_with_a_reason(auth_headers, world, roles):
    status, body = _call(auth_headers, _receipt(world, 19.70, 20.00), posting_part='gold')
    assert status == 400 and body['error'] == 'receipt_difference_over_tolerance', body
    approval = {'difference_approval': {'reason': 'ميزان المورد غير معاير'}}
    status, body = _call(_headers_for('invoices.create', 'invoices.supplier'),
                         _receipt(world, 19.70, 20.00, **approval), posting_part='gold')
    assert status == 400 and body['error'] == 'receipt_difference_not_approved', 'not the owner or the manager'
    status, body = _call(_headers_for('invoices.create', 'invoices.supplier', 'receiving.approve_difference'),
                         _receipt(world, 19.70, 20.00, **approval), posting_part='gold')
    assert status == 201, body
    assert _grams(_id(body), roles['shortage_w'].id) == 0.3
