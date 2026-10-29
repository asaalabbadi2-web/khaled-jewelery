"""Auto-update gold price scheduler.

This scheduler reads configuration from the Settings row:
- gold_price_auto_update_enabled: bool
- gold_price_auto_update_mode: "interval" | "daily"
- gold_price_auto_update_interval_minutes: int
- gold_price_auto_update_time: "HH:MM" (server local time; used only for daily mode)

Note: This is designed for single-process deployments (or dev mode). In multi-worker
setups you should run this as a separate singleton service to avoid duplicate updates.
"""

from __future__ import annotations

import os
import time
from threading import Thread

import schedule

from gold_price import fetch_gold_price, save_gold_price
from models import GoldPrice, Settings, db


MIN_INTERVAL_SECONDS = 10


class GoldPriceScheduler:
    def __init__(self, app):
        self.app = app
        self.is_running = False
        self._last_config: tuple[bool, str, str] | None = None
        self._scheduler = schedule.Scheduler()

    def _read_config(self) -> tuple[bool, str, int]:
        with self.app.app_context():
            row = Settings.query.first()
            if not row:
                return False, "interval", 60
            enabled = bool(getattr(row, "gold_price_auto_update_enabled", False))
            mode = (getattr(row, "gold_price_auto_update_mode", None) or "interval").strip()
            interval = getattr(row, "gold_price_auto_update_interval_seconds", None)
            try:
                interval_seconds = int(interval) if interval is not None else 60
            except Exception:
                interval_seconds = 60
            return enabled, mode, interval_seconds

    def _apply_schedule(self, enabled: bool, mode: str, interval_seconds: int) -> None:
        self._scheduler.clear("gold_price")
        if not enabled:
            print("[GoldPriceScheduler] Auto-update disabled")
            return

        normalized = (mode or "interval").strip().lower()

        if normalized == "daily":
            at_time = "09:00"
            with self.app.app_context():
                row = Settings.query.first()
                if row:
                    at_time = (getattr(row, "gold_price_auto_update_time", None) or "09:00").strip()
            try:
                self._scheduler.every().day.at(at_time).do(self.update_from_internet).tag("gold_price")
                print(f"[GoldPriceScheduler] Auto-update enabled daily at {at_time}")
            except Exception as exc:
                print(f"[GoldPriceScheduler] Invalid daily time '{at_time}': {exc}")
            return

        # Default: interval mode, every N seconds -- 10 at the least: the source is a
        # public feed (PRICE-LIVE-1, the owner 29 Oct 2026: 15).
        try:
            seconds = int(interval_seconds)
        except Exception:
            seconds = 60
        seconds = max(seconds, MIN_INTERVAL_SECONDS)

        self._scheduler.every(seconds).seconds.do(self.update_from_internet).tag("gold_price")
        print(f"[GoldPriceScheduler] Auto-update enabled every {seconds} second(s)")

    def update_from_internet(self) -> None:
        with self.app.app_context():
            try:
                price = fetch_gold_price()
                if price is None:
                    print("[GoldPriceScheduler] No price fetched")
                    return

                # Keep behavior consistent with the manual update endpoint.
                save_gold_price(self.app, float(price))
                print(f"[GoldPriceScheduler] ✓ Gold price updated automatically: {price}")
            except Exception as exc:
                try:
                    db.session.rollback()
                except Exception:
                    pass
                print(f"[GoldPriceScheduler] ❌ Failed to auto-update gold price: {exc}")

    def start(self) -> None:
        if self.is_running:
            print("[GoldPriceScheduler] Scheduler already running")
            return

        self.is_running = True

        def run_loop() -> None:
            # Initial schedule build
            enabled, mode, interval_seconds = self._read_config()
            self._last_config = (enabled, mode, str(interval_seconds))
            self._apply_schedule(enabled, mode, interval_seconds)
            last_read = time.monotonic()

            while self.is_running:
                # Re-read config every 30 seconds and re-schedule if changed; run what
                # is due every second (an interval may be 15 seconds).
                if time.monotonic() - last_read >= 30:
                    last_read = time.monotonic()
                    try:
                        enabled_now, mode_now, interval_now = self._read_config()
                        fingerprint = (enabled_now, mode_now, str(interval_now))
                        if self._last_config != fingerprint:
                            self._last_config = fingerprint
                            self._apply_schedule(enabled_now, mode_now, interval_now)
                    except Exception as exc:
                        print(f"[GoldPriceScheduler] Config read failed: {exc}")

                self._scheduler.run_pending()
                time.sleep(1)

        Thread(target=run_loop, daemon=True).start()
        print("[GoldPriceScheduler] 🚀 Started")

    def stop(self) -> None:
        self.is_running = False
        self._scheduler.clear("gold_price")
        print("[GoldPriceScheduler] ⏸️ Stopped")


_scheduler_instance: GoldPriceScheduler | None = None


def get_gold_price_scheduler(app) -> GoldPriceScheduler:
    global _scheduler_instance
    if _scheduler_instance is None:
        _scheduler_instance = GoldPriceScheduler(app)
    return _scheduler_instance


def start_gold_price_scheduler(app):
    # Avoid double-start under Werkzeug reloader in debug mode
    if app.debug and os.environ.get("WERKZEUG_RUN_MAIN") != "true":
        return None

    scheduler = get_gold_price_scheduler(app)
    scheduler.start()
    return scheduler
