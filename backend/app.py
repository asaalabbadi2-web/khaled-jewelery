import sys
import os
import warnings
from datetime import datetime

# Silence a common macOS dev warning when Python is compiled against LibreSSL.
# This warning is noisy but not actionable for local development.
warnings.filterwarnings(
	"ignore",
	message=r"urllib3 v2 only supports OpenSSL 1\.1\.1\+.*LibreSSL.*",
)
# Load environment variables from project root if available (optional).
try:
	from dotenv import load_dotenv
	_backend_dir = os.path.abspath(os.path.dirname(__file__))
	_repo_root = os.path.abspath(os.path.join(_backend_dir, '..'))
	# Support both layouts:
	# - repo root:   <repo>/.env
	# - backend dir: <repo>/backend/.env
	#
	# IMPORTANT: Only load .env.production when the environment is explicitly
	# production. This prevents dev machines from being “locked” just because
	# .env.production exists in the repo.
	load_dotenv(os.path.join(_repo_root, '.env'), override=False)
	load_dotenv(os.path.join(_backend_dir, '.env'), override=False)

	_env = (
		(os.getenv('YASAR_ENV') or '').strip().lower()
		or (os.getenv('APP_ENV') or '').strip().lower()
		or (os.getenv('ENV') or '').strip().lower()
		or (os.getenv('FLASK_ENV') or '').strip().lower()
	)
	if _env in ('prod', 'production'):
		load_dotenv(os.path.join(_repo_root, '.env.production'), override=False)
		load_dotenv(os.path.join(_backend_dir, '.env.production'), override=False)
except Exception:
	pass
# Ensure the backend package directory is importable as top-level for legacy
# imports like `from models import ...` and `from config import ...`.
sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))
# Also keep project root available for any scripts that rely on it.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# Flask app setup, database connection, and register routes

# Flask app setup with PostgreSQL, db init, register routes, create tables, run debug
try:
	from flask import Flask, url_for
	from models import db
	from routes import api, ensure_weight_closing_support_accounts
	from routes import public_api
	from routes.pricing import pricing_bp
	from routes.customers import customers_bp
	from routes.suppliers import suppliers_bp
	from routes.supplier_settlement_adjustments import supplier_settlement_adjustments_bp
	from routes.accounts import accounts_bp
	from routes.invoices import invoices_bp
	from routes.employees import employees_bp
	from routes.reports import reports_bp
	from routes.catalog import catalog_bp
	from routes.safe_boxes import safe_boxes_bp
	from routes.journals import journals_bp
	from routes.vouchers import vouchers_bp
	from routes.clearing import clearing_bp
	from routes.gold_advances import gold_advances_bp
	from routes.office_reservations import office_reservations_bp
	from routes.admin import admin_bp
	from routes.system import system_bp
except ImportError as exc:
	import traceback as _tb
	print(
		"\n[STARTUP ERROR] ImportError during backend initialisation:\n"
		+ _tb.format_exc()
		+ "\nMissing backend dependencies. Run the backend using the venv:\n"
		"  cd backend && ./venv/bin/python app.py\n"
		"(or activate the venv first: source backend/venv/bin/activate)",
		file=sys.stderr,
		flush=True,
	)
	raise SystemExit(1) from exc

_log_startup_imports = os.getenv('LOG_STARTUP_IMPORTS', '0') in ('1', 'true', 'True')
if _log_startup_imports:
	print("DEBUG: Imported api blueprint from routes")
from payment_methods_routes import payment_methods_api, ensure_default_payment_types  # 🆕 استيراد payment methods routes
if _log_startup_imports:
	print("DEBUG: Imported payment_methods_api blueprint")
# استيراد recurring_journal_routes ليتم تسجيل routes على نفس api blueprint
import recurring_journal_routes  # 🆕 استيراد recurring journal routes
if _log_startup_imports:
	print("DEBUG: Imported recurring_journal_routes")
from offices_routes import offices_bp  # 🆕 استيراد offices routes
if _log_startup_imports:
	print("DEBUG: Imported offices_bp blueprint")
from branches_routes import branches_bp  # 🆕 استيراد branches routes
if _log_startup_imports:
	print("DEBUG: Imported branches_bp blueprint")
