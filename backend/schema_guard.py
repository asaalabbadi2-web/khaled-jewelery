"""Runtime safeguards for keeping critical schema pieces in sync.

These helpers are intentionally lightweight so the app can self-heal when
new columns are introduced but existing deployments have not yet executed
Alembic migrations. They should only be used for additive changes that are
safe to apply with simple `ALTER TABLE ... ADD COLUMN ... DEFAULT ...`.
"""
from __future__ import annotations

import logging
from typing import Iterable

from sqlalchemy import inspect, text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError

LOGGER = logging.getLogger(__name__)


def _dialect_name(engine: Engine, connection) -> str:
    try:
        return (connection.dialect.name or '').strip().lower()
    except Exception:
        try:
            return (engine.dialect.name or '').strip().lower()
        except Exception:
            return ''


def _normalize_column_ddl_for_dialect(
    *,
    dialect: str,
    ddl_type: str,
    default: str,
) -> tuple[str, str]:
    """Normalize DDL snippets for specific SQL dialect quirks.

    This project historically used SQLite-friendly defaults like BOOLEAN DEFAULT 0.
    PostgreSQL requires boolean defaults to be TRUE/FALSE.
    """
    d = (dialect or '').lower()
    t = (ddl_type or '').strip()
    default_norm = (default or '').strip()

    if d in ('postgresql', 'postgres'):
        # Postgres doesn't have DATETIME; use TIMESTAMP.
        if t.upper() == 'DATETIME':
            t = 'TIMESTAMP'

        # Normalize boolean defaults.
        if t.upper() == 'BOOLEAN':
            if default_norm in ('0', '0.0'):
                default_norm = 'FALSE'
            elif default_norm in ('1', '1.0'):
                default_norm = 'TRUE'
            elif default_norm.lower() in ('true', 'false'):
                default_norm = default_norm.upper()

    return t, default_norm


def _ensure_columns(
    engine: Engine,
    table: str,
    columns: Iterable[tuple[str, str, str]],
) -> list[str]:
    """Ensure each ``(name, ddl, default)`` column tuple exists on ``table``.

    Parameters
    ----------
    engine:
        Bound SQLAlchemy engine to use for inspection and DDL execution.
    table:
        Table name to modify.
    columns:
        Iterable of tuples describing ``(column_name, ddl_type, default)``.

    Returns
    -------
    list[str]
        Names of columns that were added during this invocation.
    """
    added: list[str] = []
    with engine.connect() as connection:
		dialect = _dialect_name(engine, connection)
        inspector = inspect(connection)
        existing = {column["name"] for column in inspector.get_columns(table)}
        for name, ddl_type, default in columns:
            if name in existing:
                continue
            LOGGER.warning(
                "Missing column %s.%s detected at runtime; applying lightweight migration",
                table,
                name,
            )
            norm_type, norm_default = _normalize_column_ddl_for_dialect(
                dialect=dialect,
                ddl_type=ddl_type,
                default=default,
            )
            ddl = text(
                f"ALTER TABLE {table} ADD COLUMN {name} {norm_type} DEFAULT {norm_default}"
            )
            # Execute each statement in its own transaction. This prevents a single
            # failing ALTER from rolling back previously-added columns (notably on Postgres).
            try:
                with connection.begin():
                    connection.execute(ddl)
                added.append(f"{table}.{name}")
            except SQLAlchemyError as exc:
                LOGGER.error("Auto schema guard failed adding %s.%s: %s", table, name, exc)

    return added


def _log_added(columns_added: list[str]) -> None:
    if columns_added:
        LOGGER.info("Auto-added missing columns: %s", ", ".join(columns_added))


