"""System domain routes — system_bp registered under /api in app.py.

Covers: debug, weight-closing settings/profiles, system-alerts, settings,
        system-reset, backup, statements/qr-sign, rebuild-account-balances,
        add-bank-info, app-config, melting-renewal.
"""
from __future__ import annotations

import hashlib
import hmac
import io
import json
import logging
import os
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import zipfile
from datetime import datetime

from flask import Blueprint, current_app, g, jsonify, request, send_file
from sqlalchemy import func
from sqlalchemy.orm import joinedload

from models import (
    db,
    Account,
    AccountingMapping,
    Attendance,
    AuditLog,
    BonusInvoiceLink,
    BonusRule,
    Customer,
    Employee,
    EmployeeBonus,
    GoalAchievement,
    Invoice,
    InvoiceItem,
    InvoiceKaratLine,
    InvoicePayment,
    JournalEntry,
    JournalEntryLine,
    Office,
    OfficeReservation,
    Payroll,
    SafeBox,
    SafeBoxTransaction,
    PaymentMethod,
    Settings,
    SettlementLine,
    Supplier,
    SupplierGoldTransaction,
    User,
    Voucher,
    VoucherAccountLine,
    WeightClosingExecution,
    WeightClosingOrder,
)

from core.database import _db_has_column
from core.number_helpers import _coerce_float
from core.responses import _wrap_api_exceptions
from auth_decorators import require_permission, require_any_permission

from services.weight_execution import list_weight_profiles

from pricing.karat_service import get_main_karat
from accounting.voucher_engine import (
    create_journal_entry_from_voucher,
    generate_voucher_number,
)
from accounting.statement_verification import _sign_qr_payload
from accounting.weight_closing import _load_weight_closing_settings
from core.settings import _get_settings_singleton
from accounting.balances import _recalculate_account_balances_for_accounts
from routes import (
    _normalize_account_ref,
    _normalize_fk_ref,
    ensure_weight_closing_support_accounts,
    _try_process_due_auto_clearing_settlements,
    _get_manufacturing_wage_inventory_account_id,
    _repair_inventory_wage_memo_links,
)

system_bp = Blueprint('system', __name__)

def _is_production_env() -> bool:
    env = (
        (os.getenv('YASAR_ENV') or '').strip().lower()
        or (os.getenv('APP_ENV') or '').strip().lower()
        or (os.getenv('ENV') or '').strip().lower()
        or (os.getenv('FLASK_ENV') or '').strip().lower()
    )
    return env in ('prod', 'production')

@system_bp.route('/debug/db-info', methods=['GET'])
def debug_db_info():
    """Debug-only helper to confirm which DB the running backend is using.

    This is intentionally restricted in production.
    """
    if _is_production_env():
        return jsonify({'error': 'not_found'}), 404

    try:
        configured_uri = current_app.config.get('SQLALCHEMY_DATABASE_URI')
    except Exception:
        configured_uri = None

    try:
        engine_url = str(db.engine.url)
    except Exception:
        engine_url = None

    return jsonify(
        {
            'sqlalchemy_database_uri': configured_uri,
            'engine_url': engine_url,
            'is_sqlite': _is_sqlite_database(),
            'sqlite_path': _sqlite_db_path(),
        }
    )

def _is_sqlite_database() -> bool:
    try:
        return (db.engine.url.get_backend_name() or '').lower().startswith('sqlite')
    except Exception:
        return False

def _is_postgres_database() -> bool:
    try:
        name = (db.engine.url.get_backend_name() or '').lower()
        return name in {'postgresql', 'postgres'}
    except Exception:
        return False

def _sqlite_db_path() -> str | None:
    try:
        if not _is_sqlite_database():
            return None
        path = db.engine.url.database
        if not path:
            return None
        # SQLAlchemy may give relative paths; resolve relative to backend cwd.
        return os.path.abspath(path)
    except Exception:
        return None

def _settings_diag_headers(settings_row: Settings | None) -> dict[str, str]:
    """Return lightweight diagnostics to debug production save/read mismatches.

    These headers help detect traffic hitting different instances or databases.
    """
    try:
        configured_uri = current_app.config.get('SQLALCHEMY_DATABASE_URI')
    except Exception:
        configured_uri = None

    uri_text = str(configured_uri or '')
    db_fingerprint = hashlib.sha1(uri_text.encode('utf-8')).hexdigest()[:12] if uri_text else 'none'

    try:
        backend_name = (db.engine.url.get_backend_name() or '').lower() or 'unknown'
    except Exception:
        backend_name = 'unknown'

    instance_id = (os.getenv('HOSTNAME') or '').strip() or socket.gethostname() or 'unknown'
    row_id = str(getattr(settings_row, 'id', '') or '')

    return {
        'X-Yasar-Instance-Id': instance_id,
        'X-Yasar-DB-Backend': backend_name,
        'X-Yasar-DB-Fingerprint': db_fingerprint,
        'X-Yasar-Settings-Row-Id': row_id,
    }

def _create_sqlite_backup_to_file(dest_path: str) -> None:
    src_path = _sqlite_db_path()
    if not src_path or not os.path.exists(src_path):
        raise FileNotFoundError('SQLite database file not found')

    # Make sure SQLAlchemy releases file locks.
    try:
        db.session.remove()
    except Exception:
        pass
    try:
        db.engine.dispose()
    except Exception:
        pass

    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    # Use SQLite native backup API (safe while DB is in use).
    src = sqlite3.connect(src_path)
    try:
        dst = sqlite3.connect(dest_path)
        try:
            src.backup(dst)
            dst.commit()
        finally:
            dst.close()
    finally:
        src.close()

def _pg_tools_available() -> tuple[bool, list[str]]:
    missing: list[str] = []
    for tool in ('pg_dump', 'pg_restore', 'psql'):
        if shutil.which(tool) is None:
            missing.append(tool)
    return (len(missing) == 0, missing)

def _postgres_conn_parts() -> dict:
    url = db.engine.url
    return {
        'host': url.host,
        'port': url.port,
        'user': url.username,
        'password': url.password,
        'database': url.database,
    }

def _create_postgres_backup_to_file(dest_path: str) -> None:
    if not _is_postgres_database():
        raise RuntimeError('PostgreSQL backend is not active')

    ok, missing = _pg_tools_available()
    if not ok:
        raise RuntimeError(f"PostgreSQL tools missing: {', '.join(missing)}")

    parts = _postgres_conn_parts()
    if not parts.get('database'):
        raise RuntimeError('PostgreSQL database name is missing')

    os.makedirs(os.path.dirname(dest_path), exist_ok=True)

    env = os.environ.copy()
    if parts.get('password'):
        env['PGPASSWORD'] = str(parts['password'])

    cmd = ['pg_dump', '-Fc', '-f', dest_path]
    if parts.get('host'):
        cmd += ['-h', str(parts['host'])]
    if parts.get('port'):
        cmd += ['-p', str(parts['port'])]
    if parts.get('user'):
        cmd += ['-U', str(parts['user'])]
    cmd.append(str(parts['database']))

    try:
        subprocess.run(cmd, check=True, env=env, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or '').strip()
        raise RuntimeError(
            'فشل إنشاء نسخة PostgreSQL عبر pg_dump.'
            + (f" التفاصيل: {stderr}" if stderr else '')
        ) from exc

def _run_postgres_psql_command(
    parts: dict,
    env: dict,
    *,
    sql: str | None = None,
    file_path: str | None = None,
) -> None:
    cmd = ['psql']
    if parts.get('host'):
        cmd += ['-h', str(parts['host'])]
    if parts.get('port'):
        cmd += ['-p', str(parts['port'])]
    if parts.get('user'):
        cmd += ['-U', str(parts['user'])]
    cmd += ['-d', str(parts['database']), '-v', 'ON_ERROR_STOP=1']

    if sql is not None:
        cmd += ['-c', sql]
    elif file_path is not None:
        cmd += ['-f', file_path]
    else:
        raise ValueError('Either sql or file_path must be provided')

    try:
        subprocess.run(cmd, check=True, env=env, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or '').strip()
        action = 'أمر PostgreSQL' if sql is not None else 'استعادة PostgreSQL عبر psql'
        raise RuntimeError(
            f'{action} فشل.' + (f" التفاصيل: {stderr}" if stderr else '')
        ) from exc

def _terminate_postgres_connections(parts: dict, env: dict) -> None:
    database_name = str(parts.get('database') or '').strip()
    if not database_name:
        raise RuntimeError('PostgreSQL database name is missing')

    safe_database_name = database_name.replace("'", "''")
    sql = (
        "SELECT pg_terminate_backend(pid) "
        "FROM pg_stat_activity "
        f"WHERE datname = '{safe_database_name}' AND pid <> pg_backend_pid();"
    )
    _run_postgres_psql_command(parts, env, sql=sql)

def _restore_postgres_from_backup_file(src_backup_path: str) -> None:
    if not _is_postgres_database():
        raise RuntimeError('PostgreSQL backend is not active')
    if not os.path.exists(src_backup_path):
        raise FileNotFoundError('Backup file not found')

    ok, missing = _pg_tools_available()
    if not ok:
        raise RuntimeError(f"PostgreSQL tools missing: {', '.join(missing)}")

    # Ensure we drop connections before restoring.
    try:
        db.session.remove()
    except Exception:
        pass
    try:
        db.engine.dispose()
    except Exception:
        pass

    parts = _postgres_conn_parts()
    if not parts.get('database'):
        raise RuntimeError('PostgreSQL database name is missing')

    env = os.environ.copy()
    if parts.get('password'):
        env['PGPASSWORD'] = str(parts['password'])

    _terminate_postgres_connections(parts, env)

    ext = os.path.splitext(src_backup_path)[1].lower()

    def _run_psql() -> None:
        _run_postgres_psql_command(parts, env, file_path=src_backup_path)

    if ext in {'.sql'}:
        _run_psql()
        return

    # Prefer pg_restore (custom format from pg_dump -Fc)
    cmd = ['pg_restore', '--clean', '--if-exists', '--no-owner', '--no-privileges']
    if parts.get('host'):
        cmd += ['-h', str(parts['host'])]
    if parts.get('port'):
        cmd += ['-p', str(parts['port'])]
    if parts.get('user'):
        cmd += ['-U', str(parts['user'])]
    cmd += ['-d', str(parts['database']), src_backup_path]

    try:
        subprocess.run(cmd, check=True, env=env, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or '').strip()

        # Common case: a plain SQL dump was uploaded but named .dump/.backup.
        # pg_restore will refuse and instruct to use psql.
        lower = stderr.lower()
        if 'text format dump' in lower or 'please use psql' in lower:
            _run_psql()
            return

        raise RuntimeError(
            'فشل استعادة PostgreSQL عبر pg_restore.'
            + (f" التفاصيل: {stderr}" if stderr else '')
        ) from exc

def _restore_sqlite_from_backup_file(src_backup_path: str) -> None:
    dest_path = _sqlite_db_path()
    if not dest_path:
        raise RuntimeError('SQLite destination path is not available')
    if not os.path.exists(src_backup_path):
        raise FileNotFoundError('Backup file not found')

    # Ensure we drop connections before restoring.
    try:
        db.session.remove()
    except Exception:
        pass
    try:
        db.engine.dispose()
    except Exception:
        pass

def _server_backup_dir() -> str:
    configured = os.getenv('BACKUP_DIR')
    if configured and configured.strip():
        return os.path.abspath(os.path.expanduser(configured.strip()))
    return os.path.abspath(os.path.join(os.path.dirname(__file__), 'backups'))

def _actor_username() -> str:
    try:
        u = getattr(g, 'current_user', None)
        if u is None:
            return 'unknown'
        return (
            getattr(u, 'username', None)
            or getattr(u, 'full_name', None)
            or getattr(u, 'name', None)
            or 'unknown'
        )
    except Exception:
        return 'unknown'

def _append_restore_audit(event: str, success: bool, details: dict | None = None) -> None:
    try:
        os.makedirs(_server_backup_dir(), exist_ok=True)
        path = os.path.join(_server_backup_dir(), 'restore_audit.log')
        payload = {
            'ts_utc': datetime.now().isoformat() + 'Z',
            'event': event,
            'success': bool(success),
            'user': _actor_username(),
            'ip': request.remote_addr,
            'ua': request.headers.get('User-Agent'),
            'details': details or {},
        }
        with open(path, 'a', encoding='utf-8') as f:
            f.write(json.dumps(payload, ensure_ascii=False) + '\n')
    except Exception:
        # Never break restore flow due to audit log write.
        pass