from posting_routes import posting_bp  # 🆕 استيراد posting routes
if _log_startup_imports:
	print("DEBUG: Imported posting_bp blueprint")
from auth_routes import auth_bp  # 🆕 استيراد auth routes
if _log_startup_imports:
	print("DEBUG: Imported auth_bp blueprint")
from permissions_routes import permissions_bp  # 🆕 استيراد permissions routes
if _log_startup_imports:
	print("DEBUG: Imported permissions_bp blueprint")
from setup_routes import setup_bp  # 🆕 Setup wizard routes
if _log_startup_imports:
	print("DEBUG: Imported setup_bp blueprint")
from inventory_routes import inventory_bp  # Inventory Engine API
from internal_routes import internal_bp   # ERP Sync internal API (machine-to-machine only)
if _log_startup_imports:
	print("DEBUG: Imported inventory_bp blueprint")
bonus_bp = None
try:
	from bonus_routes import bonus_bp  # 🆕 استيراد bonus routes
	if _log_startup_imports:
		print("DEBUG: Imported bonus_bp blueprint")
except ImportError as exc:
	# Bonus routes are optional; avoid noisy warnings on every startup.
	if _log_startup_imports:
		print(f"[WARNING] Bonus routes disabled: {exc}")
from schema_guard import (
	ensure_profit_weight_columns,
	ensure_invoice_item_scrap_columns,
	ensure_settings_columns,
	ensure_voucher_print_columns,
	ensure_journal_entry_columns,
	ensure_app_user_security_columns,
	ensure_auth_security_columns,
	ensure_weight_closing_columns,
	ensure_invoice_tax_columns,
	ensure_invoice_barter_columns,
	ensure_invoice_branch_columns,
	ensure_invoice_employee_columns,
	ensure_employee_gold_safe_columns,
	ensure_employee_cash_safe_columns,
	ensure_app_user_photo_column,
	ensure_employee_photo_column,
	ensure_employee_goal_columns,
	ensure_journal_line_dimension_columns,
	ensure_supplier_columns,
	ensure_payment_method_columns,
	ensure_account_columns,
	ensure_safe_box_transaction_stones_columns,
	ensure_goal_achievement_columns,
	ensure_employee_bonus_audit_columns,
	ensure_bonus_accounts,
	ensure_unique_reservation_invoice_index,
	ensure_category_wage_column,
	ensure_invoice_gold24k_columns,
	ensure_invoice_karat_diff_columns,
	ensure_dashboard_performance_indexes,
	ensure_account_memo_pair_constraints,
	ensure_all_model_columns,
	ensure_invoice_online_sale_columns,
)

import os
from flask_cors import CORS
app = Flask(__name__)
# Flask secret key (used by some Flask features). Keep separate from JWT secret.
app.config['SECRET_KEY'] = (os.getenv('FLASK_SECRET_KEY') or os.getenv('SECRET_KEY') or 'yasar-gold-dev-flask-secret').strip()

# Swagger UI — available at /apidocs (local/dev only; no auth bypass)
app.config['SWAGGER'] = {
    'title': 'YasarGold ERP API',
    'uiversion': 3,
    'openapi': '3.0.3',
}
from flasgger import Swagger as _Swagger
_swagger = _Swagger(app, template={
    'info': {'title': 'YasarGold ERP API', 'version': '1.0'},
    'servers': [{'url': '/'}],
})


def _normalize_database_url(raw: str) -> str:
	"""Normalize DATABASE_URL to avoid surprises with Flask's instance/ path.

	Flask-SQLAlchemy resolves relative SQLite paths under the app's `instance/`
	directory. Historically this project uses `backend/app.db`, so we normalize
	common relative SQLite URLs (e.g. sqlite:///app.db) to point to backend/app.db.
	"""
	value = (raw or '').strip()
	if not value:
		return value
	if value.startswith('sqlite:///') and not value.startswith('sqlite:////'):
		sqlite_path = value[len('sqlite:///'):]
		# Absolute paths are already fine (they end up as sqlite:////abs/path)
		# Only normalize the simplest relative filename (e.g. "app.db").
		# If the value includes path separators (e.g. "../app.db"), respect it.
		if (
			sqlite_path
			and not sqlite_path.startswith('/')
			and '/' not in sqlite_path
			and '\\' not in sqlite_path
		):
			backend_dir = os.path.dirname(os.path.abspath(__file__))
			abs_path = os.path.abspath(os.path.join(backend_dir, sqlite_path))
			return f"sqlite:///{abs_path}"
	return value


