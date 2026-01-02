from __future__ import annotations

import os
import sys
import secrets
import subprocess
from typing import Dict

from flask import Blueprint, jsonify, request, g

from auth_decorators import get_current_user, require_auth
from models import AppUser, Settings, User, db
from setup_utils import get_env_production_path, is_setup_locked

from sqlalchemy import create_engine, text


setup_bp = Blueprint('setup', __name__)


def _needs_setup_by_users() -> bool:
	active_users = User.query.filter_by(is_active=True).count()
	active_app_users = AppUser.query.filter_by(is_active=True).count()
	return (active_users + active_app_users) == 0


def _require_setup_unlocked() -> None:
	if is_setup_locked():
		raise PermissionError('setup_locked')


def _build_pg_url(host: str, port: int, db_name: str, username: str, password: str) -> str:
	# Keep it simple: only PostgreSQL for this wizard (matches docker-compose.prod.yml)
	from urllib.parse import quote_plus

	host = (host or '').strip() or 'db'
	username = (username or '').strip() or 'yasargold'
	db_name = (db_name or '').strip() or 'yasargold'
	password = password or ''
	port = int(port or 5432)

	return f"postgresql://{quote_plus(username)}:{quote_plus(password)}@{host}:{port}/{quote_plus(db_name)}"


@setup_bp.route('/setup/status', methods=['GET'])
def setup_status():
	try:
		locked = is_setup_locked()
		needs_setup = False if locked else _needs_setup_by_users()
		return jsonify({
			'success': True,
			'locked': bool(locked),
			'needs_setup': bool(needs_setup),
			'env_production_exists': bool(locked),
		}), 200
	except Exception as exc:
		return jsonify({'success': False, 'message': str(exc)}), 500


@setup_bp.route('/setup/test-db', methods=['POST'])
def test_db_connection():
	"""Test DB connection without persisting anything.

	Allowed only when the system is not yet set up.
	"""
	try:
		_require_setup_unlocked()

		# Allow unauthenticated only on an empty system. After an admin is created,
		# allow retries only for authenticated system admins until setup is locked.
		if not _needs_setup_by_users():
			user = get_current_user()
			is_admin = bool(getattr(user, 'is_admin', False)) if user else False
			role = str(getattr(user, 'role', '') or '') if user else ''
			if not user or (not is_admin and role != 'system_admin'):
				return jsonify({
					'success': False,
					'error': 'forbidden',
					'message': 'غير مصرح. يلزم تسجيل الدخول كمسؤول نظام لإعادة الاختبار.',
				}), 403

		data = request.get_json() or {}
		host = str(data.get('host') or 'db')
		port = int(data.get('port') or 5432)
		db_name = str(data.get('db_name') or 'yasargold')
		username = str(data.get('username') or 'yasargold')
		password = str(data.get('password') or '')

		url = _build_pg_url(host, port, db_name, username, password)
		engine = create_engine(url, pool_pre_ping=True)
		with engine.connect() as conn:
			version = conn.execute(text('select version()')).scalar()

		return jsonify({
			'success': True,
			'message': 'تم الاتصال بقاعدة البيانات بنجاح',
			'database_url_preview': f"postgresql://{username}:***@{host}:{port}/{db_name}",
			'version': version,
		}), 200
	except PermissionError:
		return jsonify({
			'success': False,
			'error': 'setup_locked',
			'message': 'واجهة التهيئة مقفلة. احذف ملف .env.production لإعادة التهيئة.',
		}), 403
	except Exception as exc:
		return jsonify({'success': False, 'message': str(exc)}), 400


@setup_bp.route('/setup/store-settings', methods=['POST'])
def save_store_settings():
	"""Persist store settings before admin is created.

	Allowed only when the system is not yet set up.
	"""
	try:
		_require_setup_unlocked()

		# Allow unauthenticated only on an empty system. After an admin is created,
		# allow updates only for authenticated system admins until setup is locked.
		if not _needs_setup_by_users():
			user = get_current_user()
			is_admin = bool(getattr(user, 'is_admin', False)) if user else False
			role = str(getattr(user, 'role', '') or '') if user else ''
			if not user or (not is_admin and role != 'system_admin'):
				return jsonify({
					'success': False,
					'error': 'forbidden',
					'message': 'غير مصرح. يلزم تسجيل الدخول كمسؤول نظام لحفظ الإعدادات.',
				}), 403

		data = request.get_json() or {}
		company_name = (data.get('company_name') or '').strip()
		currency_symbol = (data.get('currency_symbol') or '').strip()
		company_tax_number = (data.get('company_tax_number') or '').strip()
		company_logo_base64 = data.get('company_logo_base64')

		settings = Settings.query.first()
		if not settings:
			settings = Settings()
			db.session.add(settings)

		if company_name:
			settings.company_name = company_name
		if currency_symbol:
			settings.currency_symbol = currency_symbol
		if company_tax_number:
			settings.company_tax_number = company_tax_number
		if company_logo_base64 is not None:
			settings.company_logo_base64 = str(company_logo_base64) if company_logo_base64 else None

		db.session.commit()
		return jsonify({'success': True, 'message': 'تم حفظ إعدادات المتجر'}), 200

	except PermissionError:
		return jsonify({
			'success': False,
			'error': 'setup_locked',
			'message': 'واجهة التهيئة مقفلة. احذف ملف .env.production لإعادة التهيئة.',
		}), 403
	except Exception as exc:
		db.session.rollback()
		return jsonify({'success': False, 'message': str(exc)}), 500