def _create_pre_restore_snapshot_zip() -> str:
    created_at = datetime.now().strftime('%Y%m%d-%H%M%S')
    backup_dir = _server_backup_dir()
    os.makedirs(backup_dir, exist_ok=True)

    filename = f'pre-restore-snapshot-{created_at}.zip'
    out_zip_path = os.path.join(backup_dir, filename)

    if _is_postgres_database():
        with tempfile.TemporaryDirectory(prefix='yasargold-pre-restore-') as tmpdir:
            dump_path = os.path.join(tmpdir, 'database.dump')
            _create_postgres_backup_to_file(dump_path)

            meta = {
                'created_at_utc': datetime.now().isoformat() + 'Z',
                'purpose': 'pre_restore_snapshot',
                'db_backend': 'postgres',
                'format': 'pg_dump_custom',
            }
            meta_path = os.path.join(tmpdir, 'metadata.json')
            with open(meta_path, 'w', encoding='utf-8') as f:
                json.dump(meta, f, ensure_ascii=False, indent=2)

            with zipfile.ZipFile(out_zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
                zf.write(dump_path, arcname='database.dump')
                zf.write(meta_path, arcname='metadata.json')

        return out_zip_path

    with tempfile.TemporaryDirectory(prefix='yasargold-pre-restore-') as tmpdir:
        db_path = os.path.join(tmpdir, 'database.sqlite')
        _create_sqlite_backup_to_file(db_path)

        meta = {
            'created_at_utc': datetime.now().isoformat() + 'Z',
            'purpose': 'pre_restore_snapshot',
            'db_backend': 'sqlite',
        }
        meta_path = os.path.join(tmpdir, 'metadata.json')
        with open(meta_path, 'w', encoding='utf-8') as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)

        with zipfile.ZipFile(out_zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
            zf.write(db_path, arcname='database.sqlite')
            zf.write(meta_path, arcname='metadata.json')

    return out_zip_path

    src = sqlite3.connect(src_backup_path)
    try:
        dst = sqlite3.connect(dest_path)
        try:
            src.backup(dst)
            dst.commit()
        finally:
            dst.close()
    finally:
        src.close()

    # Dispose again so new requests reconnect cleanly.
    try:
        db.engine.dispose()
    except Exception:
        pass

@system_bp.route('/weight-closing/settings', methods=['GET'])
@require_permission('system.settings')
def get_weight_closing_settings():
    """Return weight closing settings payload (merged with defaults)."""
    return jsonify(_load_weight_closing_settings()), 200

@system_bp.route('/weight-closing/settings', methods=['PUT'])
@require_permission('system.settings')
def update_weight_closing_settings():
    """Update weight closing settings (stored in Settings.weight_closing_settings JSON)."""
    payload = request.get_json(silent=True) or {}
    if not isinstance(payload, dict):
        return jsonify({'error': 'invalid_payload'}), 400

    # Load current + defaults
    merged = _load_weight_closing_settings()

    # Normalize supported keys (keep it permissive, but sane)
    if 'enabled' in payload:
        merged['enabled'] = bool(payload.get('enabled') is True)

    if 'allow_override' in payload:
        merged['allow_override'] = bool(payload.get('allow_override') is True)

    if 'price_source' in payload:
        src = (str(payload.get('price_source') or '').strip().lower())
        if src in {'live', 'average', 'invoice'}:
            merged['price_source'] = src

    if 'shift_close_cash_deficit_threshold' in payload:
        merged['shift_close_cash_deficit_threshold'] = max(
            0.0,
            float(_coerce_float(payload.get('shift_close_cash_deficit_threshold'), 50.0)),
        )

    if 'shift_close_gold_pure_deficit_threshold_grams' in payload:
        merged['shift_close_gold_pure_deficit_threshold_grams'] = max(
            0.0,
            float(_coerce_float(payload.get('shift_close_gold_pure_deficit_threshold_grams'), 0.10)),
        )

    # Inventory + cash account IDs
    for key in (
        'inventory_new_account_id',
        'inventory_scrap_account_id',
        # Backward-compat
        'inventory_account_id',
        'cash_account_id',
    ):
        if key in payload:
            v = _normalize_account_ref(payload.get(key))
            if v is None:
                merged[key] = None
            elif v > 0:
                merged[key] = v

    # Preferred settlement safebox (nullable)
    if 'cash_safe_box_id' in payload:
        v = _normalize_fk_ref(payload.get('cash_safe_box_id'))
        if v is None:
            merged['cash_safe_box_id'] = None
        elif v > 0:
            merged['cash_safe_box_id'] = v

    # Persist
    settings_row = Settings.query.first()
    if not settings_row:
        settings_row = Settings(main_karat=get_main_karat() or 21)
        db.session.add(settings_row)
        db.session.flush()

    settings_row.weight_closing_settings = json.dumps(merged, ensure_ascii=False)
    db.session.commit()
    return jsonify(_load_weight_closing_settings()), 200

@system_bp.route('/system-alerts', methods=['GET'])
@require_permission('reports.financial')
def list_system_alerts():
    """List system alerts (MVP: filterable by reviewed/severity)."""
    from models import SystemAlert

    severity = (request.args.get('severity') or '').strip().lower() or None
    reviewed = request.args.get('reviewed')

    q = SystemAlert.query
    if severity in {'critical', 'warning', 'info'}:
        q = q.filter(SystemAlert.severity == severity)

    if reviewed is not None:
        s = str(reviewed).strip().lower()
        if s in {'0', 'false', 'no', 'n'}:
            q = q.filter(SystemAlert.is_reviewed.is_(False))
        elif s in {'1', 'true', 'yes', 'y'}:
            q = q.filter(SystemAlert.is_reviewed.is_(True))

    rows = q.order_by(SystemAlert.created_at.desc()).limit(50).all()
    return jsonify({'success': True, 'count': len(rows), 'alerts': [r.to_dict() for r in rows]}), 200

@system_bp.route('/system-alerts/<int:alert_id>/review', methods=['PUT'])
@require_permission('reports.financial')
def review_system_alert(alert_id: int):
    from models import SystemAlert

    row = SystemAlert.query.get_or_404(alert_id)
    if row.is_reviewed:
        return jsonify({'success': True, 'alert': row.to_dict()}), 200

    user_name = None
    try:
        user_name = getattr(getattr(g, 'current_user', None), 'username', None)
    except Exception:
        user_name = None
    user_name = user_name or 'system'

    row.is_reviewed = True
    row.reviewed_at = datetime.now()
    row.reviewed_by = user_name
    db.session.commit()
    return jsonify({'success': True, 'alert': row.to_dict()}), 200

@system_bp.route('/weight-closing/profiles', methods=['GET'])
@require_permission('journal.post')
def list_weight_closing_profiles():
    ensure_weight_closing_support_accounts()
    return jsonify({'profiles': list_weight_profiles()})

@system_bp.route('/settings', methods=['GET'])
def get_settings():
    settings = _get_settings_singleton(create_if_missing=True)
    response = jsonify(settings.to_dict())
    response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'
    response.headers.update(_settings_diag_headers(settings))
    return response

@system_bp.route('/settings', methods=['PUT'])
def update_settings():
    import json
    settings = _get_settings_singleton(create_if_missing=True)

    data = request.get_json(silent=True) or {}
    if not isinstance(data, dict):
        return jsonify({'error': 'invalid_payload'}), 400

    # Fail fast for unknown top-level keys to avoid silent drops.
    allowed_keys = {
        'main_karat',
        'currency_symbol',
        'tax_rate',
        'tax_enabled',
        'vat_exempt_karats',
        'payment_methods',
        'invoice_prefix',
        'show_company_logo',
        'company_name',
        'company_logo_base64',
        'company_address',
        'company_phone',
        'company_tax_number',
        'company_cr_number',
        'print_template_by_invoice_type',
        'decimal_places',
        'date_format',
        'default_discount_rate',
        'allow_discount',
        'allow_manual_invoice_items',
        'employee_cash_safes_enabled',
        'employee_gold_safes_enabled',
        'main_cash_safe_box_id',
        'sale_gold_safe_box_id',
        'main_scrap_gold_safe_box_id',
        'stones_pending_account_id',
        'stones_display_revenue_account_id',
        'manufacturing_wage_mode',
        'voucher_auto_post',
        'auto_post_invoices',
        'auto_post_entries',
        'require_approval_before_post',
        'allow_unposting',
        'require_auth_for_invoice_create',
        'idle_timeout_enabled',
        'idle_timeout_minutes',
        'allow_partial_invoice_payments',
        'weekly_sales_target_weight',
        'monthly_sales_target_weight',
        'sales_race_settings',
        'gold_price_auto_update_enabled',
        'gold_price_auto_update_time',
        'gold_price_auto_update_mode',
        'gold_price_auto_update_interval_minutes',
        'backup_auto_enabled',
        'backup_auto_mode',
        'backup_auto_time',
        'backup_auto_interval_minutes',
        'backup_retention_count',
    }
    unknown_keys = sorted(set(data.keys()) - allowed_keys)
    if unknown_keys:
        return jsonify({
            'error': 'unknown_settings_keys',
            'message': 'تحتوي الحمولة على مفاتيح إعدادات غير مدعومة',
            'unknown_keys': unknown_keys,
        }), 400
    
    # إعدادات أساسية
    if 'main_karat' in data:
        settings.main_karat = data['main_karat']
    if 'currency_symbol' in data:
        settings.currency_symbol = data['currency_symbol']
    
    # إعدادات الضريبة
    if 'tax_rate' in data:
        settings.tax_rate = data['tax_rate']
    if 'tax_enabled' in data:
        settings.tax_enabled = data['tax_enabled']

    # 🆕 إعفاء العيارات من ضريبة الذهب
    if 'vat_exempt_karats' in data:
        raw = data.get('vat_exempt_karats')
        values = []

        if isinstance(raw, (list, tuple, set)):
            candidates = list(raw)
        elif isinstance(raw, str):
            s = raw.strip()
            candidates = []
            if s:
                try:
                    decoded = json.loads(s)
                    if isinstance(decoded, (list, tuple, set)):
                        candidates = list(decoded)
                    else:
                        candidates = [decoded]
                except Exception:
                    # Fallback: comma/space separated
                    candidates = [part for part in s.replace(';', ',').split(',')]
        else:
            candidates = []

        for v in candidates:
            try:
                k = int(str(v).strip())
            except Exception:
                continue
            if k in (18, 21, 22, 24):
                values.append(str(k))

        values = sorted(set(values), key=lambda x: int(x))
        settings.vat_exempt_karats = json.dumps(values, ensure_ascii=False) if values else None
    
    # وسائل الدفع
    if 'payment_methods' in data:
        pm_raw = data.get('payment_methods')
        if isinstance(pm_raw, str):
            try:
                pm_raw = json.loads(pm_raw)
            except Exception:
                pm_raw = None
        if isinstance(pm_raw, (list, tuple)):
            settings.payment_methods = json.dumps(list(pm_raw), ensure_ascii=False)
    
    # إعدادات الفواتير
    if 'invoice_prefix' in data:
        settings.invoice_prefix = data['invoice_prefix']
    if 'show_company_logo' in data:
        settings.show_company_logo = data['show_company_logo']
    if 'company_name' in data:
        settings.company_name = data['company_name']
    if 'company_logo_base64' in data:
        settings.company_logo_base64 = data['company_logo_base64']
    if 'company_address' in data:
        settings.company_address = data['company_address']
    if 'company_phone' in data:
        settings.company_phone = data['company_phone']
    if 'company_tax_number' in data:
        settings.company_tax_number = data['company_tax_number']
    if 'company_cr_number' in data:
        settings.company_cr_number = data['company_cr_number']

    # 🆕 افتراضي قالب الطباعة حسب نوع الفاتورة
    if 'print_template_by_invoice_type' in data:
        try:
            settings.print_template_by_invoice_type = json.dumps(
                data['print_template_by_invoice_type'],
                ensure_ascii=False,
            )
        except Exception:
            settings.print_template_by_invoice_type = None
    
    # إعدادات التنسيق
    if 'decimal_places' in data:
        settings.decimal_places = data['decimal_places']
    if 'date_format' in data:
        settings.date_format = data['date_format']
    
    # إعدادات الخصم
    if 'default_discount_rate' in data:
        settings.default_discount_rate = data['default_discount_rate']
    if 'allow_discount' in data:
        settings.allow_discount = data['allow_discount']

    # 🆕 إعدادات إضافية كانت تُرسل من الواجهة دون أن تُحفظ
    if 'allow_manual_invoice_items' in data:
        settings.allow_manual_invoice_items = data['allow_manual_invoice_items']

    # ==========================================
    # 🆕 Feature Toggles لمسار خزائن الموظفين + خزائن افتراضية
    # ==========================================
    if 'employee_cash_safes_enabled' in data:
        settings.employee_cash_safes_enabled = bool(data.get('employee_cash_safes_enabled'))
    if 'employee_gold_safes_enabled' in data:
        settings.employee_gold_safes_enabled = bool(data.get('employee_gold_safes_enabled'))

    # Default SafeBoxes + Stones Accounts
    for key in (
        'main_cash_safe_box_id', 'sale_gold_safe_box_id', 'main_scrap_gold_safe_box_id',
        'stones_pending_account_id', 'stones_display_revenue_account_id',
    ):
        if key in data:
            raw = data.get(key)
            if raw in (None, '', 0, '0', False):
                setattr(settings, key, None)
            else:
                try:
                    setattr(settings, key, int(raw))
                except Exception:
                    pass
    if 'manufacturing_wage_mode' in data:
        settings.manufacturing_wage_mode = data['manufacturing_wage_mode']
    if 'voucher_auto_post' in data:
        settings.voucher_auto_post = data['voucher_auto_post']

    # 🆕 إعدادات الترحيل (Posting Preferences)
    for _pk in ('auto_post_invoices', 'auto_post_entries', 'require_approval_before_post', 'allow_unposting'):
        if _pk in data:
            setattr(settings, _pk, bool(data[_pk]))

    # 🆕 إعدادات الأمان
    if 'require_auth_for_invoice_create' in data:
        settings.require_auth_for_invoice_create = data['require_auth_for_invoice_create']

    # 🆕 إنهاء الجلسة عند عدم النشاط
    if 'idle_timeout_enabled' in data:
        raw = data['idle_timeout_enabled']
        if isinstance(raw, bool):
            settings.idle_timeout_enabled = raw
        elif isinstance(raw, (int, float)):
            settings.idle_timeout_enabled = bool(raw)
        elif isinstance(raw, str):
            s = raw.strip().lower()
            settings.idle_timeout_enabled = s in {'1', 'true', 'yes', 'y', 'on'}
        else:
            settings.idle_timeout_enabled = True

    if 'idle_timeout_minutes' in data:
        raw = data.get('idle_timeout_minutes')
        minutes = None
        try:
            minutes = int(raw)
        except Exception:
            try:
                minutes = int(str(raw).strip())
            except Exception:
                minutes = None

        if minutes is None:
            # keep existing value
            pass
        else:
            if minutes < 1:
                minutes = 1
            if minutes > 10080:
                minutes = 10080
            settings.idle_timeout_minutes = minutes

    # 🆕 إعدادات الدفع الجزئي/البيع الآجل
    if 'allow_partial_invoice_payments' in data:
        settings.allow_partial_invoice_payments = data['allow_partial_invoice_payments']

    # 🆕 أهداف المبيعات وإعدادات سباق الأداء
    if 'weekly_sales_target_weight' in data:
        try:
            settings.weekly_sales_target_weight = max(0.0, float(data['weekly_sales_target_weight'] or 0.0))
        except Exception:
            pass
    if 'monthly_sales_target_weight' in data:
        try:
            settings.monthly_sales_target_weight = max(0.0, float(data['monthly_sales_target_weight'] or 0.0))
        except Exception:
            pass
    if 'sales_race_settings' in data:
        race_data = data['sales_race_settings']
        if isinstance(race_data, str):
            try:
                race_data = json.loads(race_data)
            except Exception:
                race_data = None
        if isinstance(race_data, dict):
            existing_raw = getattr(settings, 'sales_race_settings', None)
            existing: dict = {}
            if existing_raw:
                try:
                    existing = json.loads(existing_raw) if isinstance(existing_raw, str) else existing_raw
                    if not isinstance(existing, dict):
                        existing = {}
                except Exception:
                    existing = {}
            existing.update(race_data)
            from sqlalchemy.orm.attributes import flag_modified as _flag_modified_race
            settings.sales_race_settings = json.dumps(existing, ensure_ascii=False)
            _flag_modified_race(settings, 'sales_race_settings')

    # 🆕 تحديث سعر الذهب تلقائياً حسب توقيت معين
    if 'gold_price_auto_update_enabled' in data:
        raw = data['gold_price_auto_update_enabled']
        if isinstance(raw, bool):
            settings.gold_price_auto_update_enabled = raw
        elif isinstance(raw, (int, float)):
            settings.gold_price_auto_update_enabled = bool(raw)
        elif isinstance(raw, str):
            s = raw.strip().lower()
            settings.gold_price_auto_update_enabled = s in {'1', 'true', 'yes', 'y', 'on'}
        else:
            settings.gold_price_auto_update_enabled = False
    if 'gold_price_auto_update_time' in data:
        raw = data['gold_price_auto_update_time']
        settings.gold_price_auto_update_time = (str(raw).strip() if raw is not None else None)

    # 🆕 تحديث سعر الذهب تلقائياً حسب فترة (دقيقة/5 دقائق/ساعة...)
    if 'gold_price_auto_update_mode' in data:
        raw = data['gold_price_auto_update_mode']
        mode = (str(raw).strip().lower() if raw is not None else 'interval')
        settings.gold_price_auto_update_mode = mode if mode in {'interval', 'daily'} else 'interval'
    if 'gold_price_auto_update_interval_minutes' in data:
        raw = data['gold_price_auto_update_interval_minutes']
        minutes = None
        try:
            minutes = int(raw)
        except Exception:
            try:
                minutes = int(str(raw).strip())
            except Exception:
                minutes = None

        if minutes is None:
            settings.gold_price_auto_update_interval_minutes = None
        else:
            if minutes < 1:
                minutes = 1
            if minutes > 10080:
                minutes = 10080
            settings.gold_price_auto_update_interval_minutes = minutes

    # 🆕 النسخ الاحتياطي التلقائي (على السيرفر)
    if 'backup_auto_enabled' in data:
        raw = data['backup_auto_enabled']
        if isinstance(raw, bool):
            settings.backup_auto_enabled = raw
        elif isinstance(raw, (int, float)):
            settings.backup_auto_enabled = bool(raw)
        elif isinstance(raw, str):
            s = raw.strip().lower()
            settings.backup_auto_enabled = s in {'1', 'true', 'yes', 'y', 'on'}
        else:
            settings.backup_auto_enabled = False

    if 'backup_auto_mode' in data:
        raw = data['backup_auto_mode']
        mode = (str(raw).strip().lower() if raw is not None else 'daily')
        settings.backup_auto_mode = mode if mode in {'interval', 'daily'} else 'daily'

    if 'backup_auto_time' in data:
        raw = data['backup_auto_time']
        settings.backup_auto_time = (str(raw).strip() if raw is not None else None)

    if 'backup_auto_interval_minutes' in data:
        raw = data['backup_auto_interval_minutes']
        minutes = None
        try:
            minutes = int(raw)
        except Exception:
            try:
                minutes = int(str(raw).strip())
            except Exception:
                minutes = None
        if minutes is None:
            # keep existing value
            pass
        else:
            if minutes < 1:
                minutes = 1
            if minutes > 10080:
                minutes = 10080
            settings.backup_auto_interval_minutes = minutes

    if 'backup_retention_count' in data:
        raw = data.get('backup_retention_count')
        count = None
        try:
            count = int(raw)
        except Exception:
            try:
                count = int(str(raw).strip())
            except Exception:
                count = None
        if count is None:
            pass
        else:
            if count < 1:
                count = 1
            if count > 365:
                count = 365
            settings.backup_retention_count = count
    
    # Capture the primary key BEFORE any session manipulation so we can
    # re-query safely after commit (avoiding DetachedInstanceError).
    settings_id = settings.id

    # ── Bulk-post existing unposted voucher JEs when auto-post is enabled ──
    # When the user switches voucher_auto_post or auto_post_entries to True,
    # retroactively post all voucher-sourced JEs that were created unposted.
    _bulk_posted_count = 0
    try:
        _want_auto_post = (
            bool(getattr(settings, 'voucher_auto_post', False))
            or bool(getattr(settings, 'auto_post_entries', False))
        )
        if _want_auto_post:
            _unposted_voucher_jes = (
                JournalEntry.query
                .filter(
                    JournalEntry.reference_type.in_(['voucher', 'invoice']),
                    func.coalesce(JournalEntry.is_posted, False) == False,
                )
                .all()
            )
            _now = datetime.now()
            for _uje in _unposted_voucher_jes:
                _uje.is_posted = True
                _uje.is_draft = False
                if not _uje.posted_at:
                    _uje.posted_at = _now
                if not _uje.posted_by:
                    _uje.posted_by = 'system'
                _bulk_posted_count += 1

        # Recompute balances for all accounts affected by the bulk-posted JEs.
        if _bulk_posted_count and _unposted_voucher_jes:
            _bulk_affected = set()
            for _bje in _unposted_voucher_jes:
                _bulk_affected.update(
                    l.account_id for l in (_bje.lines or []) if l.account_id
                )
            if _bulk_affected:
                _recalculate_account_balances_for_accounts(list(_bulk_affected))
    except Exception as _bp_err:
        print(f'[Settings] Bulk-post existing JEs warning: {_bp_err}')

    try:
        db.session.commit()
    except Exception as commit_err:
        db.session.rollback()
        return jsonify({'error': 'commit_failed', 'message': str(commit_err)}), 500

    # Re-read using a completely independent session so we are 100% guaranteed
    # to see the committed data and never return a stale cached value.
    # This is critical in PostgreSQL multi-worker (Gunicorn) production where
    # the request-scoped session may have a stale identity map after commit.
    result_dict = None
    try:
        from sqlalchemy.orm import Session as _IndependentSession
        with _IndependentSession(db.engine) as _s:
            _fresh = _s.query(Settings).filter_by(id=settings_id).first()
            if _fresh is not None:
                result_dict = _fresh.to_dict()
    except Exception:
        result_dict = None

    if result_dict is None:
        # Fallback: expire the request session and re-query from it.
        try:
            db.session.expire_all()
            _fallback = db.session.query(Settings).filter_by(id=settings_id).first()
            result_dict = _fallback.to_dict() if _fallback else settings.to_dict()
        except Exception:
            result_dict = settings.to_dict()

    response = jsonify(result_dict)
    response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'
    response.headers.update(_settings_diag_headers(settings))
    return response

@system_bp.route('/system/reset', methods=['POST'])
@require_permission('system.settings')
def system_reset():
    """System reset with multiple safety levels.

    Body Parameters (JSON):
      - reset_type: str
        Backward-compatible:
          * "transactions" - حذف العمليات فقط (القيود، الفواتير، السندات)
          * "nuclear" - تصفير شامل للعمليات (يشمل دفتر الخزائن + التنبيهات + السجل) مع إبقاء الهيكل الأساسي
          * "customers_suppliers" - حذف/مسح بيانات العملاء والموردين
          * "settings" - إعادة تعيين الإعدادات للقيم الافتراضية
          * "all" - إعادة تهيئة كاملة مع الحفاظ على شجرة الحسابات
          * "all_with_accounts" - إعادة تهيئة كاملة (بما في ذلك شجرة الحسابات)

        Leveled (recommended):
          * "balances_only" - تصفير الأرصدة التشغيلية فقط (SafeBoxTransaction)
          * "oversight_only" - تصفير الرقابة (SystemAlert + AuditLog)
          * "factory_data" - مسح كل البيانات التشغيلية + العملاء/الموردين مع إبقاء (الخزائن/الموظفين/الفروع/الحسابات)
          * "full_wipe" - Full System Wipe (حذف كل شيء بما فيه الخزائن/الموظفين/الفروع/المكاتب) مع استثناء الأدمن

      - confirm: str (required for dangerous actions)
    """
    try:
        data = request.get_json(silent=True) or {}
        reset_type = (data.get('reset_type') or 'all').strip()

        def _actor_is_system_admin() -> bool:
            try:
                actor = getattr(g, 'current_user', None)
                return bool(getattr(actor, 'is_admin', False))
            except Exception:
                return False

        def _is_production_env() -> bool:
            # Support multiple common env var names used across deployments.
            env = (
                os.getenv('YASAR_ENV')
                or os.getenv('APP_ENV')
                or os.getenv('ENV')
                or os.getenv('FLASK_ENV')
                or ''
            )
            return str(env).strip().lower() in {'prod', 'production'}

        def _dangerous_resets_allowed() -> bool:
            val = os.getenv('ALLOW_DANGEROUS_RESETS')
            return str(val or '').strip().lower() in {'1', 'true', 'yes', 'y', 'on'}

        # 🔒 Production Lock: block destructive reset types in production unless explicitly enabled.
        if _is_production_env() and not _dangerous_resets_allowed():
            if reset_type not in {'settings'}:
                return jsonify({
                    'status': 'error',
                    'message': (
                        'هذا الإجراء مقفّل على نسخة الإنتاج (Production Lock). '
                        'لأسباب أمنية لا يُسمح بتنفيذ عمليات التصفير/الحذف على الإنتاج. '
                        'إذا كنت متأكدًا، فعّل ALLOW_DANGEROUS_RESETS=true في بيئة التشغيل.'
                    ),
                    'error': 'production_lock',
                    'reset_type': reset_type,
                }), 403
        
        if reset_type in {'transactions', 'operations_only', 'operations'}:
            # حذف العمليات فقط (القيود، الفواتير، السندات، المدفوعات)
            _reset_transactions()
            message = 'تم حذف جميع العمليات بنجاح (القيود، الفواتير، السندات)'

        elif reset_type in {'balances_only', 'balances'}:
            confirm = (data.get('confirm') or '').strip()
            if confirm != 'BALANCES':
                return jsonify({
                    'status': 'error',
                    'message': 'تأكيد غير صحيح. ارسل confirm=BALANCES لتصفير الأرصدة (دفتر الخزائن فقط).',
                }), 400
            _reset_balances_only()
            message = 'تم تصفير الأرصدة التشغيلية للخزائن (SafeBoxTransaction) بنجاح.'

        elif reset_type in {'oversight_only', 'oversight'}:
            confirm = (data.get('confirm') or '').strip()
            if confirm != 'AUDIT':
                return jsonify({
                    'status': 'error',
                    'message': 'تأكيد غير صحيح. ارسل confirm=AUDIT لمسح التنبيهات وسجل التدقيق.',
                }), 400
            _reset_oversight_only()
            message = 'تم مسح التنبيهات وسجل النشاط (Audit) بنجاح.'

        elif reset_type == 'nuclear':
            if not _actor_is_system_admin():
                return jsonify({
                    'status': 'error',
                    'message': 'هذا الإجراء مسموح فقط لمسؤول النظام (system admin).',
                }), 403
            confirm = (data.get('confirm') or '').strip()
            if confirm != 'RESET':
                return jsonify({
                    'status': 'error',
                    'message': 'تأكيد غير صحيح. ارسل confirm=RESET لتنفيذ التصفير الشامل.',
                }), 400

            _reset_nuclear_transactions()
            message = (
                'تم تنفيذ التصفير الشامل بنجاح: تم مسح دفتر الخزائن والعمليات والقيود '
                'والفواتير والتنبيهات والسجل، مع إبقاء الخزائن/الموظفين/الفروع/الحسابات.'
            )
            
        elif reset_type in {'customers_suppliers', 'customers_only', 'customers'}:
            # حذف العملاء والموردين
            confirm = (data.get('confirm') or '').strip()
            # customers_suppliers historically had no confirm; keep it optional but allow enforcing it in UI.
            if reset_type in {'customers_only', 'customers'} and confirm != 'CUSTOMERS':
                return jsonify({
                    'status': 'error',
                    'message': 'تأكيد غير صحيح. ارسل confirm=CUSTOMERS لمسح بيانات العملاء والموردين.',
                }), 400
            _reset_customers_suppliers()
            message = 'تم حذف جميع بيانات العملاء والموردين بنجاح'

        elif reset_type in {'factory_data', 'factory'}:
            if not _actor_is_system_admin():
                return jsonify({
                    'status': 'error',
                    'message': 'هذا الإجراء مسموح فقط لمسؤول النظام (system admin).',
                }), 403

            confirm = (data.get('confirm') or '').strip()
            if confirm != 'FACTORY':
                return jsonify({
                    'status': 'error',
                    'message': 'تأكيد غير صحيح. ارسل confirm=FACTORY لتنفيذ إعادة ضبط المصنع (بيانات).',
                }), 400

            _reset_factory_data()
            message = (
                'تم تنفيذ إعادة ضبط المصنع (بيانات) بنجاح: تم مسح العمليات ودفتر الخزائن والتنبيهات والسجل '
                'ومسح العملاء/الموردين، مع إبقاء الخزائن/الموظفين/الفروع/شجرة الحسابات.'
            )

        elif reset_type in {'full_wipe', 'full_system_wipe'}:
            if not _actor_is_system_admin():
                return jsonify({
                    'status': 'error',
                    'message': 'هذا الإجراء مسموح فقط لمسؤول النظام (system admin).',
                }), 403

            confirm = (data.get('confirm') or '').strip()
            if confirm != 'WIPE-ALL':
                return jsonify({
                    'status': 'error',
                    'message': 'تأكيد غير صحيح. ارسل confirm=WIPE-ALL لتنفيذ Full System Wipe.',
                }), 400

            _reset_full_system_wipe()
            message = (
                'تم تنفيذ Full System Wipe بنجاح: تم حذف كل البيانات بما فيها الخزائن/الموظفين/الفروع/المكاتب '
                'مع استثناء مستخدم الأدمن الرئيسي.'
            )
            
        elif reset_type == 'settings':
            # إعادة تعيين الإعدادات
            _reset_settings()
            message = 'تم إعادة تعيين الإعدادات للقيم الافتراضية'
            
        elif reset_type == 'all':
            # إعادة تهيئة كاملة مع الحفاظ على شجرة الحسابات (السلوك الافتراضي)
            # Use the currently-running Flask app module to avoid importing a second app instance.
            from app import reset_database_preserve_accounts
            reset_database_preserve_accounts()
            message = 'تم إعادة تهيئة النظام بالكامل بنجاح مع الحفاظ على شجرة الحسابات.'

        elif reset_type == 'all_with_accounts':
            # إعادة تهيئة كاملة (بما في ذلك شجرة الحسابات)
            # Use the currently-running Flask app module to avoid importing a second app instance.
            from app import reset_database
            reset_database()

            # Defensive: ensure the account table is empty before rebuilding the COA.
            # Some bootstraps may auto-create support accounts immediately after a reset.
            try:
                from models import Account
                if getattr(db.engine.dialect, 'name', '') == 'sqlite':
                    db.session.execute(db.text('PRAGMA foreign_keys=OFF'))
                Account.query.delete()
                if getattr(db.engine.dialect, 'name', '') == 'sqlite':
                    db.session.execute(db.text('PRAGMA foreign_keys=ON'))
                db.session.commit()
            except Exception:
                db.session.rollback()

            # إعادة إنشاء شجرة الحسابات بالترقيم الجديد (مالية + وزنية)
            try:
                from renumber_accounts import create_financial_and_memo_accounts
                create_financial_and_memo_accounts(force_delete_existing=True)
            except Exception as exc:
                return jsonify({
                    'status': 'error',
                    'message': f'فشل إنشاء شجرة الحسابات بالترقيم الجديد: {str(exc)}',
                    'reset_type': reset_type,
                }), 500

            # إعادة إنشاء حسابات الدعم الأساسية (إن وجدت/مطلوبة) بعد إعادة تهيئة الجداول
            try:
                ensure_weight_closing_support_accounts()
            except Exception:
                # لا نكسر عملية إعادة التهيئة إذا فشل إنشاء حسابات الدعم
                pass

            message = 'تم إعادة تهيئة النظام بالكامل بنجاح (بما في ذلك شجرة الحسابات).'
            
        else:
            return jsonify({
                'status': 'error', 
                'message': (
                    f'نوع إعادة التهيئة غير صحيح: {reset_type}. '
                    'الخيارات: balances_only, transactions, oversight_only, customers_suppliers, nuclear, '
                    'factory_data, full_wipe, settings, all, all_with_accounts'
                )
            }), 400
        
        return jsonify({
            'status': 'success',
            'message': message,
            'reset_type': reset_type,
        }), 200

    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

def _reset_transactions():
    """حذف جميع العمليات (القيود، الفواتير، السندات) مع إعادة ضبط الأرصدة"""
    try:
        # حذف السجلات المرتبطة بالموظفين أولاً لتفادي تعارض العلاقات
        Attendance.query.delete()
        Payroll.query.delete()

        # حذف مكافآت الموظفين المرتبطة بالفواتير/الحضور (نواتج عمليات)
        BonusInvoiceLink.query.delete()
        EmployeeBonus.query.delete()

        # ✅ Weight-closing tables reference Invoice/JournalEntry via FK (PostgreSQL will enforce).
        # IMPORTANT: query.delete() bypasses ORM cascades, so delete children first.
        try:
            WeightClosingExecution.query.delete()
        except Exception:
            pass
        try:
            WeightClosingOrder.query.delete()
        except Exception:
            pass
        try:
            InvoiceWeightSettlement.query.delete()
        except Exception:
            pass

        # حذف القيود المحاسبية وسطورها
        JournalEntryLine.query.delete()
        JournalEntry.query.delete()

        # حذف الفواتير وعناصرها ومدفوعاتها
        InvoicePayment.query.delete()
        InvoiceKaratLine.query.delete()
        InvoiceItem.query.delete()
        Invoice.query.delete()

        # حذف السندات وسطورها
        VoucherAccountLine.query.delete()
        Voucher.query.delete()

        # إعادة ضبط أرصدة الحسابات لتتوافق مع قاعدة البيانات الفارغة
        db.session.query(Account).update({
            Account.balance_cash: 0.0,
            Account.balance_18k: 0.0,
            Account.balance_21k: 0.0,
            Account.balance_22k: 0.0,
            Account.balance_24k: 0.0,
        }, synchronize_session=False)

        # إعادة ضبط أرصدة العملاء والموردين بعد حذف العمليات
        db.session.query(Customer).update({
            Customer.balance_cash: 0.0,
            Customer.balance_gold_18k: 0.0,
            Customer.balance_gold_21k: 0.0,
            Customer.balance_gold_22k: 0.0,
            Customer.balance_gold_24k: 0.0,
        }, synchronize_session=False)

        # No supplier balance to reset: a supplier's cash/gold balance is
        # derived from the ledger (compute_live_supplier_balances), so zeroing
        # the journal above already zeroes it. Customer still has its own
        # cached columns and is reset just above.

        db.session.commit()

    except Exception as e:
        db.session.rollback()
        raise e

def _reset_nuclear_transactions():
    """☢️ تصفير شامل للعمليات مع إبقاء الهيكل الأساسي (testing only).

    يشمل:
      - SafeBoxTransaction (دفتر الخزائن/الذهب)
      - JournalEntry + JournalEntryLine
      - Invoice + InvoiceItem + InvoicePayment + InvoiceKaratLine
      - Voucher + VoucherAccountLine
      - SystemAlert + AuditLog
      - WeightClosingLog + SupplierGoldTransaction + InventoryCostingConfig
    """
    try:
        from models import (
            AuditLog,
            InventoryCostingConfig,
            SafeBoxTransaction,
            SupplierGoldTransaction,
            SystemAlert,
            WeightClosingLog,
        )

        # Operational logs / alerts
        try:
            WeightClosingLog.query.delete()
        except Exception:
            pass
        try:
            SystemAlert.query.delete()
        except Exception:
            pass
        try:
            AuditLog.query.delete()
        except Exception:
            pass

        # Clear ledger first so dashboard balances become zero
        try:
            SafeBoxTransaction.query.delete()
        except Exception:
            pass

        # Other operational subsystems
        try:
            SupplierGoldTransaction.query.delete()
        except Exception:
            pass

        # Costing snapshots/config
        try:
            InventoryCostingConfig.query.delete()
        except Exception:
            pass

        # Core operations (journals/invoices/vouchers/payroll/etc)
        _reset_transactions()

        # Ensure balances are zeroed (in case _reset_transactions was adjusted in future)
        db.session.query(Account).update({
            Account.balance_cash: 0.0,
            Account.balance_18k: 0.0,
            Account.balance_21k: 0.0,
            Account.balance_22k: 0.0,
            Account.balance_24k: 0.0,
        }, synchronize_session=False)

        db.session.query(Customer).update({
            Customer.balance_cash: 0.0,
            Customer.balance_gold_18k: 0.0,
            Customer.balance_gold_21k: 0.0,
            Customer.balance_gold_22k: 0.0,
            Customer.balance_gold_24k: 0.0,
        }, synchronize_session=False)

        # No supplier balance to reset: a supplier's cash/gold balance is
        # derived from the ledger (compute_live_supplier_balances), so zeroing
        # the journal above already zeroes it. Customer still has its own
        # cached columns and is reset just above.

        db.session.commit()

    except Exception as e:
        db.session.rollback()
        raise e

def _reset_balances_only():
    """Reset only SafeBox ledger movements (opening custody to zero)."""
    try:
        SafeBoxTransaction.query.delete()
        db.session.commit()
        _try_process_due_auto_clearing_settlements(payment_method_ids=[pm_id])
    except Exception as e:
        db.session.rollback()
        raise e

def _reset_oversight_only():
    """Reset oversight tables only (SystemAlert + AuditLog)."""
    try:
        from models import AuditLog, SystemAlert
        try:
            SystemAlert.query.delete()
        except Exception:
            pass
        try:
            AuditLog.query.delete()
        except Exception:
            pass
        db.session.commit()
    except Exception as e:
        db.session.rollback()
        raise e

def _reset_customers_suppliers():
    """حذف العملاء والموردين بأمان.

    ملاحظة: قد توجد علاقات عبر فواتير/سندات/قيود. لضمان عدم فشل IntegrityError:
      - نفصل الروابط (set NULL) حيثما أمكن
      - نحذف العمليات المرتبطة غير القابلة للفصل (مثل SupplierGoldTransaction)
    """
    try:
        # Detach FK references to allow deletion
        try:
            db.session.query(Invoice).update({
                Invoice.customer_id: None,
                Invoice.supplier_id: None,
            }, synchronize_session=False)
        except Exception:
            pass

        try:
            db.session.query(Voucher).update({
                Voucher.customer_id: None,
                Voucher.supplier_id: None,
            }, synchronize_session=False)
        except Exception:
            pass

        try:
            db.session.query(JournalEntryLine).update({
                JournalEntryLine.customer_id: None,
                JournalEntryLine.supplier_id: None,
            }, synchronize_session=False)
        except Exception:
            pass

        try:
            db.session.query(Office).update({
                Office.supplier_id: None,
            }, synchronize_session=False)
        except Exception:
            pass

        # Supplier gold ledger depends on supplier_id (NOT NULL)
        try:
            from models import SupplierGoldTransaction
            SupplierGoldTransaction.query.delete()
        except Exception:
            pass

        # Delete customers/suppliers
        Customer.query.delete()
        Supplier.query.delete()

        db.session.commit()
        
    except Exception as e:
        db.session.rollback()
        raise e

def _reset_factory_data():
    """Factory reset (data): wipes operational data + customers/suppliers; keeps master structure."""
    try:
        from models import (
            AuditLog,
            InventoryCostingConfig,
            SupplierGoldTransaction,
            SystemAlert,
            WeightClosingLog,
        )

        # Oversight first
        try:
            SystemAlert.query.delete()
        except Exception:
            pass
        try:
            AuditLog.query.delete()
        except Exception:
            pass
        try:
            WeightClosingLog.query.delete()
        except Exception:
            pass

        # Weight-closing operational entities
        try:
            WeightClosingExecution.query.delete()
        except Exception:
            pass
        try:
            WeightClosingOrder.query.delete()
        except Exception:
            pass

        # Office reservations are operational
        try:
            OfficeReservation.query.delete()
        except Exception:
            pass

        # Ledger
        try:
            SafeBoxTransaction.query.delete()
        except Exception:
            pass

        # Supplier gold movements (operational)
        try:
            SupplierGoldTransaction.query.delete()
        except Exception:
            pass

        # Costing snapshots/config
        try:
            InventoryCostingConfig.query.delete()
        except Exception:
            pass

        # Core operations
        _reset_transactions()

        # Detach office↔supplier link (Office keeps existing, supplier is wiped)
        try:
            db.session.query(Office).update({
                Office.supplier_id: None,
            }, synchronize_session=False)
        except Exception:
            pass

        # Wipe customers/suppliers
        Customer.query.delete()
        Supplier.query.delete()

        db.session.commit()
    except Exception as e:
        db.session.rollback()
        raise e

def _reset_full_system_wipe():
    """Full System Wipe (Level 6).

    Root-cause fix (PostgreSQL):
    - Do not swallow FK/constraint errors and still return "success".
    - Explicitly delete/clear *all* SafeBox/Account dependency tables first.

    Ordering:
      1) Operational/transaction tables (incl. SafeBoxTransaction + CategoryWeightMovement + recurring journals)
      2) Parties/master-data (customers/suppliers/items/categories/payment)
      3) Structure (employees/users/branches/offices/safebox)
      4) Chart of accounts (mappings -> accounts)
    """

    from models import (
        AppUser,
        AuditLog,
        Branch,
        BonusRule,
        Category,
        CategoryWeightMovement,
        GoldPrice,
        InventoryCostingConfig,
        InvoiceWeightSettlement,
        Item,
        PaymentType,
        SupplierGoldTransaction,
        SystemAlert,
        WeightClosingLog,
    )
    from recurring_journal_system import RecurringJournalLine, RecurringJournalTemplate

    def _step(label: str, fn, required: bool = True) -> None:
        try:
            with db.session.begin_nested():
                fn()
                db.session.flush()
        except Exception as e:
            # Savepoint is rolled back automatically; make the failure explicit.
            msg = f"{label}: {str(e)}"
            if required:
                raise Exception(msg)
            print(f"⚠️ {msg}")

    # 1) Transactions/operational tables that block SafeBox/Account deletion
    _step('Delete CategoryWeightMovement (blocks SafeBox)', lambda: CategoryWeightMovement.query.delete())
    _step('Delete SafeBoxTransaction (blocks SafeBox)', lambda: SafeBoxTransaction.query.delete())
    _step('Delete recurring journals (block Account)', lambda: RecurringJournalLine.query.delete())
    _step('Delete recurring journal templates (block Account)', lambda: RecurringJournalTemplate.query.delete())

    # Core operations (children first)
    _step('Delete WeightClosingExecution', lambda: WeightClosingExecution.query.delete())
    _step('Delete WeightClosingOrder', lambda: WeightClosingOrder.query.delete())
    _step('Delete InvoiceWeightSettlement', lambda: InvoiceWeightSettlement.query.delete())

    _step('Delete JournalEntryLine', lambda: JournalEntryLine.query.delete())
    _step('Delete JournalEntry', lambda: JournalEntry.query.delete())

    _step('Delete InvoicePayment', lambda: InvoicePayment.query.delete())
    _step('Delete InvoiceKaratLine', lambda: InvoiceKaratLine.query.delete())
    _step('Delete InvoiceItem', lambda: InvoiceItem.query.delete())
    _step('Delete Invoice', lambda: Invoice.query.delete())

    _step('Delete VoucherAccountLine', lambda: VoucherAccountLine.query.delete())
    _step('Delete Voucher', lambda: Voucher.query.delete())

    _step('Delete OfficeReservation', lambda: OfficeReservation.query.delete())
    _step('Delete Payroll', lambda: Payroll.query.delete())
    _step('Delete Attendance', lambda: Attendance.query.delete())
    _step('Delete Employee bonuses', lambda: EmployeeBonus.query.delete())
    _step('Delete BonusInvoiceLink', lambda: BonusInvoiceLink.query.delete())

    # Oversight/logging
    _step('Delete SystemAlert', lambda: SystemAlert.query.delete())
    _step('Delete AuditLog', lambda: AuditLog.query.delete())
    _step('Delete WeightClosingLog', lambda: WeightClosingLog.query.delete())
    _step('Delete SupplierGoldTransaction', lambda: SupplierGoldTransaction.query.delete())
    _step('Delete InventoryCostingConfig', lambda: InventoryCostingConfig.query.delete())

    # 2) Master data that can reference safebox/account
    _step('Detach PaymentMethod -> SafeBox (default/settlement)', lambda: PaymentMethod.query.update({
        PaymentMethod.default_safe_box_id: None,
        PaymentMethod.settlement_bank_safe_box_id: None,
    }, synchronize_session=False), required=False)
    _step('Delete PaymentMethod', lambda: PaymentMethod.query.delete())
    _step('Delete PaymentType', lambda: PaymentType.query.delete(), required=False)

    _step('Delete Item', lambda: Item.query.delete())
    _step('Delete Category', lambda: Category.query.delete())
    _step('Delete GoldPrice', lambda: GoldPrice.query.delete(), required=False)
    _step('Delete BonusRule', lambda: BonusRule.query.delete(), required=False)

    # 3) Structure: clear FK references that are RESTRICT before deleting
    def _detach_settings_refs() -> None:
        settings_row = Settings.query.first()
        if not settings_row:
            settings_row = Settings()
            db.session.add(settings_row)
            db.session.flush()

        settings_row.main_cash_safe_box_id = None
        settings_row.sale_gold_safe_box_id = None
        settings_row.main_scrap_gold_safe_box_id = None
        settings_row.payment_methods = '[]'
        try:
            settings_row.disable_startup_bootstrap = True
        except Exception:
            # Column may not exist on legacy DBs until schema_guard runs.
            pass

    _step('Detach Settings -> SafeBox', _detach_settings_refs, required=False)

    _step('Detach Employee -> SafeBox', lambda: db.session.query(Employee).update({
        Employee.gold_safe_box_id: None,
        Employee.cash_safe_box_id: None,
    }, synchronize_session=False), required=False)

    _step('Detach AppUser -> Employee', lambda: db.session.query(AppUser).update({
        AppUser.employee_id: None,
    }, synchronize_session=False), required=False)

    # Delete SafeBoxes now (SafeBox.account_id blocks Account deletion)
    _step('Delete SafeBox', lambda: SafeBox.query.delete())

    # Now delete parties + structure
    _step('Delete Customer', lambda: Customer.query.delete())
    _step('Delete Supplier', lambda: Supplier.query.delete())

    _step('Delete Employee', lambda: Employee.query.delete())
    _step('Delete User (non-admin)', lambda: User.query.filter(User.is_admin.is_(False)).delete(synchronize_session=False), required=False)
    _step('Delete AppUser (non-system_admin)', lambda: AppUser.query.filter(func.lower(AppUser.role) != 'system_admin').delete(synchronize_session=False), required=False)

    _step('Delete Branch', lambda: Branch.query.delete())
    _step('Delete Office', lambda: Office.query.delete())

    # 4) Chart of accounts
    _step('Delete AccountingMapping', lambda: AccountingMapping.query.delete())
    _step('Detach Account self-references', lambda: db.session.query(Account).update({
        Account.parent_id: None,
        Account.memo_account_id: None,
    }, synchronize_session=False), required=False)
    _step('Delete Account', lambda: Account.query.delete())

    def _verify_post_wipe_counts() -> None:
        # Ensure all counts used by /system/reset/info are actually cleared.
        remaining = {
            'safe_box_transactions': SafeBoxTransaction.query.count(),
            'system_alerts': SystemAlert.query.count(),
            'audit_logs': AuditLog.query.count(),
            'weight_closing_logs': WeightClosingLog.query.count(),
            'office_reservations': OfficeReservation.query.count(),
            'payroll_entries': Payroll.query.count(),
            'attendance_records': Attendance.query.count(),
            'employee_bonuses': EmployeeBonus.query.count(),
            'bonus_invoice_links': BonusInvoiceLink.query.count(),
            'weight_closing_orders': WeightClosingOrder.query.count(),
            'weight_closing_executions': WeightClosingExecution.query.count(),
            'invoice_weight_settlements': InvoiceWeightSettlement.query.count(),
            'customers': Customer.query.count(),
            'suppliers': Supplier.query.count(),
            'items': Item.query.count(),
            'categories': Category.query.count(),
            'gold_prices': GoldPrice.query.count(),
            'payment_methods': PaymentMethod.query.count(),
            'safe_boxes': SafeBox.query.count(),
            'employees': Employee.query.count(),
            'branches': Branch.query.count(),
            'offices': Office.query.count(),
            'accounting_mappings': AccountingMapping.query.count(),
            'accounts': Account.query.count(),
            'bonus_rules': BonusRule.query.count(),
        }

        not_empty = {k: v for k, v in remaining.items() if int(v or 0) != 0}
        if not_empty:
            raise Exception(f"Post-wipe verification failed; remaining rows: {not_empty}")

    _step('Verify post-wipe counts are zero', _verify_post_wipe_counts)

    try:
        db.session.commit()
    except Exception as e:
        db.session.rollback()
        raise e

def _reset_settings():
    """إعادة تعيين الإعدادات للقيم الافتراضية"""
    try:
        # حذف الإعدادات الحالية
        Settings.query.delete()
        
        # إنشاء إعدادات جديدة بالقيم الافتراضية
        default_settings = Settings(
            main_karat=21,
            currency_symbol='ريال',
            tax_rate=0.0,
            tax_enabled=False,
            invoice_prefix='INV-',
            decimal_places=3,
            date_format='yyyy-MM-dd',
            default_discount_rate=0.0,
            allow_discount=True,
            show_company_logo=False,
            company_name='مجوهرات خالد',
            company_address='',
            company_phone='',
            company_tax_number=''
        )
        
        db.session.add(default_settings)
        db.session.commit()
        
    except Exception as e:
        db.session.rollback()
        raise e

@system_bp.route('/system/reset/info', methods=['GET'])
@require_permission('system.settings')
def get_reset_info():
    """
    الحصول على معلومات عن البيانات الحالية في النظام
    
    Returns:
    - counts: عدد السجلات في كل جدول
    """
    try:
        from models import AppUser, AuditLog, Branch, SafeBoxTransaction, SystemAlert, WeightClosingLog
        def _is_production_env() -> bool:
            env = (
                os.getenv('YASAR_ENV')
                or os.getenv('APP_ENV')
                or os.getenv('ENV')
                or os.getenv('FLASK_ENV')
                or ''
            )
            return str(env).strip().lower() in {'prod', 'production'}

        def _dangerous_resets_allowed() -> bool:
            val = os.getenv('ALLOW_DANGEROUS_RESETS')
            return str(val or '').strip().lower() in {'1', 'true', 'yes', 'y', 'on'}

        info = {
            'safety': {
                'production_lock': _is_production_env() and not _dangerous_resets_allowed(),
                'is_production': _is_production_env(),
                'dangerous_resets_allowed': _dangerous_resets_allowed(),
            },
            'transactions': {
                'journal_entries': JournalEntry.query.count(),
                'journal_entry_lines': JournalEntryLine.query.count(),
                'invoices': Invoice.query.count(),
                'invoice_items': InvoiceItem.query.count(),
                'invoice_karat_lines': InvoiceKaratLine.query.count(),
                'invoice_payments': InvoicePayment.query.count(),
                'vouchers': Voucher.query.count(),
                'voucher_lines': VoucherAccountLine.query.count(),
                'employee_bonuses': EmployeeBonus.query.count(),
                'bonus_invoice_links': BonusInvoiceLink.query.count(),
                'payroll_entries': Payroll.query.count(),
                'attendance_records': Attendance.query.count(),
                'office_reservations': OfficeReservation.query.count(),
                'weight_closing_orders': WeightClosingOrder.query.count(),
                'weight_closing_executions': WeightClosingExecution.query.count(),
                'safe_box_transactions': SafeBoxTransaction.query.count(),
                'system_alerts': SystemAlert.query.count(),
                'audit_logs': AuditLog.query.count(),
                'weight_closing_logs': WeightClosingLog.query.count(),
            },
            'customers_suppliers': {
                'customers': Customer.query.count(),
                'suppliers': Supplier.query.count(),
            },
            'master_data': {
                'accounts': Account.query.count(),
                'items': Item.query.count(),
                'gold_prices': GoldPrice.query.count(),
                'payment_methods': PaymentMethod.query.count(),
                'safe_boxes': SafeBox.query.count(),
                'employees': Employee.query.count(),
                'app_users': AppUser.query.count(),
                'users': User.query.count(),
                'branches': Branch.query.count(),
                'offices': Office.query.count(),
                'accounting_mappings': AccountingMapping.query.count(),
                'bonus_rules': BonusRule.query.count(),
            },
            'settings': {
                'has_settings': Settings.query.count() > 0,
            }
        }
        
        return jsonify({
            'status': 'success',
            'data': info
        }), 200
        
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

@system_bp.route('/system/backup/download', methods=['GET'])
@require_permission('system.settings')
def system_backup_download():
    """Download a system backup as a ZIP file.
    Supports SQLite and PostgreSQL.
    """

    if not (_is_sqlite_database() or _is_postgres_database()):
        return jsonify({
            'status': 'error',
            'message': 'نوع قاعدة البيانات الحالية غير مدعوم للنسخ الاحتياطي من داخل الواجهة.',
            'error': 'not_supported',
            'db': (db.engine.url.get_backend_name() if db.engine else None),
        }), 501

    created_at = datetime.now().strftime('%Y%m%d-%H%M%S')
    filename = f'yasargold-backup-{created_at}.zip'

    with tempfile.TemporaryDirectory(prefix='yasargold-backup-') as tmpdir:
        if _is_postgres_database():
            db_path = os.path.join(tmpdir, 'database.dump')
            try:
                _create_postgres_backup_to_file(db_path)
            except Exception as exc:
                return jsonify({
                    'status': 'error',
                    'message': f'فشل إنشاء نسخة PostgreSQL: {exc}',
                    'error': 'backup_failed',
                }), 500

            meta = {
                'created_at_utc': datetime.now().isoformat() + 'Z',
                'db_backend': 'postgres',
                'format': 'pg_dump_custom',
            }
            archive_name = 'database.dump'
        else:
            db_path = os.path.join(tmpdir, 'database.sqlite')
            _create_sqlite_backup_to_file(db_path)

            meta = {
                'created_at_utc': datetime.now().isoformat() + 'Z',
                'db_backend': 'sqlite',
            }
            archive_name = 'database.sqlite'
        meta_path = os.path.join(tmpdir, 'metadata.json')
        with open(meta_path, 'w', encoding='utf-8') as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)

        zip_path = os.path.join(tmpdir, filename)
        with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
            zf.write(db_path, arcname=archive_name)
            zf.write(meta_path, arcname='metadata.json')

        with open(zip_path, 'rb') as f:
            data = f.read()

    return send_file(
        io.BytesIO(data),
        mimetype='application/zip',
        as_attachment=True,
        download_name=filename,
    )

