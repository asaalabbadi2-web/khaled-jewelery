from flask import Blueprint, request, jsonify
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker, joinedload
from sqlalchemy import func, or_, case
from gold_price import fetch_gold_price, save_gold_price
from models import (
    GoldPrice,
    db,
    Customer,
    Item,
    Invoice,
    InvoiceItem,
    InvoiceKaratLine,
    Account,
    JournalEntry,
    JournalEntryLine,
    Settings,
    Supplier,
    VoucherAccountLine,
    Voucher,
    PaymentMethod,
    InvoicePayment,
    AccountingMapping,
    Employee,
    Payroll,
    Attendance,
    SafeBox,
    Office,
    User,
)
from utils import normalize_number
from dual_system_helpers import create_dual_journal_entry, verify_dual_balance, get_account_balances
from datetime import datetime, date, time, timedelta
from collections import defaultdict
from statistics import pstdev

print("DEBUG: routes.py loaded")  # Debug log

api = Blueprint('api', __name__)

print("DEBUG: routes.py loaded")


def _parse_iso_date(value, field_name: str):
    if value in (None, ''):
        return None
    if isinstance(value, date):
        return value
    if isinstance(value, datetime):
        return value.date()
    try:
        return date.fromisoformat(str(value))
    except ValueError:
        raise ValueError(f'Invalid {field_name} format. Expected YYYY-MM-DD')


def _parse_iso_time(value, field_name: str):
    if value in (None, ''):
        return None
    if isinstance(value, time):
        return value
    if isinstance(value, datetime):
        return value.time()
    try:
        return time.fromisoformat(str(value))
    except ValueError:
        raise ValueError(f'Invalid {field_name} format. Expected HH:MM or HH:MM:SS')


def _generate_employee_code():
    prefix = f"EMP-{datetime.now().year}"
    latest_employee = (
        Employee.query.filter(Employee.employee_code.like(f"{prefix}%"))
        .order_by(Employee.employee_code.desc())
        .first()
    )

    if not latest_employee:
        return f"{prefix}-0001"

    try:
        last_sequence = int(str(latest_employee.employee_code).split('-')[-1])
    except (ValueError, AttributeError):
        last_sequence = latest_employee.id or 0

    return f"{prefix}-{last_sequence + 1:04d}"

@api.route('/settings', methods=['GET'])
def get_settings():
    settings = Settings.query.first()
    if not settings:
        # If no settings exist, create one with default value
        settings = Settings(main_karat=21)
        db.session.add(settings)
        db.session.commit()
    return jsonify(settings.to_dict())

@api.route('/settings', methods=['PUT'])
def update_settings():
    import json
    settings = Settings.query.first()
    if not settings:
        settings = Settings()
        db.session.add(settings)
    
    data = request.get_json()
    
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
    
    # وسائل الدفع
    if 'payment_methods' in data:
        settings.payment_methods = json.dumps(data['payment_methods'], ensure_ascii=False)
    
    # إعدادات الفواتير
    if 'invoice_prefix' in data:
        settings.invoice_prefix = data['invoice_prefix']
    if 'show_company_logo' in data:
        settings.show_company_logo = data['show_company_logo']
    if 'company_name' in data:
        settings.company_name = data['company_name']
    if 'company_address' in data:
        settings.company_address = data['company_address']
    if 'company_phone' in data:
        settings.company_phone = data['company_phone']
    if 'company_tax_number' in data:
        settings.company_tax_number = data['company_tax_number']
    
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
    
    db.session.commit()
    return jsonify(settings.to_dict())

@api.route('/system/reset', methods=['POST'])
def system_reset():
    """
    إعادة تهيئة النظام مع خيارات متعددة
    
    Body Parameters (JSON):
    - reset_type: نوع الإعادة (required)
        * "transactions" - حذف العمليات فقط (القيود، الفواتير، السندات)
        * "customers_suppliers" - حذف بيانات العملاء والموردين فقط
        * "settings" - إعادة تعيين الإعدادات للقيم الافتراضية
        * "all" - حذف كل شيء وإعادة تهيئة كاملة
    
    Returns:
    - success: رسالة نجاح
    - error: رسالة خطأ
    """
    try:
        data = request.get_json() or {}
        reset_type = data.get('reset_type', 'all')
        
        if reset_type == 'transactions':
            # حذف العمليات فقط (القيود، الفواتير، السندات، المدفوعات)
            _reset_transactions()
            message = 'تم حذف جميع العمليات بنجاح (القيود، الفواتير، السندات)'
            
        elif reset_type == 'customers_suppliers':
            # حذف العملاء والموردين
            _reset_customers_suppliers()
            message = 'تم حذف جميع بيانات العملاء والموردين بنجاح'
            
        elif reset_type == 'settings':
            # إعادة تعيين الإعدادات
            _reset_settings()
            message = 'تم إعادة تعيين الإعدادات للقيم الافتراضية'
            
        elif reset_type == 'all':
            # حذف كل شيء
            from backend.app import reset_database
            reset_database()
            message = 'تم إعادة تهيئة النظام بالكامل بنجاح. تحتاج الآن إلى إعادة تحميل شجرة الحسابات.'
            
        else:
            return jsonify({
                'status': 'error', 
                'message': f'نوع إعادة التهيئة غير صحيح: {reset_type}. الخيارات المتاحة: transactions, customers_suppliers, settings, all'
            }), 400
        
        return jsonify({
            'status': 'success', 
            'message': message,
            'reset_type': reset_type
        }), 200
        
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500


def _reset_transactions():
    """حذف جميع العمليات (القيود، الفواتير، السندات) مع إعادة ضبط الأرصدة"""
    try:
        # حذف السجلات المرتبطة بالموظفين أولاً لتفادي تعارض العلاقات
        Attendance.query.delete()
        Payroll.query.delete()

        # حذف القيود المحاسبية وسطورها
        JournalEntryLine.query.delete()
        JournalEntry.query.delete()

        # حذف الفواتير وعناصرها ومدفوعاتها
        InvoicePayment.query.delete()
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

        db.session.query(Supplier).update({
            Supplier.balance_cash: 0.0,
            Supplier.balance_gold_18k: 0.0,
            Supplier.balance_gold_21k: 0.0,
            Supplier.balance_gold_22k: 0.0,
            Supplier.balance_gold_24k: 0.0,
        }, synchronize_session=False)

        db.session.commit()

    except Exception as e:
        db.session.rollback()
        raise e


def _reset_customers_suppliers():
    """حذف العملاء والموردين"""
    try:
        # حذف العملاء
        Customer.query.delete()
        
        # حذف الموردين
        Supplier.query.delete()
        
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
            company_name='محل الياسر للذهب والمجوهرات',
            company_address='',
            company_phone='',
            company_tax_number=''
        )
        
        db.session.add(default_settings)
        db.session.commit()
        
    except Exception as e:
        db.session.rollback()
        raise e


