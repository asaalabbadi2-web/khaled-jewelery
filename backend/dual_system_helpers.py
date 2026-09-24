"""
🟡 القاعدة الذهبية للنظام المزدوج (ريال ↔ وزن)
=====================================================

⚠️ تحديث مهم:
--------------
منطق القاعدة الذهبية الآن في:
backend/services/weight_ledger_service.py

يُفضل استخدام WeightLedgerService مباشرة بدلاً من هذه الدوال
لتجنب تكرار الكود وضمان تطبيق موحد للقاعدة.

المبدأ الأساسي:
--------------
أي ريال يدخل أو يخرج → يتحول فورًا إلى جرام في دفتر الوزن

الاستثناء الوحيد:
-----------------
المخزون الذهبي:
- في الدفتر المالي: يُسجّل بالقيمة (التكلفة بالريال)
- في الدفتر الوزني: يُسجّل بالوزن الفعلي (بدون تحويل)

آلية التحويل:
-------------
الوزن المعادل = المبلغ بالريال ÷ السعر المباشر للذهب عيار 24

الفوائد:
--------
1. قوائم مالية مزدوجة (نقد + وزن)
2. تتبع الأداء الحقيقي بالوزن
3. حماية من تقلبات الأسعار
4. ربحية وزنية واضحة

Dual accounting system helpers (cash + weight)
Note: These functions must be called from within a Flask app context
"""

from config import MAIN_KARAT as CONFIG_MAIN_KARAT, WEIGHT_SUPPORT_ACCOUNTS
from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS

_MAIN_KARAT_CACHE = None


def _get_main_karat_value(db_session):
    """Return the main karat configured for weight normalization."""
    global _MAIN_KARAT_CACHE
    if _MAIN_KARAT_CACHE:
        return _MAIN_KARAT_CACHE
    value = CONFIG_MAIN_KARAT or 21
    try:
        from models import Settings
        settings = db_session.query(Settings).first()
        if settings and settings.main_karat:
            value = settings.main_karat
    except Exception:
        # Fallback silently to the configured value
        pass
    _MAIN_KARAT_CACHE = value
    return value


def _normalize_weight_to_main(weight, karat, main_karat):
    if not weight or weight <= 0 or not main_karat:
        return 0.0
    return (weight * karat) / main_karat


