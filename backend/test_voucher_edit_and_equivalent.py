from datetime import datetime

from app import app
from models import Account, Voucher, VoucherAccountLine, db
from routes import generate_voucher_number, update_voucher



def _sign_in_as_system_admin():
    """The route is called directly; since ADR-036 it asks who calls (vouchers.edit / vouchers.approve)."""
    from flask import g
    from models import AppUser
    g.current_user = AppUser.query.filter_by(role='system_admin').first() or AppUser(
        username='pytest-admin', role='system_admin', is_active=True, password_hash='x')

def _ensure_account(account_number: str, name: str, *, transaction_type='both', tracks_weight=False):
    account = Account.query.filter_by(account_number=account_number).first()
    if account:
        return account

    account = Account(
        account_number=account_number,
        name=name,
        type='Asset',
        transaction_type=transaction_type,
        tracks_weight=tracks_weight,
    )
    db.session.add(account)
    db.session.flush()
    return account


def test_voucher_to_dict_reports_main_karat_equivalent_for_multi_karat_gold():
    with app.app_context():
        debit_gold = _ensure_account('1300', 'خزنة ذهب اختبار', transaction_type='gold', tracks_weight=True)
        credit_gold = _ensure_account('1301', 'مقابل ذهب اختبار', transaction_type='gold', tracks_weight=True)

        voucher = Voucher(
            voucher_number=generate_voucher_number('receipt'),
            voucher_type='receipt',
            date=datetime.now(),
            party_type='other',
            party_name='طرف متعدد العيارات',
            amount_cash=0.0,
            amount_gold=3.0,
            description='اختبار وزن مكافئ',
            created_by='pytest',
            status='pending',
        )
        db.session.add(voucher)
        db.session.flush()

        db.session.add_all([
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=debit_gold.id,
                line_type='debit',
                amount_type='gold',
                amount=2.0,
                karat=24,
            ),
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=debit_gold.id,
                line_type='debit',
                amount_type='gold',
                amount=1.0,
                karat=18,
            ),
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=credit_gold.id,
                line_type='credit',
                amount_type='gold',
                amount=2.0,
                karat=24,
            ),
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=credit_gold.id,
                line_type='credit',
                amount_type='gold',
                amount=1.0,
                karat=18,
            ),
        ])
        db.session.commit()

        payload = voucher.to_dict()

        assert payload['gold_karat'] == 'متعدد'
        assert payload['amount_gold'] == 3.0
        assert payload['main_karat'] == 21.0
        assert payload['amount_gold_main_karat'] == 3.142857
        assert payload['gold_breakdown'] == [
            {'karat': 18.0, 'weight': 1.0, 'weight_main_karat': 0.857143},
            {'karat': 24.0, 'weight': 2.0, 'weight_main_karat': 2.285714},
        ]


def test_update_voucher_replaces_lines_and_recomputes_totals():
    with app.app_context():
        cash_debit = _ensure_account('1510', 'صندوق اختبار 1')
        cash_credit = _ensure_account('1511', 'صندوق اختبار 2')
        gold_debit = _ensure_account('1310', 'ذهب اختبار 1', transaction_type='gold', tracks_weight=True)
        gold_credit = _ensure_account('1311', 'ذهب اختبار 2', transaction_type='gold', tracks_weight=True)

        voucher = Voucher(
            voucher_number=generate_voucher_number('payment'),
            voucher_type='payment',
            date=datetime.now(),
            party_type='other',
            party_name='طرف تعديل',
            amount_cash=100.0,
            amount_gold=1.0,
            description='قبل التعديل',
            created_by='pytest',
            status='pending',
        )
        db.session.add(voucher)
        db.session.flush()

        db.session.add_all([
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=cash_debit.id,
                line_type='debit',
                amount_type='cash',
                amount=100.0,
            ),
            VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=cash_credit.id,
                line_type='credit',
                amount_type='cash',
                amount=100.0,
            ),
        ])
        db.session.commit()

        payload = {
            'voucher_type': 'payment',
            'date': datetime.now().date().isoformat(),
            'party_type': 'other',
            'party_name': 'طرف بعد التعديل',
            'description': 'بعد التعديل',
            'notes': 'اختبار تحديث السند',
            'account_lines': [
                {
                    'account_id': cash_debit.id,
                    'line_type': 'debit',
                    'amount_type': 'cash',
                    'amount': 250.0,
                    'description': 'نقد مدين',
                },
                {
                    'account_id': cash_credit.id,
                    'line_type': 'credit',
                    'amount_type': 'cash',
                    'amount': 250.0,
                    'description': 'نقد دائن',
                },
                {
                    'account_id': gold_debit.id,
                    'line_type': 'debit',
                    'amount_type': 'gold',
                    'amount': 2.0,
                    'karat': 24,
                    'description': 'ذهب مدين',
                },
                {
                    'account_id': gold_credit.id,
                    'line_type': 'credit',
                    'amount_type': 'gold',
                    'amount': 2.0,
                    'karat': 24,
                    'description': 'ذهب دائن',
                },
            ],
        }

        with app.test_request_context(json=payload):

            _sign_in_as_system_admin()
            response = update_voucher(voucher.id)

        if isinstance(response, tuple):
            flask_response, status_code = response
        else:
            flask_response, status_code = response, response.status_code

        assert status_code == 200

        db.session.refresh(voucher)
        lines = voucher.account_lines.order_by(VoucherAccountLine.id.asc()).all()
        assert len(lines) == 4
        assert voucher.party_name == 'طرف بعد التعديل'
        assert voucher.description == 'بعد التعديل'
        assert voucher.notes == 'اختبار تحديث السند'
        assert voucher.amount_cash == 250.0
        assert voucher.amount_gold == 2.0

        response_payload = flask_response.get_json()
        assert response_payload['amount_gold_main_karat'] == 2.285714
        assert response_payload['gold_breakdown'] == [
            {'karat': 24.0, 'weight': 2.0, 'weight_main_karat': 2.285714},
        ]


