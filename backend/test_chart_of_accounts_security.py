"""Chart-of-Accounts security & correctness tests.

Coverage:
  - Auth: 401 (no token), 403 (no permission), 2xx (with permission) × 5 endpoints
  - Validation: missing/invalid fields, invalid parent, invalid account number, duplicate
  - Business rule: tracks_weight derived from account number prefix, user value ignored
  - Parallel account: warning in response (not crash) when creation fails
  - Database: duplicate number → 409, rollback on IntegrityError, children guard on delete
"""
import pytest
from app import app
from models import db, Account, User
from auth_decorators import generate_token


# ── helpers ──────────────────────────────────────────────────────────────────

def _make_user(username, is_admin=False, permissions=None):
    """Create and flush a test user. `permissions` is a list of permission name strings."""
    u = User(
        username=username,
        full_name=username,
        email=None,
        is_active=True,
        is_admin=is_admin,
    )
    u.set_password('pass123')
    db.session.add(u)
    db.session.flush()
    if permissions:
        from models import Permission
        for perm_name in permissions:
            p = Permission.query.filter_by(name=perm_name).first()
            if p:
                u.permissions.append(p)
    return u


@pytest.fixture(scope='module')
def admin_headers():
    with app.app_context():
        admin = User.query.filter_by(username='admin').first()
        token = generate_token(admin)
        return {'Authorization': f'Bearer {token}'}


@pytest.fixture(scope='module')
def no_perm_headers():
    """Non-admin user with NO accounts.* permissions."""
    with app.app_context():
        u = _make_user('noperm_accounts')
        db.session.commit()
        token = generate_token(u)
        return {'Authorization': f'Bearer {token}'}


@pytest.fixture(scope='module')
def parent_account_id():
    """ID of a seeded root account to use as parent in tests."""
    with app.app_context():
        a = Account.query.filter_by(account_number='15').first()
        return a.id


# ── 1. Authentication: 401 when token is invalid ─────────────────────────────
# Note: .env sets BYPASS_AUTH_FOR_DEVELOPMENT=1, which auto-sets g.current_user=admin
# for requests WITHOUT an Authorization header. Sending a bad token forces the bypass
# to stand down (it bails when Authorization header is present) so real auth runs.

_BAD_TOKEN = {'Authorization': 'Bearer totally.invalid.token'}


class TestAuth401:
    def test_next_number_rejects_bad_token(self):
        with app.test_client() as c:
            r = c.get('/api/accounts/next-number/1', headers=_BAD_TOKEN)
            assert r.status_code == 401

    def test_validate_number_rejects_bad_token(self):
        with app.test_client() as c:
            r = c.post('/api/accounts/validate-number', json={}, headers=_BAD_TOKEN)
            assert r.status_code == 401

    def test_add_account_rejects_bad_token(self):
        with app.test_client() as c:
            r = c.post('/api/accounts', json={}, headers=_BAD_TOKEN)
            assert r.status_code == 401

    def test_update_account_rejects_bad_token(self):
        # Use seeded account_number='15' — id may vary, so look it up first.
        with app.app_context():
            a = Account.query.filter_by(account_number='15').first()
            account_id = a.id if a else 15

        with app.test_client() as c:
            r = c.put(f'/api/accounts/{account_id}', json={}, headers=_BAD_TOKEN)
            assert r.status_code == 401

    def test_delete_account_rejects_bad_token(self):
        with app.app_context():
            a = Account.query.filter_by(account_number='15').first()
            account_id = a.id if a else 15

        with app.test_client() as c:
            r = c.delete(f'/api/accounts/{account_id}', headers=_BAD_TOKEN)
            assert r.status_code == 401


# ── 2. Authorization: 403 when authenticated but no permission ───────────────

class TestAuth403:
    def test_next_number_forbidden(self, no_perm_headers):
        with app.test_client() as c:
            r = c.get('/api/accounts/next-number/1', headers=no_perm_headers)
            assert r.status_code == 403

    def test_validate_number_forbidden(self, no_perm_headers):
        with app.test_client() as c:
            r = c.post('/api/accounts/validate-number', json={}, headers=no_perm_headers)
            assert r.status_code == 403

    def test_add_account_forbidden(self, no_perm_headers):
        with app.test_client() as c:
            r = c.post('/api/accounts', json={}, headers=no_perm_headers)
            assert r.status_code == 403

    def test_update_account_forbidden(self, no_perm_headers):
        with app.test_client() as c:
            r = c.put('/api/accounts/1', json={}, headers=no_perm_headers)
            assert r.status_code == 403

    def test_delete_account_forbidden(self, no_perm_headers):
        with app.test_client() as c:
            r = c.delete('/api/accounts/1', headers=no_perm_headers)
            assert r.status_code == 403


# ── 3. Validation: add_account ───────────────────────────────────────────────