# Configure DB connection
_default_db = f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}"
app.config['SQLALCHEMY_DATABASE_URI'] = _normalize_database_url(os.getenv('DATABASE_URL', _default_db))
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False


def _env_str(name: str, default: str = '') -> str:
	value = os.getenv(name)
	if value is None:
		return default
	return str(value)


def _is_production() -> bool:
	env = (_env_str('YASAR_ENV', '').strip().lower() or _env_str('FLASK_ENV', '').strip().lower())
	return env in ('prod', 'production')


def _parse_cors_origins(raw: str):
	# Comma-separated list. Examples:
	# - "http://example.com,https://example.com"
	# - "*" (dev only)
	value = (raw or '').strip()
	if not value:
		return []
	if value == '*':
		return '*'
	return [o.strip() for o in value.split(',') if o.strip()]


def _default_local_cors_origins():
	# Allow common local dev origins (Flutter web, etc.)
	# Use regex so any port is accepted.
	return [
		r"^https?://(localhost|127\\.0\\.0\\.1)(:\\d+)?$",
	]


# CORS policy:
# - Use CORS_ORIGINS to explicitly allow origins (comma-separated), or "*" for dev.
# - If unset, allow localhost by default so Flutter web can call the API.
_cors_origins_raw = _env_str('CORS_ORIGINS', '').strip()
_cors_origins = _parse_cors_origins(_cors_origins_raw)
if _cors_origins == '*':
	# Wildcard cannot be combined with credentials.
	CORS(app, resources={r"/api/.*": {"origins": "*"}})
elif _cors_origins:
	CORS(app, resources={r"/api/.*": {"origins": _cors_origins}}, supports_credentials=True)
else:
	# Dev-friendly default: allow cross-origin requests.
	# (Flutter web runs on a different origin/port like http://localhost:8080)
	CORS(app)

db.init_app(app)


def _compute_backend_build() -> str:
	"""Best-effort build identifier for troubleshooting deployments.

	Prefer explicit env vars; fall back to git (if available); otherwise 'unknown'.
	"""
	build = (os.getenv('APP_BUILD') or os.getenv('BACKEND_BUILD') or os.getenv('GIT_SHA') or '').strip()
	if build:
		return build
	try:
		# Don't fail app startup if git isn't available in production.
		import subprocess
		out = subprocess.check_output(
			['git', 'rev-parse', '--short', 'HEAD'],
			stderr=subprocess.DEVNULL,
			cwd=os.path.dirname(__file__),
			timeout=0.5,
		)
		sha = out.decode('utf-8').strip()
		return sha or 'unknown'
	except Exception:
		return 'unknown'


_BACKEND_BUILD = _compute_backend_build()
_BACKEND_STARTED_AT = datetime.now().isoformat(timespec='seconds') + 'Z'


@app.after_request
def _ensure_cors_headers(response):
	"""Ensure CORS headers exist for Flutter web (dev usage).

	Some environments may have strict/odd CORS settings; this keeps `/api/*`
	callable from a browser origin (e.g. http://localhost:8080).
	"""
	# Debug marker (safe to keep; helps verify proxy/browser issues)
	response.headers.setdefault('X-Backend-AfterRequest', '1')
	response.headers.setdefault('X-Backend-Build', _BACKEND_BUILD)
	response.headers.setdefault('X-Backend-Started-At', _BACKEND_STARTED_AT)
	try:
		from flask import request
		origin = request.headers.get('Origin')
		path = request.path or ''
		if origin and path.startswith('/api/'):
			response.headers.setdefault('Access-Control-Allow-Origin', origin)
			# Ensure caches don't mix origins.
			response.headers.setdefault('Vary', 'Origin')
			response.headers.setdefault(
				'Access-Control-Allow-Headers',
				'Authorization, Content-Type, Accept',
			)
			response.headers.setdefault(
				'Access-Control-Allow-Methods',
				'GET, POST, PUT, PATCH, DELETE, OPTIONS',
			)
	except Exception:
		pass
	return response

