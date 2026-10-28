"""The sales still waiting to become gold, measured against the office's price (OFFICE-PRICE-1).

Each sale keeps its scrap price (ADR-048 decision 5): what its riyals waiting
to become gold are measured against. A sale before the office's terms kept
the ounce's -- and what waits will be closed at the office's (the owner, 28
Oct 2026: «نحن نقوم بالتسكير حسب سعر مكاتب التسكير»). Left so, the day of the
switch reads every waiting sale about 1 % short in ⑤; re-priced, it reads its
own sale's price at the office (the owner, 29 Oct 2026: the rest as advised).

Only a sale still waiting, recorded before the first price saved with the
office's terms: its ounce then (from the market price it kept), at the
office's terms now, times the ratio it was sold under. Its market price and
its profit stay as they were. dry_run (the default) writes nothing; a sale
an earlier run re-priced (its audit says which) is left as it is -- its ratio
is read from its price, which is the office's then.
"""
import json

from models import AuditLog, GoldPrice, Invoice, db


def _office_since():
    """When the first price with the office's terms was saved -- None before."""
    return (db.session.query(db.func.min(GoldPrice.date))
            .filter(GoldPrice.office_custom_fees_usd.isnot(None)).scalar())


ACTION = 'repair_waiting_sales_office_price'


def _repriced_already() -> set:
    done = set()
    for (details,) in db.session.query(AuditLog.details).filter(AuditLog.action == ACTION):
        try:
            done.update(int(c['invoice_id']) for c in json.loads(details or '{}').get('changed', []))
        except (ValueError, TypeError, KeyError):
            continue
    return done


def reprice_waiting_sales(*, by, now, dry_run=True):
    from pricing.buy_price import buy_price_ratio
    from pricing.gold_price_service import get_main_karat
    from pricing.office_price import gram_price, ounce_for_gram_24, settings_terms
    from services.weight_position import _replayed

    since = _office_since()
    if since is None:
        return {'refused': 'no price is saved with the office terms yet: nothing to measure against'}
    main, terms, ratio_now = int(get_main_karat()), settings_terms(), buy_price_ratio()
    waiting = [lot for lot in _replayed(now.date()).open_lots if lot.invoice_id is not None]
    changed, skipped, done = [], [], _repriced_already()
    for lot in waiting:
        sale = db.session.get(Invoice, lot.invoice_id)
        if sale is None or sale.invoice_type != 'بيع' or sale.date >= since or sale.id in done:
            continue
        market = float(sale.profit_weight_price_per_gram or 0)
        if market <= 0:
            skipped.append({'invoice_id': sale.id, 'why': 'no market price kept'})
            continue
        before = float(sale.scrap_buy_price_at_sale or 0)
        ratio = before / market if before > 0 else ratio_now
        ounce = ounce_for_gram_24(market * 24 / main, None)
        after = round(gram_price(ounce, main, terms) * ratio, 4)
        if abs(after - before) < 0.0001:
            continue
        changed.append({'invoice_id': sale.id, 'number': sale.invoice_type_id, 'date': sale.date,
                        'grams_waiting': round(lot.grams_open, 3), 'riyals_waiting': round(lot.cash_open, 2),
                        'scrap_price_before': round(before, 4) if before else None, 'scrap_price_after': after})
        if not dry_run:
            sale.scrap_buy_price_at_sale = after
    plan = {'office_since': since, 'terms': terms.__dict__, 'changed': changed, 'skipped': skipped}
    if not dry_run and changed:
        db.session.add(AuditLog(user_name=by, action=ACTION, entity_type='invoice',
                                entity_id=changed[0]['invoice_id'], success=True,
                                details=json.dumps(plan, ensure_ascii=False, default=str)))
        db.session.flush()
    return plan
