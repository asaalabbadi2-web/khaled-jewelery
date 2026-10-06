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
    dialect = ''
    existing: set[str] = set()
    # Use a dedicated connection for inspection only. SQLAlchemy 2.0 may autobegin
    # a transaction during inspection, which makes nested begin() calls invalid.
    with engine.connect() as connection:
        dialect = _dialect_name(engine, connection)
        inspector = inspect(connection)
        try:
            if not inspector.has_table(table):
                return []
        except Exception:
            # If the dialect doesn't support has_table properly, fall back to get_columns.
            pass

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
        # Execute each statement in its own fresh transaction/connection.
        try:
            with engine.begin() as ddl_connection:
                ddl_connection.execute(ddl)
            added.append(f"{table}.{name}")
            existing.add(name)
        except SQLAlchemyError as exc:
            LOGGER.error("Auto schema guard failed adding %s.%s: %s", table, name, exc)

    return added


def _log_added(columns_added: list[str]) -> None:
    if columns_added:
        LOGGER.info("Auto-added missing columns: %s", ", ".join(columns_added))


def _sqlalchemy_default_as_ddl(col) -> str | None:
    """Extract a SQL-safe default string from a SQLAlchemy Column, or None."""
    server_default = getattr(col, 'server_default', None)
    if server_default is not None:
        try:
            return str(server_default.arg)
        except Exception:
            pass

    col_default = getattr(col, 'default', None)
    if col_default is None:
        return 'NULL'

    try:
        val = col_default.arg
        if isinstance(val, bool):
            return '1' if val else '0'
        if isinstance(val, (int, float)):
            return str(val)
        if isinstance(val, str):
            escaped = val.replace("'", "''")
            return f"'{escaped}'"
    except Exception:
        pass
    return 'NULL'


def _sqlalchemy_type_as_ddl(col) -> str:
    """Map a SQLAlchemy column type to a DDL type string."""
    import sqlalchemy as sa
    t = col.type
    if isinstance(t, sa.Boolean):
        return 'BOOLEAN'
    if isinstance(t, sa.Integer):
        return 'INTEGER'
    if isinstance(t, sa.Float):
        return 'FLOAT'
    if isinstance(t, sa.Numeric):
        return 'NUMERIC'
    if isinstance(t, sa.Text):
        return 'TEXT'
    if isinstance(t, (sa.String, sa.VARCHAR)):
        length = getattr(t, 'length', None)
        return f'VARCHAR({length})' if length else 'VARCHAR'
    if isinstance(t, sa.DateTime):
        return 'DATETIME'
    if isinstance(t, sa.Date):
        return 'DATE'
    if isinstance(t, sa.JSON):
        return 'TEXT'
    return 'TEXT'