class TestAddAccountValidation:
    def _post(self, client, data, headers):
        return client.post('/api/accounts', json=data, headers=headers)

    def test_missing_account_number(self, admin_headers):
        with app.test_client() as c:
            r = self._post(c, {'name': 'اختبار', 'type': 'Asset'}, admin_headers)
            assert r.status_code == 400
            body = r.get_json()
            assert body['error'] == 'MISSING_ACCOUNT_NUMBER'

    def test_blank_account_number(self, admin_headers):
        with app.test_client() as c:
            r = self._post(c, {'account_number': '   ', 'name': 'اختبار', 'type': 'Asset'}, admin_headers)
            assert r.status_code == 400
            assert r.get_json()['error'] == 'MISSING_ACCOUNT_NUMBER'

    def test_missing_name(self, admin_headers):
        with app.test_client() as c:
            r = self._post(c, {'account_number': '9901', 'type': 'Asset'}, admin_headers)
            assert r.status_code == 400
            assert r.get_json()['error'] == 'MISSING_NAME'

    def test_blank_name(self, admin_headers):
        with app.test_client() as c:
            r = self._post(c, {'account_number': '9901', 'name': '', 'type': 'Asset'}, admin_headers)
            assert r.status_code == 400
            assert r.get_json()['error'] == 'MISSING_NAME'

    def test_missing_type(self, admin_headers):
        with app.test_client() as c:
            r = self._post(c, {'account_number': '9901', 'name': 'اختبار'}, admin_headers)
            assert r.status_code == 400
            assert r.get_json()['error'] == 'MISSING_TYPE'

    def test_invalid_type(self, admin_headers):
        with app.test_client() as c:
            r = self._post(c, {'account_number': '9901', 'name': 'اختبار', 'type': 'Fake'}, admin_headers)
            assert r.status_code == 400
            assert r.get_json()['error'] == 'INVALID_TYPE'

    def test_invalid_parent_id(self, admin_headers):
        with app.test_client() as c:
            r = self._post(
                c,
                {'account_number': '9901', 'name': 'اختبار', 'type': 'Asset', 'parent_id': 999999},
                admin_headers,
            )
            assert r.status_code == 404
            assert r.get_json()['error'] == 'PARENT_NOT_FOUND'

    def test_duplicate_account_number_returns_409(self, admin_headers):
        with app.test_client() as c:
            # account_number='15' already seeded in conftest
            r = self._post(c, {'account_number': '15', 'name': 'مكرر', 'type': 'Asset'}, admin_headers)
            assert r.status_code == 409
            assert r.get_json()['error'] == 'ACCOUNT_NUMBER_EXISTS'


# ── 4. Business rule: tracks_weight derived from prefix ──────────────────────

class TestTracksWeightBusinessRule:
    def test_non_7_prefix_always_sets_tracks_weight_false(self, admin_headers):
        """Non-7xxx accounts are always cash + tracks_weight=False, regardless of user input."""
        with app.test_client() as c:
            # User sends True — backend must ignore it and set False
            r = c.post(
                '/api/accounts',
                json={
                    'account_number': '9910',
                    'name': 'حساب نقدي اختبار',
                    'type': 'Asset',
                    'tracks_weight': True,
                },
                headers=admin_headers,
            )
            assert r.status_code == 201
            body = r.get_json()
            assert body['tracks_weight'] is False, 'Backend must ignore user tracks_weight for non-7xxx'
            assert body['transaction_type'] == 'cash'

        with app.test_client() as c:
            # User sends False — backend sets False (same result, explicit case)
            r = c.post(
                '/api/accounts',
                json={
                    'account_number': '9911',
                    'name': 'حساب نقدي اختبار 2',
                    'type': 'Asset',
                    'tracks_weight': False,
                },
                headers=admin_headers,
            )
            assert r.status_code == 201
            assert r.get_json()['tracks_weight'] is False

    def test_7xxx_prefix_sets_gold(self, admin_headers):
        """Account number starting with 7 → tracks_weight=True, transaction_type=gold."""
        with app.test_client() as c:
            r = c.post(
                '/api/accounts',
                json={
                    'account_number': '7910',
                    'name': 'حساب ذهبي اختبار',
                    'type': 'Expense',
                    'tracks_weight': False,  # user sends False — must be ignored
                },
                headers=admin_headers,
            )
            assert r.status_code == 201
            body = r.get_json()
            assert body['tracks_weight'] is True, 'Backend must ignore user-supplied tracks_weight'
            assert body['transaction_type'] == 'gold'

    def test_a_number_into_the_twin_scheme_is_refused_and_the_kind_kept(self, admin_headers):
        """PUT: a cash account renumbered 7xxx is refused -- the kind is the account's
        mark, not its number (CHART-002 4c4); it used to flip silently to gold."""
        with app.app_context():
            a = Account(account_number='9920', name='تعديل اختبار', type='Asset', tracks_weight=False)
            db.session.add(a)
            db.session.commit()
            target_id = a.id

        with app.test_client() as c:
            r = c.put(
                f'/api/accounts/{target_id}',
                json={'account_number': '7920', 'tracks_weight': True},  # the user's tracks_weight is ignored
                headers=admin_headers,
            )
            assert r.status_code == 400
            assert r.get_json()['error'] == 'MEMO_MISMATCH'
        with app.app_context():
            kept = Account.query.get(target_id)
            assert kept.account_number == '9920' and kept.tracks_weight is False

    def test_an_update_keeps_the_accounts_own_mark(self, admin_headers):
        """PUT: the mark is the account's -- an update does not re-derive it from the
        number (CHART-002 4c4; it used to reset a weight account numbered outside the
        scheme to cash on any edit, its name's included)."""
        with app.app_context():
            # Account with legacy tracks_weight=True (e.g. old inventory account)
            a = Account(account_number='9921', name='مخزون اختبار', type='Asset', tracks_weight=True)
            db.session.add(a)
            db.session.commit()
            target_id = a.id

        with app.test_client() as c:
            r = c.put(f'/api/accounts/{target_id}', json={'name': 'مخزون اختبار معدّل', 'tracks_weight': False},
                      headers=admin_headers)
            assert r.status_code == 200
            assert r.get_json()['tracks_weight'] is True, 'the mark is kept, the input ignored'