# 🔓 تعطيل Authentication مؤقتاً لتطوير Flutter (اختياري)
@app.before_request
def bypass_auth_for_development():
	"""تعطيل اختياري للـ authentication في وضع التطوير.

	مهم: هذا يدمّر دقة posted_by وبالتالي حساب المكافآت.
	لذلك أصبح Opt-in عبر env: BYPASS_AUTH_FOR_DEVELOPMENT=1
	ويعمل فقط عند غياب Authorization header.
	"""
	from flask import request, g
	from models import User

	bypass_enabled = os.getenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0') in ('1', 'true', 'True')
	if not bypass_enabled:
		return

	# Defence in depth: the boot guard below already refuses to start a
	# production process with the bypass on, but never apply it in production
	# even if that guard is somehow circumvented.
	if _is_production():
		return

	if not request.path.startswith('/api/'):
		return

	# لا تتدخل في مسارات تسجيل الدخول/الفحص
	if request.path in ('/api/auth/login', '/api/auth/check-setup'):
		return

	# إذا كان هناك توكن، اتركه يُحدد المستخدم الحقيقي
	if request.headers.get('Authorization'):
		return

	admin = User.query.filter_by(username='admin').first()
	if admin:
		g.current_user = admin


def _assert_auth_bypass_not_in_production() -> None:
	"""Refuse to boot a production process with authentication disabled.

	BYPASS_AUTH_FOR_DEVELOPMENT serves any /api/ request that carries no
	Authorization header as `admin`, which defeats authentication and every
	permission check built on top of it. In development that is a deliberate
	convenience; in production it is a total authorization bypass.

	Failing at boot is the same fail-closed choice the platform makes for
	financial adapters: a refused start is immediately visible, whereas a
	silently unauthenticated API is invisible until it is abused.
	"""
	bypass_enabled = os.getenv('BYPASS_AUTH_FOR_DEVELOPMENT', '0') in ('1', 'true', 'True')
	if bypass_enabled and _is_production():
		raise RuntimeError(
			'BYPASS_AUTH_FOR_DEVELOPMENT=1 is set while running in production '
			f"(YASAR_ENV/FLASK_ENV={_env_str('YASAR_ENV', '') or _env_str('FLASK_ENV', '')!r}). "
			'This serves unauthenticated /api/ requests as admin and disables every '
			'permission check. Unset BYPASS_AUTH_FOR_DEVELOPMENT (or set it to 0) '
			'in the production environment before starting the application.'
		)


_assert_auth_bypass_not_in_production()

with app.app_context():
	ensure_profit_weight_columns(db.engine)
	ensure_invoice_item_scrap_columns(db.engine)
	ensure_settings_columns(db.engine)
	ensure_voucher_print_columns(db.engine)
	ensure_journal_entry_columns(db.engine)
	ensure_app_user_security_columns(db.engine)
	ensure_auth_security_columns(db.engine)
	ensure_weight_closing_columns(db.engine)
	ensure_invoice_tax_columns(db.engine)
	ensure_invoice_barter_columns(db.engine)
	ensure_invoice_branch_columns(db.engine)
	ensure_invoice_employee_columns(db.engine)
	ensure_employee_gold_safe_columns(db.engine)
	ensure_employee_cash_safe_columns(db.engine)
	ensure_app_user_photo_column(db.engine)
	ensure_employee_photo_column(db.engine)
	ensure_employee_goal_columns(db.engine)
	ensure_journal_line_dimension_columns(db.engine)
	ensure_supplier_columns(db.engine)
	ensure_payment_method_columns(db.engine)
	ensure_account_columns(db.engine)
	ensure_safe_box_transaction_stones_columns(db.engine)
	ensure_goal_achievement_columns(db.engine)
	ensure_employee_bonus_audit_columns(db.engine)
	ensure_bonus_accounts(db.engine)
	ensure_unique_reservation_invoice_index(db.engine)
	ensure_category_wage_column(db.engine)
	ensure_invoice_gold24k_columns(db.engine)
	ensure_invoice_karat_diff_columns(db.engine)
	ensure_dashboard_performance_indexes(db.engine)
	ensure_account_memo_pair_constraints(db.engine)
	ensure_invoice_online_sale_columns(db.engine)
	# ensure_weight_closing_support_accounts()  # Moved to after create_tables()
