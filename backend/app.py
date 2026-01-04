import sys
import os
# Ensure the backend package directory is importable as top-level for legacy
# imports like `from models import ...` and `from config import ...`.
sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))
# Also keep project root available for any scripts that rely on it.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# Flask app setup, database connection, and register routes

# Flask app setup with PostgreSQL, db init, register routes, create tables, run debug
from flask import Flask, url_for
from models import db
from routes import api, ensure_weight_closing_support_accounts
print("DEBUG: Imported api blueprint from routes")  # Debug log
from payment_methods_routes import payment_methods_api  # 🆕 استيراد payment methods routes
print("DEBUG: Imported payment_methods_api blueprint")  # Debug log
# استيراد recurring_journal_routes ليتم تسجيل routes على نفس api blueprint
import recurring_journal_routes  # 🆕 استيراد recurring journal routes
print("DEBUG: Imported recurring_journal_routes")  # Debug log
from offices_routes import offices_bp  # 🆕 استيراد offices routes
print("DEBUG: Imported offices_bp blueprint")  # Debug log
from branches_routes import branches_bp  # 🆕 استيراد branches routes
print("DEBUG: Imported branches_bp blueprint")  # Debug log
from posting_routes import posting_bp  # 🆕 استيراد posting routes
print("DEBUG: Imported posting_bp blueprint")  # Debug log
from auth_routes import auth_bp  # 🆕 استيراد auth routes
print("DEBUG: Imported auth_bp blueprint")  # Debug log
from permissions_routes import permissions_bp  # 🆕 استيراد permissions routes
print("DEBUG: Imported permissions_bp blueprint")  # Debug log
from setup_routes import setup_bp  # 🆕 Setup wizard routes
print("DEBUG: Imported setup_bp blueprint")
bonus_bp = None
try:
	from bonus_routes import bonus_bp  # 🆕 استيراد bonus routes
	print("DEBUG: Imported bonus_bp blueprint")  # Debug log
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
	ensure_invoice_branch_columns,
	ensure_journal_line_dimension_columns,
)

import os
from flask_cors import CORS
app = Flask(__name__)
# Configure PostgreSQL connection (replace values as needed)
app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}")
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False


# تفعيل CORS بشكل آمن: السماح فقط للـ localhost (المتصفح) مع دعم credentials
# تفعيل CORS لجميع المصادر بشكل بسيط وآمن
CORS(app)

db.init_app(app)

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
	ensure_invoice_branch_columns(db.engine)
	ensure_journal_line_dimension_columns(db.engine)
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
app.register_blueprint(api, url_prefix='/api')  # ✅ API الرئيسي (أخيراً)
# recurring_journal_routes تستخدم نفس api blueprint، لذا لا حاجة لتسجيلها

@app.route("/routes")
def list_routes():
    output = []
    for rule in app.url_map.iter_rules():
        methods = ','.join(rule.methods)
        line = "{:50s} {:20s} {}".format(rule.endpoint, methods, rule.rule)
        output.append(line)
    return "<br>".join(sorted(output))

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
		ensure_invoice_branch_columns(db.engine)
		ensure_journal_line_dimension_columns(db.engine)


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
		from bonus_scheduler import start_bonus_scheduler
		start_bonus_scheduler(app)
	except Exception as e:
		print(f"[WARNING] فشل تشغيل مجدول المكافآت: {e}")

	# تفعيل مجدول تحديث سعر الذهب حسب الإعداد
	try:
		from gold_price_scheduler import start_gold_price_scheduler
		start_gold_price_scheduler(app)
	except Exception as e:
		print(f"[WARNING] فشل تشغيل مجدول سعر الذهب: {e}")
	
	app.run(host="0.0.0.0", port=port, debug=debug_mode, threaded=True)