def create_dual_journal_entry(journal_entry_id, account_id, cash_debit=0, cash_credit=0, 
                               weight_18k_debit=0, weight_18k_credit=0,
                               weight_21k_debit=0, weight_21k_credit=0,
                               weight_22k_debit=0, weight_22k_credit=0,
                               weight_24k_debit=0, weight_24k_credit=0,
                               description=None, customer_id=None, supplier_id=None,
                               debit_18k=0, credit_18k=0,
                               debit_21k=0, credit_21k=0,
                               debit_22k=0, credit_22k=0,
                               debit_24k=0, credit_24k=0,
                               apply_golden_rule=True,  # 🆕 تطبيق القاعدة الذهبية تلقائياً
                               exclude_from_ledger=False,  # 🆕 لا تربط السطر بالعميل/المورد تلقائياً
                               **kwargs):
    """
    Create dual journal entry with cash and weight.
    Must be called from routes.py where db is already in context.

    ─────────────────────────────────────────────────────────────────────
    حارس الفصل بين الحساب النقدي والوزني
    ─────────────────────────────────────────────────────────────────────
    القاعدة الصارمة:
      • حساب cash  → يستقبل نقداً فقط  (أوزان تُعاد توجيهها لـ memo_account_id)
      • حساب gold  → يستقبل وزناً فقط  (نقد يُعاد توجيهه لـ memo_account_id)
    التطبيق يتم هنا قبل أي معالجة أخرى، فهو الخط الأخير للدفاع.
    ─────────────────────────────────────────────────────────────────────
    
    Args:
        apply_golden_rule: تطبيق القاعدة الذهبية (افتراضي True)
        customer_id: معرف العميل (اختياري)
        supplier_id: معرف المورد (اختياري)
        **kwargs: معاملات ديناميكية إضافية (يتم تجاهلها)
    """
    
    # دمج المعاملات القديمة والجديدة
    weight_18k_debit = weight_18k_debit or debit_18k
    weight_18k_credit = weight_18k_credit or credit_18k
    weight_21k_debit = weight_21k_debit or debit_21k
    weight_21k_credit = weight_21k_credit or credit_21k
    weight_22k_debit = weight_22k_debit or debit_22k
    weight_22k_credit = weight_22k_credit or credit_22k
    weight_24k_debit = weight_24k_debit or debit_24k
    weight_24k_credit = weight_24k_credit or credit_24k
    # Get db from current Flask app extensions
    from flask import current_app
    from models import JournalEntryLine, Account, JournalEntry, Invoice, Voucher
    
    db = current_app.extensions['sqlalchemy']

    # ─────────────────────────────────────────────────────────────────────
    # توزيع القيم المختلطة عبر dual_distribution_service — المحرك المركزي
    # الوحيد لمنطق التوجيه. نفس الخوارزمية المستخدمة في journals.py.
    # ─────────────────────────────────────────────────────────────────────
    from dual_distribution_service import distribute_line as _distribute_line
    import logging as _logging
    _dds_log = _logging.getLogger('dual_distribution_service')

    _input_line = {
        'account_id': account_id,
        'cash_debit': cash_debit, 'cash_credit': cash_credit,
        'debit_18k': weight_18k_debit, 'credit_18k': weight_18k_credit,
        'debit_21k': weight_21k_debit, 'credit_21k': weight_21k_credit,
        'debit_22k': weight_22k_debit, 'credit_22k': weight_22k_credit,
        'debit_24k': weight_24k_debit, 'credit_24k': weight_24k_credit,
    }
    _distributed = _distribute_line(_input_line)

    if len(_distributed) > 1 or (_distributed and _distributed[0].get('account_id') != account_id):
        # جرى توزيع — أنشئ سطراً للحسابات الإضافية (الجانب الموازي)
        for _dl in _distributed:
            if _dl.get('account_id') != account_id:
                _dds_log.debug(
                    'dual_distribution: redirect JE=%s acc=%s → acc=%s',
                    journal_entry_id, account_id, _dl['account_id'],
                )
                create_dual_journal_entry(
                    journal_entry_id=journal_entry_id,
                    account_id=_dl['account_id'],
                    cash_debit=_dl.get('cash_debit', 0),
                    cash_credit=_dl.get('cash_credit', 0),
                    weight_18k_debit=_dl.get('debit_18k', 0),
                    weight_18k_credit=_dl.get('credit_18k', 0),
                    weight_21k_debit=_dl.get('debit_21k', 0),
                    weight_21k_credit=_dl.get('credit_21k', 0),
                    weight_22k_debit=_dl.get('debit_22k', 0),
                    weight_22k_credit=_dl.get('credit_22k', 0),
                    weight_24k_debit=_dl.get('debit_24k', 0),
                    weight_24k_credit=_dl.get('credit_24k', 0),
                    description=description,
                    customer_id=customer_id, supplier_id=supplier_id,
                    apply_golden_rule=False,
                    exclude_from_ledger=exclude_from_ledger,
                )
        # حدّث args الحساب الحالي بالقيم المتبقية بعد التوزيع
        _my_line = next(
            (_dl for _dl in _distributed if _dl.get('account_id') == account_id), None
        )
        if _my_line is None:
            return  # الحساب الحالي لم يبقَ له قيم — لا سطر يُنشأ
        cash_debit = _my_line.get('cash_debit', 0)
        cash_credit = _my_line.get('cash_credit', 0)
        weight_18k_debit = _my_line.get('debit_18k', 0)
        weight_18k_credit = _my_line.get('credit_18k', 0)
        weight_21k_debit = _my_line.get('debit_21k', 0)
        weight_21k_credit = _my_line.get('credit_21k', 0)
        weight_22k_debit = _my_line.get('debit_22k', 0)
        weight_22k_credit = _my_line.get('credit_22k', 0)
        weight_24k_debit = _my_line.get('debit_24k', 0)
        weight_24k_credit = _my_line.get('credit_24k', 0)
    # ─────────────────────────────────────────────────────────────────────

    if account_id is None:
        raise ValueError(
            "Account id is None while creating dual journal entry "
            f"(journal_entry_id={journal_entry_id}, description={description!r}, "
            f"cash_debit={cash_debit}, cash_credit={cash_credit}, "
            f"w18d={weight_18k_debit}, w18c={weight_18k_credit}, "
            f"w21d={weight_21k_debit}, w21c={weight_21k_credit}, "
            f"w22d={weight_22k_debit}, w22c={weight_22k_credit}, "
            f"w24d={weight_24k_debit}, w24c={weight_24k_credit})"
        )

    account = db.session.query(Account).filter_by(id=account_id).first()
    if not account:
        raise ValueError(f"Account {account_id} not found while creating dual journal entry")

    account_code = (account.account_number or '').strip()
    # حسابات المذكرة تبدأ بـ '7' (النظام القديم)
    is_memo_account = account_code.startswith('7') if account_code else False
    memo_main_karat = _get_main_karat_value(db.session) if is_memo_account else None

    # Resolve customer/supplier context automatically when not provided explicitly.
    # When exclude_from_ledger=True we *don't* auto-tag the line with customer/supplier
    # from the related invoice/voucher to avoid mixing valuation/inventory lines into entity statements.
    resolved_customer_id = customer_id
    resolved_supplier_id = supplier_id

    try:
        journal_entry = db.session.query(JournalEntry).get(journal_entry_id)
    except Exception:
        journal_entry = None

    related_invoice = None
    related_voucher = None

    if journal_entry:
        if journal_entry.reference_type == 'invoice':
            related_invoice = db.session.query(Invoice).get(journal_entry.reference_id)
            if related_invoice and not exclude_from_ledger:
                if not resolved_customer_id and related_invoice.customer_id:
                    resolved_customer_id = related_invoice.customer_id
                if not resolved_supplier_id and related_invoice.supplier_id:
                    resolved_supplier_id = related_invoice.supplier_id
        elif journal_entry.reference_type == 'voucher':
            related_voucher = db.session.query(Voucher).get(journal_entry.reference_id)
            if related_voucher and not exclude_from_ledger:
                if not resolved_customer_id and related_voucher.customer_id:
                    resolved_customer_id = related_voucher.customer_id
                if not resolved_supplier_id and related_voucher.supplier_id:
                    resolved_supplier_id = related_voucher.supplier_id

    # 🆕 Financial Dimensions (line-level)
    dimension_set_id = None
    try:
        from dimensions_service import DimensionInput, get_or_create_dimension_set

        dim_inputs = []

        # Branch (stored under the 'office' dimension code in analytics)
        # مكاتب التسكير كيان مختلف؛ لذلك لا نستخدم invoice.office_id كـ "فرع".
        branch_id = getattr(related_invoice, 'branch_id', None)
        branch_label = None
        if branch_id:
            try:
                from models import Branch
                branch = db.session.query(Branch).get(branch_id)
                branch_label = branch.name if branch else None
            except Exception:
                branch_label = None

            dim_inputs.append(DimensionInput(code='office', int_value=int(branch_id), label_ar=branch_label))

        # Gold Office (مكتب تسكير / مورد ذهب خام)
        # This is distinct from Branch and uses its own dimension code.
        gold_office_id = getattr(related_invoice, 'office_id', None)
        gold_office_label = None
        if gold_office_id:
            try:
                from models import Office
                office_row = db.session.query(Office).get(gold_office_id)
                gold_office_label = office_row.name if office_row else None
            except Exception:
                gold_office_label = None

            dim_inputs.append(
                DimensionInput(
                    code='gold_office',
                    int_value=int(gold_office_id),
                    label_ar=gold_office_label,
                )
            )

        # Transaction Type
        transaction_type = getattr(related_invoice, 'invoice_type', None) or getattr(journal_entry, 'entry_type', None)
        if transaction_type:
            dim_inputs.append(DimensionInput(code='transaction_type', str_value=str(transaction_type), label_ar=str(transaction_type)))

        # Employee
        employee_username = getattr(journal_entry, 'posted_by', None) or getattr(journal_entry, 'created_by', None)
        if employee_username:
            dim_inputs.append(DimensionInput(code='employee', str_value=str(employee_username), label_ar=str(employee_username)))

        dimension_set_id = get_or_create_dimension_set(db.session, dim_inputs)
    except Exception:
        dimension_set_id = None
    
    # 🆕 تطبيق القاعدة الذهبية تلقائياً
    # إذا كان الحساب له memo_account_id وتم تمرير قيم نقدية فقط
    has_weights = any([weight_18k_debit, weight_18k_credit, weight_21k_debit, weight_21k_credit,
                       weight_22k_debit, weight_22k_credit, weight_24k_debit, weight_24k_credit])
    has_cash = (cash_debit > 0 or cash_credit > 0)
    
    # Only apply golden rule when the target account is intended to carry weight.
    # Otherwise we create "phantom" weight on non-weight accounts, which breaks JE balancing.
    if apply_golden_rule and has_cash and not has_weights and account.memo_account_id and is_memo_account:
        # الحصول على سعر الذهب للعيار الرئيسي مباشرة من قاعدة البيانات
        try:
            from models import GoldPrice, Settings
            
            # الحصول على آخر سعر ذهب (هو سعر الأونصة بالدولار)
            latest_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
            if not latest_price:
                raise Exception("لا يوجد سعر ذهب محفوظ")
            
            price_per_gram_24k_sar = (latest_price.price / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
            
            # الحصول على العيار الرئيسي من الإعدادات
            settings = Settings.query.first()
            main_karat = settings.main_karat if settings else 21
            
            # 🔧 FIXED: حساب السعر للعيار الرئيسي (SAR/gram)
            gold_price_main_karat = (price_per_gram_24k_sar * main_karat) / 24.0
            
            if gold_price_main_karat > 0:
                # تطبيق القاعدة الذهبية
                if cash_debit > 0:
                    weight_main_debit = cash_debit / gold_price_main_karat
                    # تعيين الوزن في حقل العيار الرئيسي
                    if main_karat == 18:
                        weight_18k_debit = weight_main_debit
                    elif main_karat == 21:
                        weight_21k_debit = weight_main_debit
                    elif main_karat == 22:
                        weight_22k_debit = weight_main_debit
                    elif main_karat == 24:
                        weight_24k_debit = weight_main_debit
                
                if cash_credit > 0:
                    weight_main_credit = cash_credit / gold_price_main_karat
                    # تعيين الوزن في حقل العيار الرئيسي
                    if main_karat == 18:
                        weight_18k_credit = weight_main_credit
                    elif main_karat == 21:
                        weight_21k_credit = weight_main_credit
                    elif main_karat == 22:
                        weight_22k_credit = weight_main_credit
                    elif main_karat == 24:
                        weight_24k_credit = weight_main_credit
                
                print(f"✅ تطبيق القاعدة الذهبية على حساب {account.account_number}: {cash_debit or cash_credit} ريال = {weight_main_debit if cash_debit else weight_main_credit:.3f} جرام ({main_karat}k @ {gold_price_main_karat:.2f} SAR/g)")
                
                # سجل إلى ملف أيضاً
                with open('/tmp/golden_rule.log', 'a', encoding='utf-8') as f:
                    f.write(f"✅ [{account.account_number}] {cash_debit or cash_credit} ريال = {weight_main_debit if cash_debit else weight_main_credit:.3f}جم ({main_karat}k)\\n")
        except Exception as e:
            print(f"⚠️ تعذر تطبيق القاعدة الذهبية على حساب {account.account_number}: {e}")
            with open('/tmp/golden_rule.log', 'a', encoding='utf-8') as f:
                f.write(f"❌ [{account.account_number}] خطأ: {e}\\n")
    else:
        # سجل تصحيح: لماذا لم يتم تطبيق القاعدة؟
        if has_cash and not has_weights:
            if not account.memo_account_id:
                print(f"⏭️ تخطي القاعدة الذهبية للحساب {account.account_number} ({account.name}): لا يوجد حساب موازي")
                with open('/tmp/golden_rule.log', 'a', encoding='utf-8') as f:
                    f.write(f"⏭️ [{account.account_number}] تخطي: لا يوجد حساب موازي\\n")
            elif not apply_golden_rule:
                print(f"⏭️ تخطي القاعدة الذهبية للحساب {account.account_number}: apply_golden_rule=False")
                with open('/tmp/golden_rule.log', 'a', encoding='utf-8') as f:
                    f.write(f"⏭️ [{account.account_number}] تخطي: apply_golden_rule=False\\n")
    
    # Create the journal entry line
    line = JournalEntryLine(
        journal_entry_id=journal_entry_id,
        account_id=account_id,
        customer_id=resolved_customer_id,  # 🆕 ربط بالعميل
        supplier_id=resolved_supplier_id,  # 🆕 ربط بالمورد
        dimension_set_id=dimension_set_id,
    )

    # Persist line-level description when provided.
    if description:
        line.description = description
    
    # Set cash amounts
    if cash_debit > 0:
        line.cash_debit = round(cash_debit, 2)
    if cash_credit > 0:
        line.cash_credit = round(cash_credit, 2)
    
    # Set weight amounts (only if weight parameters provided)
    if weight_18k_debit > 0:
        line.debit_18k = round(weight_18k_debit, 3)
    if weight_18k_credit > 0:
        line.credit_18k = round(weight_18k_credit, 3)
        
    if weight_21k_debit > 0:
        line.debit_21k = round(weight_21k_debit, 3)
    if weight_21k_credit > 0:
        line.credit_21k = round(weight_21k_credit, 3)
        
    if weight_22k_debit > 0:
        line.debit_22k = round(weight_22k_debit, 3)
    if weight_22k_credit > 0:
        line.credit_22k = round(weight_22k_credit, 3)
        
    if weight_24k_debit > 0:
        line.debit_24k = round(weight_24k_debit, 3)
    if weight_24k_credit > 0:
        line.credit_24k = round(weight_24k_credit, 3)

    if is_memo_account and memo_main_karat:
        total_debit_weight = (
            _normalize_weight_to_main(weight_18k_debit, 18, memo_main_karat) +
            _normalize_weight_to_main(weight_21k_debit, 21, memo_main_karat) +
            _normalize_weight_to_main(weight_22k_debit, 22, memo_main_karat) +
            _normalize_weight_to_main(weight_24k_debit, 24, memo_main_karat)
        )
        total_credit_weight = (
            _normalize_weight_to_main(weight_18k_credit, 18, memo_main_karat) +
            _normalize_weight_to_main(weight_21k_credit, 21, memo_main_karat) +
            _normalize_weight_to_main(weight_22k_credit, 22, memo_main_karat) +
            _normalize_weight_to_main(weight_24k_credit, 24, memo_main_karat)
        )

        if total_debit_weight > 0:
            line.debit_weight = round(total_debit_weight, 6)
        if total_credit_weight > 0:
            line.credit_weight = round(total_credit_weight, 6)

    # 🆕 Analytics metrics (signed)
    try:
        from dimensions_service import compute_line_analytics

        amount_cash, weight_24k, weight_main = compute_line_analytics(db.session, line)
        line.analytic_amount_cash = amount_cash
        line.analytic_weight_24k = weight_24k
        line.analytic_weight_main = weight_main
    except Exception:
        pass
    
    db.session.add(line)
    
    # Update account balance
    try:
        if account and hasattr(account, 'update_balance'):
            account.update_balance(
                cash_amount=(cash_debit - cash_credit),
                weight_18k=(weight_18k_debit - weight_18k_credit),
                weight_21k=(weight_21k_debit - weight_21k_credit),
                weight_22k=(weight_22k_debit - weight_22k_credit),
                weight_24k=(weight_24k_debit - weight_24k_credit)
            )
    except Exception as e:
        # If account update fails, log it but don't fail the entry creation
        print(f"Warning: Could not update account balance for account {account_id}: {e}")
    
    # A SUPPLIER balance is deliberately NOT updated here.
    #
    # This block used to do `supplier.balance_gold_21k += (debit - credit)` and
    # the same for cash and the other karats. That incremental cache drifted
    # from the ledger by 21,121.06 g across 24 suppliers in real production:
    # every GL write that bypassed this helper, every write with an unresolved
    # supplier_id, and every reversal or deletion widened the gap, while
    # compute_live_supplier_balances() — the declared Single Source — read the
    # journal with additional rules of its own. A supplier balance is now
    # derived on read from that one function and stored nowhere.
    # Enforced by tests/test_supplier_balance_is_derived_ratchet.py.
    #
    # Customer is intentionally left as-is: same defect, but its own consumers,
    # and an explicitly deferred decision.
    try:
        if resolved_customer_id:
            from models import Customer
            customer = db.session.query(Customer).filter_by(id=resolved_customer_id).first()
            if customer:
                print(f"🔍 Updating customer {resolved_customer_id} balance:")
                print(f"   Before: cash={customer.balance_cash}, 18k={customer.balance_gold_18k}, 21k={customer.balance_gold_21k}")
                customer.balance_cash += (cash_debit - cash_credit)
                customer.balance_gold_18k += (weight_18k_debit - weight_18k_credit)
                customer.balance_gold_21k += (weight_21k_debit - weight_21k_credit)
                customer.balance_gold_22k += (weight_22k_debit - weight_22k_credit)
                customer.balance_gold_24k += (weight_24k_debit - weight_24k_credit)
                print(f"   After: cash={customer.balance_cash}, 18k={customer.balance_gold_18k}, 21k={customer.balance_gold_21k}")
            else:
                print(f"⚠️ Customer {resolved_customer_id} not found!")
    except Exception as e:
        print(f"❌ Warning: Could not update customer/supplier balance: {e}")
    
    return line


def verify_dual_balance(journal_entry_id):
    """
    Verify dual balance for a journal entry.
    Must be called from routes.py where db is already in context.
    """
    from sqlalchemy import func
    from flask import current_app
    from models import JournalEntryLine, Account
    
    db = current_app.extensions['sqlalchemy']
    
    cash_totals = db.session.query(
        func.sum(JournalEntryLine.cash_debit).label('total_debit'),
        func.sum(JournalEntryLine.cash_credit).label('total_credit')
    ).filter_by(journal_entry_id=journal_entry_id).first()
    
    cash_debit = cash_totals.total_debit or 0
    cash_credit = cash_totals.total_credit or 0
    cash_balance = round(cash_debit - cash_credit, 2)
    
    weight_totals = db.session.query(
        func.sum(JournalEntryLine.debit_18k).label('debit_18k'),
        func.sum(JournalEntryLine.credit_18k).label('credit_18k'),
        func.sum(JournalEntryLine.debit_21k).label('debit_21k'),
        func.sum(JournalEntryLine.credit_21k).label('credit_21k'),
        func.sum(JournalEntryLine.debit_22k).label('debit_22k'),
        func.sum(JournalEntryLine.credit_22k).label('credit_22k'),
        func.sum(JournalEntryLine.debit_24k).label('debit_24k'),
        func.sum(JournalEntryLine.credit_24k).label('credit_24k')
    ).filter_by(journal_entry_id=journal_entry_id).first()
    
    weight_balances = {
        '18k': round((weight_totals.debit_18k or 0) - (weight_totals.credit_18k or 0), 3),
        '21k': round((weight_totals.debit_21k or 0) - (weight_totals.credit_21k or 0), 3),
        '22k': round((weight_totals.debit_22k or 0) - (weight_totals.credit_22k or 0), 3),
        '24k': round((weight_totals.debit_24k or 0) - (weight_totals.credit_24k or 0), 3)
    }

    # Debug logging to trace imbalances (helps diagnose weight gaps)
    try:
        log_lines = [
            f"🔍 Dual balance check for JE #{journal_entry_id}",
            f"   Cash -> debit: {cash_debit:.2f}, credit: {cash_credit:.2f}, diff: {cash_balance:.2f}",
            f"   18k -> debit: {(weight_totals.debit_18k or 0):.3f}, credit: {(weight_totals.credit_18k or 0):.3f}, diff: {((weight_totals.debit_18k or 0) - (weight_totals.credit_18k or 0)):.3f}",
            f"   21k -> debit: {(weight_totals.debit_21k or 0):.3f}, credit: {(weight_totals.credit_21k or 0):.3f}, diff: {((weight_totals.debit_21k or 0) - (weight_totals.credit_21k or 0)):.3f}",
            f"   22k -> debit: {(weight_totals.debit_22k or 0):.3f}, credit: {(weight_totals.credit_22k or 0):.3f}, diff: {((weight_totals.debit_22k or 0) - (weight_totals.credit_22k or 0)):.3f}",
            f"   24k -> debit: {(weight_totals.debit_24k or 0):.3f}, credit: {(weight_totals.credit_24k or 0):.3f}, diff: {((weight_totals.debit_24k or 0) - (weight_totals.credit_24k or 0)):.3f}"
        ]
        for line in log_lines:
            print(line)
        with open('/tmp/dual_balance.log', 'a', encoding='utf-8') as dbg:
            dbg.write('\n'.join(log_lines) + '\n')

            # Log detailed lines to help trace imbalance sources
            from models import JournalEntryLine, Account
            lines = db.session.query(JournalEntryLine).filter_by(journal_entry_id=journal_entry_id).all()
            for line in lines:
                acc = line.account or db.session.query(Account).get(line.account_id)
                acc_label = f"{acc.account_number} - {acc.name}" if acc else f"Account {line.account_id}"
                detail = (
                    f"      -> {acc_label}: cash({line.cash_debit:.2f}/{line.cash_credit:.2f}) "
                    f"weights 18k({line.debit_18k:.3f}/{line.credit_18k:.3f}) "
                    f"21k({line.debit_21k:.3f}/{line.credit_21k:.3f}) "
                    f"22k({line.debit_22k:.3f}/{line.credit_22k:.3f}) "
                    f"24k({line.debit_24k:.3f}/{line.credit_24k:.3f})"
                )
                print(detail)
                dbg.write(detail + '\n')
    except Exception as log_exc:
        with open('/tmp/dual_balance.log', 'a', encoding='utf-8') as dbg:
            dbg.write(f"⚠️ Failed to log dual balance details: {log_exc}\n")
    
    errors = []
    balanced = True
    
    if abs(cash_balance) > 0.01:
        balanced = False
        errors.append(f'Cash imbalance: {cash_balance}')
    
    for karat, balance in weight_balances.items():
        if abs(balance) > 0.01:  # Increased tolerance from 0.001 to 0.01 grams
            balanced = False
            errors.append(f'Weight imbalance ({karat}): {balance}')
    
    return {
        'balanced': balanced,
        'cash_balance': cash_balance,
        'weight_balances': weight_balances,
        'errors': errors
    }


def get_account_balances(account_id):
    """
    Get account balances (cash + weight).
    Must be called from routes.py where db is already in context.
    """
    from flask import current_app
    from models import Account
    
    db = current_app.extensions['sqlalchemy']
    
    account = db.session.query(Account).filter_by(id=account_id).first()
    if not account:
        raise ValueError(f'Account {account_id} not found')
    
    result = {
        'cash': round(account.balance_cash, 2)
    }
    
    if account.tracks_weight:
        result['weight'] = {
            '18k': round(account.balance_18k, 3),
            '21k': round(account.balance_21k, 3),
            '22k': round(account.balance_22k, 3),
            '24k': round(account.balance_24k, 3),
            'total': round(account.get_total_weight(), 3)
        }
    
    return result


def get_live_gold_price_helper():
    """
    الحصول على السعر المباشر للذهب (للجرام الواحد بالعيار الرئيسي الديناميكي)
    
    ملاحظة هامة:
    يستخدم سعر العيار الرئيسي (21 عادةً) وليس 24k
    هذا يضمن التوافق مع نظام المحاسبة الوزني
    """
    try:
        # محاولة الحصول على السعر من API الذهب
        from pricing.gold_price_service import get_current_gold_price
        price_data = get_current_gold_price()
        # 🔧 تم التصليح: استخدام سعر العيار الرئيسي بدلاً من 24k
        return price_data.get('price_per_gram_main_karat', 350.0)
    except:
        # قيمة افتراضية في حالة الفشل (سعر 21k تقريباً)
        return 350.0


def create_dual_entry_with_memo(
    date,
    description,
    entries,
    reference_type=None,
    reference_id=None,
    gold_price=None,
    posted=True
):
    """
    إنشاء قيد مزدوج (نقد + وزن) مع تسجيل تلقائي في حسابات المذكرة
    
    Args:
        date: تاريخ القيد
        description: وصف القيد
        entries: قائمة من القيود، كل قيد يحتوي على:
            {
                'account_id': رقم الحساب,
                'debit_cash': المبلغ المدين (اختياري),
                'credit_cash': المبلغ الدائن (اختياري),
                'debit_weight': الوزن المدين (اختياري - يُحسب تلقائياً إن لم يُحدد),
                'credit_weight': الوزن الدائن (اختياري),
                'customer_id': العميل (اختياري),
                'supplier_id': المورد (اختياري),
                'description': وصف السطر (اختياري)
            }
        reference_type: نوع المرجع
        reference_id: رقم المرجع
        gold_price: السعر المباشر للذهب (إذا لم يُحدد يتم جلبه تلقائياً)
        posted: هل القيد مُرحّل؟
    
    Returns:
        JournalEntry: القيد المنشأ
    """
    from flask import current_app
    from models import JournalEntry, JournalEntryLine, Account
    from datetime import datetime
    
    db = current_app.extensions['sqlalchemy']
    
    # الحصول على السعر المباشر للذهب
    if gold_price is None:
        gold_price = get_live_gold_price_helper()
    
    # إنشاء القيد الرئيسي
    from accounting.reference_number_service import generate_journal_entry_number
    entry_number = generate_journal_entry_number('JE')
    
    journal_entry = JournalEntry(
        entry_number=entry_number,
        date=date,
        description=description,
        reference_type=reference_type,
        reference_id=reference_id,
        is_posted=posted,
        posted_at=datetime.now() if posted else None,
        posted_by='system' if posted else None
    )
    db.session.add(journal_entry)
    db.session.flush()
    
    # معالجة كل قيد في القائمة
    for entry in entries:
        account_id = entry.get('account_id')
        account_code = entry.get('account_code')
        
        # الحصول على الحساب
        if account_id:
            account = db.session.query(Account).get(account_id)
        elif account_code:
            account = db.session.query(Account).filter_by(account_number=account_code).first()
        else:
            continue
        
        if not account:
            continue
        
        account_id = account.id
        
        # القيد المالي (النقدي) - دعم كلا الصيغتين
        debit_cash = entry.get('debit_cash') or entry.get('debit', 0.0) or 0.0
        credit_cash = entry.get('credit_cash') or entry.get('credit', 0.0) or 0.0
        
        # القيد الوزني (إذا كان مُحدداً مباشرة) - فقط لحسابات المخزون/المبيعات
        debit_weight = entry.get('debit_weight', 0.0) or 0.0
        credit_weight = entry.get('credit_weight', 0.0) or 0.0
        
        # حساب الوزن المعادل لحسابات المذكرة
        memo_debit_weight = debit_weight if debit_weight > 0 else (debit_cash / gold_price if debit_cash > 0 else 0.0)
        memo_credit_weight = credit_weight if credit_weight > 0 else (credit_cash / gold_price if credit_cash > 0 else 0.0)
        
        # إنشاء سطر القيد المالي (نقد فقط - بدون أوزان)
        line = JournalEntryLine(
            journal_entry_id=journal_entry.id,
            account_id=account_id,
            customer_id=entry.get('customer_id'),
            supplier_id=entry.get('supplier_id'),
            cash_debit=debit_cash,
            cash_credit=credit_cash,
            debit_weight=0.0,  # الحسابات المالية لا تحمل أوزان
            credit_weight=0.0,
            gold_price_snapshot=gold_price,
            description=entry.get('description', description)
        )
        db.session.add(line)
        
        # إذا كان للحساب حساب مذكرة موازي، نُنشئ قيداً وزنياً (أوزان فقط)
        if account.memo_account_id:
            memo_line = JournalEntryLine(
                journal_entry_id=journal_entry.id,
                account_id=account.memo_account_id,
                customer_id=entry.get('customer_id'),
                supplier_id=entry.get('supplier_id'),
                cash_debit=0.0,  # حسابات المذكرة لا تحمل نقد
                cash_credit=0.0,
                debit_weight=memo_debit_weight,  # الوزن الفعلي أو المعادل
                credit_weight=memo_credit_weight,
                gold_price_snapshot=gold_price,
                description=f"{entry.get('description', description)} (وزن معادل)"
            )
            db.session.add(memo_line)
    
    db.session.flush()
    return journal_entry


def link_memo_accounts_helper():
    """
        ربط الحسابات المالية بحسابات المذكرة الموازية.

        IMPORTANT:
        There are two supported linking strategies:
        1) Explicit mappings from WEIGHT_SUPPORT_ACCOUNTS (authoritative for special accounts).
        2) Generic fallback mapping: memo_number = '7' + financial.account_number.

        This helper is intentionally conservative:
        - It will only *link* accounts when both sides already exist.
        - It will not create new accounts.
        - It will not overwrite an already-correct explicit support mapping.
    """
    from flask import current_app
    from models import Account
    from account_pair_service import link_accounts

    db = current_app.extensions['sqlalchemy']

    def digits_only(value: str) -> str:
        return ''.join(ch for ch in str(value or '').strip() if ch.isdigit())

    def desired_memo_number(financial_number: str):
        digits = digits_only(financial_number)
        if not digits:
            return None
        return f"7{digits}"

    count = 0
    changed = False

    # 1) Apply explicit support mappings first.
    explicit_fin_to_memo: dict[str, str] = {}
    try:
        for entry in WEIGHT_SUPPORT_ACCOUNTS:
            fin = digits_only((entry.get('financial') or {}).get('account_number'))
            memo = digits_only((entry.get('memo') or {}).get('account_number'))
            if fin and memo:
                explicit_fin_to_memo[fin] = memo
    except Exception:
        explicit_fin_to_memo = {}

    for fin_no, memo_no in sorted(explicit_fin_to_memo.items()):
        financial_acc = db.session.query(Account).filter_by(account_number=fin_no).first()
        memo_acc = db.session.query(Account).filter_by(account_number=memo_no).first()
        if not financial_acc or not memo_acc:
            continue
        if memo_acc.transaction_type != 'gold' or not bool(memo_acc.tracks_weight):
            continue
        # عملية link/relink صريحة (الفحصان كانا منفصلين سابقاً، فيمكن أن
        # يُصلَح اتجاه واحد فقط ويبقى الآخر معطوباً -- بالضبط نمط
        # one_way_link الذي اكتُشف مراراً على الإنتاج). عبر الخدمة المركزية فقط.
        if financial_acc.memo_account_id != memo_acc.id or memo_acc.memo_account_id != financial_acc.id:
            link_accounts(financial_acc, memo_acc, created_by='link_memo_accounts_helper_explicit')
            changed = True
            count += 1

    # 2) Generic fallback for any other already-linked financial accounts (repair common mislinks).
    candidates: set[str] = set()
    try:
        linked = db.session.query(Account).filter(Account.memo_account_id.isnot(None)).all()
        for acc in linked:
            if acc and acc.account_number:
                fin_no = digits_only(acc.account_number)
                if fin_no and not fin_no.startswith('7') and fin_no not in explicit_fin_to_memo:
                    candidates.add(fin_no)
    except Exception:
        candidates = set()

    for fin_no in sorted(candidates):
        financial_acc = db.session.query(Account).filter_by(account_number=fin_no).first()
        if not financial_acc:
            continue

        memo_no = desired_memo_number(fin_no)
        if not memo_no:
            continue

        memo_acc = db.session.query(Account).filter_by(account_number=memo_no).first()
        if not memo_acc:
            continue

        if memo_acc.transaction_type != 'gold' or not bool(memo_acc.tracks_weight):
            continue

        # نفس منطق link/relink أعلاه -- عبر الخدمة المركزية فقط.
        if financial_acc.memo_account_id != memo_acc.id or memo_acc.memo_account_id != financial_acc.id:
            link_accounts(financial_acc, memo_acc, created_by='link_memo_accounts_helper_fallback')
            changed = True
            count += 1

    if changed:
        db.session.commit()

    print(f"✓ تم ربط {count} حساب مالي بحسابات المذكرة")
    return count


def create_golden_rule_entry(
    journal_entry_id,
    account_id,
    debit_cash=0.0,
    credit_cash=0.0,
    gold_price=None,
    is_inventory=False,
    actual_weight_18k=0.0,
    actual_weight_21k=0.0,
    actual_weight_22k=0.0,
    actual_weight_24k=0.0,
    description=None,
    customer_id=None,
    supplier_id=None
):
    """
    🟡 القاعدة الذهبية للنظام المزدوج
    
    قاعدة عامة: أي ريال يدخل أو يخرج → يتحول إلى جرام في دفتر الوزن
    الاستثناء الوحيد: المخزون يُسجل بالوزن الفعلي (بدون تحويل)
    
    Args:
        journal_entry_id: رقم القيد
        account_id: رقم الحساب المالي
        debit_cash: المبلغ المدين (ريال)
        credit_cash: المبلغ الدائن (ريال)
        gold_price: السعر المباشر للذهب عيار 24 (ريال/جرام)
        is_inventory: هل هذا حساب مخزون؟ (استثناء من التحويل)
        actual_weight_XXk: الوزن الفعلي لكل عيار (فقط للمخزون)
        description: وصف القيد
        customer_id: معرف العميل
        supplier_id: معرف المورد
    
    Returns:
        tuple: (financial_line, memo_line)
    """
    from flask import current_app
    from models import Account, JournalEntryLine
    
    db = current_app.extensions['sqlalchemy']
    
    # الحصول على الحساب المالي
    account = db.session.query(Account).get(account_id)
    if not account:
        raise ValueError(f"Account {account_id} not found")
    
    # الحصول على السعر المباشر للذهب
    if gold_price is None:
        gold_price = get_live_gold_price_helper()
    
    # ============================================
    # 1️⃣ القيد المالي (نقد فقط - بدون أوزان)
    # ============================================
    financial_line = JournalEntryLine(
        journal_entry_id=journal_entry_id,
        account_id=account_id,
        customer_id=customer_id,
        supplier_id=supplier_id,
        cash_debit=round(debit_cash, 2) if debit_cash > 0 else 0.0,
        cash_credit=round(credit_cash, 2) if credit_cash > 0 else 0.0,
        debit_weight=0.0,  # ✅ الحسابات المالية لا تحمل أوزان
        credit_weight=0.0,
        debit_18k=0.0,
        credit_18k=0.0,
        debit_21k=0.0,
        credit_21k=0.0,
        debit_22k=0.0,
        credit_22k=0.0,
        debit_24k=0.0,
        credit_24k=0.0,
        gold_price_snapshot=gold_price
    )
    db.session.add(financial_line)
    
    # ============================================
    # 2️⃣ القيد الوزني (وزن فقط - بدون نقد)
    # ============================================
    memo_line = None
    
    # تحقق من وجود حساب مذكرة موازٍ
    if account.memo_account_id:
        memo_account = db.session.query(Account).get(account.memo_account_id)
        
        if memo_account:
            # حساب الأوزان حسب نوع الحساب
            if is_inventory:
                # ✅ استثناء: المخزون يُسجل بالوزن الفعلي (بدون تحويل)
                weight_18k_debit = actual_weight_18k if debit_cash > 0 else 0.0
                weight_18k_credit = actual_weight_18k if credit_cash > 0 else 0.0
                weight_21k_debit = actual_weight_21k if debit_cash > 0 else 0.0
                weight_21k_credit = actual_weight_21k if credit_cash > 0 else 0.0
                weight_22k_debit = actual_weight_22k if debit_cash > 0 else 0.0
                weight_22k_credit = actual_weight_22k if credit_cash > 0 else 0.0
                weight_24k_debit = actual_weight_24k if debit_cash > 0 else 0.0
                weight_24k_credit = actual_weight_24k if credit_cash > 0 else 0.0
            else:
                # ✅ القاعدة العامة: تحويل الريال إلى جرام
                # الوزن = المبلغ ÷ السعر المباشر
                weight_equivalent_debit = (debit_cash / gold_price) if gold_price > 0 and debit_cash > 0 else 0.0
                weight_equivalent_credit = (credit_cash / gold_price) if gold_price > 0 and credit_cash > 0 else 0.0
                
                # افتراضياً نسجل في عيار 21 (العيار الرئيسي)
                weight_18k_debit = 0.0
                weight_18k_credit = 0.0
                weight_21k_debit = weight_equivalent_debit
                weight_21k_credit = weight_equivalent_credit
                weight_22k_debit = 0.0
                weight_22k_credit = 0.0
                weight_24k_debit = 0.0
                weight_24k_credit = 0.0
            
            # إنشاء سطر القيد الوزني
            memo_line = JournalEntryLine(
                journal_entry_id=journal_entry_id,
                account_id=memo_account.id,
                customer_id=customer_id,
                supplier_id=supplier_id,
                cash_debit=0.0,  # ✅ حسابات المذكرة لا تحمل نقد
                cash_credit=0.0,
                debit_18k=round(weight_18k_debit, 3) if weight_18k_debit > 0 else 0.0,
                credit_18k=round(weight_18k_credit, 3) if weight_18k_credit > 0 else 0.0,
                debit_21k=round(weight_21k_debit, 3) if weight_21k_debit > 0 else 0.0,
                credit_21k=round(weight_21k_credit, 3) if weight_21k_credit > 0 else 0.0,
                debit_22k=round(weight_22k_debit, 3) if weight_22k_debit > 0 else 0.0,
                credit_22k=round(weight_22k_credit, 3) if weight_22k_credit > 0 else 0.0,
                debit_24k=round(weight_24k_debit, 3) if weight_24k_debit > 0 else 0.0,
                credit_24k=round(weight_24k_credit, 3) if weight_24k_credit > 0 else 0.0,
                debit_weight=0.0,  # سنستخدم الأوزان حسب العيار مباشرة
                credit_weight=0.0,
                gold_price_snapshot=gold_price
            )
            db.session.add(memo_line)
    
    return (financial_line, memo_line)


def create_complete_golden_entry(
    date,
    description,
    entries,
    gold_price=None,
    reference_type=None,
    reference_id=None,
    posted=True
):
    """
    🟡 إنشاء قيد كامل وفق القاعدة الذهبية
    
    القاعدة: كل ريال → يتحول لجرام، المخزون فقط بالوزن الفعلي
    
    Args:
        date: تاريخ القيد
        description: وصف القيد
        entries: قائمة القيود، كل عنصر:
            {
                'account_id': رقم الحساب,
                'debit': مدين نقدي (اختياري),
                'credit': دائن نقدي (اختياري),
                'is_inventory': هل حساب مخزون؟ (افتراضي False),
                'weight_18k': الوزن الفعلي عيار 18 (للمخزون فقط),
                'weight_21k': الوزن الفعلي عيار 21 (للمخزون فقط),
                'weight_22k': الوزن الفعلي عيار 22 (للمخزون فقط),
                'weight_24k': الوزن الفعلي عيار 24 (للمخزون فقط),
                'customer_id': معرف العميل (اختياري),
                'supplier_id': معرف المورد (اختياري),
                'description': وصف السطر (اختياري)
            }
        gold_price: السعر المباشر للذهب (إذا لم يُحدد يُجلب تلقائياً)
        reference_type: نوع المرجع (invoice, voucher, etc.)
        reference_id: رقم المرجع
        posted: هل القيد مُرحّل؟
    
    Returns:
        JournalEntry: القيد المُنشأ
    """
    from flask import current_app
    from models import JournalEntry
    from datetime import datetime
    
    db = current_app.extensions['sqlalchemy']
    
    # الحصول على السعر المباشر للذهب
    if gold_price is None:
        gold_price = get_live_gold_price_helper()
    
    # إنشاء القيد الرئيسي
    from accounting.reference_number_service import generate_journal_entry_number
    entry_number = generate_journal_entry_number('JE')
    
    journal_entry = JournalEntry(
        entry_number=entry_number,
        date=date,
        description=description,
        reference_type=reference_type,
        reference_id=reference_id,
        is_posted=posted,
        posted_at=datetime.now() if posted else None,
        posted_by='system' if posted else None
    )
    db.session.add(journal_entry)
    db.session.flush()
    
    # معالجة كل قيد في القائمة
    for entry in entries:
        account_id = entry.get('account_id')
        if not account_id:
            continue
        
        debit_cash = entry.get('debit', 0.0) or 0.0
        credit_cash = entry.get('credit', 0.0) or 0.0
        is_inventory = entry.get('is_inventory', False)
        
        # الأوزان الفعلية (فقط للمخزون)
        actual_weight_18k = entry.get('weight_18k', 0.0) or 0.0
        actual_weight_21k = entry.get('weight_21k', 0.0) or 0.0
        actual_weight_22k = entry.get('weight_22k', 0.0) or 0.0
        actual_weight_24k = entry.get('weight_24k', 0.0) or 0.0
        
        # إنشاء القيد وفق القاعدة الذهبية
        create_golden_rule_entry(
            journal_entry_id=journal_entry.id,
            account_id=account_id,
            debit_cash=debit_cash,
            credit_cash=credit_cash,
            gold_price=gold_price,
            is_inventory=is_inventory,
            actual_weight_18k=actual_weight_18k,
            actual_weight_21k=actual_weight_21k,
            actual_weight_22k=actual_weight_22k,
            actual_weight_24k=actual_weight_24k,
            description=entry.get('description', description),
            customer_id=entry.get('customer_id'),
            supplier_id=entry.get('supplier_id')
        )
    
    # 🆕 Verify balance after creating all lines (Fail Fast)
    db.session.flush()
    is_balanced, balance_details = verify_dual_balance(journal_entry.id, raise_on_error=False)
    
    if not is_balanced:
        error_msg = f"Journal entry {journal_entry.id} is not balanced after applying golden rule"
        print(f"❌ {error_msg}")
        print(f"Balance details: {balance_details}")
        # Log to file for debugging
        with open('/tmp/dual_balance.log', 'a', encoding='utf-8') as f:
            f.write(f"❌ JE#{journal_entry.id} IMBALANCED after golden rule batch\\n")
            f.write(f"Details: {balance_details}\\n")
        
        # 🆕 Raise error to prevent saving imbalanced entries
        from services.weight_ledger_service import WeightImbalanceError
        raise WeightImbalanceError(error_msg)
    
    db.session.flush()
    return journal_entry


def apply_golden_rule_to_line(line_data, gold_price_main_karat, apply_rule=True):
    """
    🆕 تطبيق القاعدة الذهبية على سطر قيد يدوي
    
    Args:
        line_data (dict): بيانات السطر من الطلب (account_id, cash_debit, cash_credit, etc.)
        gold_price_main_karat (float): سعر الذهب للعيار الرئيسي (افتراضي 21 قيراط)
        apply_rule (bool): تطبيق القاعدة أم لا (افتراضي True)
    
    Returns:
        dict: السطر مع القيم الوزنية المحسوبة
    
    ملاحظة:
        - إذا كان apply_rule=False، يعيد السطر كما هو
        - إذا كان apply_rule=True ولا توجد قيم نقدية، يعيد السطر كما هو
        - القاعدة: الوزن = المبلغ النقدي ÷ سعر الذهب للعيار الرئيسي
    """
    if not apply_rule:
        return line_data
    
    # نسخ البيانات
    result = line_data.copy()
    
    # التحقق من وجود قيم نقدية
    cash_debit = float(line_data.get('cash_debit', 0))
    cash_credit = float(line_data.get('cash_credit', 0))
    
    if cash_debit == 0 and cash_credit == 0:
        # لا توجد قيم نقدية، لا حاجة لتطبيق القاعدة
        return result
    
    if gold_price_main_karat <= 0:
        # سعر غير صحيح، لا يمكن تطبيق القاعدة
        return result
    
def apply_golden_rule_to_line(line_data, gold_price_main_karat, main_karat=21, apply_rule=True):
    """
    🆕 تطبيق القاعدة الذهبية على سطر قيد يدوي
    
    Args:
        line_data (dict): بيانات السطر من الطلب (account_id, cash_debit, cash_credit, etc.)
        gold_price_main_karat (float): سعر الذهب للعيار الرئيسي
        main_karat (int): العيار الرئيسي (افتراضي 21، لكنه قابل للتغيير)
        apply_rule (bool): تطبيق القاعدة أم لا (افتراضي True)
    
    Returns:
        dict: السطر مع القيم الوزنية المحسوبة
    
    ملاحظة:
        - إذا كان apply_rule=False، يعيد السطر كما هو
        - إذا كان apply_rule=True ولا توجد قيم نقدية، يعيد السطر كما هو
        - القاعدة: الوزن = المبلغ النقدي ÷ سعر الذهب للعيار الرئيسي
        - يُسجل الوزن في حقل العيار الرئيسي (debit_XXk / credit_XXk)
    """
    if not apply_rule:
        return line_data
    
    # نسخ البيانات
    result = line_data.copy()
    
    # التحقق من وجود قيم نقدية
    cash_debit = float(line_data.get('cash_debit', 0))
    cash_credit = float(line_data.get('cash_credit', 0))
    
    if cash_debit == 0 and cash_credit == 0:
        # لا توجد قيم نقدية، لا حاجة لتطبيق القاعدة
        return result
    
    if gold_price_main_karat <= 0:
        # سعر غير صحيح، لا يمكن تطبيق القاعدة
        return result
    
    # تحديد حقل العيار المناسب
    karat_field_debit = f'debit_{main_karat}k'
    karat_field_credit = f'credit_{main_karat}k'
    
    # تطبيق القاعدة الذهبية
    # الوزن = المبلغ ÷ سعر العيار الرئيسي
    if cash_debit > 0:
        weight_debit = cash_debit / gold_price_main_karat
        result[karat_field_debit] = round(weight_debit, 3)
    
    if cash_credit > 0:
        weight_credit = cash_credit / gold_price_main_karat
        result[karat_field_credit] = round(weight_credit, 3)
    
    return result