# ⚠️ ترتيب التسجيل مهم: auth_bp يجب أن يُسجل قبل api لأن auth_bp.login له أولوية
app.register_blueprint(auth_bp, url_prefix='/api')  # 🆕 تسجيل auth & permissions routes (أولاً!)
app.register_blueprint(permissions_bp, url_prefix='/api')  # 🆕 تسجيل permissions routes
app.register_blueprint(setup_bp, url_prefix='/api')  # 🆕 تسجيل setup wizard routes
app.register_blueprint(posting_bp, url_prefix='/api')  # 🆕 تسجيل posting routes
app.register_blueprint(payment_methods_api, url_prefix='/api')  # 🆕 تسجيل payment methods routes
if bonus_bp:
	app.register_blueprint(bonus_bp, url_prefix='/api')  # 🆕 تسجيل bonus routes
app.register_blueprint(offices_bp)  # 🆕 تسجيل offices routes (has its own prefix /api/offices)
app.register_blueprint(branches_bp)  # 🆕 تسجيل branches routes (has its own prefix /api/branches)
app.register_blueprint(public_api, url_prefix='/api')  # 🆕 Public (unauthenticated) API
app.register_blueprint(inventory_bp)               # Inventory Engine (/api/inventory/*)
app.register_blueprint(pricing_bp, url_prefix='/api')    # Pricing domain (gold price + costing)
app.register_blueprint(customers_bp, url_prefix='/api')  # Customers domain
app.register_blueprint(suppliers_bp, url_prefix='/api')  # Suppliers domain
app.register_blueprint(supplier_settlement_adjustments_bp, url_prefix='/api')  # SAD (ADR-025)
app.register_blueprint(accounts_bp, url_prefix='/api')   # Accounts domain
app.register_blueprint(invoices_bp, url_prefix='/api')   # Invoices domain
app.register_blueprint(employees_bp, url_prefix='/api')  # Employees domain
app.register_blueprint(reports_bp, url_prefix='/api')    # Reports domain
app.register_blueprint(catalog_bp, url_prefix='/api')    # Catalog domain (items, categories)
app.register_blueprint(safe_boxes_bp, url_prefix='/api') # Safe-boxes domain
app.register_blueprint(journals_bp, url_prefix='/api')  # Journal-entries domain
app.register_blueprint(vouchers_bp, url_prefix='/api')  # Vouchers domain
app.register_blueprint(clearing_bp, url_prefix='/api')  # Clearing & weight-closing domain
app.register_blueprint(gold_advances_bp, url_prefix='/api')  # Gold Advance & Allocation domain (Phase 15C)
app.register_blueprint(office_reservations_bp, url_prefix='/api')  # Office reservations domain
app.register_blueprint(admin_bp, url_prefix='/api')     # Admin & temp-pdf domain
app.register_blueprint(system_bp, url_prefix='/api')    # System domain (debug, settings, reset, backup)
app.register_blueprint(internal_bp)             # ERP Sync internal API (/api/internal/*)
app.register_blueprint(api, url_prefix='/api')  # ✅ API الرئيسي (أخيراً)
# recurring_journal_routes تستخدم نفس api blueprint، لذا لا حاجة لتسجيلها

@app.route("/routes")
def list_routes():
	# Disable route listing in production unless explicitly enabled.
	if _is_production() and os.getenv('ENABLE_ROUTE_LISTING', '0') not in ('1', 'true', 'True'):
		from flask import jsonify
		return jsonify({'error': 'Not Found'}), 404
	output = []
	for rule in app.url_map.iter_rules():
		methods = ','.join(rule.methods)
		line = "{:50s} {:20s} {}".format(rule.endpoint, methods, rule.rule)
		output.append(line)
	return "<br>".join(sorted(output))


@app.get('/health')
def healthcheck():
	from flask import jsonify
	return jsonify({'status': 'ok', 'env': os.getenv('YASAR_ENV', '')}), 200


@app.get('/ready')
def readinesscheck():
	from flask import jsonify
	try:
		with db.engine.connect() as conn:
			conn.exec_driver_sql('SELECT 1')
		return jsonify({'status': 'ready'}), 200
	except Exception as exc:
		return jsonify({'status': 'not_ready', 'error': str(exc)}), 503

