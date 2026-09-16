try:
    # When running via Docker/Gunicorn we import backend as a package.
    from backend.config import MAIN_KARAT
except ImportError:  # Local scripts running from backend/ directory
    from config import MAIN_KARAT
# SQLAlchemy models for Customer, Item, Invoice, InvoiceItem
from datetime import datetime, date, time
import json
import logging
from flask_sqlalchemy import SQLAlchemy
from werkzeug.security import check_password_hash, generate_password_hash
from sqlalchemy import event, text
from sqlalchemy.orm import validates

db = SQLAlchemy()


def _configured_main_karat_f() -> float:
    """Return the configured main karat as float.

    Prefers Settings.main_karat when available, otherwise falls back to MAIN_KARAT/21.
    Kept defensive because this can be called in varied app/migration contexts.
    """
    try:
        settings = Settings.query.first()  # type: ignore[name-defined]
        if settings and getattr(settings, 'main_karat', None):
            return float(settings.main_karat)
    except Exception:
        pass

    try:
        return float(MAIN_KARAT or 21)
    except Exception:
        return 21.0


def get_race_points_per_gram() -> float:
    """Return points_per_gram from سباق الأداء settings (dynamic, not hardcoded)."""
    try:
        cfg = get_race_points_config()
        return max(0.0, float(cfg['points_per_gram']))
    except Exception:
        return 10.0


def get_race_points_config() -> dict:
    """Read full points config from Settings.sales_race_settings.

    Single Source of Truth for both Race (PointsMetric) and Bonus (BonusCalculator).
    Returns a dict with keys: points_source, cash_amount_per_point,
    points_per_gram, point_rules.
    """
    import json as _json
    import sys as _sys
    cfg: dict = {
        'points_source':         'gold_weight',
        'cash_amount_per_point': 100.0,
        'points_per_gram':       10.0,
        'point_rules':           None,
    }
    try:
        # Use the same canonical row picker as the settings API
        # (lazy import to avoid circular dependency at module load time)
        from core.settings import _get_settings_singleton as _gss
        settings = _gss(create_if_missing=False)
        if settings:
            raw = getattr(settings, 'sales_race_settings', None)
            if raw:
                # handle both db.Text (str) and already-decoded dict
                decoded = _json.loads(raw) if isinstance(raw, str) else raw
                if isinstance(decoded, dict):
                    for k in ('points_source', 'cash_amount_per_point',
                              'points_per_gram', 'point_rules'):
                        if k in decoded and decoded[k] is not None:
                            cfg[k] = decoded[k]
    except Exception as _e:
        print(f"[get_race_points_config] ERROR reading settings: {_e}", file=_sys.stderr)
    return cfg


PAYMENT_METHOD_ALLOWED_INVOICE_TYPES = [
    'بيع',
    'شراء من عميل',
    'مرتجع بيع',
    'مرتجع شراء',
    'شراء',
    'مرتجع شراء (مورد)',
]

class Account(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    account_number = db.Column(db.String(20), unique=True, nullable=False)
    name = db.Column(db.String(100), nullable=False)
    type = db.Column(db.String(50), nullable=False)  # Asset, Liability, Equity, Revenue, Expense
    transaction_type = db.Column(db.String(10), nullable=False, server_default='both') # cash, gold, both
    parent_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=True)
    
    # 🆕 معلومات إضافية للحسابات البنكية ووسائل الدفع
    bank_name = db.Column(db.String(100), nullable=True)  # اسم البنك أو المؤسسة (بنك الرياض، تمارا، STC Pay)
    account_number_external = db.Column(db.String(100), nullable=True)  # IBAN أو رقم الحساب الفعلي
    account_type = db.Column(db.String(50), nullable=True)  # bank_account, digital_wallet, bnpl, cash
    
    # 🔥 النظام المزدوج: أرصدة نقدية ووزنية
    # الأرصدة النقدية (ر.س)
    balance_cash = db.Column(db.Float, default=0.0, nullable=False)
    
    # الأرصدة الوزنية (جم) - لكل عيار
    balance_18k = db.Column(db.Float, default=0.0, nullable=False)  # عيار 18
    balance_21k = db.Column(db.Float, default=0.0, nullable=False)  # عيار 21 (الرئيسي)
    balance_22k = db.Column(db.Float, default=0.0, nullable=False)  # عيار 22
    balance_24k = db.Column(db.Float, default=0.0, nullable=False)  # عيار 24 (الذهب الخالص)
    
    # 🔥 علامة للنظام المزدوج: هل هذا الحساب يتعامل مع الوزن؟
    tracks_weight = db.Column(db.Boolean, default=False, nullable=False)
    # True: حسابات المخزون، المبيعات، المشتريات
    # False: حسابات النقدية البحتة، المصروفات الإدارية
    
    # 🔥 ربط مع حساب المذكرة الموازي (للنظام المزدوج الكامل)
    memo_account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=True)

    # 🆕 علم تضمين الحساب في تقرير ربح الجرام الوزني
    # True → يدخل في حساب الربح الوزني (إيراد أو مصروف حسب رقم الحساب)
    include_in_gram_profit = db.Column(db.Boolean, default=False, nullable=False)
    # True → يُستثنى صراحةً من ربح الجرام حتى لو كانت فئته (74/75) تُضمَّن تلقائياً
    exclude_from_gram_profit = db.Column(db.Boolean, default=False, nullable=False)
    # يشير إلى الحساب الوزني الموازي في قسم (7) حسابات المذكرة
    # مثال: حساب "1000 صندوق النقدية" له حساب موازي "7100 صندوق النقدية (وزن معادل)"
    
    children = db.relationship('Account', 
                               foreign_keys=[parent_id],
                               backref=db.backref('parent', remote_side=[id]))

    def to_dict(self):
        """تحويل الحساب إلى dict مع جميع المعلومات"""
        result = {
            'id': self.id,
            'account_number': self.account_number,
            'name': self.name,
            'type': self.type,
            'transaction_type': self.transaction_type,
            'parent_id': self.parent_id,
            'bank_name': self.bank_name,
            'account_number_external': self.account_number_external,
            'account_type': self.account_type,
            'tracks_weight': self.tracks_weight,
            'memo_account_id': self.memo_account_id,
            'include_in_gram_profit': bool(getattr(self, 'include_in_gram_profit', False)),
            'exclude_from_gram_profit': bool(getattr(self, 'exclude_from_gram_profit', False)),
        }
        
        # إضافة الأرصدة (النظام المزدوج)
        result['balances'] = {
            'cash': round(self.balance_cash, 2),
        }
        
        # إضافة الأرصدة الوزنية إذا كان الحساب يتتبع الوزن
        if self.tracks_weight:
            result['balances']['weight'] = {
                '18k': round(self.balance_18k, 3),
                '21k': round(self.balance_21k, 3),
                '22k': round(self.balance_22k, 3),
                '24k': round(self.balance_24k, 3),
                'total': round(self.balance_18k + self.balance_21k + self.balance_22k + self.balance_24k, 3)
            }
        
        return result

    def update_balance(self, cash_amount=0, weight_18k=0, weight_21k=0, weight_22k=0, weight_24k=0):
        """
        تحديث أرصدة الحساب (النظام المزدوج)
        
        Args:
            cash_amount: المبلغ النقدي (موجب = زيادة، سالب = نقصان)
            weight_18k: الوزن عيار 18 (موجب = زيادة، سالب = نقصان)
            weight_21k: الوزن عيار 21
            weight_22k: الوزن عيار 22
            weight_24k: الوزن عيار 24
        """
        self.balance_cash += cash_amount
        
        if self.tracks_weight:
            self.balance_18k += weight_18k
            self.balance_21k += weight_21k
            self.balance_22k += weight_22k
            self.balance_24k += weight_24k
    
    def get_total_weight(self):
        """حساب إجمالي الوزن في الحساب (مجموع كل العيارات)"""
        if not self.tracks_weight:
            return 0.0
        return self.balance_18k + self.balance_21k + self.balance_22k + self.balance_24k
    
    def get_weight_by_karat(self, karat):
        """الحصول على الوزن لعيار محدد"""
        if not self.tracks_weight:
            return 0.0
        
        karat_map = {
            '18': self.balance_18k,
            '21': self.balance_21k,
            '22': self.balance_22k,
            '24': self.balance_24k
        }
        return karat_map.get(str(karat), 0.0)
    
    # ─────────────────────────────────────────────────────────────────────────
    # قائمة البادئات المسموح لها بإنشاء حساب موازي (وزني).
    # أي حساب لا تبدأ به رقمه بأحد هذه البادئات لا يستحق حساباً وزنياً.
    # المعيار: هل الحساب يشارك مباشرة في حركات الذهب (مخزون / موردون ذهب /
    #          مكاتب تسكير / مصروفات معالجة / إيرادات ذهب / فروقات تقييم)؟
    # ─────────────────────────────────────────────────────────────────────────
    _PARALLEL_ALLOWED_PREFIXES: tuple = (
        # ── أصول ──────────────────────────────────────────────────────────
        '129',   # جسر مشتريات الكسر والتسكير (1290)
        '130',   # مخزون المعروض للبيع (1300)
        '131',   # مخزون الكسر / عهدة موظفين (1310-1319)
        '132',   # مخزون أجور مصنعية (1320)
        # ── موردو الذهب ── (المطلوبات المرتبطة بعمليات ذهبية)
        '210',   # موردو الذهب المشغول ومكاتب التسكير (2100xxx)
        '220',   # موردو الذهب الخام (2200xxx)
        # ── مصروفات معالجة الذهب ─────────────────────────────────────────
        '511',   # مصاريف نظافة ذهب (5110)
        '512',   # مشتريات ذهب كسر (512)
        '513',   # مصاريف صهر (5120)
        '510',   # بادئة مشتركة لمجموعة معالجة الذهب
        '51',    # مجموعة كاملة لمصاريف معالجة الذهب
        # ── إيرادات ذهب ─────────────────────────────────────────────────
        '41',    # إيرادات المبيعات الذهبية
        '42',    # إيرادات مشتريات الذهب / كسر
        # ── حقوق ملكية: فروقات تقييم فقط ──────────────────────────────
        '360',   # فروقات تقييم الذهب (3600)
    )

    def _is_parallel_allowed(self) -> bool:
        """هل يُسمح لهذا الحساب بإنشاء حساب موازي وزني؟"""
        num = (self.account_number or '').strip()
        return num.startswith(self._PARALLEL_ALLOWED_PREFIXES)

    # علامات نصية تُستخدم في هذا النظام لوضع حساب كـ"متروك" بعد دمج/استبدال
    # (لا يوجد حقل is_active على Account، فالاتفاقية الوحيدة المتاحة هي
    # إضافة هذه العلامة لاسم الحساب). يستخدمها أيضاً audit_account_memo_invariants.py.
    _DEPRECATED_ACCOUNT_MARKERS = ('غير مستخدم', 'مكرَّر', 'مكرر', 'متروك')

    @validates('memo_account_id')
    def _validate_memo_account_id(self, key, value):
        """ضمان دائم يمنع تكرار حادثة حساب #1213: حساب #1072 (مكتب تسكير
        فورية واشخاص) ظلّ memo_account_id فيه يشير لحساب أُعيدت تسميته
        لاحقاً كـ"متروك/مكرَّر" بعد استبداله بحساب آخر، فاستمرت حجوزات
        ذهب جديدة بالتسجيل عليه شهوراً دون أن يُلاحظ أحد -- لأن لا شيء في
        البنية كان يرفض هذا التعيين عند حدوثه، رغم 36 موضع كتابة مختلفاً
        لهذا الحقل في الكود.

        هذا الحارس يعمل بغضّ النظر عن أي مسار كتابة استدعاه (وليس فقط
        create_parallel_account)، ويرفض فوراً:
          - حساب يشير لنفسه.
          - حساب يشير لحساب آخر موسوم صراحةً كمتروك/مكرَّر.

        لفحص شامل لكل الحسابات الموجودة فعلاً وعلاقاتها (one-way link،
        duplicate target، إلخ) استخدم audit_account_memo_invariants.py --
        هذا الحارس يمنع فقط حالات *جديدة* مستقبلاً.
        """
        if value is None:
            return value
        if self.id is not None and value == self.id:
            raise ValueError(f'لا يمكن لحساب #{self.id} أن يشير لنفسه عبر memo_account_id.')
        try:
            target = db.session.query(Account).filter(Account.id == value).first()
        except Exception:
            target = None
        if target is not None and target.name and any(
            marker in target.name for marker in self._DEPRECATED_ACCOUNT_MARKERS
        ):
            raise ValueError(
                f"لا يمكن ربط memo_account_id بحساب #{target.id} ({target.name}) "
                "لأنه موسوم كمتروك/مكرَّر -- هذا تحديداً ما سبّب حادثة حساب #1213."
            )
        return value

    def create_parallel_account(self, force: bool = False):
        """إنشاء حساب موازي (نقدي ↔ وزني).

        بشكل افتراضي يعمل فقط على الحسابات المدرجة في _PARALLEL_ALLOWED_PREFIXES
        (بادئات ذهبية معروفة). عند تمرير force=True تُتجاوز القائمة البيضاء —
        يُستخدم عندما يختار المستخدم صراحةً إنشاء حساب موازي لحساب خارج القائمة
        (مثال: ذمم الشركاء التي قد تستلم ذهباً).

        القواعد:
        - cash → ينشئ حساب gold برقم (7 + الرقم الأصلي)
        - gold → ينشئ حساب cash بحذف الـ7 من البداية
        - الأب الموازي يُنشأ تلقائياً إذا لم يكن موجوداً
        """
        if self.transaction_type == 'both':
            return None

        # القائمة البيضاء: تُطبَّق فقط عند الإنشاء التلقائي (force=False).
        # عند الطلب الصريح من المستخدم (force=True) تُتجاوز — لأن السياسة
        # ليست قانوناً: الشريك قد يستلم ذهباً، والمورد قد يُسوَّى وزنياً.
        if self.transaction_type == 'cash' and not force and not self._is_parallel_allowed():
            return None
        
        # تحديد اتجاه الإنشاء
        if self.transaction_type == 'cash':
            # إنشاء حساب وزني موازي
            parallel_number = f"7{self.account_number}"
            parallel_name = f"{self.name} وزني"
            parallel_type = 'gold'
            parallel_tracks_weight = True
            
            # إيجاد/إنشاء الحساب الأب الموازي
            parallel_parent_id = None
            if self.parent_id:
                parent_account = Account.query.get(self.parent_id)
                if parent_account:
                    # إذا الأب المالي ما عنده memo مربوط، ننشئ واحد له
                    if not parent_account.memo_account_id:
                        parent_parallel = parent_account.create_parallel_account()
                        if parent_parallel:
                            parallel_parent_id = parent_parallel.id
                    else:
                        parallel_parent_id = parent_account.memo_account_id
        
        elif self.transaction_type == 'gold':
            # إنشاء حساب مالي موازي
            # التحقق من أن الرقم يبدأ بـ 7
            if not self.account_number.startswith('7'):
                # حساب وزني لكن لا يبدأ بـ 7، لا يمكن إنشاء موازي
                return None
            
            parallel_number = self.account_number[1:]  # حذف الـ 7
            parallel_name = self.name.replace(' وزني', '').strip()
            parallel_type = 'cash'
            parallel_tracks_weight = False
            
            # إيجاد/إنشاء الحساب الأب الموازي
            parallel_parent_id = None
            if self.parent_id:
                parent_account = Account.query.get(self.parent_id)
                if parent_account:
                    # البحث عن الحساب المالي الذي يشير إلى الأب الوزني
                    financial_parent = Account.query.filter_by(
                        memo_account_id=parent_account.id
                    ).first()
                    if financial_parent:
                        parallel_parent_id = financial_parent.id
                    else:
                        # إذا الأب الوزني ما عنده حساب مالي مربوط، ننشئ واحد له
                        parent_parallel = parent_account.create_parallel_account()
                        if parent_parallel:
                            parallel_parent_id = parent_parallel.id
        
        else:
            return None
        
        # التحقق من عدم وجود الحساب مسبقاً
        existing = Account.query.filter_by(account_number=parallel_number).first()
        if existing:
            # Ensure existing account matches the intended parallel semantics.
            existing.transaction_type = parallel_type
            existing.tracks_weight = bool(parallel_tracks_weight)

            # Keep parenting mirrored when possible.
            if parallel_parent_id and existing.parent_id != parallel_parent_id:
                existing.parent_id = parallel_parent_id
                db.session.add(existing)

            # جميع كتابات memo_account_id تمر حصراً عبر link_accounts() —
            # الطريق الوحيد المعتمد — لضمان تنظيف stale pointers و1:1 و Audit Log.
            from account_pair_service import link_accounts as _link
            if self.transaction_type == 'cash':
                _link(self, existing, created_by='create_parallel_account')
            else:
                _link(existing, self, created_by='create_parallel_account')

            db.session.flush()
            return existing

        # إنشاء الحساب الموازي
        parallel_account = Account(
            account_number=parallel_number,
            name=parallel_name,
            type=self.type,  # نفس النوع (Asset, Liability, etc.)
            transaction_type=parallel_type,
            tracks_weight=parallel_tracks_weight,
            parent_id=parallel_parent_id
        )

        db.session.add(parallel_account)
        db.session.flush()  # ضروري: link_accounts() يتطلب id لكلا الطرفين

        # جميع كتابات memo_account_id تمر حصراً عبر link_accounts().
        from account_pair_service import link_accounts as _link
        if self.transaction_type == 'cash':
            _link(self, parallel_account, created_by='create_parallel_account')
        else:
            _link(parallel_account, self, created_by='create_parallel_account')

        db.session.flush()
        return parallel_account

    def __repr__(self):
        return f'<Account {self.name}>'

class PaymentMethod(db.Model):
    """
    نموذج وسائل الدفع المرتبطة بالخزائن
    التصميم الجديد: PaymentMethod → SafeBox → Account
    """
    __tablename__ = 'payment_method'
    
    id = db.Column(db.Integer, primary_key=True)
    
    # نوع وسيلة الدفع
    payment_type = db.Column(db.String(50), nullable=False)  # mada, visa, mastercard, apple_pay, stc_pay, tamara, tabby
    
    # اسم وسيلة الدفع
    name = db.Column(db.String(100), nullable=False)  # مثال: "مدى - بنك الراجحي"
    
    # نسبة العمولة (بدون VAT)
    commission_rate = db.Column(db.Float, default=0.0)  # مثال: 2.5 (يعني 2.5%)

    # عمولة ثابتة لكل عملية (بدون VAT)
    # تُضاف إلى العمولة النسبية عند الحساب (إن وُجدت)
    commission_fixed_amount = db.Column(db.Float, default=0.0)

    # متى تُسجل العمولة؟
    # - invoice: تُحسب/تُسجل ضمن الفاتورة (وتؤثر على net_amount)
    # - settlement: تُسجل عند التسوية (ولا تخصم ضمن الفاتورة)
    commission_timing = db.Column(db.String(20), default='invoice', nullable=False)
    
    # أيام التسوية
    settlement_days = db.Column(db.Integer, default=0)  # عدد أيام التسوية

    # 🆕 إعدادات التسوية التلقائية (مستحقات تحصيل → بنك)
    auto_settlement_enabled = db.Column(db.Boolean, default=False, nullable=False)

    # نوع الجدولة:
    # - days: تسوية بعد N أيام (تستخدم settlement_days)
    # - weekday: تسوية في يوم محدد من الأسبوع (0=Mon .. 6=Sun)
    settlement_schedule_type = db.Column(db.String(20), default='days', nullable=False)
    settlement_weekday = db.Column(db.Integer, nullable=True)

    # عدد أيام تأخير الإيداع بعد يوم التسوية (للجدولة الأسبوعية)
    # مثال: التسوية السبت (weekday=5) + تأخير 4 أيام = إيداع الأربعاء
    deposit_delay_days = db.Column(db.Integer, default=0, nullable=False)

    # نوع جدولة الإيداع (مستقل عن التسوية)
    # - days: الإيداع بعد N أيام من التسوية (السلوك الافتراضي، يستخدم deposit_delay_days)
    # - weekday: الإيداع في يوم ثابت بالأسبوع (مثل كل أحد) بغض النظر عن يوم التسوية
    deposit_schedule_type = db.Column(db.String(20), default='days', nullable=False)
    # يوم الأسبوع للإيداع عند deposit_schedule_type='weekday' (0=الاثنين .. 6=الأحد)
    deposit_weekday = db.Column(db.Integer, nullable=True)

    # الخزينة البنكية المستهدفة للتسوية التلقائية
    settlement_bank_safe_box_id = db.Column(
        db.Integer,
        db.ForeignKey('safe_box.id', ondelete='RESTRICT'),
        nullable=True,
    )
    settlement_bank_safe_box = db.relationship(
        'SafeBox',
        foreign_keys=[settlement_bank_safe_box_id],
        backref='payment_methods_settle_to_bank',
    )

    # الحد الأدنى لمبلغ التسوية (0 = بلا حد أدنى)
    # إذا كان رصيد التحصيل أقل من هذا المبلغ، تؤجل التسوية التلقائية
    min_settlement_amount = db.Column(db.Float, default=0.0, nullable=False)

    # نمط التسوية:
    # - bulk: تسوية مجمعة (سند واحد لكل المعاملات المستحقة)
    # - per_transaction: تسوية فردية (سند لكل معاملة على حدة)
    settlement_mode = db.Column(db.String(20), default='bulk', nullable=False)

    # حساب مصروف العمولة الافتراضي لهذه الوسيلة (يُحمَّل تلقائياً عند التسوية)
    fee_expense_account_id = db.Column(
        db.Integer,
        db.ForeignKey('account.id', ondelete='SET NULL'),
        nullable=True,
    )
    fee_expense_account = db.relationship(
        'Account',
        foreign_keys='PaymentMethod.fee_expense_account_id',
        backref='payment_methods_fee_expense',
    )

    # هل وسيلة الدفع نشطة؟
    is_active = db.Column(db.Boolean, default=True)
    
    # ترتيب العرض
    display_order = db.Column(db.Integer, default=999)

    # أنواع الفواتير المسموح بها لهذه الوسيلة
    applicable_invoice_types = db.Column(db.JSON, nullable=True)
    
    # 🆕 الربط بالخزينة الافتراضية (الطريقة الوحيدة للربط بشجرة الحسابات)
    default_safe_box_id = db.Column(
        db.Integer,
        db.ForeignKey('safe_box.id', ondelete='RESTRICT'),
        nullable=True,
    )
    default_safe_box = db.relationship(
        'SafeBox',
        foreign_keys=[default_safe_box_id],
        backref='payment_methods_using_as_default',
    )
    
    # تاريخ الإنشاء
    created_at = db.Column(db.DateTime, default=db.func.now())
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now())
    
    def to_dict(self):
        # 🆕 معلومات الخزينة الافتراضية (الطريقة الوحيدة للربط بشجرة الحسابات)
        safe_box_dict = None
        if self.default_safe_box:
            safe_box_dict = {
                'id': self.default_safe_box.id,
                'name': self.default_safe_box.name,
                'safe_type': self.default_safe_box.safe_type,
                'account_id': self.default_safe_box.account_id,
            }
        
        return {
            'id': self.id,
            'payment_type': self.payment_type,
            'name': self.name,
            'commission_rate': self.commission_rate,
            'commission_fixed_amount': getattr(self, 'commission_fixed_amount', 0.0) or 0.0,
            'commission_timing': getattr(self, 'commission_timing', 'invoice'),
            'settlement_days': getattr(self, 'settlement_days', 0),
            'auto_settlement_enabled': bool(getattr(self, 'auto_settlement_enabled', False)),
            'settlement_schedule_type': getattr(self, 'settlement_schedule_type', 'days') or 'days',
            'settlement_weekday': getattr(self, 'settlement_weekday', None),
            'deposit_delay_days': int(getattr(self, 'deposit_delay_days', 0) or 0),
            'deposit_schedule_type': getattr(self, 'deposit_schedule_type', 'days') or 'days',
            'deposit_weekday': getattr(self, 'deposit_weekday', None),
            'settlement_bank_safe_box_id': getattr(self, 'settlement_bank_safe_box_id', None),
            'fee_expense_account_id': getattr(self, 'fee_expense_account_id', None),
            'min_settlement_amount': float(getattr(self, 'min_settlement_amount', 0.0) or 0.0),
            'settlement_mode': str(getattr(self, 'settlement_mode', 'bulk') or 'bulk'),
            'is_active': self.is_active,
            'display_order': self.display_order,
            'applicable_invoice_types': list(self.applicable_invoice_types)
            if self.applicable_invoice_types
            else list(PAYMENT_METHOD_ALLOWED_INVOICE_TYPES),
            'default_safe_box_id': self.default_safe_box_id,
            'default_safe_box': safe_box_dict,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }
    
    def __repr__(self):
        return f'<PaymentMethod {self.name}>'


class PaymentType(db.Model):
    """
    نموذج أنواع وسائل الدفع - لجعل النظام ديناميكياً
    يتيح إضافة أنواع جديدة بدون تعديل الكود
    """
    __tablename__ = 'payment_type'
    
    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(50), unique=True, nullable=False)  # مثال: mada, visa, urpay
    name_ar = db.Column(db.String(100), nullable=False)  # الاسم بالعربية: مدى، فيزا، يوربي
    name_en = db.Column(db.String(100))  # الاسم بالإنجليزية (اختياري)
    icon = db.Column(db.String(10))  # الأيقونة: 💳, 📱, 🛍️
    category = db.Column(db.String(50))  # card, mobile_wallet, bnpl (buy now pay later), cash
    is_active = db.Column(db.Boolean, default=True)
    sort_order = db.Column(db.Integer, default=0)  # ترتيب العرض
    created_at = db.Column(db.DateTime, default=db.func.now())
    
    def to_dict(self):
        return {
            'id': self.id,
            'code': self.code,
            'name_ar': self.name_ar,
            'name_en': self.name_en,
            'icon': self.icon,
            'category': self.category,
            'is_active': self.is_active,
            'sort_order': self.sort_order,
        }
    
    def __repr__(self):
        return f'<PaymentType {self.code}>'


class Branch(db.Model):
    """فروع المعرض/المحل (كيان منفصل عن مكاتب التسكير)."""

    __tablename__ = 'branch'

    id = db.Column(db.Integer, primary_key=True)
    branch_code = db.Column(db.String(20), unique=True, nullable=False, index=True)
    name = db.Column(db.String(100), nullable=False)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=db.func.now())

    def to_dict(self):
        return {
            'id': self.id,
            'branch_code': self.branch_code,
            'name': self.name,
            'active': self.active,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }

    def __repr__(self):
        return f'<Branch {self.name}>'


class Office(db.Model):
    """مكاتب تسكير الذهب"""
    __tablename__ = 'office'
    
    id = db.Column(db.Integer, primary_key=True)
    
    # كود المكتب الفريد (O-000001, O-000002, ...)
    office_code = db.Column(db.String(20), unique=True, nullable=False, index=True)
    
    name = db.Column(db.String(100), nullable=False)
    phone = db.Column(db.String(20))
    email = db.Column(db.String(120))
    contact_person = db.Column(db.String(100))  # اسم الشخص المسؤول
    address_line_1 = db.Column(db.String(120))
    address_line_2 = db.Column(db.String(120))
    city = db.Column(db.String(80))
    state = db.Column(db.String(80))
    postal_code = db.Column(db.String(20))
    country = db.Column(db.String(50), default='Saudi Arabia')
    notes = db.Column(db.Text)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=db.func.now())
    
    # معلومات إضافية للمكاتب
    license_number = db.Column(db.String(50))  # رقم الترخيص
    tax_number = db.Column(db.String(50))  # الرقم الضريبي
    
    # الربط مع الحساب التجميعي في شجرة الحسابات
    account_category_id = db.Column(db.Integer, db.ForeignKey('account.id', name='fk_office_account_category'), nullable=True)
    account_category = db.relationship('Account', foreign_keys=[account_category_id])
    supplier_id = db.Column(db.Integer, db.ForeignKey('supplier.id', name='fk_office_supplier'), unique=True, nullable=True)
    supplier = db.relationship('Supplier', foreign_keys=[supplier_id], backref=db.backref('office', uselist=False))
    
    # الأرصدة (لتسريع الاستعلامات)
    balance_cash = db.Column(db.Float, default=0.0)
    balance_gold_18k = db.Column(db.Float, default=0.0)
    balance_gold_21k = db.Column(db.Float, default=0.0)
    balance_gold_22k = db.Column(db.Float, default=0.0)
    balance_gold_24k = db.Column(db.Float, default=0.0)
    total_reservations = db.Column(db.Integer, default=0)
    total_weight_purchased = db.Column(db.Float, default=0.0)
    total_amount_paid = db.Column(db.Float, default=0.0)

    reservations = db.relationship('OfficeReservation', backref='office', lazy=True, cascade='all, delete-orphan')

    def to_dict(self):
        supplier_default_safe_box = None
        try:
            supplier_default_safe_box = self.supplier.default_safe_box if self.supplier else None
        except Exception:
            supplier_default_safe_box = None
        return {
            'id': self.id,
            'office_code': self.office_code,
            'name': self.name,
            'phone': self.phone,
            'email': self.email,
            'contact_person': self.contact_person,
            'address_line_1': self.address_line_1,
            'address_line_2': self.address_line_2,
            'city': self.city,
            'state': self.state,
            'postal_code': self.postal_code,
            'country': self.country,
            'notes': self.notes,
            'active': self.active,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'license_number': self.license_number,
            'tax_number': self.tax_number,
            'account_category_id': self.account_category_id,
            'account_category_name': self.account_category.name if self.account_category else None,
            'supplier_id': self.supplier_id,
            'supplier_code': self.supplier.supplier_code if self.supplier else None,
            'supplier_name': self.supplier.name if self.supplier else None,
            'supplier_default_safe_box_id': getattr(self.supplier, 'default_safe_box_id', None) if self.supplier else None,
            'supplier_default_safe_box_name': supplier_default_safe_box.name if supplier_default_safe_box else None,
            'balance_cash': self.balance_cash,
            'balance_gold_18k': self.balance_gold_18k,
            'balance_gold_21k': self.balance_gold_21k,
            'balance_gold_22k': self.balance_gold_22k,
            'balance_gold_24k': self.balance_gold_24k,
            'total_reservations': self.total_reservations,
            'total_weight_purchased': self.total_weight_purchased,
            'total_amount_paid': self.total_amount_paid,
        }

    def __repr__(self):
        return f'<Office {self.name}>'


