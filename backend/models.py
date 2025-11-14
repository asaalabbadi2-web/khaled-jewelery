from config import MAIN_KARAT
# SQLAlchemy models for Customer, Item, Invoice, InvoiceItem
from datetime import datetime, date, time
from flask_sqlalchemy import SQLAlchemy
from werkzeug.security import check_password_hash, generate_password_hash

db = SQLAlchemy()


PAYMENT_METHOD_ALLOWED_INVOICE_TYPES = [
    'بيع',
    'شراء من عميل',
    'مرتجع بيع',
    'مرتجع شراء',
    'شراء من مورد',
    'مرتجع شراء من مورد',
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
    
    children = db.relationship('Account', backref=db.backref('parent', remote_side=[id]))

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
    
    # أيام التسوية
    settlement_days = db.Column(db.Integer, default=0)  # عدد أيام التسوية
    
    # هل وسيلة الدفع نشطة؟
    is_active = db.Column(db.Boolean, default=True)
    
    # ترتيب العرض
    display_order = db.Column(db.Integer, default=999)

    # أنواع الفواتير المسموح بها لهذه الوسيلة
    applicable_invoice_types = db.Column(db.JSON, nullable=True)
    
    # 🆕 الربط بالخزينة الافتراضية (الطريقة الوحيدة للربط بشجرة الحسابات)
    default_safe_box_id = db.Column(db.Integer, db.ForeignKey('safe_box.id'), nullable=True)
    default_safe_box = db.relationship('SafeBox', backref='payment_methods_using_as_default')
    
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
            'settlement_days': getattr(self, 'settlement_days', 0),
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


class Office(db.Model):
    """مكاتب بيع وشراء الذهب الخام (التسكير)"""
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
    
    # الأرصدة (لتسريع الاستعلامات)
    balance_cash = db.Column(db.Float, default=0.0)
    balance_gold_18k = db.Column(db.Float, default=0.0)
    balance_gold_21k = db.Column(db.Float, default=0.0)
    balance_gold_22k = db.Column(db.Float, default=0.0)
    balance_gold_24k = db.Column(db.Float, default=0.0)

    def to_dict(self):
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
            'balance_cash': self.balance_cash,
            'balance_gold_18k': self.balance_gold_18k,
            'balance_gold_21k': self.balance_gold_21k,
            'balance_gold_22k': self.balance_gold_22k,
            'balance_gold_24k': self.balance_gold_24k,
        }

    def __repr__(self):
        return f'<Office {self.name}>'


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