def _format_env_value(value: str) -> str:
	value = '' if value is None else str(value)
	# Quote only when needed (spaces/special chars)
	if any(ch in value for ch in (' ', '\t', '#', '"', "'")):
		escaped = value.replace('\\', '\\\\').replace('"', '\\"')
		return f'"{escaped}"'
	return value


def _write_env_production(env_path: str, values: Dict[str, str]) -> None:
	lines = []
	for key, value in values.items():
		if value is None:
			continue
		lines.append(f"{key}={_format_env_value(value)}")
	content = "\n".join(lines).rstrip() + "\n"

	# Ensure parent exists and write with restricted permissions when possible
	os.makedirs(os.path.dirname(env_path), exist_ok=True)
	tmp_path = env_path + '.tmp'
	with open(tmp_path, 'w', encoding='utf-8') as f:
		f.write(content)
	try:
		os.chmod(tmp_path, 0o600)
	except Exception:
		pass
	os.replace(tmp_path, env_path)


@setup_bp.route('/setup/write-env-production', methods=['POST'])
@require_auth
def write_env_production():
	"""Finalize setup: write .env.production, create tables, and try restarting containers.

	Requires an authenticated user (system admin) to reduce attack surface.
	"""
	try:
		_require_setup_unlocked()
		current_user = getattr(g, 'current_user', None)
		is_admin = bool(getattr(current_user, 'is_admin', False))
		role = str(getattr(current_user, 'role', '') or '')
		if not is_admin and role != 'system_admin':
			return jsonify({
				'success': False,
				'error': 'forbidden',
				'message': 'غير مصرح. يلزم حساب مسؤول النظام لإكمال التهيئة.',
			}), 403

		data = request.get_json() or {}
		db_cfg = data.get('db') or {}
		host = str(db_cfg.get('host') or 'db')
		port = int(db_cfg.get('port') or 5432)
		db_name = str(db_cfg.get('db_name') or 'yasargold')
		username = str(db_cfg.get('username') or 'yasargold')
		password = str(db_cfg.get('password') or '')

		jwt_secret = (data.get('jwt_secret_key') or os.getenv('JWT_SECRET_KEY') or '').strip()
		if not jwt_secret:
			jwt_secret = secrets.token_urlsafe(48)

		database_url = _build_pg_url(host, port, db_name, username, password)

		env_path = get_env_production_path()
		_write_env_production(env_path, {
			'POSTGRES_DB': db_name,
			'POSTGRES_USER': username,
			'POSTGRES_PASSWORD': password,
			'DATABASE_URL': database_url,
			'JWT_SECRET_KEY': jwt_secret,
			'BYPASS_AUTH_FOR_DEVELOPMENT': '0',
		})

		# Build tables on the target DB (best-effort). We avoid alembic here because the
		# project also uses db.create_all() and schema guards heavily.
		init_cmd = [sys.executable, 'backend/init_db.py']
		proc = subprocess.run(
			init_cmd,
			cwd=os.path.realpath(os.path.join(os.path.dirname(__file__), '..')),
			env={**os.environ, 'DATABASE_URL': database_url},
			capture_output=True,
			text=True,
		)
		if proc.returncode != 0:
			return jsonify({
				'success': False,
				'error': 'init_db_failed',
				'message': (proc.stderr or proc.stdout or 'Failed to initialize DB'),
			}), 500

		# Try to restart docker compose (best-effort). In many deployments, the backend
		# container won't have access to docker; we return a manual command.
		restart_attempted = False
		restart_ok = False
		restart_error = None
		restart_allowed = os.getenv('SETUP_ALLOW_DOCKER_RESTART', '0') in ('1', 'true', 'True')
		if data.get('restart_containers') in (True, 'true', '1') and restart_allowed:
			restart_attempted = True
			try:
				restart_proc = subprocess.run(
					['docker', 'compose', '-f', 'docker-compose.prod.yml', '--env-file', '.env.production', 'restart'],
					cwd=os.path.realpath(os.path.join(os.path.dirname(__file__), '..')),
					capture_output=True,
					text=True,
					timeout=60,
				)
				restart_ok = restart_proc.returncode == 0
				if not restart_ok:
					restart_error = (restart_proc.stderr or restart_proc.stdout or 'restart failed')
			except Exception as exc:
				restart_error = str(exc)

		return jsonify({
			'success': True,
			'message': 'تم إنشاء ملف .env.production وتهيئة قاعدة البيانات',
			'env_path': env_path,
			'restart_attempted': restart_attempted,
			'restart_ok': restart_ok,
			'restart_error': restart_error,
			'restart_allowed': restart_allowed,
			'manual_restart_command': 'docker compose -f docker-compose.prod.yml --env-file .env.production restart',
		}), 200

	except PermissionError:
		return jsonify({
			'success': False,
			'error': 'setup_locked',
			'message': 'واجهة التهيئة مقفلة. احذف ملف .env.production لإعادة التهيئة.',
		}), 403
	except Exception as exc:
		return jsonify({'success': False, 'message': str(exc)}), 500