class OfficeReservation(db.Model):
    __tablename__ = 'office_reservation'

    id = db.Column(db.Integer, primary_key=True)
    office_id = db.Column(db.Integer, db.ForeignKey('office.id'), nullable=False, index=True)
    reservation_code = db.Column(db.String(30), nullable=False, unique=True)
    reservation_date = db.Column(db.DateTime, default=db.func.now())
    karat = db.Column(db.Integer, default=24)
    weight_grams = db.Column(db.Float, nullable=False)
    weight_main_karat = db.Column(db.Float, nullable=False)
    price_per_gram = db.Column(db.Float, nullable=False)
    execution_price_per_gram = db.Column(db.Float, nullable=False)
    total_amount = db.Column(db.Float, nullable=False)
    paid_amount = db.Column(db.Float, default=0.0)
    payment_status = db.Column(db.String(20), default='pending')
    status = db.Column(db.String(20), default='approved')
    contact_person = db.Column(db.String(100))
    contact_phone = db.Column(db.String(50))
    notes = db.Column(db.Text)
    executions_created = db.Column(db.Integer, default=0)
    weight_consumed_main_karat = db.Column(db.Float, default=0.0)
    weight_remaining_main_karat = db.Column(db.Float, default=0.0)
    # ربط بالفاتورة التي تثبت سداد الحجز (اختياري)
    purchase_invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now())
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now())

    def to_dict(self):
        return {
            'id': self.id,
            'office_id': self.office_id,
            'reservation_code': self.reservation_code,
            'reservation_date': self.reservation_date.isoformat() if self.reservation_date else None,
            'karat': self.karat,
            'weight_grams': self.weight_grams,
            'weight_main_karat': self.weight_main_karat,
            'price_per_gram': self.price_per_gram,
            'execution_price_per_gram': self.execution_price_per_gram,
            'total_amount': self.total_amount,
            'paid_amount': self.paid_amount,
            'payment_status': self.payment_status,
            'status': self.status,
            'contact_person': self.contact_person,
            'contact_phone': self.contact_phone,
            'notes': self.notes,
            'executions_created': self.executions_created,
            'weight_consumed_main_karat': self.weight_consumed_main_karat,
            'weight_remaining_main_karat': self.weight_remaining_main_karat,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
            'purchase_invoice_id': self.purchase_invoice_id,
        }


class Supplier(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    
    # كود المورد الفريد (S-000001, S-000002, ...)
    supplier_code = db.Column(db.String(20), unique=True, nullable=False, index=True)
    
    name = db.Column(db.String(100), nullable=False)
    phone = db.Column(db.String(20))
    email = db.Column(db.String(120))
    address_line_1 = db.Column(db.String(120))
    address_line_2 = db.Column(db.String(120))
    city = db.Column(db.String(80))
    state = db.Column(db.String(80))
    postal_code = db.Column(db.String(20))
    country = db.Column(db.String(50))
    notes = db.Column(db.Text)
    tax_number = db.Column(db.String(50))
    classification = db.Column(db.String(50))
    # How this supplier expects manufacturing wages to be settled by default:
    # - cash: wages are a SAR liability
    # - gold: wages are converted to gold weight (main karat) and added to gold liability
    default_wage_type = db.Column(db.String(10), default='cash')

    # Default cash/bank SafeBox for settlements (optional)
    default_safe_box_id = db.Column(
        db.Integer,
        db.ForeignKey('safe_box.id', name='fk_supplier_default_safe_box'),
        nullable=True,
    )
    default_safe_box = db.relationship('SafeBox', foreign_keys=[default_safe_box_id])
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=db.func.now())
    
    # الربط مع الحساب التجميعي في شجرة الحسابات (211)
    account_category_id = db.Column(db.Integer, db.ForeignKey('account.id', name='fk_supplier_account_category'), nullable=True)
    account_category = db.relationship('Account', foreign_keys=[account_category_id])
    
    # الحساب القديم (للتوافق - سيتم إزالته لاحقاً)
    account_id = db.Column(db.Integer, db.ForeignKey('account.id', name='fk_supplier_account_id'), nullable=True)
    account = db.relationship('Account', foreign_keys=[account_id], backref='supplier_old', uselist=False)
    
    # الأرصدة (لتسريع الاستعلامات)
    balance_cash = db.Column(db.Float, default=0.0)
    balance_gold_18k = db.Column(db.Float, default=0.0)
    balance_gold_21k = db.Column(db.Float, default=0.0)
    balance_gold_22k = db.Column(db.Float, default=0.0)
    balance_gold_24k = db.Column(db.Float, default=0.0)
    gold_balance_weight = db.Column(db.Float, default=0.0)
    gold_balance_cash_equivalent = db.Column(db.Float, default=0.0)
    last_gold_transaction_date = db.Column(db.DateTime, nullable=True)
    
    invoices = db.relationship('Invoice', backref='supplier', lazy=True)

    def to_dict(self):
        return {
            'id': self.id,
            'supplier_code': self.supplier_code,
            'name': self.name,
            'phone': self.phone,
            'email': self.email,
            'address_line_1': self.address_line_1,
            'address_line_2': self.address_line_2,
            'city': self.city,
            'state': self.state,
            'postal_code': self.postal_code,
            'country': self.country,
            'notes': self.notes,
            'tax_number': self.tax_number,
            'classification': self.classification,
            'default_wage_type': self.default_wage_type or 'cash',
            'default_safe_box_id': self.default_safe_box_id,
            'default_safe_box_name': self.default_safe_box.name if self.default_safe_box else None,
            'active': self.active,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'account_category_id': self.account_category_id,
            'account_category_name': self.account_category.name if self.account_category else None,
            'account_id': self.account_id,
            'account_name': self.account.name if self.account else None,
            'balance_cash': self.balance_cash,
            'balance_gold_18k': self.balance_gold_18k,
            'balance_gold_21k': self.balance_gold_21k,
            'balance_gold_22k': self.balance_gold_22k,
            'balance_gold_24k': self.balance_gold_24k,
            'gold_balance_weight': self.gold_balance_weight,
            'gold_balance_cash_equivalent': self.gold_balance_cash_equivalent,
            'last_gold_transaction_date': self.last_gold_transaction_date.isoformat() if self.last_gold_transaction_date else None,
        }

    def to_dict_with_account(self):
        return self.to_dict()

    def __repr__(self):
        return f'<Supplier {self.name}>'

class Customer(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    
    # كود العميل الفريد (C-000001, C-000002, ...)
    customer_code = db.Column(db.String(20), unique=True, nullable=False, index=True)
    
    name = db.Column(db.String(100), nullable=False)
    phone = db.Column(db.String(20))
    email = db.Column(db.String(120))
    address_line_1 = db.Column(db.String(120))
    address_line_2 = db.Column(db.String(120))
    city = db.Column(db.String(80))
    state = db.Column(db.String(80))
    postal_code = db.Column(db.String(20))
    country = db.Column(db.String(50))
    id_number = db.Column(db.String(50))
    birth_date = db.Column(db.Date)
    id_version_number = db.Column(db.String(50))
    notes = db.Column(db.Text)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=db.func.now())
    
    # الربط مع الحساب التجميعي في شجرة الحسابات (1100، 1110، 1120)
    account_category_id = db.Column(db.Integer, db.ForeignKey('account.id', name='fk_customer_account_category'), nullable=True)
    account_category = db.relationship('Account', foreign_keys=[account_category_id])
    
    # الحساب القديم (للتوافق مع النظام القديم - سيتم إزالته لاحقاً)
    account_id = db.Column(db.Integer, db.ForeignKey('account.id', name='fk_customer_account_id'), nullable=True)
    account = db.relationship('Account', foreign_keys=[account_id], backref='customer_old', uselist=False)
    
    # الأرصدة (لتسريع الاستعلامات)
    balance_cash = db.Column(db.Float, default=0.0)
    balance_gold_18k = db.Column(db.Float, default=0.0)
    balance_gold_21k = db.Column(db.Float, default=0.0)
    balance_gold_22k = db.Column(db.Float, default=0.0)
    balance_gold_24k = db.Column(db.Float, default=0.0)

    # 'عميل' | 'مورد' — للفلترة في تقارير السيولة والمستحقات
    customer_type = db.Column(db.String(20), nullable=True)

    invoices = db.relationship('Invoice', backref='customer', lazy=True, cascade="all, delete-orphan")

    def to_dict(self):
        return {
            'id': self.id,
            'customer_code': self.customer_code,
            'name': self.name,
            'phone': self.phone,
            'email': self.email,
            'address_line_1': self.address_line_1,
            'address_line_2': self.address_line_2,
            'city': self.city,
            'state': self.state,
            'postal_code': self.postal_code,
            'country': self.country,
            'id_number': self.id_number,
            'birth_date': self.birth_date.isoformat() if self.birth_date else None,
            'id_version_number': self.id_version_number,
            'notes': self.notes,
            'active': self.active,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'account_category_id': self.account_category_id,
            'account_category_name': self.account_category.name if self.account_category else None,
            'account_id': self.account_id,
            'account_name': self.account.name if self.account else None,
            'balance_cash': self.balance_cash,
            'balance_gold_18k': self.balance_gold_18k,
            'balance_gold_21k': self.balance_gold_21k,
            'balance_gold_22k': self.balance_gold_22k,
            'balance_gold_24k': self.balance_gold_24k,
        }

    def to_dict_with_account(self):
        return self.to_dict()

class Category(db.Model):
    """تصنيفات الأصناف - لتحسين دقة التقارير"""
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False, unique=True)
    description = db.Column(db.String(200))
    karat = db.Column(db.String(10), nullable=True)
    default_wage = db.Column(db.Float, nullable=True)  # متوسط أجور مصنعية افتراضي للتصنيف
    created_at = db.Column(db.DateTime, default=datetime.now)

    # العلاقة مع الأصناف
    items = db.relationship('Item', backref='category', lazy=True)

    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'description': self.description,
            'karat': self.karat,
            'default_wage': self.default_wage,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'items_count': len(self.items)
        }


class Item(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    
    # كود الصنف الفريد (I-000001, I-000002, ...)
    item_code = db.Column(db.String(20), unique=True, nullable=False, index=True)
    
    name = db.Column(db.String(100), nullable=False)
    barcode = db.Column(db.String(100), unique=True, nullable=True, index=True)  # باركود فريد (اختياري - يُولّد تلقائياً إذا كان فارغاً)
    
    # 🆕 التصنيف
    category_id = db.Column(db.Integer, db.ForeignKey('category.id'), nullable=True)
    
    karat = db.Column(db.String(10))  # عيار
    weight = db.Column(db.Float)      # وزن
    
    # 🆕 معلومات الأحجار
    has_stones = db.Column(db.Boolean, default=False, nullable=False)  # هل يحتوي على أحجار؟
    stones_weight = db.Column(db.Float, default=0.0, nullable=True)    # وزن الأحجار (بالجرام)
    stones_value = db.Column(db.Float, default=0.0, nullable=True)     # قيمة الأحجار (بالريال)
    def weight_in_main_karat(self):
        """
        تحويل الوزن إلى العيار الرئيسي
        """
        try:
            main_karat = _configured_main_karat_f()
            karat_value = float(self.karat)
            if not main_karat:
                return self.weight
            return self.weight * karat_value / main_karat
        except Exception:
            return self.weight
    count = db.Column(db.Integer)     # عدد
    wage = db.Column(db.Float)        # أجرة المصنعية

    def wage_in_gold(self):
        """
        تحويل أجرة المصنعية إلى ما يعادلها بالذهب
        """
        try:
            main_karat = _configured_main_karat_f()
            if not main_karat:
                return self.wage
            return self.wage / main_karat
        except Exception:
            return self.wage
    
    # 🆕 حقل جديد: أجرة المصنعية للجرام (لفواتير الشراء)
    manufacturing_wage_per_gram = db.Column(db.Float, default=0.0, nullable=True)  # أجرة المصنعية/جرام
    
    description = db.Column(db.String(200))
    price = db.Column(db.Float, nullable=False)
    stock = db.Column(db.Integer, default=0)
    invoice_items = db.relationship('InvoiceItem', backref='item', lazy=True)

    @staticmethod
    def periodic_inventory_report():
        """
        إجراء جرد دوري للمخزون بالوزن ومقارنته بالسجلات
        """
        from backend.models import db, Item
        items = Item.query.all()
        report = []
        for item in items:
            report.append({
                'id': item.id,
                'name': item.name,
                'karat': item.karat,
                'weight': item.weight,
                'weight_in_main_karat': item.weight_in_main_karat(),
                'stock': item.stock
            })
        return report

class Invoice(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    invoice_type_id = db.Column(db.Integer, nullable=False)
    customer_id = db.Column(db.Integer, db.ForeignKey('customer.id'), nullable=True)
    supplier_id = db.Column(db.Integer, db.ForeignKey('supplier.id'), nullable=True)
    # 🆕 الموظف المنفّذ/البائع (مربوط بحساب المستخدم)
    employee_id = db.Column(db.Integer, db.ForeignKey('employee.id'), nullable=True)
    branch_id = db.Column(db.Integer, db.ForeignKey('branch.id'), nullable=True)  # 🆕 الفرع (منفصل عن مكاتب التسكير)
    office_id = db.Column(db.Integer, db.ForeignKey('office.id'), nullable=True)  # 🆕 للتسكير من المكاتب
    date = db.Column(db.DateTime, nullable=False)
    total = db.Column(db.Float, nullable=False)

    branch = db.relationship('Branch', foreign_keys=[branch_id])
    employee = db.relationship('Employee', foreign_keys=[employee_id])
    
    # نوع الفاتورة - 6 أنواع
    # 'بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء', 'مرتجع شراء (مورد)'
    invoice_type = db.Column(db.String(50), nullable=False, server_default='بيع')
    
    # حالة الدفع
    status = db.Column(db.String(50), default='unpaid') # unpaid, paid, partially_paid
    
    # 🆕 نظام الترحيل (Posting System)
    is_posted = db.Column(db.Boolean, default=False, nullable=False, index=True)  # هل تم ترحيل الفاتورة؟
    posted_at = db.Column(db.DateTime, nullable=True)  # متى تم الترحيل؟
    posted_by = db.Column(db.String(100), nullable=True)  # من قام بالترحيل؟
    
    # الربط بالفاتورة الأصلية (للمرتجعات فقط)
    original_invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=True)
    
    # سبب الإرجاع (للمرتجعات فقط)
    return_reason = db.Column(db.Text, nullable=True)
    
    # نوع الذهب: 'new' (جديد) أو 'scrap' (كسر)
    gold_type = db.Column(db.String(20), nullable=True, server_default='new')
    
    total_weight = db.Column(db.Float)
    total_tax = db.Column(db.Float)
    total_cost = db.Column(db.Float)
    gold_subtotal = db.Column(db.Float, default=0.0)
    wage_subtotal = db.Column(db.Float, default=0.0)
    gold_tax_total = db.Column(db.Float, default=0.0)
    wage_tax_total = db.Column(db.Float, default=0.0)
    apply_gold_tax = db.Column(db.Boolean, default=False)
    avg_cost_per_gram_snapshot = db.Column(db.Float, default=0.0)
    avg_cost_gold_component = db.Column(db.Float, default=0.0)
    avg_cost_manufacturing_component = db.Column(db.Float, default=0.0)
    avg_cost_total_snapshot = db.Column(db.Float, default=0.0)
    settlement_status = db.Column(db.String(20), default='pending')
    settlement_method = db.Column(db.String(20), nullable=True)
    settlement_date = db.Column(db.DateTime, nullable=True)
    settlement_price_per_gram = db.Column(db.Float, nullable=True)
    settlement_cash_amount = db.Column(db.Float, default=0.0)
    settlement_gold_weight = db.Column(db.Float, default=0.0)

    # 🆕 ملخص أمر التسكير (التزامات الذهب)
    weight_closing_status = db.Column(db.String(20), default='not_initialized')
    weight_closing_main_karat = db.Column(db.Float, default=21.0)
    weight_closing_total_weight = db.Column(db.Float, default=0.0)
    weight_closing_executed_weight = db.Column(db.Float, default=0.0)
    weight_closing_remaining_weight = db.Column(db.Float, default=0.0)
    weight_closing_close_price = db.Column(db.Float, default=0.0)
    weight_closing_order_number = db.Column(db.String(30), nullable=True)
    weight_closing_price_source = db.Column(db.String(20), nullable=True)
    
    # 🆕 حقول الربح بالذهب
    profit_cash = db.Column(db.Float, default=0.0)  # الربح النقدي (ر.س)
    profit_gold = db.Column(db.Float, default=0.0)  # الربح بالذهب (جم)
    profit_weight_price_per_gram = db.Column(db.Float, default=0.0)  # سعر التحويل المستخدم للربح الوزني

    # عمولة السداد بذهب صافي (عيار 24)
    gold24k_settlement = db.Column(db.Boolean, default=False)
    gold24k_weight = db.Column(db.Float, default=0.0)           # الوزن المسلَّم بعيار 24
    gold24k_commission_per_gram = db.Column(db.Float, default=0.0)  # العمولة / جم
    gold24k_commission_total = db.Column(db.Float, default=0.0)     # إجمالي العمولة

    # عمولة / رسوم فرق العيار (شاملة — تدعم الاتجاهين)
    karat_diff_settlement = db.Column(db.Boolean, default=False)
    karat_diff_owed_karat = db.Column(db.Float, default=0.0)
    karat_diff_paid_karat = db.Column(db.Float, default=0.0)
    karat_diff_weight = db.Column(db.Float, default=0.0)
    karat_diff_per_gram = db.Column(db.Float, default=0.0)
    karat_diff_total = db.Column(db.Float, default=0.0)
    karat_diff_earn_total = db.Column(db.Float, default=0.0)   # عمولة تكسبها الشركة (مدين للمورد)
    karat_diff_pay_total = db.Column(db.Float, default=0.0)    # رسوم تدفعها الشركة (دائن للمورد)

    # سبب توقف الفاتورة للاعتماد (يُحفظ عند الإنشاء، يُعرض في قائمة المعلقات)
    pending_approval_reason = db.Column(db.Text, nullable=True)

    # 🆕 قالب الطباعة الخاص بهذه الفاتورة (Preset key from Template Studio)
    # مثال: a4_portrait, a5_portrait, thermal_80x200
    print_template_preset_key = db.Column(db.String(64), nullable=True)
    
    # 🆕 ربط بوسيلة الدفع (Foreign Key)
    payment_method_id = db.Column(db.Integer, db.ForeignKey('payment_method.id'), nullable=True)
    payment_method_obj = db.relationship('PaymentMethod', backref='invoices')
    
    # 🆕 ربط بالخزينة (SafeBox)
    safe_box_id = db.Column(
        db.Integer,
        db.ForeignKey('safe_box.id', ondelete='RESTRICT'),
        nullable=True,
    )
    safe_box = db.relationship('SafeBox', backref='invoices')
    
    # الاحتفاظ بالحقل القديم للتوافق مع الفواتير القديمة
    payment_method = db.Column(db.String(50))
    
    # 🆕 العمولة المحسوبة (تُحسب تلقائياً من payment_method.commission_rate)
    commission_amount = db.Column(db.Float, default=0.0)
    net_amount = db.Column(db.Float)  # المبلغ الصافي بعد خصم العمولة
    
    amount_paid = db.Column(db.Float)
    
    # Fields for purchase barter
    payment_gold_weight = db.Column(db.Float, nullable=True)
    payment_gold_karat = db.Column(db.Float, nullable=True)
    wage_payment_method = db.Column(db.String(50), nullable=True)
    net_gold_difference_21k = db.Column(db.Float, nullable=True)
    total_wage = db.Column(db.Float, nullable=True)
    wage_in_gold_21k = db.Column(db.Float, nullable=True)
    manufacturing_wage_mode_snapshot = db.Column(db.String(20), nullable=True)
    wage_inventory_account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=True)
    wage_inventory_account = db.relationship('Account', foreign_keys=[wage_inventory_account_id])
    wage_inventory_balance_main_karat = db.Column(db.Float, default=0.0)

    # Fields for partial/deferred payments
    settled_gold_weight = db.Column(db.Float, nullable=True)
    settled_wage_amount = db.Column(db.Float, nullable=True)

    # 🆕 Cash-equivalent amount settled via barter/trade-in (used in sales payment netting).
    barter_total = db.Column(db.Float, default=0.0, nullable=False)

    # 🆕 Identity of who holds received scrap gold (barter flow) without using SafeBox.
    scrap_holder_employee_id = db.Column(db.Integer, db.ForeignKey('employee.id'), nullable=True)
    scrap_holder_employee = db.relationship('Employee', foreign_keys=[scrap_holder_employee_id])

    # 🆕 Link a customer scrap-purchase invoice back to the originating sale invoice (barter flow)
    barter_sale_invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=True)

    # Commerce API link — set for online orders synced via ERPSyncWorker.
    # Unique per order; NULL for POS invoices.
    commerce_order_id = db.Column(db.String(100), nullable=True, unique=True)

    items = db.relationship('InvoiceItem', backref='invoice', lazy=True)
    
    # 🆕 علاقة مع دفعات متعددة (One-to-Many)
    payments = db.relationship('InvoicePayment', backref='invoice', lazy=True, cascade='all, delete-orphan')
    
    # 🆕 سطور العيارات لمشتريات الموردين
    karat_lines = db.relationship('InvoiceKaratLine', backref='invoice', lazy=True, cascade='all, delete-orphan')
    
    # العلاقة بالفاتورة الأصلية (للمرتجعات)
    original_invoice = db.relationship('Invoice', remote_side=[id], foreign_keys=[original_invoice_id], backref='returns', uselist=False)

    # 🆕 تسويات الوزن (مصروف/تسكير)
    weight_settlements = db.relationship('InvoiceWeightSettlement', backref='invoice', lazy=True, cascade='all, delete-orphan')

    __table_args__ = (db.UniqueConstraint('invoice_type', 'invoice_type_id', name='_invoice_type_uc'),)

    @property
    def invoice_number(self) -> str:
        """Computed invoice number.

        NOTE: This intentionally does NOT depend on a DB column, so it works
        in production databases that haven't had an `invoice_number` migration.
        """
        try:
            from invoice_number_generator import generate_invoice_number

            invoice_type_value = (getattr(self, 'invoice_type', None) or '').strip()
            if 'مورد' in invoice_type_value and 'شراء' in invoice_type_value:
                if 'مرتجع' in invoice_type_value:
                    invoice_type_value = 'مرتجع شراء (مورد)'
                else:
                    invoice_type_value = 'شراء'

            return generate_invoice_number(
                invoice_type=invoice_type_value or 'INV',
                invoice_type_id=int(getattr(self, 'invoice_type_id', 0) or 0),
                invoice_date=getattr(self, 'date', None),
                use_arabic=False,
            )
        except Exception:
            try:
                return f"INV-{int(getattr(self, 'id', 0) or 0)}"
            except Exception:
                return "INV"

    def to_dict(self):
        invoice_type_value = (self.invoice_type or '').strip()
        if 'مورد' in invoice_type_value and 'شراء' in invoice_type_value:
            if 'مرتجع' in invoice_type_value:
                invoice_type_value = 'مرتجع شراء (مورد)'
            else:
                invoice_type_value = 'شراء'

        effective_total_weight = self.total_weight
        effective_total_weight_mk = None  # الوزن المعادل بالعيار الرئيسي
        try:
            if getattr(self, 'karat_lines', None):
                kl_sum = 0.0
                kl_sum_mk = 0.0
                for kl in self.karat_lines:
                    lw = float(getattr(kl, 'weight_grams', 0.0) or 0.0)
                    lk = float(getattr(kl, 'karat', MAIN_KARAT) or MAIN_KARAT)
                    kl_sum += lw
                    kl_sum_mk += lw * lk / MAIN_KARAT
                if kl_sum > 0:
                    effective_total_weight = round(kl_sum, 4)
                    effective_total_weight_mk = round(kl_sum_mk, 4)
            if effective_total_weight_mk is None and getattr(self, 'items', None):
                ii_sum = 0.0
                ii_sum_mk = 0.0
                for ii in self.items:
                    iw = float(getattr(ii, 'weight', 0.0) or 0.0)
                    ik = float(getattr(ii, 'karat', 0.0) or 0.0) or MAIN_KARAT
                    ii_sum += iw
                    ii_sum_mk += iw * ik / MAIN_KARAT
                if ii_sum > 0:
                    effective_total_weight_mk = round(ii_sum_mk, 4)
        except Exception:
            effective_total_weight = self.total_weight

        result = {
            'id': self.id,
            'invoice_type_id': self.invoice_type_id,
            'invoice_number': getattr(self, 'invoice_number', None),
            'customer_id': self.customer_id,
            'supplier_id': self.supplier_id,
            'employee_id': self.employee_id,
            'branch_id': self.branch_id,
            'office_id': self.office_id,  # 🆕 المكتب
            'date': self.date.isoformat(),
            'total': self.total,
            'invoice_type': invoice_type_value,
            'status': self.status,
            'is_posted': self.is_posted,  # 🆕 حالة الترحيل
            'posted_at': self.posted_at.isoformat() if self.posted_at else None,  # 🆕
            'posted_by': self.posted_by,  # 🆕
            'total_weight': effective_total_weight,
            'total_weight_main_karat': effective_total_weight_mk,
            'total_tax': self.total_tax,
            'total_cost': self.total_cost,
            'gold_subtotal': self.gold_subtotal,
            'wage_subtotal': self.wage_subtotal,
            'gold_tax_total': self.gold_tax_total,
            'wage_tax_total': self.wage_tax_total,
            'apply_gold_tax': self.apply_gold_tax,
            'avg_cost_per_gram_snapshot': self.avg_cost_per_gram_snapshot,
            'avg_cost_gold_component': self.avg_cost_gold_component,
            'avg_cost_manufacturing_component': self.avg_cost_manufacturing_component,
            'avg_cost_total_snapshot': self.avg_cost_total_snapshot,
            'settlement_status': self.settlement_status,
            'settlement_method': self.settlement_method,
            'settlement_date': self.settlement_date.isoformat() if self.settlement_date else None,
            'settlement_price_per_gram': self.settlement_price_per_gram,
            'settlement_cash_amount': self.settlement_cash_amount,
            'settlement_gold_weight': self.settlement_gold_weight,
            'weight_closing_status': self.weight_closing_status,
            'weight_closing_main_karat': self.weight_closing_main_karat,
            'weight_closing_total_weight': self.weight_closing_total_weight,
            'weight_closing_executed_weight': self.weight_closing_executed_weight,
            'weight_closing_remaining_weight': self.weight_closing_remaining_weight,
            'weight_closing_close_price': self.weight_closing_close_price,
            'weight_closing_order_number': self.weight_closing_order_number,
            'weight_closing_price_source': self.weight_closing_price_source,
            'profit_cash': self.profit_cash,  # 🆕 الربح النقدي
            'profit_gold': self.profit_gold,  # 🆕 الربح بالذهب
            'profit_weight_price_per_gram': self.profit_weight_price_per_gram,
            'print_template_preset_key': self.print_template_preset_key,
            'payment_method': self.payment_method,  # للتوافق مع الفواتير القديمة
            'payment_method_id': self.payment_method_id,
            'commission_amount': self.commission_amount,
            'net_amount': self.net_amount,
            'amount_paid': self.amount_paid,
            'barter_total': float(getattr(self, 'barter_total', 0.0) or 0.0),
            'manufacturing_wage_mode_snapshot': self.manufacturing_wage_mode_snapshot,
            'wage_inventory_account_id': self.wage_inventory_account_id,
            'wage_inventory_balance_main_karat': self.wage_inventory_balance_main_karat,
            'safe_box_id': self.safe_box_id,  # 🆕 الخزينة
            'scrap_holder_employee_id': getattr(self, 'scrap_holder_employee_id', None),
            'barter_sale_invoice_id': getattr(self, 'barter_sale_invoice_id', None),
            'original_invoice_id': self.original_invoice_id,
            'return_reason': self.return_reason,
            'gold_type': self.gold_type,
            'items': [item.to_dict() for item in self.items]
        }

        # Read-only helper: total settled value (cash/bank + barter).
        try:
            paid_amount = float(self.amount_paid or 0.0)
        except Exception:
            paid_amount = 0.0
        try:
            barter_total = float(getattr(self, 'barter_total', 0.0) or 0.0)
        except Exception:
            barter_total = 0.0
        result['total_settled_amount'] = round(paid_amount + barter_total, 2)

        try:
            result['scrap_holder_employee_name'] = (
                self.scrap_holder_employee.name if self.scrap_holder_employee else None
            )
        except Exception:
            result['scrap_holder_employee_name'] = None

        # 🆕 اسم الموظف المنفذ
        # - المصدر الأساسي: employee_id المخزن على الفاتورة
        # - fallback: محاولة ربط posted_by كـ username في AppUser
        # - fallback أخير: posted_by كتسمية عرض
        try:
            employee_name = None

            # 1) Direct relationship / employee_id
            if self.employee and self.employee.name:
                employee_name = self.employee.name
            elif getattr(self, 'employee_id', None):
                try:
                    emp = Employee.query.get(self.employee_id)
                    if emp and emp.name:
                        employee_name = emp.name
                except Exception:
                    employee_name = None

            # 2) Map posted_by to AppUser.username (case-insensitive/trim)
            if employee_name is None and self.posted_by:
                try:
                    from sqlalchemy import func

                    posted_by_key = str(self.posted_by).strip().lower()
                    user = AppUser.query.filter(
                        func.lower(func.trim(AppUser.username)) == posted_by_key
                    ).first()
                    if user and user.employee and user.employee.name:
                        employee_name = user.employee.name
                except Exception:
                    employee_name = None

            # 3) Final fallback: show posted_by as-is
            if employee_name is None:
                employee_name = self.posted_by

            result['employee_name'] = employee_name
        except Exception:
            result['employee_name'] = None

        # 🆕 اسم الفرع (اختياري) لتسهيل العرض في الواجهات
        try:
            result['branch_name'] = self.branch.name if self.branch else None
        except Exception:
            result['branch_name'] = None


        # 🆕 إضافة تفاصيل الخزينة
        if self.safe_box:
            result['safe_box_details'] = {
                'id': self.safe_box.id,
                'name': self.safe_box.name,
                'safe_type': self.safe_box.safe_type,
            }
        
        # 🆕 إضافة تفاصيل وسيلة الدفع القديمة (للتوافق)
        if self.payment_method_obj:
            account_info = None
            default_safe_box = getattr(self.payment_method_obj, 'default_safe_box', None)
            if default_safe_box and getattr(default_safe_box, 'account', None):
                account_info = {
                    'id': default_safe_box.account.id,
                    'account_number': default_safe_box.account.account_number,
                    'name': default_safe_box.account.name
                }
            result['payment_method_details'] = {
                'id': self.payment_method_obj.id,
                'name': self.payment_method_obj.name,
                'commission_rate': self.payment_method_obj.commission_rate,
                'account': account_info
            }
        
        # 🆕 إضافة دفعات متعددة (الميزة الجديدة)
        if self.payments:
            result['payments'] = [payment.to_dict() for payment in self.payments]
            # حساب إجماليات الدفعات (حماية من None)
            result['total_payments_amount'] = sum((p.amount or 0.0) for p in self.payments)
            result['total_commission'] = sum((p.commission_amount or 0.0) for p in self.payments)
            result['total_net'] = sum((p.net_amount or 0.0) for p in self.payments)
        else:
            result['payments'] = []
        
        if self.karat_lines:
            result['karat_lines'] = [line.to_dict() for line in self.karat_lines]
        else:
            result['karat_lines'] = []

        if self.weight_settlements:
            result['weight_settlements'] = [settlement.to_dict() for settlement in self.weight_settlements]
        else:
            result['weight_settlements'] = []
        
        return result

    def calculate_total_weight(self):
        """
        حساب إجمالي وزن الفاتورة بالعيار الرئيسي، بما في ذلك الأصناف اليدوية.
        """

        main_karat = _configured_main_karat_f()

        def _to_float(value, default=0.0):
            try:
                if value in (None, ''):
                    return default
                return float(value)
            except (TypeError, ValueError):
                return default

        def _convert_to_main_karat(weight_value, karat_value):
            weight_float = _to_float(weight_value, 0.0)
            karat_float = _to_float(karat_value, main_karat)
            if weight_float <= 0 or karat_float <= 0:
                return 0.0
            if not main_karat:
                return weight_float
            return (weight_float * karat_float) / main_karat

        base_weight = 0.0

        # v2: أولوية لـ karat_lines (الأكثر دقة) — بدون ضرب في الكمية
        if self.karat_lines:
            kl_weight = 0.0
            for line in self.karat_lines:
                kl_weight += _convert_to_main_karat(line.weight_grams or 0, line.karat or main_karat)
            if kl_weight > 0:
                return kl_weight

        # v2: InvoiceItem.weight = الوزن الكلي للسطر — لا يُضرب في الكمية
        for invoice_item in self.items:
            if invoice_item.weight is not None and invoice_item.weight > 0:
                base_weight += _convert_to_main_karat(invoice_item.weight, invoice_item.karat or main_karat)
            elif invoice_item.item:
                # احتياط: وزن الكتالوج (للصنف غير الوزن السطر) × الكمية
                quantity = invoice_item.quantity or 1
                base_weight += (invoice_item.item.weight_in_main_karat() or 0.0) * quantity

        return base_weight

    def total_wage_in_gold(self):
        """
        حساب إجمالي أجرة المصنعية بالذهب
        """
        main_karat = _configured_main_karat_f()
        if not main_karat:
            return sum(ii.item.wage * ii.quantity for ii in self.items)
        return sum(ii.item.wage * ii.quantity / main_karat for ii in self.items)

    def profit_loss_in_gold(self):
        """
        حساب الربح أو الخسارة بالذهب (الفرق بين الوزن الداخل والخارج)
        """
        # يمكن تعديل المنطق حسب نوع الحركة (بيع/شراء)
        # هنا مثال بسيط: الربح = إجمالي الوزن - إجمالي المصاريف بالذهب
        return self.total_weight() - self.total_wage_in_gold()