@api.route('/system/reset/info', methods=['GET'])
def get_reset_info():
    """
    الحصول على معلومات عن البيانات الحالية في النظام
    
    Returns:
    - counts: عدد السجلات في كل جدول
    """
    try:
        info = {
            'transactions': {
                'journal_entries': JournalEntry.query.count(),
                'journal_entry_lines': JournalEntryLine.query.count(),
                'invoices': Invoice.query.count(),
                'invoice_items': InvoiceItem.query.count(),
                'invoice_payments': InvoicePayment.query.count(),
                'vouchers': Voucher.query.count(),
                'voucher_lines': VoucherAccountLine.query.count(),
                'payroll_entries': Payroll.query.count(),
                'attendance_records': Attendance.query.count(),
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
                'app_users': User.query.count(),
                'accounting_mappings': AccountingMapping.query.count(),
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


@api.route('/accounts/<int:account_id>/statement', methods=['GET'])
def get_account_statement(account_id):
    account = Account.query.get_or_404(account_id)
    account = Account.query.get_or_404(account_id)
    main_karat = get_main_karat()

    # Sum up all opening balances for the account
    opening_balances = db.session.query(
        func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit).label('balance_cash'),
        func.sum(JournalEntryLine.debit_18k - JournalEntryLine.credit_18k).label('balance_18k'),
        func.sum(JournalEntryLine.debit_21k - JournalEntryLine.credit_21k).label('balance_21k'),
        func.sum(JournalEntryLine.debit_22k - JournalEntryLine.credit_22k).label('balance_22k'),
        func.sum(JournalEntryLine.debit_24k - JournalEntryLine.credit_24k).label('balance_24k')
    ).filter(JournalEntryLine.account_id == account_id).first()

    # Initialize running balances for each karat
    running_balance_cash = opening_balances.balance_cash or 0
    running_balances_gold = {
        '18k': opening_balances.balance_18k or 0,
        '21k': opening_balances.balance_21k or 0,
        '22k': opening_balances.balance_22k or 0,
        '24k': opening_balances.balance_24k or 0,
    }

    lines = JournalEntryLine.query.join(JournalEntry) \
        .filter(JournalEntryLine.account_id == account_id) \
        .order_by(JournalEntry.date.asc(), JournalEntry.id.asc()) \
        .all()

    statement_lines = []
    total_cash_debit = 0
    total_cash_credit = 0
    total_gold_debit_normalized = 0
    total_gold_credit_normalized = 0

    for line in lines:
        # Update running balances for each karat
        running_balances_gold['18k'] += (line.debit_18k or 0) - (line.credit_18k or 0)
        running_balances_gold['21k'] += (line.debit_21k or 0) - (line.credit_21k or 0)
        running_balances_gold['22k'] += (line.debit_22k or 0) - (line.credit_22k or 0)
        running_balances_gold['24k'] += (line.debit_24k or 0) - (line.credit_24k or 0)
        running_balance_cash += (line.cash_debit or 0) - (line.cash_credit or 0)

        # Normalize gold for the line item display
        gold_debit_normalized = (
            convert_to_main_karat(line.debit_18k or 0, 18) +
            convert_to_main_karat(line.debit_21k or 0, 21) +
            convert_to_main_karat(line.debit_22k or 0, 22) +
            convert_to_main_karat(line.debit_24k or 0, 24)
        )
        gold_credit_normalized = (
            convert_to_main_karat(line.credit_18k or 0, 18) +
            convert_to_main_karat(line.credit_21k or 0, 21) +
            convert_to_main_karat(line.credit_22k or 0, 22) +
            convert_to_main_karat(line.credit_24k or 0, 24)
        )

        statement_lines.append({
            'id': line.id,
            'date': line.journal_entry.date.isoformat(),
            'description': line.journal_entry.description,
            'journal_entry_id': line.journal_entry_id,
            'cash_debit': line.cash_debit or 0,
            'cash_credit': line.cash_credit or 0,
            'gold_debit': gold_debit_normalized,
            'gold_credit': gold_credit_normalized,
            'debit_18k': line.debit_18k or 0,
            'credit_18k': line.credit_18k or 0,
            'debit_21k': line.debit_21k or 0,
            'credit_21k': line.credit_21k or 0,
            'debit_22k': line.debit_22k or 0,
            'credit_22k': line.credit_22k or 0,
            'debit_24k': line.debit_24k or 0,
            'credit_24k': line.credit_24k or 0,
        })
        
        total_cash_debit += line.cash_debit or 0
        total_cash_credit += line.cash_credit or 0
        total_gold_debit_normalized += gold_debit_normalized
        total_gold_credit_normalized += gold_credit_normalized

    # Final closing balances
    closing_balance_gold_normalized = (
        convert_to_main_karat(running_balances_gold['18k'], 18) +
        convert_to_main_karat(running_balances_gold['21k'], 21) +
        convert_to_main_karat(running_balances_gold['22k'], 22) +
        convert_to_main_karat(running_balances_gold['24k'], 24)
    )

    return jsonify({
        'account_name': account.name,
        'main_karat': main_karat,
        'opening_balance_cash': 0, # Statements start from zero
        'opening_balance_gold_normalized': 0,
        'lines': statement_lines,
        'totals': {
            'cash_debit': total_cash_debit,
            'cash_credit': total_cash_credit,
            'gold_debit_normalized': total_gold_debit_normalized,
            'gold_credit_normalized': total_gold_credit_normalized,
        },
        'closing_balance_cash': running_balance_cash,
        'closing_balance_gold_normalized': closing_balance_gold_normalized,
        'closing_balance_gold_details': running_balances_gold,
    })

# Customers CRUD
@api.route('/customers/<int:id>', methods=['DELETE'])
def delete_customer(id):
    customer = Customer.query.get_or_404(id)
    try:
        # Check if customer has invoices
        has_invoices = Invoice.query.filter_by(customer_id=id).first()
        if has_invoices:
            return jsonify({'error': 'لا يمكن حذف عميل نشط'}), 400
        
        # Check if customer has journal entries
        has_journal_entries = JournalEntryLine.query.filter_by(customer_id=id).first()
        if has_journal_entries:
            return jsonify({'error': 'لا يمكن حذف عميل لديه قيود يومية'}), 400
        
        db.session.delete(customer)
        db.session.commit()
        return jsonify({'result': 'success'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to delete customer: {str(e)}'}), 500

@api.route('/customers/<int:id>/statement', methods=['GET'])
def get_customer_statement(id):
    """
    كشف حساب العميل - عرض جميع القيود اليومية المتعلقة بالعميل
    """
    customer = Customer.query.get_or_404(id)
    
    # Get all journal entry lines linked to this customer
    lines = JournalEntryLine.query.filter_by(customer_id=id).join(
        JournalEntry
    ).order_by(JournalEntry.date.desc(), JournalEntry.id.desc()).all()
    
    # Format the statement
    statement_lines = []
    for line in lines:
        entry = line.journal_entry
        statement_lines.append({
            'id': line.id,
            'date': entry.date.isoformat(),
            'entry_number': entry.entry_number,
            'description': entry.description,
            'account_number': line.account.account_number if line.account else None,
            'account_name': line.account.name if line.account else None,
            'debit_cash': float(line.debit_cash) if line.debit_cash else 0.0,
            'credit_cash': float(line.credit_cash) if line.credit_cash else 0.0,
            'debit_gold_18k': float(line.debit_gold_18k) if line.debit_gold_18k else 0.0,
            'credit_gold_18k': float(line.credit_gold_18k) if line.credit_gold_18k else 0.0,
            'debit_gold_21k': float(line.debit_gold_21k) if line.debit_gold_21k else 0.0,
            'credit_gold_21k': float(line.credit_gold_21k) if line.credit_gold_21k else 0.0,
            'debit_gold_22k': float(line.debit_gold_22k) if line.debit_gold_22k else 0.0,
            'credit_gold_22k': float(line.credit_gold_22k) if line.credit_gold_22k else 0.0,
            'debit_gold_24k': float(line.debit_gold_24k) if line.debit_gold_24k else 0.0,
            'credit_gold_24k': float(line.credit_gold_24k) if line.credit_gold_24k else 0.0,
        })
    
    return jsonify({
        'customer': customer.to_dict(),
        'statement': statement_lines
    })

@api.route('/customers/next-code', methods=['GET'])
def get_next_customer_code():
    """
    الحصول على الكود التالي المتاح للعميل
    """
    from backend.code_generator import generate_customer_code, get_customer_statistics
    
    stats = get_customer_statistics()
    return jsonify({
        'next_code': generate_customer_code(),
        'total_customers': stats['total_customers'],
        'remaining_capacity': stats['remaining_capacity']
    })

@api.route('/suppliers/next-code', methods=['GET'])
def get_next_supplier_code():
    """
    الحصول على الكود التالي المتاح للمورد
    """
    from backend.code_generator import generate_supplier_code, get_supplier_statistics
    
    stats = get_supplier_statistics()
    return jsonify({
        'next_code': generate_supplier_code(),
        'total_suppliers': stats['total_suppliers'],
        'remaining_capacity': stats['remaining_capacity']
    })

@api.route('/customers', methods=['GET'])
def get_customers():
    customers = Customer.query.all()
    results = []
    for c in customers:
        account = Account.query.filter_by(name=c.name).first()
        results.append({
            'id': c.id, 
            'name': c.name, 
            'phone': c.phone, 
            'email': c.email,
            'id_number': c.id_number, 
            'birth_date': c.birth_date.isoformat() if c.birth_date else None,
            'id_version_number': c.id_version_number,
            'account_id': account.id if account else None
        })
    return jsonify(results)

@api.route('/customers', methods=['POST'])
def add_customer():
    """
    إضافة عميل جديد (النظام الهجين)
    يتم توليد customer_code تلقائياً
    """
    from code_generator import generate_customer_code
    
    data = request.json
    
    # Basic validation
    if not data or 'name' not in data:
        return jsonify({'error': 'الاسم مطلوب'}), 400

    birth_date_str = data.get('birth_date')
    birth_date = None
    if birth_date_str:
        try:
            birth_date = datetime.strptime(birth_date_str, '%Y-%m-%d').date()
        except (ValueError, TypeError):
            pass

    try:
        # 1. توليد كود العميل تلقائياً
        customer_code = data.get('customer_code')
        if not customer_code:
            customer_code = generate_customer_code()
        
        # 2. تحديد الحساب التجميعي (افتراضي: عملاء بيع ذهب - 1100)
        account_category_number = data.get('account_category_number', '1100')
        account_category = Account.query.filter_by(account_number=account_category_number).first()
        
        if not account_category:
            # fallback: ابحث عن أي حساب عملاء
            account_category = Account.query.filter_by(account_number='110').first()
        
        # 3. إنشاء العميل
        customer = Customer(
            customer_code=customer_code,
            name=data.get('name'),
            phone=data.get('phone'),
            email=data.get('email'),
            address_line_1=data.get('address_line_1'),
            address_line_2=data.get('address_line_2'),
            city=data.get('city'),
            state=data.get('state'),
            postal_code=data.get('postal_code'),
            country=data.get('country'),
            id_number=data.get('id_number'),
            birth_date=birth_date,
            id_version_number=data.get('id_version_number'),
            notes=data.get('notes'),
            active=data.get('active', True),
            account_category_id=account_category.id if account_category else None,
            balance_cash=0.0,
            balance_gold_18k=0.0,
            balance_gold_21k=0.0,
            balance_gold_22k=0.0,
            balance_gold_24k=0.0
        )
        db.session.add(customer)
        db.session.commit()

        return jsonify(customer.to_dict()), 201

    except IntegrityError as e:
        db.session.rollback()
        if 'customer_code' in str(e):
            return jsonify({'error': f'كود العميل {customer_code} مستخدم بالفعل'}), 409
        return jsonify({'error': 'عميل بنفس البيانات موجود بالفعل'}), 409
    except Exception as e:
        db.session.rollback()
        # Log the full error for debugging
        print(f"ERROR in add_customer: {str(e)}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'An unexpected error occurred: {str(e)}'}), 500

# Suppliers CRUD
@api.route('/suppliers', methods=['GET'])
def get_suppliers():
    suppliers = Supplier.query.all()
    return jsonify([s.to_dict() for s in suppliers])


@api.route('/suppliers', methods=['POST'])
def add_supplier():
    """
    إضافة مورد جديد (النظام الهجين)
    يتم توليد supplier_code تلقائياً
    """
    from code_generator import generate_supplier_code, validate_supplier_code
    
    data = request.get_json()
    
    # Check for required fields
    if not data or 'name' not in data:
        return jsonify({'error': 'الاسم مطلوب'}), 400

    try:
        # 1. توليد كود المورد تلقائياً
        supplier_code = data.get('supplier_code')
        if not supplier_code:
            supplier_code = generate_supplier_code()
        else:
            # إذا تم توفير كود، تحقق من صحته
            validation = validate_supplier_code(supplier_code)
            if not validation['is_valid']:
                return jsonify({'error': validation['message']}), 400
        
        # 2. تحديد الحساب التجميعي (افتراضي: الموردين - 211)
        account_category_number = data.get('account_category_number', '211')
        account_category = Account.query.filter_by(account_number=account_category_number).first()
        
        if not account_category:
            # fallback: ابحث عن أي حساب موردين
            account_category = Account.query.filter_by(account_number='21').first()
        
        # 3. إنشاء المورد
        new_supplier = Supplier(
            supplier_code=supplier_code,
            name=data['name'],
            phone=data.get('phone'),
            email=data.get('email'),
            address_line_1=data.get('address_line_1'),
            address_line_2=data.get('address_line_2'),
            city=data.get('city'),
            state=data.get('state'),
            postal_code=data.get('postal_code'),
            country=data.get('country'),
            account_category_id=account_category.id if account_category else None,
            balance_cash=0.0,
            balance_gold_18k=0.0,
            balance_gold_21k=0.0,
            balance_gold_22k=0.0,
            balance_gold_24k=0.0
        )
        db.session.add(new_supplier)
        db.session.commit()

        return jsonify(new_supplier.to_dict()), 201
        
    except IntegrityError as e:
        db.session.rollback()
        if 'supplier_code' in str(e):
            return jsonify({'error': f'كود المورد {supplier_code} مستخدم بالفعل'}), 409
        return jsonify({'error': 'مورد بنفس البيانات موجود بالفعل'}), 409
    except Exception as e:
        db.session.rollback()
        print(f"Error adding supplier: {e}")
        return jsonify({'error': 'حدث خطأ داخلي'}), 500

@api.route('/suppliers/<int:id>', methods=['PUT'])
def update_supplier(id):
    """
    تحديث بيانات المورد (النظام الهجين)
    لا يتم تحديث supplier_code بعد الإنشاء
    """
    supplier = Supplier.query.get_or_404(id)
    data = request.json

    # Update supplier details (but not supplier_code)
    supplier.name = data.get('name', supplier.name)
    supplier.phone = data.get('phone', supplier.phone)
    supplier.email = data.get('email', supplier.email)
    supplier.address_line_1 = data.get('address_line_1', supplier.address_line_1)
    supplier.address_line_2 = data.get('address_line_2', supplier.address_line_2)
    supplier.city = data.get('city', supplier.city)
    supplier.state = data.get('state', supplier.state)
    supplier.postal_code = data.get('postal_code', supplier.postal_code)
    supplier.country = data.get('country', supplier.country)

    # Allow updating account_category if needed
    if 'account_category_number' in data:
        account_category = Account.query.filter_by(account_number=data['account_category_number']).first()
        if account_category:
            supplier.account_category_id = account_category.id

    try:
        db.session.commit()
        return jsonify(supplier.to_dict())
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update supplier: {str(e)}'}), 500

@api.route('/suppliers/<int:id>', methods=['DELETE'])
def delete_supplier(id):
    supplier = Supplier.query.get_or_404(id)
    try:
        if supplier.account_id:
            account = Account.query.get(supplier.account_id)
            if account:
                # Optional: Check if account has transactions before deleting
                has_transactions = JournalEntryLine.query.filter_by(account_id=account.id).first()
                if has_transactions:
                    return jsonify({'error': 'Cannot delete supplier with existing transactions.'}), 400
                db.session.delete(account)
        
        db.session.delete(supplier)
        db.session.commit()
        return jsonify({'result': 'success'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to delete supplier: {str(e)}'}), 500

# Items CRUD
@api.route('/items/<int:id>', methods=['PUT'])
def update_item(id):
    """
    تحديث صنف موجود
    
    لا يتم تحديث item_code بعد الإنشاء
    إذا تم تحديث barcode إلى فارغ، يُولّد تلقائياً من item_code
    """
    from code_generator import generate_barcode_from_item_code
    
    item = Item.query.get_or_404(id)
    data = request.json
    
    # Update item details (but not item_code)
    item.name = data.get('name', item.name)
    
    # إذا تم حذف barcode، أعد توليده
    new_barcode = data.get('barcode', item.barcode)
    if not new_barcode:
        new_barcode = generate_barcode_from_item_code(item.item_code)
    item.barcode = new_barcode
    
    item.karat = normalize_number(str(data.get('karat', item.karat)))
    item.weight = normalize_number(str(data.get('weight', item.weight)))
    item.count = normalize_number(str(data.get('count', item.count)))
    item.wage = normalize_number(str(data.get('wage', item.wage)))
    item.manufacturing_wage_per_gram = normalize_number(str(data.get('manufacturing_wage_per_gram', item.manufacturing_wage_per_gram)))
    item.description = data.get('description', item.description)
    item.price = normalize_number(str(data.get('price', item.price)))
    item.stock = normalize_number(str(data.get('stock', item.stock)))
    
    db.session.commit()
    return jsonify({
        'result': 'success',
        'item_code': item.item_code,
        'barcode': item.barcode
    })

@api.route('/items/<int:id>', methods=['DELETE'])
def delete_item(id):
    item = Item.query.get_or_404(id)
    db.session.delete(item)
    db.session.commit()
    return jsonify({'result': 'success'})
@api.route('/items', methods=['GET'])
def get_items():
    items = Item.query.all()
    return jsonify([
        {
            'id': i.id,
            'item_code': i.item_code,
            'name': i.name,
            'barcode': i.barcode,
            'karat': i.karat,
            'weight': i.weight,
            'count': i.count,
            'wage': i.wage,
            'manufacturing_wage_per_gram': i.manufacturing_wage_per_gram,
            'description': i.description,
            'price': i.price,
            'stock': i.stock
        } for i in items
    ])

@api.route('/items/search/barcode/<barcode>', methods=['GET'])
def search_item_by_barcode(barcode):
    """
    البحث عن صنف بالباركود
    يُستخدم عند مسح الباركود لإضافة الصنف تلقائياً للفاتورة
    """
    item = Item.query.filter_by(barcode=barcode).first()
    if not item:
        return jsonify({'error': 'الصنف غير موجود'}), 404
    
    return jsonify({
        'id': item.id,
        'item_code': item.item_code,
        'name': item.name,
        'barcode': item.barcode,
        'karat': item.karat,
        'weight': item.weight,
        'count': item.count,
        'wage': item.wage,
        'manufacturing_wage_per_gram': item.manufacturing_wage_per_gram or 0.0,
        'description': item.description,
        'price': item.price,
        'stock': item.stock
    })

@api.route('/items', methods=['POST'])
def add_item():
    """
    إضافة صنف جديد
    
    يتم توليد item_code تلقائياً
    إذا لم يُدخل barcode، يتم توليده تلقائياً من item_code
    """
    from code_generator import generate_item_code, generate_barcode_from_item_code, validate_item_code
    
    data = request.json
    
    try:
        # توليد item_code تلقائياً
        item_code = data.get('item_code')
        if not item_code:
            item_code = generate_item_code()
        else:
            # التحقق من صحة الكود المدخل
            validation = validate_item_code(item_code)
            if not validation['is_valid']:
                return jsonify({'error': validation['message']}), 400
        
        # توليد barcode إذا لم يُدخل
        barcode = data.get('barcode')
        if not barcode:
            barcode = generate_barcode_from_item_code(item_code)
        
        item = Item(
            item_code=item_code,
            name=data['name'],
            barcode=barcode,
            karat=normalize_number(str(data.get('karat', ''))),
            weight=normalize_number(str(data.get('weight', ''))),
            count=normalize_number(str(data.get('count', ''))),
            wage=normalize_number(str(data.get('wage', ''))),
            manufacturing_wage_per_gram=normalize_number(str(data.get('manufacturing_wage_per_gram', 0))),
            description=data.get('description'),
            price=normalize_number(str(data.get('price', 0))),
            stock=normalize_number(str(data.get('stock', 0)))
        )
        db.session.add(item)
        db.session.commit()
        return jsonify({
            'id': item.id,
            'item_code': item.item_code,
            'barcode': item.barcode
        }), 201
        
    except Exception as e:
        db.session.rollback()
        # تحقق من خطأ التكرار
        if 'item_code' in str(e):
            return jsonify({'error': f'كود الصنف {item_code} مستخدم بالفعل'}), 409
        if 'barcode' in str(e):
            return jsonify({'error': f'الباركود {barcode} مستخدم بالفعل'}), 409
        return jsonify({'error': str(e)}), 500

# Endpoint لجلب سعر الذهب الحالي
@api.route('/gold_price', methods=['GET'])
def get_gold_price():
    """
    يجلب آخر سعر ذهب من قاعدة البيانات
    إذا لم يكن موجود أو قديم (أكثر من 24 ساعة)، يجلب سعر جديد من API
    """
    from datetime import datetime, timedelta
    
    latest = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
    
    # إذا لم يكن هناك سعر أو السعر قديم (أكثر من 24 ساعة)
    should_update = False
    if not latest:
        print('[INFO] لا يوجد سعر ذهب في قاعدة البيانات - سيتم الجلب من API')
        should_update = True
    elif (datetime.now() - latest.date) > timedelta(hours=24):
        print(f'[INFO] السعر المحفوظ قديم ({latest.date}) - سيتم التحديث')
        should_update = True
    
    if should_update:
        try:
            # جلب سعر جديد من API
            price_usd = fetch_gold_price()
            if price_usd:
                # تحويل من دولار للأونصة إلى ريال للجرام
                # 1 أونصة = 31.1035 جرام
                # 1 دولار ≈ 3.75 ريال سعودي
                price_per_gram_sar = (price_usd / 31.1035) * 3.75
                
                # حفظ في قاعدة البيانات
                from flask import current_app
                save_gold_price(current_app._get_current_object(), price_usd)
                
                print(f'[SUCCESS] تم جلب وحفظ سعر جديد: ${price_usd}/أونصة = {price_per_gram_sar:.2f} ر.س/جم')
                
                return jsonify({
                    'price_24k': round(price_per_gram_sar, 2),
                    'price_usd_per_oz': price_usd,
                    'currency': 'ر.س',
                    'date': datetime.now().isoformat(),
                    'source': 'API'
                })
        except Exception as e:
            print(f'[ERROR] فشل جلب السعر من API: {e}')
            # إذا فشل الجلب واستخدم آخر سعر محفوظ
            if latest:
                price_per_gram_sar = (latest.price / 31.1035) * 3.75
                return jsonify({
                    'price_24k': round(price_per_gram_sar, 2),
                    'price_usd_per_oz': latest.price,
                    'currency': 'ر.س',
                    'date': latest.date.isoformat() if latest.date else None,
                    'source': 'Database (Fallback)'
                })
    
    # إرجاع السعر المحفوظ
    if latest:
        price_per_gram_sar = (latest.price / 31.1035) * 3.75
        return jsonify({
            'price_24k': round(price_per_gram_sar, 2),
            'price_usd_per_oz': latest.price,
            'currency': 'ر.س',
            'date': latest.date.isoformat() if latest.date else None,
            'source': 'Database (Cached)'
        })
    
    # إذا لم يكن هناك أي سعر
    return jsonify({
        'price_24k': 0,
        'price_usd_per_oz': 0,
        'currency': 'ر.س',
        'date': None,
        'error': 'لا يوجد سعر ذهب متاح'
    }), 404

    # Endpoint لتحديث سعر الذهب يدوياً
@api.route('/gold_price/update', methods=['POST'])
def update_gold_price():
    import traceback
    try:
        data = request.get_json(silent=True)
        if data and 'price' in data:
            price = float(data['price'])
        else:
            price = fetch_gold_price()
        if price:
            save_gold_price(price)
            return jsonify({'success': True, 'price': price})
        return jsonify({'success': False, 'error': 'No price returned'}), 500
    except Exception as e:
        print('[ERROR] تحديث سعر الذهب تلقائياً:', str(e))
        traceback.print_exc()
        return jsonify({'success': False, 'error': str(e), 'trace': traceback.format_exc()}), 500
# Invoices CRUD
@api.route('/invoices', methods=['GET'])
def get_invoices():
    # Pagination parameters
    page = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 10, type=int)

    # Sorting parameters
    sort_by = request.args.get('sort_by', 'date')
    sort_order = request.args.get('sort_order', 'desc')

    # Filtering parameters
    search = request.args.get('search')
    status = request.args.get('status')
    invoice_type = request.args.get('invoice_type')
    date_from_str = request.args.get('date_from')
    date_to_str = request.args.get('date_to')

    # Base query
    query = Invoice.query

    # Filtering
    if search:
        query = query.join(Customer).filter(
            (Invoice.invoice_type_id.ilike(f'%{search}%')) |
            (Customer.name.ilike(f'%{search}%'))
        )
    if status and status != 'all':
        # This assumes you add a 'status' column to the Invoice model
        query = query.filter(Invoice.status == status)
    if invoice_type and invoice_type != 'الكل':
        query = query.filter(Invoice.invoice_type == invoice_type)
    if date_from_str:
        date_from = datetime.fromisoformat(date_from_str)
        query = query.filter(Invoice.date >= date_from)
    if date_to_str:
        date_to = datetime.fromisoformat(date_to_str)
        query = query.filter(Invoice.date <= date_to)

    # Sorting
    if sort_by == 'date':
        order = Invoice.date.desc() if sort_order == 'desc' else Invoice.date.asc()
    elif sort_by == 'customer':
        order = Customer.name.desc() if sort_order == 'desc' else Customer.name.asc()
        query = query.join(Customer)
    elif sort_by == 'amount':
        order = Invoice.total.desc() if sort_order == 'desc' else Invoice.total.asc()
    else:
        order = Invoice.date.desc() # Default sort
    
    query = query.order_by(order)

    # Pagination
    paginated_invoices = query.paginate(page=page, per_page=per_page, error_out=False)
    invoices = paginated_invoices.items

    result = []
    for inv in invoices:
        invoice_dict = inv.to_dict()  # 🆕 استخدام to_dict() لتضمين payments
        
        # إضافة أسماء العملاء والموردين
        customer_name = inv.customer.name if inv.customer else (inv.supplier.name if inv.supplier else "N/A")
        supplier_name = inv.supplier.name if inv.supplier else "N/A"
        
        invoice_dict['customer_name'] = customer_name
        invoice_dict['supplier_name'] = supplier_name
        
        result.append(invoice_dict)

    return jsonify({
        'invoices': result,
        'total': paginated_invoices.total,
        'pages': paginated_invoices.pages,
        'current_page': paginated_invoices.page,
        'per_page': paginated_invoices.per_page
    })


# ==================== دالة مساعدة للربط المحاسبي ====================

def get_account_id_for_mapping(operation_type, account_type):
    """
    الحصول على معرف الحساب المحاسبي لعملية معينة
    
    Args:
        operation_type: نوع العملية (بيع، شراء، مرتجع...)
        account_type: نوع الحساب (inventory_21k, cash, revenue...)
    
    Returns:
        int: معرف الحساب المحاسبي، أو None إذا لم يتم العثور عليه
    
    الدالة تحاول:
    1. البحث في إعدادات الربط المخصصة (AccountingMapping)
    2. إذا لم تجد، تستخدم الحسابات الافتراضية
    """
    from backend.models import AccountingMapping
    
    # 1. محاولة الحصول على الحساب من الإعدادات المخصصة
    mapping = db.session.query(AccountingMapping).filter_by(
        operation_type=operation_type,
        account_type=account_type,
        is_active=True
    ).first()
    
    if mapping:
        return mapping.account_id
    
    # 2. استخدام الحسابات الافتراضية (Fallback)
    # تم تحديث الأرقام لتطابق دليل الحسابات الفعلي
    DEFAULT_ACCOUNTS = {
        # المخزون (حسب العيار)
        'inventory_18k': 25,  # مخزون ذهب عيار 18
        'inventory_21k': 24,  # مخزون ذهب عيار 21  
        'inventory_22k': 23,  # مخزون ذهب عيار 22
        'inventory_24k': 22,  # مخزون ذهب عيار 24
        
        # النقدية والبنوك
        'cash': 15,           # صندوق النقدية
        
        # العملاء والموردين
        'customers': 5,       # العملاء (حساب تجميعي)
        'suppliers': 38,      # الموردين
        
        # الإيرادات والتكاليف (قديمة - للتوافق)
        'revenue': 55,        # مبيعات ذهب جديد
        'cost': 83,           # تكلفة مبيعات الذهب
        
        # 🆕 حسابات النظام المزدوج (نقد + وزن)
        'sales_gold_new': 55,      # مبيعات ذهب جديد (حساب 400)
        'purchase_scrap': 95,      # مشتريات الكسر والتسكير (حساب 431)
        
        # العمولات
        'commission': 79,     # مصاريف عمولات
        'commission_vat': 9,  # ضريبة القيمة المضافة (مدينة)
        
        # الضرائب
        'vat_payable': 40,    # ضريبة القيمة المضافة - دائنة
        'vat_receivable': 9,  # ضريبة القيمة المضافة (مدينة)
        
        # حسابات إضافية
        'profit_loss': 50,    # حساب الأرباح والخسائر
        'sales_returns': 54,  # مردودات ومسموحات المبيعات
        'purchase_returns': 54,  # مردودات المشتريات (نفس حساب مردودات المبيعات)

        # حسابات للجسر والمصنعية في مشتريات الموردين
        'supplier_bridge': None,
        'manufacturing_wage': None,
    }
    
    return DEFAULT_ACCOUNTS.get(account_type)


def get_inventory_average_cost(karat):
    """
    حساب متوسط تكلفة المخزون لعيار معين (Weighted Average Cost)
    
    Args:
        karat: العيار (18, 21, 22, 24)
    
    Returns:
        float: متوسط التكلفة بالريال/جم
        
    المبدأ:
        متوسط التكلفة = إجمالي قيمة المخزون (ر.س) ÷ إجمالي الوزن (جم)
        
    مثال:
        المخزون: 8 جم بتكلفة 2,550 ر.س
        المتوسط: 2,550 / 8 = 318.75 ر.س/جم
    """
    from sqlalchemy import func
    from backend.models import JournalEntryLine
    
    # تحديد حساب المخزون حسب العيار
    inventory_account_map = {
        '18': 25,  # مخزون ذهب عيار 18
        '21': 24,  # مخزون ذهب عيار 21
        '22': 23,  # مخزون ذهب عيار 22
        '24': 22   # مخزون ذهب عيار 24
    }
    
    account_id = inventory_account_map.get(str(karat))
    if not account_id:
        return 0.0
    
    # حساب المجاميع من جدول journal_entry_line
    result = db.session.query(
        func.coalesce(func.sum(JournalEntryLine.cash_debit), 0).label('total_debit_cash'),
        func.coalesce(func.sum(JournalEntryLine.cash_credit), 0).label('total_credit_cash'),
        func.coalesce(func.sum(getattr(JournalEntryLine, f'debit_{karat}k')), 0).label('total_debit_weight'),
        func.coalesce(func.sum(getattr(JournalEntryLine, f'credit_{karat}k')), 0).label('total_credit_weight')
    ).filter(
        JournalEntryLine.account_id == account_id
    ).first()
    
    # حساب الرصيد (المدين - الدائن)
    total_cash = (result.total_debit_cash or 0) - (result.total_credit_cash or 0)
    total_weight = (result.total_debit_weight or 0) - (result.total_credit_weight or 0)
    
    # حساب المتوسط
    if total_weight > 0:
        average_cost = total_cash / total_weight
        return round(average_cost, 2)
    else:
        return 0.0


def calculate_profit_in_gold(items_sold):
    """
    حساب الربح بالذهب لأصناف مباعة
    
    Args:
        items_sold: قائمة الأصناف المباعة
        مثال: [{'karat': '24', 'weight': 2.0, 'subtotal': 800}, ...]
    
    Returns:
        dict: {
            'total_profit_cash': float,      # الربح النقدي الإجمالي
            'total_profit_gold': float,      # الربح بالذهب الإجمالي (جم)
            'total_cost': float,             # التكلفة الإجمالية
            'details_by_karat': {            # التفاصيل حسب العيار
                '24': {
                    'weight_sold': float,
                    'sale_price': float,
                    'avg_cost_per_gram': float,
                    'total_cost': float,
                    'profit_cash': float,
                    'profit_gold': float,
                    'profit_percentage': float
                }
            }
        }
        
    المعادلة:
        الربح بالذهب (جم) = الربح النقدي (ر.س) ÷ متوسط سعر الشراء (ر.س/جم)
    """
    total_profit_cash = 0.0
    total_profit_gold = 0.0
    total_cost = 0.0
    details_by_karat = {}
    
    for item in items_sold:
        karat = str(item.get('karat', '24'))
        weight = float(item.get('weight', 0))
        sale_price = float(item.get('subtotal', 0))
        
        # 1. حساب متوسط سعر الشراء (تكلفة/جم)
        avg_cost_per_gram = get_inventory_average_cost(karat)
        
        # 2. حساب التكلفة الإجمالية لهذا الصنف
        item_cost = weight * avg_cost_per_gram
        
        # 3. حساب الربح النقدي
        profit_cash = sale_price - item_cost
        
        # 4. حساب الربح بالذهب
        profit_gold = (profit_cash / avg_cost_per_gram) if avg_cost_per_gram > 0 else 0
        
        # 5. حساب نسبة الربح
        profit_percentage = (profit_cash / item_cost * 100) if item_cost > 0 else 0
        
        # 6. جمع الإجماليات
        total_profit_cash += profit_cash
        total_profit_gold += profit_gold
        total_cost += item_cost
        
        # 7. حفظ التفاصيل حسب العيار
        if karat not in details_by_karat:
            details_by_karat[karat] = {
                'weight_sold': 0,
                'sale_price': 0,
                'avg_cost_per_gram': avg_cost_per_gram,
                'total_cost': 0,
                'profit_cash': 0,
                'profit_gold': 0,
                'profit_percentage': 0
            }
        
        details_by_karat[karat]['weight_sold'] += weight
        details_by_karat[karat]['sale_price'] += sale_price
        details_by_karat[karat]['total_cost'] += item_cost
        details_by_karat[karat]['profit_cash'] += profit_cash
        details_by_karat[karat]['profit_gold'] += profit_gold
        details_by_karat[karat]['profit_percentage'] = (
            (details_by_karat[karat]['profit_cash'] / details_by_karat[karat]['total_cost'] * 100)
            if details_by_karat[karat]['total_cost'] > 0 else 0
        )
    
    return {
        'total_profit_cash': round(total_profit_cash, 2),
        'total_profit_gold': round(total_profit_gold, 3),
        'total_cost': round(total_cost, 2),
        'details_by_karat': details_by_karat
    }


@api.route('/invoices', methods=['POST'])
def add_invoice():
    data = request.get_json(silent=True)
    print(f"\n=== 📝 Invoice Creation Request ===")
    print(f"Received data: {data}")
    
    if not isinstance(data, dict):
        return jsonify({'error': 'Invalid or missing JSON body'}), 400

    # دعم كل من invoice_type و transaction_type للتوافق مع الشاشات المختلفة
    invoice_type = data.get('invoice_type')
    if not invoice_type:
        # إذا كان transaction_type موجود، استخدمه لتحديد invoice_type
        transaction_type = data.get('transaction_type', 'sell')
        if transaction_type == 'sell':
            invoice_type = 'بيع'
        elif transaction_type == 'buy':
            invoice_type = 'شراء من عميل'
        else:
            invoice_type = 'بيع'  # افتراضي
    
    if not invoice_type:
        return jsonify({'error': 'invoice_type or transaction_type is required'}), 400
    
    # 🆕 Validation للمرتجعات
    return_types = ['مرتجع بيع', 'مرتجع شراء', 'مرتجع شراء من مورد']
    if invoice_type in return_types:
        # التحقق من وجود original_invoice_id
        if not data.get('original_invoice_id'):
            return jsonify({'error': 'original_invoice_id is required for return invoices'}), 400
        
        # التحقق من وجود الفاتورة الأصلية
        original_invoice = Invoice.query.get(data['original_invoice_id'])
        if not original_invoice:
            return jsonify({'error': f'Original invoice with ID {data["original_invoice_id"]} not found'}), 404
        
        # التحقق من تطابق العميل/المورد
        if invoice_type == 'مرتجع بيع' and original_invoice.invoice_type == 'بيع':
            if original_invoice.customer_id != data.get('customer_id'):
                return jsonify({'error': 'Customer ID must match original invoice'}), 400
        elif invoice_type == 'مرتجع شراء' and original_invoice.invoice_type == 'شراء من عميل':
            if original_invoice.customer_id != data.get('customer_id'):
                return jsonify({'error': 'Customer ID must match original invoice'}), 400
        elif invoice_type == 'مرتجع شراء من مورد' and original_invoice.invoice_type == 'شراء من مورد':
            if original_invoice.supplier_id != data.get('supplier_id'):
                return jsonify({'error': 'Supplier ID must match original invoice'}), 400
    
    # 🆕 Validation لنوع الذهب
    gold_type = data.get('gold_type', 'new')
    if gold_type not in ['new', 'scrap']:
        return jsonify({'error': 'gold_type must be either "new" or "scrap"'}), 400
    
    # 🆕 دعم وسائل دفع متعددة في الفاتورة الواحدة
    # يمكن إرسال إما:
    # 1. payment_method_id (وسيلة واحدة - للتوافق)
    # 2. payments (array من وسائل متعددة - الميزة الجديدة)
    
    payment_method_id = data.get('payment_method_id')  # للتوافق مع الكود القديم
    payments_data = data.get('payments', [])  # 🆕 دعم وسائل متعددة
    payment_method_obj = None  # نستخدمه لاحقاً عند الحاجة للخزينة الافتراضية
    karat_lines_data = data.get('karat_lines', [])
    
    commission_amount = 0.0
    net_amount = data['total']
    
    # إذا كانت هناك وسائل دفع متعددة
    if payments_data and isinstance(payments_data, list) and len(payments_data) > 0:
        # التحقق من أن مجموع المبالغ = إجمالي الفاتورة
        total_payments = sum(p.get('amount', 0) for p in payments_data)
        if abs(total_payments - data['total']) > 0.01:  # tolerance للفواصل العشرية
            return jsonify({
                'error': f'مجموع المبالغ ({total_payments}) لا يساوي إجمالي الفاتورة ({data["total"]})'
            }), 400
        
        # حساب إجمالي العمولات
        for payment in payments_data:
            pm_id = payment.get('payment_method_id')
            pm_amount = payment.get('amount', 0)
            
            if not pm_id:
                return jsonify({'error': 'payment_method_id is required for each payment'}), 400
            
            pm_obj = PaymentMethod.query.get(pm_id)
            if not pm_obj:
                return jsonify({'error': f'Payment method with ID {pm_id} not found'}), 404
            
            if not pm_obj.is_active:
                return jsonify({'error': f'Payment method "{pm_obj.name}" is not active'}), 400
            
            # حساب عمولة هذه الدفعة
            if pm_obj.commission_rate and pm_obj.commission_rate > 0:
                payment_commission = pm_amount * (pm_obj.commission_rate / 100)
                commission_amount += payment_commission
        
        net_amount = data['total'] - commission_amount
    
    # وسيلة دفع واحدة (للتوافق مع الكود القديم)
    elif payment_method_id:
        payment_method_obj = PaymentMethod.query.get(payment_method_id)
        if not payment_method_obj:
            return jsonify({'error': f'Payment method with ID {payment_method_id} not found'}), 404
        
        if not payment_method_obj.is_active:
            return jsonify({'error': f'Payment method "{payment_method_obj.name}" is not active'}), 400
        
        # حساب العمولة
        if payment_method_obj.commission_rate and payment_method_obj.commission_rate > 0:
            commission_amount = data['total'] * (payment_method_obj.commission_rate / 100)
            net_amount = data['total'] - commission_amount
    
    print(f"🔴 ENTERING try block for invoice creation, invoice_type={invoice_type}")
    try:
        # --- 1. Create Invoice and Items ---
        print(f"🟢 Step 1: Creating invoice...")
        last_invoice = Invoice.query.filter_by(invoice_type=invoice_type).order_by(Invoice.invoice_type_id.desc()).first()
        next_invoice_type_id = (last_invoice.invoice_type_id + 1) if last_invoice else 1

        def _extract_float(key, default=0.0):
            if key not in data:
                return default
            try:
                return normalize_number(str(data.get(key, default)))
            except Exception:
                return default

        def _to_float(value, default=0.0):
            if value in (None, '', False):
                return default
            try:
                normalized = normalize_number(str(value))
                return float(normalized)
            except (TypeError, ValueError):
                try:
                    return float(value)
                except (TypeError, ValueError):
                    return default

        new_invoice = Invoice(
            invoice_type_id=next_invoice_type_id,
            customer_id=data.get('customer_id'),
            supplier_id=data.get('supplier_id'),
            date=datetime.fromisoformat(data['date']),
            total=data['total'],
            invoice_type=invoice_type,
            total_weight=data.get('total_weight'),
            total_tax=_extract_float('total_tax'),
            total_cost=_extract_float('total_cost'),
            gold_subtotal=_extract_float('gold_subtotal'),
            wage_subtotal=_extract_float('wage_subtotal'),
            gold_tax_total=_extract_float('gold_tax_total'),
            wage_tax_total=_extract_float('wage_tax_total'),
            apply_gold_tax=bool(data.get('apply_gold_tax', False)),
            payment_method=data.get('payment_method'),  # للتوافق مع الفواتير القديمة
            payment_method_id=payment_method_id,  # 🆕 Foreign key
            commission_amount=commission_amount,  # 🆕 العمولة المحسوبة
            net_amount=net_amount,  # 🆕 المبلغ الصافي
            amount_paid=data.get('amount_paid'),
            safe_box_id=data.get('safe_box_id'),  # 🆕 الخزينة المستخدمة
            # 🆕 الحقول الجديدة
            original_invoice_id=data.get('original_invoice_id'),
            return_reason=data.get('return_reason'),
            gold_type=gold_type
        )
        db.session.add(new_invoice)
        db.session.flush()

        computed_total_weight = 0.0

        for item_data in data.get('items', []):
            print(f"\n📦 DEBUG - item_data: {item_data}")  # 🔍 Debug logging

            item_id = item_data.get('item_id')
            item = Item.query.get(item_id) if item_id else None

            if item_id and not item:
                return jsonify({'error': f"Item {item_id} not found"}), 404

            # Extract base attributes, preferring DB values when available
            item_name = (item.name if item else item_data.get('name')) or 'صنف بدون اسم'
            item_karat = item.karat if item else item_data.get('karat')
            item_weight = item.weight if item else item_data.get('weight')
            item_wage = item.wage if item else item_data.get('manufacturing_wage_per_gram', 0)

            if item_weight is None:
                item_weight = item_data.get('total_weight', 0)

            # 💵 Get values from request
            selling_price_raw = (
                item_data.get('selling_price')
                or item_data.get('price')
                or item_data.get('subtotal')
                or 0
            )
            tax_amount_raw = item_data.get('tax_amount', item_data.get('tax', 0)) or 0
            discount_amount_raw = item_data.get('discount_amount', 0)
            quantity_raw = item_data.get('quantity', 1)

            quantity_value = _to_float(quantity_raw, 1.0) or 1.0
            quantity_int = int(round(quantity_value)) if quantity_value > 0 else 1

            selling_price_val = _to_float(selling_price_raw, 0.0)
            tax_amount_val = _to_float(tax_amount_raw, 0.0)
            discount_amount_val = _to_float(discount_amount_raw, 0.0)

            print(f"   💵 selling_price={selling_price_val}, tax_amount={tax_amount_val}, discount={discount_amount_val}")

            if tax_amount_val < 0:
                print(f"⚠️ WARNING: Negative tax received for purchase item '{item_name}': {tax_amount_val}")
                tax_amount_val = abs(tax_amount_val)

            net_price = selling_price_val - tax_amount_val - discount_amount_val
            total_price = selling_price_val

            weight_per_item = _to_float(item_weight, 0.0)
            if weight_per_item <= 0:
                weight_per_item = _to_float(item_data.get('total_weight'), 0.0)

            item_total_weight = weight_per_item * quantity_value
            if item_total_weight > 0:
                computed_total_weight += item_total_weight

            item_wage_val = _to_float(item_wage, 0.0)

            db.session.add(InvoiceItem(
                invoice_id=new_invoice.id,
                item_id=item.id if item else None,
                name=item_name,
                karat=item_karat,
                weight=weight_per_item,
                wage=item_wage_val,
                net=net_price,
                tax=tax_amount_val,
                price=total_price,
                quantity=quantity_int
            ))

        print(f"🟢 Step 1.5: Adding invoice items complete")

        processed_karat_lines = 0
        if karat_lines_data and isinstance(karat_lines_data, list):
            print("🆕 Step 1.6: Creating karat lines from request...")
            for idx, line_data in enumerate(karat_lines_data, start=1):
                karat_value = _to_float(line_data.get('karat'))
                weight_value = _to_float(
                    line_data.get('weight_grams',
                                   line_data.get('weight',
                                                 line_data.get('total_weight')))
                )

                if karat_value <= 0 or weight_value <= 0:
                    print(f"⚠️ Skipping karat line #{idx}: invalid karat/weight = ({line_data.get('karat')}, {line_data.get('weight_grams') or line_data.get('weight')})")
                    continue

                gold_value_cash = _to_float(line_data.get('gold_value_cash', line_data.get('gold_value')))
                wage_cash = _to_float(line_data.get('manufacturing_wage_cash', line_data.get('wage_cash')))
                gold_tax_val = _to_float(line_data.get('gold_tax'))
                wage_tax_val = _to_float(line_data.get('wage_tax'))
                description = line_data.get('description') or line_data.get('notes')

                db.session.add(InvoiceKaratLine(
                    invoice_id=new_invoice.id,
                    karat=karat_value,
                    weight_grams=weight_value,
                    gold_value_cash=gold_value_cash,
                    manufacturing_wage_cash=wage_cash,
                    gold_tax=gold_tax_val,
                    wage_tax=wage_tax_val,
                    description=description
                ))

                computed_total_weight += weight_value
                processed_karat_lines += 1

            print(f"🟢 Step 1.7: Added {processed_karat_lines} karat lines")
        else:
            print("🟡 Step 1.6: No karat lines supplied with invoice")

        if computed_total_weight > 0:
            new_invoice.total_weight = round(computed_total_weight, 4)

        db.session.add(new_invoice)
        db.session.flush()
        print(f"🟢 Invoice #{new_invoice.id} created successfully!")

        # 🆕 --- 1.5. Create Invoice Payments (وسائل دفع متعددة) ---
        print(f"🟢 Step 2: Creating invoice payments (if any)...")
        if payments_data and isinstance(payments_data, list) and len(payments_data) > 0:
            # إنشاء سجل لكل وسيلة دفع
            for payment in payments_data:
                pm_id = payment.get('payment_method_id')
                pm_amount = payment.get('amount', 0)
                pm_obj = PaymentMethod.query.get(pm_id)
                
                # حساب العمولة وضريبتها لهذه الدفعة
                pm_commission_rate = payment.get('commission_rate', pm_obj.commission_rate if pm_obj else 0.0)
                pm_commission_amount = payment.get('commission_amount', pm_amount * (pm_commission_rate / 100) if pm_commission_rate > 0 else 0.0)
                pm_commission_vat = payment.get('commission_vat', pm_commission_amount * 0.15)  # 🆕 ضريبة 15%
                pm_net_amount = payment.get('net_amount', pm_amount - pm_commission_amount - pm_commission_vat)
                
                db.session.add(InvoicePayment(
                    invoice_id=new_invoice.id,
                    payment_method_id=pm_id,
                    amount=pm_amount,
                    commission_rate=pm_commission_rate,
                    commission_amount=pm_commission_amount,
                    commission_vat=pm_commission_vat,
                    net_amount=pm_net_amount,
                    notes=payment.get('notes')
                ))
        
        # وسيلة دفع واحدة (للتوافق مع الكود القديم)
        elif payment_method_id:
            pm_obj = PaymentMethod.query.get(payment_method_id)
            pm_commission_rate = pm_obj.commission_rate if pm_obj else 0.0
            
            db.session.add(InvoicePayment(
                invoice_id=new_invoice.id,
                payment_method_id=payment_method_id,
                amount=data['total'],
                commission_rate=pm_commission_rate,
                commission_amount=commission_amount,
                net_amount=net_amount
            ))

        # --- 2. Aggregate Gold and Cash Totals ---
        total_cash = new_invoice.total
        
        # Aggregate weights by karat from invoice items (using DB data)
        gold_by_karat = {'18': 0.0, '21': 0.0, '22': 0.0, '24': 0.0}

        def _register_gold_weight(karat_val, weight_val):
            karat_float = _to_float(karat_val, 0.0)
            weight_float = _to_float(weight_val, 0.0)
            if karat_float <= 0 or weight_float <= 0:
                return

            karat_key = str(int(round(karat_float)))
            if karat_key not in gold_by_karat:
                gold_by_karat[karat_key] = 0.0

            gold_by_karat[karat_key] += weight_float

        for item_data in data.get('items', []):
            item_id = item_data.get('item_id')
            item = Item.query.get(item_id) if item_id else None

            karat_value = item.karat if item else item_data.get('karat')
            weight_value = item.weight if item else item_data.get('weight')

            if weight_value is None:
                weight_value = item_data.get('total_weight')

            quantity_value = _to_float(item_data.get('quantity', 1), 1.0) or 1.0
            total_weight_value = _to_float(weight_value, 0.0) * (quantity_value if quantity_value > 0 else 1.0)

            _register_gold_weight(karat_value, total_weight_value)

        if karat_lines_data and isinstance(karat_lines_data, list):
            for line_data in karat_lines_data:
                karat_val = line_data.get('karat')
                weight_val = line_data.get('weight_grams', line_data.get('weight', line_data.get('total_weight')))
                _register_gold_weight(karat_val, weight_val)

        # --- 3. Determine Accounts and Journal Entry Logic ---
        # 🆕 منطق محدث لدعم 6 أنواع من الفواتير
        
        # الحسابات الأساسية
        cash_account = Account.query.filter_by(name='صندوق النقدية').first()
        inventory_account = Account.query.filter_by(name='المخزون').first()
        sales_account = Account.query.filter(Account.name.like('مبيعات%')).first()
        revenue_account = Account.query.filter(Account.name.like('الإيرادات%')).first()
        purchases_account = Account.query.filter_by(name='تكلفة البضاعة المباعة').first()
        
        # حساب الطرف (عميل أو مورد)
        party_account = None
        if new_invoice.customer_id:
            customer = Customer.query.get(new_invoice.customer_id)
            if customer and customer.account_id:
                party_account = Account.query.get(customer.account_id)
        elif new_invoice.supplier_id:
            supplier = Supplier.query.get(new_invoice.supplier_id)
            if supplier and supplier.account_id:
                party_account = Account.query.get(supplier.account_id)
        
        # إذا لم يكن هناك طرف، استخدم الصندوق
        if not party_account:
            party_account = cash_account

        # --- 4. Create Journal Entry ---
        journal_desc = f"فاتورة {invoice_type} رقم #{new_invoice.invoice_type_id}"
        if new_invoice.original_invoice_id:
            journal_desc += f" (مرتبطة بفاتورة #{new_invoice.original_invoice_id})"
        
        # 🔧 توليد رقم القيد
        year = new_invoice.date.year
        entry_count = JournalEntry.query.filter(
            db.func.strftime('%Y', JournalEntry.date) == str(year)
        ).count() + 1
        entry_number_str = f'JE-{year}-{entry_count:05d}'
        
        journal_entry = JournalEntry(
            entry_number=entry_number_str,
            date=new_invoice.date,
            description=journal_desc,
            reference_type='invoice',
            reference_id=new_invoice.id
        )
        db.session.add(journal_entry)
        db.session.flush()

        # --- 5. Create Journal Entry Lines ---
        # 🆕 منطق محدث لدعم 6 أنواع من الفواتير
        
        # تحضير حقول الذهب
        gold_debit_fields = {f"debit_{k}k": v for k, v in gold_by_karat.items() if v > 0}
        gold_credit_fields = {f"credit_{k}k": v for k, v in gold_by_karat.items() if v > 0}
        
        # 🆕 دالة مساعدة لإضافة قيد العمولة وضريبتها
        def add_commission_entry(journal_entry_id, payment_method_obj, commission_amount, commission_vat=0.0):
            """
            ملاحظة: قيود العمولات تُعالج الآن في قسم multi-payment أدناه
            """
        
        # --- القيود حسب نوع الفاتورة ---
        
        print(f"📊 Processing invoice type: '{invoice_type}'")
        print(f"📊 Checking condition: invoice_type == 'بيع' => {invoice_type == 'بيع'}")
        
        if invoice_type == 'بيع':
            # ============================================
            # 1. فاتورة بيع - النظام المحاسبي الصحيح
            # ============================================
            # القيد الأول: إثبات الإيراد الكامل
            #     من حـ/ النقدية [مدين نقد]
            #         إلى حـ/ مبيعات الذهب الجديد [دائن نقد بالمبلغ الكامل]
            # 
            # القيد الثاني: إثبات التكلفة (متوسط سعر الشراء)
            #     من حـ/ تكلفة المبيعات [مدين نقد + وزن]
            #         إلى حـ/ مخزون الذهب عيار XX [دائن نقد + وزن]
            #
            # الربح = الإيراد - التكلفة
            # الربح بالذهب = الربح النقدي ÷ متوسط سعر الشراء
            # ============================================
            
            # الحصول على الحسابات من الربط المحاسبي
            cash_acc_id = get_account_id_for_mapping('بيع', 'cash')
            sales_gold_new_acc_id = get_account_id_for_mapping('بيع', 'sales_gold_new') or 55  # الإيرادات
            cost_of_sales_acc_id = get_account_id_for_mapping('بيع', 'cost_of_sales') or 83  # تكلفة المبيعات
            vat_payable_acc_id = get_account_id_for_mapping('بيع', 'vat_payable')
            commission_acc_id = get_account_id_for_mapping('بيع', 'commission')
            commission_vat_acc_id = get_account_id_for_mapping('بيع', 'commission_vat')
            
            # حسابات المخزون حسب العيار
            inventory_accounts = {}
            for karat in ['18', '21', '22', '24']:
                inv_acc_id = get_account_id_for_mapping('بيع', f'inventory_{karat}k')
                if inv_acc_id:
                    inventory_accounts[karat] = inv_acc_id
            
            # ============================================
            # القيد الأول: إثبات الإيراد (المبلغ الكامل)
            # من حـ/ النقدية → إلى حـ/ مبيعات الذهب الجديد
            # ============================================
            
            # 🆕 دعم وسائل دفع متعددة
            if payments_data and len(payments_data) > 0:
                for payment in payments_data:
                    pm_obj = PaymentMethod.query.get(payment['payment_method_id'])
                    pm_amount = payment['amount']
                    pm_commission = payment.get('commission_amount', 0.0)
                    pm_commission_vat = payment.get('commission_vat', 0.0)
                    pm_net = payment.get('net_amount', pm_amount - pm_commission - pm_commission_vat)
                    
                    # 🆕 الحصول على الحساب من الخزينة (وليس من وسيلة الدفع مباشرة)
                    safe_box = None
                    safe_box_id = payment.get('safe_box_id')
                    if safe_box_id:
                        safe_box = SafeBox.query.get(safe_box_id)
                    elif pm_obj and pm_obj.default_safe_box:
                        safe_box = pm_obj.default_safe_box
                    
                    # مدين حساب الخزينة
                    if safe_box and safe_box.account:
                        create_dual_journal_entry(
                            journal_entry_id=journal_entry.id,
                            account_id=safe_box.account.id,
                            cash_debit=pm_net,
                            description=f"استلام دفعة عبر {pm_obj.name} - {safe_box.name}"
                        )
                    
                    # قيد العمولة وضريبتها
                    if pm_commission > 0 and commission_acc_id:
                        create_dual_journal_entry(
                            journal_entry_id=journal_entry.id,
                            account_id=commission_acc_id,
                            cash_debit=pm_commission,
                            description=f"عمولة {pm_obj.name}"
                        )
                    
                    if pm_commission_vat > 0 and commission_vat_acc_id:
                        create_dual_journal_entry(
                            journal_entry_id=journal_entry.id,
                            account_id=commission_vat_acc_id,
                            cash_debit=pm_commission_vat,
                            description=f"ضريبة عمولة {pm_obj.name}"
                        )
            
            # وسيلة دفع واحدة
            elif payment_method_id:
                actual_debit_amount = net_amount if commission_amount > 0 else total_cash
                
                # 🆕 الحصول على الحساب من الخزينة
                safe_box = None
                if safe_box_id:
                    safe_box = SafeBox.query.get(safe_box_id)
                elif payment_method_obj and payment_method_obj.default_safe_box:
                    safe_box = payment_method_obj.default_safe_box
                
                if safe_box and safe_box.account:
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=safe_box.account.id,
                        cash_debit=actual_debit_amount,
                        description=f"استلام دفعة عبر {payment_method_obj.name} - {safe_box.name}"
                    )
                else:
                    acc_id = cash_acc_id or 15
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=acc_id,
                        cash_debit=total_cash,
                        description="استلام نقدي"
                    )
                
                # قيد العمولة
                if commission_amount > 0 and commission_acc_id:
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=commission_acc_id,
                        cash_debit=commission_amount,
                        description="عمولة الدفع"
                    )
            
            # لا توجد وسيلة دفع - استخدام الصندوق
            else:
                acc_id = cash_acc_id or 15
                create_dual_journal_entry(
                    journal_entry_id=journal_entry.id,
                    account_id=acc_id,
                    cash_debit=total_cash,
                    description="استلام نقدي"
                )
            
            # ✅ دائن حساب المبيعات (الإيراد بدون الضريبة)
            # ✅ دائن حساب الضريبة (قيمة الضريبة منفصلة)
            
            # حساب إجمالي الضريبة من بيانات الطلب (data) وليس من new_invoice.items
            # لأن items قد لا تكون محملة بعد flush()
            # ✅ دعم كل من 'tax' و 'tax_amount'
            total_tax = sum([
                item_data.get('tax_amount', 0) or item_data.get('tax', 0) 
                for item_data in data.get('items', [])
            ])
            # تحويل القيم السالبة إلى موجبة
            if total_tax < 0:
                total_tax = abs(total_tax)
            
            sales_amount = total_cash - total_tax  # المبيعات = الإجمالي - الضريبة
            
            print(f"💰 Tax calculation: total_cash={total_cash}, total_tax={total_tax}, sales_amount={sales_amount}")
            print(f"📋 Items from data: {len(data.get('items', []))}")
            print(f"🏦 VAT account ID: {vat_payable_acc_id}")
            
            # قيد المبيعات (بدون الضريبة)
            create_dual_journal_entry(
                journal_entry_id=journal_entry.id,
                account_id=sales_gold_new_acc_id,
                cash_credit=sales_amount,
                description="مبيعات ذهب (بدون ضريبة)"
            )
            
            # قيد الضريبة (إن وجدت)
            if total_tax > 0 and vat_payable_acc_id:
                print(f"✅ Adding VAT entry: {total_tax}")
                create_dual_journal_entry(
                    journal_entry_id=journal_entry.id,
                    account_id=vat_payable_acc_id,
                    cash_credit=total_tax,
                    description="ضريبة القيمة المضافة"
                )
            else:
                print(f"⚠️ Skipping VAT entry: total_tax={total_tax}, vat_payable_acc_id={vat_payable_acc_id}")
            
            # ============================================
            # القيد الثاني: إثبات التكلفة (متوسط المخزون)
            # من حـ/ تكلفة المبيعات → إلى حـ/ المخزون
            # ============================================
            
            total_cost_cash = 0.0  # إجمالي التكلفة النقدية
            
            for karat, weight in gold_by_karat.items():
                if weight > 0 and karat in inventory_accounts:
                    # 1. حساب متوسط سعر الشراء لهذا العيار
                    avg_cost_per_gram = get_inventory_average_cost(karat)
                    
                    # 2. حساب التكلفة الإجمالية لهذا الصنف
                    item_cost_cash = round(weight * avg_cost_per_gram, 2)
                    total_cost_cash += item_cost_cash
                    
                    # 3. مدين تكلفة المبيعات (نقد + وزن)
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=cost_of_sales_acc_id,
                        cash_debit=item_cost_cash,
                        **{f"weight_{karat}k_debit": weight},
                        description=f"تكلفة المبيعات عيار {karat}"
                    )
                    
                    # 4. دائن المخزون (نقد + وزن)
                    inv_acc_id = inventory_accounts[karat]
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=inv_acc_id,
                        cash_credit=item_cost_cash,
                        **{f"weight_{karat}k_credit": weight},
                        description=f"خصم من مخزون عيار {karat}"
                    )
            
            # ============================================
            # 🆕 حساب الربح بالذهب وإضافته للفاتورة
            # ============================================
            # الربح النقدي = الإيراد - التكلفة
            profit_cash = total_cash - total_cost_cash
            
            # حساب الربح بالذهب (إجمالي)
            # نستخدم متوسط الأسعار المرجحة
            total_weight_sold = sum(gold_by_karat.values())
            weighted_avg_cost = (total_cost_cash / total_weight_sold) if total_weight_sold > 0 else 0
            profit_gold = (profit_cash / weighted_avg_cost) if weighted_avg_cost > 0 else 0
            
            # حفظ الربح في الفاتورة
            new_invoice.profit_cash = round(profit_cash, 2)
            new_invoice.profit_gold = round(profit_gold, 3)
            new_invoice.total_cost = round(total_cost_cash, 2)
        
        elif invoice_type == 'شراء من عميل':
            # ============================================
            # 2. شراء كسر من عميل - النظام المحاسبي الصحيح
            # ============================================
            # القيد المباشر للمخزون:
            #     من حـ/ مخزون الذهب عيار XX [مدين نقد + وزن]
            #         إلى حـ/ النقدية [دائن نقد]
            # ============================================
            
            # الحصول على الحسابات
            cash_acc_id = get_account_id_for_mapping('شراء من عميل', 'cash')
            vat_receivable_acc_id = get_account_id_for_mapping('شراء من عميل', 'vat_receivable')
            
            # حسابات المخزون حسب العيار
            inventory_accounts = {}
            for karat in ['18', '21', '22', '24']:
                inv_acc_id = get_account_id_for_mapping('شراء من عميل', f'inventory_{karat}k')
                if inv_acc_id:
                    inventory_accounts[karat] = inv_acc_id
            
            # ============================================
            # القيد المباشر: إضافة للمخزون
            # من حـ/ المخزون (نقد + وزن) → إلى حـ/ النقدية
            # ============================================
            
            # 1. مدين المخزون (نقد + وزن حسب العيار)
            for karat, weight in gold_by_karat.items():
                if weight > 0 and karat in inventory_accounts:
                    inv_acc_id = inventory_accounts[karat]
                    
                    # حساب نسبة التكلفة لهذا العيار من الإجمالي
                    total_weight_all_karats = sum(gold_by_karat.values())
                    karat_proportion = weight / total_weight_all_karats if total_weight_all_karats > 0 else 0
                    karat_cash = round(total_cash * karat_proportion, 2)
                    
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=inv_acc_id,
                        cash_debit=karat_cash,
                        **{f"weight_{karat}k_debit": weight},
                        description=f"شراء ذهب عيار {karat}"
                    )
            
            # 2. دائن حساب النقدية (من الخزينة)
            acc_id = cash_acc_id or 15
            
            # 🆕 الحصول على الحساب من الخزينة
            safe_box = None
            if safe_box_id:
                safe_box = SafeBox.query.get(safe_box_id)
            elif payment_method_obj and payment_method_obj.default_safe_box:
                safe_box = payment_method_obj.default_safe_box
            
            if safe_box and safe_box.account:
                acc_id = safe_box.account.id
            
            create_dual_journal_entry(
                journal_entry_id=journal_entry.id,
                account_id=acc_id,
                cash_credit=total_cash,
                description="دفع نقدي لشراء ذهب"
            )
            
            # ============================================
            # قيد ضريبة القيمة المضافة (إن وجدت)
            # ============================================
            total_vat = data.get('total_tax', 0)
            if total_vat > 0 and vat_receivable_acc_id:
                create_dual_journal_entry(
                    journal_entry_id=journal_entry.id,
                    account_id=vat_receivable_acc_id,
                    cash_debit=total_vat,
                    description="ضريبة القيمة المضافة"
                )
        
        elif invoice_type == 'مرتجع بيع':
            # 3. مرتجع بيع (عكس البيع)
            # من حـ/ المخزون [مدين]
            # من حـ/ مردودات المبيعات [مدين]
            #     إلى حـ/ العميل (أو الصندوق) [دائن]
            
            # 🔥 استخدام الربط المحاسبي
            cash_acc_id = get_account_id_for_mapping('مرتجع بيع', 'cash')
            customers_acc_id = get_account_id_for_mapping('مرتجع بيع', 'customers')
            sales_returns_acc_id = get_account_id_for_mapping('مرتجع بيع', 'sales_returns')
            
            # حسابات المخزون
            inventory_acc_id = None
            for karat in ['18', '21', '22', '24']:
                inv_acc_id = get_account_id_for_mapping('مرتجع بيع', f'inventory_{karat}k')
                if inv_acc_id:
                    inventory_acc_id = inv_acc_id
                    break
            
            total_cost = data.get('total_cost', 0) or (total_cash * 0.8)
            
            # Line 1: مدين المخزون
            if inventory_acc_id:
                create_dual_journal_entry(
                    journal_entry_id=journal_entry.id,
                    account_id=inventory_acc_id,
                    cash_debit=total_cost,
                    **{f"weight_{k}k_debit": v for k, v in gold_by_karat.items() if v > 0},
                    description="مرتجع للمخزون"
                )
            
            # Line 2: مدين مردودات المبيعات
            if sales_returns_acc_id:
                create_dual_journal_entry(
                    journal_entry_id=journal_entry.id,
                    account_id=sales_returns_acc_id,
                    cash_debit=total_cash - total_cost,
                    description="مردودات المبيعات"
                )
            
            # Line 3: دائن العميل/الصندوق
            acc_id = customers_acc_id or cash_acc_id or party_account.id
            create_dual_journal_entry(
                journal_entry_id=journal_entry.id,
                account_id=acc_id,
                cash_credit=total_cash,
                **{f"weight_{k}k_credit": v for k, v in gold_by_karat.items() if v > 0},
                description="استرداد نقدي للعميل"
            )
        
        elif invoice_type == 'مرتجع شراء':
            # 4. مرتجع شراء كسر (عكس الشراء من عميل)
            # من حـ/ العميل (أو الصندوق) [مدين]
            #     إلى حـ/ المخزون - كسر [دائن]
            
            # 🔥 استخدام الربط المحاسبي
            cash_acc_id = get_account_id_for_mapping('مرتجع شراء', 'cash')
            customers_acc_id = get_account_id_for_mapping('مرتجع شراء', 'customers')
            purchase_returns_acc_id = get_account_id_for_mapping('مرتجع شراء', 'purchase_returns')
            
            # حسابات المخزون
            inventory_acc_id = None
            for karat in ['18', '21', '22', '24']:
                inv_acc_id = get_account_id_for_mapping('مرتجع شراء', f'inventory_{karat}k')
                if inv_acc_id:
                    inventory_acc_id = inv_acc_id
                    break
            
            # Line 1: مدين العميل/الصندوق
            acc_id = customers_acc_id or cash_acc_id or party_account.id
            create_dual_journal_entry(
                journal_entry_id=journal_entry.id,
                account_id=acc_id,
                cash_debit=total_cash,
                **{f"weight_{k}k_debit": v for k, v in gold_by_karat.items() if v > 0},
                description="استلام نقدي من مرتجع شراء"
            )
            
            # Line 2: دائن المخزون
            if inventory_acc_id:
                create_dual_journal_entry(
                    journal_entry_id=journal_entry.id,
                    account_id=inventory_acc_id,
                    cash_credit=total_cash,
                    **{f"weight_{k}k_credit": v for k, v in gold_by_karat.items() if v > 0},
                    description="خصم من المخزون (مرتجع)"
                )
        
        elif invoice_type == 'شراء من مورد':
            # 5. شراء من مورد
            # السيناريو الجديد: المخزون يُثبت بالوزن والقيمة، المورد دائن بالذهب،
            # ويتم تسجيل التقييم النقدي على حساب جسر مستقل.
            
            print("\n" + "="*60)
            print("🔍 DEBUGGING: شراء من مورد - START")
            print("="*60)
            print(f"invoice_type = {invoice_type}")
            print(f"data keys = {list(data.keys())}")
            print(f"gold_tax_total = {data.get('gold_tax_total')}")
            print(f"wage_tax_total = {data.get('wage_tax_total')}")
            print("="*60 + "\n")

            # محاولة الحصول على حساب الجسر من الطلب أو إعدادات الربط
            bridge_acc_id = (
                data.get('bridge_account_id')
                or get_account_id_for_mapping('شراء من مورد', 'supplier_bridge')
                or get_account_id_for_mapping('شراء', 'supplier_bridge')
            )

            if not bridge_acc_id:
                bridge_acc_id = (
                    get_account_id_for_mapping('شراء من مورد', 'suppliers')
                    or get_account_id_for_mapping('شراء', 'suppliers')
                    or (party_account.id if party_account and not party_account.tracks_weight else None)
                    or (cash_account.id if cash_account else None)
                )

            if bridge_acc_id:
                operation_key = 'شراء من مورد'
                fallback_operation = 'شراء'
                dual_entry_params = set(create_dual_journal_entry.__code__.co_varnames)

                def _mapping(account_type):
                    value = get_account_id_for_mapping(operation_key, account_type)
                    if value is None:
                        value = get_account_id_for_mapping(fallback_operation, account_type)
                    return value

                def _normalize_karat(value):
                    try:
                        return str(int(round(float(value))))
                    except (TypeError, ValueError):
                        return None

                # حسابات أساسية
                vat_receivable_acc_id = _mapping('vat_receivable')
                wage_expense_acc_id = (
                    data.get('wage_expense_account_id')
                    or _mapping('manufacturing_wage')
                )

                # بناء قاموس حسابات المخزون حسب العيار
                inventory_accounts = {}
                for karat in ['18', '21', '22', '24']:
                    acc_id = _mapping(f'inventory_{karat}k')
                    if acc_id:
                        inventory_accounts[karat] = acc_id

                # تحديد حساب المورد (يجب أن يتتبع الوزن دائماً)
                supplier_account_id = None
                if party_account and party_account.tracks_weight:
                    supplier_account_id = party_account.id
                else:
                    mapped_supplier = _mapping('suppliers')
                    supplier_account_id = mapped_supplier or (party_account.id if party_account else None)

                supplier_account_obj = Account.query.get(supplier_account_id) if supplier_account_id else None
                if supplier_account_obj and not supplier_account_obj.tracks_weight:
                    # نحاول الحصول على حساب مورد يتتبع الوزن من إعدادات الربط
                    alt_supplier_id = _mapping('suppliers')
                    if alt_supplier_id and alt_supplier_id != supplier_account_id:
                        alt_supplier_obj = Account.query.get(alt_supplier_id)
                        if alt_supplier_obj and alt_supplier_obj.tracks_weight:
                            supplier_account_id = alt_supplier_id
                            supplier_account_obj = alt_supplier_obj

                # إذا كان الحساب النهائي لا يتتبع الوزن، نستخدم party_account إن كان يدعم ذلك
                if supplier_account_obj is None or not supplier_account_obj.tracks_weight:
                    if party_account and party_account.tracks_weight:
                        supplier_account_id = party_account.id
                        supplier_account_obj = party_account
                    else:
                        supplier_account_id = None

                # تجميع أوزان المورد (يمكن تمريرها من الواجهة، وإلا نستخدم أوزان الأصناف)
                supplier_gold_lines = data.get('supplier_gold_lines') or data.get('supplier_gold_weights')
                supplier_gold_by_karat = {}

                if isinstance(supplier_gold_lines, list):
                    for line in supplier_gold_lines:
                        karat_key = _normalize_karat(line.get('karat'))
                        weight = _to_float(line.get('weight', 0), 0.0)
                        if not karat_key or weight <= 0:
                            continue
                        supplier_gold_by_karat[karat_key] = supplier_gold_by_karat.get(karat_key, 0.0) + weight
                elif isinstance(supplier_gold_lines, dict):
                    for karat, weight in supplier_gold_lines.items():
                        weight_val = _to_float(weight, 0.0)
                        if weight_val <= 0:
                            continue
                        karat_key = _normalize_karat(karat)
                        if not karat_key:
                            continue
                        supplier_gold_by_karat[karat_key] = supplier_gold_by_karat.get(karat_key, 0.0) + weight_val

                if not supplier_gold_by_karat:
                    supplier_gold_by_karat = {k: v for k, v in gold_by_karat.items() if v > 0}

                # حفظ إجمالي الذهب (عيار رئيسي) في الفاتورة للرجوع إليه لاحقاً
                supplier_gold_main = sum(
                    convert_to_main_karat(weight, int(round(float(karat))))
                    for karat, weight in supplier_gold_by_karat.items()
                )
                new_invoice.payment_gold_weight = round(supplier_gold_main, 3)
                new_invoice.payment_gold_karat = get_main_karat()

                # قراءة القيم النقدية من الطلب أو حسابها
                gold_tax_total = _to_float(data.get('gold_tax_total', 0), 0.0)
                wage_tax_total = _to_float(data.get('wage_tax_total', 0), 0.0)
                total_vat_source = (
                    data.get('vat_receivable_cash')
                    or data.get('total_tax')
                    or (gold_tax_total + wage_tax_total)
                    or new_invoice.total_tax
                    or 0
                )
                total_vat = _to_float(total_vat_source, 0.0)
                wage_cash = _to_float(
                    data.get('manufacturing_wage_cash')
                    or data.get('wage_cash')
                    or data.get('total_wage')
                    or data.get('wage_subtotal')
                    or 0
                , 0.0)

                valuation_cash_total = data.get('valuation_cash_total')
                if valuation_cash_total is None and isinstance(data.get('valuation'), dict):
                    valuation_cash_total = data['valuation'].get('cash_total')

                valuation_cash_total = _to_float(valuation_cash_total, None) if valuation_cash_total is not None else None
                if valuation_cash_total is None:
                    valuation_cash_total = _to_float(data.get('gold_subtotal', 0), None)
                if valuation_cash_total is None:
                    valuation_cash_total = new_invoice.total - wage_cash - total_vat
                valuation_cash_total = max(round(valuation_cash_total, 2), 0)

                # توزيع الوزن الخاص بالتقييم (يمكن أن يختلف عن الوزن الفعلي إن وجد)
                valuation_weights = {}
                raw_valuation_weights = None
                if isinstance(data.get('valuation_gold_weights'), dict):
                    raw_valuation_weights = data.get('valuation_gold_weights')
                elif isinstance(data.get('valuation'), dict) and isinstance(data['valuation'].get('weight_by_karat'), dict):
                    raw_valuation_weights = data['valuation'].get('weight_by_karat')

                if raw_valuation_weights:
                    for karat, weight in raw_valuation_weights.items():
                        weight_val = _to_float(weight, 0.0)
                        if weight_val <= 0:
                            continue
                        karat_key = _normalize_karat(karat)
                        if not karat_key:
                            continue
                        valuation_weights[karat_key] = weight_val
                else:
                    valuation_weights = {k: v for k, v in gold_by_karat.items() if v > 0}

                # إجمالي الوزن المستخدم للتوزيع النقدي
                total_weight_for_allocation = sum(
                    weight for karat, weight in valuation_weights.items()
                    if weight > 0 and str(karat) in inventory_accounts
                )

                cash_debit_booked = 0.0

                # --- 1) إثبات المخزون (نقد + وزن لكل عيار) ---
                if valuation_cash_total > 0 or total_weight_for_allocation > 0:
                    remaining_cash = valuation_cash_total
                    positive_karats = [k for k in valuation_weights if k in inventory_accounts and valuation_weights[k] > 0]

                    for index, karat in enumerate(positive_karats):
                        weight_value = valuation_weights[karat]
                        inv_account_id = inventory_accounts.get(karat)
                        if not inv_account_id:
                            continue

                        if total_weight_for_allocation > 0 and index < len(positive_karats) - 1:
                            cash_share = round(valuation_cash_total * (weight_value / total_weight_for_allocation), 2)
                            remaining_cash = round(remaining_cash - cash_share, 2)
                        else:
                            cash_share = max(round(remaining_cash, 2), 0)
                            remaining_cash = 0

                        weight_kwargs = {f'weight_{karat}k_debit': round(weight_value, 3)}

                        create_dual_journal_entry(
                            journal_entry_id=journal_entry.id,
                            account_id=inv_account_id,
                            cash_debit=cash_share if cash_share > 0 else 0,
                            **weight_kwargs,
                            description=f"إثبات مخزون عيار {karat} شراء من مورد"
                        )

                        cash_debit_booked = round(cash_debit_booked + max(cash_share, 0), 2)

                    # في حال لم يُسجَّل أي سطر (لعدم وجود أوزان)، ننشئ سطر نقدي واحد للمخزون
                    if not positive_karats and valuation_cash_total > 0 and inventory_accounts:
                        fallback_account_id = next(iter(inventory_accounts.values()))
                        create_dual_journal_entry(
                            journal_entry_id=journal_entry.id,
                            account_id=fallback_account_id,
                            cash_debit=valuation_cash_total,
                            description="إثبات مخزون شراء من مورد (بدون توزيع عيارات)"
                        )
                        cash_debit_booked = round(cash_debit_booked + valuation_cash_total, 2)

                # --- 2) أجور المصنعية (إن وجدت) ---
                if wage_cash > 0 and not wage_expense_acc_id:
                    wage_expense_acc_id = next(iter(inventory_accounts.values()), None)

                if wage_cash > 0 and wage_expense_acc_id:
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=wage_expense_acc_id,
                        cash_debit=round(wage_cash, 2),
                        description="أجور مصنعية شراء من مورد"
                    )
                    cash_debit_booked = round(cash_debit_booked + wage_cash, 2)

                # --- 3) ضريبة القيمة المضافة ---
                # ملاحظة: ضريبة الذهب تُضاف لقيمة المخزون، وضريبة الأجور تُسجل منفصلة
                # لذا نسجل فقط ضريبة الأجور كقيد مستقل
                if wage_tax_total > 0 and vat_receivable_acc_id:
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=vat_receivable_acc_id,
                        cash_debit=round(wage_tax_total, 2),
                        description="ضريبة على أجور المصنعية - مشتريات من مورد"
                    )
                    cash_debit_booked = round(cash_debit_booked + wage_tax_total, 2)
                
                # إذا كانت هناك ضريبة على الذهب، تُضاف للمخزون (مدرجة ضمن valuation_cash_total)
                if gold_tax_total > 0 and vat_receivable_acc_id:
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=vat_receivable_acc_id,
                        cash_debit=round(gold_tax_total, 2),
                        description="ضريبة على قيمة الذهب - مشتريات من مورد"
                    )
                    cash_debit_booked = round(cash_debit_booked + gold_tax_total, 2)

                # --- 4) الحساب الجسر: يثبت المبلغ النقدي المستحق للمورد ---
                # حساب الجسر يحمل كامل المبلغ النقدي (قيمة الذهب + الأجور + الضرائب)
                bridge_total_cash = round(cash_debit_booked, 2)
                if bridge_total_cash > 0:
                    create_dual_journal_entry(
                        journal_entry_id=journal_entry.id,
                        account_id=bridge_acc_id,
                        cash_credit=bridge_total_cash,
                        description="جسر تقييم المورد (مستحق نقدي)"
                    )

                # --- 5) المورد دائن بالذهب (حسب العيارات) ---
                if not supplier_account_id and supplier_gold_by_karat:
                    fallback_candidates = [
                        get_account_id_for_mapping('شراء من مورد', 'suppliers_weight'),
                        get_account_id_for_mapping('شراء', 'suppliers_weight'),
                        get_account_id_for_mapping('شراء من مورد', 'suppliers'),
                        get_account_id_for_mapping('شراء', 'suppliers'),
                        party_account.id if party_account and party_account.tracks_weight else None,
                    ]

                    for candidate_id in fallback_candidates:
                        if not candidate_id:
                            continue
                        candidate_account = Account.query.get(candidate_id)
                        if candidate_account and candidate_account.tracks_weight:
                            supplier_account_id = candidate_id
                            supplier_account_obj = candidate_account
                            break

                if supplier_gold_by_karat and (not supplier_account_obj or not supplier_account_obj.tracks_weight):
                    return jsonify({
                        'error': 'إعدادات الربط المحاسبي للمورد لا تتتبع الوزن. يرجى ضبط حساب مورد يتتبع الوزن ضمن الربط "suppliers" أو "suppliers_weight".'
                    }), 400

                if supplier_account_id and supplier_gold_by_karat:
                    supplier_weight_kwargs = {
                        f'weight_{karat}k_credit': round(weight, 3)
                        for karat, weight in supplier_gold_by_karat.items()
                        if weight > 0 and f'weight_{karat}k_credit' in dual_entry_params
                    }

                    # إن لم تُطابق أسماء الوسائط (عيار غير مدعوم)، نحاول تحويله إلى العيار الرئيسي
                    unsupported_karats = [
                        karat for karat in supplier_gold_by_karat
                        if f'weight_{karat}k_credit' not in dual_entry_params
                    ]

                    additional_21k = 0.0
                    for karat in unsupported_karats:
                        weight = supplier_gold_by_karat.get(karat, 0)
                        additional_21k += convert_to_main_karat(weight, int(round(float(karat))))

                    if additional_21k > 0:
                        supplier_weight_kwargs['weight_21k_credit'] = round(
                            supplier_weight_kwargs.get('weight_21k_credit', 0.0) + additional_21k,
                            3
                        )

                    if supplier_weight_kwargs:
                        create_dual_journal_entry(
                            journal_entry_id=journal_entry.id,
                            account_id=supplier_account_id,
                            **supplier_weight_kwargs,
                            description="رصيد مورد بالذهب"
                        )

            else:
                return jsonify({
                    'error': 'لم يتم تهيئة حساب الجسر لمشتريات الموردين، يرجى ضبط mapping "supplier_bridge" أو حساب المورد النقدي.'
                }), 400
        
        elif invoice_type == 'مرتجع شراء من مورد':
            # 6. مرتجع شراء من مورد (عكس الشراء)
            # من حـ/ المورد (أو الصندوق) [مدين]
            #     إلى حـ/ المخزون [دائن]
            
            # 🔥 استخدام الربط المحاسبي (نفس إعدادات "شراء")
            cash_acc_id = get_account_id_for_mapping('شراء', 'cash')
            suppliers_acc_id = get_account_id_for_mapping('شراء', 'suppliers')
            
            # حسابات المخزون
            inventory_acc_id = None
            for karat in ['18', '21', '22', '24']:
                inv_acc_id = get_account_id_for_mapping('شراء', f'inventory_{karat}k')
                if inv_acc_id:
                    inventory_acc_id = inv_acc_id
                    break
            
            # Line 1: مدين المورد/الصندوق
            acc_id = suppliers_acc_id or cash_acc_id or party_account.id
            create_dual_journal_entry(
                journal_entry_id=journal_entry.id,
                account_id=acc_id,
                cash_debit=total_cash,
                **{f"weight_{k}k_debit": v for k, v in gold_by_karat.items() if v > 0},
                description="استلام نقدي من مرتجع شراء"
            )
            
            # Line 2: دائن المخزون
            if inventory_acc_id:
                create_dual_journal_entry(
                    journal_entry_id=journal_entry.id,
                    account_id=inventory_acc_id,
                    cash_credit=total_cash,
                    **{f"weight_{k}k_credit": v for k, v in gold_by_karat.items() if v > 0},
                    description="خصم من المخزون (مرتجع)"
                )

        # --- 6. Verify Dual Balance Before Commit ---
        db.session.flush()  # Ensure all entries are in DB before verification
        print(f"🔍 Verifying dual balance for journal entry #{journal_entry.id}...")
        balance_check = verify_dual_balance(journal_entry.id)
        print(f"Balance check result: {balance_check}")
        if not balance_check['balanced']:
            db.session.rollback()
            error_msg = f"Journal entry is not balanced: {', '.join(balance_check['errors'])}"
            print(f"❌ Balance Error: {error_msg}")
            return jsonify({'error': error_msg, 'balance_details': balance_check}), 400

        # --- 7. Mark as Posted and Commit ---
        print(f"✅ Balance verified! Marking invoice and journal entry as posted...")
        new_invoice.is_posted = True
        journal_entry.is_posted = True
        
        print(f"✅ Committing transaction...")
        db.session.commit()
        return jsonify(new_invoice.to_dict()), 201

    except (ValueError, IntegrityError) as e:
        db.session.rollback()
        # Log the error for debugging
        print(f"Error adding invoice: {str(e)}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': 'Failed to create invoice', 'detail': str(e)}), 500
    except Exception as e:
        db.session.rollback()
        print(f"An unexpected error occurred: {str(e)}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': 'An unexpected server error occurred.'}), 500

@api.route('/accounts', methods=['GET'])
def get_accounts():
    """
    الحصول على جميع الحسابات مع دعم الهيكل الهرمي (parent-child)
    """
    accounts = Account.query.all()
    
    result = []
    for acc in accounts:
        # استخدام to_dict() من Model
        account_dict = acc.to_dict()
        
        # إضافة معلومات الحساب الأب إن وجد
        if acc.parent_id:
            parent = Account.query.get(acc.parent_id)
            if parent:
                account_dict['parent_account'] = {
                    'id': parent.id,
                    'account_number': parent.account_number,
                    'name': parent.name
                }
        
        # إضافة الحسابات الفرعية
        children = Account.query.filter_by(parent_id=acc.id).all()
        if children:
            account_dict['sub_accounts'] = [{
                'id': child.id,
                'account_number': child.account_number,
                'name': child.name,
                'bank_name': child.bank_name,
                'account_number_external': child.account_number_external
            } for child in children]
        
        result.append(account_dict)
    
    return jsonify(result)


@api.route('/accounts/balances', methods=['GET'])
def get_accounts_balances():
    """
    الحصول على أرصدة جميع الحسابات (Cash + Gold) دفعة واحدة
    """
    # جلب جميع الحسابات
    accounts = Account.query.all()
    
    balances = {}
    
    for acc in accounts:
        # حساب الأرصدة من journal_entry_line
        account_lines = db.session.query(
            func.sum(JournalEntryLine.cash_debit - JournalEntryLine.cash_credit).label('balance_cash'),
            func.sum(JournalEntryLine.debit_18k - JournalEntryLine.credit_18k).label('balance_18k'),
            func.sum(JournalEntryLine.debit_21k - JournalEntryLine.credit_21k).label('balance_21k'),
            func.sum(JournalEntryLine.debit_22k - JournalEntryLine.credit_22k).label('balance_22k'),
            func.sum(JournalEntryLine.debit_24k - JournalEntryLine.credit_24k).label('balance_24k')
        ).filter(
            JournalEntryLine.account_id == acc.id,
            JournalEntryLine.is_deleted == False
        ).first()
        
        # تحويل None إلى 0
        balance_cash = account_lines.balance_cash or 0.0
        balance_18k = account_lines.balance_18k or 0.0
        balance_21k = account_lines.balance_21k or 0.0
        balance_22k = account_lines.balance_22k or 0.0
        balance_24k = account_lines.balance_24k or 0.0
        
        # حفظ الأرصدة
        balances[acc.id] = {
            'account_id': acc.id,
            'account_number': acc.account_number,
            'account_name': acc.name,
            'cash': round(balance_cash, 2),
            'gold_18k': round(balance_18k, 3),
            'gold_21k': round(balance_21k, 3),
            'gold_22k': round(balance_22k, 3),
            'gold_24k': round(balance_24k, 3),
            'has_balance': abs(balance_cash) > 0.01 or abs(balance_18k) > 0.001 or abs(balance_21k) > 0.001 or abs(balance_22k) > 0.001 or abs(balance_24k) > 0.001
        }
    
    return jsonify(balances)


@api.route('/accounts/hierarchy', methods=['GET'])
def get_accounts_hierarchy():
    """
    الحصول على شجرة الحسابات في شكل هرمي (tree structure)
    """
    # الحصول على الحسابات الرئيسية فقط (بدون parent)
    root_accounts = Account.query.filter_by(parent_id=None).all()
    
    def build_tree(account):
        """بناء شجرة الحسابات بشكل recursive"""
        node = {
            'id': account.id,
            'account_number': account.account_number,
            'name': account.name,
            'type': account.type,
            'transaction_type': account.transaction_type,
            'children': []
        }
        
        # الحصول على الحسابات الفرعية
        children = Account.query.filter_by(parent_id=account.id).all()
        for child in children:
            node['children'].append(build_tree(child))
        
        return node
    
    tree = [build_tree(acc) for acc in root_accounts]
    
    return jsonify({
        'accounts_tree': tree,
        'total_accounts': Account.query.count()
    })

# 🆕 Endpoints للمرتجعات
@api.route('/invoices/<int:invoice_id>/returns', methods=['GET'])
def get_invoice_returns(invoice_id):
    """
    الحصول على جميع المرتجعات المرتبطة بفاتورة معينة
    """
    invoice = Invoice.query.get_or_404(invoice_id)
    
    # الحصول على جميع المرتجعات
    returns = Invoice.query.filter_by(original_invoice_id=invoice_id).all()
    
    return jsonify({
        'original_invoice': {
            'id': invoice.id,
            'invoice_type_id': invoice.invoice_type_id,
            'invoice_type': invoice.invoice_type,
            'date': invoice.date.isoformat(),
            'total': invoice.total,
            'status': invoice.status
        },
        'returns': [r.to_dict() for r in returns],
        'total_returns': len(returns)
    })

@api.route('/invoices/<int:invoice_id>/can-return', methods=['GET'])
def check_can_return(invoice_id):
    """
    التحقق من إمكانية إرجاع فاتورة
    """
    invoice = Invoice.query.get_or_404(invoice_id)
    
    # الفواتير التي يمكن إرجاعها
    returnable_types = ['بيع', 'شراء من عميل', 'شراء من مورد']
    
    can_return = invoice.invoice_type in returnable_types
    
    # التحقق من المرتجعات السابقة
    existing_returns = Invoice.query.filter_by(original_invoice_id=invoice_id).all()
    total_returned = sum(r.total for r in existing_returns)
    
    return jsonify({
        'can_return': can_return,
        'invoice_type': invoice.invoice_type,
        'original_total': invoice.total,
        'total_returned': total_returned,
        'remaining_amount': invoice.total - total_returned,
        'existing_returns_count': len(existing_returns),
        'message': 'يمكن إرجاع هذه الفاتورة' if can_return else 'لا يمكن إرجاع هذا النوع من الفواتير'
    })

@api.route('/invoices/returnable', methods=['GET'])
def get_returnable_invoices():
    """
    الحصول على جميع الفواتير القابلة للإرجاع
    """
    # الأنواع القابلة للإرجاع
    returnable_types = ['بيع', 'شراء من عميل', 'شراء من مورد']
    
    # فلترة حسب النوع إذا تم تحديده
    invoice_type_filter = request.args.get('invoice_type')
    customer_id = request.args.get('customer_id', type=int)
    supplier_id = request.args.get('supplier_id', type=int)
    
    query = Invoice.query.filter(Invoice.invoice_type.in_(returnable_types))
    
    if invoice_type_filter:
        query = query.filter_by(invoice_type=invoice_type_filter)
    
    if customer_id:
        query = query.filter_by(customer_id=customer_id)
    
    if supplier_id:
        query = query.filter_by(supplier_id=supplier_id)
    
    invoices = query.order_by(Invoice.date.desc()).all()
    
    result = []
    for inv in invoices:
        # حساب المرتجعات الموجودة
        existing_returns = Invoice.query.filter_by(original_invoice_id=inv.id).all()
        total_returned = sum(r.total for r in existing_returns)
        
        result.append({
            'id': inv.id,
            'invoice_type_id': inv.invoice_type_id,
            'invoice_type': inv.invoice_type,
            'date': inv.date.isoformat(),
            'total': inv.total,
            'total_returned': total_returned,
            'remaining_amount': inv.total - total_returned,
            'can_return': (inv.total - total_returned) > 0,
            'customer_name': inv.customer.name if inv.customer else None,
            'supplier_name': inv.supplier.name if inv.supplier else None,
            'items_count': len(inv.items)
        })
    
    return jsonify({
        'invoices': result,
        'total_count': len(result)
    })

@api.route('/accounts/next-number/<parent_number>', methods=['GET'])
def get_next_account_number_api(parent_number):
    """
    API endpoint للحصول على رقم الحساب التالي المتاح
    
    Args:
        parent_number: رقم الحساب الأب (مثل '1100' لعملاء بيع الذهب)
        
    Returns:
        JSON: {'suggested_number': 'XXXXXX', 'is_valid': True, ...}
    """
    try:
        from account_number_generator import suggest_account_number_with_validation
        
        result = suggest_account_number_with_validation(parent_number)
        return jsonify(result), 200
        
    except Exception as e:
        return jsonify({
            'suggested_number': None,
            'is_valid': False,
            'message': f'خطأ: {str(e)}'
        }), 400

@api.route('/accounts/validate-number', methods=['POST'])
def validate_account_number_api():
    """
    API endpoint للتحقق من صحة رقم حساب
    
    Body:
        {
            "account_number": "110000",
            "parent_account_number": "1100"
        }
        
    Returns:
        JSON: {'is_valid': True/False, 'message': '...'}
    """
    try:
        from account_number_generator import validate_account_number
        
        data = request.json
        account_number = data.get('account_number')
        parent_account_number = data.get('parent_account_number')
        
        if not account_number or not parent_account_number:
            return jsonify({
                'is_valid': False,
                'message': 'يجب تقديم رقم الحساب ورقم الحساب الأب'
            }), 400
        
        result = validate_account_number(account_number, parent_account_number)
        return jsonify(result), 200
        
    except Exception as e:
        return jsonify({
            'is_valid': False,
            'message': f'خطأ: {str(e)}'
        }), 400

@api.route('/accounts/capacity/<category_number>', methods=['GET'])
def get_account_capacity_api(category_number):
    """
    API endpoint للحصول على معلومات السعة لفئة حسابات
    
    Args:
        category_number: رقم الفئة (مثل '1100' لعملاء بيع الذهب)
        
    Returns:
        JSON: معلومات السعة المتاحة والمستخدمة
    """
    try:
        from account_number_generator import get_customer_account_capacity
        
        result = get_customer_account_capacity(category_number)
        return jsonify(result), 200
        
    except Exception as e:
        return jsonify({
            'error': f'خطأ: {str(e)}'
        }), 400

@api.route('/accounts', methods=['POST'])
def add_account():
    data = request.json
    new_account = Account(
        account_number=data['account_number'],
        name=data['name'],
        type=data['type'],
        parent_id=data.get('parent_id'),
        transaction_type=data.get('transaction_type', 'both'),
        bank_name=data.get('bank_name'),
        account_number_external=data.get('account_number_external'),
        account_type=data.get('account_type')
    )
    db.session.add(new_account)
    db.session.commit()
    return jsonify(new_account.to_dict()), 201

@api.route('/accounts/<int:id>', methods=['PUT'])
def update_account(id):
    account = Account.query.get_or_404(id)
    data = request.json
    account.account_number = data.get('account_number', account.account_number)
    account.name = data.get('name', account.name)
    account.type = data.get('type', account.type)
    account.parent_id = data.get('parent_id', account.parent_id)
    account.transaction_type = data.get('transaction_type', account.transaction_type)
    
    # 🆕 تحديث معلومات البنك
    if 'bank_name' in data:
        account.bank_name = data['bank_name']
    if 'account_number_external' in data:
        account.account_number_external = data['account_number_external']
    if 'account_type' in data:
        account.account_type = data['account_type']
    
    db.session.commit()
    return jsonify(account.to_dict())

@api.route('/accounts/<int:id>', methods=['DELETE'])
def delete_account(id):
    account = Account.query.get_or_404(id)
    db.session.delete(account)
    db.session.commit()
    return jsonify({'result': 'success'})

# Journal Entries CRUD
@api.route('/journal_entries', methods=['GET'])
def get_journal_entries():
    # إخفاء القيود المحذوفة افتراضياً
    entries = JournalEntry.query.filter_by(is_deleted=False).order_by(JournalEntry.date.desc()).all()
    result = []
    for entry in entries:
        lines = []
        for line in entry.lines:
            if not line.is_deleted:  # تخطي الأسطر المحذوفة
                # التعامل مع الحسابات المحذوفة
                account_name = line.account.name if line.account else f'حساب محذوف (ID: {line.account_id})'
                
                lines.append({
                    'id': line.id,
                    'account_id': line.account_id,
                    'account_name': account_name,
                    'cash_debit': line.cash_debit,
                    'cash_credit': line.cash_credit,
                    'debit_18k': line.debit_18k,
                'credit_18k': line.credit_18k,
                'debit_21k': line.debit_21k,
                'credit_21k': line.credit_21k,
                'debit_22k': line.debit_22k,
                'credit_22k': line.credit_22k,
                'debit_24k': line.debit_24k,
                'credit_24k': line.credit_24k,
            })
        result.append({
            'id': entry.id,
            'date': entry.date.isoformat(),
            'description': entry.description,
            'lines': lines
        })
    return jsonify(result)

def get_main_karat():
    settings = Settings.query.first()
    return settings.main_karat if settings else 21

def convert_to_main_karat(weight, karat):
    main_karat = get_main_karat()
    if karat == 0 or main_karat == 0:
        return 0
    return (weight * karat) / main_karat

def convert_from_main_karat(weight, karat):
    main_karat = get_main_karat()
    if karat == 0:
        return 0
    return (weight * main_karat) / karat

@api.route('/journal_entries', methods=['POST'])
def add_journal_entry():
    data = request.get_json()
    lines_data = data.get('lines', [])

    # --- Pre-validation ---
    # Filter out completely empty lines first
    lines_data = [
        line for line in lines_data if any([
            line.get('cash_debit', 0), line.get('cash_credit', 0),
            line.get('debit_18k', 0), line.get('credit_18k', 0),
            line.get('debit_21k', 0), line.get('credit_21k', 0),
            line.get('debit_22k', 0), line.get('credit_22k', 0),
            line.get('debit_24k', 0), line.get('credit_24k', 0)
        ]) or line.get('account_id')
    ]

    # Check if any line with data is missing an account
    for line in lines_data:
        has_values = any([
            line.get('cash_debit', 0), line.get('cash_credit', 0),
            line.get('debit_18k', 0), line.get('credit_18k', 0),
            line.get('debit_21k', 0), line.get('credit_21k', 0),
            line.get('debit_22k', 0), line.get('credit_22k', 0),
            line.get('debit_24k', 0), line.get('credit_24k', 0)
        ])
        if has_values and not line.get('account_id'):
            return jsonify({'error': 'Each line must have an associated account.'}), 400

    if not lines_data or len(lines_data) < 2:
        return jsonify({'error': 'يجب أن يحتوي قيد اليومية على سطرين على الأقل.'}), 400

    # --- Balance Validation ---
    total_cash_debit = sum(line.get('cash_debit', 0) for line in lines_data)
    total_cash_credit = sum(line.get('cash_credit', 0) for line in lines_data)

    if round(total_cash_debit, 3) != round(total_cash_credit, 3):
        return jsonify({'error': 'Cash debits and credits must be balanced.'}), 400

    # --- Gold Balance Calculation and Auto-Balancing ---
    total_gold_debit_normalized = sum(
        convert_to_main_karat(line.get('debit_18k', 0), 18) +
        convert_to_main_karat(line.get('debit_21k', 0), 21) +
        convert_to_main_karat(line.get('debit_22k', 0), 22) +
        convert_to_main_karat(line.get('debit_24k', 0), 24)
        for line in lines_data
    )
    total_gold_credit_normalized = sum(
        convert_to_main_karat(line.get('credit_18k', 0), 18) +
        convert_to_main_karat(line.get('credit_21k', 0), 21) +
        convert_to_main_karat(line.get('credit_22k', 0), 22) +
        convert_to_main_karat(line.get('credit_24k', 0), 24)
        for line in lines_data
    )

    gold_difference = total_gold_debit_normalized - total_gold_credit_normalized

    # Auto-balance if the difference is negligible (less than 0.01)
    if 0 < abs(gold_difference) < 0.01:
        adjustment_applied = False
        # If debit is greater, increase a credit line
        if gold_difference > 0:
            for line in lines_data:
                # Find a line with any credit amount to adjust
                if any(line.get(f'credit_{k}k', 0) > 0 for k in [18, 21, 22, 24]):
                    # Adjust the first available credit karat (prefer 21k)
                    if line.get('credit_21k', 0) > 0:
                        line['credit_21k'] += convert_from_main_karat(gold_difference, 21)
                    elif line.get('credit_18k', 0) > 0:
                        line['credit_18k'] += convert_from_main_karat(gold_difference, 18)
                    elif line.get('credit_22k', 0) > 0:
                        line['credit_22k'] += convert_from_main_karat(gold_difference, 22)
                    elif line.get('credit_24k', 0) > 0:
                        line['credit_24k'] += convert_from_main_karat(gold_difference, 24)
                    adjustment_applied = True
                    break
        # If credit is greater, increase a debit line
        else: # gold_difference < 0
            for line in lines_data:
                # Find a line with any debit amount to adjust
                if any(line.get(f'debit_{k}k', 0) > 0 for k in [18, 21, 22, 24]):
                    # Adjust the first available debit karat (prefer 21k)
                    if line.get('debit_21k', 0) > 0:
                        line['debit_21k'] -= convert_from_main_karat(gold_difference, 21) # subtract negative diff
                    elif line.get('debit_18k', 0) > 0:
                        line['debit_18k'] -= convert_from_main_karat(gold_difference, 18)
                    elif line.get('debit_22k', 0) > 0:
                        line['debit_22k'] -= convert_from_main_karat(gold_difference, 22)
                    elif line.get('debit_24k', 0) > 0:
                        line['debit_24k'] -= convert_from_main_karat(gold_difference, 24)
                    adjustment_applied = True
                    break
        
        # Recalculate totals if an adjustment was made
        if adjustment_applied:
            total_gold_debit_normalized = sum(
                convert_to_main_karat(line.get('debit_18k', 0), 18) +
                convert_to_main_karat(line.get('debit_21k', 0), 21) +
                convert_to_main_karat(line.get('debit_22k', 0), 22) +
                convert_to_main_karat(line.get('debit_24k', 0), 24)
                for line in lines_data
            )
            total_gold_credit_normalized = sum(
                convert_to_main_karat(line.get('credit_18k', 0), 18) +
                convert_to_main_karat(line.get('credit_21k', 0), 21) +
                convert_to_main_karat(line.get('credit_22k', 0), 22) +
                convert_to_main_karat(line.get('credit_24k', 0), 24)
                for line in lines_data
            )

    # Final check for gold balance after potential auto-balancing
    if round(total_gold_debit_normalized, 3) != round(total_gold_credit_normalized, 3):
        return jsonify({'error': f'Gold debits and credits must be balanced when normalized to main karat. Debit: {total_gold_debit_normalized}, Credit: {total_gold_credit_normalized}'}), 400
    # --- End Balance Validation ---

    try:
        new_entry = JournalEntry(
            date=datetime.fromisoformat(data['date']),
            description=data['description']
        )
        db.session.add(new_entry)
        db.session.flush() # Get the ID for the lines

        for line_data in lines_data:
            new_line = JournalEntryLine(
                journal_entry_id=new_entry.id,
                account_id=line_data['account_id'],
                cash_debit=line_data.get('cash_debit', 0),
                cash_credit=line_data.get('cash_credit', 0),
                debit_18k=line_data.get('debit_18k', 0),
                credit_18k=line_data.get('credit_18k', 0),
                debit_21k=line_data.get('debit_21k', 0),
                credit_21k=line_data.get('credit_21k', 0),
                debit_22k=line_data.get('debit_22k', 0),
                credit_22k=line_data.get('credit_22k', 0),
                debit_24k=line_data.get('debit_24k', 0),
                credit_24k=line_data.get('credit_24k', 0)
            )
            db.session.add(new_line)

        db.session.commit()
        return jsonify(new_entry.to_dict()), 201
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'Failed to save journal entry', 'details': str(e)}), 500

