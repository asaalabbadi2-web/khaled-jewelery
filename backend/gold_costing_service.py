"""Gold costing service utilities for moving average calculations."""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Dict, Optional

from models import db, InventoryCostingConfig


@dataclass
class AverageSnapshot:
    """Simple container for exposing average components."""

    avg_total: float
    avg_gold: float
    avg_manufacturing: float

    def to_dict(self) -> Dict[str, float]:
        return asdict(self)


class GoldCostingService:
    """Encapsulates moving-average costing logic (gold + manufacturing)."""

    @staticmethod
    def _get_config(costing_type: str = 'normal', create_if_missing: bool = True) -> InventoryCostingConfig:
        config: Optional[InventoryCostingConfig] = (
            InventoryCostingConfig.query
            .filter_by(costing_type=costing_type)
            .first()
        )
        # Backward-compat fallback: if no 'normal' row exists, try the first row
        if not config and costing_type == 'normal':
            config = InventoryCostingConfig.query.first()
            if config and not config.costing_type:
                config.costing_type = 'normal'
                db.session.flush()
        if not config and create_if_missing:
            config = InventoryCostingConfig(
                costing_type=costing_type,
                costing_method='moving_average',
                current_avg_cost_per_gram=0.0,
                avg_gold_price_per_gram=0.0,
                avg_manufacturing_per_gram=0.0,
                avg_total_cost_per_gram=0.0,
                total_inventory_weight=0.0,
                total_gold_value=0.0,
                total_manufacturing_value=0.0,
            )
            db.session.add(config)
            # flush, not commit: an invoice asks for the average mid-creation,
            # and a commit here kept the half-built invoice when its posting
            # was then refused -- on a database with no costing row yet (a new
            # year's, ADR-044). The row is the caller's transaction's.
            db.session.flush()
        return config

    @staticmethod
    def snapshot() -> AverageSnapshot:
        """Return the current average components for use on invoices."""
        config = GoldCostingService._get_config()
        return AverageSnapshot(
            avg_total=config.avg_total_cost_per_gram or 0.0,
            avg_gold=config.avg_gold_price_per_gram or 0.0,
            avg_manufacturing=config.avg_manufacturing_per_gram or 0.0,
        )

    @staticmethod
    def config_dict() -> Dict[str, float]:
        config = GoldCostingService._get_config()
        return config.to_dict()

    @staticmethod
    def update_config(costing_method: Optional[str] = None) -> Dict[str, float]:
        config = GoldCostingService._get_config()
        if costing_method:
            config.costing_method = costing_method
        db.session.commit()
        return config.to_dict()

    @staticmethod
    def update_average_on_purchase(
        weight_grams: float,
        gold_price_per_gram: float,
        manufacturing_wage_per_gram: float = 0.0,
        auto_commit: bool = True,
    ) -> AverageSnapshot:
        """Update moving averages when purchasing new gold inventory."""
        if weight_grams is None or weight_grams <= 0:
            return GoldCostingService.snapshot()

        config = GoldCostingService._get_config()

        gold_value = (gold_price_per_gram or 0.0) * weight_grams
        manufacturing_value = (manufacturing_wage_per_gram or 0.0) * weight_grams
        total_value = gold_value + manufacturing_value

        config.total_inventory_weight = (config.total_inventory_weight or 0.0) + weight_grams
        config.total_gold_value = (config.total_gold_value or 0.0) + gold_value
        config.total_manufacturing_value = (config.total_manufacturing_value or 0.0) + manufacturing_value

        if config.total_inventory_weight > 0:
            config.avg_gold_price_per_gram = config.total_gold_value / config.total_inventory_weight
            config.avg_manufacturing_per_gram = (
                config.total_manufacturing_value / config.total_inventory_weight
            )
            config.avg_total_cost_per_gram = config.avg_gold_price_per_gram + config.avg_manufacturing_per_gram
            config.current_avg_cost_per_gram = config.avg_total_cost_per_gram
        else:
            config.avg_gold_price_per_gram = 0.0
            config.avg_manufacturing_per_gram = 0.0
            config.avg_total_cost_per_gram = 0.0
            config.current_avg_cost_per_gram = 0.0

        config.last_purchase_price = gold_price_per_gram
        config.last_purchase_weight = weight_grams

        if auto_commit:
            db.session.commit()
        else:
            db.session.flush()

        return GoldCostingService.snapshot()

    @staticmethod
    def consume_inventory(weight_grams: float, auto_commit: bool = True) -> AverageSnapshot:
        """Reduce totals after a sale using the current moving average."""
        if weight_grams is None or weight_grams <= 0:
            return GoldCostingService.snapshot()

        config = GoldCostingService._get_config()
        if not config.total_inventory_weight:
            return GoldCostingService.snapshot()

        deduction_weight = min(weight_grams, config.total_inventory_weight)
        gold_deduction = (config.avg_gold_price_per_gram or 0.0) * deduction_weight
        manufacturing_deduction = (config.avg_manufacturing_per_gram or 0.0) * deduction_weight

        config.total_inventory_weight -= deduction_weight
        config.total_gold_value = max(0.0, (config.total_gold_value or 0.0) - gold_deduction)
        config.total_manufacturing_value = max(
            0.0, (config.total_manufacturing_value or 0.0) - manufacturing_deduction
        )

        if config.total_inventory_weight > 0:
            config.avg_gold_price_per_gram = config.total_gold_value / config.total_inventory_weight
            config.avg_manufacturing_per_gram = (
                config.total_manufacturing_value / config.total_inventory_weight
            )
            config.avg_total_cost_per_gram = config.avg_gold_price_per_gram + config.avg_manufacturing_per_gram
            config.current_avg_cost_per_gram = config.avg_total_cost_per_gram
        else:
            config.avg_gold_price_per_gram = 0.0
            config.avg_manufacturing_per_gram = 0.0
            config.avg_total_cost_per_gram = 0.0
            config.current_avg_cost_per_gram = 0.0

        if auto_commit:
            db.session.commit()
        else:
            db.session.flush()
        return GoldCostingService.snapshot()

    @staticmethod
    def calculate_cogs(weight_grams: float) -> Dict[str, float]:
        """Calculate cost of goods sold for a weight using the current average."""
        snapshot = GoldCostingService.snapshot()
        weight = weight_grams or 0.0
        gold_component = snapshot.avg_gold * weight
        manufacturing_component = snapshot.avg_manufacturing * weight
        total = gold_component + manufacturing_component
        return {
            'weight_grams': weight,
            'gold_component': gold_component,
            'manufacturing_component': manufacturing_component,
            'total_cogs': total,
        }


