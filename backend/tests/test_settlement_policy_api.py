"""HTTP contract for reading and changing the settlement limits.

The model has always said these numbers are POLICY — finance changes them without
a deploy. There was no surface to change them through, so the only way in was
hand-written SQL, and that is the real reason a documented waiver sat behind a
5 SAR rounding limit: nobody could raise it.

Two rules this proves, and they are the ones that matter:

  1. A change CLOSES the current row and inserts a new one. Never an UPDATE — a
     posted settlement froze the policy id it was judged against, so editing that
     row rewrites the basis of an accounting decision already taken.
  2. A limit that can never be reached is refused rather than stored. A
     per-operation tolerance above its own monthly cap would display a number the
     mechanism ignores.

No numbers are asserted as "correct" here. The fixtures use the values already in
force so the tests measure the mechanism, not a business choice.

Run:
    python -m pytest tests/test_settlement_policy_api.py -v
"""

import uuid
from datetime import datetime, timedelta

import pytest

from app import app, db
from auth_decorators import generate_token
from models import (
    Permission,
    Role,
    SupplierSettlementAdjustment as SAD,
    SupplierSettlementPolicy,
    SupplierSettlementReasonLimit,
    User,
)


ENDPOINT = '/api/supplier-settlement-policy'

# The values already in force in this environment. Reused verbatim so a POST test
# leaves the limits where it found them.
GLOBALS = {
    'tolerance_cash': 5.0,
    'tolerance_weight': 0.05,
    'period_cap_cash': 50.0,
    'period_cap_weight': 0.5,
    'review_threshold_cash': 500.0,
}


def _headers_for(*permission_codes, is_admin=False):
    suffix = uuid.uuid4().hex[:8]
    user = User(username=f'pol_{suffix}', full_name='policy test user',
                is_active=True, is_admin=is_admin)
    user.set_password('x')
    db.session.add(user)
    db.session.flush()

    if permission_codes:
        role = Role(name=f'pol_role_{suffix}', name_ar='دور اختبار', is_active=True)
        db.session.add(role)
        db.session.flush()
        for code in permission_codes:
            perm = Permission.query.filter_by(code=code).first()
            if perm is None:
                perm = Permission(code=code, name=code, name_ar=code,
                                  category='supplier_settlement_adjustments',
                                  is_active=True)
                db.session.add(perm)
                db.session.flush()
            role.permissions.append(perm)
        user.roles.append(role)

    db.session.commit()
    return {'Authorization': f'Bearer {generate_token(user)}'}


@pytest.fixture
def restore_policy():
    """These endpoints commit, so the database is left exactly as found.

    Exactly as found matters more than it looks: a policy row left behind here is
    a SECOND open policy for every later test, and _resolve_policy() then picks
    between them by date. That is how leaking one row turned six passing tests in
    test_supplier_settlement_adjustment.py red — they assert the id their own
    fixture created was the one frozen onto the document.

    So the cleanup removes whatever this fixture created, including the seed
    policy when there was none to begin with, and reopens a pre-existing row only
    if a POST closed it.
    """
    with app.app_context():
        existing = SupplierSettlementPolicy.in_effect_at(datetime.now())
        seeded_here = existing is None
        if seeded_here:
            existing = SupplierSettlementPolicy(
                effective_from=datetime.now() - timedelta(days=30),
                created_by='test', **GLOBALS,
            )
            db.session.add(existing)
            db.session.commit()
        before_id = existing.id

        yield before_id

        floor = before_id if seeded_here else before_id + 1
        for policy in (SupplierSettlementPolicy.query
                       .filter(SupplierSettlementPolicy.id >= floor).all()):
            SupplierSettlementReasonLimit.query.filter_by(
                policy_id=policy.id).delete()
            db.session.delete(policy)
        if not seeded_here:
            pre_existing = db.session.get(SupplierSettlementPolicy, before_id)
            if pre_existing is not None:
                pre_existing.effective_to = None
        db.session.commit()


# ── Reading ──────────────────────────────────────────────────────────────────