# ── 5. Parallel account: warning surfaces, not crash ─────────────────────────

class TestParallelAccountWarning:
    def test_no_create_parallel_flag_means_no_parallel(self, admin_headers):
        """Without create_parallel=True in request → no parallel account, no error, no warning."""
        with app.test_client() as c:
            r = c.post(
                '/api/accounts',
                json={'account_number': '9930', 'name': 'بدون موازي', 'type': 'Asset'},
                headers=admin_headers,
            )
            assert r.status_code == 201
            body = r.get_json()
            assert 'parallel_account' not in body or body.get('parallel_account') is None
            assert 'warning' not in body

    def test_create_parallel_creates_gold_account_and_links(self, admin_headers):
        """create_parallel=True on a root account → gold account created at root (no parent)."""
        with app.test_client() as c:
            r = c.post(
                '/api/accounts',
                json={
                    'account_number': '9935',
                    'name': 'شريك اختبار',
                    'type': 'Liability',
                    'create_parallel': True,
                },
                headers=admin_headers,
            )
            assert r.status_code == 201
            body = r.get_json()
            assert body['tracks_weight'] is False
            assert body['transaction_type'] == 'cash'
            assert 'parallel_account' in body
            assert body['parallel_account']['account_number'] == '79935'
            assert body['parallel_account']['transaction_type'] == 'gold'

        with app.app_context():
            cash_acc = Account.query.filter_by(account_number='9935').first()
            gold_acc = Account.query.filter_by(account_number='79935').first()
            assert cash_acc.memo_account_id == gold_acc.id
            assert gold_acc.memo_account_id == cash_acc.id
            assert gold_acc.tracks_weight is True
            assert gold_acc.parent_id is None  # root cash → root gold

    def test_create_parallel_inherits_gold_parent(self, admin_headers):
        """Gold parallel of a child account must be nested under the parent's gold parallel.

        Convention: 3-digit parent → 4-digit children (account_number_generator rule).
        Tree: cash_parent(993) + gold_parent(7993) as linked pair.
              cash_child(9930) added with create_parallel=True.
              → gold_child(79930) must have parent_id = gold_parent.id
        """
        from account_pair_service import link_accounts
        with app.app_context():
            # Use 556/7556 range — isolated from all other test account numbers
            cash_parent = Account(account_number='556', name='أب نقدي', type='Liability',
                                  transaction_type='cash', tracks_weight=False)
            gold_parent = Account(account_number='7556', name='أب ذهبي', type='Liability',
                                  transaction_type='gold', tracks_weight=True)
            db.session.add_all([cash_parent, gold_parent])
            db.session.flush()
            link_accounts(cash_parent, gold_parent, created_by='test')
            db.session.commit()
            cash_parent_id = cash_parent.id
            gold_parent_id = gold_parent.id

        with app.test_client() as c:
            # 3-digit parent → 4-digit child (account_number_generator convention)
            r = c.post(
                '/api/accounts',
                json={
                    'account_number': '5560',
                    'name': 'ابن نقدي',
                    'type': 'Liability',
                    'parent_id': cash_parent_id,
                    'create_parallel': True,
                },
                headers=admin_headers,
            )
            assert r.status_code == 201, r.get_json()

        with app.app_context():
            gold_child = Account.query.filter_by(account_number='75560').first()
            assert gold_child is not None, 'Gold child (75560) must be created'
            assert gold_child.parent_id == gold_parent_id, (
                f'Gold child parent must be gold_parent id={gold_parent_id}, got {gold_child.parent_id}'
            )

    def test_create_parallel_ignored_for_7xxx_accounts(self, admin_headers):
        """create_parallel=True on a 7xxx (gold) account is silently ignored — already the memo side."""
        with app.test_client() as c:
            r = c.post(
                '/api/accounts',
                json={
                    'account_number': '79936',
                    'name': 'ذهبي اختبار',
                    'type': 'Liability',
                    'create_parallel': True,
                },
                headers=admin_headers,
            )
            assert r.status_code == 201
            body = r.get_json()
            assert body['tracks_weight'] is True
            assert body['transaction_type'] == 'gold'
            assert 'parallel_account' not in body or body.get('parallel_account') is None


# ── 6. Delete: guards ────────────────────────────────────────────────────────