@api.route('/journal_entries/<int:id>', methods=['GET'])
def get_journal_entry(id):
    entry = JournalEntry.query.get_or_404(id)
    lines = []
    for line in entry.lines:
        lines.append({
            'id': line.id,
            'account_id': line.account_id,
            'account_name': line.account.name if line.account else 'Unknown Account',
            'cash_debit': line.cash_debit,
            'cash_credit': line.cash_credit,
            'debit_18k': line.debit_18k,
            'credit_18k': line.credit_18k,
            'debit_21k': line.debit_21k,
            'credit_21k': line.credit_21k,
            'debit_22k': line.debit_22k,
            'credit_22k': line.credit_22k,
            'debit_24k': line.debit_24k,
            'credit_24k': line.credit_24k,
        })
    return jsonify({
        'id': entry.id,
        'date': entry.date.isoformat(),
        'description': entry.description,
        'lines': lines
    })

@api.route('/journal_entries/<int:id>', methods=['PUT'])
def update_journal_entry(id):
    entry = JournalEntry.query.get_or_404(id)
    data = request.get_json()

    if not data.get('lines') or len(data.get('lines')) < 2:
        return jsonify({'error': 'A journal entry must have at least two lines.'}), 400

    # --- Balance Validation ---
    total_cash_debit = sum(line.get('cash_debit', 0) for line in data['lines'])
    total_cash_credit = sum(line.get('cash_credit', 0) for line in data['lines'])

    if round(total_cash_debit, 3) != round(total_cash_credit, 3):
        return jsonify({'error': 'Cash debits and credits must be balanced.'}), 400

    total_gold_debit_normalized = sum(
        convert_to_main_karat(line.get('debit_18k', 0), 18) +
        convert_to_main_karat(line.get('debit_21k', 0), 21) +
        convert_to_main_karat(line.get('debit_22k', 0), 22) +
        convert_to_main_karat(line.get('debit_24k', 0), 24)
        for line in data['lines']
    )
    total_gold_credit_normalized = sum(
        convert_to_main_karat(line.get('credit_18k', 0), 18) +
        convert_to_main_karat(line.get('credit_21k', 0), 21) +
        convert_to_main_karat(line.get('credit_22k', 0), 22) +
        convert_to_main_karat(line.get('credit_24k', 0), 24)
        for line in data['lines']
    )

    if round(total_gold_debit_normalized, 3) != round(total_gold_credit_normalized, 3):
        return jsonify({'error': f'Gold debits and credits must be balanced when normalized to main karat. Debit: {total_gold_debit_normalized}, Credit: {total_gold_credit_normalized}'}), 400
    # --- End Balance Validation ---

    try:
        entry.date = datetime.fromisoformat(data['date'])
        entry.description = data['description']

        # Remove old lines
        for line in entry.lines:
            db.session.delete(line)

        # Add new lines
        for line_data in data['lines']:
            new_line = JournalEntryLine(
                journal_entry_id=entry.id,
                account_id=line_data['account_id'],
                cash_debit=line_data.get('cash_debit', 0),
                cash_credit=line_data.get('cash_credit', 0),
                debit_18k=line_data.get('debit_18k', 0),
                credit_18k=line_data.get('credit_18k', 0),
                debit_21k=line_data.get('debit_21k', 0),
                credit_21k=line_data.get('credit_21k', 0),
                debit_22k=line_data.get('debit_22k', 0),
                credit_22k=line_data.get('credit_22k', 0),
                debit_24k=line_data.get('debit_24k', 0),
                credit_24k=line_data.get('credit_24k', 0),
            )
            db.session.add(new_line)

        db.session.commit()
        return jsonify({'result': 'success'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'Failed to update journal entry', 'detail': str(e)}), 500

