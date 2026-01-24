from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

from sqlalchemy import func

from models import Category, CategoryWeightMovement, Employee, Invoice, Item, SafeBox, Settings, db


def _coerce_float(value, default: float = 0.0) -> float:
    try:
        if value in (None, '', False):
            return float(default)
        return float(value)
    except Exception:
        return float(default)


def _get_main_karat_value() -> float:
    try:
        settings_row = Settings.query.first()
        mk = getattr(settings_row, 'main_karat', None) if settings_row else None
        mk_val = _coerce_float(mk, 21.0)
        return mk_val if mk_val > 0 else 21.0
    except Exception:
        return 21.0


def _convert_to_main_karat(weight_grams: float, karat: float) -> float:
    main_karat = _get_main_karat_value()
    k = _coerce_float(karat, main_karat)
    w = _coerce_float(weight_grams, 0.0)
    if w <= 0:
        return 0.0
    if main_karat <= 0 or k <= 0:
        return w
    return (w * k) / main_karat


def resolve_gold_safe_box_id_for_invoice(invoice: Invoice, karat: Optional[float] = None) -> Optional[int]:
    """Resolve which gold SafeBox represents the inventory location for this invoice.

    IMPORTANT: Invoice.safe_box_id is used for cash/bank payments. For gold location,
    we use Settings.* gold safe IDs, and optionally employee custody gold safe.
    """

    try:
        settings_row = Settings.query.first()
    except Exception:
        settings_row = None

    invoice_type = (getattr(invoice, 'invoice_type', None) or '').strip()
    gold_type = (getattr(invoice, 'gold_type', None) or 'new').strip() or 'new'

    # Sales inventory location is always the sale gold safe.
    # Employee gold safes are for custody/intake flows, not for where sale inventory lives.
    try:
        if invoice_type in ('بيع', 'مرتجع بيع'):
            sb_id = getattr(settings_row, 'sale_gold_safe_box_id', None) if settings_row else None
            if sb_id not in (None, '', 0, '0', False):
                return int(sb_id)
    except Exception:
        pass

    # Customer gold intake (scrap purchases): prefer employee custody gold safe when enabled.
    try:
        if invoice_type == 'شراء من عميل' and bool(getattr(settings_row, 'employee_gold_safes_enabled', False)):
            emp = getattr(invoice, 'employee', None)
            if not emp and getattr(invoice, 'employee_id', None):
                emp = Employee.query.get(int(invoice.employee_id))
            emp_safe = getattr(emp, 'gold_safe_box_id', None) if emp else None
            if emp_safe not in (None, '', 0, '0', False):
                return int(emp_safe)
    except Exception:
        pass

    # Default gold inventory locations by gold_type.
    try:
        if gold_type == 'scrap':
            sb_id = getattr(settings_row, 'main_scrap_gold_safe_box_id', None) if settings_row else None
        else:
            sb_id = getattr(settings_row, 'sale_gold_safe_box_id', None) if settings_row else None
        if sb_id not in (None, '', 0, '0', False):
            return int(sb_id)
    except Exception:
        pass

    # Last resort: pick a gold safe by karat (supports unified karat=None safe).
    try:
        karat_int = int(round(_coerce_float(karat, _get_main_karat_value())))
    except Exception:
        karat_int = int(round(_get_main_karat_value()))

    try:
        sb = SafeBox.get_gold_safe_by_karat(karat_int)
        return int(sb.id) if sb and sb.id else None
    except Exception:
        return None