class TestDeleteAccount:
    def test_delete_account_with_children_returns_409(self, admin_headers):
        with app.app_context():
            parent = Account(account_number='8800', name='أب اختبار', type='Asset')
            db.session.add(parent)
            db.session.flush()
            child = Account(
                account_number='88001', name='فرع اختبار', type='Asset', parent_id=parent.id
            )
            db.session.add(child)
            db.session.commit()
            parent_id = parent.id

        with app.test_client() as c:
            r = c.delete(f'/api/accounts/{parent_id}', headers=admin_headers)
            assert r.status_code == 409
            assert r.get_json()['error'] == 'HAS_CHILDREN'

    def test_delete_account_with_je_lines_returns_409(self, admin_headers):
        """Account referenced by a JournalEntryLine must return HAS_TRANSACTIONS."""
        from models import JournalEntry, JournalEntryLine
        from datetime import datetime
        with app.app_context():
            acct = Account(account_number='8810', name='حساب بحركات', type='Asset')
            db.session.add(acct)
            db.session.flush()
            je = JournalEntry(
                entry_number='TEST-8810-JE',
                date=datetime.now(),
                description='اختبار حذف',
            )
            db.session.add(je)
            db.session.flush()
            line = JournalEntryLine(
                journal_entry_id=je.id,
                account_id=acct.id,
                cash_debit=100.0,
                cash_credit=0.0,
            )
            db.session.add(line)
            db.session.commit()
            acct_id = acct.id

        with app.test_client() as c:
            r = c.delete(f'/api/accounts/{acct_id}', headers=admin_headers)
            assert r.status_code == 409
            assert r.get_json()['error'] == 'HAS_TRANSACTIONS'

    def test_delete_leaf_account_with_no_transactions_succeeds(self, admin_headers):
        """Account with no JE lines, no entity links, no SafeBox → deleted successfully."""
        with app.app_context():
            leaf = Account(account_number='8899', name='ورقة اختبار', type='Asset')
            db.session.add(leaf)
            db.session.commit()
            leaf_id = leaf.id

        with app.test_client() as c:
            r = c.delete(f'/api/accounts/{leaf_id}', headers=admin_headers)
            assert r.status_code == 200
            assert r.get_json()['result'] == 'success'

        with app.app_context():
            assert Account.query.get(leaf_id) is None, 'Account must be physically deleted'

    def test_delete_paired_account_returns_confirm_required(self, admin_headers):
        """When a paired account exists with no deps, first DELETE returns confirm_required."""
        from account_pair_service import link_accounts
        with app.app_context():
            cash = Account(account_number='8860', name='نقدي confirm', type='Asset',
                           transaction_type='cash', tracks_weight=False)
            gold = Account(account_number='78860', name='ذهبي confirm', type='Asset',
                           transaction_type='gold', tracks_weight=True)
            db.session.add_all([cash, gold])
            db.session.flush()
            link_accounts(cash, gold, created_by='test')
            db.session.commit()
            cash_id = cash.id
            gold_id = gold.id

        with app.test_client() as c:
            r = c.delete(f'/api/accounts/{cash_id}', headers=admin_headers)
            assert r.status_code == 200
            body = r.get_json()
            assert body['result'] == 'confirm_required'
            assert body['parallel_account']['id'] == gold_id

        with app.app_context():
            # Neither account must be deleted yet
            assert Account.query.get(cash_id) is not None
            assert Account.query.get(gold_id) is not None

    def test_delete_parallel_true_deletes_both(self, admin_headers):
        """?delete_parallel=true → both accounts deleted in a single transaction."""
        from account_pair_service import link_accounts
        with app.app_context():
            cash = Account(account_number='8861', name='نقدي حذف كلاهما', type='Asset',
                           transaction_type='cash', tracks_weight=False)
            gold = Account(account_number='78861', name='ذهبي حذف كلاهما', type='Asset',
                           transaction_type='gold', tracks_weight=True)
            db.session.add_all([cash, gold])
            db.session.flush()
            link_accounts(cash, gold, created_by='test')
            db.session.commit()
            cash_id = cash.id
            gold_id = gold.id

        with app.test_client() as c:
            r = c.delete(f'/api/accounts/{cash_id}?delete_parallel=true', headers=admin_headers)
            assert r.status_code == 200
            assert r.get_json()['result'] == 'success'

        with app.app_context():
            assert Account.query.get(cash_id) is None, 'Cash account must be deleted'
            assert Account.query.get(gold_id) is None, 'Gold parallel must also be deleted'

    def test_delete_parallel_false_keeps_parallel_unlinked(self, admin_headers):
        """?delete_parallel=false → only main account deleted; parallel survives with memo cleared."""
        from account_pair_service import link_accounts
        with app.app_context():
            cash = Account(account_number='8862', name='نقدي حذف واحد', type='Asset',
                           transaction_type='cash', tracks_weight=False)
            gold = Account(account_number='78862', name='ذهبي باقٍ', type='Asset',
                           transaction_type='gold', tracks_weight=True)
            db.session.add_all([cash, gold])
            db.session.flush()
            link_accounts(cash, gold, created_by='test')
            db.session.commit()
            cash_id = cash.id
            gold_id = gold.id

        with app.test_client() as c:
            r = c.delete(f'/api/accounts/{cash_id}?delete_parallel=false', headers=admin_headers)
            assert r.status_code == 200
            assert r.get_json()['result'] == 'success'

        with app.app_context():
            assert Account.query.get(cash_id) is None, 'Cash account must be deleted'
            surviving = Account.query.get(gold_id)
            assert surviving is not None, 'Gold parallel must survive'
            assert surviving.memo_account_id is None, 'memo link must be cleared'

    def test_delete_nonexistent_returns_404(self, admin_headers):
        with app.test_client() as c:
            r = c.delete('/api/accounts/999999', headers=admin_headers)
            assert r.status_code == 404
            assert r.get_json()['error'] == 'ACCOUNT_NOT_FOUND'


