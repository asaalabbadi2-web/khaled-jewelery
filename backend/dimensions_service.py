from __future__ import annotations

import hashlib

from pricing.constants import SAR_USD_PEG, TROY_OZ_TO_GRAMS
from dataclasses import dataclass
from typing import Any, Dict, Tuple


@dataclass(frozen=True)
class DimensionInput:
    code: str
    int_value: int | None = None
    str_value: str | None = None
    label_ar: str | None = None


# Simple in-memory caches (per-process) to reduce DB lookups
_DEFINITION_ID_CACHE: Dict[str, int] = {}
_DIMENSION_VALUE_CACHE: Dict[Tuple[int, int | None, str | None], int] = {}
_DIMENSION_SET_CACHE: Dict[str, int] = {}


def _stable_key(parts: list[str]) -> str:
    raw = "|".join(parts)
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def ensure_core_dimensions(db_session) -> dict[str, int]:
    """Ensure the core dimension definitions exist.

    Returns a mapping of {code -> definition_id}.
    """
    from models import DimensionDefinition

    global _DEFINITION_ID_CACHE

    # Fast path: if we already have all core codes cached, reuse.
    # NOTE: Historical/legacy naming:
    # - We store Branch under the dimension code "office" for older installs.
    # - "gold_office" is the dedicated dimension for gold raw suppliers (مكاتب التسكير).
    core = {
        "office": "الفرع",
        "gold_office": "مكتب تسكير",
        "transaction_type": "نوع العملية",
        "employee": "الموظف",
    }

    if all(code in _DEFINITION_ID_CACHE for code in core.keys()):
        # Guard against stale in-memory cache after DB reset (drop/create).
        # Don't trust cached ids blindly; rebuild mapping from current DB.
        rows = (
            db_session.query(DimensionDefinition)
            .filter(DimensionDefinition.code.in_(list(core.keys())))
            .all()
        )
        if len(rows) == len(core):
            result = {d.code: d.id for d in rows}
            _DEFINITION_ID_CACHE.update(result)
            return result
        _DEFINITION_ID_CACHE.clear()

    existing = {
        d.code: d
        for d in db_session.query(DimensionDefinition)
        .filter(DimensionDefinition.code.in_(list(core.keys())))
        .all()
    }

    for code, name_ar in core.items():
        if code in existing:
            continue
        db_session.add(DimensionDefinition(code=code, name_ar=name_ar))

    db_session.flush()

    # Re-read ids (flush created them) and update cache.
    result = {
        d.code: d.id
        for d in db_session.query(DimensionDefinition)
        .filter(DimensionDefinition.code.in_(list(core.keys())))
        .all()
    }
    _DEFINITION_ID_CACHE.update(result)
    return result


def get_or_create_dimension_value(db_session, definition_id: int, input_value: DimensionInput) -> int:
    from models import DimensionValue

    global _DIMENSION_VALUE_CACHE

    cache_key: Tuple[int, int | None, str | None] = (
        int(definition_id),
        int(input_value.int_value) if input_value.int_value is not None else None,
        str(input_value.str_value) if input_value.str_value is not None else None,
    )

    # Cache fast-path
    cached_id = _DIMENSION_VALUE_CACHE.get(cache_key)
    if cached_id is not None:
        # Guard against stale cache after DB reset.
        # Important: IDs may be re-used after drop/create, so validate row identity.
        existing_cached = db_session.get(DimensionValue, cached_id)
        if existing_cached is not None:
            expected_int = int(input_value.int_value) if input_value.int_value is not None else None
            expected_str = str(input_value.str_value) if input_value.str_value is not None else None
            if (
                int(existing_cached.definition_id) == int(definition_id)
                and (existing_cached.int_value == expected_int)
                and (existing_cached.str_value == expected_str)
            ):
                return cached_id
        _DIMENSION_VALUE_CACHE.pop(cache_key, None)

    query = db_session.query(DimensionValue).filter(DimensionValue.definition_id == definition_id)
    if input_value.int_value is None:
        query = query.filter(DimensionValue.int_value.is_(None))
    else:
        query = query.filter(DimensionValue.int_value == int(input_value.int_value))

    if input_value.str_value is None:
        query = query.filter(DimensionValue.str_value.is_(None))
    else:
        query = query.filter(DimensionValue.str_value == str(input_value.str_value))

    existing = query.first()
    if existing:
        # Keep label up-to-date (optional)
        if input_value.label_ar and (existing.label_ar != input_value.label_ar):
            existing.label_ar = input_value.label_ar
        db_session.flush()
        _DIMENSION_VALUE_CACHE[cache_key] = existing.id
        return existing.id

    created = DimensionValue(
        definition_id=definition_id,
        int_value=input_value.int_value,
        str_value=input_value.str_value,
        label_ar=input_value.label_ar,
    )
    db_session.add(created)
    db_session.flush()
    _DIMENSION_VALUE_CACHE[cache_key] = created.id
    return created.id


