from __future__ import annotations

from datetime import datetime

from models import db, Settings


def _get_settings_singleton(create_if_missing: bool = True) -> Settings | None:
    """Return the canonical Settings row, deterministically deduplicating if needed."""

    rows = Settings.query.order_by(Settings.id.asc()).all()
    if not rows:
        if not create_if_missing:
            return None
        row = Settings()   # no main karat until one is chosen: nothing is weighed on a guess
        db.session.add(row)
        db.session.commit()
        return row

    def _sort_key(s: Settings):
        dt = getattr(s, 'updated_at', None) or getattr(s, 'created_at', None)
        if dt is None:
            dt = datetime.min
        return (dt, int(getattr(s, 'id', 0) or 0))

    canonical = max(rows, key=_sort_key)

    if len(rows) > 1:
        def _is_blank(v) -> bool:
            if v is None:
                return True
            if isinstance(v, str) and not v.strip():
                return True
            return False

        merged_any = False
        for other in rows:
            if other.id == canonical.id:
                continue

            for attr in (
                'main_karat',
                'currency_symbol',
                'manufacturing_wage_mode',
                'tax_rate',
                'tax_enabled',
                'vat_exempt_karats',
                'invoice_prefix',
                'show_company_logo',
                'company_name',
                'company_logo_base64',
                'company_address',
                'company_phone',
                'company_tax_number',
                'company_cr_number',
                'print_template_by_invoice_type',
                'decimal_places',
                'date_format',
                'default_discount_rate',
                'allow_discount',
                'allow_manual_invoice_items',
                'require_auth_for_invoice_create',
                'idle_timeout_enabled',
                'idle_timeout_minutes',
                'allow_partial_invoice_payments',
                'employee_cash_safes_enabled',
                'employee_gold_safes_enabled',
                'main_cash_safe_box_id',
                'sale_gold_safe_box_id',
                'main_scrap_gold_safe_box_id',
                'auto_post_invoices',
                'auto_post_entries',
                'require_approval_before_post',
                'allow_unposting',
                'voucher_auto_post',
                'weight_closing_settings',
                'gold_price_auto_update_enabled',
                'gold_price_auto_update_time',
                'gold_price_auto_update_mode',
                'gold_price_auto_update_interval_minutes',
                'backup_auto_enabled',
                'backup_auto_mode',
                'backup_auto_time',
                'backup_auto_interval_minutes',
                'backup_retention_count',
                'password_policy',
                'disable_startup_bootstrap',
                'weekly_sales_target_weight',
                'monthly_sales_target_weight',
                'sales_race_settings',
            ):
                try:
                    current = getattr(canonical, attr)
                    incoming = getattr(other, attr)
                except Exception:
                    continue

                if _is_blank(current) and not _is_blank(incoming):
                    try:
                        setattr(canonical, attr, incoming)
                        merged_any = True
                    except Exception:
                        pass

            try:
                db.session.delete(other)
            except Exception:
                pass

        if merged_any:
            db.session.add(canonical)
        db.session.commit()

    return canonical