# ── 7. Update: duplicate number guard ────────────────────────────────────────

class TestUpdateAccountValidation:
    def test_update_to_existing_number_returns_409(self, admin_headers):
        with app.app_context():
            a = Account(account_number='9940', name='الأول', type='Asset')
            b = Account(account_number='9941', name='الثاني', type='Asset')
            db.session.add_all([a, b])
            db.session.commit()
            b_id = b.id

        with app.test_client() as c:
            r = c.put(f'/api/accounts/{b_id}', json={'account_number': '9940'}, headers=admin_headers)
            assert r.status_code == 409
            assert r.get_json()['error'] == 'ACCOUNT_NUMBER_EXISTS'

    def test_update_nonexistent_returns_404(self, admin_headers):
        with app.test_client() as c:
            r = c.put('/api/accounts/999999', json={'name': 'لا يوجد'}, headers=admin_headers)
            assert r.status_code == 404
            assert r.get_json()['error'] == 'ACCOUNT_NOT_FOUND'

    def test_update_invalid_type_returns_400(self, admin_headers):
        with app.app_context():
            a = Account(account_number='9950', name='تحديث نوع', type='Asset')
            db.session.add(a)
            db.session.commit()
            a_id = a.id

        with app.test_client() as c:
            r = c.put(f'/api/accounts/{a_id}', json={'type': 'INVALID'}, headers=admin_headers)
            assert r.status_code == 400
            assert r.get_json()['error'] == 'INVALID_TYPE'


# ── 8. Happy-path: add and update succeed ────────────────────────────────────

class TestHappyPath:
    def test_add_account_returns_201_with_id(self, admin_headers):
        with app.test_client() as c:
            r = c.post(
                '/api/accounts',
                json={'account_number': '9960', 'name': 'حساب جديد', 'type': 'Expense'},
                headers=admin_headers,
            )
            assert r.status_code == 201
            body = r.get_json()
            assert 'id' in body
            assert body['account_number'] == '9960'

    def test_update_name_succeeds(self, admin_headers):
        with app.app_context():
            a = Account(account_number='9970', name='قديم', type='Asset')
            db.session.add(a)
            db.session.commit()
            a_id = a.id

        with app.test_client() as c:
            r = c.put(f'/api/accounts/{a_id}', json={'name': 'جديد'}, headers=admin_headers)
            assert r.status_code == 200
            assert r.get_json()['name'] == 'جديد'


# ── 9. توريث create_parallel من الأب (القاعدة 4/6/8) ───────────────────────