class InvoiceItem(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=False)
    item_id = db.Column(db.Integer, db.ForeignKey('item.id'))
    category_id = db.Column(db.Integer, db.ForeignKey('category.id'), nullable=True)
    name = db.Column(db.String(100))
    quantity = db.Column(db.Integer, nullable=False)
    price = db.Column(db.Float, nullable=False)
    karat = db.Column(db.Float)
    weight = db.Column(db.Float)
    standing_weight = db.Column(db.Float, default=0.0)
    stones_weight = db.Column(db.Float, default=0.0)
    direct_purchase_price_per_gram = db.Column(db.Float, default=0.0)
    wage = db.Column(db.Float)
    net = db.Column(db.Float)
    tax = db.Column(db.Float)
    avg_cost_per_gram_snapshot = db.Column(db.Float, default=0.0)
    profit_cash = db.Column(db.Float, default=0.0)
    profit_weight = db.Column(db.Float, default=0.0)
    profit_weight_price_per_gram = db.Column(db.Float, default=0.0)

    def to_dict(self):
        # Resolve category name via relationship or direct query
        category_name = None
        if self.category_id:
            try:
                from models import Category
                cat = Category.query.get(self.category_id)
                category_name = cat.name if cat else None
            except Exception:
                pass
        return {
            'id': self.id,
            'invoice_id': self.invoice_id,
            'item_id': self.item_id,
            'category_id': self.category_id,
            'category_name': category_name,
            'name': self.name,
            'quantity': self.quantity,
            'price': self.price,
            'karat': self.karat,
            'weight': self.weight,
            'standing_weight': self.standing_weight,
            'stones_weight': self.stones_weight,
            'direct_purchase_price_per_gram': self.direct_purchase_price_per_gram,
            'wage': self.wage,
            'net': self.net,
            'tax': self.tax,
            'avg_cost_per_gram_snapshot': self.avg_cost_per_gram_snapshot,
            'profit_cash': self.profit_cash,
            'profit_weight': self.profit_weight,
            'profit_weight_price_per_gram': self.profit_weight_price_per_gram,
            'weight_closing_logs': [log.to_dict() for log in self.weight_closing_logs]
        }

    weight_closing_logs = db.relationship(
        'WeightClosingLog',
        backref='sale_item',
        lazy=True,
        cascade='all, delete-orphan'
    )


class CategoryWeightMovement(db.Model):
    """Track weight movements by Category and location (gold SafeBox).

    This supports non-coded inventory workflows where stock is tracked by
    category totals per location (showroom vs employee custody), without
    requiring per-piece item coding.
    """

    __tablename__ = 'category_weight_movement'

    id = db.Column(db.Integer, primary_key=True)
    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False, index=True)

    category_id = db.Column(db.Integer, db.ForeignKey('category.id', ondelete='RESTRICT'), nullable=False, index=True)
    safe_box_id = db.Column(db.Integer, db.ForeignKey('safe_box.id', ondelete='RESTRICT'), nullable=False, index=True)

    invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id', ondelete='SET NULL'), nullable=True, index=True)

    # Optional: preserve traceability to the original line payload by storing a line label.
    line_label = db.Column(db.String(200), nullable=True)

    invoice_type = db.Column(db.String(50), nullable=True)  # e.g. بيع/شراء/مرتجع...
    gold_type = db.Column(db.String(20), nullable=True)  # new/scrap

    karat = db.Column(db.Float, nullable=True)

    # Signed delta: + adds to stock, - removes from stock.
    weight_delta_grams = db.Column(db.Float, nullable=False, default=0.0)
    weight_delta_main_karat = db.Column(db.Float, nullable=False, default=0.0)

    created_by = db.Column(db.String(100), nullable=True)
    note = db.Column(db.Text, nullable=True)

    category = db.relationship('Category', foreign_keys=[category_id])
    safe_box = db.relationship('SafeBox', foreign_keys=[safe_box_id])
    invoice = db.relationship('Invoice', foreign_keys=[invoice_id])

    def to_dict(self):
        return {
            'id': self.id,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'category_id': self.category_id,
            'category_name': self.category.name if self.category else None,
            'safe_box_id': self.safe_box_id,
            'safe_box_name': self.safe_box.name if self.safe_box else None,
            'invoice_id': self.invoice_id,
            'invoice_type': self.invoice_type,
            'gold_type': self.gold_type,
            'karat': self.karat,
            'weight_delta_grams': float(self.weight_delta_grams or 0.0),
            'weight_delta_main_karat': float(self.weight_delta_main_karat or 0.0),
            'created_by': self.created_by,
            'line_label': self.line_label,
            'note': self.note,
        }


class InvoiceKaratLine(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=False)
    karat = db.Column(db.Float, nullable=False)
    weight_grams = db.Column(db.Float, nullable=False)
    gold_value_cash = db.Column(db.Float, default=0.0)
    manufacturing_wage_cash = db.Column(db.Float, default=0.0)
    gold_tax = db.Column(db.Float, default=0.0)
    wage_tax = db.Column(db.Float, default=0.0)
    description = db.Column(db.String(200))

    def to_dict(self):
        return {
            'id': self.id,
            'invoice_id': self.invoice_id,
            'karat': self.karat,
            'weight_grams': self.weight_grams,
            'gold_value_cash': self.gold_value_cash,
            'manufacturing_wage_cash': self.manufacturing_wage_cash,
            'gold_tax': self.gold_tax,
            'wage_tax': self.wage_tax,
            'description': self.description,
        }


class WeightClosingLog(db.Model):
    __tablename__ = 'weight_closing_log'

    id = db.Column(db.Integer, primary_key=True)
    sale_item_id = db.Column(db.Integer, db.ForeignKey('invoice_item.id'), nullable=False, index=True)
    profit_weight = db.Column(db.Float, default=0.0)
    profit_cash = db.Column(db.Float, default=0.0)
    snapshot_cost_per_gram = db.Column(db.Float, default=0.0)
    close_price = db.Column(db.Float, nullable=False)
    close_value = db.Column(db.Float, default=0.0)
    difference_value = db.Column(db.Float, default=0.0)
    difference_weight = db.Column(db.Float, default=0.0)
    close_date = db.Column(db.DateTime, default=db.func.now())
    journal_entry_id = db.Column(db.Integer, db.ForeignKey('journal_entry.id'), nullable=True)

    def to_dict(self):
        return {
            'id': self.id,
            'sale_item_id': self.sale_item_id,
            'profit_weight': self.profit_weight,
            'profit_cash': self.profit_cash,
            'snapshot_cost_per_gram': self.snapshot_cost_per_gram,
            'close_price': self.close_price,
            'close_value': self.close_value,
            'difference_value': self.difference_value,
            'difference_weight': self.difference_weight,
            'close_date': self.close_date.isoformat() if self.close_date else None,
            'journal_entry_id': self.journal_entry_id,
            'difference_value_realized': self.difference_value if self.journal_entry_id else 0.0,
        }


class WeightClosingOrder(db.Model):
    __tablename__ = 'weight_closing_order'

    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=False, unique=True, index=True)
    order_number = db.Column(db.String(30), unique=True, nullable=False)
    status = db.Column(db.String(20), default='open', nullable=False)
    main_karat = db.Column(db.Float, default=21.0, nullable=False)
    price_source = db.Column(db.String(20), default='live', nullable=False)
    close_price_per_gram = db.Column(db.Float, default=0.0, nullable=False)
    gold_value_cash = db.Column(db.Float, default=0.0)
    manufacturing_wage_cash = db.Column(db.Float, default=0.0)
    profit_weight_main_karat = db.Column(db.Float, default=0.0)
    total_cash_value = db.Column(db.Float, default=0.0)
    total_weight_main_karat = db.Column(db.Float, default=0.0)
    executed_weight_main_karat = db.Column(db.Float, default=0.0)
    remaining_weight_main_karat = db.Column(db.Float, default=0.0)
    valuation_journal_entry_id = db.Column(db.Integer, db.ForeignKey('journal_entry.id'), nullable=True)
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=db.func.now())
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now())

    invoice = db.relationship('Invoice', backref=db.backref('weight_closing_order', uselist=False, cascade='all, delete-orphan', single_parent=True))
    valuation_journal_entry = db.relationship('JournalEntry', backref='weight_closing_orders', lazy=True)

    executions = db.relationship(
        'WeightClosingExecution',
        backref='order',
        lazy=True,
        cascade='all, delete-orphan'
    )

    def to_dict(self, include_executions: bool = True):
        payload = {
            'id': self.id,
            'invoice_id': self.invoice_id,
            'order_number': self.order_number,
            'status': self.status,
            'main_karat': self.main_karat,
            'price_source': self.price_source,
            'close_price_per_gram': self.close_price_per_gram,
            'gold_value_cash': self.gold_value_cash,
            'manufacturing_wage_cash': self.manufacturing_wage_cash,
            'profit_weight_main_karat': self.profit_weight_main_karat,
            'total_cash_value': self.total_cash_value,
            'total_weight_main_karat': self.total_weight_main_karat,
            'executed_weight_main_karat': self.executed_weight_main_karat,
            'remaining_weight_main_karat': self.remaining_weight_main_karat,
            'valuation_journal_entry_id': self.valuation_journal_entry_id,
            'notes': self.notes,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }
        if include_executions:
            payload['executions'] = [execution.to_dict() for execution in self.executions]
        return payload


class WeightClosingExecution(db.Model):
    __tablename__ = 'weight_closing_execution'

    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer, db.ForeignKey('weight_closing_order.id'), nullable=False, index=True)
    source_invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=True)
    execution_type = db.Column(db.String(30), nullable=False, default='purchase_scrap')
    weight_main_karat = db.Column(db.Float, default=0.0)
    price_per_gram = db.Column(db.Float, default=0.0)
    difference_value = db.Column(db.Float, default=0.0)
    difference_weight = db.Column(db.Float, default=0.0)
    journal_entry_id = db.Column(db.Integer, db.ForeignKey('journal_entry.id'), nullable=True)
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=db.func.now())

    source_invoice = db.relationship('Invoice', backref='weight_closing_executions', foreign_keys=[source_invoice_id])
    journal_entry = db.relationship('JournalEntry', backref='weight_closing_executions', lazy=True)

    def to_dict(self):
        return {
            'id': self.id,
            'order_id': self.order_id,
            'source_invoice_id': self.source_invoice_id,
            'execution_type': self.execution_type,
            'weight_main_karat': self.weight_main_karat,
            'price_per_gram': self.price_per_gram,
            'difference_value': self.difference_value,
            'difference_weight': self.difference_weight,
            'journal_entry_id': self.journal_entry_id,
            'notes': self.notes,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }


class InvoiceWeightSettlement(db.Model):
    __tablename__ = 'invoice_weight_settlement'

    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=False, index=True)
    settlement_type = db.Column(db.String(20), default='expense', nullable=False)  # expense | weight
    required_weight = db.Column(db.Float, default=0.0)
    required_cash = db.Column(db.Float, default=0.0)
    executed_weight = db.Column(db.Float, default=0.0)
    executed_cash = db.Column(db.Float, default=0.0)
    rate_used = db.Column(db.Float, default=0.0)
    status = db.Column(db.String(20), default='pending')  # pending | partially_closed | closed
    journal_entry_id = db.Column(db.Integer, db.ForeignKey('journal_entry.id'), nullable=True)
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=db.func.now())
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now())

    def to_dict(self):
        return {
            'id': self.id,
            'invoice_id': self.invoice_id,
            'settlement_type': self.settlement_type,
            'required_weight': round(self.required_weight or 0.0, 6),
            'required_cash': round(self.required_cash or 0.0, 2),
            'executed_weight': round(self.executed_weight or 0.0, 6),
            'executed_cash': round(self.executed_cash or 0.0, 2),
            'rate_used': round(self.rate_used or 0.0, 4),
            'status': self.status,
            'journal_entry_id': self.journal_entry_id,
            'notes': self.notes,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }

# Install Flask-SQLAlchemy
# RUN: pip install flask_sqlalchemy

# نموذج لتخزين سعر الذهب
class GoldPrice(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    price = db.Column(db.Float, nullable=False)
    date = db.Column(db.DateTime, default=db.func.now())


class InventoryCostingConfig(db.Model):
    __tablename__ = 'inventory_costing_config'

    id = db.Column(db.Integer, primary_key=True)
    # 'normal' = supplier purchases (new gold), 'scrap' = scrap/settlement purchases
    costing_type = db.Column(db.String(20), default='normal', nullable=False)
    costing_method = db.Column(db.String(20), default='moving_average')
    current_avg_cost_per_gram = db.Column(db.Float, default=0.0)
    avg_gold_price_per_gram = db.Column(db.Float, default=0.0)
    avg_manufacturing_per_gram = db.Column(db.Float, default=0.0)
    avg_total_cost_per_gram = db.Column(db.Float, default=0.0)
    total_inventory_weight = db.Column(db.Float, default=0.0)
    total_gold_value = db.Column(db.Float, default=0.0)
    total_manufacturing_value = db.Column(db.Float, default=0.0)
    last_purchase_price = db.Column(db.Float, nullable=True)
    last_purchase_weight = db.Column(db.Float, nullable=True)
    last_updated = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now())
    created_at = db.Column(db.DateTime, default=db.func.now())

    def to_dict(self):
        return {
            'id': self.id,
            'costing_method': self.costing_method,
            'current_avg_cost_per_gram': self.current_avg_cost_per_gram,
            'avg_gold_price_per_gram': self.avg_gold_price_per_gram,
            'avg_manufacturing_per_gram': self.avg_manufacturing_per_gram,
            'avg_total_cost_per_gram': self.avg_total_cost_per_gram,
            'total_inventory_weight': self.total_inventory_weight,
            'total_gold_value': self.total_gold_value,
            'total_manufacturing_value': self.total_manufacturing_value,
            'last_purchase_price': self.last_purchase_price,
            'last_purchase_weight': self.last_purchase_weight,
            'last_updated': self.last_updated.isoformat() if self.last_updated else None,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }


class SupplierGoldTransaction(db.Model):
    __tablename__ = 'supplier_gold_transaction'

    id = db.Column(db.Integer, primary_key=True)
    supplier_id = db.Column(db.Integer, db.ForeignKey('supplier.id'), nullable=False)
    supplier = db.relationship('Supplier', backref=db.backref('gold_transactions', lazy='dynamic'))
    invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=True)
    invoice = db.relationship('Invoice', backref='gold_transactions')
    journal_entry_id = db.Column(db.Integer, db.ForeignKey('journal_entry.id'), nullable=True)
    journal_entry = db.relationship('JournalEntry', backref='supplier_gold_transactions')
    transaction_type = db.Column(db.String(50), nullable=False)
    gold_weight = db.Column(db.Float, nullable=False)
    original_karat = db.Column(db.Float, nullable=True)
    original_weight = db.Column(db.Float, nullable=True)
    price_per_gram = db.Column(db.Float, nullable=False)
    manufacturing_wage_per_gram = db.Column(db.Float, default=0.0)
    cash_amount = db.Column(db.Float, nullable=False)
    settlement_price_per_gram = db.Column(db.Float, nullable=True)
    settlement_cash_amount = db.Column(db.Float, default=0.0)
    settlement_gold_weight = db.Column(db.Float, default=0.0)
    notes = db.Column(db.Text, nullable=True)
    transaction_date = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    created_by = db.Column(db.String(100), nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)

    def to_dict(self):
        return {
            'id': self.id,
            'supplier_id': self.supplier_id,
            'invoice_id': self.invoice_id,
            'journal_entry_id': self.journal_entry_id,
            'transaction_type': self.transaction_type,
            'gold_weight': self.gold_weight,
            'original_karat': self.original_karat,
            'original_weight': self.original_weight,
            'price_per_gram': self.price_per_gram,
            'manufacturing_wage_per_gram': self.manufacturing_wage_per_gram,
            'cash_amount': self.cash_amount,
            'settlement_price_per_gram': self.settlement_price_per_gram,
            'settlement_cash_amount': self.settlement_cash_amount,
            'settlement_gold_weight': self.settlement_gold_weight,
            'notes': self.notes,
            'transaction_date': self.transaction_date.isoformat() if self.transaction_date else None,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }

# نموذج قيد اليومية
class JournalEntry(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    entry_number = db.Column(db.String(50), unique=True, nullable=False)  # رقم القيد
    date = db.Column(db.DateTime, nullable=False, default=db.func.now())
    description = db.Column(db.String(200))
    entry_type = db.Column(db.String(50), default='عادي', nullable=False)  # نوع القيد: عادي، دوري، افتتاحي، إقفال
    reference_type = db.Column(db.String(50))  # نوع المرجع (voucher, invoice, etc.)
    reference_id = db.Column(db.Integer)  # معرف المرجع
    reference_number = db.Column(db.String(100))  # رقم المرجع الخارجي (رقم الفاتورة، السند، إلخ)
    recurring_template_id = db.Column(db.Integer, db.ForeignKey('recurring_journal_template.id'), nullable=True)  # ربط بالقالب الدوري
    created_by = db.Column(db.String(100))
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=True)

    # نظام المسودات (Draft) أصبح غير مُعتمد؛ يتم الاعتماد على نظام الترحيل (Posting).
    # نُبقي الحقل للتوافق مع قواعد بيانات قديمة/واجهات قديمة، لكن الافتراضي الآن: ليس مسودة.
    is_draft = db.Column(db.Boolean, default=False, nullable=False, index=True)  # هل القيد مسودة؟
    
    # 🆕 نظام الترحيل (Posting System)
    is_posted = db.Column(db.Boolean, default=False, nullable=False, index=True)  # هل تم ترحيل القيد؟
    posted_at = db.Column(db.DateTime, nullable=True)  # متى تم الترحيل؟
    posted_by = db.Column(db.String(100), nullable=True)  # من قام بالترحيل؟
    
    # حقول نظام الحذف الآمن (Soft Delete)
    is_deleted = db.Column(db.Boolean, default=False, nullable=False, index=True)
    deleted_at = db.Column(db.DateTime, nullable=True)
    deleted_by = db.Column(db.String(100), nullable=True)
    deletion_reason = db.Column(db.String(500), nullable=True)
    
    # حقول الاسترجاع
    restored_at = db.Column(db.DateTime, nullable=True)
    restored_by = db.Column(db.String(100), nullable=True)
    
    lines = db.relationship('JournalEntryLine', backref='journal_entry', lazy=True, cascade="all, delete-orphan")

    def soft_delete(self, deleted_by, reason=None):
        """حذف ناعم للقيد مع تسجيل المعلومات"""
        from datetime import datetime
        self.is_deleted = True
        self.deleted_at = datetime.now()
        self.deleted_by = deleted_by
        self.deletion_reason = reason
        
    def restore(self, restored_by):
        """استرجاع القيد المحذوف"""
        from datetime import datetime
        self.is_deleted = False
        self.restored_at = datetime.now()
        self.restored_by = restored_by
        
    def to_dict(self, include_deleted_info=False):
        """تحويل القيد إلى قاموس"""
        result = {
            'id': self.id,
            'entry_number': self.entry_number,
            'date': self.date.isoformat(),
            'description': self.description,
            'entry_type': self.entry_type,
            'reference_type': self.reference_type,
            'reference_id': self.reference_id,
            'reference_number': self.reference_number,
            'created_by': self.created_by,
            'is_draft': self.is_draft,  # 🆕 حالة المسودة
            'is_posted': self.is_posted,  # 🆕 حالة الترحيل
            'posted_at': self.posted_at.isoformat() if self.posted_at else None,  # 🆕
            'posted_by': self.posted_by,  # 🆕
            'lines': [line.to_dict() for line in self.lines if not line.is_deleted]
        }
        
        if include_deleted_info:
            result.update({
                'is_deleted': self.is_deleted,
                'deleted_at': self.deleted_at.isoformat() if self.deleted_at else None,
                'deleted_by': self.deleted_by,
                'deletion_reason': self.deletion_reason,
                'restored_at': self.restored_at.isoformat() if self.restored_at else None,
                'restored_by': self.restored_by
            })
            
        return result


# Auto-generate `entry_number` for JournalEntry when not provided.
def _generate_journal_entry_number_for_date(connection, entry_date: datetime, prefix: str = 'JE') -> str:
    """Generate a unique sequential entry_number inside the current DB transaction.

    Uses MAX(entry_number) (not COUNT) + a per-connection cache to avoid duplicates
    when multiple JournalEntry rows are inserted within the same flush.
    """
    year = int(entry_date.year)
    prefix_str = str(prefix)
    number_prefix = f'{prefix_str}-{year}-'

    cache = connection.info.setdefault('_je_entry_number_seq_cache', {})
    cache_key = (prefix_str, year)
    last_seq = cache.get(cache_key)

    if last_seq is None:
        row = connection.execute(
            text(
                "SELECT entry_number FROM journal_entry "
                "WHERE entry_number LIKE :p "
                "ORDER BY entry_number DESC LIMIT 1"
            ),
            {"p": f"{number_prefix}%"},
        ).fetchone()

        if row and row[0]:
            try:
                last_seq = int(str(row[0]).split('-')[-1])
            except Exception:
                last_seq = 0
        else:
            last_seq = 0

    next_seq = int(last_seq) + 1
    while True:
        candidate = f'{number_prefix}{next_seq:05d}'
        exists = connection.execute(
            text("SELECT 1 FROM journal_entry WHERE entry_number = :n LIMIT 1"),
            {"n": candidate},
        ).fetchone()
        if not exists:
            cache[cache_key] = next_seq
            return candidate
        next_seq += 1


@event.listens_for(JournalEntry, 'before_insert')
def _ensure_entry_number(mapper, connection, target):
    # Only set if not provided
    if not getattr(target, 'entry_number', None):
        entry_dt = getattr(target, 'date', None) or datetime.now()
        try:
            target.entry_number = _generate_journal_entry_number_for_date(connection, entry_dt)
        except Exception:
            # As a last resort, set a placeholder to avoid NOT NULL failure
            target.entry_number = f'JE-{datetime.now().year}-00000'