def _drive_sa_available() -> bool:
    # Minimal check; actual validation happens in the service module.
    if (os.getenv('GOOGLE_DRIVE_BACKUP_FOLDER_ID') or '').strip() == '':
        return False
    if (os.getenv('GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON') or '').strip():
        return True
    if (os.getenv('GOOGLE_DRIVE_SERVICE_ACCOUNT_FILE') or '').strip():
        return True
    return False

def _drive_user_facing_error(exc: Exception) -> str:
    """Return a concise Arabic message for common Google Drive errors.

    In production, googleapiclient HttpError messages can be extremely verbose.
    This helper keeps UI output readable and actionable.
    """

    try:
        # Only import when available.
        from googleapiclient.errors import HttpError  # type: ignore
    except Exception:
        HttpError = None  # type: ignore

    # Best-effort parsing of HttpError JSON payload.
    if HttpError is not None and isinstance(exc, HttpError):
        try:
            raw = getattr(exc, "content", None)
            if isinstance(raw, (bytes, bytearray)):
                raw = raw.decode("utf-8", errors="ignore")
            payload = json.loads(raw) if isinstance(raw, str) and raw.strip() else {}
            err = payload.get("error") if isinstance(payload, dict) else None
            message = (err.get("message") if isinstance(err, dict) else None) or ""
            errors = (err.get("errors") if isinstance(err, dict) else None) or []
            reason = ""
            if isinstance(errors, list) and errors:
                first = errors[0] if isinstance(errors[0], dict) else {}
                reason = (first.get("reason") or "") if isinstance(first, dict) else ""

            # Common production blocker: Service Accounts have no personal Drive quota.
            if reason == "storageQuotaExceeded" or ("Service Accounts do not have storage quota" in message):
                return (
                    "فشل رفع النسخة إلى Google Drive: حساب الخدمة (Service Account) لا يملك سعة تخزين على Google Drive. "
                    "الحلول: استخدم Google Workspace Shared Drive وضمّ الحساب له، أو فعّل Domain-wide Delegation وحدد GOOGLE_DRIVE_IMPERSONATE_USER، "
                    "أو استخدم طريقة OAuth/Rclone (Option D)."
                )

            if message:
                return f"فشل عملية Google Drive: {message}"
        except Exception:
            # Fall through to generic error.
            pass

    # Default fallback.
    return f"فشل عملية Google Drive: {exc}"