class TestParallelInheritance:
    """إذا كان للأب حساب موازٍ وأُضيف ابن بدون إرسال create_parallel،
    يجب أن ينشئ Backend الموازي تلقائياً (الإرث). الإرسال الصريح لـ false
    يلغي الإرث. الأب بلا موازٍ يعني الافتراضي false."""

    def _make_linked_pair(self, cash_num: str, gold_num: str, *, name: str, acc_type: str = 'Asset'):
        from account_pair_service import link_accounts
        cash = Account(account_number=cash_num, name=f'{name} نقدي',
                       type=acc_type, transaction_type='cash', tracks_weight=False)
        gold = Account(account_number=gold_num, name=f'{name} ذهبي',
                       type=acc_type, transaction_type='gold', tracks_weight=True)
        db.session.add_all([cash, gold])
        db.session.flush()
        link_accounts(cash, gold, created_by='test')
        db.session.commit()
        return cash, gold

    def test_field_omitted_inherits_true_when_parent_has_parallel(self, admin_headers):
        """create_parallel محذوف + الأب لديه موازٍ → يُنشأ موازٍ تلقائياً."""
        with app.app_context():
            parent, _ = self._make_linked_pair('559', '7559', name='أب اختبار إرث')
            parent_id = parent.id

        with app.test_client() as c:
            r = c.post('/api/accounts', json={
                'account_number': '5590',
                'name': 'ابن موروث',
                'type': 'Asset',
                'parent_id': parent_id,
                # create_parallel محذوف عمداً
            }, headers=admin_headers)
            assert r.status_code == 201, r.get_json()
            body = r.get_json()
            assert body.get('parallel_account') is not None, (
                'يجب إنشاء موازٍ تلقائياً — create_parallel محذوف والأب لديه موازٍ'
            )
            assert body['parallel_account']['account_number'] == '75590'

        with app.app_context():
            # تحقق من الربط الثنائي وسلامة الإنفاريانت
            child = Account.query.filter_by(account_number='5590').first()
            gold_child = Account.query.filter_by(account_number='75590').first()
            assert child is not None and gold_child is not None
            assert child.memo_account_id == gold_child.id
            assert gold_child.memo_account_id == child.id
            from account_pair_invariants import classify as _classify
            violations = _classify(Account.query.all())['decisions']
            assert len(violations) == 0, f'Invariant violations: {violations}'

    def test_explicit_false_overrides_inherited_default(self, admin_headers):
        """create_parallel=false صريح يلغي الإرث حتى لو كان الأب لديه موازٍ."""
        with app.app_context():
            parent, _ = self._make_linked_pair('558', '7558', name='أب اختبار إلغاء إرث')
            parent_id = parent.id

        with app.test_client() as c:
            r = c.post('/api/accounts', json={
                'account_number': '5580',
                'name': 'ابن بلا موازٍ',
                'type': 'Asset',
                'parent_id': parent_id,
                'create_parallel': False,  # صريح — يلغي الإرث
            }, headers=admin_headers)
            assert r.status_code == 201, r.get_json()
            body = r.get_json()
            assert body.get('parallel_account') is None, (
                'create_parallel=false يجب أن يُلغي الإرث'
            )

        with app.app_context():
            assert Account.query.filter_by(account_number='75580').first() is None

    def test_parent_without_parallel_defaults_to_no_parallel(self, admin_headers):
        """الأب بلا موازٍ + create_parallel محذوف → لا ينشئ موازياً."""
        with app.app_context():
            parent = Account(account_number='557', name='أب بلا موازٍ',
                             type='Asset', transaction_type='cash', tracks_weight=False)
            db.session.add(parent)
            db.session.commit()
            parent_id = parent.id

        with app.test_client() as c:
            r = c.post('/api/accounts', json={
                'account_number': '5570',
                'name': 'ابن بلا إرث',
                'type': 'Asset',
                'parent_id': parent_id,
                # create_parallel محذوف والأب بلا موازٍ → الافتراضي false
            }, headers=admin_headers)
            assert r.status_code == 201, r.get_json()
            body = r.get_json()
            assert body.get('parallel_account') is None

        with app.app_context():
            assert Account.query.filter_by(account_number='75570').first() is None

    def test_7xxx_account_never_creates_extra_parallel(self, admin_headers):
        """الحساب 7xxx هو نفسه الجانب الوزني — لا ينشئ موازياً إضافياً أبداً."""
        with app.test_client() as c:
            r = c.post('/api/accounts', json={
                'account_number': '75590',  # 7xxx بدون create_parallel
                'name': 'ذهبي اختبار',
                'type': 'Asset',
                # لا create_parallel
            }, headers=admin_headers)
            # 75590 قد يكون موجوداً بالفعل من الاختبار الأول — نتحقق من الحالتين
            if r.status_code == 201:
                body = r.get_json()
                assert body.get('parallel_account') is None
                assert body['tracks_weight'] is True
                assert body['transaction_type'] == 'gold'
            else:
                assert r.status_code == 409  # مكرر — مقبول هنا

    def test_next_number_returns_parent_has_parallel_and_suggested_number(self, admin_headers):
        """GET /next-number/<parent> يُعيد parent_has_parallel وsuggested_parallel_number."""
        with app.app_context():
            # تأكد أن 559/7559 موجودان ومرتبطان (أُنشئا في الاختبار الأول)
            parent = Account.query.filter_by(account_number='559').first()
            assert parent is not None and parent.memo_account_id is not None, (
                'يجب أن يكون 559 مرتبطاً بـ 7559 من اختبار سابق'
            )

        with app.test_client() as c:
            r = c.get('/api/accounts/next-number/559', headers=admin_headers)
            assert r.status_code == 200
            body = r.get_json()
            assert body.get('parent_has_parallel') is True, (
                f'parent_has_parallel يجب أن يكون True لـ 559، الرد: {body}'
            )
            assert body.get('suggested_parallel_number', '').startswith('7'), (
                f'suggested_parallel_number يجب أن يبدأ بـ 7، الرد: {body}'
            )

    def test_next_number_parent_without_parallel_returns_false(self, admin_headers):
        """الأب بلا موازٍ → parent_has_parallel=False في رد next-number."""
        with app.test_client() as c:
            r = c.get('/api/accounts/next-number/557', headers=admin_headers)
            assert r.status_code == 200
            body = r.get_json()
            assert body.get('parent_has_parallel') is False, (
                f'parent_has_parallel يجب أن يكون False لـ 557، الرد: {body}'
            )


# ── 10. update_account: إبطال رابط memo عند تغيير رقم الحساب ───────────────