# ===== نظام الحذف الآمن (Soft Delete) =====

@api.route('/journal_entries/<int:id>/soft_delete', methods=['POST'])
def soft_delete_journal_entry(id):
    """حذف ناعم للقيد مع تسجيل المعلومات"""
    entry = JournalEntry.query.get_or_404(id)
    
    # التحقق من أن القيد غير محذوف مسبقاً
    if entry.is_deleted:
        return jsonify({'error': 'القيد محذوف مسبقاً'}), 400
    
    data = request.get_json() or {}
    deleted_by = data.get('deleted_by', 'غير محدد')
    reason = data.get('reason', '')
    
    try:
        # تطبيق الحذف الناعم
        entry.soft_delete(deleted_by, reason)
        
        # حذف ناعم للأسطر المرتبطة
        from datetime import datetime
        for line in entry.lines:
            line.is_deleted = True
            line.deleted_at = datetime.now()
        
        db.session.commit()
        
        return jsonify({
            'result': 'success',
            'message': 'تم حذف القيد بنجاح (يمكن الاسترجاع)',
            'can_restore': True,
            'deleted_at': entry.deleted_at.isoformat(),
            'deleted_by': entry.deleted_by
        })
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'فشل حذف القيد', 'detail': str(e)}), 500

@api.route('/journal_entries/<int:id>/restore', methods=['POST'])
def restore_journal_entry(id):
    """استرجاع قيد محذوف"""
    entry = JournalEntry.query.filter_by(id=id, is_deleted=True).first_or_404()
    
    data = request.get_json() or {}
    restored_by = data.get('restored_by', 'غير محدد')
    
    try:
        # استرجاع القيد
        entry.restore(restored_by)
        
        # استرجاع الأسطر
        for line in entry.lines:
            line.is_deleted = False
            line.deleted_at = None
        
        db.session.commit()
        
        return jsonify({
            'result': 'success',
            'message': 'تم استرجاع القيد بنجاح',
            'restored_at': entry.restored_at.isoformat(),
            'restored_by': entry.restored_by
        })
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'فشل استرجاع القيد', 'detail': str(e)}), 500

@api.route('/journal_entries/deleted', methods=['GET'])
def get_deleted_journal_entries():
    """عرض القيود المحذوفة"""
    entries = JournalEntry.query.filter_by(is_deleted=True).order_by(JournalEntry.deleted_at.desc()).all()
    return jsonify([entry.to_dict(include_deleted_info=True) for entry in entries])

@api.route('/journal_entries/<int:id>', methods=['DELETE'])
def delete_journal_entry(id):
    """حذف نهائي للقيد (Hard Delete) - للاستخدام الإداري فقط"""
    entry = JournalEntry.query.get_or_404(id)
    try:
        db.session.delete(entry)
        db.session.commit()
        return jsonify({'result': 'success', 'message': 'تم الحذف النهائي للقيد'})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': 'Failed to delete journal entry', 'detail': str(e)}), 500



# ============================================================================
# Reports API - Sales Overview
# ============================================================================

@api.route('/reports/sales_overview', methods=['GET'])
def get_sales_overview_report():
    """تقرير ملخص المبيعات وفق النظام الوزني"""
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    group_by = (request.args.get('group_by') or 'day').lower()
    if group_by not in {'day', 'month', 'year'}:
        group_by = 'day'
    include_unposted = (request.args.get('include_unposted', 'false').lower() == 'true')
    gold_type_filter = request.args.get('gold_type')

    try:
        start_dt = None
        end_dt = None

        if start_date:
            start_value = _parse_iso_date(start_date, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date:
            end_value = _parse_iso_date(end_date, 'end_date')
            # استخدم < end_dt لتجنب مشاكل المناطق الزمنية
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)

    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    sale_types = {
        'بيع': 1,
        'مرتجع بيع': -1,
    }

    filters = [Invoice.invoice_type.in_(sale_types.keys())]

    if not include_unposted:
        filters.append(Invoice.is_posted.is_(True))

    if gold_type_filter:
        filters.append(Invoice.gold_type == gold_type_filter)

    if start_dt:
        filters.append(Invoice.date >= start_dt)

    if end_dt:
        filters.append(Invoice.date < end_dt)

    invoices = (
        Invoice.query
        .filter(*filters)
        .order_by(Invoice.date.asc())
        .all()
    )

    summary = {
        'total_documents': len(invoices),
        'net_sales_value': 0.0,
        'gross_sales_value': 0.0,
        'returns_value': 0.0,
        'net_gold_weight': 0.0,
        'gross_gold_weight': 0.0,
        'returns_count': 0,
        'average_invoice_value': 0.0,
        'average_gold_weight': 0.0,
        'by_gold_type': {},
    }

    series_map = defaultdict(lambda: {
        'period': '',
        'documents': 0,
        'net_value': 0.0,
        'net_weight': 0.0,
        'sales_value': 0.0,
        'sales_weight': 0.0,
        'returns_value': 0.0,
        'returns_weight': 0.0,
        'returns_count': 0,
    })

    gold_type_map = defaultdict(lambda: {
        'count': 0,
        'net_value': 0.0,
        'net_weight': 0.0,
        'sales_value': 0.0,
        'returns_value': 0.0,
    })

    for invoice in invoices:
        sign = sale_types.get(invoice.invoice_type, 1)
        total_value = float(invoice.total or 0.0)
        total_weight = float(invoice.total_weight or 0.0)

        net_value = total_value * sign
        net_weight = total_weight * sign

        summary['net_sales_value'] += net_value
        summary['net_gold_weight'] += net_weight

        if sign > 0:
            summary['gross_sales_value'] += total_value
            summary['gross_gold_weight'] += total_weight
        else:
            summary['returns_count'] += 1
            summary['returns_value'] += total_value

        period_source = invoice.date or datetime.utcnow()
        if group_by == 'year':
            period_key = period_source.strftime('%Y')
        elif group_by == 'month':
            period_key = period_source.strftime('%Y-%m')
        else:
            period_key = period_source.strftime('%Y-%m-%d')

        bucket = series_map[period_key]
        bucket['period'] = period_key
        bucket['documents'] += 1
        bucket['net_value'] += net_value
        bucket['net_weight'] += net_weight

        if sign > 0:
            bucket['sales_value'] += total_value
            bucket['sales_weight'] += total_weight
        else:
            bucket['returns_value'] += total_value
            bucket['returns_weight'] += total_weight
            bucket['returns_count'] += 1

        gold_key = (invoice.gold_type or 'unspecified').lower()
        gold_entry = gold_type_map[gold_key]
        gold_entry['count'] += 1
        gold_entry['net_value'] += net_value
        gold_entry['net_weight'] += net_weight
        if sign > 0:
            gold_entry['sales_value'] += total_value
        else:
            gold_entry['returns_value'] += total_value

    if summary['total_documents'] > 0:
        summary['average_invoice_value'] = summary['gross_sales_value'] / summary['total_documents']
        summary['average_gold_weight'] = summary['gross_gold_weight'] / summary['total_documents']

    # تقريب القيم النقدية والوزنية
    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    summary['net_sales_value'] = round_money(summary['net_sales_value'])
    summary['gross_sales_value'] = round_money(summary['gross_sales_value'])
    summary['returns_value'] = round_money(summary['returns_value'])
    summary['average_invoice_value'] = round_money(summary['average_invoice_value'])
    summary['net_gold_weight'] = round_weight(summary['net_gold_weight'])
    summary['gross_gold_weight'] = round_weight(summary['gross_gold_weight'])
    summary['average_gold_weight'] = round_weight(summary['average_gold_weight'])

    summary['by_gold_type'] = {
        gold_type: {
            'count': data['count'],
            'net_value': round_money(data['net_value']),
            'net_weight': round_weight(data['net_weight']),
            'sales_value': round_money(data['sales_value']),
            'returns_value': round_money(data['returns_value']),
        }
        for gold_type, data in gold_type_map.items()
    }

    series = sorted(series_map.values(), key=lambda item: item['period'])
    for row in series:
        row['net_value'] = round_money(row['net_value'])
        row['sales_value'] = round_money(row['sales_value'])
        row['returns_value'] = round_money(row['returns_value'])
        row['net_weight'] = round_weight(row['net_weight'])
        row['sales_weight'] = round_weight(row['sales_weight'])
        row['returns_weight'] = round_weight(row['returns_weight'])

    sales_case = case((Invoice.invoice_type == 'مرتجع بيع', -1), else_=1)

    top_customers_rows = (
        db.session.query(
            Customer.id,
            Customer.name,
            func.count(Invoice.id).label('documents'),
            func.coalesce(func.sum(func.coalesce(Invoice.total, 0) * sales_case), 0).label('net_value'),
            func.coalesce(func.sum(func.coalesce(Invoice.total_weight, 0) * sales_case), 0).label('net_weight'),
        )
        .join(Customer, Invoice.customer_id == Customer.id)
        .filter(*filters, Invoice.customer_id.isnot(None))
        .group_by(Customer.id, Customer.name)
        .order_by(func.sum(func.coalesce(Invoice.total, 0) * sales_case).desc())
        .limit(5)
        .all()
    )

    top_customers = [
        {
            'id': row.id,
            'name': row.name,
            'documents': int(row.documents or 0),
            'net_value': round_money(row.net_value),
            'net_weight': round_weight(row.net_weight),
        }
        for row in top_customers_rows
    ]

    return jsonify({
        'summary': summary,
        'series': series,
        'top_customers': top_customers,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'group_by': group_by,
            'include_unposted': include_unposted,
            'gold_type': gold_type_filter,
        },
        'count': len(invoices),
    })


@api.route('/reports/sales_by_customer', methods=['GET'])
def get_sales_by_customer_report():
    """تقرير مبيعات حسب العملاء مع ملخصات وزن وقيمة"""
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    limit_param = request.args.get('limit')
    order_by = (request.args.get('order_by') or 'net_value').lower()
    order_direction = (request.args.get('order_direction') or 'desc').lower()

    try:
        start_dt = None
        end_dt = None

        if start_date:
            start_value = _parse_iso_date(start_date, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date:
            end_value = _parse_iso_date(end_date, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)

        limit = int(limit_param) if limit_param else 25
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    limit = max(5, min(limit, 200))

    sale_types = {'بيع', 'مرتجع بيع'}

    filters = [
        Invoice.invoice_type.in_(sale_types),
        Invoice.customer_id.isnot(None),
    ]

    if not include_unposted:
        filters.append(Invoice.is_posted.is_(True))

    if start_dt:
        filters.append(Invoice.date >= start_dt)

    if end_dt:
        filters.append(Invoice.date < end_dt)

    sales_case = case((Invoice.invoice_type == 'مرتجع بيع', -1), else_=1)

    documents_expr = func.count(Invoice.id).label('documents')
    sales_value_expr = func.coalesce(
        func.sum(case((Invoice.invoice_type == 'مرتجع بيع', 0), else_=func.coalesce(Invoice.total, 0))),
        0,
    ).label('sales_value')
    returns_value_expr = func.coalesce(
        func.sum(case((Invoice.invoice_type == 'مرتجع بيع', func.coalesce(Invoice.total, 0)), else_=0)),
        0,
    ).label('returns_value')
    net_value_expr = func.coalesce(
        func.sum(func.coalesce(Invoice.total, 0) * sales_case),
        0,
    ).label('net_value')

    sales_weight_expr = func.coalesce(
        func.sum(case((Invoice.invoice_type == 'مرتجع بيع', 0), else_=func.coalesce(Invoice.total_weight, 0))),
        0,
    ).label('sales_weight')
    returns_weight_expr = func.coalesce(
        func.sum(case((Invoice.invoice_type == 'مرتجع بيع', func.coalesce(Invoice.total_weight, 0)), else_=0)),
        0,
    ).label('returns_weight')
    net_weight_expr = func.coalesce(
        func.sum(func.coalesce(Invoice.total_weight, 0) * sales_case),
        0,
    ).label('net_weight')

    last_invoice_expr = func.max(Invoice.date).label('last_invoice_date')
    average_invoice_expr = func.coalesce(
        func.avg(func.coalesce(Invoice.total, 0)),
        0,
    ).label('average_invoice_value')

    query = (
        db.session.query(
            Customer.id.label('customer_id'),
            Customer.name.label('customer_name'),
            Customer.customer_code.label('customer_code'),
            documents_expr,
            sales_value_expr,
            returns_value_expr,
            net_value_expr,
            sales_weight_expr,
            returns_weight_expr,
            net_weight_expr,
            last_invoice_expr,
            average_invoice_expr,
        )
        .join(Customer, Invoice.customer_id == Customer.id)
        .filter(*filters)
        .group_by(Customer.id, Customer.name, Customer.customer_code)
    )

    order_map = {
        'documents': documents_expr,
        'sales_value': sales_value_expr,
        'returns_value': returns_value_expr,
        'net_value': net_value_expr,
        'sales_weight': sales_weight_expr,
        'returns_weight': returns_weight_expr,
        'net_weight': net_weight_expr,
        'last_invoice_date': last_invoice_expr,
        'average_invoice_value': average_invoice_expr,
    }

    order_column = order_map.get(order_by, net_value_expr)
    if order_direction == 'asc':
        query = query.order_by(order_column.asc())
    else:
        query = query.order_by(order_column.desc())

    results = query.limit(limit).all()

    summary_row = (
        db.session.query(
            func.count(func.distinct(Invoice.customer_id)).label('customer_count'),
            func.count(Invoice.id).label('documents'),
            func.coalesce(func.sum(case((Invoice.invoice_type == 'مرتجع بيع', 0), else_=func.coalesce(Invoice.total, 0))), 0).label('sales_value'),
            func.coalesce(func.sum(case((Invoice.invoice_type == 'مرتجع بيع', func.coalesce(Invoice.total, 0)), else_=0)), 0).label('returns_value'),
            func.coalesce(func.sum(func.coalesce(Invoice.total, 0) * sales_case), 0).label('net_value'),
            func.coalesce(func.sum(case((Invoice.invoice_type == 'مرتجع بيع', 0), else_=func.coalesce(Invoice.total_weight, 0))), 0).label('sales_weight'),
            func.coalesce(func.sum(case((Invoice.invoice_type == 'مرتجع بيع', func.coalesce(Invoice.total_weight, 0)), else_=0)), 0).label('returns_weight'),
            func.coalesce(func.sum(func.coalesce(Invoice.total_weight, 0) * sales_case), 0).label('net_weight'),
            func.coalesce(func.avg(func.coalesce(Invoice.total, 0)), 0).label('average_invoice_value'),
        )
        .filter(*filters)
        .first()
    )

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    summary = {
        'customer_count': int(summary_row.customer_count or 0),
        'documents': int(summary_row.documents or 0),
        'sales_value': round_money(summary_row.sales_value),
        'returns_value': round_money(summary_row.returns_value),
        'net_value': round_money(summary_row.net_value),
        'sales_weight': round_weight(summary_row.sales_weight),
        'returns_weight': round_weight(summary_row.returns_weight),
        'net_weight': round_weight(summary_row.net_weight),
        'average_invoice_value': round_money(summary_row.average_invoice_value),
    }

    customer_ids = [row.customer_id for row in results]
    balance_map = {}
    if customer_ids:
        customers = Customer.query.filter(Customer.id.in_(customer_ids)).all()
        for customer in customers:
            gold_balance_main = (
                convert_to_main_karat(customer.balance_gold_18k or 0, 18)
                + convert_to_main_karat(customer.balance_gold_21k or 0, 21)
                + convert_to_main_karat(customer.balance_gold_22k or 0, 22)
                + convert_to_main_karat(customer.balance_gold_24k or 0, 24)
            )
            balance_map[customer.id] = {
                'cash': round_money(customer.balance_cash),
                'gold_main_karat': round_weight(gold_balance_main),
            }

    customers_data = []
    for index, row in enumerate(results, start=1):
        balances = balance_map.get(row.customer_id, {'cash': 0.0, 'gold_main_karat': 0.0})
        customers_data.append({
            'rank': index,
            'customer_id': row.customer_id,
            'customer_name': row.customer_name,
            'customer_code': row.customer_code,
            'documents': int(row.documents or 0),
            'sales_value': round_money(row.sales_value),
            'returns_value': round_money(row.returns_value),
            'net_value': round_money(row.net_value),
            'sales_weight': round_weight(row.sales_weight),
            'returns_weight': round_weight(row.returns_weight),
            'net_weight': round_weight(row.net_weight),
            'average_invoice_value': round_money(row.average_invoice_value),
            'last_invoice_date': row.last_invoice_date.isoformat() if row.last_invoice_date else None,
            'balance_cash': balances['cash'],
            'balance_gold_main_karat': balances['gold_main_karat'],
        })

    return jsonify({
        'summary': summary,
        'customers': customers_data,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'include_unposted': include_unposted,
            'limit': limit,
            'order_by': order_by,
            'order_direction': order_direction,
        },
        'count': len(customers_data),
    })


@api.route('/reports/sales_by_item', methods=['GET'])
def get_sales_by_item_report():
    """تقرير المبيعات حسب الأصناف"""
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    limit_param = request.args.get('limit')
    order_by = (request.args.get('order_by') or 'net_value').lower()
    order_direction = (request.args.get('order_direction') or 'desc').lower()

    try:
        start_dt = None
        end_dt = None

        if start_date:
            start_value = _parse_iso_date(start_date, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date:
            end_value = _parse_iso_date(end_date, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)

        limit = int(limit_param) if limit_param else 25
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    limit = max(5, min(limit, 200))

    sale_types = {'بيع', 'مرتجع بيع'}

    filters = [
        Invoice.invoice_type.in_(sale_types),
    ]

    if not include_unposted:
        filters.append(Invoice.is_posted.is_(True))

    if start_dt:
        filters.append(Invoice.date >= start_dt)

    if end_dt:
        filters.append(Invoice.date < end_dt)

    rows = (
        db.session.query(InvoiceItem, Invoice, Item)
        .join(Invoice, InvoiceItem.invoice_id == Invoice.id)
        .outerjoin(Item, InvoiceItem.item_id == Item.id)
        .filter(*filters)
        .all()
    )

    main_karat = get_main_karat()

    def _parse_karat(value):
        if value is None:
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            if isinstance(value, str):
                cleaned = value.replace('K', '').replace('k', '').replace('عيار', '').strip()
                try:
                    return float(cleaned)
                except (TypeError, ValueError):
                    return None
        return None

    def _normalize_weight(weight, karat_value):
        if weight is None:
            return 0.0
        try:
            karat_number = float(karat_value) if karat_value not in (None, 0) else float(main_karat)
        except (TypeError, ValueError):
            karat_number = float(main_karat) if main_karat else 0.0
        if not karat_number or not main_karat:
            return float(weight or 0.0)
        return (float(weight or 0.0) * karat_number) / float(main_karat)

    aggregates = {}

    for invoice_item, invoice, item in rows:
        sign = -1 if invoice.invoice_type == 'مرتجع بيع' else 1

        key = invoice_item.item_id or f"manual:{invoice_item.name or 'غير مسمى'}:{invoice_item.karat or 'unknown'}"

        if key not in aggregates:
            aggregates[key] = {
                'item_id': invoice_item.item_id,
                'item_code': getattr(item, 'item_code', None),
                'item_name': invoice_item.name or getattr(item, 'name', 'غير مسمى'),
                'karat': invoice_item.karat or getattr(item, 'karat', None),
                'documents': set(),
                'sales_value': 0.0,
                'returns_value': 0.0,
                'net_value': 0.0,
                'sales_weight': 0.0,
                'returns_weight': 0.0,
                'net_weight': 0.0,
                'sales_quantity': 0.0,
                'returns_quantity': 0.0,
                'net_quantity': 0.0,
                'last_invoice_date': None,
            }

        entry = aggregates[key]
        entry['documents'].add(invoice.id)

        quantity = float(invoice_item.quantity or 0)
        line_value = invoice_item.net
        if line_value is None:
            price = invoice_item.price or 0.0
            line_value = price * quantity
        line_value = float(line_value or 0.0)

        weight_value = invoice_item.weight
        if weight_value is None and item is not None:
            base_weight = getattr(item, 'weight', None)
            if base_weight is not None:
                if quantity > 0:
                    weight_value = base_weight * quantity
                else:
                    weight_value = base_weight
        weight_value = float(weight_value or 0.0)

        karat_value = invoice_item.karat
        if karat_value in (None, 0) and item is not None:
            karat_value = getattr(item, 'karat', None)
        karat_value = _parse_karat(karat_value) or main_karat

        normalized_weight = _normalize_weight(weight_value, karat_value)

        if sign > 0:
            entry['sales_value'] += line_value
            entry['sales_weight'] += normalized_weight
            entry['sales_quantity'] += quantity
        else:
            entry['returns_value'] += abs(line_value)
            entry['returns_weight'] += abs(normalized_weight)
            entry['returns_quantity'] += abs(quantity)

        entry['net_value'] += line_value * sign
        entry['net_weight'] += normalized_weight * sign
        entry['net_quantity'] += quantity * sign

        if not entry['last_invoice_date'] or (invoice.date and invoice.date > entry['last_invoice_date']):
            entry['last_invoice_date'] = invoice.date

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    items_data = []
    for data in aggregates.values():
        sales_weight = data['sales_weight']
        returns_weight = data['returns_weight']
        net_weight = data['net_weight']
        sales_value = data['sales_value']

        average_price_per_gram = 0.0
        if sales_weight:
            average_price_per_gram = sales_value / sales_weight if sales_weight else 0.0

        last_invoice_iso = data['last_invoice_date'].isoformat() if data['last_invoice_date'] else None

        items_data.append({
            'item_id': data['item_id'],
            'item_code': data['item_code'],
            'item_name': data['item_name'],
            'karat': data['karat'],
            'documents': len(data['documents']),
            'sales_value': round_money(data['sales_value']),
            'returns_value': round_money(data['returns_value']),
            'net_value': round_money(data['net_value']),
            'sales_weight': round_weight(sales_weight),
            'returns_weight': round_weight(returns_weight),
            'net_weight': round_weight(net_weight),
            'sales_quantity': round_weight(data['sales_quantity']),
            'returns_quantity': round_weight(data['returns_quantity']),
            'net_quantity': round_weight(data['net_quantity']),
            'average_price_per_gram': round_money(average_price_per_gram),
            'last_invoice_date': last_invoice_iso,
        })

    order_map = {
        'net_value': lambda item: item['net_value'],
        'sales_value': lambda item: item['sales_value'],
        'returns_value': lambda item: item['returns_value'],
        'net_weight': lambda item: item['net_weight'],
        'sales_weight': lambda item: item['sales_weight'],
        'returns_weight': lambda item: item['returns_weight'],
        'net_quantity': lambda item: item['net_quantity'],
        'sales_quantity': lambda item: item['sales_quantity'],
        'returns_quantity': lambda item: item['returns_quantity'],
        'documents': lambda item: item['documents'],
        'average_price_per_gram': lambda item: item['average_price_per_gram'],
        'last_invoice_date': lambda item: item['last_invoice_date'] or '',
    }

    order_key = order_map.get(order_by, order_map['net_value'])
    reverse = order_direction != 'asc'
    items_data.sort(key=order_key, reverse=reverse)

    limited_items = items_data[:limit]

    summary = {
        'item_count': len(items_data),
        'documents': sum(item['documents'] for item in items_data),
        'sales_value': round_money(sum(item['sales_value'] for item in items_data)),
        'returns_value': round_money(sum(item['returns_value'] for item in items_data)),
        'net_value': round_money(sum(item['net_value'] for item in items_data)),
        'sales_weight': round_weight(sum(item['sales_weight'] for item in items_data)),
        'returns_weight': round_weight(sum(item['returns_weight'] for item in items_data)),
        'net_weight': round_weight(sum(item['net_weight'] for item in items_data)),
        'sales_quantity': round_weight(sum(item['sales_quantity'] for item in items_data)),
        'returns_quantity': round_weight(sum(item['returns_quantity'] for item in items_data)),
        'net_quantity': round_weight(sum(item['net_quantity'] for item in items_data)),
    }

    total_sales_weight = summary['sales_weight']
    summary['average_price_per_gram'] = round_money(
        summary['sales_value'] / total_sales_weight if total_sales_weight else 0.0
    )

    return jsonify({
        'summary': summary,
        'items': limited_items,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'include_unposted': include_unposted,
            'limit': limit,
            'order_by': order_by,
            'order_direction': order_direction,
        },
        'count': len(limited_items),
    })


@api.route('/reports/inventory_status', methods=['GET'])
def get_inventory_status_report():
    """تقرير حالة المخزون حسب الأصناف"""
    include_zero_stock = request.args.get('include_zero_stock', 'false').lower() == 'true'
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    order_by = (request.args.get('order_by') or 'market_value').lower()
    order_direction = (request.args.get('order_direction') or 'desc').lower()

    limit_param = request.args.get('limit')
    slow_days_param = request.args.get('slow_days')
    karats_param = request.args.get('karats')

    try:
        limit = int(limit_param) if limit_param else None
        if limit is not None:
            limit = max(5, min(limit, 500))
    except ValueError:
        return jsonify({'error': 'Invalid limit parameter'}), 400

    try:
        slow_days_threshold = int(slow_days_param) if slow_days_param else 45
        slow_days_threshold = max(7, min(slow_days_threshold, 365))
    except ValueError:
        return jsonify({'error': 'Invalid slow_days parameter'}), 400

    karat_filters = []
    if karats_param:
        for part in karats_param.split(','):
            value = part.strip()
            if not value:
                continue
            try:
                karat_filters.append(float(value))
            except ValueError:
                return jsonify({'error': f'Invalid karat value: {value}'}), 400

    def parse_float(value, default=0.0):
        try:
            return float(value)
        except (TypeError, ValueError):
            return default

    def parse_karat(value):
        if value in (None, ''):
            return None
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            cleaned = value.lower().replace('k', '').replace('عيار', '').strip()
            cleaned = cleaned.replace(' ', '')
            if cleaned.endswith('قيراط'):
                cleaned = cleaned[:-5]
            try:
                return float(cleaned)
            except (TypeError, ValueError):
                return None
        return None

    def matches_karat(target_value):
        if not karat_filters:
            return True
        if target_value is None:
            return False
        for expected in karat_filters:
            if abs(target_value - expected) < 0.01:
                return True
        return False

    main_karat = get_main_karat() or 21

    def normalize_to_main(weight, karat_value):
        base_weight = parse_float(weight, 0.0)
        karat_number = parse_float(karat_value, 0.0) or main_karat
        if base_weight == 0:
            return 0.0
        if not main_karat:
            return base_weight
        return (base_weight * karat_number) / float(main_karat)

    items = Item.query.order_by(Item.item_code.asc()).all()
    filtered_items = [
        item for item in items
        if matches_karat(parse_karat(getattr(item, 'karat', None)))
    ]

    item_map = {item.id: item for item in filtered_items if item.id is not None}
    item_ids = list(item_map.keys())

    invoice_filters = [InvoiceItem.item_id.isnot(None)]
    if item_ids:
        invoice_filters.append(InvoiceItem.item_id.in_(item_ids))
    if not include_unposted:
        invoice_filters.append(Invoice.is_posted.is_(True))

    movement_map = {}

    def ensure_bucket(item_id):
        if item_id not in movement_map:
            movement_map[item_id] = {
                'net_quantity': 0.0,
                'net_weight_main': 0.0,
                'incoming_quantity': 0.0,
                'incoming_weight_main': 0.0,
                'outgoing_quantity': 0.0,
                'outgoing_weight_main': 0.0,
                'incoming_value': 0.0,
                'outgoing_value': 0.0,
                'net_value': 0.0,
                'documents': set(),
                'last_movement': None,
            }
        return movement_map[item_id]

    if item_ids:
        movement_rows = (
            db.session.query(InvoiceItem, Invoice)
            .join(Invoice, InvoiceItem.invoice_id == Invoice.id)
            .filter(*invoice_filters)
            .all()
        )
    else:
        movement_rows = []

    purchase_types = {'شراء من عميل', 'شراء من مورد', 'شراء'}
    sale_types = {'بيع', 'فاتورة بيع'}
    sale_return_types = {'مرتجع بيع'}
    purchase_return_types = {'مرتجع شراء', 'مرتجع شراء من مورد'}

    for invoice_item, invoice in movement_rows:
        item_id = invoice_item.item_id
        if item_id not in item_map:
            continue

        invoice_type = (invoice.invoice_type or '').strip()

        sign = 0
        if invoice_type in purchase_types or (
            'شراء' in invoice_type and 'مرتجع' not in invoice_type
        ):
            sign = 1
        elif invoice_type in sale_types or (
            'بيع' in invoice_type and 'مرتجع' not in invoice_type
        ):
            sign = -1
        elif invoice_type in sale_return_types or (
            'مرتجع' in invoice_type and 'بيع' in invoice_type
        ):
            sign = 1
        elif invoice_type in purchase_return_types or (
            'مرتجع' in invoice_type and 'شراء' in invoice_type
        ):
            sign = -1

        if sign == 0:
            continue

        bucket = ensure_bucket(item_id)
        item_obj = item_map[item_id]

        quantity = parse_float(invoice_item.quantity, 0.0)
        line_value = invoice_item.net
        if line_value is None:
            line_value = parse_float(invoice_item.price, 0.0) * quantity
        else:
            line_value = parse_float(line_value, 0.0)

        raw_weight = invoice_item.weight
        if raw_weight is None:
            base_weight = getattr(item_obj, 'weight', None)
            if base_weight is not None:
                raw_weight = parse_float(base_weight, 0.0) * (quantity or 1)
        raw_weight = parse_float(raw_weight, 0.0)

        karat_value = parse_karat(invoice_item.karat)
        if karat_value is None:
            karat_value = parse_karat(getattr(item_obj, 'karat', None)) or main_karat

        normalized_weight = normalize_to_main(raw_weight, karat_value)

        bucket['net_quantity'] += quantity * sign
        bucket['net_weight_main'] += normalized_weight * sign
        bucket['net_value'] += line_value * sign

        if sign > 0:
            bucket['incoming_quantity'] += quantity
            bucket['incoming_weight_main'] += normalized_weight
            bucket['incoming_value'] += line_value
        else:
            bucket['outgoing_quantity'] += quantity
            bucket['outgoing_weight_main'] += normalized_weight
            bucket['outgoing_value'] += abs(line_value)

        bucket['documents'].add(invoice.id)
        if invoice.date:
            last_date = bucket.get('last_movement')
            if last_date is None or invoice.date > last_date:
                bucket['last_movement'] = invoice.date

    latest_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
    price_per_gram_24k = None
    price_reference_date = None
    if latest_price:
        try:
            price_per_gram_24k = (float(latest_price.price or 0.0) / 31.1035) * 3.75
            price_reference_date = latest_price.date.isoformat() if latest_price.date else None
        except (TypeError, ValueError):
            price_per_gram_24k = None

    price_per_gram_main = None
    if price_per_gram_24k:
        try:
            price_per_gram_main = price_per_gram_24k * (main_karat / 24.0)
        except (TypeError, ValueError, ZeroDivisionError):
            price_per_gram_main = None

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    now = datetime.utcnow()

    summary_totals = {
        'items_total': len(filtered_items),
        'items_in_stock': 0,
        'items_out_of_stock': 0,
        'items_negative': 0,
        'slow_moving_items': 0,
        'total_recorded_quantity': 0.0,
        'total_calculated_quantity': 0.0,
        'total_effective_quantity': 0.0,
        'total_recorded_weight_main': 0.0,
        'total_calculated_weight_main': 0.0,
        'total_effective_weight_main': 0.0,
        'total_market_value': 0.0,
        'total_tag_value': 0.0,
        'total_documents': 0,
        'latest_movement': None,
    }

    items_payload = []

    for item in filtered_items:
        item_karat = parse_karat(getattr(item, 'karat', None)) or main_karat

        recorded_stock_qty = parse_float(getattr(item, 'stock', None), 0.0)
        if recorded_stock_qty == 0:
            recorded_stock_qty = parse_float(getattr(item, 'count', None), 0.0)

        unit_weight = parse_float(getattr(item, 'weight', None), 0.0)
        recorded_total_weight = unit_weight * recorded_stock_qty if unit_weight and recorded_stock_qty else unit_weight
        recorded_weight_main = normalize_to_main(recorded_total_weight, item_karat)

        bucket = movement_map.get(item.id)
        if bucket is None:
            bucket = {
                'net_quantity': 0.0,
                'net_weight_main': 0.0,
                'incoming_quantity': 0.0,
                'incoming_weight_main': 0.0,
                'outgoing_quantity': 0.0,
                'outgoing_weight_main': 0.0,
                'incoming_value': 0.0,
                'outgoing_value': 0.0,
                'net_value': 0.0,
                'documents': set(),
                'last_movement': None,
            }

        calculated_quantity = bucket['net_quantity']
        calculated_weight_main = bucket['net_weight_main']

        effective_quantity = calculated_quantity if abs(calculated_quantity) > 1e-6 else recorded_stock_qty
        effective_weight_main = calculated_weight_main if abs(calculated_weight_main) > 1e-6 else recorded_weight_main

        documents_count = len(bucket['documents'])
        last_movement = bucket['last_movement']
        days_since_movement = None
        if last_movement:
            try:
                days_since_movement = (now - last_movement).days
            except Exception:
                days_since_movement = None

        status = 'active'
        if effective_quantity < -1e-6 or effective_weight_main < -1e-6:
            status = 'negative_balance'
        elif abs(effective_quantity) <= 1e-6 and abs(effective_weight_main) <= 1e-6:
            status = 'out_of_stock'
        elif days_since_movement is not None and days_since_movement >= slow_days_threshold:
            status = 'slow_moving'

        slow_moving = status == 'slow_moving'

        market_value = 0.0
        if price_per_gram_main is not None:
            market_value = effective_weight_main * price_per_gram_main

        valuation_quantity = recorded_stock_qty if recorded_stock_qty > 0 else max(effective_quantity, 0.0)
        tag_value = parse_float(getattr(item, 'price', None), 0.0) * valuation_quantity
        valuation_gap = market_value - tag_value

        average_tag_price_per_gram = 0.0
        if effective_weight_main > 0:
            average_tag_price_per_gram = tag_value / effective_weight_main if effective_weight_main else 0.0

        item_entry = {
            'item_id': item.id,
            'item_code': item.item_code,
            'item_name': item.name,
            'karat': getattr(item, 'karat', None),
            'recorded_stock_quantity': round_weight(recorded_stock_qty),
            'calculated_stock_quantity': round_weight(calculated_quantity),
            'effective_stock_quantity': round_weight(effective_quantity),
            'unit_weight': round_weight(unit_weight),
            'recorded_total_weight': round_weight(recorded_total_weight),
            'calculated_total_weight_main_karat': round_weight(calculated_weight_main),
            'effective_weight_main_karat': round_weight(effective_weight_main),
            'market_value': round_money(market_value),
            'tag_value': round_money(tag_value),
            'valuation_gap': round_money(valuation_gap),
            'average_tag_price_per_gram': round_money(average_tag_price_per_gram),
            'net_value_flow': round_money(bucket['net_value']),
            'incoming_weight_main_karat': round_weight(bucket['incoming_weight_main']),
            'outgoing_weight_main_karat': round_weight(bucket['outgoing_weight_main']),
            'incoming_quantity': round_weight(bucket['incoming_quantity']),
            'outgoing_quantity': round_weight(bucket['outgoing_quantity']),
            'documents': int(documents_count),
            'last_movement_ts': last_movement.timestamp() if isinstance(last_movement, datetime) else None,
            'days_since_movement': int(days_since_movement) if days_since_movement is not None else None,
            'status': status,
            'slow_moving': bool(slow_moving),
        }

        if not include_zero_stock and (
            abs(item_entry['effective_stock_quantity']) <= 1e-6 and
            abs(item_entry['effective_weight_main_karat']) <= 1e-6
        ):
            continue

        items_payload.append(item_entry)

        if status == 'negative_balance':
            summary_totals['items_negative'] += 1
        elif status == 'out_of_stock':
            summary_totals['items_out_of_stock'] += 1
        else:
            summary_totals['items_in_stock'] += 1

        if slow_moving:
            summary_totals['slow_moving_items'] += 1

        summary_totals['total_recorded_quantity'] += max(recorded_stock_qty, 0.0)
        summary_totals['total_calculated_quantity'] += max(calculated_quantity, 0.0)
        summary_totals['total_effective_quantity'] += max(effective_quantity, 0.0)

        summary_totals['total_recorded_weight_main'] += max(recorded_weight_main, 0.0)
        summary_totals['total_calculated_weight_main'] += max(calculated_weight_main, 0.0)
        summary_totals['total_effective_weight_main'] += max(effective_weight_main, 0.0)

        summary_totals['total_market_value'] += market_value
        summary_totals['total_tag_value'] += tag_value
        summary_totals['total_documents'] += documents_count

        if last_movement:
            current_latest = summary_totals['latest_movement']
            if current_latest is None or last_movement > current_latest:
                summary_totals['latest_movement'] = last_movement

    reverse = order_direction != 'asc'

    if order_by == 'item_code':
        items_payload.sort(key=lambda item: (item.get('item_code') or '').lower(), reverse=reverse)
    elif order_by == 'item_name':
        items_payload.sort(key=lambda item: (item.get('item_name') or '').lower(), reverse=reverse)
    elif order_by == 'days_since_movement':
        sentinel = float('inf') if not reverse else float('-inf')
        items_payload.sort(
            key=lambda item: item.get('days_since_movement', sentinel)
            if item.get('days_since_movement') is not None else sentinel,
            reverse=reverse,
        )
    elif order_by == 'status':
        items_payload.sort(key=lambda item: item.get('status', ''), reverse=reverse)
    else:
        items_payload.sort(
            key=lambda item: item.get(order_by, 0.0),
            reverse=reverse,
        )

    if limit is not None:
        items_payload = items_payload[:limit]

    for item in items_payload:
        ts_value = item.pop('last_movement_ts', None)
        item['last_movement_date'] = (
            datetime.utcfromtimestamp(ts_value).isoformat() if ts_value is not None else None
        )

    latest_movement = summary_totals['latest_movement']
    days_since_latest = None
    if latest_movement:
        try:
            days_since_latest = (now - latest_movement).days
        except Exception:
            days_since_latest = None

    summary = {
        'items_total': summary_totals['items_total'],
        'items_considered': len(items_payload),
        'items_in_stock': summary_totals['items_in_stock'],
        'items_out_of_stock': summary_totals['items_out_of_stock'],
        'items_negative': summary_totals['items_negative'],
        'slow_moving_items': summary_totals['slow_moving_items'],
        'total_recorded_quantity': round_weight(summary_totals['total_recorded_quantity']),
        'total_calculated_quantity': round_weight(summary_totals['total_calculated_quantity']),
        'total_effective_quantity': round_weight(summary_totals['total_effective_quantity']),
        'total_recorded_weight_main_karat': round_weight(summary_totals['total_recorded_weight_main']),
        'total_calculated_weight_main_karat': round_weight(summary_totals['total_calculated_weight_main']),
        'total_effective_weight_main_karat': round_weight(summary_totals['total_effective_weight_main']),
        'total_market_value': round_money(summary_totals['total_market_value']),
        'total_tag_value': round_money(summary_totals['total_tag_value']),
        'valuation_gap': round_money(summary_totals['total_market_value'] - summary_totals['total_tag_value']),
        'documents_count': summary_totals['total_documents'],
        'latest_movement_date': latest_movement.isoformat() if latest_movement else None,
        'days_since_latest_movement': days_since_latest,
        'price_reference': {
            'per_gram_24k': round_money(price_per_gram_24k) if price_per_gram_24k else None,
            'per_gram_main_karat': round_money(price_per_gram_main) if price_per_gram_main else None,
            'main_karat': main_karat,
            'gold_price_date': price_reference_date,
        },
        'slow_days_threshold': slow_days_threshold,
    }

    return jsonify({
        'summary': summary,
        'items': items_payload,
        'filters': {
            'karats': karat_filters,
            'include_zero_stock': include_zero_stock,
            'include_unposted': include_unposted,
            'order_by': order_by,
            'order_direction': order_direction,
            'limit': limit,
            'slow_days_threshold': slow_days_threshold,
        },
        'count': len(items_payload),
    })