@system_bp.route('/system/backup/drive/status', methods=['GET'])
@require_any_permission('system.backup', 'system.settings')
def system_backup_drive_status():
    """Return whether server-side Google Drive backups are configured."""
    return jsonify({
        'enabled': bool(_drive_sa_available()),
        'folder_id_set': bool((os.getenv('GOOGLE_DRIVE_BACKUP_FOLDER_ID') or '').strip()),
        'sa_json_set': bool((os.getenv('GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON') or '').strip()),
        'sa_file_set': bool((os.getenv('GOOGLE_DRIVE_SERVICE_ACCOUNT_FILE') or '').strip()),
    })

@system_bp.route('/system/backup/drive/upload', methods=['POST'])
@require_any_permission('system.backup', 'system.settings')
def system_backup_drive_upload():
    """Create a fresh system backup ZIP on the server and upload it to Google Drive.

    Uses a Google Service Account configured via env vars.
    """
    if not _drive_sa_available():
        return jsonify({
            'status': 'error',
            'error': 'drive_not_configured',
            'message': (
                'Google Drive (Service Account) غير مُعد على السيرفر. '
                'اضبط GOOGLE_DRIVE_BACKUP_FOLDER_ID و GOOGLE_DRIVE_SERVICE_ACCOUNT_FILE/JSON.'
            ),
        }), 400

    if not (_is_sqlite_database() or _is_postgres_database()):
        return jsonify({
            'status': 'error',
            'message': 'نوع قاعدة البيانات الحالية غير مدعوم للنسخ الاحتياطي.',
            'error': 'not_supported',
            'db': (db.engine.url.get_backend_name() if db.engine else None),
        }), 501

    try:
        from google_drive_service_account import upload_bytes
    except Exception as exc:
        return jsonify({
            'status': 'error',
            'error': 'drive_dependency_missing',
            'message': f'تعذر تحميل مكتبات Google Drive على السيرفر: {exc}',
        }), 500

    created_at = datetime.now().strftime('%Y%m%d-%H%M%S')
    filename = f'yasargold-backup-{created_at}.zip'

    with tempfile.TemporaryDirectory(prefix='yasargold-backup-') as tmpdir:
        if _is_postgres_database():
            db_path = os.path.join(tmpdir, 'database.dump')
            try:
                _create_postgres_backup_to_file(db_path)
            except Exception as exc:
                return jsonify({
                    'status': 'error',
                    'message': f'فشل إنشاء نسخة PostgreSQL: {exc}',
                    'error': 'backup_failed',
                }), 500

            meta = {
                'created_at_utc': datetime.now().isoformat() + 'Z',
                'db_backend': 'postgres',
                'format': 'pg_dump_custom',
            }
            archive_name = 'database.dump'
        else:
            db_path = os.path.join(tmpdir, 'database.sqlite')
            _create_sqlite_backup_to_file(db_path)

            meta = {
                'created_at_utc': datetime.now().isoformat() + 'Z',
                'db_backend': 'sqlite',
            }
            archive_name = 'database.sqlite'

        meta_path = os.path.join(tmpdir, 'metadata.json')
        with open(meta_path, 'w', encoding='utf-8') as f:
            json.dump(meta, f, ensure_ascii=False, indent=2)

        zip_path = os.path.join(tmpdir, filename)
        with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
            zf.write(db_path, arcname=archive_name)
            zf.write(meta_path, arcname='metadata.json')

        with open(zip_path, 'rb') as f:
            data = f.read()

    try:
        info = upload_bytes(filename=filename, content=data, mime_type='application/zip')
    except Exception as exc:
        return jsonify({
            'status': 'error',
            'error': 'drive_upload_failed',
            'message': _drive_user_facing_error(exc),
        }), 500

    return jsonify({
        'status': 'success',
        'message': 'تم رفع النسخة إلى Google Drive (Service Account).',
        'file': {
            'id': info.id,
            'name': info.name,
            'mimeType': info.mimeType,
            'createdTime': info.createdTime,
            'size': info.size,
        },
    })