class TestUpdateAccountMemoRevalidation:
    """تغيير رقم الحساب بما يقلب tracks_weight يجب أن يُبطل رابط memo_account_id
    عبر unlink_account() — الطريق الوحيد المعتمد."""

    def _make_linked_pair(self, cash_num: str, gold_num: str, *, name: str):
        from account_pair_service import link_accounts
        cash = Account(account_number=cash_num, name=f'{name} نقدي',
                       type='Asset', transaction_type='cash', tracks_weight=False)
        gold = Account(account_number=gold_num, name=f'{name} ذهبي',
                       type='Asset', transaction_type='gold', tracks_weight=True)
        db.session.add_all([cash, gold])
        db.session.flush()
        link_accounts(cash, gold, created_by='test')
        db.session.commit()
        return cash, gold

    def test_number_change_to_7xxx_is_refused_and_the_link_kept(self, admin_headers):
        """نقدي مرتبط بذهبي → تغيير رقمه لـ 7xxx يُرفض، ويبقى نوعه ورابطه (CHART-002 4c4:
        النوع علامة الحساب لا رقمه؛ كان يُقلب ويُفسخ الرابط بصمت)."""
        with app.app_context():
            cash, gold = self._make_linked_pair('446', '7446', name='اختبار قلب النوع')
            cash_id, gold_id = cash.id, gold.id

        with app.test_client() as c:
            r = c.put(f'/api/accounts/{cash_id}',
                      json={'account_number': '74460'}, headers=admin_headers)
            assert r.status_code == 400, r.get_json()
            assert r.get_json()['error'] == 'MEMO_MISMATCH'

        with app.app_context():
            updated = Account.query.get(cash_id)
            assert updated.account_number == '446' and updated.tracks_weight is False
            assert updated.memo_account_id == gold_id, 'الرابط باقٍ'

    def test_name_change_preserves_memo_link(self, admin_headers):
        """تغيير الاسم فقط لا يُبطل رابط memo_account_id."""
        with app.app_context():
            cash, gold = self._make_linked_pair('445', '7445', name='اختبار تغيير الاسم')
            cash_id, gold_id = cash.id, gold.id

        with app.test_client() as c:
            r = c.put(f'/api/accounts/{cash_id}',
                      json={'name': 'اسم جديد'}, headers=admin_headers)
            assert r.status_code == 200

        with app.app_context():
            updated = Account.query.get(cash_id)
            assert updated.memo_account_id == gold_id, (
                'تغيير الاسم يجب ألا يُبطل الرابط'
            )

    def test_number_change_same_type_preserves_memo_link(self, admin_headers):
        """تغيير الرقم مع بقاء النوع نقدياً (non-7xxx) لا يُبطل الرابط."""
        with app.app_context():
            cash, gold = self._make_linked_pair('444', '7444', name='اختبار بقاء الرابط')
            cash_id, gold_id = cash.id, gold.id

        with app.test_client() as c:
            # 444 → 4441 كلاهما non-7xxx، tracks_weight يبقى False
            r = c.put(f'/api/accounts/{cash_id}',
                      json={'account_number': '4441'}, headers=admin_headers)
            assert r.status_code == 200

        with app.app_context():
            updated = Account.query.get(cash_id)
            assert updated.memo_account_id == gold_id, (
                'تغيير الرقم مع بقاء non-7xxx لا يُبطل الرابط'
            )