# نموذج لأسطر قيد اليومية
class JournalEntryLine(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    journal_entry_id = db.Column(db.Integer, db.ForeignKey('journal_entry.id'), nullable=False)
    account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=False)
    account = db.relationship('Account')
    
    # ربط مع العملاء والموردين (اختياري - فقط للحسابات المتعلقة بهم)
    customer_id = db.Column(db.Integer, db.ForeignKey('customer.id', name='fk_jel_customer'), nullable=True)
    customer = db.relationship('Customer', backref='journal_lines')
    
    supplier_id = db.Column(db.Integer, db.ForeignKey('supplier.id', name='fk_jel_supplier'), nullable=True)
    supplier = db.relationship('Supplier', backref='journal_lines')
    
    # حقول الحذف الناعم
    is_deleted = db.Column(db.Boolean, default=False, nullable=False)
    deleted_at = db.Column(db.DateTime, nullable=True)
    gold_transaction_id = db.Column(db.Integer, db.ForeignKey('supplier_gold_transaction.id'), nullable=True)
    gold_transaction = db.relationship('SupplierGoldTransaction', backref='journal_lines')
    gold_weight_equiv = db.Column(db.Float, nullable=True)
    gold_price_applied = db.Column(db.Float, nullable=True)
    
    # Cash
    cash_debit = db.Column(db.Float, default=0.0)
    cash_credit = db.Column(db.Float, default=0.0)

    # Gold Karat 18
    debit_18k = db.Column(db.Float, default=0.0)
    credit_18k = db.Column(db.Float, default=0.0)

    # Gold Karat 21
    debit_21k = db.Column(db.Float, default=0.0)
    credit_21k = db.Column(db.Float, default=0.0)

    # Gold Karat 22
    debit_22k = db.Column(db.Float, default=0.0)
    credit_22k = db.Column(db.Float, default=0.0)

    # Gold Karat 24
    debit_24k = db.Column(db.Float, default=0.0)
    credit_24k = db.Column(db.Float, default=0.0)
    
    # أعمدة الوزن المعادل (للحسابات المذكرة - النظام المزدوج)
    # تحسب بقسمة القيمة النقدية على السعر المباشر للذهب
    debit_weight = db.Column(db.Float, default=0.0)  # الوزن المعادل المدين
    credit_weight = db.Column(db.Float, default=0.0)  # الوزن المعادل الدائن
    gold_price_snapshot = db.Column(db.Float, nullable=True)  # السعر المباشر المستخدم للتحويل
    description = db.Column(db.String(500), nullable=True)  # وصف القيد
    
    # 🆕 نوع الوزن: فعلي (PHYSICAL) أو تحليلي (ANALYTICAL)
    # PHYSICAL: وزن حقيقي للمخزون (inventory actual weight)
    # ANALYTICAL: وزن محسوب من القيمة النقدية (converted from cash value)
    weight_type = db.Column(db.String(20), default='ANALYTICAL', nullable=True)  # PHYSICAL | ANALYTICAL

    # 🆕 Financial Dimensions (SAP/D365-style)
    dimension_set_id = db.Column(db.Integer, db.ForeignKey('dimension_set.id'), nullable=True)

    # 🆕 Analytics measures (line-level)
    # Signed metrics: debit positive, credit negative.
    analytic_amount_cash = db.Column(db.Float, nullable=True)
    analytic_weight_24k = db.Column(db.Float, nullable=True)
    analytic_weight_main = db.Column(db.Float, nullable=True)

    def to_dict(self):
        return {
            'id': self.id,
            'journal_entry_id': self.journal_entry_id,
            'account_id': self.account_id,
            'account_number': self.account.account_number if self.account else None,
            'account_name': self.account.name if self.account else '',
            'customer_id': self.customer_id,
            'customer_name': self.customer.name if self.customer else None,
            'customer_code': self.customer.customer_code if self.customer else None,
            'supplier_id': self.supplier_id,
            'supplier_name': self.supplier.name if self.supplier else None,
            'supplier_code': self.supplier.supplier_code if self.supplier else None,
            'cash_debit': self.cash_debit,
            'cash_credit': self.cash_credit,
            'gold_weight_equiv': self.gold_weight_equiv,
            'gold_price_applied': self.gold_price_applied,
            'gold_transaction_id': self.gold_transaction_id,
            'debit_18k': self.debit_18k,
            'credit_18k': self.credit_18k,
            'debit_21k': self.debit_21k,
            'credit_21k': self.credit_21k,
            'debit_22k': self.debit_22k,
            'credit_22k': self.credit_22k,
            'debit_24k': self.debit_24k,
            'credit_24k': self.credit_24k,
            'debit_weight': self.debit_weight,
            'credit_weight': self.credit_weight,
            'gold_price_snapshot': self.gold_price_snapshot,
            'weight_type': self.weight_type,  # 🆕
            'dimension_set_id': self.dimension_set_id,
            'analytic_amount_cash': self.analytic_amount_cash,
            'analytic_weight_24k': self.analytic_weight_24k,
            'analytic_weight_main': self.analytic_weight_main,
            'description': self.description,
        }


_CLEARING_ACCOUNT_GUARD_LOGGER = logging.getLogger('clearing_account_guard')

# Stage-2 (audit mode): provisionally allowed reference_type values on
# clearing accounts, based on everything actually observed across مدى/تابي/
# تمارا/فيزا-ماستر while investigating مدى's balance history. 'voucher' stays
# allowed deliberately -- it covers both legitimate legacy migration-era
# receipts and at least one questionable ad-hoc transfer (RV-2026-00482), and
# there isn't yet enough evidence to tell those apart by reference_type alone.
# Anything outside this set is NOT blocked yet -- only logged -- so a real
# legitimate path we haven't audited isn't broken. Promote to a hard
# whitelist (stage 3) only after a observation period with zero unexpected
# warnings.
_KNOWN_CLEARING_REFERENCE_TYPES = {
    'clearing_settlement',
    'invoice_payment',
    'invoice_payments',
    'voucher',
    'voucher_reversal',
    'payment_method_correction',
    'invoice',
}


def _validate_journal_entry_line_clearing_account_or_raise(line: 'JournalEntryLine') -> None:
    """Stage-1 (enforced) + stage-2 (audit-only) clearing-account guard.

    Any JournalEntryLine touching a clearing-type safe box's account (مدى,
    تابي, تمارا, فيزا/ماستر, ...) must belong to a JournalEntry with a
    non-empty reference_type. An unattributed entry on a clearing account is
    exactly how a historical ~4380 SAR adjustment on مدى's account became
    untraceable (no reference_type, no created_by, no link to any process).
    This is the only condition actually enforced (raises and blocks).

    Stage 2: if reference_type is present but not in
    _KNOWN_CLEARING_REFERENCE_TYPES, log a warning and allow it through
    anyway. This collects real evidence of any reference_type we haven't
    audited yet before stage 3 turns it into a hard rejection.
    """
    account_id = getattr(line, 'account_id', None)
    if not account_id:
        return

    is_clearing_account = (
        SafeBox.query.filter_by(safe_type='clearing', account_id=account_id).first() is not None
    )
    if not is_clearing_account:
        return

    journal_entry_id = getattr(line, 'journal_entry_id', None)
    entry = JournalEntry.query.get(journal_entry_id) if journal_entry_id else None
    reference_type = (getattr(entry, 'reference_type', None) or '').strip() if entry else ''

    if not reference_type:
        raise ValueError(
            f"Unclassified JournalEntryLine on clearing account #{account_id}: the parent "
            f"JournalEntry has no reference_type. Entries touching a clearing-account must be "
            f"explicitly classified (e.g. 'clearing_settlement' via the settlement engine, or a "
            f"tagged manual reconciliation/correction entry with a stated reason)."
        )

    if reference_type not in _KNOWN_CLEARING_REFERENCE_TYPES:
        _CLEARING_ACCOUNT_GUARD_LOGGER.warning(
            "[stage-2 audit] Unknown reference_type=%r touching clearing account #%s "
            "(JournalEntry#%s, created_by=%r) -- not blocked yet, review before stage-3 enforcement.",
            reference_type, account_id, journal_entry_id, getattr(entry, 'created_by', None),
        )


@event.listens_for(JournalEntryLine, 'before_insert')
def _guard_journal_entry_line_clearing_account_before_insert(mapper, connection, target):
    _validate_journal_entry_line_clearing_account_or_raise(target)


@event.listens_for(JournalEntryLine, 'before_update')
def _guard_journal_entry_line_clearing_account_before_update(mapper, connection, target):
    _validate_journal_entry_line_clearing_account_or_raise(target)


class DimensionDefinition(db.Model):
    __tablename__ = 'dimension_definition'

    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(50), unique=True, nullable=False, index=True)
    name_ar = db.Column(db.String(100), nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now())


class DimensionValue(db.Model):
    __tablename__ = 'dimension_value'

    id = db.Column(db.Integer, primary_key=True)
    definition_id = db.Column(db.Integer, db.ForeignKey('dimension_definition.id'), nullable=False, index=True)
    definition = db.relationship('DimensionDefinition')

    int_value = db.Column(db.Integer, nullable=True, index=True)
    str_value = db.Column(db.String(200), nullable=True, index=True)
    label_ar = db.Column(db.String(200), nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now())

    __table_args__ = (
        db.UniqueConstraint('definition_id', 'int_value', 'str_value', name='uq_dimension_value_def_val'),
    )


class DimensionSet(db.Model):
    __tablename__ = 'dimension_set'

    id = db.Column(db.Integer, primary_key=True)
    key_hash = db.Column(db.String(64), unique=True, nullable=False, index=True)
    created_at = db.Column(db.DateTime, default=db.func.now())


class DimensionSetItem(db.Model):
    __tablename__ = 'dimension_set_item'

    id = db.Column(db.Integer, primary_key=True)
    dimension_set_id = db.Column(db.Integer, db.ForeignKey('dimension_set.id'), nullable=False, index=True)
    dimension_set = db.relationship('DimensionSet', backref='items')

    dimension_value_id = db.Column(db.Integer, db.ForeignKey('dimension_value.id'), nullable=False, index=True)
    dimension_value = db.relationship('DimensionValue')

    __table_args__ = (
        db.UniqueConstraint('dimension_set_id', 'dimension_value_id', name='uq_dimension_set_item'),
    )

class Settings(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    
    # إعدادات أساسية
    main_karat = db.Column(db.Integer, default=21)
    currency_symbol = db.Column(db.String(10), default='ر.س')
    manufacturing_wage_mode = db.Column(db.String(20), default='expense')  # expense | inventory

    # أرقام حسابات المكافآت القابلة للتخصيص (NULL = بحث تلقائي بالاسم)
    bonus_expense_account_number = db.Column(db.String(20), nullable=True)
    bonus_payable_account_number = db.Column(db.String(20), nullable=True)

    # Feature Flags — أنواع مكافآت تعتمد على مصادر بيانات لم تُكتمل بعد
    # default=False: يمنع إنشاء قواعد تُنتج نتائج وهمية في الإنتاج
    bonus_attendance_enabled  = db.Column(db.Boolean, nullable=False, default=False)
    bonus_performance_enabled = db.Column(db.Boolean, nullable=False, default=False)

    # إعدادات الضريبة
    tax_rate = db.Column(db.Float, default=0.15)  # 15%
    tax_enabled = db.Column(db.Boolean, default=True)

    # 🆕 العيارات المعفاة من ضريبة الذهب (JSON list stored as TEXT)
    # مثال: ["24"] أو [24]
    vat_exempt_karats = db.Column(db.Text, nullable=True)
    
    # وسائل الدفع (JSON)
    # مثال: [{"name": "نقداً", "commission": 0}, {"name": "بطاقة", "commission": 2.5}]
    payment_methods = db.Column(db.Text, default='[{"name":"نقداً","commission":0},{"name":"بطاقة","commission":2.5},{"name":"تحويل","commission":1.5},{"name":"آجل","commission":0}]')
    
    # إعدادات الفواتير
    invoice_prefix = db.Column(db.String(10), default='INV')
    show_company_logo = db.Column(db.Boolean, default=True)
    company_name = db.Column(db.String(100), default='مجوهرات خالد')
    # Base64-encoded image bytes (optionally with data URL prefix).
    # Kept as TEXT for SQLite compatibility.
    company_logo_base64 = db.Column(db.Text, nullable=True)
    company_address = db.Column(db.Text)
    company_phone = db.Column(db.String(50))
    company_tax_number = db.Column(db.String(50))
    company_cr_number = db.Column(db.String(50))

    # 🆕 افتراضي قالب الطباعة حسب نوع الفاتورة (JSON)
    # مثال: {"بيع":"a4_portrait","شراء من عميل":"a5_portrait"}
    print_template_by_invoice_type = db.Column(db.Text, nullable=True)
    
    # إعدادات التنسيق
    decimal_places = db.Column(db.Integer, default=2)
    date_format = db.Column(db.String(20), default='DD/MM/YYYY')
    
    # إعدادات الخصم
    default_discount_rate = db.Column(db.Float, default=0.0)  # نسبة خصم افتراضية
    allow_discount = db.Column(db.Boolean, default=True)
    allow_manual_invoice_items = db.Column(db.Boolean, default=True)

    # 🆕 إعدادات الأمان
    # عند التفعيل: يمنع إنشاء الفواتير بدون Authorization token
    require_auth_for_invoice_create = db.Column(db.Boolean, default=False)

    # 🆕 إنهاء الجلسة عند عدم النشاط (Auto logout)
    # عند التعطيل: لا يتم فرض انتهاء الجلسة بسبب عدم النشاط
    idle_timeout_enabled = db.Column(db.Boolean, default=True)

    # 🆕 مدة الخمول بالدقائق
    # تُستخدم فقط إذا كان idle_timeout_enabled=True
    idle_timeout_minutes = db.Column(db.Integer, default=30)

    # 🆕 السماح بالدفع الجزئي/البيع الآجل عند إنشاء الفواتير
    # عند التعطيل: يجب أن يساوي مجموع الدفعات إجمالي الفاتورة
    allow_partial_invoice_payments = db.Column(db.Boolean, default=False)

    # ==========================================
    # 🆕 Feature Toggles لمسار خزائن الموظفين
    # ==========================================
    # عند التفعيل: تُستخدم خزائن الموظفين (إن كانت مربوطة بالموظف) كمسار افتراضي للنقد/الذهب
    employee_cash_safes_enabled = db.Column(db.Boolean, default=False)
    employee_gold_safes_enabled = db.Column(db.Boolean, default=False)

    # ==========================================
    # 🆕 خزائن افتراضية للنظام (Fallback)
    # ==========================================
    # الخزينة النقدية الرئيسية (صندوق المحل)
    main_cash_safe_box_id = db.Column(db.Integer, db.ForeignKey('safe_box.id'), nullable=True)
    main_cash_safe_box = db.relationship('SafeBox', foreign_keys=[main_cash_safe_box_id])

    # خزينة الذهب للمعروض للبيع (ذهب مشغول معروض للبيع)
    sale_gold_safe_box_id = db.Column(db.Integer, db.ForeignKey('safe_box.id'), nullable=True)
    sale_gold_safe_box = db.relationship('SafeBox', foreign_keys=[sale_gold_safe_box_id])

    # خزينة الذهب للكسر الرئيسية (صندوق الكسر الرئيسي)
    main_scrap_gold_safe_box_id = db.Column(db.Integer, db.ForeignKey('safe_box.id'), nullable=True)
    main_scrap_gold_safe_box = db.relationship('SafeBox', foreign_keys=[main_scrap_gold_safe_box_id])

    # ==========================================
    # حسابات الفصوص (Stones Accounts)
    # ==========================================
    # حساب الفصوص المعلقة: يُقيَّد دائناً عند شراء قطعة تحتوي فصوصاً
    # ويُقيَّد مديناً عند تحويل القطعة للعرض (تجديد)
    stones_pending_account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=True)
    stones_pending_account = db.relationship('Account', foreign_keys=[stones_pending_account_id])

    # حساب إيراد الفصوص المعروضة: يُقيَّد دائناً عند تحويل القطعة للعرض (تجديد)
    stones_display_revenue_account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=True)
    stones_display_revenue_account = db.relationship('Account', foreign_keys=[stones_display_revenue_account_id])

    # ==========================================
    # 🆕 إعدادات الترحيل (Posting Preferences)
    # ==========================================
    # ترحيل الفواتير تلقائياً فور الحفظ
    auto_post_invoices = db.Column(db.Boolean, default=True)
    # ترحيل القيود تلقائياً فور الحفظ
    auto_post_entries = db.Column(db.Boolean, default=True)
    # طلب موافقة قبل الترحيل (يؤثر على بوابات الاعتماد - below_cost/large_discount)
    require_approval_before_post = db.Column(db.Boolean, default=False)
    # السماح بإلغاء ترحيل الفواتير والقيود المرحلة
    allow_unposting = db.Column(db.Boolean, default=False)
    
    # 🆕 إعدادات السندات
    voucher_auto_post = db.Column(db.Boolean, default=False)  # False = يتطلب اعتماد قبل الترحيل، True = ترحيل تلقائي
    weight_closing_settings = db.Column(db.Text, nullable=True)

    # 🆕 تحديث سعر الذهب تلقائياً حسب توقيت معين
    gold_price_auto_update_enabled = db.Column(db.Boolean, default=False)
    # Stored as "HH:MM" in server local time.
    gold_price_auto_update_time = db.Column(db.String(5), default='09:00')
    # interval | daily
    gold_price_auto_update_mode = db.Column(db.String(20), default='interval')
    gold_price_auto_update_interval_minutes = db.Column(db.Integer, default=60)

    # 🆕 النسخ الاحتياطي التلقائي (على السيرفر)
    backup_auto_enabled = db.Column(db.Boolean, default=False)
    # interval | daily
    backup_auto_mode = db.Column(db.String(20), default='daily')
    # Stored as "HH:MM" in server local time (used when mode=daily)
    backup_auto_time = db.Column(db.String(5), default='02:00')
    backup_auto_interval_minutes = db.Column(db.Integer, default=1440)
    # Keep last N backups on the server
    backup_retention_count = db.Column(db.Integer, default=7)

    # 🆕 سياسة كلمات المرور (JSON)
    # مثال: {"min_length": 6, "require_numbers": false}
    password_policy = db.Column(db.Text, nullable=True)

    # 🆕 تعطيل bootstraps عند بدء التشغيل (مفيد بعد Full System Wipe)
    # عندما True: لا يتم seed لشجرة الحسابات أو حسابات الدعم تلقائياً عند تشغيل السيرفر.
    disable_startup_bootstrap = db.Column(db.Boolean, default=False)

    # ==========================================
    # 🆕 Gamification Targets
    # ==========================================
    # هدف وزن مبيعات الأسبوع (بالجرام) لاستخدامه في تحدي الفريق.
    weekly_sales_target_weight = db.Column(db.Float, default=2000.0)
    monthly_sales_target_weight = db.Column(db.Float, default=8000.0)
    sales_race_settings = db.Column(db.Text, nullable=True)
    
    created_at = db.Column(db.DateTime, default=db.func.now())
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now())

    def to_dict(self):
        import json
        policy = None
        if self.password_policy:
            try:
                policy = json.loads(self.password_policy)
            except Exception:
                policy = None

        template_by_type = None
        if self.print_template_by_invoice_type:
            try:
                decoded = json.loads(self.print_template_by_invoice_type)
                if isinstance(decoded, dict):
                    template_by_type = decoded
            except Exception:
                template_by_type = None
        exempt_karats = ['24']
        raw_exempt = getattr(self, 'vat_exempt_karats', None)
        if raw_exempt:
            try:
                decoded = json.loads(raw_exempt) if isinstance(raw_exempt, str) else raw_exempt
                if isinstance(decoded, (list, tuple, set)):
                    normalized = []
                    for v in decoded:
                        try:
                            k = int(str(v).strip())
                        except Exception:
                            continue
                        if k in (18, 21, 22, 24):
                            normalized.append(str(k))
                    exempt_karats = sorted(set(normalized), key=lambda x: int(x)) or ['24']
            except Exception:
                exempt_karats = ['24']

        # Existing to_dict continues below...

        sales_race_settings = {
            'enabled': True,
            'default_period': 'today',
            'points_per_gram': 10.0,
            'allow_fallback_to_latest_period': True,
            'show_invoice_count': True,
            'show_sales_amount_per_employee': True,
            'show_champion': True,
            'show_total_cash_to_all_users': True,
            'show_total_profit_to_all_users': False,
        }
        raw_sales_race = getattr(self, 'sales_race_settings', None)
        if raw_sales_race:
            try:
                decoded_sales_race = json.loads(raw_sales_race) if isinstance(raw_sales_race, str) else raw_sales_race
                if isinstance(decoded_sales_race, dict):
                    sales_race_settings.update(decoded_sales_race)
            except Exception:
                pass

        # Gamification targets
        weekly_target = None
        try:
            weekly_target = float(getattr(self, 'weekly_sales_target_weight', None) or 0.0)
        except Exception:
            weekly_target = 0.0

        monthly_target = None
        try:
            monthly_target = float(getattr(self, 'monthly_sales_target_weight', None) or 0.0)
        except Exception:
            monthly_target = 0.0

        # Decode JSON fields defensively (legacy DBs may contain invalid JSON strings).
        payment_methods = []
        try:
            raw_pm = getattr(self, 'payment_methods', None)
            if raw_pm:
                decoded_pm = json.loads(raw_pm) if isinstance(raw_pm, str) else raw_pm
                if isinstance(decoded_pm, (list, tuple)):
                    payment_methods = list(decoded_pm)
        except Exception:
            payment_methods = []

        weight_closing_settings = None
        try:
            raw_wc = getattr(self, 'weight_closing_settings', None)
            if raw_wc:
                decoded_wc = json.loads(raw_wc) if isinstance(raw_wc, str) else raw_wc
                if isinstance(decoded_wc, dict):
                    weight_closing_settings = decoded_wc
        except Exception:
            weight_closing_settings = None

        return {
            'id': self.id,
            'main_karat': self.main_karat,
            'currency_symbol': self.currency_symbol,
            'weekly_sales_target_weight': weekly_target,
            'monthly_sales_target_weight': monthly_target,
            'sales_race_settings': sales_race_settings,
            'tax_rate': self.tax_rate,
            'tax_enabled': self.tax_enabled,
            'vat_exempt_karats': exempt_karats,
            'payment_methods': payment_methods,
            'invoice_prefix': self.invoice_prefix,
            'show_company_logo': self.show_company_logo,
            'company_name': self.company_name,
            'company_logo_base64': self.company_logo_base64,
            'company_address': self.company_address,
            'company_phone': self.company_phone,
            'company_tax_number': self.company_tax_number,
            'company_cr_number': getattr(self, 'company_cr_number', None),
            'print_template_by_invoice_type': template_by_type,
            'decimal_places': self.decimal_places,
            'date_format': self.date_format,
            'default_discount_rate': self.default_discount_rate,
            'allow_discount': self.allow_discount,
            'allow_manual_invoice_items': self.allow_manual_invoice_items,
            'require_auth_for_invoice_create': bool(self.require_auth_for_invoice_create),
            'idle_timeout_enabled': bool(getattr(self, 'idle_timeout_enabled', True)),
            'idle_timeout_minutes': int(getattr(self, 'idle_timeout_minutes', 30) or 30),
            'allow_partial_invoice_payments': bool(self.allow_partial_invoice_payments),

            # Feature Toggles — أنواع مكافآت (attendance/performance غير مفعّلَين افتراضياً)
            'bonus_attendance_enabled':  bool(getattr(self, 'bonus_attendance_enabled', False)),
            'bonus_performance_enabled': bool(getattr(self, 'bonus_performance_enabled', False)),

            # 🆕 Feature Toggles (مسار خزائن الموظفين)
            'employee_cash_safes_enabled': bool(getattr(self, 'employee_cash_safes_enabled', False)),
            'employee_gold_safes_enabled': bool(getattr(self, 'employee_gold_safes_enabled', False)),

            # 🆕 Default SafeBoxes (IDs)
            'main_cash_safe_box_id': getattr(self, 'main_cash_safe_box_id', None),
            'sale_gold_safe_box_id': getattr(self, 'sale_gold_safe_box_id', None),
            'main_scrap_gold_safe_box_id': getattr(self, 'main_scrap_gold_safe_box_id', None),
            'stones_pending_account_id': getattr(self, 'stones_pending_account_id', None),
            'stones_display_revenue_account_id': getattr(self, 'stones_display_revenue_account_id', None),
            'manufacturing_wage_mode': (self.manufacturing_wage_mode or 'expense'),
            'voucher_auto_post': self.voucher_auto_post,

            # 🆕 Posting Preferences
            'auto_post_invoices': bool(getattr(self, 'auto_post_invoices', True)),
            'auto_post_entries': bool(getattr(self, 'auto_post_entries', True)),
            'require_approval_before_post': bool(getattr(self, 'require_approval_before_post', False)),
            'allow_unposting': bool(getattr(self, 'allow_unposting', False)),

            'weight_closing_settings': weight_closing_settings,
            'gold_price_auto_update_enabled': bool(self.gold_price_auto_update_enabled),
            'gold_price_auto_update_time': self.gold_price_auto_update_time or '09:00',
            'gold_price_auto_update_mode': (self.gold_price_auto_update_mode or 'interval'),
            'gold_price_auto_update_interval_minutes': int(self.gold_price_auto_update_interval_minutes or 60),
            'backup_auto_enabled': bool(getattr(self, 'backup_auto_enabled', False)),
            'backup_auto_mode': (getattr(self, 'backup_auto_mode', None) or 'daily'),
            'backup_auto_time': (getattr(self, 'backup_auto_time', None) or '02:00'),
            'backup_auto_interval_minutes': int(getattr(self, 'backup_auto_interval_minutes', 1440) or 1440),
            'backup_retention_count': int(getattr(self, 'backup_retention_count', 7) or 7),
            'password_policy': policy,
        }