@system_bp.route('/system/backup/drive/list', methods=['GET'])
@require_any_permission('system.backup', 'system.settings')
def system_backup_drive_list():
    if not _drive_sa_available():
        return jsonify({
            'status': 'error',
            'error': 'drive_not_configured',
            'message': 'Google Drive (Service Account) غير مُعد على السيرفر.',
        }), 400

    try:
        from google_drive_service_account import list_backups
        files = list_backups(page_size=int(request.args.get('page_size') or 20))
    except Exception as exc:
        return jsonify({
            'status': 'error',
            'error': 'drive_list_failed',
            'message': _drive_user_facing_error(exc),
        }), 500

    return jsonify({
        'status': 'success',
        'files': [
            {
                'id': f.id,
                'name': f.name,
                'mimeType': f.mimeType,
                'createdTime': f.createdTime,
                'size': f.size,
            }
            for f in files
        ],
    })

@system_bp.route('/system/backup/drive/download/<string:file_id>', methods=['GET'])
@require_any_permission('system.backup', 'system.settings')
def system_backup_drive_download(file_id: str):
    if not _drive_sa_available():
        return jsonify({
            'status': 'error',
            'error': 'drive_not_configured',
            'message': 'Google Drive (Service Account) غير مُعد على السيرفر.',
        }), 400

    try:
        from google_drive_service_account import download_bytes
        data, info = download_bytes(file_id)
    except Exception as exc:
        return jsonify({
            'status': 'error',
            'error': 'drive_download_failed',
            'message': _drive_user_facing_error(exc),
        }), 500

    name = (info.name or f'{file_id}.zip').strip() or f'{file_id}.zip'
    return send_file(
        io.BytesIO(data),
        mimetype=(info.mimeType or 'application/octet-stream'),
        as_attachment=True,
        download_name=name,
    )