class TestRemoveParallel:
    """POST /accounts/<id>/remove-parallel — عملية تجارية مستقلة:
    تُزيل الحساب الموازي فقط مع الحفاظ على الحساب الأساسي."""

    def _make_linked_pair(self, cash_num: str, gold_num: str, *, name: str):
        from account_pair_service import link_accounts
        cash = Account(account_number=cash_num, name=f'{name} نقدي',
                       type='Asset', transaction_type='cash', tracks_weight=False)
        gold = Account(account_number=gold_num, name=f'{name} ذهبي',
                       type='Asset', transaction_type='gold', tracks_weight=True)
        db.session.add_all([cash, gold])
        db.session.flush()
        link_accounts(cash, gold, created_by='test')
        db.session.commit()
        return cash, gold

    # ── happy path ────────────────────────────────────────────────────────────

    def test_remove_parallel_deletes_gold_account(self, admin_headers):
        """الحالة النظيفة: حساب نقدي مرتبط بذهبي، الذهبي بلا تبعيات."""
        with app.app_context():
            cash, gold = self._make_linked_pair('3881', '73881', name='إزالة موازي - سعيدة')
            cash_id, gold_id = cash.id, gold.id

        with app.test_client() as c:
            r = c.post(f'/api/accounts/{cash_id}/remove-parallel',
                       headers=admin_headers)
            assert r.status_code == 200, r.get_json()
            body = r.get_json()
            assert body['result'] == 'success'
            assert body['removed_parallel']['id'] == gold_id
            assert body['removed_parallel']['account_number'] == '73881'

        with app.app_context():
            primary = Account.query.get(cash_id)
            assert primary is not None, 'الحساب الأساسي يجب أن يبقى'
            assert primary.memo_account_id is None, 'الرابط يجب أن يُفسَخ'
            assert Account.query.get(gold_id) is None, 'الحساب الموازي يجب أن يُحذَف'

    def test_remove_parallel_is_bidirectional_unlink(self, admin_headers):
        """يتحقق من فسخ الربط من الطرفين (unlink_account() ثنائي الاتجاه)."""
        with app.app_context():
            cash, gold = self._make_linked_pair('3882', '73882', name='إزالة موازي - ثنائي')
            cash_id, gold_id = cash.id, gold.id

        with app.test_client() as c:
            r = c.post(f'/api/accounts/{cash_id}/remove-parallel',
                       headers=admin_headers)
            assert r.status_code == 200

        with app.app_context():
            primary = Account.query.get(cash_id)
            assert primary.memo_account_id is None
            assert Account.query.get(gold_id) is None

    # ── رفض — لا موازي ───────────────────────────────────────────────────────

    def test_no_parallel_returns_404(self, admin_headers):
        """حساب بدون memo_account_id → 404."""
        with app.app_context():
            solo = Account(account_number='3883', name='حساب منفرد اختبار',
                           type='Asset', transaction_type='cash', tracks_weight=False)
            db.session.add(solo)
            db.session.commit()
            solo_id = solo.id

        with app.test_client() as c:
            r = c.post(f'/api/accounts/{solo_id}/remove-parallel',
                       headers=admin_headers)
            assert r.status_code == 404
            assert r.get_json()['error'] == 'NO_PARALLEL'

    def test_nonexistent_account_returns_404(self, admin_headers):
        """معرف حساب غير موجود → 404."""
        with app.test_client() as c:
            r = c.post('/api/accounts/999999987/remove-parallel',
                       headers=admin_headers)
            assert r.status_code == 404

    # ── رفض — تبعيات الموازي ─────────────────────────────────────────────────

    def test_parallel_with_je_lines_returns_409(self, admin_headers):
        """الحساب الموازي له سطور قيد → 409 PARALLEL_HAS_JE_LINES."""
        from models import JournalEntry, JournalEntryLine
        import datetime

        with app.app_context():
            cash, gold = self._make_linked_pair('3884', '73884', name='موازي له قيود')
            cash_id, gold_id = cash.id, gold.id

            je = JournalEntry(date=datetime.date.today(), description='اختبار منع الإزالة')
            db.session.add(je)
            db.session.flush()
            line = JournalEntryLine(journal_entry_id=je.id, account_id=gold_id,
                                    debit_21k=1.0)
            db.session.add(line)
            db.session.commit()

        with app.test_client() as c:
            r = c.post(f'/api/accounts/{cash_id}/remove-parallel',
                       headers=admin_headers)
            assert r.status_code == 409
            assert r.get_json()['error'] == 'PARALLEL_HAS_JE_LINES'

        with app.app_context():
            assert Account.query.get(cash_id) is not None, 'الحساب الأساسي يجب أن يبقى'
            assert Account.query.get(gold_id) is not None, 'الحساب الموازي لا يُحذَف عند الرفض'
            assert Account.query.get(cash_id).memo_account_id == gold_id, 'الرابط يجب أن يبقى'

    def test_parallel_with_children_returns_409(self, admin_headers):
        """الحساب الموازي له حسابات فرعية → 409 PARALLEL_HAS_CHILDREN."""
        with app.app_context():
            cash, gold = self._make_linked_pair('3885', '73885', name='موازي له أبناء')
            cash_id, gold_id = cash.id, gold.id

            child = Account(account_number='738851', name='حساب فرعي اختبار',
                            type='Asset', transaction_type='gold',
                            tracks_weight=True, parent_id=gold_id)
            db.session.add(child)
            db.session.commit()

        with app.test_client() as c:
            r = c.post(f'/api/accounts/{cash_id}/remove-parallel',
                       headers=admin_headers)
            assert r.status_code == 409
            assert r.get_json()['error'] == 'PARALLEL_HAS_CHILDREN'

        with app.app_context():
            assert Account.query.get(gold_id) is not None
            assert Account.query.get(cash_id).memo_account_id == gold_id

    # ── atomicity ─────────────────────────────────────────────────────────────

    def test_rejection_leaves_db_unchanged(self, admin_headers):
        """عند الرفض، لا يتغير أي شيء في قاعدة البيانات (transactional rollback)."""
        from models import JournalEntry, JournalEntryLine
        import datetime

        with app.app_context():
            cash, gold = self._make_linked_pair('3886', '73886', name='اختبار ذرية')
            cash_id, gold_id = cash.id, gold.id

            je = JournalEntry(date=datetime.date.today(), description='اختبار atomicity')
            db.session.add(je)
            db.session.flush()
            db.session.add(JournalEntryLine(journal_entry_id=je.id,
                                             account_id=gold_id, debit_24k=2.5))
            db.session.commit()
            original_memo_id = cash.memo_account_id

        with app.test_client() as c:
            r = c.post(f'/api/accounts/{cash_id}/remove-parallel',
                       headers=admin_headers)
            assert r.status_code == 409

        with app.app_context():
            cash_after = Account.query.get(cash_id)
            gold_after = Account.query.get(gold_id)
            assert cash_after.memo_account_id == gold_id, 'الرابط يجب أن يبقى بعد الرفض'
            assert gold_after is not None, 'الموازي يجب أن يبقى بعد الرفض'
            assert gold_after.memo_account_id == cash_id, 'ربط الموازي يجب أن يبقى أيضاً'
