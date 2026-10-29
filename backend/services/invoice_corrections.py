"""A posted invoice's line corrected, by the difference (ت-1; the owner, 22 Oct 2026).

Eleven of 2026's twenty-one returns were not returns: a karat, a weight or a
price entered wrong, put right by returning the whole invoice and entering it
again -- 3314's 1.5 g of 18k took four documents. The owner chose one
document instead (docs/plans/invoice-correction-study.md):

  - the line is corrected IN PLACE: the invoice says what happened, so every
    report that reads invoice lines shows it;
  - the difference is ONE posted entry dated the day of the correction -- the
    old line's gold out of the safe it is in now, the new lines' in; their
    price's difference on the customer's account -- so the books of the past
    are not rewritten;
  - the record (InvoiceCorrection) keeps what was and what is, why, who, when;
  - the invoice's profit stays as it was paid: its points move in the
    correction's period (ت-2).

It corrects a customer's scrap purchase and a sale -- its VAT at its own
invoice's rate, its wage released with the weight sold, from the gold-cost
day its gold's cost. A supplier's invoice comes after; refused by name.
"""
from __future__ import annotations

from models import (Account, Customer, Invoice, InvoiceCorrection, InvoiceItem, JournalEntry, JournalEntryLine,
                    SafeBox, db)

SALE = 'بيع'
CORRECTABLE = ('شراء من عميل', SALE)
KARATS = (18, 21, 22, 24)
GRAM = 0.0005
CENT = 0.005


class CorrectionRefused(ValueError):
    def __init__(self, code: str, message: str, **extra):
        super().__init__(message)
        self.code, self.message, self.extra = code, message, extra