def test_update_voucher_persists_receiver_and_weight_details():
    with app.app_context():
        gold_credit = _ensure_account('1320', 'ذهب طباعة', transaction_type='gold', tracks_weight=True)
        gold_debit = _ensure_account('1321', 'مقابل ذهب طباعة', transaction_type='gold', tracks_weight=True)

        voucher = Voucher(
            voucher_number=generate_voucher_number('payment'),
            voucher_type='payment',
            date=datetime.now(),
            party_type='other',
            party_name='طرف طباعة',
            amount_cash=0.0,
            amount_gold=1.0,
            description='قبل حفظ التفاصيل',
            created_by='pytest',
            status='pending',
        )
        db.session.add(voucher)
        db.session.flush()

        payload = {
            'voucher_type': 'payment',
            'date': datetime.now().date().isoformat(),
            'party_type': 'other',
            'party_name': 'طرف طباعة',
            'description': 'سند صرف مع تفاصيل وزن',
            'receiver_name': 'أحمد محمد',
            'account_lines': [
                {
                    'account_id': gold_credit.id,
                    'line_type': 'credit',
                    'amount_type': 'gold',
                    'amount': 9.5,
                    'karat': 21,
                    'gross_weight': 10.2,
                    'net_weight': 9.5,
                    'stones_weight': 0.7,
                    'description': 'ذهب منصرف',
                },
                {
                    'account_id': gold_debit.id,
                    'line_type': 'debit',
                    'amount_type': 'gold',
                    'amount': 9.5,
                    'karat': 21,
                    'gross_weight': 10.2,
                    'net_weight': 9.5,
                    'stones_weight': 0.7,
                    'description': 'مقابل ذهب منصرف',
                },
            ],
        }

        with app.test_request_context(json=payload):

            _sign_in_as_system_admin()
            response = update_voucher(voucher.id)

        if isinstance(response, tuple):
            flask_response, status_code = response
        else:
            flask_response, status_code = response, response.status_code

        assert status_code == 200

        db.session.refresh(voucher)
        lines = voucher.account_lines.order_by(VoucherAccountLine.id.asc()).all()
        assert voucher.receiver_name == 'أحمد محمد'
        assert len(lines) == 2
        assert lines[0].gross_weight == 10.2
        assert lines[0].net_weight == 9.5
        assert lines[0].stones_weight == 0.7

        response_payload = flask_response.get_json()
        assert response_payload['receiver_name'] == 'أحمد محمد'
        assert response_payload['gross_weight'] == 20.4
        assert response_payload['net_weight'] == 19.0
        assert response_payload['stones_weight'] == 1.4
        assert response_payload['account_lines'][0]['gross_weight'] == 10.2
        assert response_payload['account_lines'][0]['net_weight'] == 9.5
        assert response_payload['account_lines'][0]['stones_weight'] == 0.7


def test_update_voucher_rejects_unknown_top_level_keys():
    with app.app_context():
        cash_debit = _ensure_account('1520', 'صندوق تحقق مفاتيح')
        cash_credit = _ensure_account('1521', 'مقابل تحقق مفاتيح')

        voucher = Voucher(
            voucher_number=generate_voucher_number('payment'),
            voucher_type='payment',
            date=datetime.now(),
            party_type='other',
            party_name='طرف تحقق',
            amount_cash=50.0,
            amount_gold=0.0,
            description='اختبار مفاتيح غير معروفة',
            created_by='pytest',
            status='pending',
        )
        db.session.add(voucher)
        db.session.flush()

        payload = {
            'voucher_type': 'payment',
            'date': datetime.now().date().isoformat(),
            'party_type': 'other',
            'party_name': 'طرف تحقق',
            'unexpected_flag': True,
            'account_lines': [
                {
                    'account_id': cash_debit.id,
                    'line_type': 'debit',
                    'amount_type': 'cash',
                    'amount': 50.0,
                },
                {
                    'account_id': cash_credit.id,
                    'line_type': 'credit',
                    'amount_type': 'cash',
                    'amount': 50.0,
                },
            ],
        }

        with app.test_request_context(json=payload):

            _sign_in_as_system_admin()
            response = update_voucher(voucher.id)

        if isinstance(response, tuple):
            flask_response, status_code = response
        else:
            flask_response, status_code = response, response.status_code

        assert status_code == 400
        assert flask_response.get_json()['error'] == 'unknown_voucher_keys'