def create_tables():
	with app.app_context():
		db.create_all()
		ensure_all_model_columns(db.engine, db.metadata)
		ensure_profit_weight_columns(db.engine)
		ensure_invoice_item_scrap_columns(db.engine)
		ensure_settings_columns(db.engine)
		ensure_voucher_print_columns(db.engine)
		ensure_journal_entry_columns(db.engine)
		ensure_app_user_security_columns(db.engine)
		ensure_auth_security_columns(db.engine)
		ensure_weight_closing_columns(db.engine)
		ensure_invoice_tax_columns(db.engine)
		ensure_invoice_barter_columns(db.engine)
		ensure_invoice_branch_columns(db.engine)
		ensure_invoice_employee_columns(db.engine)
		ensure_employee_gold_safe_columns(db.engine)
		ensure_employee_cash_safe_columns(db.engine)
		ensure_app_user_photo_column(db.engine)
		ensure_employee_photo_column(db.engine)
		ensure_employee_goal_columns(db.engine)
		ensure_journal_line_dimension_columns(db.engine)
		ensure_supplier_columns(db.engine)
		ensure_payment_method_columns(db.engine)
		ensure_account_columns(db.engine)
		ensure_safe_box_transaction_stones_columns(db.engine)
		ensure_goal_achievement_columns(db.engine)
		ensure_unique_reservation_invoice_index(db.engine)
		ensure_invoice_gold24k_columns(db.engine)
		ensure_invoice_karat_diff_columns(db.engine)
		ensure_dashboard_performance_indexes(db.engine)
		ensure_account_memo_pair_constraints(db.engine)


# In production Docker we run under Gunicorn (`backend.wsgi:app`).
# In that mode `__main__` is not executed, so we must bootstrap DB tables here
# to avoid 500s on first-load routes like `/api/auth/check-setup`.
try:
	create_tables()
	with app.app_context():
		# Allow admin tooling (Full System Wipe) to intentionally keep the system empty
		# without auto-creating COA/support accounts on worker restart.
		bootstrap_disabled = False
		try:
			from models import Settings
			s = Settings.query.first()
			bootstrap_disabled = bool(getattr(s, 'disable_startup_bootstrap', False)) if s else False
		except Exception as exc:
			db.session.rollback()
			print(f"[WARNING] Bootstrap flag read failed: {exc}")
			bootstrap_disabled = False

		if bootstrap_disabled:
			print('[INFO] Startup bootstrap disabled by settings; skipping COA/support account seeding.')
		else:
			# Seed chart of accounts only for fresh/empty databases.
			try:
				from coa_seed import seed_chart_of_accounts_if_empty
				seeded = seed_chart_of_accounts_if_empty(db, '../exports/accounts_standard_220126.json')
				if seeded:
					print(f"[INFO] Seeded chart of accounts from standard JSON: {seeded} accounts")
			except Exception as exc:
				print(f"[WARNING] COA seed skipped/failed: {exc}")

			# Repair/normalize employee gold custody group account numbering on startup.
			try:
				from employee_gold_safe_helpers import ensure_employee_gold_group_account
				ensure_employee_gold_group_account(created_by='system')
				db.session.commit()
			except Exception as exc:
				db.session.rollback()
				print(f"[WARNING] Employee gold custody bootstrap skipped/failed: {exc}")

			ensure_weight_closing_support_accounts()
			# Ensure core VAT accounts exist (required by supplier purchase postings).
			try:
				from models import Account

				def _ensure_account(account_number, name, acc_type):
					acc = Account.query.filter_by(account_number=str(account_number)).first()
					if acc:
						return acc
					acc = Account(
						account_number=str(account_number),
						name=str(name),
						type=str(acc_type),
						transaction_type='cash',
						tracks_weight=False,
						parent_id=None,
					)
					db.session.add(acc)
					db.session.flush()
					return acc

				_ensure_account('1500', 'ضريبة القيمة المضافة (مدفوعة)', 'Asset')
				_ensure_account('2210', 'ضريبة القيمة المضافة المستحقة', 'Liability')
				_ensure_account('1501', 'ضريبة عمولات نقاط البيع (مدفوعة)', 'Asset')
				db.session.commit()
			except Exception as exc:
				db.session.rollback()
				print(f"[WARNING] VAT accounts bootstrap skipped/failed: {exc}")
			try:
				ensure_default_payment_types()
			except Exception as exc:
				print(f"[WARNING] Default payment types bootstrap failed: {exc}")

		# ── One-time fix: remove duplicate invoice_sale_gold_movement SBTs for scrap invoices ──
		# Before the inv_gold_type != 'scrap' guard was added, scrap sale invoices created
		# BOTH an invoice_scrap_sale SBT and an invoice_sale_gold_movement SBT, doubling the
		# weight-out in the sub-ledger and causing a GL reconciliation gap.
		try:
			from models import SafeBoxTransaction, Invoice as _Inv
			from sqlalchemy import func as _func
			_dup_sbts = (
				db.session.query(SafeBoxTransaction)
				.join(_Inv, _Inv.id == SafeBoxTransaction.invoice_id)
				.filter(
					SafeBoxTransaction.ref_type == 'invoice_sale_gold_movement',
					_func.lower(_func.coalesce(_Inv.gold_type, 'new')) == 'scrap',
				)
				.all()
			)
			if _dup_sbts:
				_ids = [s.id for s in _dup_sbts]
				print(f'[INFO] Removing {len(_dup_sbts)} duplicate invoice_sale_gold_movement SBT(s) for scrap invoices: ids={_ids}')
				for _s in _dup_sbts:
					db.session.delete(_s)
				db.session.commit()
				print('[INFO] Duplicate scrap SBTs removed successfully.')
		except Exception as exc:
			db.session.rollback()
			print(f"[WARNING] Duplicate scrap SBT cleanup failed: {exc}")