@system_bp.route('/system/backup/restore', methods=['POST'])
@require_permission('system.settings')
def system_backup_restore():
    """Restore a system backup from an uploaded ZIP.

    Safety:
    - Blocked in production unless ALLOW_DANGEROUS_RESETS=true.
    - Requires confirm=RESTORE in form data.
    """

    def _is_production_env() -> bool:
        env = (
            os.getenv('YASAR_ENV')
            or os.getenv('APP_ENV')
            or os.getenv('ENV')
            or os.getenv('FLASK_ENV')
            or ''
        )
        return str(env).strip().lower() in {'prod', 'production'}

    def _dangerous_actions_allowed() -> bool:
        val = os.getenv('ALLOW_DANGEROUS_RESETS')
        return str(val or '').strip().lower() in {'1', 'true', 'yes', 'y', 'on'}

    if _is_production_env() and not _dangerous_actions_allowed():
        _append_restore_audit(
            event='system_backup_restore_blocked',
            success=False,
            details={
                'reason': 'production_lock',
                'is_production': True,
                'dangerous_resets_allowed': False,
            },
        )
        return jsonify({
            'status': 'error',
            'message': (
                'هذا الإجراء مقفّل على نسخة الإنتاج (Production Lock). '
                'فعّل ALLOW_DANGEROUS_RESETS=true إذا كنت متأكدًا.'
            ),
            'error': 'production_lock',
        }), 403

    confirm = (request.form.get('confirm') or '').strip()
    if confirm != 'RESTORE':
        _append_restore_audit(
            event='system_backup_restore_rejected',
            success=False,
            details={
                'reason': 'invalid_confirm',
                'confirm': confirm,
            },
        )
        return jsonify({
            'status': 'error',
            'message': 'تأكيد غير صحيح. ارسل confirm=RESTORE لتنفيذ الاستعادة.',
        }), 400

    uploaded = request.files.get('file')
    if uploaded is None:
        _append_restore_audit(
            event='system_backup_restore_rejected',
            success=False,
            details={
                'reason': 'missing_file',
            },
        )
        return jsonify({
            'status': 'error',
            'message': 'الملف مطلوب (multipart field name: file)',
        }), 400

    if not _is_sqlite_database():
        if not _is_postgres_database():
            _append_restore_audit(
                event='system_backup_restore_rejected',
                success=False,
                details={
                    'reason': 'not_supported',
                    'db': (db.engine.url.get_backend_name() if db.engine else None),
                },
            )
            return jsonify({
                'status': 'error',
                'message': 'نوع قاعدة البيانات الحالية غير مدعوم للاستعادة من داخل الواجهة.',
                'error': 'not_supported',
            }), 501

    with tempfile.TemporaryDirectory(prefix='yasargold-restore-') as tmpdir:
        zip_path = os.path.join(tmpdir, 'upload.zip')
        uploaded.save(zip_path)

        try:
            with zipfile.ZipFile(zip_path, 'r') as zf:
                if _is_postgres_database():
                    candidates = [
                        'database.dump',
                        'database.backup',
                        'database.sql',
                    ]
                else:
                    candidates = [
                        'database.sqlite',
                        'app.db',
                        'app.sqlite',
                    ]
                member = None
                for c in candidates:
                    if c in zf.namelist():
                        member = c
                        break
                if member is None:
                    return jsonify({
                        'status': 'error',
                        'message': 'لم يتم العثور على ملف قاعدة البيانات داخل ملف النسخة الاحتياطية.',
                        'error': 'invalid_backup',
                    }), 400

                extracted_ext = os.path.splitext(member)[1].lower()
                extracted_path = os.path.join(
                    tmpdir,
                    'restored' + (extracted_ext if extracted_ext else ''),
                )
                with zf.open(member) as src, open(extracted_path, 'wb') as dst:
                    dst.write(src.read())
        except zipfile.BadZipFile:
            _append_restore_audit(
                event='system_backup_restore_failed',
                success=False,
                details={
                    'reason': 'invalid_zip',
                    'filename': getattr(uploaded, 'filename', None),
                },
            )
            return jsonify({
                'status': 'error',
                'message': 'ملف النسخة الاحتياطية غير صالح (ليس ZIP).',
                'error': 'invalid_zip',
            }), 400

        # Mandatory: create a pre-restore snapshot on the server file system.
        try:
            snapshot_path = _create_pre_restore_snapshot_zip()
            _append_restore_audit(
                event='system_backup_restore_snapshot_created',
                success=True,
                details={
                    'snapshot': snapshot_path,
                    'filename': getattr(uploaded, 'filename', None),
                },
            )
        except Exception as exc:
            _append_restore_audit(
                event='system_backup_restore_failed',
                success=False,
                details={
                    'reason': 'snapshot_failed',
                    'error': str(exc),
                    'filename': getattr(uploaded, 'filename', None),
                },
            )
            return jsonify({
                'status': 'error',
                'message': 'تعذر أخذ نسخة طوارئ (Snapshot) قبل الاستعادة. تم إيقاف العملية للحماية.',
                'error': 'snapshot_failed',
            }), 500

        try:
            if _is_postgres_database():
                _restore_postgres_from_backup_file(extracted_path)
            else:
                _restore_sqlite_from_backup_file(extracted_path)
        except Exception as exc:
            try:
                db.session.rollback()
            except Exception:
                pass

            _append_restore_audit(
                event='system_backup_restore_failed',
                success=False,
                details={
                    'reason': 'restore_failed',
                    'error': str(exc),
                    'filename': getattr(uploaded, 'filename', None),
                },
            )
            return jsonify({
                'status': 'error',
                'message': f'فشل الاستعادة: {exc}',
                'error': 'restore_failed',
            }), 500

    _append_restore_audit(
        event='system_backup_restore_success',
        success=True,
        details={
            'filename': getattr(uploaded, 'filename', None),
        },
    )

    return jsonify({
        'status': 'success',
        'message': 'تمت الاستعادة بنجاح. قد تحتاج لإعادة تشغيل التطبيق/الخادم لتحديث البيانات.',
    })

