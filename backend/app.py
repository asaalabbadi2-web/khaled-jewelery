import sys
import os
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
except ImportError as exc:
	raise SystemExit(
		"Missing backend dependencies. Run the backend using the venv:\n"
		"  cd backend && ./venv/bin/python app.py\n"
		"(or activate the venv first: source backend/venv/bin/activate)"
	) from exc

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
bonus_bp = None
try:
	from bonus_routes import bonus_bp  # 🆕 استيراد bonus routes
	if _log_startup_imports:
		print("DEBUG: Imported bonus_bp blueprint")
except ImportError as exc:
	print(f"[WARNING] Bonus routes disabled: {exc}")
from schema_guard import (
	ensure_profit_weight_columns,
	ensure_invoice_item_scrap_columns,
	ensure_settings_columns,
	ensure_app_user_security_columns,
	ensure_auth_security_columns,
	ensure_weight_closing_columns,
	ensure_invoice_tax_columns,
	ensure_invoice_barter_columns,
	ensure_invoice_branch_columns,
	ensure_invoice_employee_columns,
	ensure_employee_gold_safe_columns,
	ensure_employee_cash_safe_columns,
	ensure_journal_line_dimension_columns,
	ensure_supplier_columns,
)

import os
from flask_cors import CORS
app = Flask(__name__)
# Flask secret key (used by some Flask features). Keep separate from JWT secret.
app.config['SECRET_KEY'] = (os.getenv('FLASK_SECRET_KEY') or os.getenv('SECRET_KEY') or 'yasar-gold-dev-flask-secret').strip()


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


@app.after_request
def _ensure_cors_headers(response):
	"""Ensure CORS headers exist for Flutter web (dev usage).

	Some environments may have strict/odd CORS settings; this keeps `/api/*`
	callable from a browser origin (e.g. http://localhost:8080).
	"""
	# Debug marker (safe to keep; helps verify proxy/browser issues)
	response.headers.setdefault('X-Backend-AfterRequest', '1')
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

with app.app_context():
	ensure_profit_weight_columns(db.engine)
	ensure_invoice_item_scrap_columns(db.engine)
	ensure_settings_columns(db.engine)
	ensure_app_user_security_columns(db.engine)
	ensure_auth_security_columns(db.engine)
	ensure_weight_closing_columns(db.engine)
	ensure_invoice_tax_columns(db.engine)
	ensure_invoice_barter_columns(db.engine)
	ensure_invoice_branch_columns(db.engine)
	ensure_journal_line_dimension_columns(db.engine)
	ensure_supplier_columns(db.engine)
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
		ensure_profit_weight_columns(db.engine)
		ensure_invoice_item_scrap_columns(db.engine)
		ensure_settings_columns(db.engine)
		ensure_app_user_security_columns(db.engine)
		ensure_auth_security_columns(db.engine)
		ensure_weight_closing_columns(db.engine)
		ensure_invoice_tax_columns(db.engine)
		ensure_invoice_barter_columns(db.engine)
		ensure_invoice_branch_columns(db.engine)
		ensure_invoice_employee_columns(db.engine)
		ensure_employee_gold_safe_columns(db.engine)
		ensure_employee_cash_safe_columns(db.engine)
		ensure_journal_line_dimension_columns(db.engine)
		ensure_supplier_columns(db.engine)


# In production Docker we run under Gunicorn (`backend.wsgi:app`).
# In that mode `__main__` is not executed, so we must bootstrap DB tables here
# to avoid 500s on first-load routes like `/api/auth/check-setup`.
try:
	create_tables()
	with app.app_context():
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