@api.route('/reports/low_stock', methods=['GET'])
def get_low_stock_report():
    """إرجاع الأصناف ذات المخزون المنخفض بناءً على عتبات الكمية أو الوزن."""

    include_zero_stock = request.args.get('include_zero_stock', 'false').lower() == 'true'
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    karats_param = request.args.get('karats')
    office_param = request.args.get('office_id')
    limit_param = request.args.get('limit')
    sort_by = (request.args.get('sort_by') or 'severity').lower()
    sort_direction = (request.args.get('sort_direction') or 'desc').lower()

    threshold_qty_param = request.args.get('threshold_quantity')
    threshold_weight_param = request.args.get('threshold_weight')

    try:
        threshold_quantity = float(threshold_qty_param) if threshold_qty_param else 2.0
        threshold_quantity = max(0.0, min(threshold_quantity, 1000.0))
    except ValueError:
        return jsonify({'error': 'Invalid threshold_quantity parameter'}), 400

    try:
        threshold_weight = float(threshold_weight_param) if threshold_weight_param else 15.0
        threshold_weight = max(0.0, min(threshold_weight, 2000.0))
    except ValueError:
        return jsonify({'error': 'Invalid threshold_weight parameter'}), 400

    try:
        limit = int(limit_param) if limit_param else 150
        limit = max(5, min(limit, 500))
    except ValueError:
        return jsonify({'error': 'Invalid limit parameter'}), 400

    office_id = None
    if office_param not in (None, ''):
        try:
            office_id = int(office_param)
        except ValueError:
            return jsonify({'error': 'office_id must be numeric'}), 400

    karat_filters = []
    if karats_param:
        for raw_value in karats_param.split(','):
            candidate = raw_value.strip()
            if not candidate:
                continue
            try:
                karat_filters.append(float(candidate))
            except ValueError:
                return jsonify({'error': f'Invalid karat value: {candidate}'}), 400

    def parse_float(value, default=0.0):
        try:
            return float(value)
        except (TypeError, ValueError):
            return default

    def parse_karat(value):
        if value in (None, ''):
            return None
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            cleaned = value.lower().replace('k', '').replace('عيار', '').strip()
            cleaned = cleaned.replace(' ', '')
            if cleaned.endswith('قيراط'):
                cleaned = cleaned[:-5]
            try:
                return float(cleaned)
            except (TypeError, ValueError):
                return None
        return None

    def matches_karat(karat_value):
        if not karat_filters:
            return True
        if karat_value is None:
            return False
        for expected in karat_filters:
            if abs(karat_value - expected) < 0.01:
                return True
        return False

    main_karat = get_main_karat() or 21

    def normalize_to_main(weight, karat_value):
        base_weight = parse_float(weight, 0.0)
        karat_number = parse_float(karat_value, 0.0) or main_karat
        if base_weight == 0:
            return 0.0
        if not main_karat:
            return base_weight
        return (base_weight * karat_number) / float(main_karat)

    items = Item.query.order_by(Item.item_code.asc()).all()
    filtered_items = [
        item for item in items
        if matches_karat(parse_karat(getattr(item, 'karat', None)))
    ]

    if not filtered_items:
        return jsonify({
            'summary': {
                'items_considered': 0,
                'items_below_threshold': 0,
                'critical_items': 0,
                'total_shortage_quantity': 0.0,
                'total_shortage_weight': 0.0,
                'generated_at': datetime.utcnow().isoformat(),
            },
            'items': [],
            'filters': {
                'include_zero_stock': include_zero_stock,
                'include_unposted': include_unposted,
                'karats': karat_filters,
                'office_id': office_id,
                'threshold_quantity': threshold_quantity,
                'threshold_weight': threshold_weight,
                'sort_by': sort_by,
                'sort_direction': sort_direction,
                'limit': limit,
            },
        })

    item_map = {item.id: item for item in filtered_items if item.id is not None}
    item_ids = list(item_map.keys())

    invoice_filters = [InvoiceItem.item_id.isnot(None)]
    if item_ids:
        invoice_filters.append(InvoiceItem.item_id.in_(item_ids))
    if not include_unposted:
        invoice_filters.append(Invoice.is_posted.is_(True))
    if office_id is not None:
        invoice_filters.append(Invoice.office_id == office_id)

    movement_rows = []
    if item_ids:
        movement_rows = (
            db.session.query(InvoiceItem, Invoice)
            .join(Invoice, InvoiceItem.invoice_id == Invoice.id)
            .filter(*invoice_filters)
            .all()
        )

    purchase_types = {'شراء من عميل', 'شراء من مورد', 'شراء'}
    sale_types = {'بيع', 'فاتورة بيع'}
    sale_return_types = {'مرتجع بيع'}
    purchase_return_types = {'مرتجع شراء', 'مرتجع شراء من مورد'}

    def determine_direction(invoice_type):
        normalized = (invoice_type or '').strip()
        if normalized in purchase_types or (
            'شراء' in normalized and 'مرتجع' not in normalized
        ):
            return 1
        if normalized in sale_types or (
            'بيع' in normalized and 'مرتجع' not in normalized
        ):
            return -1
        if normalized in sale_return_types or (
            'مرتجع' in normalized and 'بيع' in normalized
        ):
            return 1
        if normalized in purchase_return_types or (
            'مرتجع' in normalized and 'شراء' in normalized
        ):
            return -1
        return 0

    movement_map = {}

    def ensure_bucket(item_id):
        if item_id not in movement_map:
            movement_map[item_id] = {
                'net_quantity': 0.0,
                'net_weight_main': 0.0,
                'documents': set(),
                'last_movement': None,
            }
        return movement_map[item_id]

    for invoice_item, invoice in movement_rows:
        item_id = invoice_item.item_id
        if item_id not in item_map:
            continue

        direction = determine_direction(invoice.invoice_type)
        if direction == 0:
            continue

        bucket = ensure_bucket(item_id)
        item_obj = item_map[item_id]

        quantity = parse_float(getattr(invoice_item, 'quantity', None), 0.0)
        raw_weight = parse_float(getattr(invoice_item, 'weight', None), 0.0)
        if raw_weight == 0.0:
            base_weight = parse_float(getattr(item_obj, 'weight', None), 0.0)
            if base_weight:
                raw_weight = base_weight * (quantity or 1.0)

        karat_value = parse_karat(getattr(invoice_item, 'karat', None))
        if karat_value is None:
            karat_value = parse_karat(getattr(item_obj, 'karat', None)) or main_karat

        normalized_weight = normalize_to_main(raw_weight, karat_value)

        bucket['net_quantity'] += quantity * direction
        bucket['net_weight_main'] += normalized_weight * direction

        bucket['documents'].add(invoice.id)
        if invoice.date:
            last_date = bucket['last_movement']
            if last_date is None or invoice.date > last_date:
                bucket['last_movement'] = invoice.date

    now = datetime.utcnow()

    def round_qty(value):
        return round(float(value or 0.0), 3)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    items_payload = []
    total_shortage_qty = 0.0
    total_shortage_weight = 0.0
    critical_count = 0
    movement_days = []

    for item in filtered_items:
        item_karat = parse_karat(getattr(item, 'karat', None)) or main_karat

        recorded_qty = parse_float(getattr(item, 'stock', None), 0.0)
        if recorded_qty == 0.0:
            recorded_qty = parse_float(getattr(item, 'count', None), 0.0)

        unit_weight = parse_float(getattr(item, 'weight', None), 0.0)
        recorded_total_weight = unit_weight * recorded_qty if unit_weight and recorded_qty else unit_weight
        recorded_weight_main = normalize_to_main(recorded_total_weight, item_karat)

        bucket = movement_map.get(item.id)
        if bucket is None:
            bucket = {
                'net_quantity': 0.0,
                'net_weight_main': 0.0,
                'documents': set(),
                'last_movement': None,
            }

        calculated_qty = bucket['net_quantity']
        calculated_weight_main = bucket['net_weight_main']

        effective_qty = calculated_qty if abs(calculated_qty) > 1e-6 else recorded_qty
        effective_weight_main = calculated_weight_main if abs(calculated_weight_main) > 1e-6 else recorded_weight_main

        last_movement = bucket['last_movement']
        days_since_movement = None
        if last_movement:
            try:
                days_since_movement = (now - last_movement).days
                movement_days.append(days_since_movement)
            except Exception:
                days_since_movement = None

        shortage_qty = max(0.0, threshold_quantity - effective_qty)
        shortage_weight = max(0.0, threshold_weight - effective_weight_main)

        status = 'ok'
        if effective_qty <= 0.0 or effective_weight_main <= 0.0:
            status = 'critical'
            critical_count += 1
        elif shortage_qty > 0 or shortage_weight > 0:
            status = 'low'

        if status == 'ok' and not include_zero_stock:
            continue

        total_shortage_qty += shortage_qty
        total_shortage_weight += shortage_weight

        documents_count = len(bucket['documents'])
        severity_score = (shortage_weight * 1.5) + shortage_qty

        items_payload.append({
            'item_id': item.id,
            'item_code': item.item_code,
            'name': item.name,
            'karat': getattr(item, 'karat', None),
            'unit_weight': round_weight(unit_weight),
            'threshold_quantity': round_qty(threshold_quantity),
            'threshold_weight': round_weight(threshold_weight),
            'available_quantity': round_qty(effective_qty),
            'available_weight_main': round_weight(effective_weight_main),
            'shortage_quantity': round_qty(shortage_qty),
            'shortage_weight': round_weight(shortage_weight),
            'status': status,
            'severity_score': round(float(severity_score), 4),
            'documents_count': documents_count,
            'days_since_movement': days_since_movement,
            'last_movement': last_movement.isoformat() if last_movement else None,
            'price': parse_float(getattr(item, 'price', None), 0.0),
        })

    if not items_payload and include_zero_stock:
        for item in filtered_items[: min(limit, len(filtered_items))]:
            items_payload.append({
                'item_id': item.id,
                'item_code': item.item_code,
                'name': item.name,
                'karat': getattr(item, 'karat', None),
                'unit_weight': round_weight(parse_float(getattr(item, 'weight', None), 0.0)),
                'threshold_quantity': round_qty(threshold_quantity),
                'threshold_weight': round_weight(threshold_weight),
                'available_quantity': 0.0,
                'available_weight_main': 0.0,
                'shortage_quantity': round_qty(threshold_quantity),
                'shortage_weight': round_weight(threshold_weight),
                'status': 'critical',
                'severity_score': round_qty(threshold_quantity + threshold_weight),
                'documents_count': 0,
                'days_since_movement': None,
                'last_movement': None,
                'price': parse_float(getattr(item, 'price', None), 0.0),
            })

    def sort_key(entry):
        if sort_by == 'quantity':
            return entry['available_quantity']
        if sort_by == 'weight':
            return entry['available_weight_main']
        if sort_by == 'name':
            return entry['name'] or ''
        return entry['severity_score']

    reverse_sort = sort_direction != 'asc'
    items_payload.sort(key=sort_key, reverse=reverse_sort)
    items_payload = items_payload[:limit]

    avg_days_since_movement = None
    if movement_days:
        avg_days_since_movement = round(sum(movement_days) / len(movement_days), 1)

    summary = {
        'items_considered': len(filtered_items),
        'items_below_threshold': len(items_payload),
        'critical_items': critical_count,
        'total_shortage_quantity': round_qty(total_shortage_qty),
        'total_shortage_weight': round_weight(total_shortage_weight),
        'average_days_since_movement': avg_days_since_movement,
        'generated_at': datetime.utcnow().isoformat(),
    }

    return jsonify({
        'summary': summary,
        'items': items_payload,
        'filters': {
            'include_zero_stock': include_zero_stock,
            'include_unposted': include_unposted,
            'karats': karat_filters,
            'office_id': office_id,
            'threshold_quantity': threshold_quantity,
            'threshold_weight': threshold_weight,
            'sort_by': sort_by,
            'sort_direction': sort_direction,
            'limit': limit,
        },
    })