@system_bp.route('/statements/qr-sign', methods=['POST'])
@_wrap_api_exceptions('statement_qr_sign_failed', 'Failed to sign statement QR payload')
def sign_statement_qr_payload():
    """Sign a provided QR payload using the server-side secret.

    Request:
      {"signed": { ... }}

    Response:
      {"algo":"HS256","signature":"..."}
    """
    data = request.get_json(silent=True) or {}
    signed = data.get('signed')
    if not isinstance(signed, dict) or not signed:
        return jsonify({'error': 'invalid_payload'}), 400

    sig = _sign_qr_payload(signed)
    if not sig:
        return jsonify({'error': 'qr_signature_disabled'}), 400

    return jsonify({'algo': 'HS256', 'signature': sig})

def _rebuild_all_account_balances() -> dict:
    """Rebuild stored Account balances from journal + voucher lines.

    This is intended as an operational repair tool when DB was migrated/restored
    and stored balances were not backfilled.
    """

    # 1) Reset all balances.
    db.session.query(Account).update({
        Account.balance_cash: 0.0,
        Account.balance_18k: 0.0,
        Account.balance_21k: 0.0,
        Account.balance_22k: 0.0,
        Account.balance_24k: 0.0,
    }, synchronize_session=False)

    # 2) Aggregate journal deltas.
    jl_filters = [
        JournalEntry.is_deleted == False,
        JournalEntryLine.is_deleted == False,
    ]
    if _db_has_column('journal_entry', 'is_posted'):
        jl_filters.append(JournalEntry.is_posted == True)
    if _db_has_column('journal_entry', 'is_draft'):
        jl_filters.append(JournalEntry.is_draft == False)

    journal_rows = (
        db.session.query(
            JournalEntryLine.account_id.label('account_id'),
            (func.coalesce(func.sum(JournalEntryLine.cash_debit), 0.0) - func.coalesce(func.sum(JournalEntryLine.cash_credit), 0.0)).label('cash'),
            (func.coalesce(func.sum(JournalEntryLine.debit_18k), 0.0) - func.coalesce(func.sum(JournalEntryLine.credit_18k), 0.0)).label('b18'),
            (func.coalesce(func.sum(JournalEntryLine.debit_21k), 0.0) - func.coalesce(func.sum(JournalEntryLine.credit_21k), 0.0)).label('b21'),
            (func.coalesce(func.sum(JournalEntryLine.debit_22k), 0.0) - func.coalesce(func.sum(JournalEntryLine.credit_22k), 0.0)).label('b22'),
            (func.coalesce(func.sum(JournalEntryLine.debit_24k), 0.0) - func.coalesce(func.sum(JournalEntryLine.credit_24k), 0.0)).label('b24'),
        )
        .join(JournalEntry)
        .filter(*jl_filters)
        .group_by(JournalEntryLine.account_id)
        .all()
    )

    # Note: deliberately NOT adding VoucherAccountLine amounts here.
    # Approved vouchers already get an automatic journal entry whose lines
    # are counted via journal_rows above, so summing voucher lines too would
    # double-count their cash effect. Keeping balance_cash derived purely
    # from journal lines also keeps it consistent with the account statement
    # (كشف الحساب), which is computed the same way.

    # 3) Apply updates (bulk).
    updates: list[dict] = []
    for r in journal_rows:
        acc_id = int(r.account_id)
        updates.append({
            'id': acc_id,
            'balance_cash': float(r.cash or 0.0),
            'balance_18k': float(r.b18 or 0.0),
            'balance_21k': float(r.b21 or 0.0),
            'balance_22k': float(r.b22 or 0.0),
            'balance_24k': float(r.b24 or 0.0),
        })

    if updates:
        db.session.bulk_update_mappings(Account, updates)

    db.session.commit()

    return {
        'updated_accounts': len(updates),
        'journal_accounts': len(journal_rows),
        'used_is_draft_filter': _db_has_column('journal_entry', 'is_draft'),
    }

@system_bp.route('/system/rebuild-account-balances', methods=['POST'])
@require_permission('system.settings')
def system_rebuild_account_balances():
    """Admin: rebuild stored account balances from transactions."""
    stats = _rebuild_all_account_balances()
    return jsonify({
        'status': 'success',
        'message': 'Rebuilt account balances',
        **stats,
    })

