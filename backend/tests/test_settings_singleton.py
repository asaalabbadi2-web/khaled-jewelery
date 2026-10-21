import json

from app import app
from models import db, Settings

import pytest

@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield



def _clear_settings_rows():
    Settings.query.delete()
    db.session.commit()


def test_settings_put_accepts_sales_race_settings_as_json_string(auth_headers):
    with app.app_context():
        _clear_settings_rows()

    payload = {
        'sales_race_settings': json.dumps(
            {
                'enabled': True,
                'default_period': 'today',
                'show_sales_amount_per_employee': True,
            },
            ensure_ascii=False,
        )
    }

    with app.test_client() as client:
        response = client.put('/api/settings', headers=auth_headers, json=payload)
        assert response.status_code == 200
        data = response.get_json()
        assert isinstance(data, dict)
        assert data['sales_race_settings']['show_sales_amount_per_employee'] is True

    with app.app_context():
        row = Settings.query.order_by(Settings.id.desc()).first()
        assert row is not None
        assert row.sales_race_settings is not None
        decoded = json.loads(row.sales_race_settings)
        assert decoded.get('show_sales_amount_per_employee') is True


def test_settings_singleton_dedupes_multiple_rows_deterministically(auth_headers):
    with app.app_context():
        _clear_settings_rows()
        s1 = Settings(main_karat=21)
        s2 = Settings(main_karat=22)
        db.session.add_all([s1, s2])
        db.session.commit()
        assert Settings.query.count() == 2

    with app.test_client() as client:
        response = client.get('/api/settings', headers=auth_headers)
        assert response.status_code == 200
        data = response.get_json()
        assert data['main_karat'] == 22

    with app.app_context():
        assert Settings.query.count() == 1
        remaining = Settings.query.first()
        assert remaining is not None
        assert remaining.main_karat == 22


def test_sales_race_full_round_trip(auth_headers):
    """Simulate exactly what Flutter does: PUT all settings → GET → verify."""
    with app.app_context():
        _clear_settings_rows()

    # Mimic _saveSettings() payload from Flutter
    save_payload = {
        'main_karat': 21,
        'currency_symbol': 'ر.س',
        'decimal_places': 2,
        'date_format': 'DD/MM/YYYY',
        'tax_enabled': True,
        'tax_rate': 0.15,
        'allow_discount': True,
        'default_discount_rate': 0.0,
        'voucher_auto_post': False,
        'weekly_sales_target_weight': 100.0,
        'sales_race_settings': {
            'enabled': False,
            'default_period': 'week',
            'points_per_gram': 5.0,
            'allow_fallback_to_latest_period': False,
            'show_invoice_count': False,
            'show_sales_amount_per_employee': True,
            'show_champion': False,
            'show_total_cash_to_all_users': False,
            'show_total_profit_to_all_users': True,
        },
    }

    with app.test_client() as client:
        # PUT (save)
        put_resp = client.put('/api/settings', headers=auth_headers, json=save_payload)
        assert put_resp.status_code == 200
        put_data = put_resp.get_json()

        # Verify PUT response contains what we saved
        assert put_data['weekly_sales_target_weight'] == 100.0
        race = put_data['sales_race_settings']
        assert race['enabled'] is False
        assert race['default_period'] == 'week'
        assert race['points_per_gram'] == 5.0
        assert race['show_sales_amount_per_employee'] is True
        assert race['show_champion'] is False
        assert race['show_total_profit_to_all_users'] is True

        # GET (reload — simulates reopening settings screen)
        get_resp = client.get('/api/settings', headers=auth_headers)
        assert get_resp.status_code == 200
        get_data = get_resp.get_json()

        # Verify GET returns same values (NOT defaults)
        assert get_data['weekly_sales_target_weight'] == 100.0
        race2 = get_data['sales_race_settings']
        assert race2['enabled'] is False, \
            f"Expected enabled=False, got {race2['enabled']}"
        assert race2['default_period'] == 'week', \
            f"Expected default_period='week', got {race2['default_period']}"
        assert race2['points_per_gram'] == 5.0, \
            f"Expected points_per_gram=5.0, got {race2['points_per_gram']}"
        assert race2['allow_fallback_to_latest_period'] is False
        assert race2['show_invoice_count'] is False
        assert race2['show_sales_amount_per_employee'] is True
        assert race2['show_champion'] is False
        assert race2['show_total_cash_to_all_users'] is False
        assert race2['show_total_profit_to_all_users'] is True

    # Also verify the DB directly
    with app.app_context():
        row = Settings.query.first()
        assert row is not None
        assert row.weekly_sales_target_weight == 100.0
        raw = json.loads(row.sales_race_settings)
        assert raw['enabled'] is False
        assert raw['show_sales_amount_per_employee'] is True


def test_sales_race_partial_update_preserves_other_fields(auth_headers):
    """Updating one setting must NOT reset sales_race_settings."""
    with app.app_context():
        _clear_settings_rows()

    with app.test_client() as client:
        # First: set sales race
        client.put('/api/settings', headers=auth_headers, json={
            'sales_race_settings': {
                'enabled': False,
                'points_per_gram': 7.0,
            },
            'weekly_sales_target_weight': 500.0,
        })

        # Second: update unrelated setting (like from posting_management_screen)
        client.put('/api/settings', headers=auth_headers, json={
            'auto_post_invoices': True,
        })

        # Third: GET and verify race settings still intact
        get_resp = client.get('/api/settings', headers=auth_headers)
        data = get_resp.get_json()
        race = data['sales_race_settings']
        assert race['enabled'] is False, \
            f"Race enabled was reset! Got {race['enabled']}"
        assert race['points_per_gram'] == 7.0, \
            f"points_per_gram was reset! Got {race['points_per_gram']}"
        assert data['weekly_sales_target_weight'] == 500.0, \
            f"weekly target was reset! Got {data['weekly_sales_target_weight']}"


def test_settings_rejects_unknown_keys_instead_of_silent_drop(auth_headers):
    with app.app_context():
        _clear_settings_rows()

    with app.test_client() as client:
        resp = client.put('/api/settings', headers=auth_headers, json={
            'sales_race_settings': {'enabled': True},
            'unknown_new_toggle': True,
        })
        assert resp.status_code == 400
        body = resp.get_json()
        assert body['error'] == 'unknown_settings_keys'
        assert 'unknown_new_toggle' in body.get('unknown_keys', [])


def test_settings_get_serializes_vat_exempt_karats_defensively(auth_headers):
    with app.app_context():
        _clear_settings_rows()
        row = Settings(main_karat=21)
        row.vat_exempt_karats = json.dumps([24, '21', 'bad', 18], ensure_ascii=False)
        db.session.add(row)
        db.session.commit()

    with app.test_client() as client:
        resp = client.get('/api/settings', headers=auth_headers)
        assert resp.status_code == 200
        data = resp.get_json()
        assert data['vat_exempt_karats'] == ['18', '21', '24']