except Exception as exc:
	print(f"[WARNING] Startup DB bootstrap failed: {exc}")


def reset_database():
	"""إعادة تهيئة قاعدة البيانات بالكامل (حذف وإنشاء جميع الجداول من جديد)."""
	with app.app_context():
		# نضمن إغلاق أي جلسات نشطة قبل إعادة التهيئة
		db.session.remove()
		# حذف جميع الجداول ثم إعادة إنشائها
		db.drop_all()
		db.create_all()
		db.session.commit()


def reset_database_preserve_accounts():
	"""إعادة تهيئة النظام بالكامل مع الحفاظ على شجرة الحسابات.

	- يتم حذف/إعادة إنشاء جميع جداول النظام ما عدا جدول الحسابات (account).
	- هذا يحقق طلب استثناء شجرة الحسابات من "إعادة تهيئة كاملة".
	"""
	with app.app_context():
		db.session.remove()
		engine = db.engine

		# Drop all tables defined in metadata except the account table.
		# This preserves the chart of accounts rows.
		tables_to_drop = [
			t
			for t in db.metadata.sorted_tables
			if t.name != 'account'
		]
		if tables_to_drop:
			# Flask-SQLAlchemy's db.drop_all() doesn't support tables= in some versions.
			# Use SQLAlchemy MetaData directly.
			db.metadata.drop_all(bind=engine, tables=tables_to_drop)

		# Recreate everything that was dropped (keep account as-is).
		if tables_to_drop:
			db.metadata.create_all(bind=engine, tables=tables_to_drop)
		db.session.commit()

if __name__ == "__main__":
	port = int(os.getenv("PORT", 8001))
	debug_mode = os.getenv("FLASK_DEBUG", "0") in ("1", "true", "True")
	print(f"\n[INFO] 🚀 Starting Flask server on http://0.0.0.0:{port} (CORS enabled for all origins)...")
	print("[INFO] إذا كنت تستخدم جدار حماية أو VPN، أوقفه مؤقتاً.")
	print(f"[INFO] افتح الرابط التالي من أي جهاز على الشبكة: http://<IP-الجهاز>:{port}/customers")
	print(f"[INFO] Debug mode: {'ON' if debug_mode else 'OFF'}")
	create_tables()
	
	# تنفيذ ensure_weight_closing_support_accounts داخل application context
	with app.app_context():
		ensure_weight_closing_support_accounts()
	
	# تفعيل مجدول المكافآت التلقائي
	try:
		from schedulers import start_all_schedulers
		start_all_schedulers(app)
	except Exception as e:
		print(f"[WARNING] فشل تشغيل المجدولات: {e}")
	
	app.run(host="0.0.0.0", port=port, debug=debug_mode, threaded=True)