class ScrapCostingService:
    """Separate moving-average tracker for scrap and settlement gold purchases.

    Tracks the average price paid when buying old gold from customers
    (invoice_type='شراء من عميل') and when receiving gold via office
    settlements (invoice_type='شراء' with gold_type='scrap').

    This average is independent of the main inventory average and is
    useful for pricing buyback offers and assessing scrap profitability.
    Does NOT track consumption — scrap gold merges into main inventory.
    """

    COSTING_TYPE = 'scrap'

    @staticmethod
    def _get_config(create_if_missing: bool = True) -> InventoryCostingConfig:
        return GoldCostingService._get_config(
            costing_type=ScrapCostingService.COSTING_TYPE,
            create_if_missing=create_if_missing,
        )

    @staticmethod
    def snapshot() -> AverageSnapshot:
        config = ScrapCostingService._get_config()
        return AverageSnapshot(
            avg_total=config.avg_total_cost_per_gram or 0.0,
            avg_gold=config.avg_gold_price_per_gram or 0.0,
            avg_manufacturing=config.avg_manufacturing_per_gram or 0.0,
        )

    @staticmethod
    def config_dict() -> dict:
        return ScrapCostingService._get_config().to_dict()

    @staticmethod
    def update_average_on_purchase(
        weight_grams: float,
        gold_price_per_gram: float,
        manufacturing_wage_per_gram: float = 0.0,
        auto_commit: bool = True,
    ) -> AverageSnapshot:
        """Update scrap moving average when buying scrap/settlement gold."""
        if not weight_grams or weight_grams <= 0:
            return ScrapCostingService.snapshot()

        config = ScrapCostingService._get_config()

        gold_value = (gold_price_per_gram or 0.0) * weight_grams
        manufacturing_value = (manufacturing_wage_per_gram or 0.0) * weight_grams

        config.total_inventory_weight = (config.total_inventory_weight or 0.0) + weight_grams
        config.total_gold_value = (config.total_gold_value or 0.0) + gold_value
        config.total_manufacturing_value = (config.total_manufacturing_value or 0.0) + manufacturing_value

        if config.total_inventory_weight > 0:
            config.avg_gold_price_per_gram = config.total_gold_value / config.total_inventory_weight
            config.avg_manufacturing_per_gram = (
                config.total_manufacturing_value / config.total_inventory_weight
            )
            config.avg_total_cost_per_gram = (
                config.avg_gold_price_per_gram + config.avg_manufacturing_per_gram
            )
            config.current_avg_cost_per_gram = config.avg_total_cost_per_gram
        else:
            config.avg_gold_price_per_gram = 0.0
            config.avg_manufacturing_per_gram = 0.0
            config.avg_total_cost_per_gram = 0.0
            config.current_avg_cost_per_gram = 0.0

        config.last_purchase_price = gold_price_per_gram
        config.last_purchase_weight = weight_grams

        if auto_commit:
            db.session.commit()
        else:
            db.session.flush()

        return ScrapCostingService.snapshot()

    @staticmethod
    def reset(auto_commit: bool = True) -> dict:
        """Zero out all scrap costing accumulators."""
        config = ScrapCostingService._get_config()
        config.current_avg_cost_per_gram = 0.0
        config.avg_gold_price_per_gram = 0.0
        config.avg_manufacturing_per_gram = 0.0
        config.avg_total_cost_per_gram = 0.0
        config.total_inventory_weight = 0.0
        config.total_gold_value = 0.0
        config.total_manufacturing_value = 0.0
        config.last_purchase_price = None
        config.last_purchase_weight = None
        if auto_commit:
            db.session.commit()
        else:
            db.session.flush()
        return config.to_dict()


def calculate_profit_weight(profit_cash: float, reference_price_per_gram: float) -> float:
    """Convert cash profit to weight units using a reference gold price/gram."""

    profit_cash = profit_cash or 0.0
    reference_price_per_gram = reference_price_per_gram or 0.0
    if reference_price_per_gram <= 0:
        return 0.0
    return profit_cash / reference_price_per_gram


def calculate_closing_difference(
    profit_weight: float,
    profit_cash: float,
    close_price: float,
) -> Dict[str, float]:
    """Calculate closing value and valuation difference when price changes."""

    profit_weight = profit_weight or 0.0
    profit_cash = profit_cash or 0.0
    close_price = close_price or 0.0

    close_value = profit_weight * close_price
    difference_value = close_value - profit_cash
    difference_weight = 0.0
    if close_price > 0:
        difference_weight = profit_weight - (profit_cash / close_price)

    return {
        'close_value': close_value,
        'difference_value': difference_value,
        'difference_weight': difference_weight,
    }