@system_bp.route('/add-bank-info-to-accounts', methods=['POST'])
@require_permission('system.settings')
def add_bank_info_to_accounts():
    """
    إضافة معلومات البنوك إلى الحسابات الموجودة
    """
    try:
        updates = [
            {
                'account_number': '1112.1',
                'bank_name': 'بنك الرياض',
                'account_type': 'bank_account',
                'account_number_external': 'يرجى تحديث رقم الحساب'
            },
            {
                'account_number': '1112.2',
                'bank_name': 'بنك الراجحي',
                'account_type': 'bank_account',
                'account_number_external': 'يرجى تحديث رقم الحساب'
            },
            {
                'account_number': '1112.3',
                'bank_name': 'بنك الراجحي',
                'account_type': 'bank_account',
                'account_number_external': 'يرجى تحديث رقم الحساب'
            },
            {
                'account_number': '1112.4',
                'bank_name': 'STC Pay',
                'account_type': 'digital_wallet',
                'account_number_external': 'يرجى تحديث رقم المحفظة'
            },
            {
                'account_number': '1112.5',
                'bank_name': 'Apple',
                'account_type': 'digital_wallet',
                'account_number_external': 'يرجى تحديث معلومات Apple Pay'
            },
            {
                'account_number': '1115',
                'bank_name': 'تابي (Tabby)',
                'account_type': 'bnpl',
                'account_number_external': 'رقم التاجر: يرجى التحديث'
            },
            {
                'account_number': '1116',
                'bank_name': 'تمارا (Tamara)',
                'account_type': 'bnpl',
                'account_number_external': 'رقم التاجر: يرجى التحديث'
            },
            {
                'account_number': '1111',
                'bank_name': None,
                'account_type': 'cash',
                'account_number_external': None
            },
        ]
        
        updated_accounts = []
        for update_data in updates:
            account = Account.query.filter_by(account_number=update_data['account_number']).first()
            if account:
                account.bank_name = update_data['bank_name']
                account.account_type = update_data['account_type']
                account.account_number_external = update_data['account_number_external']
                updated_accounts.append({
                    'account_number': account.account_number,
                    'name': account.name,
                    'bank_name': account.bank_name,
                    'account_type': account.account_type
                })
        
        db.session.commit()
        
        return jsonify({
            'status': 'success',
            'message': 'تم تحديث معلومات البنوك بنجاح',
            'updated_count': len(updated_accounts),
            'accounts': updated_accounts
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500

@system_bp.route('/app-config', methods=['GET'])
@require_permission('vouchers.view')
def get_app_config():
    """Return small configuration payload needed by client screens.

    This endpoint is intentionally lightweight and safe for non-admin users.
    It exposes only the aggregate accounts used by vouchers as a fallback when
    a party (customer/supplier) has no dedicated account linked.
    """
    try:
        from models import Settings, AccountingMapping, Account

        settings = Settings.query.first()

        def _account_payload(account: Account | None):
            if not account:
                return None
            return {
                'account_id': account.id,
                'account_number': account.account_number,
                'name': account.name,
            }

        def _resolve_aggregate(account_type: str, fallback_numbers: list[str]):
            # Prefer explicit mapping under operation_type='سندات'
            mapping = AccountingMapping.query.filter_by(
                operation_type='سندات',
                account_type=account_type,
                is_active=True,
            ).first()
            if mapping and mapping.account:
                return _account_payload(mapping.account)

            # Fallback to well-known account numbers (supports different charts)
            for num in fallback_numbers:
                acc = Account.query.filter_by(account_number=str(num)).first()
                if acc:
                    return _account_payload(acc)

            return None

        customers_agg = _resolve_aggregate('customers', ['1100', '1110', '1120'])
        suppliers_agg = _resolve_aggregate('suppliers', ['220', '211'])

        return jsonify({
            'main_karat': int(getattr(settings, 'main_karat', 21) or 21) if settings else 21,
            'currency_symbol': getattr(settings, 'currency_symbol', 'ر.س') if settings else 'ر.س',
            'aggregate_accounts': {
                'customers': customers_agg,
                'suppliers': suppliers_agg,
            },
        }), 200

    except Exception as e:
        return jsonify({'error': str(e)}), 500

@system_bp.route('/melting-renewal', methods=['POST'])
@require_permission('safe_boxes.edit')
def create_melting_renewal():
    """تسجيل عملية تكسير أو تجديد.

    Body JSON:
        operation_type : str   — 'melting' | 'renewal'
        from_safe_box_id : int — الخزينة المصدر (للتكسير: خزينة الذهب المعروض)
        to_safe_box_id   : int — الخزينة الوجهة  (للتكسير: صندوق الكسر)
        from_karat       : int — عيار الذهب المكسَّر  (18|21|22|24)
        to_karat         : int — عيار الذهب الناتج   (18|21|22|24)  [اختياري ← يساوي from_karat إن لم يُحدَّد]
        gold_weight      : float — وزن الذهب (جم)
        stones_weight    : float — وزن الفصوص (جم)  [اختياري]
        stones_revenue_account_id  : int — حساب إيراد الفصوص الداخلة  [اختياري]
        stones_expense_account_id  : int — حساب مصروف الفصوص الخارجة [اختياري]
        damage_wage_weight         : float — مبلغ المصنعية التالفة (نقد) [اختياري، تكسير فقط]
        damage_wage_account_id     : int   — حساب مصروف المصنعية التالفة [اختياري، تكسير فقط]
        notes            : str — ملاحظات       [اختياري]
    """
    data = request.get_json(silent=True) or {}

    operation_type = (data.get('operation_type') or '').strip().lower()
    if operation_type not in ('melting', 'renewal'):
        return jsonify({'error': 'invalid_operation_type', 'allowed': ['melting', 'renewal']}), 400

    _valid_karats = {18, 21, 22, 24}

    try:
        from_safe_id = int(data['from_safe_box_id'])
        to_safe_id   = int(data['to_safe_box_id'])
    except (KeyError, TypeError, ValueError):
        return jsonify({'error': 'missing_safe_box_ids'}), 400

    try:
        from_karat = int(data.get('from_karat', 21))
        to_karat   = int(data.get('to_karat') or from_karat)
    except (TypeError, ValueError):
        return jsonify({'error': 'invalid_karat'}), 400

    if from_karat not in _valid_karats or to_karat not in _valid_karats:
        return jsonify({'error': 'invalid_karat', 'allowed': list(_valid_karats)}), 400

    try:
        gold_weight        = float(data.get('gold_weight') or 0)
        stones_weight      = float(data.get('stones_weight') or 0)
        damage_wage_amount = float(data.get('damage_wage_amount') or data.get('damage_wage_weight') or 0)
    except (TypeError, ValueError):
        return jsonify({'error': 'invalid_weight'}), 400

    if gold_weight <= 0:
        return jsonify({'error': 'invalid_gold_weight'}), 400

    stones_rev_account_id  = data.get('stones_revenue_account_id')
    stones_exp_account_id  = data.get('stones_expense_account_id')
    damage_wage_account_id = data.get('damage_wage_account_id')
    try:
        if stones_rev_account_id:
            stones_rev_account_id = int(stones_rev_account_id)
        if stones_exp_account_id:
            stones_exp_account_id = int(stones_exp_account_id)
        if damage_wage_account_id:
            damage_wage_account_id = int(damage_wage_account_id)
    except (TypeError, ValueError):
        return jsonify({'error': 'invalid_account_id'}), 400

    notes = (data.get('notes') or '').strip() or None

    # Validate safe boxes + available balance
    try:
        from_safe = SafeBox.query.filter_by(id=from_safe_id).first()
        to_safe   = SafeBox.query.filter_by(id=to_safe_id).first()
        if not from_safe:
            return jsonify({'error': 'from_safe_not_found'}), 404
        if not to_safe:
            return jsonify({'error': 'to_safe_not_found'}), 404
        if from_safe_id == to_safe_id:
            return jsonify({'error': 'same_safe_box'}), 400

        from_col  = f'weight_{from_karat}k'
        q_src = SafeBoxTransaction.query.filter_by(safe_box_id=from_safe_id)
        col_a = getattr(SafeBoxTransaction, from_col)
        w_in  = float(q_src.with_entities(func.coalesce(func.sum(col_a), 0.0))
                           .filter(SafeBoxTransaction.direction == 'in').scalar() or 0.0)
        w_out = float(q_src.with_entities(func.coalesce(func.sum(col_a), 0.0))
                           .filter(SafeBoxTransaction.direction == 'out').scalar() or 0.0)
        available = round(w_in - w_out, 6)

        if gold_weight > available + 1e-6:
            return jsonify({
                'error': 'insufficient_balance',
                'karat': from_karat,
                'available': round(available, 3),
            }), 400

        # تحقق من رصيد الفصوص إذا أُدخل وزن فصوص
        if stones_weight > 0:
            s_in  = float(q_src.with_entities(
                func.coalesce(func.sum(SafeBoxTransaction.stones_weight), 0.0))
                .filter(SafeBoxTransaction.direction == 'in').scalar() or 0.0)
            s_out = float(q_src.with_entities(
                func.coalesce(func.sum(SafeBoxTransaction.stones_weight), 0.0))
                .filter(SafeBoxTransaction.direction == 'out').scalar() or 0.0)
            stones_available = round(s_in - s_out, 6)
            if stones_weight > stones_available + 1e-6:
                return jsonify({
                    'error': 'insufficient_stones_balance',
                    'message': f'وزن الفصوص المطلوب ({stones_weight:.3f} جم) يتجاوز الرصيد المتاح ({stones_available:.3f} جم)',
                    'stones_available': round(stones_available, 3),
                }), 400

        created_by = getattr(getattr(g, 'current_user', None), 'username', None) or 'system'

        # Optional: validate stones accounts exist
        if stones_rev_account_id:
            if not Account.query.get(stones_rev_account_id):
                return jsonify({'error': 'stones_revenue_account_not_found'}), 404
        if stones_exp_account_id:
            if not Account.query.get(stones_exp_account_id):
                return jsonify({'error': 'stones_expense_account_not_found'}), 404
        if damage_wage_account_id:
            if not Account.query.get(damage_wage_account_id):
                return jsonify({'error': 'damage_wage_account_not_found'}), 404

    except Exception as pre_err:
        import traceback; traceback.print_exc()
        return jsonify({'error': 'pre_validation_failed', 'message': str(pre_err)}), 500

    try:
        op_label = 'تكسير' if operation_type == 'melting' else 'تجديد'
        voucher_dt     = datetime.now()
        voucher_number = generate_voucher_number('adjustment', voucher_date=voucher_dt)

        desc_parts = [
            f'{op_label}: {gold_weight:.3f} جم {from_karat}k',
            f'من: {from_safe.name}',
            f'إلى: {to_safe.name}',
        ]
        if stones_weight > 0:
            desc_parts.append(f'فصوص: {stones_weight:.3f} جم')
        if damage_wage_amount > 0 and operation_type == 'melting':
            desc_parts.append(f'مصنعية تالفة: {damage_wage_amount:.2f}')

        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type='adjustment',
            date=voucher_dt,
            description=' | '.join(desc_parts),
            amount_cash=0.0,
            amount_gold=round(gold_weight, 4),
            reference_type='manual',
            notes=notes,
            created_by=created_by,
            status='pending',
        )
        db.session.add(voucher)
        db.session.flush()

        # قيد ذهبي: دائن خزينة المصدر، مدين خزينة الوجهة
        for lt, acct_id, karat_val in (
            ('credit', from_safe.account_id, float(from_karat)),
            ('debit',  to_safe.account_id,   float(to_karat)),
        ):
            db.session.add(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=acct_id,
                line_type=lt,
                amount_type='gold',
                amount=gold_weight,
                karat=karat_val,
            ))

        # ─── قيد الفصوص عند التجديد فقط ───
        # مدين:  حساب أصول الفصوص  (الفصوص تُسجَّل كأصل)
        # دائن:  حساب إيراد الفصوص  (إيراد يُعترف به عند التجديد)
        _stones_je_warning = None
        if operation_type == 'renewal' and stones_weight > 0:
            _s = Settings.query.first()
            _stones_asset_acc   = getattr(_s, 'stones_pending_account_id', None) if _s else None
            _stones_revenue_acc = getattr(_s, 'stones_display_revenue_account_id', None) if _s else None
            if not _stones_asset_acc or not _stones_revenue_acc:
                _stones_je_warning = 'لم تُسجَّل قيود الفصوص المحاسبية — يرجى تعريف حسابَي أصول وإيراد الفصوص في الإعدادات'
            if _stones_asset_acc and _stones_revenue_acc:
                db.session.add(VoucherAccountLine(
                    voucher_id=voucher.id,
                    account_id=_stones_asset_acc,
                    line_type='debit',
                    amount_type='gold',
                    amount=stones_weight,
                    karat=float(to_karat),
                    description=f'أصول فصوص — تجديد ({stones_weight:.3f} جم)',
                ))
                db.session.add(VoucherAccountLine(
                    voucher_id=voucher.id,
                    account_id=_stones_revenue_acc,
                    line_type='credit',
                    amount_type='gold',
                    amount=stones_weight,
                    karat=float(to_karat),
                    description=f'إيراد فصوص — تجديد ({stones_weight:.3f} جم)',
                ))

        # قيد المصنعية التالفة (تكسير فقط):
        # مدين: حساب مصروف المصنعية التالفة (نقد)
        # دائن: حساب مخزون أجور المصنعية
        if damage_wage_amount > 0 and operation_type == 'melting' and damage_wage_account_id:
            wage_inventory_acc_id = _get_manufacturing_wage_inventory_account_id()
            if not wage_inventory_acc_id:
                raise Exception('حساب مخزون أجور المصنعية غير موجود. يرجى إنشاؤه أولاً.')
            db.session.add(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=damage_wage_account_id,
                line_type='debit',
                amount_type='cash',
                amount=damage_wage_amount,
                karat=None,
                description='مصروف مصنعية تالفة',
            ))
            db.session.add(VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=wage_inventory_acc_id,
                line_type='credit',
                amount_type='cash',
                amount=damage_wage_amount,
                karat=None,
                description='تخفيض مخزون أجور المصنعية - تكسير',
            ))

        journal_entry = create_journal_entry_from_voucher(voucher)
        if not journal_entry:
            raise Exception('فشل إنشاء القيد المحاسبي')

        voucher.status     = 'approved'
        voucher.approved_at = datetime.now()
        voucher.approved_by = created_by
        voucher.journal_entry_id = journal_entry.id

        # stones_weight: معلوماتي فقط — لا يؤثر على رصيد الوزن الذهبي
        _stones_raw = data.get('stones') or {}
        _sf = lambda v: max(0.0, float(v or 0))
        _s18 = _sf(_stones_raw.get('18k'))
        _s21 = _sf(_stones_raw.get('21k'))
        _s22 = _sf(_stones_raw.get('22k'))
        _s24 = _sf(_stones_raw.get('24k'))
        _s_total = _s18 + _s21 + _s22 + _s24
        if _s_total > 0:
            _stones_kw = {
                'stones_weight': round(_s_total, 6),
                'stones_18k': round(_s18, 6),
                'stones_21k': round(_s21, 6),
                'stones_22k': round(_s22, 6),
                'stones_24k': round(_s24, 6),
            }
        elif stones_weight > 0:
            _stones_kw = {'stones_weight': round(stones_weight, 6)}
        else:
            _stones_kw = {}

        # SafeBoxTransaction: خروج من المصدر (وزن صافي + فصوص معلوماتي)
        db.session.add(SafeBoxTransaction(
            safe_box_id=from_safe_id,
            direction='out',
            ref_type='voucher',
            ref_id=voucher.id,
            created_by=created_by,
            notes=f'{op_label} — خروج {from_karat}k',
            amount_cash=0.0,
            **{f'weight_{from_karat}k': round(gold_weight, 6)},
            **_stones_kw,
        ))

        # SafeBoxTransaction: دخول إلى الوجهة (وزن صافي + فصوص معلوماتي)
        db.session.add(SafeBoxTransaction(
            safe_box_id=to_safe_id,
            direction='in',
            ref_type='voucher',
            ref_id=voucher.id,
            created_by=created_by,
            notes=f'{op_label} — دخول {to_karat}k',
            amount_cash=0.0,
            **{f'weight_{to_karat}k': round(gold_weight, 6)},
            **_stones_kw,
        ))

        db.session.commit()

        resp = {
            'message': f'تم تسجيل عملية {op_label} بنجاح',
            'voucher': voucher.to_dict(),
            'operation': {
                'type': operation_type,
                'from_safe': from_safe.name,
                'to_safe': to_safe.name,
                'from_karat': from_karat,
                'to_karat': to_karat,
                'gold_weight': round(gold_weight, 3),
                'stones_weight': round(stones_weight, 3),
                'damage_wage_amount': round(damage_wage_amount, 2),
            },
        }
        if _stones_je_warning:
            resp['warning'] = _stones_je_warning
        return jsonify(resp), 201

    except Exception as e:
        db.session.rollback()
        import traceback; traceback.print_exc()
        return jsonify({'error': 'melting_renewal_failed', 'message': str(e)}), 500