def get_or_create_dimension_set(db_session, dimensions: list[DimensionInput]) -> int | None:
    """Create/reuse a DimensionSet for the given dimensions.

    - One set per unique combination (stable SHA1 key).
    - Returns DimensionSet.id or None if dimensions empty.
    """
    if not dimensions:
        return None

    from models import DimensionSet, DimensionSetItem

    global _DIMENSION_SET_CACHE

    defs = ensure_core_dimensions(db_session)

    # Normalize + de-dup by code (last wins).
    by_code: dict[str, DimensionInput] = {}
    for dim in dimensions:
        if not dim.code:
            continue
        by_code[dim.code] = dim

    normalized: list[DimensionInput] = []
    key_parts: list[str] = []
    for code in sorted(by_code.keys()):
        dim = by_code[code]
        definition_id = defs.get(code)
        if not definition_id:
            # Ignore unknown dimension codes for now.
            continue
        value_id = get_or_create_dimension_value(db_session, definition_id, dim)
        normalized.append(DimensionInput(code=code, int_value=value_id))
        key_parts.append(f"{code}:{value_id}")

    if not key_parts:
        return None

    key_hash = _stable_key(key_parts)

    # Cache fast-path
    cached_id = _DIMENSION_SET_CACHE.get(key_hash)
    if cached_id is not None:
        # Guard against stale cache after DB reset.
        # IDs may be re-used after drop/create, so verify key_hash.
        existing_cached = db_session.get(DimensionSet, cached_id)
        if existing_cached is not None and existing_cached.key_hash == key_hash:
            return cached_id
        _DIMENSION_SET_CACHE.pop(key_hash, None)

    existing = db_session.query(DimensionSet).filter(DimensionSet.key_hash == key_hash).first()
    if existing:
        _DIMENSION_SET_CACHE[key_hash] = existing.id
        return existing.id

    created = DimensionSet(key_hash=key_hash)
    db_session.add(created)
    db_session.flush()
    _DIMENSION_SET_CACHE[key_hash] = created.id

    for dim in normalized:
        db_session.add(DimensionSetItem(dimension_set_id=created.id, dimension_value_id=int(dim.int_value)))

    db_session.flush()
    return created.id


def _get_price_per_gram_24k_sar(db_session) -> float | None:
    """Return SAR/gram for 24k based on latest GoldPrice (ounce USD)."""
    try:
        from models import GoldPrice

        latest = db_session.query(GoldPrice).order_by(GoldPrice.date.desc()).first()
        if not latest or not latest.price:
            return None
        return (float(latest.price) / TROY_OZ_TO_GRAMS) * SAR_USD_PEG
    except Exception:
        return None


def _get_main_karat(db_session) -> int:
    """The settings' main karat -- MainKaratNotSet when they hold none."""
    from pricing.gold_price_service import get_main_karat
    return int(get_main_karat())


def compute_line_analytics(db_session, line: Any) -> tuple[float | None, float | None, float | None]:
    """Compute signed analytics metrics for a JournalEntryLine.

    Returns: (analytic_amount_cash, analytic_weight_24k, analytic_weight_main)
    """
    cash_debit = float(getattr(line, "cash_debit", 0.0) or 0.0)
    cash_credit = float(getattr(line, "cash_credit", 0.0) or 0.0)
    amount_cash = cash_debit - cash_credit

    # Physical net by karat (signed)
    net_18 = float(getattr(line, "debit_18k", 0.0) or 0.0) - float(getattr(line, "credit_18k", 0.0) or 0.0)
    net_21 = float(getattr(line, "debit_21k", 0.0) or 0.0) - float(getattr(line, "credit_21k", 0.0) or 0.0)
    net_22 = float(getattr(line, "debit_22k", 0.0) or 0.0) - float(getattr(line, "credit_22k", 0.0) or 0.0)
    net_24 = float(getattr(line, "debit_24k", 0.0) or 0.0) - float(getattr(line, "credit_24k", 0.0) or 0.0)

    physical_24k = (net_18 * (18.0 / 24.0)) + (net_21 * (21.0 / 24.0)) + (net_22 * (22.0 / 24.0)) + net_24

    weight_type = (getattr(line, "weight_type", None) or "ANALYTICAL").upper()

    # Prefer stored snapshot on the line (price per gram 24k in SAR) when converting
    # cash → weight for analytics, to keep historical reports stable.
    snapshot_price = None
    try:
        raw = getattr(line, "gold_price_snapshot", None)
        if raw is not None:
            snapshot_price = float(raw) or None
    except Exception:
        snapshot_price = None

    price_24k = snapshot_price if snapshot_price and snapshot_price > 0 else _get_price_per_gram_24k_sar(db_session)

    computed_24k: float | None = None

    has_any_weight = any(abs(v) > 0 for v in (net_18, net_21, net_22, net_24))

    if weight_type == "PHYSICAL" and has_any_weight:
        computed_24k = physical_24k
    elif abs(amount_cash) > 0.0001 and price_24k and price_24k > 0:
        computed_24k = amount_cash / float(price_24k)
    elif has_any_weight:
        computed_24k = physical_24k

    main_karat = _get_main_karat(db_session)
    if computed_24k is None or not main_karat:
        return (amount_cash, computed_24k, None)

    weight_main = computed_24k * (24.0 / float(main_karat))
    return (amount_cash, computed_24k, weight_main)