class Voucher(db.Model):
    """
    نموذج السندات - سندات القبض والصرف
    Receipt Vouchers and Payment Vouchers
    """
    __tablename__ = 'voucher'
    
    id = db.Column(db.Integer, primary_key=True)
    
    # رقم السند (تسلسلي حسب النوع والسنة)
    # مثال: RV-2025-00001 (Receipt Voucher)
    #       PV-2025-00001 (Payment Voucher)
    voucher_number = db.Column(db.String(50), unique=True, nullable=False, index=True)
    
    # نوع السند
    # القيم المسموحة: 'receipt' (قبض), 'payment' (صرف), 'adjustment' (تسوية)
    voucher_type = db.Column(db.String(20), nullable=False, index=True)
    
    # التاريخ
    date = db.Column(db.DateTime, nullable=False, default=db.func.now(), index=True)
    
    # الطرف (عميل أو مورد أو آخر)
    # القيم: 'customer', 'supplier', 'other', None
    party_type = db.Column(db.String(20), nullable=True)
    
    # معرف العميل (إذا كان الطرف عميل)
    customer_id = db.Column(db.Integer, db.ForeignKey('customer.id'), nullable=True)
    customer = db.relationship('Customer', backref='vouchers')
    
    # معرف المورد (إذا كان الطرف مورد)
    supplier_id = db.Column(db.Integer, db.ForeignKey('supplier.id'), nullable=True)
    supplier = db.relationship('Supplier', backref='vouchers')
    
    # اسم الطرف (إذا كان غير مسجل في النظام)
    party_name = db.Column(db.String(200), nullable=True)

    # معرف الموظف (إذا كان الطرف موظفاً)
    employee_id = db.Column(db.Integer, db.ForeignKey('employee.id'), nullable=True)
    employee = db.relationship('Employee', backref='vouchers')
    
    # المبلغ النقدي
    amount_cash = db.Column(db.Float, default=0.0, nullable=False)
    
    # المبلغ بالذهب (بالجرام)
    amount_gold = db.Column(db.Float, default=0.0, nullable=False)
    
    # عيار الذهب (إذا كان هناك مبلغ ذهبي)
    gold_karat = db.Column(db.Float, nullable=True)
    
    # البيان / الوصف
    description = db.Column(db.Text, nullable=True)
    
    # نوع المرجع (إن وجد)
    # القيم: 'invoice', 'voucher', 'journal_entry', 'manual', None
    reference_type = db.Column(db.String(20), nullable=True)
    
    # معرف المرجع (رقم الفاتورة أو السند المرتبط)
    reference_id = db.Column(db.Integer, nullable=True)
    
    # رقم المرجع (للعرض) — غير فريد، لا يوجد عليه DB constraint.
    # لـ reference_type='clearing_settlement': يمثّل مجموعة تسوية منطقية
    # (pm_id + يوم/أسبوع الاستحقاق)، لا سنداً واحداً بعينه. أكثر من سند
    # يمكن أن يتشارك نفس reference_number عند "استكمال" تسوية جزئية سابقة
    # (انظر allow_continuation في _create_clearing_settlement_voucher بـ
    # routes.py) — كل سند منها مستقل تماماً (id/journal_entry/اعتماد خاص به)،
    # و reference_number هنا مفتاح تجميع فقط، لا معرّف فريد.
    # reference_number is NOT unique. For clearing_settlement it represents a
    # logical settlement grouping key (pm_id + settle period), not a single
    # voucher — multiple independent vouchers may share it on continuation.
    reference_number = db.Column(db.String(50), nullable=True)
    
    # القيد المحاسبي المرتبط
    journal_entry_id = db.Column(db.Integer, db.ForeignKey('journal_entry.id'), nullable=True)
    journal_entry = db.relationship('JournalEntry', backref='vouchers')
    
    # ملاحظة: الحسابات المدينة والدائنة يتم تخزينها في جدول VoucherAccountLine
    # بدلاً من حقلين منفصلين، لدعم قيود متعددة الأطراف (نقد + عدة عيارات ذهب)
    
    # حالة السند
    # القيم: 'pending', 'approved', 'rejected', 'cancelled'
    status = db.Column(db.String(20), default='pending', nullable=False, index=True)
    
    # سبب الإلغاء (إذا كان ملغى)
    cancellation_reason = db.Column(db.Text, nullable=True)
    
    # تاريخ الإلغاء
    cancelled_at = db.Column(db.DateTime, nullable=True)
    
    # المرفقات (JSON array of file paths)
    attachments = db.Column(db.Text, nullable=True)
    
    # ملاحظات إضافية
    notes = db.Column(db.Text, nullable=True)

    # اسم المستلم المطبوع على السند
    receiver_name = db.Column(db.String(200), nullable=True)

    # عمولة / رسوم فرق العيار — per-line aggregation
    karat_diff_earn_total = db.Column(db.Float, default=0.0)  # عمولة تكسبها الشركة
    karat_diff_pay_total = db.Column(db.Float, default=0.0)   # رسوم تدفعها الشركة

    # معلومات المستخدم الذي أنشأ السند
    created_by = db.Column(db.String(100), nullable=True)
    
    # تاريخ الإنشاء
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    
    # تاريخ آخر تعديل
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now())

    # حقول الموافقة
    approved_by = db.Column(db.String(100), nullable=True)
    approved_at = db.Column(db.DateTime, nullable=True)
    rejected_by = db.Column(db.String(100), nullable=True)
    rejected_at = db.Column(db.DateTime, nullable=True)
    rejection_reason = db.Column(db.Text, nullable=True)

    def _gold_display_summary(self):
        main_karat = _configured_main_karat_f()
        debit_by_karat = {}
        credit_by_karat = {}

        for line in self.account_lines.all():
            if line.amount_type != 'gold':
                continue

            amount = float(line.amount or 0.0)
            if amount <= 0:
                continue

            karat = float(line.karat or main_karat or 21.0)
            bucket = debit_by_karat if line.line_type == 'debit' else credit_by_karat
            bucket[karat] = bucket.get(karat, 0.0) + amount

        display_breakdown = debit_by_karat or credit_by_karat
        breakdown_items = []
        equivalent_total = 0.0
        for karat in sorted(display_breakdown.keys()):
            weight = float(display_breakdown[karat] or 0.0)
            weight_main = (weight * karat) / main_karat if main_karat > 0 else weight
            equivalent_total += weight_main
            breakdown_items.append({
                'karat': round(float(karat), 3),
                'weight': round(weight, 6),
                'weight_main_karat': round(weight_main, 6),
            })

        display_karat = None
        if len(breakdown_items) == 1:
            display_karat = breakdown_items[0]['karat']
        elif len(breakdown_items) > 1:
            display_karat = 'متعدد'

        total_gold_display = round(
            sum(float(item['weight']) for item in breakdown_items),
            6,
        ) if breakdown_items else round(float(self.amount_gold or 0.0), 6)

        return {
            'main_karat': round(float(main_karat), 3),
            'display_karat': display_karat,
            'amount_gold_display': total_gold_display,
            'amount_gold_main_karat': round(float(equivalent_total), 6),
            'gold_breakdown': breakdown_items,
        }

    def to_dict(self):
        """تحويل السند إلى dictionary"""
        gold_summary = self._gold_display_summary()
        
        result = {
            'id': self.id,
            'voucher_number': self.voucher_number,
            'voucher_type': self.voucher_type,
            'date': self.date.isoformat() if self.date else None,
            'party_type': self.party_type,
            'customer_id': self.customer_id,
            'supplier_id': self.supplier_id,
            'employee_id': self.employee_id,
            'party_name': self.party_name,
            'amount_cash': self.amount_cash,
            'amount_gold': gold_summary['amount_gold_display'],
            'amount_gold_main_karat': gold_summary['amount_gold_main_karat'],
            'main_karat': gold_summary['main_karat'],
            'gold_karat': gold_summary['display_karat'],
            'gold_breakdown': gold_summary['gold_breakdown'],
            'gross_weight': round(sum(float(line.gross_weight or 0.0) for line in self.account_lines.all() if line.amount_type == 'gold'), 6),
            'net_weight': round(sum(float(line.net_weight or line.amount or 0.0) for line in self.account_lines.all() if line.amount_type == 'gold'), 6),
            'stones_weight': round(sum(float(line.stones_weight or 0.0) for line in self.account_lines.all() if line.amount_type == 'gold'), 6),
            'description': self.description,
            'reference_type': self.reference_type,
            'reference_id': self.reference_id,
            'reference_number': self.reference_number,
            'journal_entry_id': self.journal_entry_id,
            'status': self.status,
            'cancellation_reason': self.cancellation_reason,
            'cancelled_at': self.cancelled_at.isoformat() if self.cancelled_at else None,
            'attachments': self.attachments,
            'notes': self.notes,
            'receiver_name': self.receiver_name,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
            'approved_by': self.approved_by,
            'approved_at': self.approved_at.isoformat() if self.approved_at else None,
            'rejected_by': self.rejected_by,
            'rejected_at': self.rejected_at.isoformat() if self.rejected_at else None,
            'rejection_reason': self.rejection_reason,
        }
        
        # إضافة معلومات الطرف
        if self.customer:
            result['customer'] = {
                'id': self.customer.id,
                'name': self.customer.name,
                'customer_code': self.customer.customer_code
            }
        
        if self.supplier:
            result['supplier'] = {
                'id': self.supplier.id,
                'name': self.supplier.name,
                'supplier_code': self.supplier.supplier_code
            }

        if self.employee:
            result['employee'] = {
                'id': self.employee.id,
                'name': self.employee.name,
            }
        
        # إضافة سطور الحسابات
        result['account_lines'] = [line.to_dict() for line in self.account_lines.all()]
        
        # إضافة رقم القيد المحاسبي
        if self.journal_entry:
            result['journal_entry'] = {
                'id': self.journal_entry.id,
                'entry_number': self.journal_entry.entry_number,
                'date': self.journal_entry.date.isoformat() if self.journal_entry.date else None
            }
        
        return result

    def __repr__(self):
        return f'<Voucher {self.voucher_number} - {self.voucher_type}>'


class VoucherAccountLine(db.Model):
    """
    سطور الحسابات في السند
    يحتوي على الحسابات المدينة والدائنة لكل سطر في السند
    مثال: في سند قبض قد يحتوي على:
    - حساب الصندوق (مدين) - نقد
    - حساب ذهب عيار 24 (مدين) - ذهب
    - حساب العميل (دائن)
    """
    __tablename__ = 'voucher_account_line'
    
    id = db.Column(db.Integer, primary_key=True)
    
    # معرف السند
    voucher_id = db.Column(db.Integer, db.ForeignKey('voucher.id', ondelete='CASCADE'), nullable=False, index=True)
    voucher = db.relationship('Voucher', backref=db.backref('account_lines', cascade='all, delete-orphan', lazy='dynamic'))
    
    # معرف الحساب
    account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=False)
    account = db.relationship('Account', backref='voucher_lines')
    
    # نوع السطر: 'debit' (مدين) أو 'credit' (دائن)
    line_type = db.Column(db.String(10), nullable=False)  # 'debit' or 'credit'
    
    # نوع المبلغ: 'cash' (نقد) أو 'gold' (ذهب)
    amount_type = db.Column(db.String(10), nullable=False)  # 'cash' or 'gold'
    
    # المبلغ
    amount = db.Column(db.Float, nullable=False, default=0.0)
    
    # العيار (في حالة الذهب فقط)
    karat = db.Column(db.Float, nullable=True)

    # الوزن القائم/الإجمالي قبل خصم الأحجار أو الشوائب
    gross_weight = db.Column(db.Float, nullable=True)

    # الوزن الصافي القابل للترحيل محاسبياً
    net_weight = db.Column(db.Float, nullable=True)

    # وزن الأحجار أو الإضافات غير الذهبية
    stones_weight = db.Column(db.Float, nullable=True)
    
    # البيان
    description = db.Column(db.Text, nullable=True)
    
    # تاريخ الإنشاء
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)

    def to_dict(self):
        """تحويل السطر إلى dictionary"""
        result = {
            'id': self.id,
            'voucher_id': self.voucher_id,
            'account_id': self.account_id,
            'line_type': self.line_type,
            'amount_type': self.amount_type,
            'amount': self.amount,
            'karat': self.karat,
            'gross_weight': self.gross_weight,
            'net_weight': self.net_weight,
            'stones_weight': self.stones_weight,
            'description': self.description,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }
        
        # إضافة معلومات الحساب
        if self.account:
            result['account'] = {
                'id': self.account.id,
                'name': self.account.name,
                'account_number': self.account.account_number,
                'type': self.account.type
            }
        
        return result

    def __repr__(self):
        return f'<VoucherAccountLine {self.line_type} - {self.account.name if self.account else "N/A"}>'


class InvoicePayment(db.Model):
    """
    سجل دفعات الفاتورة - دعم وسائل دفع متعددة في الفاتورة الواحدة
    """
    __tablename__ = 'invoice_payment'
    
    id = db.Column(db.Integer, primary_key=True)
    
    # ربط بالفاتورة
    invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id', ondelete='CASCADE'), nullable=False)
    
    # ربط بوسيلة الدفع — حقل هجين بمرحلتين، لا "immutable audit field" ولا
    # "mutable business truth" بشكل كامل:
    #   - قبل وجود أي SettlementLine لهذه الدفعة: قابل للتصحيح (انظر
    #     POST /invoices/<id>/payments/<id>/correct-method) — "أفضل فهم
    #     حالي"، derived/correctable.
    #   - بعد وجود SettlementLine واحدة على الأقل: القيمة تتجمَّد (الـ
    #     endpoint أعلاه يرفض أي تعديل) — لكن التجمُّد لا يعني أن هذا الحقل
    #     يصبح "الحقيقة التاريخية". هو فقط يتوقّف عن كونه قابلاً للتغيير؛
    #     الحقيقة التاريخية الفعلية (أي حساب استقبل المال، بأي عمولة) تبقى
    #     دائماً في JournalEntryLine/VoucherAccountLine وقت تلك التسوية، لا
    #     في إعادة استدلال عبر هذا الحقل + إعدادات PaymentMethod *الحالية*.
    #     مثال ملموس: لو تغيّر PaymentMethod.default_safe_box_id لاحقاً، فإن
    #     "payment_method_id → default_safe_box_id الحالي" سيُعطي حساباً
    #     مختلفاً عن الحساب الحقيقي الذي استُخدم وقت التسوية الفعلية.
    # القاعدة العملية: أي إعادة بناء لحقيقة تاريخية (حالية أو سابقة على
    # تصحيح) تُبنى من سجل الأحداث (event log) — JournalEntryLine +
    # SettlementLine + AuditLog(action='correct_payment_method') — لا من
    # قراءة هذا الحقل وإعادة تفسيره عبر أي إعداد حالي.
    payment_method_id = db.Column(db.Integer, db.ForeignKey('payment_method.id'), nullable=False)
    payment_method = db.relationship('PaymentMethod', backref='invoice_payments')

    # المبلغ المدفوع بهذه الوسيلة
    amount = db.Column(db.Float, nullable=False)

    # العمولة المحسوبة بناءً على وسيلة الدفع الحالية للدفعة — derived data لا
    # historical snapshot: تُعاد حسابها بالكامل (rate/amount/vat/net) عند أي
    # تصحيح لـ payment_method_id قبل التسوية (نفس قاعدة الحقل أعلاه)، فتعكس
    # دائماً وسيلة الدفع الحالية المسجَّلة، لا بالضرورة ما حُسب وقت الدفع
    # الأصلي إن جرى تصحيح لاحق.
    commission_rate = db.Column(db.Float, default=0.0)

    # العمولة المحسوبة (بدون ضريبة)
    commission_amount = db.Column(db.Float, default=0.0)

    # ضريبة القيمة المضافة على العمولة (15%)
    commission_vat = db.Column(db.Float, default=0.0)

    # المبلغ الصافي بعد العمولة وضريبتها
    net_amount = db.Column(db.Float, nullable=False)
    
    # ملاحظات خاصة بهذه الدفعة
    notes = db.Column(db.Text)
    
    # تاريخ الإنشاء
    created_at = db.Column(db.DateTime, default=db.func.now())
    
    def to_dict(self):
        """تحويل إلى قاموس JSON"""
        result = {
            'id': self.id,
            'invoice_id': self.invoice_id,
            'payment_method_id': self.payment_method_id,
            'amount': self.amount,
            'commission_rate': self.commission_rate,
            'commission_amount': self.commission_amount,
            'commission_vat': self.commission_vat,
            'net_amount': self.net_amount,
            'notes': self.notes,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }
        
        # إضافة معلومات وسيلة الدفع
        if self.payment_method:
            result['payment_method_name'] = self.payment_method.name
            result['payment_method_details'] = self.payment_method.to_dict()
        
        return result
    
    def __repr__(self):
        return f'<InvoicePayment Invoice#{self.invoice_id} - {self.amount} via {self.payment_method_id}>'


class SettlementLine(db.Model):
    """Per-transaction clearing settlement link.

    Each row ties one InvoicePayment to the Voucher that settled it,
    recording the exact amount settled and the commission deducted.
    Partial settlements are supported (amount_settled < IP.amount).
    """
    __tablename__ = 'settlement_line'

    id = db.Column(db.Integer, primary_key=True)
    voucher_id = db.Column(db.Integer, db.ForeignKey('voucher.id', ondelete='CASCADE'), nullable=False, index=True)
    invoice_payment_id = db.Column(db.Integer, db.ForeignKey('invoice_payment.id', ondelete='CASCADE'), nullable=False, index=True)
    amount_settled = db.Column(db.Float, nullable=False)
    commission = db.Column(db.Float, default=0.0)
    commission_vat = db.Column(db.Float, default=0.0)
    created_at = db.Column(db.DateTime, default=db.func.now())

    voucher = db.relationship('Voucher', backref=db.backref('settlement_lines', lazy='dynamic'))
    invoice_payment = db.relationship('InvoicePayment', backref=db.backref('settlement_lines', lazy='dynamic'))

    def to_dict(self):
        return {
            'id': self.id,
            'voucher_id': self.voucher_id,
            'invoice_payment_id': self.invoice_payment_id,
            'amount_settled': self.amount_settled,
            'commission': self.commission,
            'commission_vat': self.commission_vat,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }

    def __repr__(self):
        return f'<SettlementLine V#{self.voucher_id} IP#{self.invoice_payment_id} {self.amount_settled}>'


class SafeBoxTransaction(db.Model):
    """Ledger movements for SafeBox (رقابة الخزينة).

    This is the audit-friendly source of truth for safe balances.
    We do not mutate balances directly; instead, we append transactions.
    """

    __tablename__ = 'safe_box_transaction'

    id = db.Column(db.Integer, primary_key=True)

    safe_box_id = db.Column(
        db.Integer,
        db.ForeignKey('safe_box.id', ondelete='RESTRICT'),
        nullable=False,
        index=True,
    )

    # Reference (optional but strongly recommended)
    ref_type = db.Column(db.String(40), nullable=True, index=True)  # invoice_payment, invoice, voucher...
    ref_id = db.Column(db.Integer, nullable=True, index=True)

    invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id', ondelete='SET NULL'), nullable=True, index=True)
    invoice_payment_id = db.Column(
        db.Integer,
        db.ForeignKey('invoice_payment.id', ondelete='SET NULL'),
        nullable=True,
        index=True,
    )
    payment_method_id = db.Column(db.Integer, db.ForeignKey('payment_method.id', ondelete='SET NULL'), nullable=True)

    # Direction: in/out
    direction = db.Column(db.String(10), nullable=False, default='in')

    # Cash amount (SAR)
    amount_cash = db.Column(db.Float, nullable=False, default=0.0)

    # Optional weight tracking by karat (grams) — الوزن القائم الكلي (يشمل الفصوص)
    weight_18k = db.Column(db.Float, nullable=False, default=0.0)
    weight_21k = db.Column(db.Float, nullable=False, default=0.0)
    weight_22k = db.Column(db.Float, nullable=False, default=0.0)
    weight_24k = db.Column(db.Float, nullable=False, default=0.0)

    # وزن الفصوص المُضمَّنة في القطعة — مستقل عن العيار
    # يُملأ عند الشراء والتجديد لمعرفة الفصوص في أي خزينة
    stones_weight = db.Column(db.Float, nullable=False, default=0.0)
    stones_18k    = db.Column(db.Float, nullable=False, default=0.0)
    stones_21k    = db.Column(db.Float, nullable=False, default=0.0)
    stones_22k    = db.Column(db.Float, nullable=False, default=0.0)
    stones_24k    = db.Column(db.Float, nullable=False, default=0.0)

    notes = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False, index=True)
    created_by = db.Column(db.String(100), nullable=True)

    safe_box = db.relationship('SafeBox', backref=db.backref('transactions', lazy=True, cascade='all, delete-orphan'))
    invoice = db.relationship('Invoice', foreign_keys=[invoice_id])
    invoice_payment = db.relationship('InvoicePayment', foreign_keys=[invoice_payment_id])
    payment_method = db.relationship('PaymentMethod', foreign_keys=[payment_method_id])

    def signed_cash(self) -> float:
        amt = float(self.amount_cash or 0.0)
        return amt if (self.direction or 'in') == 'in' else -amt

    def to_dict(self):
        return {
            'id': self.id,
            'safe_box_id': self.safe_box_id,
            'ref_type': self.ref_type,
            'ref_id': self.ref_id,
            'invoice_id': self.invoice_id,
            'invoice_payment_id': self.invoice_payment_id,
            'payment_method_id': self.payment_method_id,
            'direction': self.direction,
            'amount_cash': float(self.amount_cash or 0.0),
            'weight_18k': float(self.weight_18k or 0.0),
            'weight_21k': float(self.weight_21k or 0.0),
            'weight_22k': float(self.weight_22k or 0.0),
            'weight_24k': float(self.weight_24k or 0.0),
            'stones_weight': float(self.stones_weight or 0.0),
            'notes': self.notes,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'created_by': self.created_by,
        }


def _validate_safe_box_transaction_or_raise(tx: 'SafeBoxTransaction') -> None:
    ref_type = (getattr(tx, 'ref_type', None) or '').strip()
    if ref_type == 'settlement':
        raise ValueError(
            "Invalid SafeBoxTransaction(ref_type='settlement'): manual settlements must be posted via JournalEntry/Voucher flows; "
            "use shift_closing_settlement for shift drawer clearing or create a posted JournalEntry." 
        )
    if ref_type != 'invoice_payment':
        return

    invoice_payment_id = getattr(tx, 'invoice_payment_id', None)
    ref_id = getattr(tx, 'ref_id', None)

    if invoice_payment_id in (None, 0, '', False) or ref_id in (None, 0, '', False):
        raise ValueError(
            "Invalid SafeBoxTransaction(invoice_payment): missing invoice_payment_id/ref_id; "
            "this would desync safe ledger and posted journals."
        )

    # NOTE: ref_id may be either invoice_payment_id OR an originating voucher.id.
    # We only require that both references exist.

    # Stronger guard: if ref_id is not the invoice_payment_id, it must point to a Voucher
    # whose notes declare the same invoice_payment_id. This prevents mis-keyed rows
    # (e.g. invoice_payment_id points to a different payment than the referenced voucher).
    try:
        ip_id = int(invoice_payment_id)
    except Exception:
        ip_id = None
    try:
        rid_int = int(ref_id)
    except Exception:
        rid_int = None

    if ip_id and rid_int and rid_int != ip_id:
        try:
            voucher = Voucher.query.get(rid_int)
        except Exception:
            voucher = None
        if voucher is None:
            raise ValueError(
                "Invalid SafeBoxTransaction(invoice_payment): ref_id does not equal invoice_payment_id and does not reference an existing Voucher."
            )

        try:
            raw_notes = getattr(voucher, 'notes', None)
            parsed = json.loads(raw_notes) if raw_notes else None
        except Exception:
            parsed = None

        v_ip = None
        try:
            if isinstance(parsed, dict) and parsed.get('invoice_payment_id') not in (None, '', False, 0, '0'):
                v_ip = int(parsed.get('invoice_payment_id'))
        except Exception:
            v_ip = None

        if v_ip != ip_id:
            raise ValueError(
                "Invalid SafeBoxTransaction(invoice_payment): voucher.notes invoice_payment_id does not match invoice_payment_id."
            )


@event.listens_for(SafeBoxTransaction, 'before_insert')
def _guard_safe_box_tx_before_insert(mapper, connection, target):
    _validate_safe_box_transaction_or_raise(target)


@event.listens_for(SafeBoxTransaction, 'before_update')
def _guard_safe_box_tx_before_update(mapper, connection, target):
    _validate_safe_box_transaction_or_raise(target)




class Employee(db.Model):
    """نموذج الموظفين"""
    __tablename__ = 'employee'

    id = db.Column(db.Integer, primary_key=True)
    employee_code = db.Column(db.String(50), unique=True, nullable=False, index=True)
    name = db.Column(db.String(150), nullable=False)
    job_title = db.Column(db.String(100), nullable=True)
    department = db.Column(db.String(100), nullable=True)
    phone = db.Column(db.String(30), nullable=True)
    email = db.Column(db.String(150), nullable=True)
    national_id = db.Column(db.String(50), nullable=True, index=True)
    salary = db.Column(db.Float, default=0.0, nullable=False)
    hire_date = db.Column(db.Date, nullable=True)
    termination_date = db.Column(db.Date, nullable=True)
    account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=True)
    # خزنة الذهب الخاصة بالموظف (اختياري). إذا كانت NULL فهذا يعني استخدام الخزنة الذهبية الرئيسية.
    gold_safe_box_id = db.Column(
        db.Integer,
        db.ForeignKey('safe_box.id', ondelete='RESTRICT'),
        nullable=True,
    )
    # خزنة النقد الخاصة بالموظف (اختياري). إذا كانت NULL فهذا يعني استخدام الخزنة النقدية الرئيسية.
    cash_safe_box_id = db.Column(
        db.Integer,
        db.ForeignKey('safe_box.id', ondelete='RESTRICT'),
        nullable=True,
    )
    is_active = db.Column(db.Boolean, default=True, index=True, nullable=False)
    notes = db.Column(db.Text, nullable=True)

    # 🎯 أهداف الأداء الشخصية (مستقلة عن أهداف الفريق في الإعدادات)
    goal_metric          = db.Column(db.String(20),  nullable=True)   # 'weight'|'points'|'invoices'
    goal_name            = db.Column(db.String(200), nullable=True)   # عنوان يظهر في الاحتفالية
    goal_weight_monthly  = db.Column(db.Float,   nullable=True)
    goal_weight_weekly   = db.Column(db.Float,   nullable=True)
    goal_points_monthly  = db.Column(db.Float,   nullable=True)
    goal_points_weekly   = db.Column(db.Float,   nullable=True)
    goal_invoices_monthly = db.Column(db.Integer, nullable=True)
    goal_invoices_weekly  = db.Column(db.Integer, nullable=True)
    goal_bonus_monthly    = db.Column(db.Float,   nullable=True)
    goal_bonus_weekly     = db.Column(db.Float,   nullable=True)
    goal_monthly_enabled  = db.Column(db.Boolean, default=True,  nullable=True)
    goal_weekly_enabled   = db.Column(db.Boolean, default=True,  nullable=True)
    goal_daily_enabled    = db.Column(db.Boolean, default=False, nullable=True)
    goal_weight_daily     = db.Column(db.Float,   nullable=True)
    goal_points_daily     = db.Column(db.Float,   nullable=True)
    goal_invoices_daily   = db.Column(db.Integer, nullable=True)
    goal_bonus_daily      = db.Column(db.Float,   nullable=True)
    goal_reward_type_daily   = db.Column(db.String(20), default='fixed', nullable=True)
    goal_reward_type_weekly  = db.Column(db.String(20), default='fixed', nullable=True)
    goal_reward_type_monthly = db.Column(db.String(20), default='fixed', nullable=True)
    goal_bonus_rule_id_daily   = db.Column(db.Integer, db.ForeignKey('bonus_rule.id'), nullable=True)
    goal_bonus_rule_id_weekly  = db.Column(db.Integer, db.ForeignKey('bonus_rule.id'), nullable=True)
    goal_bonus_rule_id_monthly = db.Column(db.Integer, db.ForeignKey('bonus_rule.id'), nullable=True)

    created_by = db.Column(db.String(100), nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now(), nullable=False)

    # صورة الموظف — مخزنة كـ data URI (base64). nullable لأنها اختيارية.
    photo = db.Column(db.Text, nullable=True)

    account = db.relationship('Account', backref=db.backref('employees', lazy='dynamic'))
    gold_safe_box = db.relationship('SafeBox', foreign_keys=[gold_safe_box_id])
    cash_safe_box = db.relationship('SafeBox', foreign_keys=[cash_safe_box_id])

    def to_dict(self, include_details: bool = False, include_bonuses: bool = False):
        data = {
            'id': self.id,
            'employee_code': self.employee_code,
            'name': self.name,
            'job_title': self.job_title,
            'department': self.department,
            'phone': self.phone,
            'email': self.email,
            'national_id': self.national_id,
            'salary': self.salary,
            'hire_date': self.hire_date.isoformat() if self.hire_date else None,
            'termination_date': self.termination_date.isoformat() if self.termination_date else None,
            'account_id': self.account_id,
            'gold_safe_box_id': self.gold_safe_box_id,
            'cash_safe_box_id': self.cash_safe_box_id,
            'is_active': self.is_active,
            'notes': self.notes,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
            'photo': self.photo,
            # 🎯 أهداف الأداء الشخصية
            'goal_metric':           self.goal_metric,
            'goal_name':             self.goal_name,
            'goal_weight_monthly':   self.goal_weight_monthly,
            'goal_weight_weekly':    self.goal_weight_weekly,
            'goal_points_monthly':   self.goal_points_monthly,
            'goal_points_weekly':    self.goal_points_weekly,
            'goal_invoices_monthly': self.goal_invoices_monthly,
            'goal_invoices_weekly':  self.goal_invoices_weekly,
            'goal_bonus_monthly':    self.goal_bonus_monthly,
            'goal_bonus_weekly':     self.goal_bonus_weekly,
            'goal_monthly_enabled':  self.goal_monthly_enabled,
            'goal_weekly_enabled':   self.goal_weekly_enabled,
            'goal_daily_enabled':    self.goal_daily_enabled,
            'goal_weight_daily':     self.goal_weight_daily,
            'goal_points_daily':     self.goal_points_daily,
            'goal_invoices_daily':   self.goal_invoices_daily,
            'goal_bonus_daily':      self.goal_bonus_daily,
            'goal_reward_type_daily':    self.goal_reward_type_daily,
            'goal_reward_type_weekly':   self.goal_reward_type_weekly,
            'goal_reward_type_monthly':  self.goal_reward_type_monthly,
            'goal_bonus_rule_id_daily':   self.goal_bonus_rule_id_daily,
            'goal_bonus_rule_id_weekly':  self.goal_bonus_rule_id_weekly,
            'goal_bonus_rule_id_monthly': self.goal_bonus_rule_id_monthly,
        }

        # `include_bonuses` kept for backward compatibility; not used currently
        if include_details:
            if self.account:
                data['account'] = {
                    'id': self.account.id,
                    'account_number': self.account.account_number,
                    'name': self.account.name,
                }
            data['payroll_count'] = self.payroll_entries.count() if hasattr(self, 'payroll_entries') else 0
            data['attendance_count'] = self.attendance_records.count() if hasattr(self, 'attendance_records') else 0

        return data

    def __repr__(self):
        return f'<Employee {self.employee_code} - {self.name}>'