def ensure_profit_weight_columns(engine: Engine) -> None:
    """Backfill profit-weight columns if Alembic migration hasn't run yet."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice",
                [("profit_weight_price_per_gram", "FLOAT", "0")],
            )
        )
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice_item",
                [
                    ("avg_cost_per_gram_snapshot", "FLOAT", "0"),
                    ("profit_cash", "FLOAT", "0"),
                    ("profit_weight", "FLOAT", "0"),
                    ("profit_weight_price_per_gram", "FLOAT", "0"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_invoice_item_scrap_columns(engine: Engine) -> None:
    """Ensure scrap-purchase invoice item columns exist for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice_item",
                [
                    ("standing_weight", "FLOAT", "0"),
                    ("stones_weight", "FLOAT", "0"),
                    ("direct_purchase_price_per_gram", "FLOAT", "0"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_settings_columns(engine: Engine) -> None:
    """Ensure newer settings columns exist for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "settings",
                [
                    ("weight_closing_settings", "TEXT", "'{}'"),
                    ("require_auth_for_invoice_create", "BOOLEAN", "0"),
                    ("allow_partial_invoice_payments", "BOOLEAN", "0"),
                    ("password_policy", "TEXT", "NULL"),
                    ("company_logo_base64", "TEXT", "NULL"),
                    ("print_template_by_invoice_type", "TEXT", "NULL"),
                    ("gold_price_auto_update_enabled", "BOOLEAN", "0"),
                    ("gold_price_auto_update_time", "VARCHAR(5)", "'09:00'"),
                    ("gold_price_auto_update_mode", "VARCHAR(20)", "'interval'"),
                    ("gold_price_auto_update_interval_minutes", "INTEGER", "60"),
                    ("vat_exempt_karats", "TEXT", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_weight_closing_columns(engine: Engine) -> None:
    """Add invoice weight-closing summary columns when missing."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice",
                [
                    ("weight_closing_status", "VARCHAR(20)", "'not_initialized'"),
                    ("weight_closing_main_karat", "FLOAT", "21"),
                    ("weight_closing_total_weight", "FLOAT", "0"),
                    ("weight_closing_executed_weight", "FLOAT", "0"),
                    ("weight_closing_remaining_weight", "FLOAT", "0"),
                    ("weight_closing_close_price", "FLOAT", "0"),
                    ("weight_closing_order_number", "VARCHAR(30)", "NULL"),
                    ("weight_closing_price_source", "VARCHAR(20)", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_invoice_tax_columns(engine: Engine) -> None:
    """Ensure invoice-level tax breakdown columns exist."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice",
                [
                    ("gold_subtotal", "FLOAT", "0"),
                    ("wage_subtotal", "FLOAT", "0"),
                    ("gold_tax_total", "FLOAT", "0"),
                    ("wage_tax_total", "FLOAT", "0"),
                    ("print_template_preset_key", "VARCHAR(64)", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_invoice_branch_columns(engine: Engine) -> None:
    """Ensure invoice branch_id column exists for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice",
                [
                    ("branch_id", "INTEGER", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_invoice_employee_columns(engine: Engine) -> None:
    """Ensure invoice employee_id column exists for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice",
                [
                    ("employee_id", "INTEGER", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_app_user_security_columns(engine: Engine) -> None:
    """Ensure AppUser security columns exist (2FA + future session tooling)."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "app_user",
                [
                    ("email", "VARCHAR(150)", "NULL"),
                    ("phone", "VARCHAR(30)", "NULL"),
                    ("must_change_password", "BOOLEAN", "0"),
                    ("password_changed_at", "DATETIME", "NULL"),
                    ("totp_secret", "TEXT", "NULL"),
                    ("two_factor_enabled", "BOOLEAN", "0"),
                    ("two_factor_verified_at", "DATETIME", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_auth_security_columns(engine: Engine) -> None:
    """Ensure auth security tables have expected columns.

    This is intentionally additive-only and safe for legacy SQLite DBs.
    """
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "refresh_tokens",
                [
                    ("device_fingerprint", "VARCHAR(255)", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_journal_line_dimension_columns(engine: Engine) -> None:
    """Ensure Financial Dimensions + analytics columns exist on journal_entry_line."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "journal_entry_line",
                [
                    ("dimension_set_id", "INTEGER", "NULL"),
                    ("analytic_amount_cash", "FLOAT", "NULL"),
                    ("analytic_weight_24k", "FLOAT", "NULL"),
                    ("analytic_weight_main", "FLOAT", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)