def record_category_weight_movements_for_invoice_payload(
    invoice_id: int,
    items_payload: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """Create category-weight movements for a posted invoice (idempotent).

    Uses the original invoice request payload so category-only lines can be
    tracked even when InvoiceItem doesn't store category_id.
    """

    invoice = Invoice.query.get(invoice_id)
    if not invoice:
        return {'status': 'skipped', 'reason': 'invoice_not_found'}

    # Only record movements for posted invoices to avoid tracking drafts/approvals.
    if not bool(getattr(invoice, 'is_posted', False)):
        return {'status': 'skipped', 'reason': 'invoice_not_posted'}

    existing = CategoryWeightMovement.query.filter_by(invoice_id=invoice.id).first()
    if existing:
        return {'status': 'ok', 'reason': 'already_recorded', 'created': 0}

    invoice_type = (getattr(invoice, 'invoice_type', None) or '').strip()
    gold_type = (getattr(invoice, 'gold_type', None) or 'new').strip() or 'new'

    # Determine sign by invoice type.
    sign = 0
    if invoice_type in ('بيع', 'مرتجع شراء', 'مرتجع شراء (مورد)'):
        sign = -1
    elif invoice_type in ('شراء', 'شراء من عميل', 'مرتجع بيع'):
        sign = 1
    else:
        return {'status': 'skipped', 'reason': f'unsupported_invoice_type:{invoice_type}'}

    created = 0
    payload_rows: List[Dict[str, Any]] = list(items_payload or [])

    for item_data in payload_rows:
        if not isinstance(item_data, dict):
            continue

        # Resolve category_id either from coded item or directly from payload.
        category_id = None
        item_obj = None
        try:
            item_id = item_data.get('item_id')
            if item_id not in (None, '', False):
                item_obj = Item.query.get(int(item_id))
        except Exception:
            item_obj = None

        try:
            if item_obj and getattr(item_obj, 'category_id', None):
                category_id = int(item_obj.category_id)
        except Exception:
            category_id = None

        if not category_id:
            raw_cat_id = item_data.get('category_id')
            try:
                if raw_cat_id not in (None, '', False):
                    category_id = int(raw_cat_id)
            except Exception:
                category_id = None

        if not category_id:
            raw_cat_name = (item_data.get('category_name') or item_data.get('category') or '').strip()
            if raw_cat_name:
                try:
                    cat = Category.query.filter_by(name=raw_cat_name).first()
                    if cat and cat.id:
                        category_id = int(cat.id)
                except Exception:
                    category_id = None

        if not category_id:
            continue

        qty = _coerce_float(item_data.get('quantity', 1), 1.0)
        if qty <= 0:
            qty = 1.0

        weight_per = _coerce_float(item_data.get('weight', None), 0.0)
        if weight_per <= 0:
            weight_per = _coerce_float(item_data.get('total_weight', None), 0.0)
        if weight_per <= 0 and item_obj is not None:
            weight_per = _coerce_float(getattr(item_obj, 'weight', None), 0.0)

        total_weight = float(weight_per) * float(qty)
        if total_weight <= 0:
            continue

        karat_val = item_data.get('karat')
        if karat_val in (None, '', False) and item_obj is not None:
            karat_val = getattr(item_obj, 'karat', None)
        karat_float = _coerce_float(karat_val, _get_main_karat_value())

        safe_box_id = resolve_gold_safe_box_id_for_invoice(invoice, karat=karat_float)
        if not safe_box_id:
            continue

        delta = float(total_weight) * float(sign)
        delta_main = float(_convert_to_main_karat(total_weight, karat_float)) * float(sign)

        cat = Category.query.get(category_id)
        label = (item_data.get('name') or (item_obj.name if item_obj else None) or (cat.name if cat else None) or '').strip() or None

        row = CategoryWeightMovement(
            category_id=category_id,
            safe_box_id=safe_box_id,
            invoice_id=invoice.id,
            line_label=label,
            invoice_type=invoice_type,
            gold_type=gold_type,
            karat=karat_float,
            weight_delta_grams=round(delta, 6),
            weight_delta_main_karat=round(delta_main, 6),
            created_by=getattr(invoice, 'posted_by', None),
        )
        db.session.add(row)
        created += 1

    return {'status': 'ok', 'created': created}


def get_category_weight_balances(
    safe_box_id: Optional[int] = None,
    category_id: Optional[int] = None,
    karat: Optional[float] = None,
    group_by_karat: bool = False,
    gold_type: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Return balances aggregated by (safe_box, category[, karat])."""

    select_cols = [
        CategoryWeightMovement.safe_box_id,
        CategoryWeightMovement.category_id,
    ]
    if group_by_karat:
        select_cols.append(CategoryWeightMovement.karat)

    q = db.session.query(
        *select_cols,
        func.sum(CategoryWeightMovement.weight_delta_main_karat).label('main_total'),
        func.sum(CategoryWeightMovement.weight_delta_grams).label('grams_total'),
    )

    if safe_box_id:
        q = q.filter(CategoryWeightMovement.safe_box_id == int(safe_box_id))
    if category_id:
        q = q.filter(CategoryWeightMovement.category_id == int(category_id))
    if gold_type:
        gt = str(gold_type).strip()
        if gt:
            q = q.filter(CategoryWeightMovement.gold_type == gt)
    if karat is not None:
        k = _coerce_float(karat, 0.0)
        # Compare with tolerance to avoid float equality issues.
        q = q.filter(func.abs(CategoryWeightMovement.karat - k) < 0.001)

    group_cols = [CategoryWeightMovement.safe_box_id, CategoryWeightMovement.category_id]
    if group_by_karat:
        group_cols.append(CategoryWeightMovement.karat)
    q = q.group_by(*group_cols)

    rows = q.all() or []
    out: List[Dict[str, Any]] = []

    for row in rows:
        if group_by_karat:
            sb_id, cat_id, k, main_total, grams_total = row
        else:
            sb_id, cat_id, main_total, grams_total = row
            k = None

        sb = SafeBox.query.get(sb_id)
        cat = Category.query.get(cat_id)
        payload: Dict[str, Any] = {
            'safe_box_id': sb_id,
            'safe_box_name': sb.name if sb else None,
            'category_id': cat_id,
            'category_name': cat.name if cat else None,
            'weight_main_karat': round(float(main_total or 0.0), 6),
            'weight_grams_signed': round(float(grams_total or 0.0), 6),
        }
        if group_by_karat:
            payload['karat'] = float(k) if k is not None else None
        out.append(payload)

    return out