class AppUser(db.Model):
    """حسابات المستخدمين الخاصة بالنظام"""
    __tablename__ = 'app_user'

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False, index=True)
    full_name = db.Column(db.String(200), nullable=True)
    email = db.Column(db.String(150), nullable=True)
    phone = db.Column(db.String(30), nullable=True)
    password_hash = db.Column(db.String(255), nullable=False)
    must_change_password = db.Column(db.Boolean, default=False, nullable=False)
    password_changed_at = db.Column(db.DateTime, nullable=True)
    employee_id = db.Column(db.Integer, db.ForeignKey('employee.id'), nullable=True)
    # الأدوار: system_admin, manager, accountant, employee
    role = db.Column(db.String(50), nullable=False, default='employee')
    permissions = db.Column(db.JSON, nullable=True)  # صلاحيات مخصصة تتجاوز الافتراضية
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    last_login_at = db.Column(db.DateTime, nullable=True)

    # 🆕 Two-Factor Authentication (TOTP)
    totp_secret = db.Column(db.Text, nullable=True)
    two_factor_enabled = db.Column(db.Boolean, default=False, nullable=False)
    two_factor_verified_at = db.Column(db.DateTime, nullable=True)

    # صورة الملف الشخصي — base64 data URI (مستقلة عن صورة الموظف)
    photo = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now(), nullable=False)

    employee = db.relationship('Employee', backref=db.backref('user_account', uselist=False))

    @property
    def is_admin(self) -> bool:
        """مسؤول النظام فقط"""
        return (self.role or '').lower() == 'system_admin'
    
    @property
    def is_manager(self) -> bool:
        """مدير أو أعلى"""
        role = (self.role or '').lower()
        return role in ['system_admin', 'manager']
    
    @property
    def is_accountant(self) -> bool:
        """محاسب أو أعلى"""
        role = (self.role or '').lower()
        return role in ['system_admin', 'manager', 'accountant']

    def has_permission(self, permission_code: str) -> bool:
        """
        تحقق من وجود صلاحية معينة
        يستخدم نظام الصلاحيات من permissions.py
        """
        from permissions import has_permission as check_permission
        return check_permission(self.role, self.permissions, permission_code)

    def set_password(self, password: str):
        # استخدام خوارزمية مدعومة عبر OpenSSL لضمان التوافق عبر البيئات
        self.password_hash = generate_password_hash(password, method='pbkdf2:sha256')
        try:
            self.password_changed_at = datetime.now()
        except Exception:
            pass

    def check_password(self, password: str) -> bool:
        if not self.password_hash:
            return False
        return check_password_hash(self.password_hash, password)

    def to_dict(self, include_employee: bool = False):
        data = {
            'id': self.id,
            'username': self.username,
            'full_name': self.full_name,
            'email': self.email,
            'phone': self.phone,
            'employee_id': self.employee_id,
            'role': self.role,
            'permissions': self.permissions,
            'is_active': self.is_active,
            'is_admin': self.is_admin,
            'last_login_at': self.last_login_at.isoformat() if self.last_login_at else None,
            'two_factor_enabled': bool(self.two_factor_enabled),
            'must_change_password': bool(self.must_change_password),
            'password_changed_at': self.password_changed_at.isoformat() if self.password_changed_at else None,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
            'photo': self.photo,
        }

        if include_employee and self.employee:
            data['employee'] = self.employee.to_dict()

        return data

    def __repr__(self):
        return f'<AppUser {self.username}>'


# ==========================================
# 🔐 Auth Security Models
# ==========================================


class TokenBlacklist(db.Model):
    """سجل توكنات JWT المحظورة (logout / security events)."""

    __tablename__ = 'token_blacklist'

    id = db.Column(db.Integer, primary_key=True)
    jti = db.Column(db.String(36), unique=True, nullable=False, index=True)
    token_type = db.Column(db.String(10), nullable=True)  # access | refresh
    expires_at = db.Column(db.DateTime, nullable=False, index=True)
    blacklisted_at = db.Column(db.DateTime, default=datetime.now, nullable=False)
    reason = db.Column(db.String(100), nullable=True)


class RefreshToken(db.Model):
    """Refresh token sessions stored server-side (revocable)."""

    __tablename__ = 'refresh_tokens'

    id = db.Column(db.Integer, primary_key=True)
    token_hash = db.Column(db.String(64), unique=True, nullable=False, index=True)

    user_id = db.Column(db.Integer, nullable=False, index=True)
    user_type = db.Column(db.String(20), nullable=False, index=True)  # user | app_user

    expires_at = db.Column(db.DateTime, nullable=False, index=True)
    is_revoked = db.Column(db.Boolean, default=False, nullable=False, index=True)
    revoked_at = db.Column(db.DateTime, nullable=True)
    revoked_reason = db.Column(db.String(100), nullable=True)

    ip_address = db.Column(db.String(45), nullable=True)
    user_agent = db.Column(db.String(255), nullable=True)
    device_fingerprint = db.Column(db.String(255), nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False)
    last_used_at = db.Column(db.DateTime, nullable=True)


class SessionActivity(db.Model):
    """Per-user last activity tracking for idle session expiry."""

    __tablename__ = 'session_activity'

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, nullable=False, index=True)
    user_type = db.Column(db.String(20), nullable=False, index=True)  # user | app_user

    last_activity_at = db.Column(db.DateTime, nullable=False, index=True, default=datetime.now)
    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.now, nullable=False)

    __table_args__ = (
        db.UniqueConstraint('user_id', 'user_type', name='uq_session_activity_user'),
    )


class LoginAttempt(db.Model):
    """محاولات تسجيل الدخول (لـ rate limit + security reporting)."""

    __tablename__ = 'login_attempts'

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), nullable=True, index=True)
    ip_address = db.Column(db.String(45), nullable=True, index=True)
    user_agent = db.Column(db.String(255), nullable=True)
    success = db.Column(db.Boolean, default=False, nullable=False, index=True)
    failure_reason = db.Column(db.String(200), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False, index=True)


class AuthActionAttempt(db.Model):
    """محاولات إجراءات حساسة (OTP/username recovery) لمنع التخمين/الإساءة.

    - نخزن identifier_hash فقط (بدون حفظ البريد/الهاتف صراحةً) لتقليل PII.
    - يُستخدم للـ rate limiting على مستوى IP + identifier_hash.
    """

    __tablename__ = 'auth_action_attempts'

    id = db.Column(db.Integer, primary_key=True)
    action = db.Column(db.String(50), nullable=False, index=True)
    identifier_hash = db.Column(db.String(64), nullable=True, index=True)
    ip_address = db.Column(db.String(45), nullable=True, index=True)
    user_agent = db.Column(db.String(255), nullable=True)
    success = db.Column(db.Boolean, default=True, nullable=False, index=True)
    blocked_reason = db.Column(db.String(50), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False, index=True)


class PasswordResetToken(db.Model):
    """توكن إعادة تعيين كلمة المرور (مخصص للعمليات الإدارية/المساعدة)."""

    __tablename__ = 'password_reset_tokens'

    id = db.Column(db.Integer, primary_key=True)
    token_hash = db.Column(db.String(64), unique=True, nullable=False, index=True)
    user_id = db.Column(db.Integer, nullable=False, index=True)
    user_type = db.Column(db.String(20), nullable=False, index=True)  # user | app_user
    expires_at = db.Column(db.DateTime, nullable=False, index=True)
    is_used = db.Column(db.Boolean, default=False, nullable=False, index=True)
    used_at = db.Column(db.DateTime, nullable=True)
    used_ip = db.Column(db.String(45), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False)



class Payroll(db.Model):
    """سجلات الرواتب الشهرية"""
    __tablename__ = 'payroll'

    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.Integer, db.ForeignKey('employee.id'), nullable=False, index=True)
    month = db.Column(db.Integer, nullable=False)
    year = db.Column(db.Integer, nullable=False)
    basic_salary = db.Column(db.Float, nullable=False, default=0.0)
    allowances = db.Column(db.Float, nullable=False, default=0.0)
    deductions = db.Column(db.Float, nullable=False, default=0.0)
    net_salary = db.Column(db.Float, nullable=False, default=0.0)
    voucher_id = db.Column(db.Integer, db.ForeignKey('voucher.id'), nullable=True)
    paid_date = db.Column(db.Date, nullable=True)
    status = db.Column(db.String(30), nullable=False, default='pending')  # pending, approved, paid, cancelled
    notes = db.Column(db.Text, nullable=True)
    created_by = db.Column(db.String(100), nullable=True)

    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now(), nullable=False)

    employee = db.relationship('Employee', backref=db.backref('payroll_entries', lazy='dynamic'))
    voucher = db.relationship('Voucher', backref=db.backref('payroll_entries', lazy='dynamic'))

    __table_args__ = (
        db.UniqueConstraint('employee_id', 'month', 'year', name='_employee_month_year_uc'),
    )

    def to_dict(self, include_employee: bool = False, include_voucher: bool = False):
        data = {
            'id': self.id,
            'employee_id': self.employee_id,
            'month': self.month,
            'year': self.year,
            'basic_salary': self.basic_salary,
            'allowances': self.allowances,
            'deductions': self.deductions,
            'net_salary': self.net_salary,
            'voucher_id': self.voucher_id,
            'paid_date': self.paid_date.isoformat() if self.paid_date else None,
            'status': self.status,
            'notes': self.notes,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }

        if include_employee and self.employee:
            data['employee'] = self.employee.to_dict()
        if include_voucher and self.voucher:
            data['voucher'] = {
                'id': self.voucher.id,
                'voucher_number': self.voucher.voucher_number,
                'status': self.voucher.status,
                'date': self.voucher.date.isoformat() if self.voucher.date else None,
            }

        return data

    def __repr__(self):
        return f'<Payroll {self.employee_id} {self.month}/{self.year}>'


class Attendance(db.Model):
    """سجلات الحضور والانصراف"""
    __tablename__ = 'attendance'

    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.Integer, db.ForeignKey('employee.id'), nullable=False, index=True)
    attendance_date = db.Column(db.Date, nullable=False, index=True)
    check_in_time = db.Column(db.Time, nullable=True)
    check_out_time = db.Column(db.Time, nullable=True)
    status = db.Column(db.String(30), nullable=False, default='present')  # present, absent, late, on_leave
    notes = db.Column(db.Text, nullable=True)
    created_by = db.Column(db.String(100), nullable=True)

    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now(), nullable=False)

    employee = db.relationship('Employee', backref=db.backref('attendance_records', lazy='dynamic'))

    __table_args__ = (
        db.UniqueConstraint('employee_id', 'attendance_date', name='_employee_attendance_date_uc'),
    )

    def to_dict(self, include_employee: bool = False):
        data = {
            'id': self.id,
            'employee_id': self.employee_id,
            'attendance_date': self.attendance_date.isoformat() if self.attendance_date else None,
            'check_in_time': self.check_in_time.isoformat() if self.check_in_time else None,
            'check_out_time': self.check_out_time.isoformat() if self.check_out_time else None,
            'status': self.status,
            'notes': self.notes,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }

        if include_employee and hasattr(self, 'employee') and self.employee:
            data['employee'] = self.employee.to_dict()

        return data

    def __repr__(self):
        return f'<Attendance {self.employee_id} {self.attendance_date}>'


class AccountingMapping(db.Model):
    """
    إعدادات الربط المحاسبي - ربط عمليات الفواتير بالحسابات المحاسبية
    
    أمثلة على أنواع الربط:
    - فواتير البيع: ربط العيار بحساب مخزون معين
    - فواتير الشراء: ربط العيار بحساب مخزون معين
    - النقدية: ربط بحساب الصندوق أو البنك
    - العمولات: ربط بحساب مصروف العمولات
    - الإيرادات: ربط بحساب الإيرادات
    """
    __tablename__ = 'accounting_mapping'
    
    id = db.Column(db.Integer, primary_key=True)
    
    # نوع العملية (invoice_type من جدول Invoice)
    # 'بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء', 'مرتجع شراء (مورد)'
    operation_type = db.Column(db.String(50), nullable=False, index=True)
    
    # نوع الحساب المراد ربطه
    # القيم المحتملة:
    # 
    # المخزون حسب العيار:
    # - 'inventory_18k': مخزون ذهب عيار 18
    # - 'inventory_21k': مخزون ذهب عيار 21
    # - 'inventory_22k': مخزون ذهب عيار 22
    # - 'inventory_24k': مخزون ذهب عيار 24
    # 
    # النقدية والبنوك:
    # - 'cash': الصندوق/النقدية
    # 
    # العملاء والموردين:
    # - 'customers': العملاء (حساب تجميعي)
    # - 'suppliers': الموردين (حساب تجميعي)
    # 
    # الإيرادات والتكاليف:
    # - 'revenue': الإيرادات
    # - 'cost': تكلفة البضاعة المباعة
    # 
    # العمولات:
    # - 'commission': مصروف العمولات
    # - 'commission_vat': ضريبة القيمة المضافة على العمولات
    # 
    # الضرائب:
    # - 'vat_payable': ضريبة القيمة المضافة المستحقة (دائنة)
    # - 'vat_receivable': ضريبة القيمة المضافة المدفوعة (مدينة)
    # 
    # حسابات إضافية:
    # - 'profit_loss': الأرباح والخسائر
    # - 'sales_returns': مردودات المبيعات
    # - 'purchase_returns': مردودات المشتريات
    account_type = db.Column(db.String(50), nullable=False, index=True)
    
    # الحساب المحاسبي المرتبط
    account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=False)
    account = db.relationship('Account', backref='accounting_mappings')
    
    # نسبة التخصيص (اختياري - للحالات التي تحتاج تقسيم نسبي)
    # مثلاً: 80% مخزون، 20% إيرادات
    allocation_percentage = db.Column(db.Float, nullable=True)
    
    # البيان/الوصف
    description = db.Column(db.Text, nullable=True)
    
    # حالة التفعيل
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    
    # معلومات التدقيق
    created_by = db.Column(db.String(100), nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now())
    
    # Unique constraint: لكل عملية ونوع حساب، يجب أن يكون هناك ربط واحد فقط
    __table_args__ = (
        db.UniqueConstraint('operation_type', 'account_type', name='_operation_account_type_uc'),
    )
    
    def to_dict(self):
        """تحويل إلى قاموس JSON"""
        return {
            'id': self.id,
            'operation_type': self.operation_type,
            'account_type': self.account_type,
            'account_id': self.account_id,
            'account_number': self.account.account_number if self.account else None,
            'account_name': self.account.name if self.account else None,
            'allocation_percentage': self.allocation_percentage,
            'description': self.description,
            'is_active': self.is_active,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }
    
    def __repr__(self):
        return f'<AccountingMapping {self.operation_type} - {self.account_type}>'


class SafeBox(db.Model):
    """
    نموذج الخزائن - لإدارة الخزائن المختلفة (نقدية، بنكية، ذهبية)
    كل خزينة مربوطة بحساب محاسبي محدد
    """
    __tablename__ = 'safe_box'
    
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)  # اسم الخزينة (صندوق النقدية الرئيسي، بنك الرياض، صندوق الكسر عيار 24)
    name_en = db.Column(db.String(100), nullable=True)  # الاسم بالإنجليزية
    safe_type = db.Column(db.String(20), nullable=False)  # نوع الخزينة: cash, bank, gold, check, clearing
    account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=False)  # الحساب المرتبط
    
    # معلومات إضافية للخزائن الذهبية
    karat = db.Column(db.Integer, nullable=True)  # العيار (18, 21, 22, 24) - للخزائن الذهبية فقط
    
    # معلومات إضافية للخزائن البنكية
    bank_name = db.Column(db.String(100), nullable=True)  # اسم البنك
    iban = db.Column(db.String(34), nullable=True)  # IBAN
    swift_code = db.Column(db.String(11), nullable=True)  # SWIFT/BIC Code
    branch = db.Column(db.String(100), nullable=True)  # الفرع
    
    # الحالة
    is_active = db.Column(db.Boolean, default=True, nullable=False)  # نشط/معطل
    is_default = db.Column(db.Boolean, default=False, nullable=False)  # هل هي الخزينة الافتراضية للنوع؟
    
    # ملاحظات
    notes = db.Column(db.Text, nullable=True)
    
    # معلومات التتبع
    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.now, onupdate=datetime.now, nullable=False)
    created_by = db.Column(db.String(100), nullable=True)
    
    # العلاقات
    account = db.relationship('Account', backref='safe_boxes', foreign_keys=[account_id])
    
    def to_dict(self, include_account=False, include_balance=False):
        """تحويل إلى قاموس JSON"""
        result = {
            'id': self.id,
            'name': self.name,
            'name_en': self.name_en,
            'safe_type': self.safe_type,
            'account_id': self.account_id,
            'karat': self.karat,
            'bank_name': self.bank_name,
            'iban': self.iban,
            'swift_code': self.swift_code,
            'branch': self.branch,
            'is_active': self.is_active,
            'is_default': self.is_default,
            'notes': self.notes,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
            'created_by': self.created_by,
        }
        
        if include_account and self.account:
            result['account'] = {
                'id': self.account.id,
                'account_number': self.account.account_number,
                'name': self.account.name,
                'type': self.account.type,
            }
        
        if include_balance and self.account:
            result['balance'] = self.account.to_dict()['balances']
        
        return result
    
    def __repr__(self):
        return f'<SafeBox {self.name} ({self.safe_type})>'
    
    @staticmethod
    def get_default_by_type(safe_type):
        """الحصول على الخزينة الافتراضية حسب النوع"""
        return SafeBox.query.filter_by(safe_type=safe_type, is_default=True, is_active=True).first()
    
    @staticmethod
    def get_active_by_type(safe_type):
        """الحصول على جميع الخزائن النشطة حسب النوع"""
        return SafeBox.query.filter_by(safe_type=safe_type, is_active=True).order_by(SafeBox.is_default.desc(), SafeBox.name).all()
    
    @staticmethod
    def get_gold_safe_by_karat(karat):
        """الحصول على خزينة الذهب حسب العيار
        
        ✅ سلوك النظام الموحّد (المفضل):
        - إذا وُجدت خزينة ذهب عامة (karat=None) نشطة، تُستخدم لكل العيارات.

        سلوك التوافق للخلف:
        - إذا لم توجد خزينة عامة، يبحث عن خزينة محددة بهذا العيار.
        """
        # Prefer a unified multi-karat gold safe when available.
        general = SafeBox.query.filter_by(safe_type='gold', karat=None, is_active=True).first()
        if general:
            return general

        # Backward compatible behavior: fall back to karat-specific safe.
        specific = SafeBox.query.filter_by(safe_type='gold', karat=karat, is_active=True).first()
        return specific


# ==========================================
# 📋 سجل التدقيق (Audit Log)
# ==========================================

class AuditLog(db.Model):
    """
    سجل التدقيق (Audit Log)
    ======================
    يسجل جميع العمليات الحساسة في النظام لأغراض المراجعة والتدقيق المحاسبي.
    
    الاستخدامات:
    - تتبع عمليات الترحيل وإلغاء الترحيل
    - تسجيل المستخدم والوقت ونوع العملية
    - حفظ تفاصيل العملية (JSON)
    - تحديد IP Address للأمان
    - دعم المراجعة المحاسبية والقانونية
    
    مثال:
    ------
    log = AuditLog(
        user_name='أحمد المحاسب',
        action='post_invoice',
        entity_type='Invoice',
        entity_id=123,
        details='{"total": 5000, "customer": "محل الذهب"}'
    )
    """
    __tablename__ = 'audit_logs'
    
    id = db.Column(db.Integer, primary_key=True)
    
    # معلومات المستخدم
    user_id = db.Column(db.Integer, nullable=True)  # سيُربط لاحقاً بجدول المستخدمين
    user_name = db.Column(db.String(100), nullable=False)  # اسم المستخدم الذي قام بالعملية
    
    # معلومات العملية
    action = db.Column(db.String(50), nullable=False)  # post_invoice, unpost_invoice, post_entry, etc.
    entity_type = db.Column(db.String(50), nullable=False)  # Invoice, JournalEntry, etc.
    entity_id = db.Column(db.Integer, nullable=False)  # ID الكيان المتأثر
    entity_number = db.Column(db.String(50), nullable=True)  # رقم الفاتورة/القيد للبحث السريع
    
    # معلومات زمنية
    timestamp = db.Column(db.DateTime, nullable=False, default=datetime.now)
    
    # معلومات الأمان
    ip_address = db.Column(db.String(45), nullable=True)  # IPv4 or IPv6
    user_agent = db.Column(db.String(255), nullable=True)  # معلومات المتصفح/التطبيق
    
    # تفاصيل العملية (JSON)
    details = db.Column(db.Text, nullable=True)  # JSON string مع التفاصيل
    
    # النتيجة
    success = db.Column(db.Boolean, nullable=False, default=True)  # نجحت العملية أم فشلت
    error_message = db.Column(db.Text, nullable=True)  # رسالة الخطأ إن وجدت

    
    # الفهارس لتسريع البحث
    __table_args__ = (
        db.Index('idx_audit_user_name', 'user_name'),
        db.Index('idx_audit_action', 'action'),
        db.Index('idx_audit_entity', 'entity_type', 'entity_id'),
        db.Index('idx_audit_timestamp', 'timestamp'),
        db.Index('idx_audit_entity_number', 'entity_number'),
    )
    
    def to_dict(self, include_details=True):
        """تحويل سجل التدقيق إلى قاموس"""
        result = {
            'id': self.id,
            'user_name': self.user_name,
            'action': self.action,
            'action_ar': self._get_action_arabic(),
            'entity_type': self.entity_type,
            'entity_type_ar': self._get_entity_type_arabic(),
            'entity_id': self.entity_id,
            'entity_number': self.entity_number,
            'timestamp': self.timestamp.isoformat() if self.timestamp else None,
            'ip_address': self.ip_address,
            'success': self.success,
        }
        
        if include_details and self.details:
            result['details'] = self.details
        
        if self.error_message:
            result['error_message'] = self.error_message
            
        return result
    
    def _get_action_arabic(self):
        """الحصول على الترجمة العربية للعملية"""
        actions_map = {
            'post_invoice': 'ترحيل فاتورة',
            'unpost_invoice': 'إلغاء ترحيل فاتورة',
            'post_invoice_batch': 'ترحيل دفعة فواتير',
            'post_entry': 'ترحيل قيد',
            'unpost_entry': 'إلغاء ترحيل قيد',
            'post_entry_batch': 'ترحيل دفعة قيود',
            'create_invoice': 'إنشاء فاتورة',
            'update_invoice': 'تعديل فاتورة',
            'delete_invoice': 'حذف فاتورة',
            'create_entry': 'إنشاء قيد',
            'update_entry': 'تعديل قيد',
            'delete_entry': 'حذف قيد',
            'shift_closing': 'إغلاق اليومية',
            'approve_voucher': 'ترحيل سند',
            'cancel_voucher': 'إلغاء سند',
        }
        return actions_map.get(self.action, self.action)
    
    def _get_entity_type_arabic(self):
        """الحصول على الترجمة العربية لنوع الكيان"""
        entity_types_map = {
            'Invoice': 'فاتورة',
            'JournalEntry': 'قيد يومية',
            'Customer': 'عميل',
            'Supplier': 'مورد',
            'Account': 'حساب',
            'ShiftClosing': 'إغلاق اليومية',
            'Voucher': 'سند',
        }
        return entity_types_map.get(self.entity_type, self.entity_type)
    
    def __repr__(self):
        return f'<AuditLog {self.id}: {self.user_name} - {self.action} on {self.entity_type}#{self.entity_id}>'
    
    @staticmethod
    def log_action(user_name, action, entity_type, entity_id, entity_number=None, 
                   details=None, ip_address=None, user_agent=None, success=True, 
                   error_message=None, user_id=None):
        """
        دالة مساعدة لتسجيل عملية في سجل التدقيق
        
        Parameters:
        -----------
        user_name : str
            اسم المستخدم الذي قام بالعملية
        action : str
            نوع العملية (post_invoice, unpost_entry, etc.)
        entity_type : str
            نوع الكيان (Invoice, JournalEntry, etc.)
        entity_id : int
            معرف الكيان
        entity_number : str, optional
            رقم الفاتورة/القيد للبحث السريع
        details : str, optional
            تفاصيل إضافية بصيغة JSON
        ip_address : str, optional
            عنوان IP للمستخدم
        user_agent : str, optional
            معلومات المتصفح/التطبيق
        success : bool, default=True
            هل نجحت العملية
        error_message : str, optional
            رسالة الخطأ إن فشلت العملية
        user_id : int, optional
            معرف المستخدم (للربط المستقبلي)
        
        Returns:
        --------
        AuditLog
            كائن سجل التدقيق المُنشأ
        
        Example:
        --------
        from models import AuditLog
        log = AuditLog.log_action(
            user_name='أحمد المحاسب',
            action='post_invoice',
            entity_type='Invoice',
            entity_id=123,
            entity_number='INV-2025-001',
            details='{"total": 5000, "customer_name": "محل الذهب"}',
            ip_address='192.168.1.10'
        )
        """
        try:
            log = AuditLog(
                user_id=user_id,
                user_name=user_name,
                action=action,
                entity_type=entity_type,
                entity_id=entity_id,
                entity_number=entity_number,
                details=details,
                ip_address=ip_address,
                user_agent=user_agent,
                success=success,
                error_message=error_message,
                timestamp=datetime.now()
            )
            db.session.add(log)
            # لا نقوم بـ commit هنا - سيتم commit في المكان الذي يستدعي log_action
            return log
        except Exception as e:
            print(f"خطأ في تسجيل Audit Log: {e}")
            return None
    
    @staticmethod
    def get_logs_by_user(user_name, limit=100):
        """الحصول على سجلات مستخدم معين"""
        return AuditLog.query.filter_by(user_name=user_name)\
            .order_by(AuditLog.timestamp.desc())\
            .limit(limit).all()
    
    @staticmethod
    def get_logs_by_entity(entity_type, entity_id):
        """الحصول على جميع سجلات كيان معين"""
        return AuditLog.query.filter_by(entity_type=entity_type, entity_id=entity_id)\
            .order_by(AuditLog.timestamp.desc()).all()
    
    @staticmethod
    def get_recent_logs(limit=100):
        """الحصول على آخر السجلات"""
        return AuditLog.query.order_by(AuditLog.timestamp.desc())\
            .limit(limit).all()
    
    @staticmethod
    def get_failed_logs(limit=50):
        """الحصول على العمليات الفاشلة"""
        return AuditLog.query.filter_by(success=False)\
            .order_by(AuditLog.timestamp.desc())\
            .limit(limit).all()


# ==========================================
# 🔐 نظام الصلاحيات (Permissions & Authorization)
# ==========================================

# جدول ربط المستخدمين بالأدوار (Many-to-Many)
user_roles = db.Table('user_roles',
    db.Column('user_id', db.Integer, db.ForeignKey('users.id', ondelete='CASCADE'), primary_key=True),
    db.Column('role_id', db.Integer, db.ForeignKey('roles.id', ondelete='CASCADE'), primary_key=True),
    db.Column('assigned_at', db.DateTime, default=datetime.now),
    db.Column('assigned_by', db.String(100))
)

# جدول ربط الأدوار بالصلاحيات (Many-to-Many)
role_permissions = db.Table('role_permissions',
    db.Column('role_id', db.Integer, db.ForeignKey('roles.id', ondelete='CASCADE'), primary_key=True),
    db.Column('permission_id', db.Integer, db.ForeignKey('permissions.id', ondelete='CASCADE'), primary_key=True),
    db.Column('granted_at', db.DateTime, default=datetime.now),
    db.Column('granted_by', db.String(100))
)


class User(db.Model):
    """
    نموذج المستخدم
    
    يمثل مستخدم النظام مع بيانات تسجيل الدخول والصلاحيات
    """
    __tablename__ = 'users'
    
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50), unique=True, nullable=False, index=True)
    email = db.Column(db.String(120), unique=True, nullable=True, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    full_name = db.Column(db.String(100), nullable=False)
    
    # حالة المستخدم
    is_active = db.Column(db.Boolean, default=True, nullable=False, index=True)
    is_admin = db.Column(db.Boolean, default=False, nullable=False)  # مدير النظام الرئيسي
    
    # معلومات إضافية
    phone = db.Column(db.String(20))
    department = db.Column(db.String(100))
    position = db.Column(db.String(100))  # المسمى الوظيفي
    
    # تواريخ
    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.now, onupdate=datetime.now)
    last_login = db.Column(db.DateTime)
    password_changed_at = db.Column(db.DateTime)
    
    # إدارة المستخدم
    created_by = db.Column(db.String(100))

    # صورة الملف الشخصي — base64 data URI
    photo = db.Column(db.Text, nullable=True)

    # العلاقات
    roles = db.relationship('Role', secondary=user_roles, backref=db.backref('users', lazy='dynamic'))
    
    # الفهارس
    __table_args__ = (
        db.Index('idx_user_username', 'username'),
        db.Index('idx_user_email', 'email'),
        db.Index('idx_user_active', 'is_active'),
    )
    
    def set_password(self, password):
        """تشفير وحفظ كلمة المرور"""
        from werkzeug.security import generate_password_hash
        self.password_hash = generate_password_hash(password, method='pbkdf2:sha256')
        self.password_changed_at = datetime.now()
    
    def check_password(self, password):
        """التحقق من كلمة المرور"""
        from werkzeug.security import check_password_hash
        return check_password_hash(self.password_hash, password)
    
    def has_permission(self, permission_code):
        """
        التحقق من امتلاك المستخدم لصلاحية معينة
        
        Parameters:
        -----------
        permission_code : str
            كود الصلاحية (مثل: 'invoice.post', 'user.create')
        
        Returns:
        --------
        bool
            True إذا كان المستخدم يمتلك الصلاحية
        """
        # المدير الرئيسي لديه جميع الصلاحيات
        if self.is_admin:
            return True
        
        # التحقق من صلاحيات جميع أدوار المستخدم
        for role in self.roles:
            if role.is_active and role.has_permission(permission_code):
                return True
        
        return False
    
    def has_role(self, role_name):
        """التحقق من امتلاك المستخدم لدور معين"""
        return any(role.name == role_name and role.is_active for role in self.roles)
    
    def get_all_permissions(self):
        """الحصول على جميع صلاحيات المستخدم"""
        if self.is_admin:
            return Permission.query.all()
        
        permissions = set()
        for role in self.roles:
            if role.is_active:
                permissions.update(role.permissions)
        return list(permissions)
    
    def to_dict(self, include_roles=True, include_permissions=False):
        """تحويل المستخدم إلى قاموس"""
        data = {
            'id': self.id,
            'username': self.username,
            'email': self.email,
            'full_name': self.full_name,
            'is_active': self.is_active,
            'is_admin': self.is_admin,
            'phone': self.phone,
            'department': self.department,
            'position': self.position,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'last_login': self.last_login.isoformat() if self.last_login else None,
            'created_by': self.created_by,
            'photo': self.photo,
        }

        if include_roles:
            data['roles'] = [role.to_dict(include_permissions=False) for role in self.roles]
        
        if include_permissions:
            data['permissions'] = [perm.to_dict() for perm in self.get_all_permissions()]
        
        return data
    
    def __repr__(self):
        return f'<User {self.username}>'