@api.route('/reports/inventory_movement', methods=['GET'])
def get_inventory_movement_report():
    """تقرير حركة المخزون الزمني (وزن وقيمة)"""

    start_date_param = request.args.get('start_date')
    end_date_param = request.args.get('end_date')
    group_interval = (request.args.get('group_interval') or 'day').lower()
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    include_returns = request.args.get('include_returns', 'true').lower() == 'true'
    karats_param = request.args.get('karats')
    office_param = request.args.get('office_ids') or request.args.get('office_id')
    movements_limit_param = request.args.get('movements_limit') or request.args.get('limit')

    valid_intervals = {'day', 'week', 'month'}
    if group_interval not in valid_intervals:
        group_interval = 'day'

    try:
        start_dt = None
        end_dt = None

        if start_date_param:
            start_value = _parse_iso_date(start_date_param, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date_param:
            end_value = _parse_iso_date(end_date_param, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    now = datetime.utcnow()
    if end_dt is None:
        end_dt = datetime.combine(now.date(), datetime.min.time()) + timedelta(days=1)
    if start_dt is None:
        start_dt = end_dt - timedelta(days=30)

    if end_dt <= start_dt:
        end_dt = start_dt + timedelta(days=1)

    try:
        movements_limit = int(movements_limit_param) if movements_limit_param else 200
    except ValueError:
        return jsonify({'error': 'Invalid movements_limit parameter'}), 400

    movements_limit = max(50, min(movements_limit, 500))

    def parse_float(value, default=0.0):
        try:
            if value in (None, ''):
                return default
            return float(value)
        except (TypeError, ValueError):
            return default

    def parse_karat(value):
        if value in (None, ''):
            return None
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            cleaned = value.lower().replace('k', '').replace('عيار', '').strip()
            cleaned = cleaned.replace(' ', '')
            if cleaned.endswith('قيراط'):
                cleaned = cleaned[:-5]
            try:
                return float(cleaned)
            except (TypeError, ValueError):
                return None
        return None

    karat_filters = []
    if karats_param:
        for raw in karats_param.split(','):
            value = raw.strip()
            if not value:
                continue
            parsed = parse_karat(value)
            if parsed is None:
                return jsonify({'error': f'Invalid karat value: {value}'}), 400
            karat_filters.append(parsed)

    def matches_karat(target_value):
        if not karat_filters:
            return True
        if target_value is None:
            return False
        for expected in karat_filters:
            if abs(target_value - expected) < 0.01:
                return True
        return False

    office_ids = []
    if office_param:
        try:
            for raw in str(office_param).split(','):
                if not raw.strip():
                    continue
                office_ids.append(int(raw.strip()))
        except ValueError:
            return jsonify({'error': 'Invalid office id value'}), 400

    main_karat = get_main_karat() or 21

    def normalize_weight(weight_value, karat_value):
        base_weight = parse_float(weight_value, 0.0)
        karat_number = parse_float(karat_value, 0.0) or main_karat
        if base_weight == 0:
            return 0.0
        if not main_karat:
            return base_weight
        return (base_weight * karat_number) / float(main_karat)

    filters = [Invoice.date >= start_dt, Invoice.date < end_dt]
    if not include_unposted:
        filters.append(Invoice.is_posted.is_(True))
    if office_ids:
        filters.append(Invoice.office_id.in_(office_ids))

    movement_rows = (
        db.session.query(InvoiceItem, Invoice, Item, Office)
        .join(Invoice, InvoiceItem.invoice_id == Invoice.id)
        .outerjoin(Item, InvoiceItem.item_id == Item.id)
        .outerjoin(Office, Invoice.office_id == Office.id)
        .filter(*filters)
        .all()
    )

    purchase_types = {'شراء', 'شراء من عميل', 'شراء من مورد'}
    sale_types = {'بيع', 'فاتورة بيع'}
    sale_return_types = {'مرتجع بيع'}
    purchase_return_types = {'مرتجع شراء', 'مرتجع شراء من مورد'}

    def determine_direction(invoice_type_value: str):
        normalized = (invoice_type_value or '').strip()
        if not include_returns and 'مرتجع' in normalized:
            return 0
        if normalized in purchase_types or (
            'شراء' in normalized and 'مرتجع' not in normalized
        ):
            return 1
        if normalized in sale_types or (
            'بيع' in normalized and 'مرتجع' not in normalized
        ):
            return -1
        if normalized in sale_return_types or (
            'مرتجع' in normalized and 'بيع' in normalized
        ):
            return 1
        if normalized in purchase_return_types or (
            'مرتجع' in normalized and 'شراء' in normalized
        ):
            return -1
        return 0

    def bucket_key_for(date_value):
        if group_interval == 'week':
            return date_value - timedelta(days=date_value.weekday())
        if group_interval == 'month':
            return date_value.replace(day=1)
        return date_value

    def bucket_bounds(start_date_value):
        start_dt_value = datetime.combine(start_date_value, datetime.min.time())
        if group_interval == 'week':
            end_dt_value = start_dt_value + timedelta(days=7)
            label = f"{start_date_value.isocalendar()[0]}-W{start_date_value.isocalendar()[1]:02d}"
        elif group_interval == 'month':
            next_month = (start_date_value.replace(day=28) + timedelta(days=4)).replace(day=1)
            end_dt_value = datetime.combine(next_month, datetime.min.time())
            label = start_date_value.strftime('%Y-%m')
        else:
            end_dt_value = start_dt_value + timedelta(days=1)
            label = start_date_value.isoformat()
        return start_dt_value, end_dt_value, label

    timeline_map = {}

    def ensure_bucket(date_value):
        key = bucket_key_for(date_value)
        if key not in timeline_map:
            start_bound, end_bound, label = bucket_bounds(key)
            timeline_map[key] = {
                'label': label,
                'start': start_bound,
                'end': end_bound,
                'inbound_weight': 0.0,
                'outbound_weight': 0.0,
                'inbound_value': 0.0,
                'outbound_value': 0.0,
                'inbound_docs': set(),
                'outbound_docs': set(),
            }
        return timeline_map[key]

    summary_totals = {
        'inbound_weight': 0.0,
        'outbound_weight': 0.0,
        'net_weight': 0.0,
        'inbound_value': 0.0,
        'outbound_value': 0.0,
        'net_value': 0.0,
    }

    inbound_doc_ids = set()
    outbound_doc_ids = set()
    ledger_map = {}
    customer_ids_needed = set()
    supplier_ids_needed = set()

    for invoice_item, invoice, item, office in movement_rows:
        if not invoice:
            continue
        if invoice.date is None:
            continue

        direction_sign = determine_direction(invoice.invoice_type)
        if direction_sign == 0:
            continue

        effective_karat = parse_karat(invoice_item.karat)
        if effective_karat is None and item is not None:
            effective_karat = parse_karat(getattr(item, 'karat', None))

        if not matches_karat(effective_karat):
            continue

        raw_weight = invoice_item.weight
        quantity = parse_float(invoice_item.quantity, 0.0)

        if raw_weight is None and item is not None:
            base_weight = parse_float(getattr(item, 'weight', None), 0.0)
            if base_weight:
                raw_weight = base_weight * (quantity if quantity else 1.0)

        normalized_weight = normalize_weight(raw_weight, effective_karat)
        weight_contribution = abs(normalized_weight)

        line_value = invoice_item.net
        if line_value is None:
            line_value = parse_float(invoice_item.price, 0.0) * (quantity or 0.0)
        value_contribution = abs(parse_float(line_value, 0.0))

        direction = 'inbound' if direction_sign > 0 else 'outbound'

        bucket = ensure_bucket(invoice.date.date())
        if direction == 'inbound':
            bucket['inbound_weight'] += weight_contribution
            bucket['inbound_value'] += value_contribution
            bucket['inbound_docs'].add(invoice.id)
            summary_totals['inbound_weight'] += weight_contribution
            summary_totals['inbound_value'] += value_contribution
            inbound_doc_ids.add(invoice.id)
        else:
            bucket['outbound_weight'] += weight_contribution
            bucket['outbound_value'] += value_contribution
            bucket['outbound_docs'].add(invoice.id)
            summary_totals['outbound_weight'] += weight_contribution
            summary_totals['outbound_value'] += value_contribution
            outbound_doc_ids.add(invoice.id)

        summary_totals['net_weight'] += weight_contribution * direction_sign
        summary_totals['net_value'] += value_contribution * direction_sign

        ledger_key = (invoice.id, direction)
        if ledger_key not in ledger_map:
            ledger_map[ledger_key] = {
                'invoice_id': invoice.id,
                'invoice_type': invoice.invoice_type,
                'invoice_type_id': invoice.invoice_type_id,
                'direction': direction,
                'date': invoice.date,
                'office_id': invoice.office_id,
                'office_name': office.name if office else None,
                'customer_id': invoice.customer_id,
                'supplier_id': invoice.supplier_id,
                'weight': 0.0,
                'value': 0.0,
                'quantity': 0.0,
                'line_count': 0,
                'item_names': set(),
                'karats': set(),
            }

        ledger_entry = ledger_map[ledger_key]
        ledger_entry['weight'] += weight_contribution
        ledger_entry['value'] += value_contribution
        ledger_entry['quantity'] += abs(quantity)
        ledger_entry['line_count'] += 1

        if invoice_item.name:
            ledger_entry['item_names'].add(invoice_item.name)
        elif item is not None and getattr(item, 'name', None):
            ledger_entry['item_names'].add(item.name)

        if effective_karat is not None:
            ledger_entry['karats'].add(round(effective_karat, 3))

        if invoice.customer_id:
            customer_ids_needed.add(invoice.customer_id)
        if invoice.supplier_id:
            supplier_ids_needed.add(invoice.supplier_id)

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    timeline_payload = []
    top_inbound = None
    top_outbound = None

    for key in sorted(timeline_map.keys()):
        bucket = timeline_map[key]
        inbound_weight = round_weight(bucket['inbound_weight'])
        outbound_weight = round_weight(bucket['outbound_weight'])
        entry = {
            'label': bucket['label'],
            'start': bucket['start'].isoformat(),
            'end': bucket['end'].isoformat(),
            'inbound_weight_main_karat': inbound_weight,
            'outbound_weight_main_karat': outbound_weight,
            'net_weight_main_karat': round_weight(bucket['inbound_weight'] - bucket['outbound_weight']),
            'inbound_value': round_money(bucket['inbound_value']),
            'outbound_value': round_money(bucket['outbound_value']),
            'net_value': round_money(bucket['inbound_value'] - bucket['outbound_value']),
            'inbound_documents': len(bucket['inbound_docs']),
            'outbound_documents': len(bucket['outbound_docs']),
        }

        if inbound_weight > 0 and (not top_inbound or inbound_weight > top_inbound['inbound_weight_main_karat']):
            top_inbound = entry
        if outbound_weight > 0 and (not top_outbound or outbound_weight > top_outbound['outbound_weight_main_karat']):
            top_outbound = entry

        timeline_payload.append(entry)

    customer_name_map = {}
    if customer_ids_needed:
        customers = Customer.query.filter(Customer.id.in_(list(customer_ids_needed))).all()
        customer_name_map = {customer.id: customer.name for customer in customers}

    supplier_name_map = {}
    if supplier_ids_needed:
        suppliers = Supplier.query.filter(Supplier.id.in_(list(supplier_ids_needed))).all()
        supplier_name_map = {supplier.id: supplier.name for supplier in suppliers}

    ledger_entries = sorted(
        ledger_map.values(),
        key=lambda entry: entry['date'] or datetime.min,
        reverse=True,
    )

    movements_payload = []
    for entry in ledger_entries[:movements_limit]:
        party_name = customer_name_map.get(entry['customer_id']) if entry['customer_id'] else None
        if not party_name and entry['supplier_id']:
            party_name = supplier_name_map.get(entry['supplier_id'])

        movements_payload.append({
            'invoice_id': entry['invoice_id'],
            'invoice_type': entry['invoice_type'],
            'invoice_number': entry['invoice_type_id'],
            'direction': entry['direction'],
            'date': entry['date'].isoformat() if entry['date'] else None,
            'office_id': entry['office_id'],
            'office_name': entry['office_name'],
            'party_name': party_name,
            'line_count': entry['line_count'],
            'total_quantity': round_weight(entry['quantity']),
            'weight_main_karat': round_weight(entry['weight']),
            'value': round_money(entry['value']),
            'karats': sorted(entry['karats']),
            'sample_items': list(entry['item_names'])[:3],
        })

    net_direction = 'balanced'
    if summary_totals['net_weight'] > 0.0005:
        net_direction = 'inbound'
    elif summary_totals['net_weight'] < -0.0005:
        net_direction = 'outbound'

    summary = {
        'total_inbound_weight_main_karat': round_weight(summary_totals['inbound_weight']),
        'total_outbound_weight_main_karat': round_weight(summary_totals['outbound_weight']),
        'net_weight_main_karat': round_weight(summary_totals['net_weight']),
        'total_inbound_value': round_money(summary_totals['inbound_value']),
        'total_outbound_value': round_money(summary_totals['outbound_value']),
        'net_value': round_money(summary_totals['net_value']),
        'inbound_documents': len(inbound_doc_ids),
        'outbound_documents': len(outbound_doc_ids),
        'period_days': max(1, (end_dt - start_dt).days),
        'date_range': {
            'start': start_dt.date().isoformat(),
            'end': (end_dt - timedelta(seconds=1)).date().isoformat(),
        },
        'group_interval': group_interval,
        'top_inbound_bucket': top_inbound,
        'top_outbound_bucket': top_outbound,
        'net_direction': net_direction,
    }

    return jsonify({
        'summary': summary,
        'timeline': timeline_payload,
        'movements': movements_payload,
        'filters': {
            'start_date': start_dt.date().isoformat(),
            'end_date': (end_dt - timedelta(seconds=1)).date().isoformat(),
            'group_interval': group_interval,
            'include_unposted': include_unposted,
            'include_returns': include_returns,
            'karats': karat_filters,
            'office_ids': office_ids,
            'movements_limit': movements_limit,
        },
        'count': len(movements_payload),
    })


@api.route('/general_ledger_all', methods=['GET'])
def get_general_ledger_all():
    """
    دفتر الأستاذ العام - عرض جميع الحركات
    Query Parameters:
    - account_id: تصفية حسب الحساب
    - start_date: تاريخ البداية (YYYY-MM-DD)
    - end_date: تاريخ النهاية (YYYY-MM-DD)
    - show_balances: عرض الأرصدة التراكمية (true/false)
    - karat_detail: عرض تفاصيل الأعيرة (true/false)
    """
    # Get query parameters
    account_id = request.args.get('account_id', type=int)
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    show_balances = request.args.get('show_balances', 'true').lower() == 'true'
    karat_detail = request.args.get('karat_detail', 'false').lower() == 'true'


@api.route('/reports/sales_vs_purchases_trend', methods=['GET'])
def get_sales_vs_purchases_trend():
    """Sales vs Purchases Trend report (by day/week/month)

    Returns timeline buckets with totals for sales and purchases and basic margins.
    """
    start_date_param = request.args.get('start_date')
    end_date_param = request.args.get('end_date')
    group_interval = (request.args.get('group_interval') or 'day').lower()
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    gold_type = request.args.get('gold_type')

    valid_intervals = {'day', 'week', 'month'}
    if group_interval not in valid_intervals:
        group_interval = 'day'

    try:
        start_dt = None
        end_dt = None

        if start_date_param:
            start_value = _parse_iso_date(start_date_param, 'start_date')
            start_dt = datetime.combine(start_value, datetime.min.time())

        if end_date_param:
            end_value = _parse_iso_date(end_date_param, 'end_date')
            end_dt = datetime.combine(end_value, datetime.min.time()) + timedelta(days=1)
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    now = datetime.utcnow()
    if end_dt is None:
        end_dt = datetime.combine(now.date(), datetime.min.time()) + timedelta(days=1)
    if start_dt is None:
        start_dt = end_dt - timedelta(days=30)

    if end_dt <= start_dt:
        end_dt = start_dt + timedelta(days=1)

    # Determine invoice direction mapping (reuse logic similar to inventory)
    purchase_types = {'شراء', 'شراء من عميل', 'شراء من مورد'}
    sale_types = {'بيع', 'فاتورة بيع'}
    sale_return_types = {'مرتجع بيع'}
    purchase_return_types = {'مرتجع شراء', 'مرتجع شراء من مورد'}

    def determine_direction(invoice_type_value: str):
        normalized = (invoice_type_value or '').strip()
        if 'مرتجع' in normalized:
            # treat returns as opposite
            if 'بيع' in normalized:
                return 1
            if 'شراء' in normalized:
                return -1
        if normalized in purchase_types or ('شراء' in normalized and 'مرتجع' not in normalized):
            return 1
        if normalized in sale_types or ('بيع' in normalized and 'مرتجع' not in normalized):
            return -1
        return 0

    def bucket_key_for(date_value):
        if group_interval == 'week':
            return date_value - timedelta(days=date_value.weekday())
        if group_interval == 'month':
            return date_value.replace(day=1)
        return date_value

    def bucket_bounds(start_date_value):
        start_dt_value = datetime.combine(start_date_value, datetime.min.time())
        if group_interval == 'week':
            end_dt_value = start_dt_value + timedelta(days=7)
            label = f"{start_date_value.isocalendar()[0]}-W{start_date_value.isocalendar()[1]:02d}"
        elif group_interval == 'month':
            next_month = (start_date_value.replace(day=28) + timedelta(days=4)).replace(day=1)
            end_dt_value = datetime.combine(next_month, datetime.min.time())
            label = start_date_value.strftime('%Y-%m')
        else:
            end_dt_value = start_dt_value + timedelta(days=1)
            label = start_date_value.isoformat()
        return start_dt_value, end_dt_value, label

    timeline_map = {}

    def ensure_bucket(date_value):
        key = bucket_key_for(date_value)
        if key not in timeline_map:
            start_bound, end_bound, label = bucket_bounds(key)
            timeline_map[key] = {
                'label': label,
                'start': start_bound,
                'end': end_bound,
                'sales_total': 0.0,
                'purchases_total': 0.0,
                'sales_weight': 0.0,
                'purchases_weight': 0.0,
                'sales_count': 0,
                'purchases_count': 0,
                'sales_margin_cash': 0.0,
                'purchases_margin_cash': 0.0,
                'sales_margin_gold': 0.0,
                'purchases_margin_gold': 0.0,
            }
        return timeline_map[key]

    # Query invoices in date range with optional filters
    invoice_query = Invoice.query.filter(Invoice.date >= start_dt, Invoice.date < end_dt)
    if gold_type:
        invoice_query = invoice_query.filter(Invoice.gold_type == gold_type)
    if not include_unposted:
        invoice_query = invoice_query.filter(Invoice.is_posted == True)

    invoices = invoice_query.order_by(Invoice.date.asc()).all()

    summary = {
        'sales_total': 0.0,
        'purchases_total': 0.0,
        'sales_weight': 0.0,
        'purchases_weight': 0.0,
        'sales_margin_cash': 0.0,
        'purchases_margin_cash': 0.0,
        'sales_margin_gold': 0.0,
        'purchases_margin_gold': 0.0,
    }

    def safe_float(v):
        try:
            return float(v or 0.0)
        except (TypeError, ValueError):
            return 0.0

    for inv in invoices:
        if not inv.date:
            continue
        direction = determine_direction(inv.invoice_type)
        if direction == 0:
            continue

        # totals
        total_cash = safe_float(inv.total)
        weight = safe_float(inv.total_weight)
        # fallback: sum item weights if total_weight not present
        if not weight and inv.items:
            try:
                weight = sum((it.weight or 0.0) * (it.quantity or 1) for it in inv.items)
            except Exception:
                weight = 0.0

        bucket = ensure_bucket(inv.date.date())
        if direction < 0:
            # sale
            bucket['sales_total'] += total_cash
            bucket['sales_weight'] += weight
            bucket['sales_count'] += 1
            bucket['sales_margin_cash'] += safe_float(inv.profit_cash)
            bucket['sales_margin_gold'] += safe_float(inv.profit_gold)
            summary['sales_total'] += total_cash
            summary['sales_weight'] += weight
            summary['sales_margin_cash'] += safe_float(inv.profit_cash)
            summary['sales_margin_gold'] += safe_float(inv.profit_gold)
        else:
            # purchase
            bucket['purchases_total'] += total_cash
            bucket['purchases_weight'] += weight
            bucket['purchases_count'] += 1
            bucket['purchases_margin_cash'] += safe_float(inv.profit_cash)
            bucket['purchases_margin_gold'] += safe_float(inv.profit_gold)
            summary['purchases_total'] += total_cash
            summary['purchases_weight'] += weight
            summary['purchases_margin_cash'] += safe_float(inv.profit_cash)
            summary['purchases_margin_gold'] += safe_float(inv.profit_gold)

    def round_money(v):
        return round(float(v or 0.0), 2)

    def round_weight(v):
        return round(float(v or 0.0), 3)

    timeline_payload = []
    for key in sorted(timeline_map.keys()):
        b = timeline_map[key]
        timeline_payload.append({
            'label': b['label'],
            'start': b['start'].isoformat(),
            'end': b['end'].isoformat(),
            'sales_total': round_money(b['sales_total']),
            'purchases_total': round_money(b['purchases_total']),
            'net_total': round_money(b['sales_total'] - b['purchases_total']),
            'sales_weight': round_weight(b['sales_weight']),
            'purchases_weight': round_weight(b['purchases_weight']),
            'net_weight': round_weight(b['sales_weight'] - b['purchases_weight']),
            'sales_count': b['sales_count'],
            'purchases_count': b['purchases_count'],
            'sales_margin_cash': round_money(b['sales_margin_cash']),
            'purchases_margin_cash': round_money(b['purchases_margin_cash']),
            'sales_margin_gold': round_weight(b['sales_margin_gold']),
            'purchases_margin_gold': round_weight(b['purchases_margin_gold']),
        })

    summary_payload = {
        'sales_total': round_money(summary['sales_total']),
        'purchases_total': round_money(summary['purchases_total']),
        'net_total': round_money(summary['sales_total'] - summary['purchases_total']),
        'sales_weight': round_weight(summary['sales_weight']),
        'purchases_weight': round_weight(summary['purchases_weight']),
        'net_weight': round_weight(summary['sales_weight'] - summary['purchases_weight']),
        'sales_margin_cash': round_money(summary['sales_margin_cash']),
        'purchases_margin_cash': round_money(summary['purchases_margin_cash']),
        'sales_margin_gold': round_weight(summary['sales_margin_gold']),
        'purchases_margin_gold': round_weight(summary['purchases_margin_gold']),
    }

    return jsonify({
        'summary': summary_payload,
        'timeline': timeline_payload,
        'filters': {
            'start_date': start_dt.date().isoformat(),
            'end_date': (end_dt - timedelta(seconds=1)).date().isoformat(),
            'group_interval': group_interval,
            'include_unposted': include_unposted,
            'gold_type': gold_type,
        },
        'count': len(timeline_payload),
    })


@api.route('/reports/customer_balances_aging', methods=['GET'])
def get_customer_balances_aging():
    """Aging analysis for customer balances (cash + gold)."""

    cutoff_param = request.args.get('cutoff_date')
    include_zero_balances = request.args.get('include_zero_balances', 'false').lower() == 'true'
    include_unposted = request.args.get('include_unposted', 'false').lower() == 'true'
    group_param = request.args.get('customer_group_id') or request.args.get('account_category_id')
    top_limit_param = request.args.get('top_limit')

    try:
        cutoff_value = _parse_iso_date(cutoff_param, 'cutoff_date') if cutoff_param else None
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    cutoff_date = cutoff_value or datetime.utcnow().date()
    cutoff_end = datetime.combine(cutoff_date, datetime.min.time()) + timedelta(days=1)

    try:
        top_limit = int(top_limit_param) if top_limit_param else 5
    except ValueError:
        return jsonify({'error': 'Invalid top_limit parameter'}), 400
    top_limit = max(3, min(top_limit, 25))

    customer_group_id = None
    if group_param not in (None, ''):
        try:
            customer_group_id = int(group_param)
        except ValueError:
            return jsonify({'error': 'customer_group_id must be numeric'}), 400

    invoice_query = (
        Invoice.query.options(
            joinedload(Invoice.customer).joinedload(Customer.account_category)
        )
        .filter(Invoice.customer_id.isnot(None))
        .filter(Invoice.date < cutoff_end)
    )

    if not include_unposted:
        invoice_query = invoice_query.filter(Invoice.is_posted == True)

    if customer_group_id is not None:
        invoice_query = invoice_query.join(Customer, Customer.id == Invoice.customer_id)
        invoice_query = invoice_query.filter(Customer.account_category_id == customer_group_id)

    invoices = invoice_query.all()

    invoice_ids = [invoice.id for invoice in invoices]
    payments_map = {}
    if invoice_ids:
        payment_rows = (
            db.session.query(
                InvoicePayment.invoice_id,
                func.coalesce(func.sum(InvoicePayment.amount), 0.0).label('total_payments'),
            )
            .filter(InvoicePayment.invoice_id.in_(invoice_ids))
            .group_by(InvoicePayment.invoice_id)
            .all()
        )
        payments_map = {row.invoice_id: float(row.total_payments or 0.0) for row in payment_rows}

    bucket_keys = ['current', 'days_31_60', 'days_61_90', 'over_90']
    bucket_labels = {
        'current': {'ar': 'حالي (0-30)', 'en': 'Current (0-30)'},
        'days_31_60': {'ar': 'متأخر 31-60 يوم', 'en': 'Past Due 31-60'},
        'days_61_90': {'ar': 'متأخر 61-90 يوم', 'en': 'Past Due 61-90'},
        'over_90': {'ar': 'أكثر من 90 يوم', 'en': 'Over 90'},
    }

    def classify_bucket(days_overdue: int) -> str:
        if days_overdue <= 30:
            return 'current'
        if days_overdue <= 60:
            return 'days_31_60'
        if days_overdue <= 90:
            return 'days_61_90'
        return 'over_90'

    def round_money(value):
        return round(float(value or 0.0), 2)

    def round_weight(value):
        return round(float(value or 0.0), 3)

    customer_entries = {}
    summary_bucket_cash = {key: 0.0 for key in bucket_keys}
    summary_bucket_weight = {key: 0.0 for key in bucket_keys}
    summary_credit_cash = 0.0
    summary_credit_weight = 0.0

    def ensure_customer_entry(customer_obj):
        entry = customer_entries.get(customer_obj.id)
        if entry is None:
            entry = {
                'customer_id': customer_obj.id,
                'customer_code': customer_obj.customer_code,
                'customer_name': customer_obj.name,
                'account_category_id': customer_obj.account_category_id,
                'account_category_name': customer_obj.account_category.name if customer_obj.account_category else None,
                'buckets': {
                    key: {'cash': 0.0, 'weight': 0.0, 'invoice_count': 0}
                    for key in bucket_keys
                },
                'outstanding_cash': 0.0,
                'outstanding_weight': 0.0,
                'credit_cash': 0.0,
                'credit_weight': 0.0,
                'invoice_count': 0,
                'open_invoice_count': 0,
                'last_invoice_date': None,
                'oldest_invoice_date': None,
                'total_days_overdue': 0.0,
                'due_invoices_count': 0,
                'recent_invoices': [],
            }
            customer_entries[customer_obj.id] = entry
        return entry

    def normalize_direction(invoice_type_value: str) -> int:
        normalized = (invoice_type_value or '').strip()
        if 'مرتجع' in normalized and 'بيع' in normalized:
            return -1
        if 'بيع' in normalized:
            return 1
        if normalized == 'فاتورة بيع':
            return 1
        return 0

    for invoice in invoices:
        direction = normalize_direction(invoice.invoice_type)
        if direction == 0:
            continue

        customer_obj = invoice.customer
        if not customer_obj:
            continue

        entry = ensure_customer_entry(customer_obj)
        entry['invoice_count'] += 1

        invoice_date = invoice.date.date() if invoice.date else cutoff_date
        if entry['last_invoice_date'] is None or invoice_date > entry['last_invoice_date']:
            entry['last_invoice_date'] = invoice_date
        if entry['oldest_invoice_date'] is None or invoice_date < entry['oldest_invoice_date']:
            entry['oldest_invoice_date'] = invoice_date

        invoice_total_cash = invoice.net_amount if invoice.net_amount is not None else invoice.total or 0.0
        paid_amount = invoice.amount_paid if invoice.amount_paid is not None else payments_map.get(invoice.id, 0.0)
        open_cash = (invoice_total_cash - paid_amount) * direction

        total_weight = invoice.total_weight or 0.0
        settled_weight = invoice.settled_gold_weight or invoice.payment_gold_weight or 0.0
        open_weight = (total_weight - settled_weight) * direction

        cash_positive = open_cash > 0.0005
        weight_positive = open_weight > 0.0005

        negative_cash = abs(open_cash) if open_cash < -0.0005 else 0.0
        negative_weight = abs(open_weight) if open_weight < -0.0005 else 0.0
        if negative_cash:
            summary_credit_cash += negative_cash
            if include_zero_balances:
                entry['credit_cash'] += round_money(negative_cash)
        if negative_weight:
            summary_credit_weight += negative_weight
            if include_zero_balances:
                entry['credit_weight'] += round_weight(negative_weight)

        if not (cash_positive or weight_positive):
            continue

        days_overdue = max(0, (cutoff_date - invoice_date).days)
        bucket_key = classify_bucket(days_overdue)
        bucket_data = entry['buckets'][bucket_key]
        bucket_added = False

        if cash_positive:
            value = round_money(open_cash)
            bucket_data['cash'] += value
            entry['outstanding_cash'] += value
            summary_bucket_cash[bucket_key] += value
            entry['total_days_overdue'] += days_overdue
            entry['due_invoices_count'] += 1
            bucket_added = True

        if weight_positive:
            weight_value = round_weight(open_weight)
            bucket_data['weight'] += weight_value
            entry['outstanding_weight'] += weight_value
            summary_bucket_weight[bucket_key] += weight_value
            bucket_added = True

        if bucket_added:
            bucket_data['invoice_count'] += 1
            entry['open_invoice_count'] += 1
            if len(entry['recent_invoices']) < 5:
                entry['recent_invoices'].append({
                    'invoice_id': invoice.id,
                    'invoice_number': invoice.invoice_type_id,
                    'date': invoice.date.isoformat() if invoice.date else None,
                    'days_overdue': days_overdue,
                    'open_cash': round_money(open_cash) if cash_positive else 0.0,
                    'open_weight': round_weight(open_weight) if weight_positive else 0.0,
                })

    customers_payload = []
    for entry in customer_entries.values():
        outstanding_cash = round_money(entry['outstanding_cash'])
        outstanding_weight = round_weight(entry['outstanding_weight'])
        if not include_zero_balances and outstanding_cash <= 0.0 and outstanding_weight <= 0.0:
            continue

        avg_days = 0.0
        if entry['due_invoices_count'] > 0:
            avg_days = round(entry['total_days_overdue'] / entry['due_invoices_count'], 1)

        customers_payload.append({
            'customer_id': entry['customer_id'],
            'customer_code': entry['customer_code'],
            'customer_name': entry['customer_name'],
            'account_category_id': entry['account_category_id'],
            'account_category_name': entry['account_category_name'],
            'outstanding_cash': outstanding_cash,
            'outstanding_weight': outstanding_weight,
            'credit_cash': round_money(entry['credit_cash']),
            'credit_weight': round_weight(entry['credit_weight']),
            'average_days_overdue': avg_days,
            'last_invoice_date': entry['last_invoice_date'].isoformat() if entry['last_invoice_date'] else None,
            'oldest_invoice_date': entry['oldest_invoice_date'].isoformat() if entry['oldest_invoice_date'] else None,
            'invoice_count': entry['invoice_count'],
            'open_invoice_count': entry['open_invoice_count'],
            'buckets': {
                key: {
                    'cash': round_money(entry['buckets'][key]['cash']),
                    'weight': round_weight(entry['buckets'][key]['weight'])
                }
                for key in bucket_keys
            },
            'recent_invoices': entry['recent_invoices'],
        })

    customers_payload.sort(key=lambda item: (item['outstanding_cash'], item['outstanding_weight']), reverse=True)

    def overdue_score(item):
        over_90_cash = item['buckets']['over_90']['cash']
        if over_90_cash and over_90_cash > 0:
            return over_90_cash
        return item['outstanding_cash'] * 0.1

    top_overdue_customers = sorted(customers_payload, key=overdue_score, reverse=True)[:top_limit]

    summary = {
        'total_customers': len(customers_payload),
        'total_outstanding_cash': round_money(sum(summary_bucket_cash.values())),
        'total_outstanding_weight': round_weight(sum(summary_bucket_weight.values())),
        'bucket_cash': {key: round_money(value) for key, value in summary_bucket_cash.items()},
        'bucket_weight': {key: round_weight(value) for key, value in summary_bucket_weight.items()},
        'credit_balances_cash': round_money(summary_credit_cash),
        'credit_balances_weight': round_weight(summary_credit_weight),
    }

    return jsonify({
        'summary': summary,
        'customers': customers_payload,
        'top_overdue_customers': top_overdue_customers,
        'buckets': bucket_labels,
        'filters': {
            'cutoff_date': cutoff_date.isoformat(),
            'include_zero_balances': include_zero_balances,
            'include_unposted': include_unposted,
            'customer_group_id': customer_group_id,
            'top_limit': top_limit,
        },
        'count': len(customers_payload),
    })
    
    # Build query
    query = JournalEntryLine.query.join(JournalEntry).filter(JournalEntryLine.is_deleted == False)
    
    # Apply filters
    if account_id:
        query = query.filter(JournalEntryLine.account_id == account_id)
    
    if start_date:
        from datetime import datetime
        start_dt = datetime.strptime(start_date, '%Y-%m-%d')
        query = query.filter(JournalEntry.date >= start_dt)
    
    if end_date:
        from datetime import datetime
        end_dt = datetime.strptime(end_date, '%Y-%m-%d')
        query = query.filter(JournalEntry.date <= end_dt)
    
    # Order by date and id
    lines = query.order_by(JournalEntry.date.asc(), JournalEntry.id.asc()).all()
    
    # Calculate running balances
    running_cash_balance = 0
    running_gold_18k = 0
    running_gold_21k = 0
    running_gold_22k = 0
    running_gold_24k = 0
    
    result = []
    for line in lines:
        # Calculate normalized gold for main view
        gold_debit_normalized = (
            convert_to_main_karat(line.debit_18k or 0, 18) +
            convert_to_main_karat(line.debit_21k or 0, 21) +
            convert_to_main_karat(line.debit_22k or 0, 22) +
            convert_to_main_karat(line.debit_24k or 0, 24)
        )
        gold_credit_normalized = (
            convert_to_main_karat(line.credit_18k or 0, 18) +
            convert_to_main_karat(line.credit_21k or 0, 21) +
            convert_to_main_karat(line.credit_22k or 0, 22) +
            convert_to_main_karat(line.credit_24k or 0, 24)
        )
        
        # Update running balances
        running_cash_balance += (line.cash_debit or 0) - (line.cash_credit or 0)
        running_gold_18k += (line.debit_18k or 0) - (line.credit_18k or 0)
        running_gold_21k += (line.debit_21k or 0) - (line.credit_21k or 0)
        running_gold_22k += (line.debit_22k or 0) - (line.credit_22k or 0)
        running_gold_24k += (line.debit_24k or 0) - (line.credit_24k or 0)
        
        entry_data = {
            'id': line.id,
            'journal_entry_id': line.journal_entry.id,
            'date': line.journal_entry.date.isoformat(),
            'type': 'Journal Entry',
            'description': line.journal_entry.description or line.description,
            'account_id': line.account_id,
            'account_name': line.account.name if line.account else 'Unknown Account',
            'account_number': line.account.account_number if line.account else 'N/A',
            'cash_debit': round(line.cash_debit or 0, 2),
            'cash_credit': round(line.cash_credit or 0, 2),
            'gold_debit': round(gold_debit_normalized, 3),
            'gold_credit': round(gold_credit_normalized, 3),
        }
        
        # Add karat details if requested
        if karat_detail:
            entry_data['karat_details'] = {
                '18k': {
                    'debit': round(line.debit_18k or 0, 3),
                    'credit': round(line.credit_18k or 0, 3)
                },
                '21k': {
                    'debit': round(line.debit_21k or 0, 3),
                    'credit': round(line.credit_21k or 0, 3)
                },
                '22k': {
                    'debit': round(line.debit_22k or 0, 3),
                    'credit': round(line.credit_22k or 0, 3)
                },
                '24k': {
                    'debit': round(line.debit_24k or 0, 3),
                    'credit': round(line.credit_24k or 0, 3)
                }
            }
        
        # Add running balances if requested
        if show_balances:
            entry_data['running_balance'] = {
                'cash': round(running_cash_balance, 2),
                'gold_normalized': round(
                    convert_to_main_karat(running_gold_18k, 18) +
                    convert_to_main_karat(running_gold_21k, 21) +
                    convert_to_main_karat(running_gold_22k, 22) +
                    convert_to_main_karat(running_gold_24k, 24),
                    3
                )
            }
            
            if karat_detail:
                entry_data['running_balance']['by_karat'] = {
                    '18k': round(running_gold_18k, 3),
                    '21k': round(running_gold_21k, 3),
                    '22k': round(running_gold_22k, 3),
                    '24k': round(running_gold_24k, 3)
                }
        
        result.append(entry_data)
    
    # Summary
    summary = {
        'total_entries': len(result),
        'final_balance': {
            'cash': round(running_cash_balance, 2),
            'gold_normalized': round(
                convert_to_main_karat(running_gold_18k, 18) +
                convert_to_main_karat(running_gold_21k, 21) +
                convert_to_main_karat(running_gold_22k, 22) +
                convert_to_main_karat(running_gold_24k, 24),
                3
            )
        }
    }
    
    if karat_detail:
        summary['final_balance']['by_karat'] = {
            '18k': round(running_gold_18k, 3),
            '21k': round(running_gold_21k, 3),
            '22k': round(running_gold_22k, 3),
            '24k': round(running_gold_24k, 3)
        }
    
    return jsonify({
        'entries': result,
        'summary': summary,
        'filters': {
            'account_id': account_id,
            'start_date': start_date,
            'end_date': end_date,
            'show_balances': show_balances,
            'karat_detail': karat_detail
        }
    })


@api.route('/account_ledger/<int:account_id>', methods=['GET'])
def get_account_ledger(account_id):
    """
    دفتر الأستاذ لحساب محدد مع تفاصيل كاملة
    Query Parameters:
    - start_date: تاريخ البداية (YYYY-MM-DD)
    - end_date: تاريخ النهاية (YYYY-MM-DD)
    - karat_detail: عرض تفاصيل الأعيرة (true/false)
    """
    # Get account
    account = Account.query.get_or_404(account_id)
    
    # Get query parameters
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    karat_detail = request.args.get('karat_detail', 'true').lower() == 'true'
    
    # Build query
    query = JournalEntryLine.query.join(JournalEntry).filter(
        JournalEntryLine.account_id == account_id,
        JournalEntryLine.is_deleted == False
    )
    
    # Apply date filters
    if start_date:
        from datetime import datetime
        start_dt = datetime.strptime(start_date, '%Y-%m-%d')
        query = query.filter(JournalEntry.date >= start_dt)
    
    if end_date:
        from datetime import datetime
        end_dt = datetime.strptime(end_date, '%Y-%m-%d')
        query = query.filter(JournalEntry.date <= end_dt)
    
    # Get opening balance (before start_date if specified)
    opening_cash = 0
    opening_18k = 0
    opening_21k = 0
    opening_22k = 0
    opening_24k = 0
    
    if start_date:
        opening_query = JournalEntryLine.query.join(JournalEntry).filter(
            JournalEntryLine.account_id == account_id,
            JournalEntryLine.is_deleted == False,
            JournalEntry.date < start_dt
        )
        
        opening_lines = opening_query.all()
        for line in opening_lines:
            opening_cash += (line.cash_debit or 0) - (line.cash_credit or 0)
            opening_18k += (line.debit_18k or 0) - (line.credit_18k or 0)
            opening_21k += (line.debit_21k or 0) - (line.credit_21k or 0)
            opening_22k += (line.debit_22k or 0) - (line.credit_22k or 0)
            opening_24k += (line.debit_24k or 0) - (line.credit_24k or 0)
    
    # Order by date
    lines = query.order_by(JournalEntry.date.asc(), JournalEntry.id.asc()).all()
    
    # Calculate running balances
    running_cash = opening_cash
    running_18k = opening_18k
    running_21k = opening_21k
    running_22k = opening_22k
    running_24k = opening_24k
    
    result = []
    for line in lines:
        # Calculate normalized gold
        gold_debit_normalized = (
            convert_to_main_karat(line.debit_18k or 0, 18) +
            convert_to_main_karat(line.debit_21k or 0, 21) +
            convert_to_main_karat(line.debit_22k or 0, 22) +
            convert_to_main_karat(line.debit_24k or 0, 24)
        )
        gold_credit_normalized = (
            convert_to_main_karat(line.credit_18k or 0, 18) +
            convert_to_main_karat(line.credit_21k or 0, 21) +
            convert_to_main_karat(line.credit_22k or 0, 22) +
            convert_to_main_karat(line.credit_24k or 0, 24)
        )
        
        # Update running balances
        running_cash += (line.cash_debit or 0) - (line.cash_credit or 0)
        running_18k += (line.debit_18k or 0) - (line.credit_18k or 0)
        running_21k += (line.debit_21k or 0) - (line.credit_21k or 0)
        running_22k += (line.debit_22k or 0) - (line.credit_22k or 0)
        running_24k += (line.debit_24k or 0) - (line.credit_24k or 0)
        
        entry_data = {
            'id': line.id,
            'journal_entry_id': line.journal_entry.id,
            'date': line.journal_entry.date.isoformat(),
            'description': line.journal_entry.description or line.description,
            'cash_debit': round(line.cash_debit or 0, 2),
            'cash_credit': round(line.cash_credit or 0, 2),
            'gold_debit': round(gold_debit_normalized, 3),
            'gold_credit': round(gold_credit_normalized, 3),
            'running_balance': {
                'cash': round(running_cash, 2),
                'gold_normalized': round(
                    convert_to_main_karat(running_18k, 18) +
                    convert_to_main_karat(running_21k, 21) +
                    convert_to_main_karat(running_22k, 22) +
                    convert_to_main_karat(running_24k, 24),
                    3
                )
            }
        }
        
        # Add karat details
        if karat_detail:
            entry_data['karat_details'] = {
                '18k': {
                    'debit': round(line.debit_18k or 0, 3),
                    'credit': round(line.credit_18k or 0, 3)
                },
                '21k': {
                    'debit': round(line.debit_21k or 0, 3),
                    'credit': round(line.credit_21k or 0, 3)
                },
                '22k': {
                    'debit': round(line.debit_22k or 0, 3),
                    'credit': round(line.credit_22k or 0, 3)
                },
                '24k': {
                    'debit': round(line.debit_24k or 0, 3),
                    'credit': round(line.credit_24k or 0, 3)
                }
            }
            entry_data['running_balance']['by_karat'] = {
                '18k': round(running_18k, 3),
                '21k': round(running_21k, 3),
                '22k': round(running_22k, 3),
                '24k': round(running_24k, 3)
            }
        
        result.append(entry_data)
    
    # Summary
    return jsonify({
        'account': {
            'id': account.id,
            'name': account.name,
            'number': account.account_number,
            'type': account.account_type
        },
        'opening_balance': {
            'cash': round(opening_cash, 2),
            'gold_normalized': round(
                convert_to_main_karat(opening_18k, 18) +
                convert_to_main_karat(opening_21k, 21) +
                convert_to_main_karat(opening_22k, 22) +
                convert_to_main_karat(opening_24k, 24),
                3
            ),
            'by_karat': {
                '18k': round(opening_18k, 3),
                '21k': round(opening_21k, 3),
                '22k': round(opening_22k, 3),
                '24k': round(opening_24k, 3)
            } if karat_detail else None
        },
        'closing_balance': {
            'cash': round(running_cash, 2),
            'gold_normalized': round(
                convert_to_main_karat(running_18k, 18) +
                convert_to_main_karat(running_21k, 21) +
                convert_to_main_karat(running_22k, 22) +
                convert_to_main_karat(running_24k, 24),
                3
            ),
            'by_karat': {
                '18k': round(running_18k, 3),
                '21k': round(running_21k, 3),
                '22k': round(running_22k, 3),
                '24k': round(running_24k, 3)
            } if karat_detail else None
        },
        'entries': result,
        'total_entries': len(result),
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'karat_detail': karat_detail
        }
    })


@api.route('/trial_balance', methods=['GET'])
def get_trial_balance():
    """
    Enhanced Trial Balance with date filtering and karat detail support
    Query Parameters:
    - start_date: Filter entries from this date (YYYY-MM-DD)
    - end_date: Filter entries to this date (YYYY-MM-DD)
    - karat_detail: If true, return karat breakdown; if false, return normalized totals
    """
    # Get optional query parameters
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')
    karat_detail = request.args.get('karat_detail', 'false').lower() == 'true'
    
    # Start building the query
    query = db.session.query(
        Account.id,
        Account.name,
        Account.account_number,
        func.sum(JournalEntryLine.cash_debit).label('total_cash_debit'),
        func.sum(JournalEntryLine.cash_credit).label('total_cash_credit'),
        func.sum(JournalEntryLine.debit_18k).label('total_debit_18k'),
        func.sum(JournalEntryLine.credit_18k).label('total_credit_18k'),
        func.sum(JournalEntryLine.debit_21k).label('total_debit_21k'),
        func.sum(JournalEntryLine.credit_21k).label('total_credit_21k'),
        func.sum(JournalEntryLine.debit_22k).label('total_debit_22k'),
        func.sum(JournalEntryLine.credit_22k).label('total_credit_22k'),
        func.sum(JournalEntryLine.debit_24k).label('total_debit_24k'),
        func.sum(JournalEntryLine.credit_24k).label('total_credit_24k')
    ).join(Account).join(JournalEntry)
    
    # Apply date filters if provided
    if start_date:
        try:
            start_dt = datetime.strptime(start_date, '%Y-%m-%d')
            query = query.filter(JournalEntry.entry_date >= start_dt)
        except ValueError:
            return jsonify({'error': 'Invalid start_date format. Use YYYY-MM-DD'}), 400
    
    if end_date:
        try:
            end_dt = datetime.strptime(end_date, '%Y-%m-%d')
            query = query.filter(JournalEntry.entry_date <= end_dt)
        except ValueError:
            return jsonify({'error': 'Invalid end_date format. Use YYYY-MM-DD'}), 400
    
    query_result = query.group_by(Account.id, Account.name, Account.account_number).all()

    trial_balance = []
    
    # Initialize grand totals
    if karat_detail:
        totals = {
            'cash_debit': 0, 'cash_credit': 0,
            'debit_18k': 0, 'credit_18k': 0,
            'debit_21k': 0, 'credit_21k': 0,
            'debit_22k': 0, 'credit_22k': 0,
            'debit_24k': 0, 'credit_24k': 0,
        }
    else:
        totals = {
            'gold_debit': 0, 'gold_credit': 0,
            'cash_debit': 0, 'cash_credit': 0,
        }

    for row in query_result:
        cash_debit = row.total_cash_debit or 0
        cash_credit = row.total_cash_credit or 0
        
        if karat_detail:
            # Return karat breakdown
            debit_18k = row.total_debit_18k or 0
            credit_18k = row.total_credit_18k or 0
            debit_21k = row.total_debit_21k or 0
            credit_21k = row.total_credit_21k or 0
            debit_22k = row.total_debit_22k or 0
            credit_22k = row.total_credit_22k or 0
            debit_24k = row.total_debit_24k or 0
            credit_24k = row.total_credit_24k or 0
            
            # Only add accounts that have transactions
            if any([cash_debit, cash_credit, debit_18k, credit_18k, debit_21k, credit_21k, 
                    debit_22k, credit_22k, debit_24k, credit_24k]):
                
                # Calculate balances for each karat
                balance_18k = debit_18k - credit_18k
                balance_21k = debit_21k - credit_21k
                balance_22k = debit_22k - credit_22k
                balance_24k = debit_24k - credit_24k
                cash_balance = cash_debit - cash_credit
                
                trial_balance.append({
                    'account_id': row.id,
                    'account_number': row.account_number,
                    'account_name': row.name,
                    'cash_debit': cash_debit,
                    'cash_credit': cash_credit,
                    'cash_balance': cash_balance,
                    'debit_18k': debit_18k,
                    'credit_18k': credit_18k,
                    'balance_18k': balance_18k,
                    'debit_21k': debit_21k,
                    'credit_21k': credit_21k,
                    'balance_21k': balance_21k,
                    'debit_22k': debit_22k,
                    'credit_22k': credit_22k,
                    'balance_22k': balance_22k,
                    'debit_24k': debit_24k,
                    'credit_24k': credit_24k,
                    'balance_24k': balance_24k,
                })
                
                # Update totals
                totals['cash_debit'] += cash_debit
                totals['cash_credit'] += cash_credit
                totals['debit_18k'] += debit_18k
                totals['credit_18k'] += credit_18k
                totals['debit_21k'] += debit_21k
                totals['credit_21k'] += credit_21k
                totals['debit_22k'] += debit_22k
                totals['credit_22k'] += credit_22k
                totals['debit_24k'] += debit_24k
                totals['credit_24k'] += credit_24k
        else:
            # Normalize gold weights to main karat
            gold_debit = (
                convert_to_main_karat(row.total_debit_18k or 0, 18) +
                convert_to_main_karat(row.total_debit_21k or 0, 21) +
                convert_to_main_karat(row.total_debit_22k or 0, 22) +
                convert_to_main_karat(row.total_debit_24k or 0, 24)
            )
            gold_credit = (
                convert_to_main_karat(row.total_credit_18k or 0, 18) +
                convert_to_main_karat(row.total_credit_21k or 0, 21) +
                convert_to_main_karat(row.total_credit_22k or 0, 22) +
                convert_to_main_karat(row.total_credit_24k or 0, 24)
            )
            
            # Only add accounts that have transactions
            if gold_debit != 0 or gold_credit != 0 or cash_debit != 0 or cash_credit != 0:
                gold_balance = gold_debit - gold_credit
                cash_balance = cash_debit - cash_credit
                
                trial_balance.append({
                    'account_id': row.id,
                    'account_number': row.account_number,
                    'account_name': row.name,
                    'gold_debit': gold_debit,
                    'gold_credit': gold_credit,
                    'gold_balance': gold_balance,
                    'cash_debit': cash_debit,
                    'cash_credit': cash_credit,
                    'cash_balance': cash_balance,
                })
                
                totals['gold_debit'] += gold_debit
                totals['gold_credit'] += gold_credit
                totals['cash_debit'] += cash_debit
                totals['cash_credit'] += cash_credit

    # Calculate total balances
    if karat_detail:
        totals['cash_balance'] = totals['cash_debit'] - totals['cash_credit']
        totals['balance_18k'] = totals['debit_18k'] - totals['credit_18k']
        totals['balance_21k'] = totals['debit_21k'] - totals['credit_21k']
        totals['balance_22k'] = totals['debit_22k'] - totals['credit_22k']
        totals['balance_24k'] = totals['debit_24k'] - totals['credit_24k']
    else:
        totals['gold_balance'] = totals['gold_debit'] - totals['gold_credit']
        totals['cash_balance'] = totals['cash_debit'] - totals['cash_credit']

    return jsonify({
        'trial_balance': trial_balance,
        'totals': totals,
        'filters': {
            'start_date': start_date,
            'end_date': end_date,
            'karat_detail': karat_detail,
        },
        'count': len(trial_balance),
    })

@api.route('/customers/<int:id>', methods=['PUT'])
def update_customer(id):
    """
    تحديث بيانات العميل (النظام الهجين)
    لا يتم تحديث customer_code بعد الإنشاء
    """
    customer = Customer.query.get_or_404(id)
    data = request.json

    # Update customer details (but not customer_code)
    customer.name = data.get('name', customer.name)
    customer.phone = data.get('phone', customer.phone)
    customer.email = data.get('email', customer.email)
    customer.address_line_1 = data.get('address_line_1', customer.address_line_1)
    customer.address_line_2 = data.get('address_line_2', customer.address_line_2)
    customer.city = data.get('city', customer.city)
    customer.state = data.get('state', customer.state)
    customer.postal_code = data.get('postal_code', customer.postal_code)
    customer.country = data.get('country', customer.country)
    customer.id_number = data.get('id_number', customer.id_number)
    
    birth_date_str = data.get('birth_date')
    if birth_date_str:
        try:
            customer.birth_date = datetime.strptime(birth_date_str, '%Y-%m-%d').date()
        except (ValueError, TypeError):
            pass
    
    customer.id_version_number = data.get('id_version_number', customer.id_version_number)
    customer.notes = data.get('notes', customer.notes)
    customer.active = data.get('active', customer.active)
    
    # Allow updating account_category if needed
    if 'account_category_number' in data:
        account_category = Account.query.filter_by(account_number=data['account_category_number']).first()
        if account_category:
            customer.account_category_id = account_category.id

    try:
        db.session.commit()
        return jsonify(customer.to_dict_with_account())
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update customer: {str(e)}'}), 500


# ============================================================================
# Employees API Routes (نظام الموظفين)
# ============================================================================

@api.route('/employees', methods=['GET'])
def list_employees():
    """إرجاع قائمة الموظفين مع دعم التصفية والبحث"""
    query = Employee.query

    is_active = request.args.get('is_active')
    if is_active is not None:
        if is_active.lower() in ['1', 'true', 'yes']:
            query = query.filter_by(is_active=True)
        elif is_active.lower() in ['0', 'false', 'no']:
            query = query.filter_by(is_active=False)

    department = request.args.get('department')
    if department:
        query = query.filter(Employee.department.ilike(f'%{department}%'))

    search = request.args.get('search')
    if search:
        search_term = f'%{search}%'
        query = query.filter(
            or_(
                Employee.name.ilike(search_term),
                Employee.employee_code.ilike(search_term),
                Employee.phone.ilike(search_term),
                Employee.email.ilike(search_term),
            )
        )

    page = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 20, type=int)

    pagination = query.order_by(Employee.name.asc()).paginate(page=page, per_page=per_page, error_out=False)

    return jsonify({
        'employees': [employee.to_dict(include_details=True) for employee in pagination.items],
        'total': pagination.total,
        'pages': pagination.pages,
        'current_page': pagination.page,
        'per_page': pagination.per_page,
    })


@api.route('/employees', methods=['POST'])
def create_employee():
    """إنشاء موظف جديد مع حساب تلقائي"""
    from employee_account_helpers import create_employee_account, get_employee_department_from_code
    
    data = request.get_json() or {}

    name = data.get('name')
    if not name:
        return jsonify({'error': 'اسم الموظف مطلوب'}), 400

    employee_code = data.get('employee_code') or _generate_employee_code()

    if Employee.query.filter_by(employee_code=employee_code).first():
        return jsonify({'error': 'كود الموظف مستخدم بالفعل'}), 400

    # إنشاء حساب تلقائي للموظف إذا لم يُحدد account_id
    account_id = data.get('account_id')
    auto_created_account = None
    
    if not account_id:
        try:
            # تحديد القسم من البيانات المُدخلة أو استخدام الافتراضي
            department_input = data.get('department', '').lower()
            
            # تحويل اسم القسم العربي إلى الإنجليزي
            department_mapping = {
                'إدارة': 'administration',
                'مبيعات': 'sales',
                'صيانة': 'maintenance',
                'محاسبة': 'accounting',
                'مستودعات': 'warehouse',
                'administration': 'administration',
                'sales': 'sales',
                'maintenance': 'maintenance',
                'accounting': 'accounting',
                'warehouse': 'warehouse',
            }
            
            department = department_mapping.get(department_input, 'administration')
            
            # إنشاء الحساب
            auto_created_account = create_employee_account(
                employee_name=name,
                department=department,
                created_by=data.get('created_by', 'system')
            )
            account_id = auto_created_account.id
            
        except Exception as e:
            return jsonify({
                'error': f'فشل إنشاء الحساب التلقائي: {str(e)}',
                'hint': 'تأكد من تشغيل seed_employee_accounts.py لإنشاء الحسابات التجميعية'
            }), 500

    employee = Employee(
        employee_code=employee_code,
        name=name,
        job_title=data.get('job_title'),
        department=data.get('department'),
        phone=data.get('phone'),
        email=data.get('email'),
        national_id=data.get('national_id'),
        salary=data.get('salary') or 0.0,
        hire_date=_parse_iso_date(data.get('hire_date'), 'hire_date'),
        termination_date=_parse_iso_date(data.get('termination_date'), 'termination_date'),
        account_id=account_id,
        is_active=data.get('is_active', True),
        notes=data.get('notes'),
        created_by=data.get('created_by'),
    )

    try:
        db.session.add(employee)
        db.session.commit()
        
        result = employee.to_dict(include_details=True)
        if auto_created_account:
            result['auto_created_account'] = {
                'account_number': auto_created_account.account_number,
                'account_name': auto_created_account.name
            }
        
        return jsonify(result), 201
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to create employee: {str(e)}'}), 500


@api.route('/employees/<int:employee_id>', methods=['GET'])
def get_employee(employee_id):
    employee = Employee.query.get_or_404(employee_id)
    return jsonify(employee.to_dict(include_details=True))


@api.route('/employees/<int:employee_id>', methods=['PUT'])
def update_employee(employee_id):
    employee = Employee.query.get_or_404(employee_id)
    data = request.get_json() or {}

    for field in ['name', 'job_title', 'department', 'phone', 'email', 'national_id', 'notes', 'created_by']:
        if field in data:
            setattr(employee, field, data[field])

    if 'salary' in data and data['salary'] is not None:
        employee.salary = float(data['salary'])

    if 'hire_date' in data:
        employee.hire_date = _parse_iso_date(data['hire_date'], 'hire_date')
    if 'termination_date' in data:
        employee.termination_date = _parse_iso_date(data['termination_date'], 'termination_date')

    if 'account_id' in data:
        employee.account_id = data['account_id']

    if 'is_active' in data:
        employee.is_active = bool(data['is_active'])

    try:
        db.session.commit()
        return jsonify(employee.to_dict(include_details=True))
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update employee: {str(e)}'}), 500


@api.route('/employees/<int:employee_id>', methods=['DELETE'])
def delete_employee(employee_id):
    employee = Employee.query.get_or_404(employee_id)

    try:
        # حذف سجلات الحضور المرتبطة (إن وجدت)
        Attendance.query.filter_by(employee_id=employee.id).delete(synchronize_session=False)

        # حذف سجلات الرواتب والسندات المرتبطة بها
        payroll_entries = Payroll.query.filter_by(employee_id=employee.id).all()
        deleted_payroll_ids = []
        deleted_voucher_ids = []
        deleted_journal_ids = []

        for payroll_entry in payroll_entries:
            # حذف السند المرتبط (إن وجد)
            if payroll_entry.voucher_id:
                voucher = Voucher.query.get(payroll_entry.voucher_id)
                if voucher is not None:
                    if voucher.journal_entry_id:
                        journal_entry = JournalEntry.query.get(voucher.journal_entry_id)
                        if journal_entry is not None:
                            deleted_journal_ids.append(journal_entry.id)
                            db.session.delete(journal_entry)
                    deleted_voucher_ids.append(voucher.id)
                    db.session.delete(voucher)

            deleted_payroll_ids.append(payroll_entry.id)
            db.session.delete(payroll_entry)

        db.session.delete(employee)
        db.session.commit()

        response = {
            'message': 'تم حذف الموظف بنجاح',
            'removed_payroll_entries': deleted_payroll_ids,
            'removed_vouchers': deleted_voucher_ids,
            'removed_journal_entries': deleted_journal_ids,
        }

        return jsonify(response)
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to delete employee: {str(e)}'}), 500


@api.route('/employees/<int:employee_id>/toggle-active', methods=['POST'])
def toggle_employee_active(employee_id):
    employee = Employee.query.get_or_404(employee_id)
    employee.is_active = not employee.is_active

    try:
        db.session.commit()
        return jsonify({'id': employee.id, 'is_active': employee.is_active})
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update employee status: {str(e)}'}), 500


@api.route('/employees/<int:employee_id>/payroll', methods=['GET'])
def list_employee_payroll(employee_id):
    employee = Employee.query.get_or_404(employee_id)
    payroll_entries = (
        Payroll.query.filter_by(employee_id=employee.id)
        .order_by(Payroll.year.desc(), Payroll.month.desc())
        .all()
    )
    return jsonify([entry.to_dict(include_voucher=True) for entry in payroll_entries])


@api.route('/employees/<int:employee_id>/attendance', methods=['GET'])
def list_employee_attendance(employee_id):
    employee = Employee.query.get_or_404(employee_id)

    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')

    query = Attendance.query.filter_by(employee_id=employee.id)

    if start_date:
        query = query.filter(Attendance.attendance_date >= _parse_iso_date(start_date, 'start_date'))
    if end_date:
        query = query.filter(Attendance.attendance_date <= _parse_iso_date(end_date, 'end_date'))

    attendance_records = query.order_by(Attendance.attendance_date.desc()).all()
    return jsonify([record.to_dict() for record in attendance_records])