def test_get_reports_the_effective_limits_for_every_reason(restore_policy):
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.view')
        with app.test_client() as client:
            resp = client.get(ENDPOINT, headers=headers)

    assert resp.status_code == 200
    payload = resp.get_json()['policy']
    reported = {r['reason_code']: r for r in payload['reason_limits']}

    assert set(reported) == set(SAD.VALID_REASON_CODES), \
        'every reason is listed, so the screen never hides one that has no row'

    for code, row in reported.items():
        # The number in force, resolved — never a blank the reader must resolve.
        for field in ('tolerance_cash', 'tolerance_weight_main_karat',
                      'review_threshold_cash', 'period_cap_cash',
                      'period_cap_weight_main_karat'):
            assert row[field] is not None, f'{code}.{field} must report an effective value'

    assert reported[SAD.REASON_OTHER]['always_requires_manager'] is True, \
        'the hard-coded floor is visible to the screen, not just to the service'


def test_get_marks_which_reasons_have_a_row_of_their_own(restore_policy):
    """is_explicit is how the screen distinguishes an inherited limit from a set
    one — the two report the same number and mean different things."""
    with app.app_context():
        policy = SupplierSettlementPolicy.in_effect_at(datetime.now())
        db.session.add(SupplierSettlementReasonLimit(
            policy_id=policy.id, reason_code=SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
            tolerance_cash=GLOBALS['tolerance_cash'],
            tolerance_weight_main_karat=GLOBALS['tolerance_weight'],
        ))
        db.session.commit()
        try:
            headers = _headers_for('supplier_settlement_adjustments.view')
            with app.test_client() as client:
                resp = client.get(ENDPOINT, headers=headers)
            reported = {r['reason_code']: r
                        for r in resp.get_json()['policy']['reason_limits']}
            assert reported[SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER]['is_explicit'] is True
            assert reported[SAD.REASON_ROUNDING_DIFFERENCE]['is_explicit'] is False
        finally:
            SupplierSettlementReasonLimit.query.filter_by(
                policy_id=policy.id).delete()
            db.session.commit()


# ── Writing ──────────────────────────────────────────────────────────────────

def test_post_closes_the_previous_row_instead_of_editing_it(restore_policy):
    """The rule the model states and nothing enforced until now."""
    before_id = restore_policy
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.approve')
        with app.test_client() as client:
            resp = client.post(ENDPOINT, headers=headers, json=dict(
                GLOBALS,
                reason_limits=[{
                    'reason_code': SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
                    'tolerance_cash': GLOBALS['tolerance_cash'],
                    'tolerance_weight_main_karat': GLOBALS['tolerance_weight'],
                }],
            ))

        assert resp.status_code == 201, resp.get_json()
        body = resp.get_json()
        assert body['closed_policy_id'] == before_id
        assert body['policy_id'] != before_id

        closed = db.session.get(SupplierSettlementPolicy, before_id)
        assert closed.effective_to is not None, \
            'the old limits keep their identity and gain an end date'
        assert SupplierSettlementPolicy.in_effect_at(
            datetime.now()).id == body['policy_id']


def test_post_stores_only_the_per_reason_ceilings_that_were_sent(restore_policy):
    """An omitted ceiling stays NULL, which is what "inherit the global" means.
    Copying the global value into the row instead would freeze it: a later change
    to the global would silently not reach this reason."""
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.approve')
        with app.test_client() as client:
            resp = client.post(ENDPOINT, headers=headers, json=dict(
                GLOBALS,
                reason_limits=[{
                    'reason_code': SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
                    'tolerance_cash': GLOBALS['tolerance_cash'],
                    'tolerance_weight_main_karat': GLOBALS['tolerance_weight'],
                }],
            ))
        assert resp.status_code == 201

        row = SupplierSettlementReasonLimit.query.filter_by(
            policy_id=resp.get_json()['policy_id'],
            reason_code=SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
        ).one()
        assert row.review_threshold_cash is None
        assert row.period_cap_cash is None
        assert row.period_cap_weight_main_karat is None

        effective = SupplierSettlementPolicy.in_effect_at(
            datetime.now()).limits_for_reason(SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER)
        assert effective.review_threshold_cash == GLOBALS['review_threshold_cash']
        assert effective.period_cap_cash == GLOBALS['period_cap_cash']


