"""Pricing domain — gold spot price + moving-average costing.

Blueprint: pricing_bp (registered under /api prefix in app.py)

Migrated from routes.py as part of Phase A domain split.
Rule: new pricing routes go here, never back into routes.py.
"""
from __future__ import annotations

import traceback
from datetime import datetime, timedelta

from flask import Blueprint, current_app, jsonify, request
from auth_decorators import require_permission
from sqlalchemy.orm import joinedload

from gold_costing_service import GoldCostingService, ScrapCostingService
from gold_price import fetch_gold_price, save_gold_price
from models import GoldPrice, InventoryCostingConfig, Invoice, db
from utils import get_main_karat
from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS
from pricing import price_clock

pricing_bp = Blueprint('pricing', __name__)

# ---------------------------------------------------------------------------
# Gold Price
# ---------------------------------------------------------------------------

@pricing_bp.route('/gold_price', methods=['GET'])
def get_gold_price():
    """يجلب آخر سعر ذهب — يُحدِّثه تلقائياً إن كان أقدم من 5 دقائق."""
    latest = GoldPrice.query.order_by(GoldPrice.date.desc()).first()

    # The stored time is UTC; so is the age, and «today» is Riyadh's (price_clock).
    now = price_clock.utc_now()
    day_start, day_end = price_clock.riyadh_day_bounds_utc(price_clock.riyadh_today(now))
    opening = (GoldPrice.query.filter(GoldPrice.date >= day_start, GoldPrice.date < day_end)
               .order_by(GoldPrice.date.asc()).first())

    should_update = not latest or (now - latest.date) > timedelta(minutes=5)
    if not latest:
        print('[INFO] لا يوجد سعر ذهب في قاعدة البيانات - سيتم الجلب من API')
    elif should_update:
        print(f'[INFO] السعر المحفوظ قديم ({latest.date}) - سيتم التحديث')

    if should_update:
        try:
            price_usd = fetch_gold_price()
            if price_usd:
                price_per_gram_sar = (price_usd / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
                save_gold_price(current_app._get_current_object(), price_usd)
                print(f'[SUCCESS] تم جلب وحفظ سعر جديد: ${price_usd}/أونصة = {price_per_gram_sar:.2f} ر.س/جم')
                main_karat = get_main_karat()
                return jsonify({
                    'price_24k': round(price_per_gram_sar, 2),
                    'price_main_karat': round((price_per_gram_sar * main_karat) / 24.0, 2),
                    'main_karat': main_karat,
                    'price_usd_per_oz': price_usd,
                    'opening_price_usd_per_oz': (opening.price if opening else price_usd),
                    'opening_date': price_clock.iso_utc(opening.date if (opening and opening.date) else now),
                    'currency': 'ر.س',
                    'date': price_clock.iso_utc(now),
                    'source': 'API',
                })
        except Exception as e:
            print(f'[ERROR] فشل جلب السعر من API: {e}')
            if latest:
                price_per_gram_sar = (latest.price / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
                main_karat = get_main_karat()
                return jsonify({
                    'price_24k': round(price_per_gram_sar, 2),
                    'price_main_karat': round((price_per_gram_sar * main_karat) / 24.0, 2),
                    'main_karat': main_karat,
                    'price_usd_per_oz': latest.price,
                    'opening_price_usd_per_oz': (opening.price if opening else latest.price),
                    'opening_date': price_clock.iso_utc(opening.date if (opening and opening.date) else latest.date),
                    'currency': 'ر.س',
                    'date': price_clock.iso_utc(latest.date),
                    'source': 'Database (Fallback)',
                })

    if latest:
        price_per_gram_sar = (latest.price / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
        main_karat = get_main_karat()
        return jsonify({
            'price_24k': round(price_per_gram_sar, 2),
            'price_main_karat': round((price_per_gram_sar * main_karat) / 24.0, 2),
            'main_karat': main_karat,
            'price_usd_per_oz': latest.price,
            'opening_price_usd_per_oz': (opening.price if opening else latest.price),
            'opening_date': price_clock.iso_utc(opening.date if (opening and opening.date) else latest.date),
            'currency': 'ر.س',
            'date': price_clock.iso_utc(latest.date),
            'source': 'Database (Cached)',
        })

    return jsonify({'price_24k': 0, 'price_usd_per_oz': 0, 'currency': 'ر.س', 'date': None,
                    'error': 'لا يوجد سعر ذهب متاح'}), 404

@pricing_bp.route('/public/gold_price', methods=['GET'])
def get_gold_price_public():
    """Public endpoint for login screen — no auth required."""
    return get_gold_price()

@pricing_bp.route('/gold_price/24h', methods=['GET'])
def get_gold_price_24h():
    """آخر 24 ساعة من أسعار الذهب (حد أقصى 48 نقطة)."""
    try:
        cutoff = price_clock.utc_now() - timedelta(hours=24)
        rows = (
            GoldPrice.query
            .filter(GoldPrice.date >= cutoff)
            .order_by(GoldPrice.date.asc())
            .all()
        )
        # At most 48 points spread over the whole day, ending at the latest --
        # .limit(48) on the ascending rows showed only the day's first 48 minutes.
        if len(rows) > 48:
            step = (len(rows) - 1) / 47.0
            rows = [rows[round(i * step)] for i in range(48)]
        points = [{'timestamp': price_clock.iso_utc(r.date), 'price_usd_per_oz': float(r.price or 0)} for r in rows]
        return jsonify({'points': points, 'count': len(points)}), 200
    except Exception as e:
        current_app.logger.error(f'Error fetching 24h gold price: {e}')
        return jsonify({'points': [], 'count': 0, 'error': str(e)}), 500

@pricing_bp.route('/gold_price/update', methods=['POST'])
@require_permission('gold_price.update')
def update_gold_price():
    try:
        data = request.get_json(silent=True)
        price = float(data['price']) if (data and 'price' in data) else fetch_gold_price()
        if price:
            save_gold_price(current_app._get_current_object(), price)
            return jsonify({'success': True, 'price': price})
        return jsonify({'success': False, 'error': 'No price returned'}), 500
    except Exception as e:
        print('[ERROR] تحديث سعر الذهب تلقائياً:', str(e))
        traceback.print_exc()
        return jsonify({'success': False, 'error': str(e), 'trace': traceback.format_exc()}), 500

# ---------------------------------------------------------------------------
# Gold Costing — Moving Average
# ---------------------------------------------------------------------------

def _costing_snapshot_payload() -> dict:
    return {'snapshot': GoldCostingService.snapshot().to_dict(), 'config': GoldCostingService.config_dict()}

def _costing_zero_config() -> dict:
    config = InventoryCostingConfig.query.first()
    if not config:
        GoldCostingService._get_config()  # pylint: disable=protected-access
        config = InventoryCostingConfig.query.first()
    config.costing_method = config.costing_method or 'moving_average'
    config.current_avg_cost_per_gram = 0.0
    config.avg_gold_price_per_gram = 0.0
    config.avg_manufacturing_per_gram = 0.0
    config.avg_total_cost_per_gram = 0.0
    config.total_inventory_weight = 0.0
    config.total_gold_value = 0.0
    config.total_manufacturing_value = 0.0
    config.last_purchase_price = None
    config.last_purchase_weight = None
    db.session.commit()
    return config.to_dict()

def _rebuild_costing_from_invoices(limit: int | None = None) -> dict:
    """Rebuild moving average by replaying invoices chronologically."""
    _costing_zero_config()

    add_types = {'شراء', 'مرتجع بيع'}
    consume_types = {'بيع', 'مرتجع شراء', 'مرتجع شراء (مورد)'}
    relevant_types = add_types | consume_types

    query = (
        Invoice.query
        .filter(Invoice.invoice_type.in_(list(relevant_types)))
        .options(joinedload(Invoice.karat_lines))
        .order_by(Invoice.date.asc())
    )
    if limit is not None:
        query = query.limit(int(limit))

    processed = 0
    for inv in query.all():
        try:
            weight_main = float(inv.calculate_total_weight() or 0.0)
        except Exception:
            weight_main = float(getattr(inv, 'total_weight', 0.0) or 0.0)
        if weight_main <= 0:
            continue

        if inv.invoice_type in consume_types:
            GoldCostingService.consume_inventory(weight_main, auto_commit=False)
            processed += 1
            continue

        if inv.invoice_type == 'شراء' and str(getattr(inv, 'gold_type', '') or '').strip().lower() == 'scrap':
            continue

        gold_value_cash = sum((l.gold_value_cash or 0.0) for l in (inv.karat_lines or []))
        wage_value_cash = sum((l.manufacturing_wage_cash or 0.0) for l in (inv.karat_lines or []))
        if gold_value_cash == 0.0 and getattr(inv, 'gold_subtotal', None) is not None:
            gold_value_cash = float(inv.gold_subtotal or 0.0)
        if wage_value_cash == 0.0 and getattr(inv, 'wage_subtotal', None) is not None:
            wage_value_cash = float(inv.wage_subtotal or 0.0)

        if inv.invoice_type == 'مرتجع بيع':
            gold_c = float(getattr(inv, 'avg_cost_gold_component', 0.0) or 0.0)
            wage_c = float(getattr(inv, 'avg_cost_manufacturing_component', 0.0) or 0.0)
            if gold_c > 0 or wage_c > 0:
                GoldCostingService.update_average_on_purchase(weight_main, gold_c, wage_c, auto_commit=False)
                processed += 1
                continue

        gold_price_per_gram = (gold_value_cash / weight_main) if weight_main > 0 else 0.0
        wage_per_gram = (wage_value_cash / weight_main) if weight_main > 0 else 0.0
        if gold_price_per_gram == 0.0 and wage_per_gram == 0.0:
            total_cash = float(getattr(inv, 'total', 0.0) or 0.0)
            gold_price_per_gram = (total_cash / weight_main) if weight_main > 0 else 0.0

        GoldCostingService.update_average_on_purchase(weight_main, gold_price_per_gram, wage_per_gram, auto_commit=False)
        processed += 1

    db.session.commit()
    return {'processed_invoices': processed, **_costing_snapshot_payload()}

@pricing_bp.route('/gold-costing', methods=['GET'])
def get_gold_costing():
    return jsonify(_costing_snapshot_payload())

@pricing_bp.route('/gold-costing', methods=['PUT'])
@require_permission('system.settings')
def update_gold_costing():
    data = request.get_json(silent=True) or {}
    config = GoldCostingService.update_config(costing_method=data.get('costing_method'))
    return jsonify({'snapshot': GoldCostingService.snapshot().to_dict(), 'config': config})

@pricing_bp.route('/gold-costing/cogs', methods=['POST'])
@require_permission('reports.financial')
def calculate_gold_costing_cogs():
    data = request.get_json(silent=True) or {}
    return jsonify(GoldCostingService.calculate_cogs(float(data.get('weight_grams') or 0.0)))

@pricing_bp.route('/gold-costing/recompute', methods=['POST'])
@require_permission('costing.recompute')
def recompute_gold_costing():
    result = _rebuild_costing_from_invoices(limit=request.args.get('limit', type=int))
    return jsonify({'status': 'success', 'result': result})

@pricing_bp.route('/gold-costing/reset', methods=['POST'])
@require_permission('system.settings')
def reset_gold_costing():
    data = request.get_json(silent=True) or {}
    mode = (data.get('mode') or '').strip().lower()
    try:
        limit_int = int(data['limit']) if data.get('limit') is not None else None
    except Exception:
        limit_int = None

    if mode == 'rebuild':
        return jsonify({'status': 'success', 'result': _rebuild_costing_from_invoices(limit=limit_int)})
    if mode == 'zero':
        config = _costing_zero_config()
        return jsonify({'status': 'success', 'result': {'processed_invoices': 0,
                        'snapshot': GoldCostingService.snapshot().to_dict(), 'config': config}})
    return jsonify({'status': 'error', 'message': 'وضع غير معروف. استخدم mode=zero أو mode=rebuild'}), 400

# ---------------------------------------------------------------------------
# Scrap / Settlement Costing
# ---------------------------------------------------------------------------

def _scrap_costing_snapshot_payload() -> dict:
    config = ScrapCostingService._get_config()  # pylint: disable=protected-access
    snapshot = ScrapCostingService.snapshot()
    return {
        'costing_type': 'scrap',
        'avg_gold_price_per_gram': config.avg_gold_price_per_gram or 0.0,
        'avg_manufacturing_per_gram': config.avg_manufacturing_per_gram or 0.0,
        'avg_total_cost_per_gram': config.avg_total_cost_per_gram or 0.0,
        'total_inventory_weight': config.total_inventory_weight or 0.0,
        'total_gold_value': config.total_gold_value or 0.0,
        'last_purchase_price': config.last_purchase_price,
        'last_purchase_weight': config.last_purchase_weight,
        'last_updated': config.last_updated.isoformat() if config.last_updated else None,
        'snapshot': snapshot.to_dict(),
    }

def _rebuild_scrap_costing_from_invoices(limit: int | None = None) -> dict:
    ScrapCostingService.reset(auto_commit=True)

    q_customer = (Invoice.query
                  .filter(Invoice.invoice_type == 'شراء من عميل')
                  .options(joinedload(Invoice.karat_lines))
                  .order_by(Invoice.date.asc()))
    q_settlement = (Invoice.query
                    .filter(Invoice.invoice_type == 'شراء', Invoice.gold_type == 'scrap')
                    .options(joinedload(Invoice.karat_lines))
                    .order_by(Invoice.date.asc()))
    if limit is not None:
        q_customer = q_customer.limit(int(limit))
        q_settlement = q_settlement.limit(int(limit))

    all_invoices = sorted(list(q_customer.all()) + list(q_settlement.all()), key=lambda i: (i.date or ''))

    processed = 0
    for inv in all_invoices:
        try:
            weight_main = float(inv.calculate_total_weight() or 0.0)
        except Exception:
            weight_main = float(getattr(inv, 'total_weight', 0.0) or 0.0)
        if weight_main <= 0:
            continue

        gold_value_cash = sum((l.gold_value_cash or 0.0) for l in (inv.karat_lines or []))
        wage_value_cash = sum((l.manufacturing_wage_cash or 0.0) for l in (inv.karat_lines or []))
        if gold_value_cash == 0.0 and getattr(inv, 'gold_subtotal', None) is not None:
            gold_value_cash = float(inv.gold_subtotal or 0.0)
        if wage_value_cash == 0.0 and getattr(inv, 'wage_subtotal', None) is not None:
            wage_value_cash = float(inv.wage_subtotal or 0.0)

        gold_price_per_gram = (gold_value_cash / weight_main) if weight_main > 0 else 0.0
        wage_per_gram = (wage_value_cash / weight_main) if weight_main > 0 else 0.0
        if gold_price_per_gram == 0.0 and wage_per_gram == 0.0:
            total_cash = float(getattr(inv, 'total', 0.0) or 0.0)
            gold_price_per_gram = (total_cash / weight_main) if weight_main > 0 else 0.0

        ScrapCostingService.update_average_on_purchase(weight_main, gold_price_per_gram, wage_per_gram, auto_commit=False)
        processed += 1

    db.session.commit()
    return {'processed_invoices': processed, **_scrap_costing_snapshot_payload()}

@pricing_bp.route('/gold-costing/scrap', methods=['GET'])
def get_scrap_costing():
    return jsonify(_scrap_costing_snapshot_payload())

@pricing_bp.route('/gold-costing/scrap/recompute', methods=['POST'])
@require_permission('costing.recompute')
def recompute_scrap_costing():
    result = _rebuild_scrap_costing_from_invoices(limit=request.args.get('limit', type=int))
    return jsonify({'status': 'success', 'result': result})

@pricing_bp.route('/gold-costing/scrap/reset', methods=['POST'])
@require_permission('system.settings')
def reset_scrap_costing():
    config = ScrapCostingService.reset(auto_commit=True)
    return jsonify({'status': 'success', 'config': config})