class Item(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    
    # كود الصنف الفريد (I-000001, I-000002, ...)
    item_code = db.Column(db.String(20), unique=True, nullable=False, index=True)
    
    name = db.Column(db.String(100), nullable=False)
    barcode = db.Column(db.String(100), unique=True, nullable=True, index=True)  # باركود فريد (اختياري - يُولّد تلقائياً إذا كان فارغاً)
    karat = db.Column(db.String(10))  # عيار
    weight = db.Column(db.Float)      # وزن
    def weight_in_main_karat(self):
        """
        تحويل الوزن إلى العيار الرئيسي
        """
        try:
            karat_value = float(self.karat)
            return self.weight * karat_value / MAIN_KARAT
        except Exception:
            return self.weight
    count = db.Column(db.Integer)     # عدد
    wage = db.Column(db.Float)        # أجرة المصنعية

    def wage_in_gold(self):
        """
        تحويل أجرة المصنعية إلى ما يعادلها بالذهب
        """
        try:
            return self.wage / MAIN_KARAT
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
    office_id = db.Column(db.Integer, db.ForeignKey('office.id'), nullable=True)  # 🆕 للتسكير من المكاتب
    date = db.Column(db.DateTime, nullable=False)
    total = db.Column(db.Float, nullable=False)
    
    # نوع الفاتورة - 6 أنواع
    # 'بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء من مورد', 'مرتجع شراء من مورد'
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
    
    # 🆕 حقول الربح بالذهب
    profit_cash = db.Column(db.Float, default=0.0)  # الربح النقدي (ر.س)
    profit_gold = db.Column(db.Float, default=0.0)  # الربح بالذهب (جم)
    
    # 🆕 ربط بوسيلة الدفع (Foreign Key)
    payment_method_id = db.Column(db.Integer, db.ForeignKey('payment_method.id'), nullable=True)
    payment_method_obj = db.relationship('PaymentMethod', backref='invoices')
    
    # 🆕 ربط بالخزينة (SafeBox)
    safe_box_id = db.Column(db.Integer, db.ForeignKey('safe_box.id'), nullable=True)
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

    # Fields for partial/deferred payments
    settled_gold_weight = db.Column(db.Float, nullable=True)
    settled_wage_amount = db.Column(db.Float, nullable=True)

    items = db.relationship('InvoiceItem', backref='invoice', lazy=True)
    
    # 🆕 علاقة مع دفعات متعددة (One-to-Many)
    payments = db.relationship('InvoicePayment', backref='invoice', lazy=True, cascade='all, delete-orphan')
    
    # 🆕 سطور العيارات لمشتريات الموردين
    karat_lines = db.relationship('InvoiceKaratLine', backref='invoice', lazy=True, cascade='all, delete-orphan')
    
    # العلاقة بالفاتورة الأصلية (للمرتجعات)
    original_invoice = db.relationship('Invoice', remote_side=[id], foreign_keys=[original_invoice_id], backref='returns', uselist=False)

    __table_args__ = (db.UniqueConstraint('invoice_type', 'invoice_type_id', name='_invoice_type_uc'),)

    def to_dict(self):
        result = {
            'id': self.id,
            'invoice_type_id': self.invoice_type_id,
            'customer_id': self.customer_id,
            'supplier_id': self.supplier_id,
            'office_id': self.office_id,  # 🆕 المكتب
            'date': self.date.isoformat(),
            'total': self.total,
            'invoice_type': self.invoice_type,
            'status': self.status,
            'is_posted': self.is_posted,  # 🆕 حالة الترحيل
            'posted_at': self.posted_at.isoformat() if self.posted_at else None,  # 🆕
            'posted_by': self.posted_by,  # 🆕
            'total_weight': self.total_weight,
            'total_tax': self.total_tax,
            'total_cost': self.total_cost,
            'gold_subtotal': self.gold_subtotal,
            'wage_subtotal': self.wage_subtotal,
            'gold_tax_total': self.gold_tax_total,
            'wage_tax_total': self.wage_tax_total,
            'apply_gold_tax': self.apply_gold_tax,
            'profit_cash': self.profit_cash,  # 🆕 الربح النقدي
            'profit_gold': self.profit_gold,  # 🆕 الربح بالذهب
            'payment_method': self.payment_method,  # للتوافق مع الفواتير القديمة
            'payment_method_id': self.payment_method_id,
            'commission_amount': self.commission_amount,
            'net_amount': self.net_amount,
            'amount_paid': self.amount_paid,
            'safe_box_id': self.safe_box_id,  # 🆕 الخزينة
            'original_invoice_id': self.original_invoice_id,
            'return_reason': self.return_reason,
            'gold_type': self.gold_type,
            'items': [item.to_dict() for item in self.items]
        }
        
        # 🆕 إضافة تفاصيل الخزينة
        if self.safe_box:
            result['safe_box_details'] = {
                'id': self.safe_box.id,
                'name': self.safe_box.name,
                'safe_type': self.safe_box.safe_type,
            }
        
        # 🆕 إضافة تفاصيل وسيلة الدفع القديمة (للتوافق)
        if self.payment_method_obj:
            result['payment_method_details'] = {
                'id': self.payment_method_obj.id,
                'name': self.payment_method_obj.name,
                'commission_rate': self.payment_method_obj.commission_rate,
                'account': {
                    'id': self.payment_method_obj.account.id,
                    'account_number': self.payment_method_obj.account.account_number,
                    'name': self.payment_method_obj.account.name
                } if self.payment_method_obj.account else None
            }
        
        # 🆕 إضافة دفعات متعددة (الميزة الجديدة)
        if self.payments:
            result['payments'] = [payment.to_dict() for payment in self.payments]
            # حساب إجماليات الدفعات
            result['total_payments_amount'] = sum(p.amount for p in self.payments)
            result['total_commission'] = sum(p.commission_amount for p in self.payments)
            result['total_net'] = sum(p.net_amount for p in self.payments)
        else:
            result['payments'] = []
        
        if self.karat_lines:
            result['karat_lines'] = [line.to_dict() for line in self.karat_lines]
        else:
            result['karat_lines'] = []
        
        return result

    def calculate_total_weight(self):
        """
        حساب إجمالي وزن الفاتورة بالعيار الرئيسي
        """
        base_weight = sum(ii.item.weight_in_main_karat() * ii.quantity for ii in self.items if ii.item)
        if self.karat_lines:
            base_weight += sum(line.weight_grams or 0 for line in self.karat_lines)
        return base_weight

    def total_wage_in_gold(self):
        """
        حساب إجمالي أجرة المصنعية بالذهب
        """
        return sum(ii.item.wage * ii.quantity / MAIN_KARAT for ii in self.items)

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
    name = db.Column(db.String(100))
    quantity = db.Column(db.Integer, nullable=False)
    price = db.Column(db.Float, nullable=False)
    karat = db.Column(db.Float)
    weight = db.Column(db.Float)
    wage = db.Column(db.Float)
    net = db.Column(db.Float)
    tax = db.Column(db.Float)

    def to_dict(self):
        return {
            'id': self.id,
            'invoice_id': self.invoice_id,
            'item_id': self.item_id,
            'name': self.name,
            'quantity': self.quantity,
            'price': self.price,
            'karat': self.karat,
            'weight': self.weight,
            'wage': self.wage,
            'net': self.net,
            'tax': self.tax
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

# Install Flask-SQLAlchemy
# RUN: pip install flask_sqlalchemy

# نموذج لتخزين سعر الذهب
class GoldPrice(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    price = db.Column(db.Float, nullable=False)
    date = db.Column(db.DateTime, default=db.func.now())

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

    def to_dict(self):
        return {
            'id': self.id,
            'journal_entry_id': self.journal_entry_id,
            'account_id': self.account_id,
            'account_name': self.account.name if self.account else '',
            'customer_id': self.customer_id,
            'customer_name': self.customer.name if self.customer else None,
            'customer_code': self.customer.customer_code if self.customer else None,
            'supplier_id': self.supplier_id,
            'supplier_name': self.supplier.name if self.supplier else None,
            'supplier_code': self.supplier.supplier_code if self.supplier else None,
            'cash_debit': self.cash_debit,
            'cash_credit': self.cash_credit,
            'debit_18k': self.debit_18k,
            'credit_18k': self.credit_18k,
            'debit_21k': self.debit_21k,
            'credit_21k': self.credit_21k,
            'debit_22k': self.debit_22k,
            'credit_22k': self.credit_22k,
            'debit_24k': self.debit_24k,
            'credit_24k': self.credit_24k,
        }

class Settings(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    
    # إعدادات أساسية
    main_karat = db.Column(db.Integer, default=21)
    currency_symbol = db.Column(db.String(10), default='ر.س')
    manufacturing_wage_mode = db.Column(db.String(20), default='expense')  # expense | inventory
    
    # إعدادات الضريبة
    tax_rate = db.Column(db.Float, default=0.15)  # 15%
    tax_enabled = db.Column(db.Boolean, default=True)
    
    # وسائل الدفع (JSON)
    # مثال: [{"name": "نقداً", "commission": 0}, {"name": "بطاقة", "commission": 2.5}]
    payment_methods = db.Column(db.Text, default='[{"name":"نقداً","commission":0},{"name":"بطاقة","commission":2.5},{"name":"تحويل","commission":1.5},{"name":"آجل","commission":0}]')
    
    # إعدادات الفواتير
    invoice_prefix = db.Column(db.String(10), default='INV')
    show_company_logo = db.Column(db.Boolean, default=True)
    company_name = db.Column(db.String(100), default='محل ياسر للذهب والمجوهرات')
    company_address = db.Column(db.Text)
    company_phone = db.Column(db.String(50))
    company_tax_number = db.Column(db.String(50))
    
    # إعدادات التنسيق
    decimal_places = db.Column(db.Integer, default=2)
    date_format = db.Column(db.String(20), default='DD/MM/YYYY')
    
    # إعدادات الخصم
    default_discount_rate = db.Column(db.Float, default=0.0)  # نسبة خصم افتراضية
    allow_discount = db.Column(db.Boolean, default=True)
    
    # 🆕 إعدادات السندات
    voucher_auto_post = db.Column(db.Boolean, default=False)  # False = يتطلب اعتماد قبل الترحيل، True = ترحيل تلقائي
    
    created_at = db.Column(db.DateTime, default=db.func.now())
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now())

    def to_dict(self):
        import json
        return {
            'id': self.id,
            'main_karat': self.main_karat,
            'currency_symbol': self.currency_symbol,
            'tax_rate': self.tax_rate,
            'tax_enabled': self.tax_enabled,
            'payment_methods': json.loads(self.payment_methods) if self.payment_methods else [],
            'invoice_prefix': self.invoice_prefix,
            'show_company_logo': self.show_company_logo,
            'company_name': self.company_name,
            'company_address': self.company_address,
            'company_phone': self.company_phone,
            'company_tax_number': self.company_tax_number,
            'decimal_places': self.decimal_places,
            'date_format': self.date_format,
            'default_discount_rate': self.default_discount_rate,
            'allow_discount': self.allow_discount,
            'manufacturing_wage_mode': (self.manufacturing_wage_mode or 'expense'),
            'voucher_auto_post': self.voucher_auto_post  # إعداد سير عمل السندات
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
    
    # رقم المرجع (للعرض)
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

    def to_dict(self):
        """تحويل السند إلى dictionary"""
        # جمع معلومات الذهب من سطور الحسابات
        gold_lines = [line for line in self.account_lines.all() if line.amount_type == 'gold']
        
        # إذا كان هناك سطر ذهب واحد فقط، نعرض عياره
        # إذا كان هناك عدة أعيرة، نعرض "متعدد"
        display_karat = None
        if len(gold_lines) == 1:
            display_karat = gold_lines[0].karat
        elif len(gold_lines) > 1:
            # فحص إذا كانت جميع السطور بنفس العيار
            karats = set(line.karat for line in gold_lines if line.karat is not None)
            if len(karats) == 1:
                display_karat = karats.pop()
            else:
                display_karat = 'متعدد'  # أعيرة مختلفة
        
        result = {
            'id': self.id,
            'voucher_number': self.voucher_number,
            'voucher_type': self.voucher_type,
            'date': self.date.isoformat() if self.date else None,
            'party_type': self.party_type,
            'customer_id': self.customer_id,
            'supplier_id': self.supplier_id,
            'party_name': self.party_name,
            'amount_cash': self.amount_cash,
            'amount_gold': self.amount_gold,
            'gold_karat': display_karat,  # العيار المحسوب من السطور
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
    
    # ربط بوسيلة الدفع
    payment_method_id = db.Column(db.Integer, db.ForeignKey('payment_method.id'), nullable=False)
    payment_method = db.relationship('PaymentMethod', backref='invoice_payments')
    
    # المبلغ المدفوع بهذه الوسيلة
    amount = db.Column(db.Float, nullable=False)
    
    # نسخة من العمولة وقت الدفع (للحفظ التاريخي)
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
    is_active = db.Column(db.Boolean, default=True, index=True, nullable=False)
    notes = db.Column(db.Text, nullable=True)

    created_by = db.Column(db.String(100), nullable=True)
    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now(), nullable=False)

    account = db.relationship('Account', backref=db.backref('employees', lazy='dynamic'))

    def to_dict(self, include_details: bool = False):
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
            'is_active': self.is_active,
            'notes': self.notes,
            'created_by': self.created_by,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }

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
    password_hash = db.Column(db.String(255), nullable=False)
    employee_id = db.Column(db.Integer, db.ForeignKey('employee.id'), nullable=True)
    role = db.Column(db.String(50), nullable=False, default='staff')
    permissions = db.Column(db.JSON, nullable=True)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    last_login_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, default=db.func.now(), nullable=False)
    updated_at = db.Column(db.DateTime, default=db.func.now(), onupdate=db.func.now(), nullable=False)

    employee = db.relationship('Employee', backref=db.backref('user_account', uselist=False))

    def set_password(self, password: str):
        # استخدام خوارزمية مدعومة عبر OpenSSL لضمان التوافق عبر البيئات
        self.password_hash = generate_password_hash(password, method='pbkdf2:sha256')

    def check_password(self, password: str) -> bool:
        if not self.password_hash:
            return False
        return check_password_hash(self.password_hash, password)

    def to_dict(self, include_employee: bool = False):
        data = {
            'id': self.id,
            'username': self.username,
            'full_name': self.full_name,
            'employee_id': self.employee_id,
            'role': self.role,
            'permissions': self.permissions,
            'is_active': self.is_active,
            'last_login_at': self.last_login_at.isoformat() if self.last_login_at else None,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }

        if include_employee and self.employee:
            data['employee'] = self.employee.to_dict()

        return data

    def __repr__(self):
        return f'<AppUser {self.username}>'


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
    # 'بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء من مورد', 'مرتجع شراء من مورد'
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
    safe_type = db.Column(db.String(20), nullable=False)  # نوع الخزينة: cash, bank, gold, check
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
    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False)
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
        """الحصول على خزينة الذهب حسب العيار"""
        return SafeBox.query.filter_by(safe_type='gold', karat=karat, is_active=True).first()


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
    timestamp = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    
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
                timestamp=datetime.utcnow()
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
    db.Column('assigned_at', db.DateTime, default=datetime.utcnow),
    db.Column('assigned_by', db.String(100))
)

# جدول ربط الأدوار بالصلاحيات (Many-to-Many)
role_permissions = db.Table('role_permissions',
    db.Column('role_id', db.Integer, db.ForeignKey('roles.id', ondelete='CASCADE'), primary_key=True),
    db.Column('permission_id', db.Integer, db.ForeignKey('permissions.id', ondelete='CASCADE'), primary_key=True),
    db.Column('granted_at', db.DateTime, default=datetime.utcnow),
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
    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    last_login = db.Column(db.DateTime)
    password_changed_at = db.Column(db.DateTime)
    
    # إدارة المستخدم
    created_by = db.Column(db.String(100))
    
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
        self.password_changed_at = datetime.utcnow()
    
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
            'created_by': self.created_by
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
    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
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
    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    
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