def test_post_refuses_a_tolerance_that_its_own_cap_would_always_reject(restore_policy):
    """A limit the mechanism can never reach is a lie on the screen."""
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.approve')
        with app.test_client() as client:
            resp = client.post(ENDPOINT, headers=headers, json=dict(
                GLOBALS,
                reason_limits=[{
                    'reason_code': SAD.REASON_DOCUMENTED_SUPPLIER_WAIVER,
                    'tolerance_cash': 25000.0,
                    'tolerance_weight_main_karat': 50.0,
                    'period_cap_cash': 1000.0,
                }],
            ))
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'unreachable_limit'


def test_post_refuses_an_unreachable_weight_tolerance(restore_policy):
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.approve')
        with app.test_client() as client:
            resp = client.post(ENDPOINT, headers=headers, json=dict(
                GLOBALS,
                reason_limits=[{
                    'reason_code': SAD.REASON_WEIGHT_DIFFERENCE,
                    'tolerance_cash': 1.0,
                    'tolerance_weight_main_karat': 50.0,
                    'period_cap_weight_main_karat': 1.0,
                }],
            ))
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'unreachable_limit'


def test_post_refuses_a_negative_ceiling(restore_policy):
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.approve')
        with app.test_client() as client:
            resp = client.post(ENDPOINT, headers=headers, json=dict(
                GLOBALS,
                reason_limits=[{
                    'reason_code': SAD.REASON_ROUNDING_DIFFERENCE,
                    'tolerance_cash': 1.0,
                    'tolerance_weight_main_karat': 0.01,
                    'review_threshold_cash': -1.0,
                }],
            ))
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'negative_limit'


def test_post_refuses_an_unknown_reason_code(restore_policy):
    """Reason codes are LAW — the enum lives in code with the accounting that
    depends on it. A new one arrives by deploy, never by policy row."""
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.approve')
        with app.test_client() as client:
            resp = client.post(ENDPOINT, headers=headers, json=dict(
                GLOBALS,
                reason_limits=[{
                    'reason_code': 'GOODWILL_GESTURE',
                    'tolerance_cash': 1.0,
                    'tolerance_weight_main_karat': 0.01,
                }],
            ))
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'invalid_reason_code'


def test_a_refused_post_leaves_the_limits_in_force_untouched(restore_policy):
    """A rejection writes nothing — not the new row, not the closing date."""
    before_id = restore_policy
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.approve')
        with app.test_client() as client:
            client.post(ENDPOINT, headers=headers, json=dict(
                GLOBALS,
                reason_limits=[{
                    'reason_code': 'NOT_A_REASON',
                    'tolerance_cash': 1.0,
                    'tolerance_weight_main_karat': 0.01,
                }],
            ))
        assert SupplierSettlementPolicy.in_effect_at(datetime.now()).id == before_id
        assert db.session.get(
            SupplierSettlementPolicy, before_id).effective_to is None


# ── Authorization ────────────────────────────────────────────────────────────

def test_changing_limits_needs_more_than_permission_to_read_them(
    restore_policy, monkeypatch
):
    """Raising a ceiling is an authority decision, so it sits behind approve —
    not behind view, which any clerk reading the screen holds."""
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0')
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.view')
        with app.test_client() as client:
            resp = client.post(ENDPOINT, headers=headers, json=GLOBALS)
        assert resp.status_code == 403


def test_anonymous_callers_cannot_read_or_change_the_limits(monkeypatch):
    monkeypatch.setenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0')
    with app.app_context():
        with app.test_client() as client:
            assert client.get(ENDPOINT).status_code == 401
            assert client.post(ENDPOINT, json=GLOBALS).status_code == 401


def test_post_refuses_a_global_tolerance_above_its_own_monthly_cap(restore_policy):
    """The same defect class as the per-reason case. The globals govern every
    reason without a row, so an unreachable global is the wider mistake."""
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.approve')
        with app.test_client() as client:
            resp = client.post(ENDPOINT, headers=headers,
                               json=dict(GLOBALS, tolerance_cash=100.0))
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'unreachable_limit'


def test_post_refuses_a_global_weight_tolerance_above_its_cap(restore_policy):
    with app.app_context():
        headers = _headers_for('supplier_settlement_adjustments.approve')
        with app.test_client() as client:
            resp = client.post(ENDPOINT, headers=headers,
                               json=dict(GLOBALS, tolerance_weight=5.0))
        assert resp.status_code == 400
        assert resp.get_json()['error'] == 'unreachable_limit'