class Role(db.Model):
    """
    نموذج الدور (Role)
    
    يمثل مجموعة من الصلاحيات التي يمكن إسنادها للمستخدمين
    """
    __tablename__ = 'roles'
    
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(50), unique=True, nullable=False, index=True)
    name_ar = db.Column(db.String(100), nullable=False)  # الاسم بالعربية
    description = db.Column(db.Text)
    
    # حالة الدور
    is_active = db.Column(db.Boolean, default=True, nullable=False, index=True)
    is_system = db.Column(db.Boolean, default=False)  # أدوار النظام لا يمكن حذفها
    
    # تواريخ
    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.now, onupdate=datetime.now)
    
    # إدارة الدور
    created_by = db.Column(db.String(100))
    
    # العلاقات
    permissions = db.relationship('Permission', secondary=role_permissions, 
                                 backref=db.backref('roles', lazy='dynamic'))
    
    # الفهارس
    __table_args__ = (
        db.Index('idx_role_name', 'name'),
        db.Index('idx_role_active', 'is_active'),
    )
    
    def has_permission(self, permission_code):
        """التحقق من امتلاك الدور لصلاحية معينة"""
        return any(perm.code == permission_code and perm.is_active 
                  for perm in self.permissions)
    
    def add_permission(self, permission):
        """إضافة صلاحية للدور"""
        if permission not in self.permissions:
            self.permissions.append(permission)
    
    def remove_permission(self, permission):
        """إزالة صلاحية من الدور"""
        if permission in self.permissions:
            self.permissions.remove(permission)
    
    def to_dict(self, include_permissions=True, include_users_count=False):
        """تحويل الدور إلى قاموس"""
        data = {
            'id': self.id,
            'name': self.name,
            'name_ar': self.name_ar,
            'description': self.description,
            'is_active': self.is_active,
            'is_system': self.is_system,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'created_by': self.created_by
        }
        
        if include_permissions:
            data['permissions'] = [perm.to_dict() for perm in self.permissions]
        
        if include_users_count:
            data['users_count'] = self.users.count()
        
        return data
    
    def __repr__(self):
        return f'<Role {self.name}>'


class Permission(db.Model):
    """
    نموذج الصلاحية (Permission)
    
    يمثل صلاحية محددة في النظام (مثل: ترحيل فاتورة، حذف مستخدم)
    """
    __tablename__ = 'permissions'
    
    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(100), unique=True, nullable=False, index=True)
    name = db.Column(db.String(100), nullable=False)
    name_ar = db.Column(db.String(100), nullable=False)  # الاسم بالعربية
    description = db.Column(db.Text)
    category = db.Column(db.String(50), nullable=False, index=True)  # تصنيف الصلاحية
    
    # حالة الصلاحية
    is_active = db.Column(db.Boolean, default=True, nullable=False, index=True)
    
    # تواريخ
    created_at = db.Column(db.DateTime, default=datetime.now, nullable=False)
    
    # الفهارس
    __table_args__ = (
        db.Index('idx_permission_code', 'code'),
        db.Index('idx_permission_category', 'category'),
        db.Index('idx_permission_active', 'is_active'),
    )
    
    def to_dict(self):
        """تحويل الصلاحية إلى قاموس"""
        return {
            'id': self.id,
            'code': self.code,
            'name': self.name,
            'name_ar': self.name_ar,
            'description': self.description,
            'category': self.category,
            'is_active': self.is_active,
            'created_at': self.created_at.isoformat() if self.created_at else None
        }
    
    @staticmethod
    def get_by_category(category):
        """الحصول على جميع الصلاحيات في تصنيف معين"""
        return Permission.query.filter_by(category=category, is_active=True).all()
    
    @staticmethod
    def initialize_default_permissions():
        """
        إنشاء الصلاحيات الافتراضية للنظام
        
        Returns:
        --------
        int
            عدد الصلاحيات المُنشأة
        """
        default_permissions = [
            # صلاحيات الفواتير
            {'code': 'invoice.view', 'name': 'View Invoices', 'name_ar': 'عرض الفواتير', 
             'category': 'invoices', 'description': 'القدرة على عرض الفواتير'},
            {'code': 'invoice.create', 'name': 'Create Invoice', 'name_ar': 'إنشاء فاتورة', 
             'category': 'invoices', 'description': 'القدرة على إنشاء فواتير جديدة'},
            {'code': 'invoice.edit', 'name': 'Edit Invoice', 'name_ar': 'تعديل فاتورة', 
             'category': 'invoices', 'description': 'القدرة على تعديل الفواتير'},
            {'code': 'invoice.delete', 'name': 'Delete Invoice', 'name_ar': 'حذف فاتورة', 
             'category': 'invoices', 'description': 'القدرة على حذف الفواتير'},
            {'code': 'invoice.post', 'name': 'Post Invoice', 'name_ar': 'ترحيل فاتورة', 
             'category': 'invoices', 'description': 'القدرة على ترحيل الفواتير إلى الحسابات'},
            {'code': 'invoice.unpost', 'name': 'Unpost Invoice', 'name_ar': 'إلغاء ترحيل فاتورة', 
             'category': 'invoices', 'description': 'القدرة على إلغاء ترحيل الفواتير'},
            
            # صلاحيات القيود
            {'code': 'journal.view', 'name': 'View Journal Entries', 'name_ar': 'عرض القيود', 
             'category': 'journal', 'description': 'القدرة على عرض القيود اليومية'},
            {'code': 'journal.create', 'name': 'Create Journal Entry', 'name_ar': 'إنشاء قيد', 
             'category': 'journal', 'description': 'القدرة على إنشاء قيود يومية'},
            {'code': 'journal.edit', 'name': 'Edit Journal Entry', 'name_ar': 'تعديل قيد', 
             'category': 'journal', 'description': 'القدرة على تعديل القيود'},
            {'code': 'journal.delete', 'name': 'Delete Journal Entry', 'name_ar': 'حذف قيد', 
             'category': 'journal', 'description': 'القدرة على حذف القيود'},
            {'code': 'journal.post', 'name': 'Post Journal Entry', 'name_ar': 'ترحيل قيد', 
             'category': 'journal', 'description': 'القدرة على ترحيل القيود'},
            {'code': 'journal.unpost', 'name': 'Unpost Journal Entry', 'name_ar': 'إلغاء ترحيل قيد', 
             'category': 'journal', 'description': 'القدرة على إلغاء ترحيل القيود'},
            
            # صلاحيات المستخدمين
            {'code': 'user.view', 'name': 'View Users', 'name_ar': 'عرض المستخدمين', 
             'category': 'users', 'description': 'القدرة على عرض المستخدمين'},
            {'code': 'user.create', 'name': 'Create User', 'name_ar': 'إنشاء مستخدم', 
             'category': 'users', 'description': 'القدرة على إنشاء مستخدمين جدد'},
            {'code': 'user.edit', 'name': 'Edit User', 'name_ar': 'تعديل مستخدم', 
             'category': 'users', 'description': 'القدرة على تعديل بيانات المستخدمين'},
            {'code': 'user.delete', 'name': 'Delete User', 'name_ar': 'حذف مستخدم', 
             'category': 'users', 'description': 'القدرة على حذف المستخدمين'},
            {'code': 'user.manage_roles', 'name': 'Manage User Roles', 'name_ar': 'إدارة أدوار المستخدمين', 
             'category': 'users', 'description': 'القدرة على إسناد الأدوار للمستخدمين'},
            
            # صلاحيات الأدوار والصلاحيات
            {'code': 'role.view', 'name': 'View Roles', 'name_ar': 'عرض الأدوار', 
             'category': 'roles', 'description': 'القدرة على عرض الأدوار'},
            {'code': 'role.create', 'name': 'Create Role', 'name_ar': 'إنشاء دور', 
             'category': 'roles', 'description': 'القدرة على إنشاء أدوار جديدة'},
            {'code': 'role.edit', 'name': 'Edit Role', 'name_ar': 'تعديل دور', 
             'category': 'roles', 'description': 'القدرة على تعديل الأدوار'},
            {'code': 'role.delete', 'name': 'Delete Role', 'name_ar': 'حذف دور', 
             'category': 'roles', 'description': 'القدرة على حذف الأدوار'},
            {'code': 'role.manage_permissions', 'name': 'Manage Role Permissions', 'name_ar': 'إدارة صلاحيات الأدوار', 
             'category': 'roles', 'description': 'القدرة على إدارة صلاحيات الأدوار'},
            
            # صلاحيات التقارير
            {'code': 'report.view', 'name': 'View Reports', 'name_ar': 'عرض التقارير', 
             'category': 'reports', 'description': 'القدرة على عرض التقارير'},
            {'code': 'report.financial', 'name': 'View Financial Reports', 'name_ar': 'عرض التقارير المالية', 
             'category': 'reports', 'description': 'القدرة على عرض التقارير المالية الحساسة'},
            
            # صلاحيات الإعدادات
            {'code': 'settings.view', 'name': 'View Settings', 'name_ar': 'عرض الإعدادات', 
             'category': 'settings', 'description': 'القدرة على عرض إعدادات النظام'},
            {'code': 'settings.edit', 'name': 'Edit Settings', 'name_ar': 'تعديل الإعدادات', 
             'category': 'settings', 'description': 'القدرة على تعديل إعدادات النظام'},
            
            # صلاحيات سجل التدقيق
            {'code': 'audit.view', 'name': 'View Audit Logs', 'name_ar': 'عرض سجل التدقيق', 
             'category': 'audit', 'description': 'القدرة على عرض سجلات التدقيق'},
        ]
        
        created_count = 0
        for perm_data in default_permissions:
            existing = Permission.query.filter_by(code=perm_data['code']).first()
            if not existing:
                permission = Permission(**perm_data)
                db.session.add(permission)
                created_count += 1
        
        try:
            db.session.commit()
            return created_count
        except Exception as e:
            db.session.rollback()
            print(f"خطأ في إنشاء الصلاحيات: {e}")
            return 0
    
    def __repr__(self):
        return f'<Permission {self.code}>'


# =============================
# 🆕 نماذج نظام المكافآت
# =============================


class BonusRule(db.Model):
    __tablename__ = 'bonus_rule'
    __table_args__ = (
        db.CheckConstraint("points_source IN ('gold', 'cash')", name='ck_bonus_rule_points_source'),
    )

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text)
    rule_type = db.Column(db.String(50), nullable=False)  # sales_target, attendance, performance, fixed, profit_based, custom
    conditions = db.Column(db.JSON)
    bonus_type = db.Column(db.String(50), nullable=False)  # percentage, fixed, sales_percentage, profit_percentage
    bonus_value = db.Column(db.Float, nullable=False)
    min_bonus = db.Column(db.Float, default=0.0)
    max_bonus = db.Column(db.Float)
    target_departments = db.Column(db.JSON)
    target_positions = db.Column(db.JSON)
    target_employee_ids = db.Column(db.JSON)
    applicable_invoice_types = db.Column(db.JSON)
    # NULL = مسار gold (التوافق الخلفي) — 'gold' أو 'cash' عند points_based فقط
    points_source = db.Column(db.String(10), nullable=True)
    is_active = db.Column(db.Boolean, default=True)
    valid_from = db.Column(db.Date)
    valid_to = db.Column(db.Date)
    created_at = db.Column(db.DateTime, default=db.func.now())
    created_by = db.Column(db.String(100))

    def is_valid_for_employee(self, employee):
        today = date.today()
        if self.valid_from and today < self.valid_from:
            return False
        if self.valid_to and today > self.valid_to:
            return False

        if self.target_departments:
            if not employee.department or employee.department not in self.target_departments:
                return False

        if self.target_positions:
            if not employee.job_title or employee.job_title not in self.target_positions:
                return False

        if self.target_employee_ids:
            if employee.id not in self.target_employee_ids:
                return False

        return True

    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'description': self.description,
            'rule_type': self.rule_type,
            'conditions': self.conditions,
            'bonus_type': self.bonus_type,
            'bonus_value': self.bonus_value,
            'min_bonus': self.min_bonus,
            'max_bonus': self.max_bonus,
            'target_departments': self.target_departments,
            'target_positions': self.target_positions,
            'target_employee_ids': self.target_employee_ids,
            'applicable_invoice_types': self.applicable_invoice_types,
            'points_source': self.points_source,
            'is_active': self.is_active,
            'valid_from': self.valid_from.isoformat() if self.valid_from else None,
            'valid_to': self.valid_to.isoformat() if self.valid_to else None,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'created_by': self.created_by,
        }

    def to_snapshot(self) -> dict:
        """نسخة ثابتة للتدقيق — مستقلة عن to_dict() الذي قد يتغير لأسباب API."""
        return {
            'id': self.id,
            'name': self.name,
            'rule_type': self.rule_type,
            'bonus_type': self.bonus_type,
            'bonus_value': self.bonus_value,
            'min_bonus': self.min_bonus,
            'max_bonus': self.max_bonus,
            'conditions': self.conditions,
            'applicable_invoice_types': self.applicable_invoice_types,
            'points_source': self.points_source,
            'valid_from': self.valid_from.isoformat() if self.valid_from else None,
            'valid_to': self.valid_to.isoformat() if self.valid_to else None,
        }


class EmployeeBonus(db.Model):
    __tablename__ = 'employee_bonus'

    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.Integer, db.ForeignKey('employee.id'), nullable=False)
    bonus_rule_id = db.Column(db.Integer, db.ForeignKey('bonus_rule.id'), nullable=True)
    bonus_type = db.Column(db.String(50), nullable=False)
    amount = db.Column(db.Float, nullable=False, default=0.0)
    status = db.Column(db.String(20), default='pending')  # pending, approved, rejected, paid, reversed
    period_start = db.Column(db.Date)
    period_end = db.Column(db.Date)
    calculation_data = db.Column(db.JSON)
    notes = db.Column(db.Text)
    payment_reference = db.Column(db.String(100))
    created_at = db.Column(db.DateTime, default=db.func.now())
    approved_at  = db.Column(db.DateTime)
    approved_by  = db.Column(db.String(100))
    rejected_at  = db.Column(db.DateTime)
    rejected_by  = db.Column(db.String(100))
    paid_at      = db.Column(db.DateTime)
    paid_by      = db.Column(db.String(100))
    reversed_at  = db.Column(db.DateTime)
    reversed_by  = db.Column(db.String(100))
    reversal_reason = db.Column(db.Text)

    # ── Snapshots (write-once عند الإنشاء — لا يُعاد كتابتهما أبداً) ──────
    rule_snapshot        = db.Column(db.JSON)  # نسخة BonusRule.to_snapshot() لحظة الحساب
    calculation_snapshot = db.Column(db.JSON)  # {inputs, calculation, result}

    # ربط مع الخزينة عند الدفع
    office_id = db.Column(db.Integer, db.ForeignKey('office.id'), nullable=True)

    employee = db.relationship('Employee', backref=db.backref('bonuses', lazy=True))
    rule     = db.relationship('BonusRule', backref=db.backref('bonuses', lazy=True))
    office   = db.relationship('Office', backref=db.backref('bonus_payments', lazy=True))

    # ─── State Machine ────────────────────────────────────────────────────
    # الانتقالات المسموحة فقط:  pending  → approved | rejected
    #                            approved → paid | reversed
    #                            paid, rejected, reversed → لا شيء (حالات نهائية)
    # ملاحظة: paid → reversed ممنوع بقرار السياسة (422 في طبقة الخدمة)؛
    #          state machine لا يُدرجه لأن القرار المحاسبي لم يُحسم بعد.
    _VALID_TRANSITIONS: dict = {
        'pending':  {'approved', 'rejected'},
        'approved': {'paid', 'reversed'},
        'rejected': set(),
        'paid':     set(),
        'reversed': set(),
    }

    def _transition(self, new_status: str) -> None:
        """يُطبّق انتقال الحالة — يُطلق ValueError على الانتقال غير المسموح."""
        current = self.status or 'pending'
        allowed = self._VALID_TRANSITIONS.get(current, set())
        if new_status not in allowed:
            raise ValueError(
                f'انتقال غير مسموح: {current} → {new_status}. '
                f'المسموح من هذه الحالة: {allowed or "لا شيء (حالة نهائية)"}'
            )
        self.status = new_status

    def approve(self, approved_by: str = 'system') -> None:
        self._transition('approved')
        self.approved_by = approved_by
        self.approved_at = datetime.now()

    def reject(self, reason: str = None, rejected_by: str = 'system') -> None:
        self._transition('rejected')
        self.rejected_by = rejected_by
        self.rejected_at = datetime.now()
        if reason:
            self.notes = f"{self.notes or ''}\nرفض: {reason}".strip()

    def mark_as_paid(self, reference: str = None, paid_by: str = 'system') -> None:
        self._transition('paid')
        self.paid_at  = datetime.now()
        self.paid_by  = paid_by
        if reference:
            self.payment_reference = reference

    def reverse(self, reversed_by: str = 'system', reason: str = None) -> None:
        """يُعكس مكافأة معتمدة فقط. المكافآت المدفوعة تُرفض من طبقة الخدمة."""
        self._transition('reversed')
        self.reversed_by = reversed_by
        self.reversed_at = datetime.now()
        if reason:
            self.reversal_reason = reason

    def to_dict(self, include_employee=False, include_rule=False):
        result = {
            'id': self.id,
            'employee_id': self.employee_id,
            'bonus_rule_id': self.bonus_rule_id,
            'bonus_type': self.bonus_type,
            'amount': self.amount,
            'status': self.status,
            'period_start': self.period_start.isoformat() if self.period_start else None,
            'period_end': self.period_end.isoformat() if self.period_end else None,
            'calculation_data': self.calculation_data,
            'notes': self.notes,
            'payment_reference': self.payment_reference,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'approved_at':  self.approved_at.isoformat()  if self.approved_at  else None,
            'approved_by':  self.approved_by,
            'rejected_at':  self.rejected_at.isoformat()  if self.rejected_at  else None,
            'rejected_by':  self.rejected_by,
            'paid_at':      self.paid_at.isoformat()      if self.paid_at      else None,
            'paid_by':      self.paid_by,
            'reversed_at':  self.reversed_at.isoformat()  if self.reversed_at  else None,
            'reversed_by':  self.reversed_by,
            'reversal_reason': self.reversal_reason,
            'rule_snapshot':         self.rule_snapshot,
            'calculation_snapshot':  self.calculation_snapshot,
            'office_id':    self.office_id,
            'office_name':  self.office.name if self.office else None,
        }
        if include_employee and self.employee:
            result['employee'] = self.employee.to_dict() if hasattr(self.employee, 'to_dict') else {
                'id': self.employee.id,
                'name': getattr(self.employee, 'name', None),
                'department': getattr(self.employee, 'department', None),
                'job_title': getattr(self.employee, 'job_title', None),
            }
        if include_rule and self.rule:
            result['rule'] = self.rule.to_dict()
            result['bonus_rule'] = result['rule']  # Flutter alias
        return result


class BonusInvoiceLink(db.Model):
    __tablename__ = 'bonus_invoice_link'

    id = db.Column(db.Integer, primary_key=True)
    bonus_id = db.Column(db.Integer, db.ForeignKey('employee_bonus.id'), nullable=False)
    invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=False)


class GoalAchievement(db.Model):
    """سجل الإنجازات التي يحققها الموظف عند تجاوز أهداف المبيعات/النقاط.
    
    يُعرض للمستخدم كـ overlay احتفالية عند فتح التطبيق.
    """

    __tablename__ = 'goal_achievement'

    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.Integer, db.ForeignKey('employee.id'), nullable=False)
    bonus_rule_id = db.Column(db.Integer, db.ForeignKey('bonus_rule.id'), nullable=True)
    bonus_id = db.Column(db.Integer, db.ForeignKey('employee_bonus.id'), nullable=True)

    goal_name = db.Column(db.String(200), nullable=False)
    goal_description = db.Column(db.Text, nullable=True)
    bonus_amount = db.Column(db.Float, nullable=False, default=0.0)
    currency = db.Column(db.String(10), default='ر.س')
    metrics = db.Column(db.JSON, nullable=True)  # {points, invoices, rank, ...}

    # مفتاح الفترة — يُستخدم للتحقق من التكرار (e.g. 'monthly-2026-05', 'weekly-2026-W21')
    period_key = db.Column(db.String(30), nullable=True, index=True)
    # نوع الفترة: 'daily' | 'weekly' | 'monthly'
    goal_period = db.Column(db.String(20), nullable=True)

    achieved_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    seen_by_user = db.Column(db.Boolean, default=False, nullable=False, index=True)
    seen_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)

    employee = db.relationship('Employee', backref=db.backref('achievements', lazy=True))

    def mark_seen(self):
        self.seen_by_user = True
        self.seen_at = datetime.now()

    def to_dict(self):
        emp = self.employee
        # period_key: prefer dedicated column, fall back to metrics['period_key']
        pk = self.period_key
        if not pk and isinstance(self.metrics, dict):
            pk = self.metrics.get('period_key')
        return {
            'id': self.id,
            'employee_id': self.employee_id,
            'employee_name': emp.name if emp else '—',
            'department': emp.department if emp else None,
            'position': emp.job_title if emp else None,
            'bonus_rule_id': self.bonus_rule_id,
            'bonus_id': self.bonus_id,
            'goal_name': self.goal_name,
            'goal_description': self.goal_description,
            'bonus_amount': self.bonus_amount,
            'currency': self.currency,
            'metrics': self.metrics or {},
            'goal_period': self.goal_period,
            'period_key': pk,
            'achieved_at': self.achieved_at.isoformat() if self.achieved_at else None,
            'seen_by_user': bool(self.seen_by_user),
            'seen_at': self.seen_at.isoformat() if self.seen_at else None,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }


class BonusClawbackCandidate(db.Model):
    """سجل إخباري: فاتورة مرتجع بيع رُحِّلت وقد تستوجب عكس مكافأة مرتبطة.

    لا يُنشئ قيوداً محاسبية. القرار المالي يبقى يدوياً عبر
    POST /bonuses/{id}/reverse. الـ Posting Pipeline يكتب هنا فقط.
    """

    __tablename__ = 'bonus_clawback_candidate'
    __table_args__ = (
        # يمنع إنشاء مرشح مكرر لنفس (مكافأة × مرتجع) عند الإعادة أو التزامن
        db.UniqueConstraint('bonus_id', 'return_invoice_id',
                            name='uq_clawback_bonus_return_invoice'),
    )

    id = db.Column(db.Integer, primary_key=True)
    bonus_id = db.Column(db.Integer,
                         db.ForeignKey('employee_bonus.id', ondelete='CASCADE'),
                         nullable=False, index=True)
    return_invoice_id = db.Column(db.Integer,
                                  db.ForeignKey('invoice.id', ondelete='SET NULL'),
                                  nullable=True, index=True)
    original_invoice_id = db.Column(db.Integer,
                                    db.ForeignKey('invoice.id', ondelete='SET NULL'),
                                    nullable=True)
    reason = db.Column(db.Text, nullable=True)
    status = db.Column(db.String(20), nullable=False, default='open')  # open | dismissed | actioned
    dismissed_by = db.Column(db.String(100), nullable=True)
    dismissed_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)

    bonus = db.relationship('EmployeeBonus',
                            backref=db.backref('clawback_candidates', lazy=True))

    def dismiss(self, dismissed_by: str) -> None:
        if self.status != 'open':
            raise ValueError(f'لا يمكن رفض مرشح بحالة "{self.status}"')
        self.status = 'dismissed'
        self.dismissed_by = dismissed_by
        self.dismissed_at = datetime.now()

    def to_dict(self):
        return {
            'id': self.id,
            'bonus_id': self.bonus_id,
            'return_invoice_id': self.return_invoice_id,
            'original_invoice_id': self.original_invoice_id,
            'reason': self.reason,
            'status': self.status,
            'dismissed_by': self.dismissed_by,
            'dismissed_at': self.dismissed_at.isoformat() if self.dismissed_at else None,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }


class BonusCalculationLog(db.Model):
    """سجل كل تشغيلة للمجدول — يُعرض في الواجهة كإشعار داخلي بعد الاحتساب التلقائي."""

    __tablename__ = 'bonus_calculation_log'

    id = db.Column(db.Integer, primary_key=True)
    run_at = db.Column(db.DateTime, nullable=False, default=datetime.now)
    # daily | weekly | monthly | manual
    period_type = db.Column(db.String(20), nullable=False)
    period_start = db.Column(db.Date, nullable=False)
    period_end = db.Column(db.Date, nullable=False)
    bonus_count = db.Column(db.Integer, nullable=False, default=0)
    total_amount = db.Column(db.Float, nullable=False, default=0.0)
    # success | failed
    status = db.Column(db.String(20), nullable=False, default='success')
    message = db.Column(db.Text, nullable=True)

    def to_dict(self):
        return {
            'id': self.id,
            'run_at': self.run_at.isoformat() if self.run_at else None,
            'period_type': self.period_type,
            'period_start': self.period_start.isoformat() if self.period_start else None,
            'period_end': self.period_end.isoformat() if self.period_end else None,
            'bonus_count': self.bonus_count,
            'total_amount': self.total_amount,
            'status': self.status,
            'message': self.message,
        }


class SystemAlert(db.Model):
    """Persistent in-app alerts for managers (MVP).

    Used for shift closing threshold breaches (cash/gold deficits).
    """

    __tablename__ = 'system_alerts'

    id = db.Column(db.Integer, primary_key=True)

    alert_type = db.Column(db.String(50), nullable=False, index=True)  # shift_closing
    severity = db.Column(db.String(20), nullable=False, index=True)  # critical | warning | info

    title = db.Column(db.String(200), nullable=True)
    message = db.Column(db.Text, nullable=True)

    entity_type = db.Column(db.String(50), nullable=True)  # ShiftClosing
    entity_id = db.Column(db.Integer, nullable=True)
    entity_number = db.Column(db.String(50), nullable=True, index=True)

    details = db.Column(db.Text, nullable=True)  # JSON

    is_reviewed = db.Column(db.Boolean, nullable=False, default=False, index=True)
    reviewed_at = db.Column(db.DateTime, nullable=True)
    reviewed_by = db.Column(db.String(100), nullable=True)

    created_by = db.Column(db.String(100), nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False, index=True)

    def to_dict(self):
        import json

        decoded_details = None
        if self.details:
            try:
                decoded_details = json.loads(self.details) if isinstance(self.details, str) else self.details
            except Exception:
                decoded_details = None

        return {
            'id': self.id,
            'alert_type': self.alert_type,
            'severity': self.severity,
            'title': self.title,
            'message': self.message,
            'entity_type': self.entity_type,
            'entity_id': self.entity_id,
            'entity_number': self.entity_number,
            'details': decoded_details,
            'is_reviewed': bool(self.is_reviewed),
            'reviewed_at': self.reviewed_at.isoformat() if self.reviewed_at else None,
            'reviewed_by': self.reviewed_by,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }


class InventoryLedger(db.Model):
    """Append-only event log for gold inventory weight movements.

    One row per (source_line, movement_type). Never updated — only inserted.
    Balance = SUM(weight_delta) filtered by bucket (branch + category + karat).

    weight_delta is signed: positive = stock IN, negative = stock OUT.
    Unit: actual karat weight in grams (same unit as InvoiceItem.weight).
    """
    __tablename__ = 'inventory_ledger'

    id = db.Column(db.Integer, primary_key=True)

    # ── Source document ──────────────────────────────────────────────────────
    # 'invoice' | 'opening_entry' | 'adjustment' | 'transfer'
    source_type = db.Column(db.String(40), nullable=False, index=True)
    source_id   = db.Column(db.Integer, nullable=False, index=True)
    # InvoiceItem.id for invoice lines; None for header-level source types
    source_line_id = db.Column(db.Integer, nullable=True)
    # 'sale' | 'purchase_from_customer' | 'supplier_purchase' |
    # 'sale_return' | 'purchase_return' | 'opening' | 'adjustment'
    movement_type = db.Column(db.String(30), nullable=False, index=True)

    # ── Bucket: branch + category + karat ───────────────────────────────────
    branch_id   = db.Column(db.Integer, db.ForeignKey('branch.id'),   nullable=True, index=True)
    category_id = db.Column(db.Integer, db.ForeignKey('category.id'), nullable=True, index=True)
    karat       = db.Column(db.Float, nullable=False)

    # ── Weight delta (grams, signed) ─────────────────────────────────────────
    weight_delta = db.Column(db.Float, nullable=False)

    # ── Metadata ─────────────────────────────────────────────────────────────
    posted_at = db.Column(db.DateTime, nullable=False, default=datetime.now, index=True)
    posted_by = db.Column(db.String(100), nullable=True)
    notes     = db.Column(db.Text, nullable=True)

    __table_args__ = (
        # Idempotency guard: prevents double-posting the same source line
        db.UniqueConstraint(
            'source_type', 'source_id', 'source_line_id', 'movement_type',
            name='uq_inventory_ledger_idempotency',
        ),
        # Composite index for bucket-balance queries
        db.Index('ix_inventory_ledger_bucket', 'branch_id', 'category_id', 'karat'),
    )

    def to_dict(self):
        return {
            'id':            self.id,
            'source_type':   self.source_type,
            'source_id':     self.source_id,
            'source_line_id': self.source_line_id,
            'movement_type': self.movement_type,
            'branch_id':     self.branch_id,
            'category_id':   self.category_id,
            'karat':         self.karat,
            'weight_delta':  self.weight_delta,
            'posted_at':     self.posted_at.isoformat() if self.posted_at else None,
            'posted_by':     self.posted_by,
            'notes':         self.notes,
        }


class InventoryBalance(db.Model):
    """Cached Projection of InventoryLedger — one row per bucket (branch + category + karat).

    Updated atomically inside the same DB transaction as the Ledger write.
    `balance` always equals SUM(InventoryLedger.weight_delta) for this bucket
    up to and including `snapshot_max_ledger_id`.

    The Ledger is the source of truth; InventoryBalance is a read optimisation.
    To rebuild from scratch: DELETE FROM inventory_balance, then replay the Ledger.
    """
    __tablename__ = 'inventory_balance'

    id = db.Column(db.Integer, primary_key=True)

    # ── Bucket ───────────────────────────────────────────────────────────────
    branch_id   = db.Column(db.Integer, db.ForeignKey('branch.id'),   nullable=True)
    category_id = db.Column(db.Integer, db.ForeignKey('category.id'), nullable=True)
    karat       = db.Column(db.Float, nullable=False)

    # ── Cached balance (grams, signed) ───────────────────────────────────────
    balance                 = db.Column(db.Float, nullable=False, default=0.0)
    snapshot_max_ledger_id  = db.Column(db.Integer, nullable=True)

    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.now)

    __table_args__ = (
        # One row per bucket — enforces the Projection invariant
        db.UniqueConstraint(
            'branch_id', 'category_id', 'karat',
            name='uq_inventory_balance_bucket',
        ),
        db.Index('ix_inventory_balance_bucket', 'branch_id', 'category_id', 'karat'),
    )

    def to_dict(self):
        return {
            'id':                       self.id,
            'branch_id':                self.branch_id,
            'category_id':              self.category_id,
            'karat':                    self.karat,
            'balance':                  self.balance,
            'snapshot_max_ledger_id':   self.snapshot_max_ledger_id,
            'updated_at':               self.updated_at.isoformat() if self.updated_at else None,
        }


class InventoryCountSession(db.Model):
    """A physical inventory count session scoped to a branch.

    Lifecycle:  open → counting → closed → approved
                         ↑                      ↓
                    (physical count)       (GL adjustment generated in Phase 4)

    snapshot_ledger_id is set once at open time to MAX(InventoryLedger.id).
    This pins the "expected" balance — any Ledger entry with id > snapshot
    belongs to the period after this count began and is excluded from
    expected calculations.
    """
    __tablename__ = 'inventory_count_session'

    id          = db.Column(db.Integer, primary_key=True)
    branch_id   = db.Column(db.Integer, db.ForeignKey('branch.id'), nullable=True, index=True)

    # 'open' | 'counting' | 'closed' | 'approved' | 'cancelled'
    status      = db.Column(db.String(20), nullable=False, default='open', index=True)

    # 'periodic' (default) | 'opening' (first-time stock entry — no GL adjustment)
    session_type = db.Column(db.String(20), nullable=False, default='periodic',
                             server_default=db.text("'periodic'"))

    # MAX(InventoryLedger.id) captured at open time — the reference point
    snapshot_ledger_id = db.Column(db.Integer, nullable=True)

    # Blind count: expected_weight hidden from counters until session closes.
    # True by default — prevents anchoring bias and eliminates manipulation risk.
    # Manager may set False for quick spot-checks where expected is needed.
    blind_count = db.Column(db.Boolean, nullable=False, default=True)

    opened_by   = db.Column(db.String(100), nullable=True)
    opened_at   = db.Column(db.DateTime, nullable=False, default=datetime.now)
    closed_at   = db.Column(db.DateTime, nullable=True)
    approved_by = db.Column(db.String(100), nullable=True)
    approved_at = db.Column(db.DateTime, nullable=True)
    notes       = db.Column(db.Text, nullable=True)

    lines = db.relationship(
        'InventoryCountLine',
        backref='session',
        lazy='dynamic',
        cascade='all, delete-orphan',
    )

    def to_dict(self):
        return {
            'id':                  self.id,
            'branch_id':           self.branch_id,
            'status':              self.status,
            'session_type':        getattr(self, 'session_type', 'periodic'),
            'snapshot_ledger_id':  self.snapshot_ledger_id,
            'blind_count':         self.blind_count,
            'opened_by':           self.opened_by,
            'opened_at':           self.opened_at.isoformat() if self.opened_at else None,
            'closed_at':           self.closed_at.isoformat() if self.closed_at else None,
            'approved_by':         self.approved_by,
            'approved_at':         self.approved_at.isoformat() if self.approved_at else None,
            'notes':               self.notes,
        }


class InventoryCountLine(db.Model):
    """One count line = one physical count for a bucket (category + karat).

    expected_weight   — balance at snapshot_ledger_id (frozen at session open)
    expected_ledger_id — snapshot_max_ledger_id from InventoryBalance at open time
                         Answers "why was expected 523.42g?" even after balance changes.
    counted_weight    — physical count by the warehouse team
    variance          — counted_weight - expected_weight (positive = surplus, negative = shortage)
    """
    __tablename__ = 'inventory_count_line'

    id         = db.Column(db.Integer, primary_key=True)
    session_id = db.Column(
        db.Integer, db.ForeignKey('inventory_count_session.id', ondelete='CASCADE'),
        nullable=False, index=True,
    )

    # Bucket
    branch_id   = db.Column(db.Integer, db.ForeignKey('branch.id'),   nullable=True)
    category_id = db.Column(db.Integer, db.ForeignKey('category.id'), nullable=True)
    karat       = db.Column(db.Float, nullable=False)

    # Reference point
    expected_weight    = db.Column(db.Float, nullable=False, default=0.0)
    expected_ledger_id = db.Column(db.Integer, nullable=True)  # InventoryBalance.snapshot_max_ledger_id at open

    # Physical count
    counted_weight = db.Column(db.Float, nullable=True)
    variance       = db.Column(db.Float, nullable=True)  # computed: counted - expected

    counted_by = db.Column(db.String(100), nullable=True)
    counted_at = db.Column(db.DateTime, nullable=True)
    notes      = db.Column(db.Text, nullable=True)

    __table_args__ = (
        # One line per bucket per session
        db.UniqueConstraint(
            'session_id', 'category_id', 'karat',
            name='uq_inventory_count_line_bucket',
        ),
    )

    def to_dict(self):
        return {
            'id':                  self.id,
            'session_id':          self.session_id,
            'branch_id':           self.branch_id,
            'category_id':         self.category_id,
            'karat':               self.karat,
            'expected_weight':     self.expected_weight,
            'expected_ledger_id':  self.expected_ledger_id,
            'counted_weight':      self.counted_weight,
            'variance':            self.variance,
            'counted_by':          self.counted_by,
            'counted_at':          self.counted_at.isoformat() if self.counted_at else None,
            'notes':               self.notes,
        }


class InventoryAdjustment(db.Model):
    """Difference Document — records the variance between expected and counted weight.

    Always flows through InventoryPostingService.post(adjustment), never writes
    directly to InventoryLedger or InventoryBalance.

    adjustment_type:
        'count_variance' — generated from an approved InventoryCountSession
        'manual'         — standalone adjustment (write-off, write-on, correction)

    Lifecycle: draft → posted | void
    """
    __tablename__ = 'inventory_adjustment'

    id              = db.Column(db.Integer, primary_key=True)
    session_id      = db.Column(
        db.Integer, db.ForeignKey('inventory_count_session.id', ondelete='SET NULL'),
        nullable=True, index=True,
    )
    branch_id       = db.Column(db.Integer, db.ForeignKey('branch.id'), nullable=True, index=True)

    # 'count_variance' | 'manual'
    adjustment_type = db.Column(db.String(30), nullable=False, default='manual')
    # 'draft' | 'posted' | 'void'
    status          = db.Column(db.String(20), nullable=False, default='draft', index=True)

    reason          = db.Column(db.String(200), nullable=True)

    created_by      = db.Column(db.String(100), nullable=True)
    created_at      = db.Column(db.DateTime, nullable=False, default=datetime.now)
    posted_by       = db.Column(db.String(100), nullable=True)
    posted_at       = db.Column(db.DateTime, nullable=True)

    # Phase 5: FK to JournalEntry once GL integration is built
    gl_entry_id     = db.Column(db.Integer, nullable=True)

    notes           = db.Column(db.Text, nullable=True)

    lines = db.relationship(
        'InventoryAdjustmentLine',
        backref='adjustment',
        lazy='dynamic',
        cascade='all, delete-orphan',
    )

    def to_dict(self):
        return {
            'id':               self.id,
            'session_id':       self.session_id,
            'branch_id':        self.branch_id,
            'adjustment_type':  self.adjustment_type,
            'status':           self.status,
            'reason':           self.reason,
            'created_by':       self.created_by,
            'created_at':       self.created_at.isoformat() if self.created_at else None,
            'posted_by':        self.posted_by,
            'posted_at':        self.posted_at.isoformat() if self.posted_at else None,
            'gl_entry_id':      self.gl_entry_id,
            'notes':            self.notes,
        }


class InventoryAdjustmentLine(db.Model):
    """One adjustment line per bucket — carries the signed variance_weight.

    variance_weight = counted_weight - expected_weight (signed).
    Positive = surplus (write-on).  Negative = shortage (write-off).

    expected_weight and counted_weight are stored for traceability;
    only variance_weight is used by InventoryPostingService as weight_delta.
    """
    __tablename__ = 'inventory_adjustment_line'

    id              = db.Column(db.Integer, primary_key=True)
    adjustment_id   = db.Column(
        db.Integer, db.ForeignKey('inventory_adjustment.id', ondelete='CASCADE'),
        nullable=False, index=True,
    )

    # Bucket
    branch_id       = db.Column(db.Integer, db.ForeignKey('branch.id'),   nullable=True)
    category_id     = db.Column(db.Integer, db.ForeignKey('category.id'), nullable=True)
    karat           = db.Column(db.Float, nullable=False)

    # Traceability
    expected_weight = db.Column(db.Float, nullable=False, default=0.0)
    counted_weight  = db.Column(db.Float, nullable=False, default=0.0)
    # Signed delta — what InventoryPostingService applies to the Ledger
    variance_weight = db.Column(db.Float, nullable=False)

    notes           = db.Column(db.Text, nullable=True)

    __table_args__ = (
        db.UniqueConstraint(
            'adjustment_id', 'category_id', 'karat',
            name='uq_inventory_adjustment_line_bucket',
        ),
    )

    def to_dict(self):
        return {
            'id':               self.id,
            'adjustment_id':    self.adjustment_id,
            'branch_id':        self.branch_id,
            'category_id':      self.category_id,
            'karat':            self.karat,
            'expected_weight':  self.expected_weight,
            'counted_weight':   self.counted_weight,
            'variance_weight':  self.variance_weight,
            'notes':            self.notes,
        }


class HistoricalClearingAdjustment(db.Model):
    """Admin-only tool for correcting historical clearing gaps.

    Three typed categories keep the audit trail unambiguous:
      historical_allocation_gap   – SL/SafeBox mismatch from rebuild reallocation (e.g. AV133)
      historical_gl_adjustment    – GL-only correction made before SafeBox layer existed (e.g. AV210)
      historical_opening_balance  – Opening balance entry with no matching IP history

    Workflow: create (status=pending) → approve → apply → status=applied
    Only 'applied' records have safe_box_transaction_id and journal_entry_id populated.
    """

    __tablename__ = 'historical_clearing_adjustment'

    VALID_TYPES = {
        'historical_allocation_gap',
        'historical_gl_adjustment',
        'historical_opening_balance',
    }

    id = db.Column(db.Integer, primary_key=True)
    safe_box_id = db.Column(db.Integer, db.ForeignKey('safe_box.id'), nullable=False, index=True)
    amount = db.Column(db.Float, nullable=False)

    adjustment_type = db.Column(db.String(50), nullable=False)
    # historical_allocation_gap | historical_gl_adjustment | historical_opening_balance

    reference_voucher_id = db.Column(db.Integer, db.ForeignKey('voucher.id'), nullable=True)
    reference_voucher_number = db.Column(db.String(50), nullable=True)

    reason = db.Column(db.Text, nullable=False)

    created_by = db.Column(db.String(100), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)

    approved_by = db.Column(db.String(100), nullable=True)
    approved_at = db.Column(db.DateTime, nullable=True)

    status = db.Column(db.String(20), nullable=False, default='pending', index=True)
    # pending | applied | cancelled

    # Populated after apply()
    safe_box_transaction_id = db.Column(db.Integer, db.ForeignKey('safe_box_transaction.id'), nullable=True)
    journal_entry_id = db.Column(db.Integer, db.ForeignKey('journal_entry.id'), nullable=True)

    safe_box = db.relationship('SafeBox', foreign_keys=[safe_box_id])
    reference_voucher = db.relationship('Voucher', foreign_keys=[reference_voucher_id])
    safe_box_transaction = db.relationship('SafeBoxTransaction', foreign_keys=[safe_box_transaction_id])
    journal_entry = db.relationship('JournalEntry', foreign_keys=[journal_entry_id])

    def to_dict(self):
        return {
            'id': self.id,
            'safe_box_id': self.safe_box_id,
            'amount': self.amount,
            'adjustment_type': self.adjustment_type,
            'reference_voucher_id': self.reference_voucher_id,
            'reference_voucher_number': self.reference_voucher_number,
            'reason': self.reason,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'approved_by': self.approved_by,
            'approved_at': self.approved_at.isoformat() if self.approved_at else None,
            'status': self.status,
            'safe_box_transaction_id': self.safe_box_transaction_id,
            'journal_entry_id': self.journal_entry_id,
        }


# ── Operational findings (S5) ─────────────────────────────────────────────────

class ReconciliationFinding(db.Model):
    """Operational findings written by schedulers and reconciliation jobs.

    Shared table — one source of truth for all operational gaps.  Consumers
    (ops dashboards, alerting queries) read a single table regardless of which
    job produced the finding.

    Kinds (extensible, add new kinds as new jobs emit here):
      STALE_SETTLEMENT — no auto_settlement voucher produced within the
                         expected window; written by ClearingSettlementScheduler.

    Lifecycle: created by the detecting job, resolved manually or by the job
    itself when the condition clears (resolved_at set to a non-NULL timestamp).
    check_count is incremented on every detection cycle while the finding
    remains open, giving ops a sense of how long the gap has persisted.
    """

    __tablename__ = 'reconciliation_findings'

    id = db.Column(db.Integer, primary_key=True)
    kind = db.Column(db.String(50), nullable=False)
    source = db.Column(db.String(100), nullable=True)
    detail = db.Column(db.Text, nullable=True)
    # Incremented on every detection cycle while resolved_at is NULL
    check_count = db.Column(db.Integer, nullable=False, default=1)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    resolved_at = db.Column(db.DateTime, nullable=True)

    __table_args__ = (
        db.Index('idx_rf_kind_open', 'kind', 'resolved_at'),
    )


# ── Supplier Settlement Adjustment (SAD) ──────────────────────────────────────

class SupplierSettlementPolicy(db.Model):
    """Effective-dated limits governing SupplierSettlementAdjustment.

    This is POLICY (data), not LAW (code): finance changes these numbers without
    a deploy.  Rows are effective-dated and treated as immutable once a SAD has
    referenced them — correcting a limit means closing the current row
    (effective_to) and inserting a new one, never editing history.

    Read LIVE at post() time (the limit in force at the moment of the accounting
    decision governs), then the resolved id is frozen onto the SAD for audit.
    See architecture-v1.md §13.
    """

    __tablename__ = 'supplier_settlement_policy'

    id = db.Column(db.Integer, primary_key=True)

    # Per-operation ceiling: a single SAD may not exceed these.
    tolerance_cash = db.Column(db.Float, nullable=False)
    tolerance_weight = db.Column(db.Float, nullable=False)

    # Cumulative ceiling per supplier per Gregorian calendar month.
    period_cap_cash = db.Column(db.Float, nullable=False)
    period_cap_weight = db.Column(db.Float, nullable=False)

    # Hard stop: a residual above this is never a settlement difference.
    review_threshold_cash = db.Column(db.Float, nullable=False)

    effective_from = db.Column(db.DateTime, nullable=False, index=True)
    effective_to = db.Column(db.DateTime, nullable=True, index=True)

    notes = db.Column(db.Text, nullable=True)
    created_by = db.Column(db.String(100), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=db.func.now())

    @classmethod
    def in_effect_at(cls, moment):
        """Return the single policy in force at `moment`, or None.

        Half-open interval [effective_from, effective_to) so that a row closed
        at T and its successor starting at T never both match.
        """
        return (
            cls.query
            .filter(cls.effective_from <= moment)
            .filter(db.or_(cls.effective_to.is_(None), cls.effective_to > moment))
            .order_by(cls.effective_from.desc(), cls.id.desc())
            .first()
        )

    def to_dict(self):
        return {
            'id': self.id,
            'tolerance_cash': self.tolerance_cash,
            'tolerance_weight': self.tolerance_weight,
            'period_cap_cash': self.period_cap_cash,
            'period_cap_weight': self.period_cap_weight,
            'review_threshold_cash': self.review_threshold_cash,
            'effective_from': self.effective_from.isoformat() if self.effective_from else None,
            'effective_to': self.effective_to.isoformat() if self.effective_to else None,
            'notes': self.notes,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }


class SupplierSettlementAdjustment(db.Model):
    """Closes a small justified residual on a supplier's GL-derived balance.

    This is NOT a "zero the supplier" button.  It writes no balance directly:
    the only accounting effect is produced by the canonical Voucher pipeline
    (Voucher → VoucherAccountLine → create_journal_entry_from_voucher), and
    JournalEntry/JournalEntryLine remains the sole source of accounting truth.

    Lifecycle: draft → approved → posted → reversed
               draft/approved → cancelled
    A posted adjustment is never edited or deleted; it is corrected by posting
    a reversing adjustment that carries reversal_of_id.
    """

    __tablename__ = 'supplier_settlement_adjustment'

    # Machine-checked settlement reasons.  PURCHASE_DISCOUNT is deliberately
    # absent: a real purchase discount affects inventory/cost/VAT and must go
    # through the purchase path, not through a settlement difference.
    REASON_ROUNDING_DIFFERENCE = 'ROUNDING_DIFFERENCE'
    REASON_FINAL_SETTLEMENT_DIFFERENCE = 'FINAL_SETTLEMENT_DIFFERENCE'
    REASON_WEIGHT_DIFFERENCE = 'WEIGHT_DIFFERENCE'
    REASON_DOCUMENTED_SUPPLIER_WAIVER = 'DOCUMENTED_SUPPLIER_WAIVER'
    REASON_OTHER = 'OTHER'

    VALID_REASON_CODES = frozenset({
        REASON_ROUNDING_DIFFERENCE,
        REASON_FINAL_SETTLEMENT_DIFFERENCE,
        REASON_WEIGHT_DIFFERENCE,
        REASON_DOCUMENTED_SUPPLIER_WAIVER,
        REASON_OTHER,
    })

    # OTHER is an escape hatch, so it costs more: a written note and a manager.
    REASONS_REQUIRING_MANAGER_APPROVAL = frozenset({REASON_OTHER})

    STATUS_DRAFT = 'draft'
    STATUS_APPROVED = 'approved'
    STATUS_POSTED = 'posted'
    STATUS_REVERSED = 'reversed'
    STATUS_CANCELLED = 'cancelled'

    # approved → draft is the kick-back path: post() found the supplier balance
    # moved since the snapshot, so the document returns to a recalculable state.
    _VALID_TRANSITIONS = {
        STATUS_DRAFT: {STATUS_APPROVED, STATUS_CANCELLED},
        STATUS_APPROVED: {STATUS_POSTED, STATUS_DRAFT, STATUS_CANCELLED},
        STATUS_POSTED: {STATUS_REVERSED},
        STATUS_REVERSED: set(),
        STATUS_CANCELLED: set(),
    }

    SNAPSHOT_SCHEMA_VERSION = 1

    id = db.Column(db.Integer, primary_key=True)
    adjustment_number = db.Column(db.String(50), unique=True, nullable=False, index=True)

    supplier_id = db.Column(
        db.Integer,
        db.ForeignKey('supplier.id', name='fk_ssa_supplier'),
        nullable=False,
        index=True,
    )
    supplier = db.relationship('Supplier', foreign_keys=[supplier_id])

    status = db.Column(db.String(20), nullable=False, default=STATUS_DRAFT, index=True)

    reason_code = db.Column(db.String(50), nullable=False)
    note = db.Column(db.Text, nullable=True)

    # ── Snapshot captured at draft creation / recalculation ───────────────────
    snapshot_schema_version = db.Column(db.Integer, nullable=False, default=SNAPSHOT_SCHEMA_VERSION)
    balance_before_financial = db.Column(db.Float, nullable=False, default=0.0)
    # JSON object keyed by karat: {"18": 0.0, "21": -0.003, "22": 0.0, "24": 0.0}
    balance_before_weight = db.Column(db.Text, nullable=True)
    snapshot_captured_at = db.Column(db.DateTime, nullable=True)

    # ── What was actually posted (set at post()) ──────────────────────────────
    posted_amount_cash = db.Column(db.Float, nullable=True)
    posted_amount_weight = db.Column(db.Text, nullable=True)  # same JSON shape

    # Policy in force at post() time, frozen here for audit.
    policy_id = db.Column(
        db.Integer,
        db.ForeignKey('supplier_settlement_policy.id', name='fk_ssa_policy'),
        nullable=True,
    )
    policy = db.relationship('SupplierSettlementPolicy', foreign_keys=[policy_id])

    # Gregorian calendar month key 'YYYY-MM' used for the cumulative cap.
    period_key = db.Column(db.String(7), nullable=True, index=True)

    # ── Accounting effect (populated only when posted) ────────────────────────
    # voucher_id is UNIQUE: the database itself refuses a second posting of the
    # same adjustment even if two transactions race past the row lock.
    voucher_id = db.Column(
        db.Integer,
        db.ForeignKey('voucher.id', name='fk_ssa_voucher'),
        nullable=True,
        unique=True,
    )
    voucher = db.relationship('Voucher', foreign_keys=[voucher_id])

    journal_entry_id = db.Column(
        db.Integer,
        db.ForeignKey('journal_entry.id', name='fk_ssa_journal_entry'),
        nullable=True,
    )
    journal_entry = db.relationship('JournalEntry', foreign_keys=[journal_entry_id])

    # ── Reversal chain ────────────────────────────────────────────────────────
    # UNIQUE: an adjustment can be reversed at most once.
    reversal_of_id = db.Column(
        db.Integer,
        db.ForeignKey('supplier_settlement_adjustment.id', name='fk_ssa_reversal_of'),
        nullable=True,
        unique=True,
    )
    reversal_of = db.relationship('SupplierSettlementAdjustment', remote_side=[id])

    # ── Audit trail ───────────────────────────────────────────────────────────
    created_by = db.Column(db.String(100), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=db.func.now())

    approved_by = db.Column(db.String(100), nullable=True)
    approved_at = db.Column(db.DateTime, nullable=True)
    approved_by_manager = db.Column(db.Boolean, nullable=False, default=False)

    posted_by = db.Column(db.String(100), nullable=True)
    posted_at = db.Column(db.DateTime, nullable=True)

    reversed_by = db.Column(db.String(100), nullable=True)
    reversed_at = db.Column(db.DateTime, nullable=True)
    reversal_reason = db.Column(db.Text, nullable=True)

    cancelled_by = db.Column(db.String(100), nullable=True)
    cancelled_at = db.Column(db.DateTime, nullable=True)
    cancellation_reason = db.Column(db.Text, nullable=True)

    __table_args__ = (
        db.Index('idx_ssa_supplier_status', 'supplier_id', 'status'),
        db.Index('idx_ssa_supplier_period', 'supplier_id', 'period_key'),
    )

    # ── State machine ─────────────────────────────────────────────────────────

    def _transition(self, new_status: str) -> None:
        current = self.status or self.STATUS_DRAFT
        allowed = self._VALID_TRANSITIONS.get(current, set())
        if new_status not in allowed:
            raise ValueError(
                f'انتقال غير مسموح: {current} → {new_status}. '
                f'المسموح من "{current}": {sorted(allowed) or "لا شيء (حالة نهائية)"}'
            )
        self.status = new_status

    @property
    def is_terminal(self) -> bool:
        return not self._VALID_TRANSITIONS.get(self.status or self.STATUS_DRAFT, set())

    # ── Weight JSON helpers ───────────────────────────────────────────────────

    @staticmethod
    def _load_weight(raw):
        if not raw:
            return {}
        try:
            parsed = json.loads(raw)
        except (TypeError, ValueError):
            return {}
        return {str(k): float(v) for k, v in (parsed or {}).items()}

    @staticmethod
    def _dump_weight(mapping):
        return json.dumps(
            {str(k): round(float(v), 6) for k, v in (mapping or {}).items()},
            ensure_ascii=False,
            sort_keys=True,
        )

    @property
    def balance_before_weight_by_karat(self) -> dict:
        return self._load_weight(self.balance_before_weight)

    @property
    def posted_amount_weight_by_karat(self) -> dict:
        return self._load_weight(self.posted_amount_weight)

    def to_dict(self):
        return {
            'id': self.id,
            'adjustment_number': self.adjustment_number,
            'supplier_id': self.supplier_id,
            'supplier_name': self.supplier.name if self.supplier else None,
            'status': self.status,
            'reason_code': self.reason_code,
            'note': self.note,
            'snapshot_schema_version': self.snapshot_schema_version,
            'balance_before_financial': self.balance_before_financial,
            'balance_before_weight': self.balance_before_weight_by_karat,
            'snapshot_captured_at': self.snapshot_captured_at.isoformat() if self.snapshot_captured_at else None,
            'posted_amount_cash': self.posted_amount_cash,
            'posted_amount_weight': self.posted_amount_weight_by_karat,
            'policy_id': self.policy_id,
            'period_key': self.period_key,
            'voucher_id': self.voucher_id,
            'journal_entry_id': self.journal_entry_id,
            'reversal_of_id': self.reversal_of_id,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'approved_by': self.approved_by,
            'approved_at': self.approved_at.isoformat() if self.approved_at else None,
            'approved_by_manager': self.approved_by_manager,
            'posted_by': self.posted_by,
            'posted_at': self.posted_at.isoformat() if self.posted_at else None,
            'reversed_by': self.reversed_by,
            'reversed_at': self.reversed_at.isoformat() if self.reversed_at else None,
            'reversal_reason': self.reversal_reason,
            'cancelled_by': self.cancelled_by,
            'cancelled_at': self.cancelled_at.isoformat() if self.cancelled_at else None,
            'cancellation_reason': self.cancellation_reason,
        }

    def __repr__(self):
        return f'<SupplierSettlementAdjustment {self.adjustment_number} - {self.status}>'