def ensure_all_model_columns(engine: Engine, metadata) -> None:
    """Auto-sync every SQLAlchemy model column to the live DB schema.

    For each table defined in *metadata*, any column that exists in the model
    but is absent from the live DB is added via ALTER TABLE. Only simple
    additive changes are attempted (no PK, no FK, no unique constraints).
    This removes the need to manually update ensure_*_columns() lists.
    """
    added: list[str] = []
    with engine.connect() as connection:
        dialect = _dialect_name(engine, connection)
        inspector = inspect(connection)
        live_tables = set(inspector.get_table_names())

    for table in metadata.sorted_tables:
        if table.name not in live_tables:
            continue
        with engine.connect() as conn:
            inspector = inspect(conn)
            existing = {c['name'] for c in inspector.get_columns(table.name)}

        for col in table.columns:
            if col.name in existing:
                continue
            # Skip primary keys and columns with FK constraints — too risky to auto-add
            if col.primary_key or col.foreign_keys:
                continue

            ddl_type = _sqlalchemy_type_as_ddl(col)
            default_val = _sqlalchemy_default_as_ddl(col)

            norm_type, norm_default = _normalize_column_ddl_for_dialect(
                dialect=dialect, ddl_type=ddl_type, default=default_val or 'NULL'
            )

            LOGGER.warning(
                "Auto-migration: adding missing column %s.%s (%s DEFAULT %s)",
                table.name, col.name, norm_type, norm_default,
            )
            ddl = text(
                f"ALTER TABLE {table.name} ADD COLUMN {col.name}"
                f" {norm_type} DEFAULT {norm_default}"
            )
            try:
                with engine.begin() as ddl_conn:
                    ddl_conn.execute(ddl)
                added.append(f"{table.name}.{col.name}")
            except SQLAlchemyError as exc:
                LOGGER.error(
                    "Auto-migration failed for %s.%s: %s", table.name, col.name, exc
                )

    _log_added(added)


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
                    ("idle_timeout_enabled", "BOOLEAN", "1"),
                    ("idle_timeout_minutes", "INTEGER", "30"),
                    ("allow_partial_invoice_payments", "BOOLEAN", "0"),
                    ("password_policy", "TEXT", "NULL"),
                    ("company_logo_base64", "TEXT", "NULL"),
                    ("company_cr_number", "VARCHAR(50)", "NULL"),
                    ("print_template_by_invoice_type", "TEXT", "NULL"),
                    ("gold_price_auto_update_enabled", "BOOLEAN", "0"),
                    ("gold_price_auto_update_time", "VARCHAR(5)", "'09:00'"),
                    ("gold_price_auto_update_mode", "VARCHAR(20)", "'interval'"),
                    ("gold_price_auto_update_interval_minutes", "INTEGER", "60"),
                    # Backup/Restore (server-side scheduling)
                    ("backup_auto_enabled", "BOOLEAN", "0"),
                    ("backup_auto_mode", "VARCHAR(20)", "'daily'"),
                    ("backup_auto_time", "VARCHAR(5)", "'02:00'"),
                    ("backup_auto_interval_minutes", "INTEGER", "1440"),
                    ("backup_retention_count", "INTEGER", "7"),
                    ("vat_exempt_karats", "TEXT", "NULL"),

                    # Employee safebox routing (feature toggles)
                    ("employee_cash_safes_enabled", "BOOLEAN", "0"),
                    ("employee_gold_safes_enabled", "BOOLEAN", "0"),

                    # Default safebox ids (nullable)
                    ("main_cash_safe_box_id", "INTEGER", "NULL"),
                    ("sale_gold_safe_box_id", "INTEGER", "NULL"),
                    ("main_scrap_gold_safe_box_id", "INTEGER", "NULL"),

                    # Stones accounts
                    ("stones_pending_account_id", "INTEGER", "NULL"),
                    ("stones_display_revenue_account_id", "INTEGER", "NULL"),

                    # Startup bootstrap guard
                    ("disable_startup_bootstrap", "BOOLEAN", "0"),

                    # Voucher auto-post
                    ("voucher_auto_post", "BOOLEAN", "0"),

                    # Gamification / sales race
                    ("weekly_sales_target_weight", "REAL", "2000.0"),
                    ("monthly_sales_target_weight", "REAL", "8000.0"),
                    ("sales_race_settings", "TEXT", "NULL"),

                    # Posting preferences
                    ("auto_post_invoices", "BOOLEAN", "1"),
                    ("auto_post_entries", "BOOLEAN", "1"),
                    ("require_approval_before_post", "BOOLEAN", "0"),
                    ("allow_unposting", "BOOLEAN", "0"),

                    # Manufacturing wage mode
                    ("manufacturing_wage_mode", "VARCHAR(20)", "'expense'"),

                    # حسابات المكافآت القابلة للتخصيص حسب بيئة الإنتاج
                    # يُترك NULL ليستخدم النظام البحث التلقائي بالاسم
                    ("bonus_expense_account_number",  "VARCHAR(20)", "NULL"),
                    ("bonus_payable_account_number",  "VARCHAR(20)", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_voucher_print_columns(engine: Engine) -> None:
    """Ensure voucher print/detail columns exist for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "voucher",
                [
                    ("employee_id", "INTEGER", "NULL"),
                    ("receiver_name", "VARCHAR(200)", "NULL"),
                    ("karat_diff_earn_total", "FLOAT", "0"),
                    ("karat_diff_pay_total", "FLOAT", "0"),
                ],
            )
        )
        columns_added.extend(
            _ensure_columns(
                engine,
                "voucher_account_line",
                [
                    ("gross_weight", "FLOAT", "NULL"),
                    ("net_weight", "FLOAT", "NULL"),
                    ("stones_weight", "FLOAT", "0"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_journal_entry_columns(engine: Engine) -> None:
    """Ensure JournalEntry draft/posting/soft-delete columns exist.

    Some deployments have legacy databases created before the draft/posting
    system was introduced. Those DBs may lack columns like `is_draft`, which
    causes runtime INSERT failures when creating journal entries.
    """
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "journal_entry",
                [
                    ("is_draft", "BOOLEAN", "1"),
                    ("is_posted", "BOOLEAN", "0"),
                    ("posted_at", "DATETIME", "NULL"),
                    ("posted_by", "VARCHAR(100)", "NULL"),
                    ("is_deleted", "BOOLEAN", "0"),
                    ("deleted_at", "DATETIME", "NULL"),
                    ("deleted_by", "VARCHAR(100)", "NULL"),
                    ("deletion_reason", "VARCHAR(500)", "NULL"),
                    ("restored_at", "DATETIME", "NULL"),
                    ("restored_by", "VARCHAR(100)", "NULL"),
                    ("created_at", "TIMESTAMP", "NULL"),
                ],
            )
        )
        # Backfill created_at from date for existing rows (PostgreSQL only)
        try:
            with engine.connect() as conn:
                dialect = _dialect_name(engine, conn)
                if dialect == 'postgresql':
                    conn.execute(text(
                        "UPDATE journal_entry SET created_at = date WHERE created_at IS NULL"
                    ))
                    conn.commit()
        except Exception:
            pass
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed (journal_entry): %s", exc)
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


def ensure_invoice_barter_columns(engine: Engine) -> None:
    """Ensure barter-link columns exist on invoices.

    Used to link a customer scrap-purchase invoice back to the originating sale
    invoice in gold barter flows.
    """
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice",
                [
                    ("barter_sale_invoice_id", "INTEGER", "NULL"),
                    ("barter_total", "FLOAT", "0"),
                    ("scrap_holder_employee_id", "INTEGER", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_supplier_columns(engine: Engine) -> None:
    """Ensure newer supplier metadata columns exist for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "supplier",
                [
                    ("tax_number", "VARCHAR(50)", "NULL"),
                    ("classification", "VARCHAR(50)", "NULL"),
                    ("default_wage_type", "VARCHAR(10)", "'cash'"),
                    ("default_safe_box_id", "INTEGER", "NULL"),
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


def ensure_employee_gold_safe_columns(engine: Engine) -> None:
    """Ensure employee gold_safe_box_id column exists for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "employee",
                [
                    ("gold_safe_box_id", "INTEGER", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_employee_cash_safe_columns(engine: Engine) -> None:
    """Ensure employee cash_safe_box_id column exists for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "employee",
                [
                    ("cash_safe_box_id", "INTEGER", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_app_user_photo_column(engine: Engine) -> None:
    """Add photo column to both app_user and users tables for profile photos."""
    for table in ("app_user", "users"):
        try:
            added = _ensure_columns(engine, table, [("photo", "TEXT", "NULL")])
            _log_added(added)
        except SQLAlchemyError as exc:
            LOGGER.error("Auto schema guard (%s photo) failed: %s", table, exc)


def ensure_employee_photo_column(engine: Engine) -> None:
    """Add photo column to employee table for profile photos (base64 data URI)."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "employee",
                [
                    ("photo", "TEXT", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard (employee photo) failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_employee_goal_columns(engine: Engine) -> None:
    """Add per-employee personal goal columns for the goal achievement system."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "employee",
                [
                    ("goal_metric",           "VARCHAR(20)", "NULL"),
                    ("goal_name",             "VARCHAR(200)", "NULL"),
                    ("goal_weight_monthly",   "REAL",         "NULL"),
                    ("goal_weight_weekly",    "REAL",         "NULL"),
                    ("goal_points_monthly",   "REAL",         "NULL"),
                    ("goal_points_weekly",    "REAL",         "NULL"),
                    ("goal_invoices_monthly", "INTEGER",      "NULL"),
                    ("goal_invoices_weekly",  "INTEGER",      "NULL"),
                    # 🎛️ تفعيل/تعطيل الاحتفالية لكل فترة
                    ("goal_daily_enabled",    "BOOLEAN",      "0"),
                    ("goal_weekly_enabled",   "BOOLEAN",      "1"),
                    ("goal_monthly_enabled",  "BOOLEAN",      "1"),
                    # 📅 هدف يومي
                    ("goal_weight_daily",     "REAL",         "NULL"),
                    ("goal_points_daily",     "REAL",         "NULL"),
                    ("goal_invoices_daily",   "INTEGER",      "NULL"),
                    ("goal_bonus_daily",      "REAL",         "NULL"),
                    # 🏆 نوع المكافأة: 'fixed' | 'rule'
                    ("goal_reward_type_daily",   "VARCHAR(20)", "'fixed'"),
                    ("goal_reward_type_weekly",  "VARCHAR(20)", "'fixed'"),
                    ("goal_reward_type_monthly", "VARCHAR(20)", "'fixed'"),
                    # 🔗 ربط بـ BonusRule
                    ("goal_bonus_rule_id_daily",   "INTEGER", "NULL"),
                    ("goal_bonus_rule_id_weekly",  "INTEGER", "NULL"),
                    ("goal_bonus_rule_id_monthly", "INTEGER", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard (employee goals) failed: %s", exc)
        return

    _log_added(columns_added)



def ensure_app_user_security_columns(engine: Engine) -> None:
    """Ensure AppUser security columns exist on both app_user and users tables (2FA + session tooling)."""
    _security_cols = [
        ("email", "VARCHAR(150)", "NULL"),
        ("phone", "VARCHAR(30)", "NULL"),
        ("must_change_password", "BOOLEAN", "0"),
        ("password_changed_at", "DATETIME", "NULL"),
        ("totp_secret", "TEXT", "NULL"),
        ("two_factor_enabled", "BOOLEAN", "0"),
        ("two_factor_verified_at", "DATETIME", "NULL"),
    ]
    for _tbl in ("app_user", "users"):
        try:
            added = _ensure_columns(engine, _tbl, _security_cols)
            _log_added(added)
        except SQLAlchemyError as exc:
            LOGGER.error("Auto schema guard (%s security) failed: %s", _tbl, exc)


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
    """Ensure dual-system + Financial Dimensions + analytics columns exist on journal_entry_line."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "journal_entry_line",
                [
                    # Dual-system columns (dual_system_001 migration)
                    ("debit_weight", "FLOAT", "0.0"),
                    ("credit_weight", "FLOAT", "0.0"),
                    ("gold_price_snapshot", "FLOAT", "NULL"),
                    ("description", "VARCHAR(500)", "NULL"),
                    # weight_type column (weight_type_field_001 migration)
                    ("weight_type", "VARCHAR(20)", "'ANALYTICAL'"),
                    # Financial Dimensions + analytics columns
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


def ensure_payment_method_columns(engine: Engine) -> None:
    """Ensure newer payment_method columns exist for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "payment_method",
                [
                    ("deposit_delay_days", "INTEGER", "0"),
                    ("deposit_schedule_type", "VARCHAR(20)", "'days'"),
                    ("deposit_weekday", "INTEGER", "NULL"),
                    ("bank_weekend_days", "VARCHAR(20)", "''"),
                    ("skip_public_holidays", "BOOLEAN", "FALSE"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_account_columns(engine: Engine) -> None:
    """Ensure newer account columns exist for legacy databases."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "account",
                [
                    ("include_in_gram_profit", "BOOLEAN", "0"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_safe_box_transaction_stones_columns(engine: Engine) -> None:
    """Add stones columns to safe_box_transaction for per-vault stones tracking."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "safe_box_transaction",
                [
                    ("stones_weight", "FLOAT", "0.0"),
                    ("stones_18k",    "FLOAT", "0.0"),
                    ("stones_21k",    "FLOAT", "0.0"),
                    ("stones_22k",    "FLOAT", "0.0"),
                    ("stones_24k",    "FLOAT", "0.0"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard (safe_box_transaction stones) failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_employee_bonus_audit_columns(engine: Engine) -> None:
    """أعمدة تدقيق الحالة لجدول employee_bonus (state machine)."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "employee_bonus",
                [
                    ("rejected_at",  "DATETIME",     "NULL"),
                    ("rejected_by",  "VARCHAR(100)", "NULL"),
                    ("paid_by",      "VARCHAR(100)", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard (employee_bonus audit columns) failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_goal_achievement_columns(engine: Engine) -> None:
    """Add period_key / goal_period columns to goal_achievement for idempotent per-period tracking."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "goal_achievement",
                [
                    ("period_key",  "VARCHAR(30)", "NULL"),
                    ("goal_period", "VARCHAR(20)", "NULL"),
                ],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard (goal_achievement) failed: %s", exc)
        return

    _log_added(columns_added)


def ensure_bonus_accounts(engine: Engine) -> None:
    """ينشئ حسابات المكافآت المطلوبة إن لم تكن موجودة.
    
    - 2310: مكافآت مستحقة للموظفين  (خصوم متداولة ← أرصدة دائنة أخرى 23)
    - 5450: حساب مصروف المكافآت    (مصاريف إدارية ← 540) — يُنشأ فقط إن غاب
    """
    try:
        from sqlalchemy import text as _text
        with engine.connect() as conn:
            # حساب 2310 تحت 23 (أرصدة دائنة أخرى)
            exists_2310 = conn.execute(
                _text("SELECT id FROM account WHERE account_number='2310' LIMIT 1")
            ).fetchone()
            if not exists_2310:
                parent_23 = conn.execute(
                    _text("SELECT id FROM account WHERE account_number='23' LIMIT 1")
                ).fetchone()
                if parent_23:
                    conn.execute(_text("""
                        INSERT INTO account
                          (account_number, name, type, parent_id,
                           tracks_weight, transaction_type,
                           balance_cash, balance_18k, balance_21k,
                           balance_22k, balance_24k,
                           include_in_gram_profit, exclude_from_gram_profit)
                        VALUES
                          ('2310', 'مكافآت مستحقة للموظفين', 'Liability', :pid,
                           0, 'cash',
                           0.0, 0.0, 0.0, 0.0, 0.0,
                           0, 0)
                    """), {"pid": parent_23[0]})
                    conn.commit()
                    LOGGER.info("schema_guard: أنشأ حساب 2310 (مكافآت مستحقة للموظفين)")

            # حساب 5450 تحت 540 (مصاريف إدارية) — إن لم يكن موجوداً
            exists_5450 = conn.execute(
                _text("SELECT id FROM account WHERE account_number='5450' LIMIT 1")
            ).fetchone()
            if not exists_5450:
                parent_540 = conn.execute(
                    _text("SELECT id FROM account WHERE account_number='540' LIMIT 1")
                ).fetchone()
                if parent_540:
                    conn.execute(_text("""
                        INSERT INTO account
                          (account_number, name, type, parent_id,
                           is_active, tracks_weight, transaction_type,
                           balance_cash, balance_gold_21k)
                        VALUES
                          ('5450', 'حساب مصروف المكافآت', 'Expense', :pid,
                           1, 0, 'cash', 0.0, 0.0)
                    """), {"pid": parent_540[0]})
                    conn.commit()
                    LOGGER.info("schema_guard: أنشأ حساب 5450 (حساب مصروف المكافآت)")

    except Exception as exc:
        LOGGER.error("ensure_bonus_accounts failed: %s", exc)


def ensure_category_wage_column(engine: Engine) -> None:
    """Add default_wage column to category table if missing."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "category",
                [("default_wage", "FLOAT", "NULL")],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("Auto schema guard (category wage) failed: %s", exc)
        return
    _log_added(columns_added)


def ensure_invoice_gold24k_columns(engine: Engine) -> None:
    """Add gold24k settlement fields to invoice table if missing."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice",
                [
                    ("gold24k_settlement", "BOOLEAN", "0"),
                    ("gold24k_weight", "FLOAT", "0"),
                    ("gold24k_commission_per_gram", "FLOAT", "0"),
                    ("gold24k_commission_total", "FLOAT", "0"),
                ],
            )
        )
        _log_added(columns_added)
    except Exception as exc:
        LOGGER.error("ensure_invoice_gold24k_columns failed: %s", exc)


def ensure_invoice_karat_diff_columns(engine: Engine) -> None:
    """Add karat-diff settlement fields to invoice table if missing."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice",
                [
                    ("karat_diff_settlement", "BOOLEAN", "0"),
                    ("karat_diff_owed_karat", "FLOAT", "0"),
                    ("karat_diff_paid_karat", "FLOAT", "0"),
                    ("karat_diff_weight", "FLOAT", "0"),
                    ("karat_diff_per_gram", "FLOAT", "0"),
                    ("karat_diff_total", "FLOAT", "0"),
                    ("karat_diff_earn_total", "FLOAT", "0"),
                    ("karat_diff_pay_total", "FLOAT", "0"),
                ],
            )
        )
        _log_added(columns_added)
    except Exception as exc:
        LOGGER.error("ensure_invoice_karat_diff_columns failed: %s", exc)


def ensure_unique_reservation_invoice_index(engine: Engine) -> None:
    """Partial unique index: each invoice can only be linked to one reservation.
    Allows multiple NULLs (unsettled reservations).
    """
    INDEX_NAME = 'uq_office_reservation_purchase_invoice_id'
    try:
        with engine.connect() as conn:
            dialect = _dialect_name(engine, conn)
            if dialect != 'postgresql':
                return  # Only needed for PostgreSQL (SQLite handles this differently)
            exists = conn.execute(text(
                "SELECT 1 FROM pg_indexes WHERE indexname = :name"
            ), {'name': INDEX_NAME}).fetchone()
            if not exists:
                conn.execute(text(f"""
                    CREATE UNIQUE INDEX {INDEX_NAME}
                    ON office_reservation (purchase_invoice_id)
                    WHERE purchase_invoice_id IS NOT NULL
                """))
                conn.commit()
                LOGGER.info("schema_guard: created partial unique index %s", INDEX_NAME)
    except Exception as exc:
        LOGGER.error("ensure_unique_reservation_invoice_index failed: %s", exc)


def ensure_dashboard_performance_indexes(engine: Engine) -> None:
    """Critical indexes for admin dashboard query performance.

    Without these, every dashboard load does 6+ full sequential scans on the
    invoice table and full scans on journal_entry_line, causing 5-10s load times.
    """
    indexes = [
        # Most critical: dashboard queries always filter is_posted=true + date range
        (
            'idx_invoice_posted_date',
            'CREATE INDEX idx_invoice_posted_date ON invoice(date) WHERE is_posted = true',
        ),
        # Type + date range queries (sales/purchases summaries)
        (
            'idx_invoice_type_date_posted',
            'CREATE INDEX idx_invoice_type_date_posted ON invoice(invoice_type, date) WHERE is_posted = true',
        ),
        # InvoiceItem karat breakdown — in() lookup on invoice_id
        (
            'idx_invoice_item_invoice_id',
            'CREATE INDEX idx_invoice_item_invoice_id ON invoice_item(invoice_id)',
        ),
        # Customer type filter (liquidity section)
        (
            'idx_customer_type',
            'CREATE INDEX idx_customer_type ON customer(customer_type)',
        ),
        # GoldPrice latest lookup
        (
            'idx_gold_price_date_desc',
            'CREATE INDEX idx_gold_price_date_desc ON gold_price(date DESC)',
        ),
        # JournalEntryLine account lookup (safe box live balances)
        (
            'idx_jel_account_id',
            'CREATE INDEX idx_jel_account_id ON journal_entry_line(account_id)',
        ),
    ]
    try:
        with engine.connect() as conn:
            dialect = _dialect_name(engine, conn)
            if dialect != 'postgresql':
                return
            for index_name, ddl in indexes:
                exists = conn.execute(text(
                    "SELECT 1 FROM pg_indexes WHERE indexname = :name"
                ), {'name': index_name}).fetchone()
                if not exists:
                    try:
                        conn.execute(text(ddl))
                        conn.commit()
                        LOGGER.info("schema_guard: created index %s", index_name)
                    except Exception as exc:
                        conn.rollback()
                        LOGGER.warning("schema_guard: index %s failed: %s", index_name, exc)
    except Exception as exc:
        LOGGER.error("ensure_dashboard_performance_indexes failed: %s", exc)


def ensure_account_memo_pair_constraints(engine: Engine) -> None:
    """قيود قاعدة بيانات لعلاقة Account.memo_account_id (مالي<->وزني) --
    خط دفاع رابع بعد account_pair_service (الخدمة المركزية)، حارس
    Account._validate_memo_account_id (ORM)، وaudit_account_memo_invariants.py
    (التدقيق). يضمن سلامة العلاقة حتى لو تجاوز كود ما الـORM (SQL مباشر،
    استيراد بيانات، إلخ) -- وهي الفجوة الوحيدة التي لا يغطيها أي مما سبق.

    1) CHECK منع الإشارة الذاتية -- آمن للتطبيق فوراً (صفر مخالفات حالياً
       في كل الفحوصات التي أُجريت).
    2) UNIQUE جزئي (يسمح بعدة NULL) يمنع أكثر من حساب من الإشارة لنفس
       الهدف -- سيفشل وتُسجَّل المحاولة فقط (لا يوقف التطبيق، كباقي دوال
       هذا الملف) حتى تُصحَّح كل حالات duplicate_target الموجودة فعلياً
       عبر repair_all_memo_account_links.py/المراجعة اليدوية. لحظة نجاحه
       لأول مرة (عند أول إقلاع بعد تنظيف البيانات)، يصبح تكرار حادثة
       #1213 (ومثيلاتها التاريخية) مستحيلاً بنيوياً، لا ممنوعاً إجرائياً فقط.
    """
    check_ok = False
    unique_ok = False

    try:
        with engine.connect() as conn:
            dialect = _dialect_name(engine, conn)
            if dialect != 'postgresql':
                return
            exists = conn.execute(text(
                "SELECT 1 FROM pg_constraint WHERE conname = 'chk_account_memo_not_self'"
            )).fetchone()
            if exists:
                check_ok = True
            else:
                try:
                    conn.execute(text("""
                        ALTER TABLE account
                        ADD CONSTRAINT chk_account_memo_not_self
                        CHECK (memo_account_id IS NULL OR memo_account_id <> id)
                    """))
                    conn.commit()
                    check_ok = True
                except Exception as exc:
                    conn.rollback()
                    LOGGER.warning("schema_guard: chk_account_memo_not_self failed: %s", exc)
    except Exception as exc:
        LOGGER.error("ensure_account_memo_pair_constraints (check) failed: %s", exc)

    try:
        with engine.connect() as conn:
            dialect = _dialect_name(engine, conn)
            if dialect != 'postgresql':
                return
            exists = conn.execute(text(
                "SELECT 1 FROM pg_indexes WHERE indexname = 'uq_account_memo_account_id'"
            )).fetchone()
            if exists:
                unique_ok = True
            else:
                try:
                    conn.execute(text("""
                        CREATE UNIQUE INDEX uq_account_memo_account_id
                        ON account (memo_account_id)
                        WHERE memo_account_id IS NOT NULL
                    """))
                    conn.commit()
                    unique_ok = True
                except Exception as exc:
                    conn.rollback()
                    LOGGER.warning(
                        "schema_guard: uq_account_memo_account_id failed -- likely existing "
                        "duplicate_target rows not yet cleaned up (see "
                        "repair_all_memo_account_links.py): %s", exc,
                    )
    except Exception as exc:
        LOGGER.error("ensure_account_memo_pair_constraints (unique index) failed: %s", exc)

    protection_level = 'FULL' if (check_ok and unique_ok) else 'PARTIAL'
    check_line = '✓ CHECK(self_reference)' if check_ok else '✗ CHECK(self_reference) failed'
    unique_line = (
        '✓ UNIQUE(memo_account_id)' if unique_ok
        else '⚠ UNIQUE skipped (duplicate_target detected)'
    )
    suffix = '' if protection_level == 'FULL' else (
        ' -- run repair_all_memo_account_links.py then restart to reach FULL'
    )
    log_fn = LOGGER.info if protection_level == 'FULL' else LOGGER.warning
    log_fn(
        "Account memo pair constraints:\n  %s\n  %s\nProtection level: %s%s",
        check_line, unique_line, protection_level, suffix,
    )


def ensure_invoice_online_sale_columns(engine: Engine) -> None:
    """Add commerce_order_id to invoice table for ERP Sync (Sprint 8)."""
    columns_added: list[str] = []
    try:
        columns_added.extend(
            _ensure_columns(
                engine,
                "invoice",
                [("commerce_order_id", "VARCHAR(100)", "NULL")],
            )
        )
    except SQLAlchemyError as exc:
        LOGGER.error("ensure_invoice_online_sale_columns failed: %s", exc)
        return

    _log_added(columns_added)

    # Add unique index on commerce_order_id (partial: only for non-NULL rows).
    # Safe to call on every startup — CREATE UNIQUE INDEX IF NOT EXISTS is idempotent.
    if not columns_added:
        return
    try:
        with engine.connect() as conn:
            dialect = _dialect_name(engine, conn)
            if dialect in ('postgresql', 'postgres'):
                conn.execute(text(
                    "CREATE UNIQUE INDEX IF NOT EXISTS "
                    "idx_invoice_commerce_order_id "
                    "ON invoice(commerce_order_id) "
                    "WHERE commerce_order_id IS NOT NULL"
                ))
                conn.commit()
    except Exception as exc:
        LOGGER.warning("ensure_invoice_online_sale_columns index failed: %s", exc)