@api.route('/employees/departments/summary', methods=['GET'])
def get_employee_departments_summary():
    """الحصول على ملخص أقسام الموظفين وعدد الموظفين في كل قسم"""
    from employee_account_helpers import get_department_summary
    
    try:
        summary = get_department_summary()
        return jsonify(summary)
    except Exception as e:
        return jsonify({'error': f'Failed to get departments summary: {str(e)}'}), 500


@api.route('/employees/<int:employee_id>/advance-account', methods=['GET'])
def get_employee_advance_account(employee_id):
    """الحصول على حساب السلفة الخاص بموظف"""
    from advance_account_helpers import get_employee_advance_balance
    
    try:
        advance_info = get_employee_advance_balance(employee_id)
        return jsonify(advance_info)
    except Exception as e:
        return jsonify({'error': f'Failed to get employee advance account: {str(e)}'}), 500


@api.route('/employees/<int:employee_id>/advance-account', methods=['POST'])
def create_employee_advance_account(employee_id):
    """إنشاء حساب سلفة لموظف"""
    from advance_account_helpers import get_or_create_employee_advance_account
    
    data = request.get_json() or {}
    created_by = data.get('created_by', 'system')
    
    try:
        advance_account = get_or_create_employee_advance_account(employee_id, created_by)
        db.session.commit()
        
        return jsonify({
            'account_id': advance_account.id,
            'account_number': advance_account.account_number,
            'account_name': advance_account.name,
            'employee_id': employee_id
        }), 201
    except ValueError as e:
        return jsonify({'error': str(e)}), 400
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to create advance account: {str(e)}'}), 500


@api.route('/advances/summary', methods=['GET'])
def get_all_advances_summary():
    """الحصول على ملخص جميع السلف المستحقة"""
    from advance_account_helpers import get_all_advances_summary as get_summary
    
    try:
        summary = get_summary()
        return jsonify(summary)
    except Exception as e:
        return jsonify({'error': f'Failed to get advances summary: {str(e)}'}), 500


# ============================================================================
# Payroll Routes (إدارة الرواتب)
# ============================================================================


@api.route('/payroll', methods=['GET'])
def list_payroll():
    query = Payroll.query

    employee_id = request.args.get('employee_id', type=int)
    if employee_id:
        query = query.filter_by(employee_id=employee_id)

    year = request.args.get('year', type=int)
    if year:
        query = query.filter_by(year=year)

    month = request.args.get('month', type=int)
    if month:
        query = query.filter_by(month=month)

    status = request.args.get('status')
    if status:
        query = query.filter_by(status=status)

    payroll_entries = query.order_by(Payroll.year.desc(), Payroll.month.desc()).all()
    return jsonify([entry.to_dict(include_employee=True, include_voucher=True) for entry in payroll_entries])


@api.route('/payroll', methods=['POST'])
def create_payroll():
    data = request.get_json() or {}

    employee_id = data.get('employee_id')
    if not employee_id:
        return jsonify({'error': 'رمز الموظف مطلوب'}), 400

    employee = Employee.query.get(employee_id)
    if not employee:
        return jsonify({'error': 'الموظف غير موجود'}), 400

    try:
        paid_date = _parse_iso_date(data.get('paid_date'), 'paid_date')
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    basic_salary = float(data.get('basic_salary', employee.salary or 0.0))
    allowances = float(data.get('allowances', 0.0))
    deductions = float(data.get('deductions', 0.0))
    net_salary = float(data.get('net_salary', basic_salary + allowances - deductions))

    payroll_entry = Payroll(
        employee_id=employee.id,
        month=int(data.get('month', datetime.utcnow().month)),
        year=int(data.get('year', datetime.utcnow().year)),
        basic_salary=basic_salary,
        allowances=allowances,
        deductions=deductions,
        net_salary=net_salary,
        voucher_id=data.get('voucher_id'),
        paid_date=paid_date,
        status=data.get('status', 'pending'),
        notes=data.get('notes'),
        created_by=data.get('created_by'),
    )

    try:
        db.session.add(payroll_entry)
        db.session.commit()
        return jsonify(payroll_entry.to_dict(include_employee=True, include_voucher=True)), 201
    except IntegrityError as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء سجل الراتب: {str(exc)}'}), 400
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء سجل الراتب: {str(exc)}'}), 500


@api.route('/payroll/<int:payroll_id>', methods=['GET'])
def get_payroll(payroll_id):
    payroll_entry = Payroll.query.get_or_404(payroll_id)
    return jsonify(payroll_entry.to_dict(include_employee=True, include_voucher=True))


@api.route('/payroll/<int:payroll_id>', methods=['PUT'])
def update_payroll(payroll_id):
    payroll_entry = Payroll.query.get_or_404(payroll_id)
    data = request.get_json() or {}

    if 'employee_id' in data:
        employee_id = data['employee_id']
        if employee_id:
            employee = Employee.query.get(employee_id)
            if not employee:
                return jsonify({'error': 'الموظف غير موجود'}), 400
            payroll_entry.employee_id = employee.id

    if 'month' in data and data['month'] is not None:
        payroll_entry.month = int(data['month'])
    if 'year' in data and data['year'] is not None:
        payroll_entry.year = int(data['year'])

    if 'basic_salary' in data and data['basic_salary'] is not None:
        payroll_entry.basic_salary = float(data['basic_salary'])
    if 'allowances' in data and data['allowances'] is not None:
        payroll_entry.allowances = float(data['allowances'])
    if 'deductions' in data and data['deductions'] is not None:
        payroll_entry.deductions = float(data['deductions'])
    if 'net_salary' in data and data['net_salary'] is not None:
        payroll_entry.net_salary = float(data['net_salary'])

    if 'status' in data and data['status']:
        payroll_entry.status = data['status']

    if 'voucher_id' in data:
        payroll_entry.voucher_id = data['voucher_id']

    if 'notes' in data:
        payroll_entry.notes = data['notes']

    if 'paid_date' in data:
        try:
            payroll_entry.paid_date = _parse_iso_date(data['paid_date'], 'paid_date')
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    try:
        db.session.commit()
        return jsonify(payroll_entry.to_dict(include_employee=True, include_voucher=True))
    except IntegrityError as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث سجل الراتب: {str(exc)}'}), 400
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث سجل الراتب: {str(exc)}'}), 500


@api.route('/payroll/<int:payroll_id>', methods=['DELETE'])
def delete_payroll(payroll_id):
    payroll_entry = Payroll.query.get_or_404(payroll_id)

    if payroll_entry.voucher_id:
        return jsonify({'error': 'لا يمكن حذف سجل الراتب المرتبط بسند'}), 400

    try:
        db.session.delete(payroll_entry)
        db.session.commit()
        return jsonify({'message': 'تم حذف سجل الراتب بنجاح'})
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل حذف سجل الراتب: {str(exc)}'}), 500


@api.route('/payroll/payment-accounts', methods=['GET'])
def get_payment_accounts():
    """
    الحصول على حسابات الدفع المتاحة (نقدية، بنوك، شيكات)
    ✨ محدّث: يستخدم نظام الخزائن الجديد
    """
    # الحصول على جميع الخزائن النقدية والبنكية النشطة
    safe_boxes = SafeBox.query.filter(
        SafeBox.safe_type.in_(['cash', 'bank', 'check']),
        SafeBox.is_active == True
    ).order_by(SafeBox.is_default.desc(), SafeBox.safe_type, SafeBox.name).all()
    
    return jsonify([{
        'id': sb.account_id,  # نرسل account_id لأن الكود الحالي يتوقعه
        'safe_box_id': sb.id,  # معرف الخزينة للمرجع
        'account_number': sb.account.account_number if sb.account else None,
        'name': sb.name,  # اسم الخزينة (أفضل من اسم الحساب)
        'type': sb.safe_type,  # cash, bank, check
        'bank_name': sb.bank_name,
        'is_default': sb.is_default
    } for sb in safe_boxes])


@api.route('/payroll/<int:payroll_id>/mark-paid', methods=['POST'])
def mark_payroll_paid(payroll_id):
    """
    تعيين راتب كمدفوع مع إنشاء سند صرف تلقائي
    
    Body Parameters:
        - paid_date: تاريخ الدفع (اختياري)
        - payment_account_id: معرف حساب الدفع (نقدية/بنك/شيك) (اختياري - افتراضي: حساب النقدية)
        - created_by: اسم المستخدم (اختياري)
    """
    payroll_entry = Payroll.query.get_or_404(payroll_id)
    data = request.get_json() or {}

    try:
        paid_date = _parse_iso_date(data.get('paid_date') or datetime.utcnow().date(), 'paid_date')
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    # ✅ إنشاء سند صرف تلقائي إذا لم يكن موجوداً
    if not payroll_entry.voucher_id:
        try:
            # البحث عن حساب الموظف
            employee = Employee.query.get(payroll_entry.employee_id)
            if not employee:
                return jsonify({'error': 'الموظف غير موجود'}), 404

            # إنشاء رقم سند فريد
            voucher_prefix = f"PAY-{payroll_entry.year}-{payroll_entry.month:02d}"
            latest_voucher = (
                Voucher.query.filter(Voucher.voucher_number.like(f"{voucher_prefix}%"))
                .order_by(Voucher.voucher_number.desc())
                .first()
            )
            
            if latest_voucher:
                try:
                    last_seq = int(latest_voucher.voucher_number.split('-')[-1])
                    voucher_number = f"{voucher_prefix}-{last_seq + 1:04d}"
                except (ValueError, IndexError):
                    voucher_number = f"{voucher_prefix}-0001"
            else:
                voucher_number = f"{voucher_prefix}-0001"

            # إنشاء السند
            voucher = Voucher(
                voucher_number=voucher_number,
                voucher_type='صرف',
                date=paid_date,
                description=f"صرف راتب {employee.name} - {payroll_entry.month}/{payroll_entry.year}",
                status='approved',
                created_by=data.get('created_by', 'system'),
            )
            db.session.add(voucher)
            db.session.flush()  # للحصول على voucher.id

            # إضافة سطر الحساب (من حساب الموظف أو حساب الرواتب)
            if employee.account_id:
                salary_account_id = employee.account_id
            else:
                # البحث عن حساب "مستحقات رواتب" (222)
                salaries_payable_account = Account.query.filter(
                    or_(
                        Account.account_number == '222',
                        Account.name.like('%مستحقات رواتب%'),
                        Account.name.like('%رواتب مستحقة%')
                    )
                ).first()
                salary_account_id = salaries_payable_account.id if salaries_payable_account else None

            if not salary_account_id:
                db.session.rollback()
                return jsonify({'error': 'لا يوجد حساب مرتبط بالموظف أو حساب مستحقات رواتب'}), 400

            # ✅ تحديد حساب الدفع (نقدية/بنك/شيك)
            payment_account_id = data.get('payment_account_id')
            
            if payment_account_id:
                # التحقق من وجود الحساب المحدد
                payment_account = Account.query.get(payment_account_id)
                if not payment_account:
                    db.session.rollback()
                    return jsonify({'error': f'حساب الدفع غير موجود (ID: {payment_account_id})'}), 400
            else:
                # البحث عن حساب النقدية الافتراضي
                payment_account = Account.query.filter(
                    or_(
                        Account.account_number.like('100%'),
                        Account.name.like('%صندوق%'),
                        Account.name.like('%نقدية%'),
                        Account.name.like('%cash%')
                    )
                ).first()

                if not payment_account:
                    db.session.rollback()
                    return jsonify({'error': 'لا يوجد حساب دفع (نقدية/بنك) في النظام'}), 400

            # إضافة السطر المدين (من حساب الدفع - خروج أموال)
            debit_line = VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=payment_account.id,
                line_type='debit',  # ✅ مدين - خروج أموال من الحساب
                amount_type='cash',
                description=f"صرف راتب {employee.name} - {payment_account.name}",
                amount=payroll_entry.net_salary,
            )
            db.session.add(debit_line)

            # إضافة السطر الدائن (لحساب مستحقات الرواتب)
            credit_line = VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=salary_account_id,
                line_type='credit',  # ✅ دائن - تسديد الالتزام
                amount_type='cash',
                description=f"راتب {payroll_entry.month}/{payroll_entry.year}",
                amount=payroll_entry.net_salary,
            )
            db.session.add(credit_line)

            payroll_entry.voucher_id = voucher.id

        except Exception as e:
            db.session.rollback()
            return jsonify({'error': f'فشل إنشاء سند الصرف: {str(e)}'}), 500

    payroll_entry.paid_date = paid_date
    payroll_entry.status = 'paid'

    try:
        db.session.commit()
        return jsonify(payroll_entry.to_dict(include_employee=True, include_voucher=True))
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث حالة السجل: {str(exc)}'}), 500


# ============================================================================
# Attendance Routes (إدارة الحضور)
# ============================================================================


@api.route('/attendance', methods=['GET'])
def list_attendance():
    query = Attendance.query

    employee_id = request.args.get('employee_id', type=int)
    if employee_id:
        query = query.filter_by(employee_id=employee_id)

    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')

    if start_date:
        try:
            query = query.filter(Attendance.attendance_date >= _parse_iso_date(start_date, 'start_date'))
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400
    if end_date:
        try:
            query = query.filter(Attendance.attendance_date <= _parse_iso_date(end_date, 'end_date'))
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    status = request.args.get('status')
    if status:
        query = query.filter_by(status=status)

    attendance_records = query.order_by(Attendance.attendance_date.desc()).all()
    return jsonify([record.to_dict(include_employee=True) for record in attendance_records])


@api.route('/attendance', methods=['POST'])
def create_attendance():
    data = request.get_json() or {}

    employee_id = data.get('employee_id')
    if not employee_id:
        return jsonify({'error': 'رمز الموظف مطلوب'}), 400

    employee = Employee.query.get(employee_id)
    if not employee:
        return jsonify({'error': 'الموظف غير موجود'}), 400

    try:
        attendance_date = _parse_iso_date(data.get('attendance_date'), 'attendance_date')
        if not attendance_date:
            raise ValueError('تاريخ الحضور مطلوب')
        check_in_time = _parse_iso_time(data.get('check_in_time'), 'check_in_time')
        check_out_time = _parse_iso_time(data.get('check_out_time'), 'check_out_time')
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    attendance_record = Attendance(
        employee_id=employee.id,
        attendance_date=attendance_date,
        check_in_time=check_in_time,
        check_out_time=check_out_time,
        status=data.get('status', 'present'),
        notes=data.get('notes'),
        created_by=data.get('created_by'),
    )

    try:
        db.session.add(attendance_record)
        db.session.commit()
        return jsonify(attendance_record.to_dict(include_employee=True)), 201
    except IntegrityError as exc:
        db.session.rollback()
        return jsonify({'error': f'سجل الحضور موجود بالفعل: {str(exc)}'}), 400
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء سجل الحضور: {str(exc)}'}), 500


@api.route('/attendance/<int:attendance_id>', methods=['GET'])
def get_attendance(attendance_id):
    attendance_record = Attendance.query.get_or_404(attendance_id)
    return jsonify(attendance_record.to_dict(include_employee=True))


@api.route('/attendance/<int:attendance_id>', methods=['PUT'])
def update_attendance(attendance_id):
    attendance_record = Attendance.query.get_or_404(attendance_id)
    data = request.get_json() or {}

    if 'employee_id' in data:
        employee_id = data['employee_id']
        if employee_id:
            employee = Employee.query.get(employee_id)
            if not employee:
                return jsonify({'error': 'الموظف غير موجود'}), 400
            attendance_record.employee_id = employee.id

    if 'attendance_date' in data:
        try:
            attendance_record.attendance_date = _parse_iso_date(data['attendance_date'], 'attendance_date')
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    if 'check_in_time' in data:
        try:
            attendance_record.check_in_time = _parse_iso_time(data['check_in_time'], 'check_in_time')
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    if 'check_out_time' in data:
        try:
            attendance_record.check_out_time = _parse_iso_time(data['check_out_time'], 'check_out_time')
        except ValueError as exc:
            return jsonify({'error': str(exc)}), 400

    if 'status' in data and data['status']:
        attendance_record.status = data['status']

    if 'notes' in data:
        attendance_record.notes = data['notes']

    try:
        db.session.commit()
        return jsonify(attendance_record.to_dict(include_employee=True))
    except IntegrityError as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث سجل الحضور: {str(exc)}'}), 400
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث سجل الحضور: {str(exc)}'}), 500


@api.route('/attendance/<int:attendance_id>', methods=['DELETE'])
def delete_attendance(attendance_id):
    attendance_record = Attendance.query.get_or_404(attendance_id)

    try:
        db.session.delete(attendance_record)
        db.session.commit()
        return jsonify({'message': 'تم حذف سجل الحضور بنجاح'})
    except Exception as exc:
        db.session.rollback()
        return jsonify({'error': f'فشل حذف سجل الحضور: {str(exc)}'}), 500


def generate_voucher_number(voucher_type, year=None):
    """
    توليد رقم سند تلقائي
    RV-2025-00001 (Receipt Voucher)
    PV-2025-00001 (Payment Voucher)
    AV-2025-00001 (Adjustment Voucher)
    """
    if year is None:
        year = datetime.now().year
    
    # تحديد البادئة حسب النوع
    prefix_map = {
        'receipt': 'RV',
        'payment': 'PV',
        'adjustment': 'AV'
    }
    prefix = prefix_map.get(voucher_type, 'V')
    
    # البحث عن آخر رقم في نفس السنة والنوع
    pattern = f'{prefix}-{year}-%'
    last_voucher = Voucher.query.filter(
        Voucher.voucher_number.like(pattern)
    ).order_by(Voucher.voucher_number.desc()).first()
    
    if last_voucher:
        # استخراج الرقم التسلسلي
        try:
            last_num = int(last_voucher.voucher_number.split('-')[-1])
            new_num = last_num + 1
        except:
            new_num = 1
    else:
        new_num = 1
    
    return f'{prefix}-{year}-{new_num:05d}'


def create_journal_entry_from_voucher(voucher):
    """
    إنشاء قيد محاسبي تلقائي من السند - نسخة محدّثة
    
    يدعم قيود متعددة الأطراف:
    - نقد + عدة عيارات ذهب في نفس السند
    - يقرأ سطور الحسابات من VoucherAccountLine
    
    سند القبض (Receipt):
    - مدين: حسابات متعددة (صندوق، ذهب عيار 24، ذهب عيار 21، إلخ)
    - دائن: حساب العميل (مجموع المبالغ)
    
    سند الصرف (Payment):
    - مدين: حساب المورد (مجموع المبالغ)
    - دائن: حسابات متعددة (صندوق، ذهب عيار 24، ذهب عيار 21، إلخ)
    """
    try:
        # توليد رقم القيد
        year = voucher.date.year
        entry_number = JournalEntry.query.filter(
            db.func.strftime('%Y', JournalEntry.date) == str(year)
        ).count() + 1
        entry_number_str = f'JE-{year}-{entry_number:05d}'
        
        # إنشاء القيد
        journal_entry = JournalEntry(
            entry_number=entry_number_str,
            date=voucher.date,
            description=f'{voucher.voucher_type.upper()} - {voucher.voucher_number}: {voucher.description or ""}',
            reference_type='voucher',
            reference_id=voucher.id,
            created_by=voucher.created_by
        )
        
        db.session.add(journal_entry)
        db.session.flush()
        
        # قراءة سطور الحسابات من VoucherAccountLine
        account_lines = VoucherAccountLine.query.filter_by(voucher_id=voucher.id).all()
        
        if not account_lines:
            print(f"Warning: No account lines found for voucher {voucher.id}")
            return None
        
        # إنشاء سطور القيد المحاسبي من سطور السند
        for account_line in account_lines:
            # تحديد المبالغ حسب نوع السطر (مدين/دائن) ونوع المبلغ (نقد/ذهب)
            cash_debit = 0
            cash_credit = 0
            debit_18k = 0
            credit_18k = 0
            debit_21k = 0
            credit_21k = 0
            debit_22k = 0
            credit_22k = 0
            debit_24k = 0
            credit_24k = 0
            
            if account_line.amount_type == 'cash':
                if account_line.line_type == 'debit':
                    cash_debit = account_line.amount
                else:  # credit
                    cash_credit = account_line.amount
            elif account_line.amount_type == 'gold':
                # تحديد العيار (تحويل إلى int للمقارنة)
                karat = int(account_line.karat) if account_line.karat else 21
                amount = account_line.amount
                is_debit = account_line.line_type == 'debit'
                
                # توزيع المبلغ حسب العيار
                if karat == 18:
                    if is_debit:
                        debit_18k = amount
                    else:
                        credit_18k = amount
                elif karat == 21:
                    if is_debit:
                        debit_21k = amount
                    else:
                        credit_21k = amount
                elif karat == 22:
                    if is_debit:
                        debit_22k = amount
                    else:
                        credit_22k = amount
                elif karat == 24:
                    if is_debit:
                        debit_24k = amount
                    else:
                        credit_24k = amount
                else:
                    # عيار غير مدعوم - استخدام 21 كافتراضي
                    print(f"Warning: Unsupported karat {karat}, defaulting to 21k")
                    if is_debit:
                        debit_21k = amount
                    else:
                        credit_21k = amount
            
            # إنشاء سطر القيد
            journal_line = JournalEntryLine(
                journal_entry_id=journal_entry.id,
                account_id=account_line.account_id,
                cash_debit=cash_debit,
                cash_credit=cash_credit,
                debit_18k=debit_18k,
                credit_18k=credit_18k,
                debit_21k=debit_21k,
                credit_21k=credit_21k,
                debit_22k=debit_22k,
                credit_22k=credit_22k,
                debit_24k=debit_24k,
                credit_24k=credit_24k
            )
            
            db.session.add(journal_line)
        
        db.session.flush()
        
        return journal_entry
        
    except Exception as e:
        print(f"Error creating journal entry from voucher: {str(e)}")
        import traceback
        traceback.print_exc()
        return None


@api.route('/vouchers', methods=['GET'])
def get_vouchers():
    print("DEBUG: get_vouchers called")
    """
    Get list of vouchers with optional filtering and pagination
    Query parameters:
    - page: int (for pagination)
    - per_page: int (for pagination)
    - type: receipt, payment, adjustment
    - party_type: customer, supplier, other
    - status: active, cancelled
    - date_from: YYYY-MM-DD
    - date_to: YYYY-MM-DD
    - customer_id: int
    - supplier_id: int
    - search: string (searches voucher_number and description)
    """
    # Pagination parameters
    page = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 20, type=int)

    query = Voucher.query

    # Filters
    voucher_type = request.args.get('type')
    if voucher_type and voucher_type != 'all':
        query = query.filter(Voucher.voucher_type == voucher_type)

    party_type = request.args.get('party_type')
    if party_type:
        query = query.filter(Voucher.party_type == party_type)

    status = request.args.get('status')
    if status and status != 'all':
        query = query.filter(Voucher.status == status)

    date_from = request.args.get('date_from')
    if date_from:
        try:
            date_from_obj = datetime.fromisoformat(date_from)
            query = query.filter(Voucher.date >= date_from_obj)
        except:
            pass

    date_to = request.args.get('date_to')
    if date_to:
        try:
            date_to_obj = datetime.fromisoformat(date_to)
            query = query.filter(Voucher.date <= date_to_obj)
        except:
            pass

    customer_id = request.args.get('customer_id')
    if customer_id:
        query = query.filter(Voucher.customer_id == int(customer_id))

    supplier_id = request.args.get('supplier_id')
    if supplier_id:
        query = query.filter(Voucher.supplier_id == int(supplier_id))
        
    search = request.args.get('search')
    if search:
        search_term = f'%{search}%'
        query = query.filter(
            (Voucher.voucher_number.ilike(search_term)) |
            (Voucher.description.ilike(search_term))
        )

    # Order by date descending
    query = query.order_by(Voucher.date.desc(), Voucher.id.desc())

    # Pagination
    paginated_vouchers = query.paginate(page=page, per_page=per_page, error_out=False)
    vouchers = paginated_vouchers.items

    result = {
        'vouchers': [v.to_dict() for v in vouchers],
        'total': paginated_vouchers.total,
        'pages': paginated_vouchers.pages,
        'current_page': paginated_vouchers.page,
        'per_page': paginated_vouchers.per_page
    }
    
    print(f"DEBUG: result type = {type(result)}")
    print(f"DEBUG: result keys = {list(result.keys())}")
    print(f"DEBUG: Returning {len(result['vouchers'])} vouchers")
    return jsonify(result)


@api.route('/vouchers/<int:voucher_id>', methods=['GET'])
def get_voucher(voucher_id):
    """Get single voucher by ID"""
    voucher = Voucher.query.get_or_404(voucher_id)
    return jsonify(voucher.to_dict())


@api.route('/vouchers', methods=['POST'])
def create_voucher():
    """
    Create a new voucher with automatic journal entry - النسخة المحدّثة
    
    يدعم سطور حسابات متعددة (نقد + عدة عيارات ذهب)
    
    Required fields:
    - voucher_type: receipt, payment, adjustment
    - date: ISO format
    - account_lines: [
        {
          "account_id": int,
          "line_type": "debit" or "credit",
          "amount_type": "cash" or "gold",
          "amount": float,
          "karat": float (optional, required if amount_type='gold'),
          "description": string (optional)
        },
        ...
      ]
    
    Optional fields:
    - party_type: customer, supplier, other
    - customer_id or supplier_id
    - party_name (if not customer/supplier)
    - description
    - reference_type, reference_id, reference_number
    - notes
    """
    data = request.get_json()
    
    # Validation
    if 'voucher_type' not in data:
        return jsonify({'error': 'voucher_type is required'}), 400
    
    if data['voucher_type'] not in ['receipt', 'payment', 'adjustment']:
        return jsonify({'error': 'Invalid voucher_type'}), 400
    
    if 'account_lines' not in data or not data['account_lines']:
        return jsonify({'error': 'account_lines is required and cannot be empty'}), 400
    
    account_lines_data = data['account_lines']
    
    # التحقق من وجود حسابات وأرصدة صحيحة
    total_debit_cash = 0
    total_credit_cash = 0
    total_debit_gold = 0
    total_credit_gold = 0
    
    for line in account_lines_data:
        if 'account_id' not in line or 'line_type' not in line or 'amount_type' not in line or 'amount' not in line:
            return jsonify({'error': 'Each account line must have account_id, line_type, amount_type, and amount'}), 400
        
        if line['line_type'] not in ['debit', 'credit']:
            return jsonify({'error': 'line_type must be either debit or credit'}), 400
        
        if line['amount_type'] not in ['cash', 'gold']:
            return jsonify({'error': 'amount_type must be either cash or gold'}), 400
        
        if line['amount_type'] == 'gold' and 'karat' not in line:
            return jsonify({'error': 'karat is required when amount_type is gold'}), 400
        
        amount = float(line['amount'])
        if amount <= 0:
            return jsonify({'error': 'Amount must be greater than zero'}), 400
        
        # حساب المجاميع للتحقق من التوازن
        if line['amount_type'] == 'cash':
            if line['line_type'] == 'debit':
                total_debit_cash += amount
            else:
                total_credit_cash += amount
        elif line['amount_type'] == 'gold':
            if line['line_type'] == 'debit':
                total_debit_gold += amount
            else:
                total_credit_gold += amount
    
    # التحقق من التوازن (مع تسامح بسيط للأخطاء العائمة)
    if abs(total_debit_cash - total_credit_cash) > 0.01:
        return jsonify({'error': f'Cash amounts not balanced: Debit={total_debit_cash}, Credit={total_credit_cash}'}), 400
    
    if abs(total_debit_gold - total_credit_gold) > 0.001:
        return jsonify({'error': f'Gold amounts not balanced: Debit={total_debit_gold}, Credit={total_credit_gold}'}), 400
    
    try:
        # التحقق من وجود جميع الحسابات
        for line in account_lines_data:
            account = Account.query.get(line['account_id'])
            if not account:
                return jsonify({'error': f'Account {line["account_id"]} not found'}), 404
        
        # Generate voucher number
        voucher_number = generate_voucher_number(data['voucher_type'])
        
        # Parse date
        voucher_date = datetime.fromisoformat(data.get('date', datetime.now().isoformat()))
        
        # حساب المجاميع للسند (للعرض)
        amount_cash = total_debit_cash  # أو total_credit_cash (متساوية)
        amount_gold = total_debit_gold  # أو total_credit_gold (متساوية)
        
        # Create voucher
        voucher = Voucher(
            voucher_number=voucher_number,
            voucher_type=data['voucher_type'],
            date=voucher_date,
            party_type=data.get('party_type'),
            customer_id=data.get('customer_id'),
            supplier_id=data.get('supplier_id'),
            party_name=data.get('party_name'),
            amount_cash=amount_cash,
            amount_gold=amount_gold,
            gold_karat=None,  # لم يعد يستخدم (الآن في سطور الحسابات)
            description=data.get('description'),
            reference_type=data.get('reference_type'),
            reference_id=data.get('reference_id'),
            reference_number=data.get('reference_number'),
            notes=data.get('notes'),
            created_by=data.get('created_by', 'system'),
            status='pending'
        )
        
        db.session.add(voucher)
        db.session.flush()  # Get the voucher ID
        
        # إنشاء سطور الحسابات
        for line_data in account_lines_data:
            account_line = VoucherAccountLine(
                voucher_id=voucher.id,
                account_id=line_data['account_id'],
                line_type=line_data['line_type'],
                amount_type=line_data['amount_type'],
                amount=float(line_data['amount']),
                karat=line_data.get('karat'),
                description=line_data.get('description')
            )
            db.session.add(account_line)
        
        db.session.commit()
        
        return jsonify(voucher.to_dict()), 201
        
    except Exception as e:
        db.session.rollback()
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'Failed to create voucher: {str(e)}'}), 500


@api.route('/vouchers/<int:voucher_id>', methods=['PUT'])
def update_voucher(voucher_id):
    """Update voucher - only active vouchers can be edited"""
    voucher = Voucher.query.get_or_404(voucher_id)
    
    if voucher.status != 'active':
        return jsonify({'error': 'Cannot edit cancelled or voided voucher'}), 400
    
    data = request.get_json()
    
    try:
        # Update allowed fields
        if 'date' in data:
            voucher.date = datetime.fromisoformat(data['date'])
        
        if 'party_type' in data:
            voucher.party_type = data['party_type']
        
        if 'customer_id' in data:
            voucher.customer_id = data['customer_id']
        
        if 'supplier_id' in data:
            voucher.supplier_id = data['supplier_id']
        
        if 'party_name' in data:
            voucher.party_name = data['party_name']
        
        if 'amount_cash' in data:
            voucher.amount_cash = float(data['amount_cash'])
        
        if 'amount_gold' in data:
            voucher.amount_gold = float(data['amount_gold'])
        
        if 'gold_karat' in data:
            voucher.gold_karat = data['gold_karat']
        
        if 'description' in data:
            voucher.description = data['description']
        
        if 'notes' in data:
            voucher.notes = data['notes']
        
        # Validation
        if voucher.amount_cash <= 0 and voucher.amount_gold <= 0:
            return jsonify({'error': 'Amount must be greater than zero'}), 400
        
        db.session.commit()
        
        return jsonify(voucher.to_dict())
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to update voucher: {str(e)}'}), 500


@api.route('/vouchers/<int:voucher_id>', methods=['DELETE'])
def delete_voucher(voucher_id):
    """Delete voucher - only if not linked to journal entry"""
    voucher = Voucher.query.get_or_404(voucher_id)
    
    if voucher.journal_entry_id:
        return jsonify({'error': 'Cannot delete voucher linked to journal entry. Cancel it instead.'}), 400
    
    try:
        db.session.delete(voucher)
        db.session.commit()
        return jsonify({'message': 'Voucher deleted successfully'}), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to delete voucher: {str(e)}'}), 500


@api.route('/vouchers/<int:voucher_id>/approve', methods=['POST'])
def approve_voucher(voucher_id):
    """
    ترحيل السند (Approve/Post Voucher)
    
    يقوم بـ:
    1. تغيير حالة السند إلى 'approved'
    2. إنشاء قيد محاسبي تلقائي من السند
    3. ربط السند بالقيد المحاسبي
    """
    voucher = Voucher.query.get_or_404(voucher_id)
    
    # التحقق من الحالة
    if voucher.status == 'approved':
        return jsonify({'error': 'السند مرحّل بالفعل'}), 400
    
    if voucher.status == 'cancelled':
        return jsonify({'error': 'لا يمكن ترحيل سند ملغى'}), 400
    
    if voucher.journal_entry_id:
        return jsonify({'error': 'السند مرتبط بقيد محاسبي بالفعل'}), 400
    
    data = request.get_json() or {}
    approved_by = data.get('approved_by', 'user')
    
    try:
        # إنشاء القيد المحاسبي
        journal_entry = create_journal_entry_from_voucher(voucher)
        
        if not journal_entry:
            raise Exception('فشل إنشاء القيد المحاسبي')
        
        # تحديث السند
        voucher.status = 'approved'
        voucher.approved_at = datetime.now()
        voucher.approved_by = approved_by
        voucher.journal_entry_id = journal_entry.id
        
        db.session.commit()
        
        return jsonify({
            'message': 'تم ترحيل السند بنجاح',
            'voucher': voucher.to_dict(),
            'journal_entry': {
                'id': journal_entry.id,
                'entry_number': journal_entry.entry_number,
                'date': journal_entry.date.isoformat()
            }
        }), 200
        
    except Exception as e:
        db.session.rollback()
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'فشل ترحيل السند: {str(e)}'}), 500


@api.route('/vouchers/<int:voucher_id>/cancel', methods=['POST'])
def cancel_voucher(voucher_id):
    """Cancel voucher"""
    voucher = Voucher.query.get_or_404(voucher_id)
    
    if voucher.status == 'cancelled':
        return jsonify({'error': 'Voucher is already cancelled'}), 400
    
    data = request.get_json()
    reason = data.get('reason', 'No reason provided')
    
    try:
        voucher.status = 'cancelled'
        voucher.cancellation_reason = reason
        voucher.cancelled_at = datetime.now()
        
        # TODO: Reverse journal entry if exists
        
        db.session.commit()
        
        return jsonify(voucher.to_dict())
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'Failed to cancel voucher: {str(e)}'}), 500


@api.route('/vouchers/stats', methods=['GET'])
def get_vouchers_stats():
    """Get vouchers statistics"""
    
    # Total counts by type
    stats = {
        'total_receipt': Voucher.query.filter_by(voucher_type='receipt', status='active').count(),
        'total_payment': Voucher.query.filter_by(voucher_type='payment', status='active').count(),
        'total_adjustment': Voucher.query.filter_by(voucher_type='adjustment', status='active').count(),
    }
    
    # Total amounts
    # Total amounts
    receipt_cash = db.session.query(db.func.sum(Voucher.amount_cash)).filter_by(
        voucher_type='receipt', status='active'
    ).scalar() or 0
    
    payment_cash = db.session.query(db.func.sum(Voucher.amount_cash)).filter_by(
        voucher_type='payment', status='active'
    ).scalar() or 0
    stats['total_receipt_cash'] = float(receipt_cash)
    stats['total_payment_cash'] = float(payment_cash)
    stats['net_cash'] = float(receipt_cash - payment_cash)
    
    return jsonify(stats)