def _f(value, default=0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _line_of(item: InvoiceItem) -> dict:
    return {'id': item.id, 'name': item.name, 'karat': int(round(_f(item.karat))), 'weight': round(_f(item.weight), 3),
            'standing_weight': round(_f(item.standing_weight), 3), 'stones_weight': round(_f(item.stones_weight), 3),
            'price': round(_f(item.net if item.net is not None else item.price), 2),
            'category_id': item.category_id}


def _invoice_of(invoice: Invoice) -> dict:
    return {'total': round(_f(invoice.total), 2), 'total_weight': round(_f(invoice.total_weight), 3),
            'net_amount': round(_f(invoice.net_amount), 2), 'total_cost': round(_f(invoice.total_cost), 2),
            'profit_cash': _f(invoice.profit_cash), 'profit_gold': _f(invoice.profit_gold)}


def _category_for(old: InvoiceItem, karat: int):
    """A new line's category when none is sent: the old line's in its karat;
    in another karat, a scrap line takes that karat's scrap category (3434 on
    the 21 Oct copy: «كسر 21» corrected to 18k is «كسر 18»); otherwise none."""
    from models import Category
    if karat == int(round(_f(old.karat))):
        return old.category_id
    category = db.session.get(Category, old.category_id) if old.category_id else None
    if category is not None and category.is_scrap:
        scrap = (Category.query.filter_by(is_scrap=True, karat=str(karat))
                 .filter(Category.is_active.isnot(False)).order_by(Category.id).first())
        return scrap.id if scrap else None
    return None


def _new_lines(raw, old: InvoiceItem) -> list[dict]:
    from models import Category
    if not isinstance(raw, list) or not raw:
        raise CorrectionRefused('correction_lines_required', 'اكتب السطر الصحيح: عياره ووزنه وسعره')
    lines = []
    for n, line in enumerate(raw, start=1):
        if not isinstance(line, dict):
            raise CorrectionRefused('correction_lines_required', f'السطر {n} غير مفهوم')
        karat = int(round(_f(line.get('karat'))))
        if karat not in KARATS:
            raise CorrectionRefused('correction_karat_invalid', f'السطر {n}: العيار 18 أو 21 أو 22 أو 24')
        weight, price = round(_f(line.get('weight')), 3), round(_f(line.get('price'), -1.0), 2)
        if weight <= GRAM:
            raise CorrectionRefused('correction_weight_invalid', f'السطر {n}: الوزن أكبر من صفر')
        if price < 0:
            raise CorrectionRefused('correction_price_invalid', f'السطر {n}: السعر صفر أو أكثر')
        category_id = line.get('category_id', _category_for(old, karat))
        if category_id:
            category = db.session.get(Category, int(category_id))
            if category is None or (category.karat and int(round(_f(category.karat))) != karat):
                raise CorrectionRefused('correction_category_invalid', f'السطر {n}: تصنيف عيار {karat}')
        lines.append({'name': (line.get('name') or old.name), 'karat': karat, 'weight': weight, 'price': price,
                      'category_id': int(category_id) if category_id else None})
    return lines


def _main(lines) -> float:
    from pricing.gold_price_service import get_main_karat
    main = float(get_main_karat())
    return sum(_f(l['weight']) * _f(l['karat']) / main for l in lines)


def _profits(invoice: Invoice, old_line: dict, new_lines: list, cash_delta: float) -> tuple[dict, dict]:
    """The purchase's profit as paid, and as it is right (ت-2). A customer's
    purchase earns the grams it bought over what its riyals buy at the price of
    its day: profit = main grams - riyals / price. That price is not kept; it
    is the paid profit's (riyals / (main grams - profit)) -- a loss's too, kept
    below nothing (POINTS-DEFICIT-1). A purchase that earned nothing tells no
    price: its right profit is nothing too."""
    paid = {'profit_gold': round(_f(invoice.profit_gold), 3), 'profit_cash': round(_f(invoice.profit_cash), 2)}
    lines = [_line_of(i) for i in InvoiceItem.query.filter_by(invoice_id=invoice.id).all()]
    grams = _main(lines)
    grams_right = grams - _main([old_line]) + _main(new_lines)
    cash = _f(invoice.total)
    price = (cash / (grams - paid['profit_gold'])
             if abs(paid['profit_gold']) > GRAM and grams - paid['profit_gold'] > GRAM else None)
    right = grams_right - (cash + cash_delta) / price if price else 0.0
    # Its cash profit moves with its grams, at the same price (its gold at the buy
    # price less what was paid, the owner 29 Oct 2026).
    right_cash = paid['profit_cash'] + (right - paid['profit_gold']) * price if price else paid['profit_cash']
    return paid, {'profit_gold': round(right, 3), 'profit_cash': round(right_cash, 2)}


def _sale_profits(invoice: Invoice, old_line: dict, new_lines: list, net_delta: float) -> tuple[dict, dict, float]:
    """A sale's profit as paid, and as it is right, and its cost's difference
    (ت-2). A sale earns its riyals less its cost (and its payment fees): the
    cost a main-karat gram is the invoice's own (its total cost over its main
    grams), so the gold's difference costs at it; the profit in grams is the
    riyals' at the price of its day, kept on the invoice."""
    paid = {'profit_gold': round(_f(invoice.profit_gold), 3), 'profit_cash': round(_f(invoice.profit_cash), 2)}
    grams = _main([_line_of(i) for i in InvoiceItem.query.filter_by(invoice_id=invoice.id).all()])
    per_gram = _f(invoice.total_cost) / grams if grams > GRAM else 0.0
    cost_delta = round(per_gram * (_main(new_lines) - _main([old_line])), 2)
    right_cash = round(paid['profit_cash'] + net_delta - cost_delta, 2)
    price = _f(invoice.profit_weight_price_per_gram)
    right_gold = round(right_cash / price, 3) if price > 0 else paid['profit_gold']
    return paid, {'profit_gold': right_gold, 'profit_cash': right_cash}, cost_delta


def _grams(karat_weights: dict) -> dict:
    return {k: round(w, 6) for k, w in karat_weights.items() if abs(w) > GRAM}


def correct_line(invoice: Invoice, *, line_id, lines, safe_box_id, reason: str, by: str, now) -> InvoiceCorrection:
    """Correct one line of a posted invoice -- or CorrectionRefused. Runs in the
    caller's transaction (the preview rolls it back)."""
    from accounting.mappings import get_account_id_for_mapping, require_account
    from accounting.safe_boxes import _rebuild_safe_box_transactions_for_journal_entry
    from accounting.voucher_engine import _generate_journal_entry_number
    from dual_system_helpers import create_dual_journal_entry, verify_dual_balance
    from services.live_balances import safe_gold_available

    reason = (reason or '').strip()
    if not reason:
        raise CorrectionRefused('correction_reason_required', 'سبب التصحيح مطلوب')
    if invoice is None:
        raise CorrectionRefused('invoice_not_found', 'الفاتورة غير موجودة')
    if not invoice.is_posted:
        raise CorrectionRefused('invoice_not_posted', 'الفاتورة غير مرحّلة: تُعدَّل بدل أن تُصحَّح')
    if (invoice.invoice_type or '').strip() not in CORRECTABLE:
        raise CorrectionRefused('correction_not_built_for_type',
                                f'تصحيح «{invoice.invoice_type}» لم يُبنَ بعد — يُصحَّح بمرتجع وإعادة إدخال')
    if Invoice.query.filter(Invoice.original_invoice_id == invoice.id, Invoice.is_posted.is_(True)).first():
        raise CorrectionRefused('correction_after_return_not_built',
                                'للفاتورة مرتجع: تصحيح فاتورة أُرجع منها شيء لم يُبنَ بعد')
    from models import InvoiceKaratLine
    if InvoiceKaratLine.query.filter_by(invoice_id=invoice.id).first():
        raise CorrectionRefused('correction_karat_lines_not_built',
                                'فاتورة بأسطر عيار (لا أصناف): تصحيحها لم يُبنَ بعد')
    old = db.session.get(InvoiceItem, int(line_id)) if line_id else None
    if old is None or old.invoice_id != invoice.id:
        raise CorrectionRefused('correction_line_not_found', 'السطر ليس من هذه الفاتورة')
    if _f(old.stones_weight) > GRAM:
        raise CorrectionRefused('correction_stones_not_built', 'تصحيح سطر فيه فصوص لم يُبنَ بعد')
    new = _new_lines(lines, old)
    safe = db.session.get(SafeBox, int(safe_box_id)) if safe_box_id else None
    if safe is None or (safe.safe_type or '').lower() != 'gold' or not safe.stock_location:
        raise CorrectionRefused('correction_safe_invalid', 'اختر خزينة الذهب التي فيها ذهب السطر الآن')

    before_line = _line_of(old)
    sale = (invoice.invoice_type or '').strip() == SALE
    if sale:
        # A sale's VAT at its own invoice's rate (the owner, 22 Oct 2026: the
        # correction puts that invoice right); the price is the line's net.
        rate = _f(old.tax) / before_line['price'] if before_line['price'] > CENT and _f(old.tax) > CENT else 0.0
        for l in new:
            l['tax'] = round(l['price'] * rate, 2)
        before_line['tax'] = round(_f(old.tax), 2)
    else:
        for l in new:
            l['tax'] = 0.0
        before_line['tax'] = 0.0
    net_delta = round(sum(l['price'] for l in new) - before_line['price'], 2)
    tax_delta = round(sum(l['tax'] for l in new) - before_line['tax'], 2)
    cash_delta = round(net_delta + tax_delta, 2)
    if not sale and abs(cash_delta) > CENT and _f(old.tax) > CENT:
        raise CorrectionRefused('correction_vat_not_built', 'تصحيح سعر سطر عليه ضريبة لم يُبنَ بعد')
    if sale:
        from models import Category
        old_category = db.session.get(Category, old.category_id) if old.category_id else None
        for l in new:
            if l['karat'] != before_line['karat'] and not l['category_id'] and old_category is not None:
                raise CorrectionRefused('correction_category_required',
                                        f'اختر تصنيف عيار {l["karat"]} للسطر الصحيح')

    # The gold that leaves the safe, per karat, net: the safe holds it. A
    # purchase's old line leaves and its right lines enter; a sale's old line
    # comes back and its right lines leave.
    sign = -1.0 if sale else 1.0
    delta = {k: 0.0 for k in KARATS}
    delta[before_line['karat']] -= sign * before_line['weight']
    for l in new:
        delta[l['karat']] += sign * l['weight']
    for karat, grams in _grams(delta).items():
        if grams < 0 and -grams > safe_gold_available(safe, karat) + 1e-6:
            raise CorrectionRefused('insufficient_balance',
                                    f'«{safe.name}» لا تحمل {-grams:.3f} غ عيار {karat}: أين ذهب السطر الآن؟',
                                    karat=karat, available=round(safe_gold_available(safe, karat), 3))

    customer = db.session.get(Customer, invoice.customer_id) if invoice.customer_id else None
    party = getattr(customer, 'account_id', None)
    if (sale or abs(cash_delta) > CENT) and not party:
        raise CorrectionRefused('correction_party_missing', 'لا حساب للعميل يُقيَّد عليه الفرق')

    profit_before, profit_after, cost_delta = (_sale_profits(invoice, before_line, new, net_delta) if sale
                                               else (*_profits(invoice, before_line, new, cash_delta), cash_delta))
    correction = InvoiceCorrection(invoice_id=invoice.id, invoice_item_id=old.id, safe_box_id=safe.id, reason=reason,
                                   before={'snapshot_schema_version': 1, 'lines': [before_line],
                                           'invoice': _invoice_of(invoice), 'profit': profit_before},
                                   after={}, cash_delta=cash_delta, created_by=by, created_at=now)
    db.session.add(correction)
    db.session.flush()

    entry = JournalEntry(entry_number=_generate_journal_entry_number('COR', now), date=now,
                         description=f'تصحيح فاتورة #{invoice.id}: {reason}'[:250], entry_type='عادي',
                         reference_type='invoice_correction', reference_id=correction.id,
                         is_posted=True, is_draft=False, posted_at=now, posted_by=by, created_by=by)
    db.session.add(entry)
    db.session.flush()

    def line(account_id, what, **amounts):
        create_dual_journal_entry(journal_entry_id=entry.id, account_id=account_id, apply_golden_rule=False,
                                  description=f'تصحيح فاتورة #{invoice.id} — {what}', **amounts)

    def cash(account_id, amount, what, **kw):
        if abs(amount) > CENT:
            line(account_id, what, **({'cash_debit': round(amount, 2)} if amount > 0
                                      else {'cash_credit': round(-amount, 2)}), **kw)

    # The gold, each line with its category: the line as posted undone, the
    # right lines done, against the side the invoice posted it against.
    if sale:
        counter = getattr(db.session.get(Account, party), 'memo_account_id', None) or party
    else:
        purchases = (get_account_id_for_mapping('شراء من عميل', 'purchases_gold_scrap')
                     or get_account_id_for_mapping('شراء من عميل', 'purchases_gold')
                     or require_account('شراء من عميل', 'purchases_gold_scrap'))
        counter = getattr(db.session.get(Account, purchases), 'memo_account_id', None) or purchases
    stock_lines = []

    def gold(karat, grams, category_id, what):
        """+grams into the safe, -grams out of it."""
        side, other = ('debit', 'credit') if grams > 0 else ('credit', 'debit')
        line(safe.account_id, what, **{f'{side}_{karat}k': abs(grams)})
        line(counter, what, **{f'{other}_{karat}k': abs(grams)})
        db.session.flush()
        written_line = (JournalEntryLine.query.filter_by(journal_entry_id=entry.id, account_id=safe.account_id)
                        .order_by(JournalEntryLine.id.desc()).first())
        stock_lines.append((written_line, karat, category_id, grams))

    gold(before_line['karat'], -sign * before_line['weight'], before_line['category_id'], 'السطر كما رُحِّل')
    for l in new:
        gold(l['karat'], sign * l['weight'], l['category_id'], 'السطر الصحيح')

    from services.gold_cost_postings import applies as gold_cost_applies
    pool = 'worked' if safe.stock_location in ('showroom', 'workshop', 'transit') else 'scrap'
    if sale:
        # The price's difference: the customer owes it, the sale earns it, its VAT as invoiced.
        revenue = (get_account_id_for_mapping('بيع', 'sales_gold_scrap' if invoice.gold_type == 'scrap'
                                              else 'sales_gold_new')
                   or get_account_id_for_mapping('بيع', 'revenue') or require_account('بيع', 'sales_gold_new'))
        cash(party, cash_delta, 'فرق السعر', customer_id=invoice.customer_id)
        cash(revenue, -net_delta, 'فرق الإيراد')
        if abs(tax_delta) > CENT:
            from accounting.mappings import require_vat_account
            cash(get_account_id_for_mapping('بيع', 'vat_payable') or require_vat_account('بيع', 'vat_payable'),
                 -tax_delta, 'فرق الضريبة')
        # The wage released with the weight sold, when wages are capitalized (ADR-039).
        from accounting.wages import (manufacturing_wage_expense_account_id, manufacturing_wage_inventory_account_id,
                                      wage_mode_of, wages_are_capitalized)
        wage_delta = round(_f(old.wage) * (sum(l['weight'] for l in new) - before_line['weight']), 2)
        if abs(wage_delta) > CENT and wages_are_capitalized(wage_mode_of(invoice)):
            cash(manufacturing_wage_expense_account_id() or require_account('بيع', 'manufacturing_wage'),
                 wage_delta, 'فرق الأجور المحمّلة')
            cash(manufacturing_wage_inventory_account_id() or require_account('شراء', 'manufacturing_wage_inventory'),
                 -wage_delta, 'فرق الأجور المحمّلة')
        # From the settings' day the gold sold carries its cost (ADR-042):
        # its difference at the sale's own cost a gram.
        if gold_cost_applies(now):
            from services.gold_cost_postings import _value_account, posted_sale_cost
            posted = posted_sale_cost(invoice)
            grams_before = _main([_line_of(i) for i in InvoiceItem.query.filter_by(invoice_id=invoice.id)])
            if posted and grams_before > GRAM:
                per_gram = sum(posted.values()) / grams_before
                cost = round(per_gram * (_main(new) - _main([before_line])), 2)
                cash(next(iter(posted)), cost, 'فرق تكلفة الذهب المباع')
                cash(_value_account(pool), -cost, 'فرق تكلفة الذهب المباع')
    elif abs(cash_delta) > CENT:
        # The price's difference: the purchase's cost against the customer. From
        # the settings' day the cost is the gold's value in its pool (ADR-042).
        cost_account = purchases
        if gold_cost_applies(now):
            from services.gold_cost_postings import _value_account
            cost_account = _value_account(pool)
        cash(cost_account, cash_delta, 'فرق السعر')
        cash(party, -cash_delta, 'فرق السعر', customer_id=invoice.customer_id)
    db.session.flush()
    verify_dual_balance(entry.id)

    from services.stock_ledger import allocate
    for written_line, karat, category_id, grams in stock_lines:
        if category_id:
            allocate(written_line, karat, category_id, grams, now=now, by=by)
    _rebuild_safe_box_transactions_for_journal_entry(
        entry, JournalEntryLine.query.filter_by(journal_entry_id=entry.id, is_deleted=False).all(), created_by=by)

    # The line in place: the first new line is the old line's row; the rest are added.
    first, rest = new[0], new[1:]
    written = []
    for item, l in [(old, first)] + [(None, l) for l in rest]:
        if item is None:
            item = InvoiceItem(invoice_id=invoice.id, quantity=1, price=0.0, wage=old.wage)
            db.session.add(item)
        written.append(item)
        item.name, item.karat, item.weight = l['name'], float(l['karat']), l['weight']
        item.standing_weight, item.stones_weight = l['weight'], 0.0
        item.net, item.tax = l['price'], l['tax']
        item.price = round(l['price'] + l['tax'], 2)
        item.category_id = l['category_id']
    db.session.flush()
    items = InvoiceItem.query.filter_by(invoice_id=invoice.id).order_by(InvoiceItem.id).all()
    invoice.total = round(_f(invoice.total) + cash_delta, 2)
    invoice.total_tax = round(_f(invoice.total_tax) + tax_delta, 2)
    invoice.net_amount = round(_f(invoice.net_amount) + cash_delta, 2)
    invoice.total_cost = round(_f(invoice.total_cost) + cost_delta, 2)
    invoice.total_weight = round(sum(_f(i.weight) for i in items), 3)

    correction.journal_entry_id = entry.id
    correction.after = {'snapshot_schema_version': 1, 'lines': [_line_of(i) for i in written],
                        'invoice': _invoice_of(invoice), 'profit': profit_after}
    db.session.flush()

    from services.invoice_payment_state_service import InvoicePaymentStateService
    InvoicePaymentStateService().recompute(invoice)
    return correction