# ========================================
# Initialize Payment Accounts & Methods
# ========================================
@api.route('/initialize-payment-system', methods=['POST'])
def initialize_payment_system():
    """
    تهيئة شجرة الحسابات ووسائل الدفع الافتراضية
    هذا Endpoint يُستدعى مرة واحدة فقط عند الإعداد الأولي
    """
    try:
        # التحقق من وجود بيانات مسبقاً


        existing_accounts = Account.query.filter(Account.account_number.in_([
            '1111', '1112', '1113', '1114', '1115', '1116', '1117'
        ])).count()
        




        if existing_accounts > 0:
            return jsonify({
                'status': 'warning',
                'message': 'Payment accounts already exist',
                'existing_count': existing_accounts
            }), 200
        
        # 1. إنشاء شجرة الحسابات
        accounts_data = [
            # الأصول (Assets)
            {'account_number': '1000', 'name': 'الأصول', 'type': 'asset', 'transaction_type': None},
            {'account_number': '1100', 'name': 'الأصول المتداولة', 'type': 'asset', 'transaction_type': None},
            
            # حسابات وسائل الدفع
            {'account_number': '1111', 'name': 'الصندوق (نقداً)', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1112', 'name': 'البنك - الحساب الجاري', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1113', 'name': 'بطاقة مدى - نقاط البيع', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1114', 'name': 'بطاقات فيزا/ماستركارد', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1115', 'name': 'تابي - مستحقات قصيرة الأجل', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1116', 'name': 'تمارا - مستحقات قصيرة الأجل', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1117', 'name': 'STC Pay - المحفظة الرقمية', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1118', 'name': 'Apple Pay / Google Pay', 'type': 'asset', 'transaction_type': 'both'},
            {'account_number': '1119', 'name': 'التحويل البنكي المباشر', 'type': 'asset', 'transaction_type': 'both'},
            
            # المصروفات (Expenses)
            {'account_number': '5000', 'name': 'المصروفات', 'type': 'expense', 'transaction_type': None},
            {'account_number': '5100', 'name': 'مصروفات التشغيل', 'type': 'expense', 'transaction_type': None},
            
            # حسابات العمولات
            {'account_number': '5111', 'name': 'عمولة البنك - بطاقة مدى', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5112', 'name': 'عمولة البنك - فيزا/ماستركارد', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5113', 'name': 'عمولة تابي (BNPL)', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5114', 'name': 'عمولة تمارا (BNPL)', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5115', 'name': 'عمولة STC Pay', 'type': 'expense', 'transaction_type': 'both'},
            {'account_number': '5116', 'name': 'عمولة Apple/Google Pay', 'type': 'expense', 'transaction_type': 'both'},
        ]
        
        created_accounts = []
        for acc_data in accounts_data:
            # التحقق من عدم وجود الحساب
            existing = Account.query.filter_by(account_number=acc_data['account_number']).first()
            if not existing:
                account = Account(
                    account_number=acc_data['account_number'],
                    name=acc_data['name'],
                    type=acc_data['type'],
                    transaction_type=acc_data['transaction_type']
                )
                db.session.add(account)
                created_accounts.append(acc_data['account_number'])
        
        db.session.commit()
        
        # 2. إنشاء وسائل الدفع الافتراضية
        from backend.models import PaymentMethod
        
        payment_methods_data = [
            {'name': 'نقداً', 'commission_rate': 0.0, 'account_number': '1111', 'settlement_days': 0, 
             'notes': 'استلام فوري - لا توجد عمولات'},
            
            {'name': 'بطاقة مدى', 'commission_rate': 1.5, 'account_number': '1113', 'settlement_days': 2,
             'notes': 'عمولة 1.5% - استلام خلال يومين'},
            
            {'name': 'فيزا / ماستركارد', 'commission_rate': 2.5, 'account_number': '1114', 'settlement_days': 3,
             'notes': 'عمولة 2.5% - استلام خلال 3 أيام'},
            
            {'name': 'تابي (Tabby)', 'commission_rate': 4.0, 'account_number': '1115', 'settlement_days': 7,
             'notes': 'عمولة 4% - استلام خلال أسبوع بعد اكتمال الأقساط'},
            
            {'name': 'تمارا (Tamara)', 'commission_rate': 4.0, 'account_number': '1116', 'settlement_days': 7,
             'notes': 'عمولة 4% - استلام خلال أسبوع بعد اكتمال الأقساط'},
            
            {'name': 'STC Pay', 'commission_rate': 1.5, 'account_number': '1117', 'settlement_days': 1,
             'notes': 'عمولة 1.5% - استلام خلال يوم واحد'},
            
            {'name': 'Apple Pay', 'commission_rate': 2.0, 'account_number': '1118', 'settlement_days': 2,
             'notes': 'عمولة 2% - استلام خلال يومين'},
            
            {'name': 'تحويل بنكي', 'commission_rate': 0.0, 'account_number': '1119', 'settlement_days': 1,
             'notes': 'بدون عمولة - استلام حسب البنك (1-3 أيام)'},
        ]
        
        created_methods = []
        for method_data in payment_methods_data:
            # البحث عن الحساب المرتبط
            account = Account.query.filter_by(account_number=method_data['account_number']).first()
            
            if account:
                # التحقق من عدم وجود وسيلة الدفع
                existing_method = PaymentMethod.query.filter_by(name=method_data['name']).first()
                if not existing_method:
                    payment_method = PaymentMethod(
                        name=method_data['name'],
                        commission_rate=method_data['commission_rate'],
                        account_id=account.id,
                        settlement_days=method_data['settlement_days'],
                        notes=method_data['notes'],
                        is_active=True
                    )
                    db.session.add(payment_method)
                    created_methods.append(method_data['name'])
        
        db.session.commit()
        
        return jsonify({
            'status': 'success',
            'message': 'Payment system initialized successfully',
            'accounts_created': len(created_accounts),
            'payment_methods_created': len(created_methods),
            'details': {
                'accounts': created_accounts,
                'payment_methods': created_methods
            }
        }), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500
    """
    إعادة تنظيم شجرة الحسابات لاستخدام Sub-Accounts
    تحويل مدى/فيزا/STC/Apple Pay لحسابات فرعية تحت البنك (1112)
    """
    try:
        # 1. حذف الحسابات المنفصلة القديمة (soft delete)
        old_accounts = ['1113', '1114', '1117', '1118']
        deleted_accounts = []
        
        for acc_num in old_accounts:
            account = Account.query.filter_by(account_number=acc_num).first()
            if account:
                # حذف الحساب
                db.session.delete(account)
                deleted_accounts.append(acc_num)
        
        # 2. إنشاء الحسابات الفرعية تحت البنك (1112)
        bank_account = Account.query.filter_by(account_number='1112').first()
        if not bank_account:
            return jsonify({
                'status': 'error',
                'message': 'حساب البنك الرئيسي (1112) غير موجود'
            }), 404
        
        sub_accounts_data = [
            {'account_number': '1112.1', 'name': 'بطاقة مدى - نقاط البيع', 'parent_id': bank_account.id},
            {'account_number': '1112.2', 'name': 'بطاقات فيزا - نقاط البيع', 'parent_id': bank_account.id},
            {'account_number': '1112.3', 'name': 'بطاقات ماستركارد - نقاط البيع', 'parent_id': bank_account.id},
            {'account_number': '1112.4', 'name': 'STC Pay - نقاط البيع', 'parent_id': bank_account.id},
            {'account_number': '1112.5', 'name': 'Apple Pay - نقاط البيع', 'parent_id': bank_account.id},
        ]
        
        created_accounts = []
        for sub_data in sub_accounts_data:
            # التحقق من عدم وجود الحساب
            existing = Account.query.filter_by(account_number=sub_data['account_number']).first()
            if not existing:
                sub_account = Account(
                    account_number=sub_data['account_number'],
                    name=sub_data['name'],
                    type='asset',
                    transaction_type='both',
                    parent_id=sub_data['parent_id']
                )
                db.session.add(sub_account)
                created_accounts.append(sub_data['account_number'])
        
        db.session.commit()
        
        # 3. تحديث وسائل الدفع للإشارة للحسابات الجديدة
        payment_mapping = {
            'بطاقة مدى': '1112.1',
            'فيزا / ماستركارد': '1112.2',  # سنفصلها لاحقاً
            'STC Pay': '1112.4',
            'Apple Pay': '1112.5',
        }
        
        updated_methods = []
        for method_name, new_account_number in payment_mapping.items():
            method = PaymentMethod.query.filter_by(name=method_name).first()
            new_account = Account.query.filter_by(account_number=new_account_number).first()
            
            if method and new_account:
                method.account_id = new_account.id
                updated_methods.append(method_name)
        
        # إضافة ماستركارد كوسيلة منفصلة
        mastercard_account = Account.query.filter_by(account_number='1112.3').first()
        existing_mastercard = PaymentMethod.query.filter_by(name='ماستركارد').first()
        
        if mastercard_account and not existing_mastercard:
            mastercard_method = PaymentMethod(
                name='ماستركارد',
                commission_rate=2.5,
                account_id=mastercard_account.id,
                settlement_days=3,
                notes='عمولة 2.5% - استلام خلال 3 أيام عبر جهاز نقاط البيع',
                is_active=True
            )
            db.session.add(mastercard_method)
            updated_methods.append('ماستركارد (جديد)')
        
        # تحديث اسم فيزا
        visa_method = PaymentMethod.query.filter_by(name='فيزا / ماستركارد').first()
        if visa_method:
            visa_method.name = 'فيزا'
            visa_account = Account.query.filter_by(account_number='1112.2').first()
            if visa_account:
                visa_method.account_id = visa_account.id
        
        db.session.commit()
        
        return jsonify({
            'status': 'success',
            'message': 'تم إعادة تنظيم شجرة الحسابات بنجاح',
            'deleted_accounts': deleted_accounts,
            'created_sub_accounts': created_accounts,
            'updated_payment_methods': updated_methods,
            'structure': {
                'main_account': '1112 - البنك - الحساب الجاري',
                'sub_accounts': [
                    '1112.1 - مدى',
                    '1112.2 - فيزا',
                    '1112.3 - ماستركارد',
                    '1112.4 - STC Pay',
                    '1112.5 - Apple Pay'
                ],
                'independent_accounts': [
                    '1111 - الصندوق (نقداً)',
                    '1115 - تابي (شركة خارجية)',
                    '1116 - تمارا (شركة خارجية)',
                    '1119 - تحويل بنكي مباشر'
                ]
            }
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500


@api.route('/reports/gold_price_history', methods=['GET'])
def get_gold_price_history_report():
    """تحليل تاريخي لأسعار الذهب (أونصة دولار → جرام بالريال والعيار الرئيسي)."""

    group_interval = (request.args.get('group_interval') or 'day').lower()
    if group_interval not in {'day', 'week', 'month'}:
        group_interval = 'day'

    start_param = request.args.get('start_date')
    end_param = request.args.get('end_date')
    limit_param = request.args.get('limit')

    try:
        start_value = _parse_iso_date(start_param, 'start_date') if start_param else None
        end_value = _parse_iso_date(end_param, 'end_date') if end_param else None
    except ValueError as exc:
        return jsonify({'error': str(exc)}), 400

    now = datetime.utcnow()
    default_start = (now - timedelta(days=90)).date()
    applied_start = start_value or default_start
    applied_end = end_value or now.date()

    if applied_start > applied_end:
        return jsonify({'error': 'start_date must be before end_date'}), 400

    try:
        limit = int(limit_param) if limit_param else 180
    except ValueError:
        return jsonify({'error': 'Invalid limit parameter'}), 400
    limit = max(12, min(limit, 730))

    start_dt = datetime.combine(applied_start, datetime.min.time())
    end_dt = datetime.combine(applied_end, datetime.min.time()) + timedelta(days=1)

    price_rows = (
        GoldPrice.query
        .filter(GoldPrice.date >= start_dt)
        .filter(GoldPrice.date < end_dt)
        .order_by(GoldPrice.date.asc())
        .all()
    )

    usd_to_sar_factor = 3.75 / 31.1035  # (USD → SAR) / grams per ounce

    def usd_oz_to_sar_gram(value):
        if value in (None, 0):
            return 0.0 if value == 0 else None
        return value * usd_to_sar_factor

    def round_money(value, digits=2):
        if value is None:
            return None
        return round(float(value), digits)

    def bucket_key(dt_value: datetime):
        if group_interval == 'month':
            return dt_value.strftime('%Y-%m')
        if group_interval == 'week':
            iso_year, iso_week, _ = dt_value.isocalendar()
            return f'{iso_year}-W{iso_week:02d}'
        return dt_value.strftime('%Y-%m-%d')

    def bucket_label(dt_value: datetime):
        if group_interval == 'month':
            return dt_value.strftime('%b %Y')
        if group_interval == 'week':
            iso_year, iso_week, _ = dt_value.isocalendar()
            return f'الأسبوع {iso_week:02d} - {iso_year}'
        return dt_value.strftime('%d %b %Y')

    bucket_map = {}
    price_points = []

    for row in price_rows:
        timestamp = row.date or now
        price_value = float(row.price or 0.0)
        key = bucket_key(timestamp)
        bucket = bucket_map.get(key)
        if bucket is None:
            bucket = {
                'key': key,
                'label': bucket_label(timestamp),
                'count': 0,
                'total_price': 0.0,
                'min_price': None,
                'max_price': None,
                'first_price': None,
                'last_price': None,
                'first_date': None,
                'last_date': None,
            }
            bucket_map[key] = bucket

        bucket['count'] += 1
        bucket['total_price'] += price_value
        bucket['min_price'] = price_value if bucket['min_price'] is None else min(bucket['min_price'], price_value)
        bucket['max_price'] = price_value if bucket['max_price'] is None else max(bucket['max_price'], price_value)
        if bucket['first_price'] is None:
            bucket['first_price'] = price_value
            bucket['first_date'] = timestamp
        bucket['last_price'] = price_value
        bucket['last_date'] = timestamp

        price_points.append({'bucket': key, 'price_usd': price_value, 'timestamp': timestamp})

    if not price_points:
        return jsonify({
            'summary': {
                'records_considered': 0,
                'buckets_count': 0,
                'average_price_usd': 0.0,
                'average_price_sar_24k': 0.0,
                'average_price_sar_main_karat': 0.0,
                'percent_change': 0.0,
                'volatility_percent': 0.0,
            },
            'series': [],
            'latest_price': None,
            'filters': {
                'start_date': applied_start.isoformat(),
                'end_date': applied_end.isoformat(),
                'group_interval': group_interval,
                'limit': limit,
            },
        })

    keys_in_order = list(bucket_map.keys())
    if len(keys_in_order) > limit:
        keys_to_keep = keys_in_order[-limit:]
        trimmed = {}
        for key in keys_to_keep:
            trimmed[key] = bucket_map[key]
        bucket_map = trimmed
        keep_set = set(keys_to_keep)
        price_points = [point for point in price_points if point['bucket'] in keep_set]

    series_payload = []
    main_karat = get_main_karat() or 21
    main_ratio = main_karat / 24.0

    for bucket in bucket_map.values():
        avg_price = bucket['total_price'] / bucket['count'] if bucket['count'] else 0.0
        avg_sar_24 = usd_oz_to_sar_gram(avg_price)
        high_sar = usd_oz_to_sar_gram(bucket['max_price']) if bucket['max_price'] is not None else None
        low_sar = usd_oz_to_sar_gram(bucket['min_price']) if bucket['min_price'] is not None else None
        change_percent = None
        if bucket['first_price'] and bucket['first_price'] != 0:
            change_percent = ((bucket['last_price'] - bucket['first_price']) / bucket['first_price']) * 100

        trend = 'flat'
        if change_percent is not None:
            if change_percent > 0.2:
                trend = 'up'
            elif change_percent < -0.2:
                trend = 'down'

        series_payload.append({
            'period': bucket['key'],
            'label': bucket['label'],
            'points': bucket['count'],
            'avg_price_usd': round_money(avg_price),
            'avg_price_sar_24k': round_money(avg_sar_24),
            'avg_price_sar_main_karat': round_money(avg_sar_24 * main_ratio if avg_sar_24 is not None else None),
            'high_price_usd': round_money(bucket['max_price']),
            'low_price_usd': round_money(bucket['min_price']),
            'high_price_sar_24k': round_money(high_sar),
            'low_price_sar_24k': round_money(low_sar),
            'first_timestamp': bucket['first_date'].isoformat() if bucket['first_date'] else None,
            'last_timestamp': bucket['last_date'].isoformat() if bucket['last_date'] else None,
            'change_percent': round_money(change_percent),
            'trend': trend,
        })

    price_series = sorted(price_points, key=lambda entry: entry['timestamp'])
    start_point = price_series[0]
    end_point = price_series[-1]
    highest_point = max(price_series, key=lambda entry: entry['price_usd'])
    lowest_point = min(price_series, key=lambda entry: entry['price_usd'])

    prices_list = [entry['price_usd'] for entry in price_series]
    avg_price_usd = sum(prices_list) / len(prices_list)
    avg_price_sar_24 = usd_oz_to_sar_gram(avg_price_usd)
    percent_change = None
    if start_point['price_usd']:
        percent_change = ((end_point['price_usd'] - start_point['price_usd']) / start_point['price_usd']) * 100

    volatility_percent = None
    if len(prices_list) > 1 and avg_price_usd:
        volatility_percent = (pstdev(prices_list) / avg_price_usd) * 100

    summary = {
        'records_considered': len(price_series),
        'buckets_count': len(series_payload),
        'start_price_usd': round_money(start_point['price_usd']),
        'end_price_usd': round_money(end_point['price_usd']),
        'start_price_sar_24k': round_money(usd_oz_to_sar_gram(start_point['price_usd'])),
        'end_price_sar_24k': round_money(usd_oz_to_sar_gram(end_point['price_usd'])),
        'average_price_usd': round_money(avg_price_usd),
        'average_price_sar_24k': round_money(avg_price_sar_24),
        'average_price_sar_main_karat': round_money(avg_price_sar_24 * main_ratio if avg_price_sar_24 is not None else None),
        'absolute_change_usd': round_money(end_point['price_usd'] - start_point['price_usd']),
        'absolute_change_sar_24k': round_money(
            usd_oz_to_sar_gram(end_point['price_usd']) - usd_oz_to_sar_gram(start_point['price_usd'])
        ),
        'percent_change': round_money(percent_change),
        'volatility_percent': round_money(volatility_percent),
        'highest_price': {
            'value_usd': round_money(highest_point['price_usd']),
            'value_sar_24k': round_money(usd_oz_to_sar_gram(highest_point['price_usd'])),
            'timestamp': highest_point['timestamp'].isoformat(),
        },
        'lowest_price': {
            'value_usd': round_money(lowest_point['price_usd']),
            'value_sar_24k': round_money(usd_oz_to_sar_gram(lowest_point['price_usd'])),
            'timestamp': lowest_point['timestamp'].isoformat(),
        },
        'main_karat': main_karat,
    }

    latest_price = {
        'price_usd': round_money(end_point['price_usd']),
        'price_sar_24k': round_money(usd_oz_to_sar_gram(end_point['price_usd'])),
        'price_sar_main_karat': round_money(usd_oz_to_sar_gram(end_point['price_usd']) * main_ratio),
        'timestamp': end_point['timestamp'].isoformat(),
    }

    return jsonify({
        'summary': summary,
        'series': series_payload,
        'latest_price': latest_price,
        'filters': {
            'start_date': applied_start.isoformat(),
            'end_date': applied_end.isoformat(),
            'group_interval': group_interval,
            'limit': limit,
        },
    })


@api.route('/reports/gold_position', methods=['GET'])
def get_gold_position_report():
    """عرض مركز الذهب الإجمالي حسب الحسابات والخزائن والمكاتب مع تحويل للعيار الرئيسي."""

    include_zero = request.args.get('include_zero', 'false').lower() == 'true'
    min_variance_param = request.args.get('min_variance')
    safe_types_param = request.args.get('safe_types')
    office_ids_param = request.args.get('office_ids')
    karats_param = request.args.get('karats')

    try:
        min_variance = float(min_variance_param) if min_variance_param else 0.05
        min_variance = max(0.0, min(min_variance, 1000.0))
    except ValueError:
        return jsonify({'error': 'Invalid min_variance value'}), 400

    def parse_float(value, default=0.0):
        try:
            return float(value)
        except (TypeError, ValueError):
            return default

    def round_weight(value):
        return round(float(value or 0.0), 3)

    main_karat = get_main_karat() or 21

    def normalize_to_main(weight_value, karat_value):
        value = parse_float(weight_value)
        karat = parse_float(karat_value, main_karat)
        if value == 0 or main_karat == 0:
            return 0.0
        return (value * karat) / float(main_karat)

    karat_profiles = [
        {'label': '18k', 'field': 'balance_18k', 'karat': 18},
        {'label': '21k', 'field': 'balance_21k', 'karat': 21},
        {'label': '22k', 'field': 'balance_22k', 'karat': 22},
        {'label': '24k', 'field': 'balance_24k', 'karat': 24},
    ]

    karat_filter = set()
    if karats_param:
        for piece in karats_param.split(','):
            piece = piece.strip().lower().replace('k', '').replace('عيار', '')
            if not piece:
                continue
            try:
                karat_filter.add(float(piece))
            except ValueError:
                return jsonify({'error': f'Invalid karat value: {piece}'}), 400

    safe_types_filter = set()
    if safe_types_param:
        safe_types_filter = {
            token.strip().lower()
            for token in safe_types_param.split(',')
            if token.strip()
        }

    office_ids_filter = set()
    if office_ids_param:
        for piece in office_ids_param.split(','):
            piece = piece.strip()
            if not piece:
                continue
            try:
                office_ids_filter.add(int(piece))
            except ValueError:
                return jsonify({'error': f'office_ids must be numeric, got {piece}'}), 400

    summary_by_karat = {profile['label']: 0.0 for profile in karat_profiles}
    total_main = 0.0
    long_total = 0.0
    short_total = 0.0

    def build_breakdown(getter, accumulate=True):
        weights = {}
        normalized_total = 0.0
        for profile in karat_profiles:
            karat_value = profile['karat']
            if karat_filter and karat_value not in karat_filter:
                weights[profile['label']] = 0.0
                continue
            raw_value = parse_float(getter(profile['field']))
            weights[profile['label']] = round_weight(raw_value)
            if accumulate:
                summary_by_karat[profile['label']] += raw_value
            normalized_total += normalize_to_main(raw_value, karat_value)
        return weights, normalized_total

    account_rows = []
    accounts_query = Account.query.filter(Account.tracks_weight == True)
    for account in accounts_query:
        weights, normalized_total = build_breakdown(lambda field: getattr(account, field, 0.0))
        total_main += normalized_total
        if normalized_total > 0:
            long_total += normalized_total
        elif normalized_total < 0:
            short_total += normalized_total

        if not include_zero and abs(normalized_total) < min_variance:
            continue

        account_rows.append({
            'id': account.id,
            'account_number': account.account_number,
            'name': account.name,
            'type': account.type,
            'weights': weights,
            'total_main_karat': round_weight(normalized_total),
            'tracks_weight': account.tracks_weight,
        })

    top_long_accounts = [row for row in account_rows if row['total_main_karat'] > 0]
    top_long_accounts.sort(key=lambda entry: entry['total_main_karat'], reverse=True)
    top_long_accounts = top_long_accounts[:5]

    top_short_accounts = [row for row in account_rows if row['total_main_karat'] < 0]
    top_short_accounts.sort(key=lambda entry: entry['total_main_karat'])
    top_short_accounts = top_short_accounts[:5]

    safe_box_rows = []
    safe_boxes_query = SafeBox.query.filter(SafeBox.is_active.is_(True))
    if safe_types_filter:
        safe_boxes_query = safe_boxes_query.filter(SafeBox.safe_type.in_(safe_types_filter))

    for safe_box in safe_boxes_query.all():
        account = safe_box.account
        if not account or not account.tracks_weight:
            continue
        weights, normalized_total = build_breakdown(lambda field: getattr(account, field, 0.0), accumulate=False)
        if not include_zero and abs(normalized_total) < min_variance:
            continue

        safe_box_rows.append({
            'id': safe_box.id,
            'name': safe_box.name,
            'safe_type': safe_box.safe_type,
            'karat': safe_box.karat,
            'account_id': account.id,
            'account_number': account.account_number,
            'weights': weights,
            'total_main_karat': round_weight(normalized_total),
            'is_default': safe_box.is_default,
        })

    office_rows = []
    offices_query = Office.query
    if office_ids_filter:
        offices_query = offices_query.filter(Office.id.in_(office_ids_filter))
    else:
        offices_query = offices_query.filter(Office.active.is_(True))

    for office in offices_query.all():
        weights = {}
        normalized_total = 0.0
        for profile in karat_profiles:
            karat_val = profile['karat']
            if karat_filter and karat_val not in karat_filter:
                weights[profile['label']] = 0.0
                continue
            # Office fields are named balance_gold_XXk
            field_name = profile['field']
            office_field = field_name.replace('balance_', 'balance_gold_')
            raw_value = parse_float(getattr(office, office_field, 0.0))
            weights[profile['label']] = round_weight(raw_value)
            normalized_total += normalize_to_main(raw_value, karat_val)

        if not include_zero and abs(normalized_total) < min_variance:
            continue

        office_rows.append({
            'id': office.id,
            'name': office.name,
            'office_code': office.office_code,
            'weights': weights,
            'total_main_karat': round_weight(normalized_total),
            'active': office.active,
        })

    distribution = []
    distribution_total_main = 0.0
    for profile in karat_profiles:
        raw_total = summary_by_karat[profile['label']]
        normalized = normalize_to_main(raw_total, profile['karat'])
        distribution_total_main += normalized
        distribution.append({
            'karat': profile['label'],
            'raw_weight': round_weight(raw_total),
            'normalized_main_karat': round_weight(normalized),
        })

    latest_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
    usd_to_sar_per_gram = 3.75 / 31.1035
    price_reference = None
    if latest_price and latest_price.price:
        per_gram_24k = round_weight(latest_price.price * usd_to_sar_per_gram)
        per_gram_main = round_weight(per_gram_24k * (main_karat / 24.0))
        price_reference = {
            'source_date': latest_price.date.isoformat() if latest_price.date else None,
            'price_usd_ounce': round_weight(latest_price.price),
            'price_sar_per_gram_24k': per_gram_24k,
            'price_sar_per_gram_main_karat': per_gram_main,
            'main_karat': main_karat,
        }

    estimated_value = None
    if price_reference:
        estimated_value = round_weight(total_main * price_reference['price_sar_per_gram_main_karat'])

    summary = {
        'total_by_karat': {
            profile['label']: round_weight(summary_by_karat[profile['label']])
            for profile in karat_profiles
        },
        'total_main_karat': round_weight(total_main),
        'long_position_main': round_weight(long_total),
        'short_position_main': round_weight(short_total),
        'net_position_main': round_weight(total_main),
        'distribution': distribution,
        'distribution_total_main': round_weight(distribution_total_main),
        'estimated_value_sar': estimated_value,
        'price_reference': price_reference,
        'main_karat': main_karat,
    }

    return jsonify({
        'summary': summary,
        'accounts': account_rows,
        'safe_boxes': safe_box_rows,
        'offices': office_rows,
        'top_long_accounts': top_long_accounts,
        'top_short_accounts': top_short_accounts,
        'filters': {
            'include_zero': include_zero,
            'min_variance': min_variance,
            'safe_types': list(safe_types_filter) if safe_types_filter else None,
            'office_ids': list(office_ids_filter) if office_ids_filter else None,
            'karats': list(karat_filter) if karat_filter else None,
        },
    })


# ========================================
# Add Bank Information to Accounts
# ========================================
@api.route('/add-bank-info-to-accounts', methods=['POST'])
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


# ==================== Accounting Mapping Endpoints ====================

@api.route('/accounting-mappings', methods=['GET'])
def get_accounting_mappings():
    """
    الحصول على جميع إعدادات الربط المحاسبي
    """
    try:
        from backend.models import AccountingMapping
        
        # يمكن تصفية حسب operation_type إذا تم تمريره كمعامل
        operation_type = request.args.get('operation_type')
        
        if operation_type:
            mappings = AccountingMapping.query.filter_by(
                operation_type=operation_type,
                is_active=True
            ).all()
        else:
            mappings = AccountingMapping.query.filter_by(is_active=True).all()
        
        return jsonify([mapping.to_dict() for mapping in mappings]), 200
    
    except Exception as e:
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500


@api.route('/accounting-mappings', methods=['POST'])
def create_accounting_mapping():
    """
    إنشاء أو تحديث إعداد ربط محاسبي
    """
    try:
        from backend.models import AccountingMapping, Account, db
        
        data = request.get_json()
        
        operation_type = data.get('operation_type')
        account_type = data.get('account_type')
        account_id = data.get('account_id')
        
        if not all([operation_type, account_type, account_id]):
            return jsonify({
                'status': 'error',
                'message': 'يجب تحديد نوع العملية ونوع الحساب والحساب المحاسبي'
            }), 400
        
        # التحقق من وجود الحساب
        account = Account.query.get(account_id)
        if not account:
            return jsonify({
                'status': 'error',
                'message': 'الحساب المحاسبي غير موجود'
            }), 404
        
        # البحث عن ربط موجود
        existing_mapping = AccountingMapping.query.filter_by(
            operation_type=operation_type,
            account_type=account_type
        ).first()
        
        if existing_mapping:
            # تحديث الربط الموجود
            existing_mapping.account_id = account_id
            existing_mapping.allocation_percentage = data.get('allocation_percentage')
            existing_mapping.description = data.get('description')
            existing_mapping.is_active = data.get('is_active', True)
            
            db.session.commit()
            
            return jsonify({
                'status': 'success',
                'message': 'تم تحديث إعدادات الربط بنجاح',
                'mapping': existing_mapping.to_dict()
            }), 200
        else:
            # إنشاء ربط جديد
            new_mapping = AccountingMapping(
                operation_type=operation_type,
                account_type=account_type,
                account_id=account_id,
                allocation_percentage=data.get('allocation_percentage'),
                description=data.get('description'),
                is_active=data.get('is_active', True),
                created_by=data.get('created_by', 'system')
            )
            
            db.session.add(new_mapping)
            db.session.commit()
            
            return jsonify({
                'status': 'success',
                'message': 'تم إنشاء إعدادات الربط بنجاح',
                'mapping': new_mapping.to_dict()
            }), 201
    
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500


@api.route('/accounting-mappings/batch', methods=['POST'])
def batch_create_accounting_mappings():
    """
    إنشاء عدة إعدادات ربط دفعة واحدة
    """
    try:
        from backend.models import AccountingMapping, Account, db
        
        data = request.get_json()
        mappings_data = data.get('mappings', [])
        
        if not mappings_data:
            return jsonify({
                'status': 'error',
                'message': 'لا توجد بيانات للإنشاء'
            }), 400
        
        created_mappings = []
        updated_mappings = []
        errors = []
        
        for mapping_data in mappings_data:
            try:
                operation_type = mapping_data.get('operation_type')
                account_type = mapping_data.get('account_type')
                account_id = mapping_data.get('account_id')
                
                if not all([operation_type, account_type, account_id]):
                    errors.append(f'بيانات ناقصة: {mapping_data}')
                    continue
                
                # التحقق من وجود الحساب
                account = Account.query.get(account_id)
                if not account:
                    errors.append(f'الحساب {account_id} غير موجود')
                    continue
                
                # البحث عن ربط موجود
                existing_mapping = AccountingMapping.query.filter_by(
                    operation_type=operation_type,
                    account_type=account_type
                ).first()
                
                if existing_mapping:
                    # تحديث
                    existing_mapping.account_id = account_id
                    existing_mapping.allocation_percentage = mapping_data.get('allocation_percentage')
                    existing_mapping.description = mapping_data.get('description')
                    existing_mapping.is_active = mapping_data.get('is_active', True)
                    updated_mappings.append(existing_mapping.to_dict())
                else:
                    # إنشاء
                    new_mapping = AccountingMapping(
                        operation_type=operation_type,
                        account_type=account_type,
                        account_id=account_id,
                        allocation_percentage=mapping_data.get('allocation_percentage'),
                        description=mapping_data.get('description'),
                        is_active=mapping_data.get('is_active', True),
                        created_by=data.get('created_by', 'system')
                    )
                    db.session.add(new_mapping)
                    created_mappings.append(new_mapping.to_dict())
            
            except Exception as e:
                errors.append(f'خطأ في معالجة {mapping_data}: {str(e)}')
        
        db.session.commit()
        
        return jsonify({
            'status': 'success',
            'message': f'تم إنشاء {len(created_mappings)} وتحديث {len(updated_mappings)} من إعدادات الربط',
            'created': created_mappings,
            'updated': updated_mappings,
            'errors': errors
        }), 200
    
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500


@api.route('/accounting-mappings/<int:mapping_id>', methods=['DELETE'])
def delete_accounting_mapping(mapping_id):
    """
    حذف إعداد ربط محاسبي
    """
    try:
        from backend.models import AccountingMapping, db
        
        mapping = AccountingMapping.query.get(mapping_id)
        
        if not mapping:
            return jsonify({
                'status': 'error',
                'message': 'إعدادات الربط غير موجودة'
            }), 404
        
        db.session.delete(mapping)
        db.session.commit()
        
        return jsonify({
            'status': 'success',
            'message': 'تم حذف إعدادات الربط بنجاح'
        }), 200
    
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500


@api.route('/accounting-mappings/get-account', methods=['POST'])
def get_mapped_account():
    """
    الحصول على الحساب المرتبط لعملية معينة
    """
    try:
        from backend.models import AccountingMapping
        
        data = request.get_json()
        operation_type = data.get('operation_type')
        account_type = data.get('account_type')
        
        if not all([operation_type, account_type]):
            return jsonify({
                'status': 'error',
                'message': 'يجب تحديد نوع العملية ونوع الحساب'
            }), 400
        
        mapping = AccountingMapping.query.filter_by(
            operation_type=operation_type,
            account_type=account_type,
            is_active=True
        ).first()
        
        if not mapping:
            return jsonify({
                'status': 'error',
                'message': 'لا يوجد ربط محاسبي لهذه العملية'
            }), 404
        
        return jsonify({
            'status': 'success',
            'mapping': mapping.to_dict()
        }), 200
    
    except Exception as e:
        return jsonify({
            'status': 'error',
            'message': str(e)
        }), 500


# ============================================================================
# SafeBox Routes (إدارة الخزائن)
# ============================================================================

@api.route('/safe-boxes', methods=['GET'])
def list_safe_boxes():
    """الحصول على جميع الخزائن أو حسب النوع"""
    safe_type = request.args.get('safe_type')  # cash, bank, gold, check
    is_active = request.args.get('is_active')
    karat = request.args.get('karat', type=int)
    
    query = SafeBox.query
    
    if safe_type:
        query = query.filter_by(safe_type=safe_type)
    
    if is_active is not None:
        query = query.filter_by(is_active=is_active.lower() == 'true')
    
    if karat:
        query = query.filter_by(karat=karat)
    
    safe_boxes = query.order_by(SafeBox.is_default.desc(), SafeBox.name).all()
    
    include_account = request.args.get('include_account', 'false').lower() == 'true'
    include_balance = request.args.get('include_balance', 'false').lower() == 'true'
    
    return jsonify([sb.to_dict(include_account=include_account, include_balance=include_balance) for sb in safe_boxes])


@api.route('/safe-boxes/<int:safe_box_id>', methods=['GET'])
def get_safe_box(safe_box_id):
    """الحصول على خزينة محددة"""
    safe_box = SafeBox.query.get_or_404(safe_box_id)
    include_account = request.args.get('include_account', 'true').lower() == 'true'
    include_balance = request.args.get('include_balance', 'true').lower() == 'true'
    
    return jsonify(safe_box.to_dict(include_account=include_account, include_balance=include_balance))


@api.route('/safe-boxes', methods=['POST'])
def create_safe_box():
    """إنشاء خزينة جديدة"""
    data = request.get_json() or {}
    
    # التحقق من الحقول المطلوبة
    if not data.get('name'):
        return jsonify({'error': 'اسم الخزينة مطلوب'}), 400
    
    if not data.get('safe_type'):
        return jsonify({'error': 'نوع الخزينة مطلوب'}), 400
    
    if not data.get('account_id'):
        return jsonify({'error': 'الحساب المرتبط مطلوب'}), 400
    
    # التحقق من وجود الحساب
    account = Account.query.get(data['account_id'])
    if not account:
        return jsonify({'error': 'الحساب المحدد غير موجود'}), 404
    
    # إذا كانت خزينة ذهبية، يجب تحديد العيار
    if data['safe_type'] == 'gold' and not data.get('karat'):
        return jsonify({'error': 'العيار مطلوب للخزائن الذهبية'}), 400
    
    try:
        safe_box = SafeBox(
            name=data['name'],
            name_en=data.get('name_en'),
            safe_type=data['safe_type'],
            account_id=data['account_id'],
            karat=data.get('karat'),
            bank_name=data.get('bank_name'),
            iban=data.get('iban'),
            swift_code=data.get('swift_code'),
            branch=data.get('branch'),
            is_active=data.get('is_active', True),
            is_default=data.get('is_default', False),
            notes=data.get('notes'),
            created_by=data.get('created_by'),
        )
        
        # إذا كانت افتراضية، إلغاء تفعيل الافتراضية من الخزائن الأخرى من نفس النوع
        if safe_box.is_default:
            SafeBox.query.filter_by(safe_type=safe_box.safe_type, is_default=True).update({'is_default': False})
        
        db.session.add(safe_box)
        db.session.commit()
        
        return jsonify(safe_box.to_dict(include_account=True, include_balance=True)), 201
    
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'فشل إنشاء الخزينة: {str(e)}'}), 500


@api.route('/safe-boxes/<int:safe_box_id>', methods=['PUT'])
def update_safe_box(safe_box_id):
    """تحديث خزينة"""
    safe_box = SafeBox.query.get_or_404(safe_box_id)
    data = request.get_json() or {}
    
    try:
        if 'name' in data:
            safe_box.name = data['name']
        
        if 'name_en' in data:
            safe_box.name_en = data['name_en']
        
        if 'safe_type' in data:
            safe_box.safe_type = data['safe_type']
        
        if 'account_id' in data:
            account = Account.query.get(data['account_id'])
            if not account:
                return jsonify({'error': 'الحساب المحدد غير موجود'}), 404
            safe_box.account_id = data['account_id']
        
        if 'karat' in data:
            safe_box.karat = data['karat']
        
        if 'bank_name' in data:
            safe_box.bank_name = data['bank_name']
        
        if 'iban' in data:
            safe_box.iban = data['iban']
        
        if 'swift_code' in data:
            safe_box.swift_code = data['swift_code']
        
        if 'branch' in data:
            safe_box.branch = data['branch']
        
        if 'is_active' in data:
            safe_box.is_active = data['is_active']
        
        if 'is_default' in data and data['is_default']:
            # إلغاء تفعيل الافتراضية من الخزائن الأخرى من نفس النوع
            SafeBox.query.filter(
                SafeBox.safe_type == safe_box.safe_type,
                SafeBox.id != safe_box_id,
                SafeBox.is_default == True
            ).update({'is_default': False})
            safe_box.is_default = True
        
        if 'notes' in data:
            safe_box.notes = data['notes']
        
        db.session.commit()
        return jsonify(safe_box.to_dict(include_account=True, include_balance=True))
    
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'فشل تحديث الخزينة: {str(e)}'}), 500


@api.route('/safe-boxes/<int:safe_box_id>', methods=['DELETE'])
def delete_safe_box(safe_box_id):
    """حذف خزينة"""
    safe_box = SafeBox.query.get_or_404(safe_box_id)
    
    # التحقق من عدم وجود معاملات مرتبطة (يمكن إضافة المزيد من الفحوصات)
    # في المستقبل: فحص السندات والحركات المرتبطة بالحساب
    
    try:
        db.session.delete(safe_box)
        db.session.commit()
        return jsonify({'message': 'تم حذف الخزينة بنجاح'})
    
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': f'فشل حذف الخزينة: {str(e)}'}), 500


@api.route('/safe-boxes/default/<safe_type>', methods=['GET'])
def get_default_safe_box(safe_type):
    """الحصول على الخزينة الافتراضية حسب النوع"""
    safe_box = SafeBox.get_default_by_type(safe_type)
    
    if not safe_box:
        return jsonify({'error': f'لا توجد خزينة افتراضية من نوع {safe_type}'}), 404
    
    return jsonify(safe_box.to_dict(include_account=True, include_balance=True))


@api.route('/safe-boxes/gold/<int:karat>', methods=['GET'])
def get_gold_safe_box_by_karat(karat):
    """الحصول على خزينة الذهب حسب العيار"""
    safe_box = SafeBox.get_gold_safe_by_karat(karat)
    
    if not safe_box:
        return jsonify({'error': f'لا توجد خزينة ذهب لعيار {karat}'}), 404
    
    return jsonify(safe_box.to_dict(include_account=True, include_balance=True))


