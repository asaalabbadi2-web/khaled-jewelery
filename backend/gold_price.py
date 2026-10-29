from threading import Thread
import time
import os
import schedule
import requests
import datetime
from typing import Optional
from models import db


# ---------------------------------------------------------------------------
# Source 1 – Swissquote public forex feed (free, no API key, reliable)
# Returns XAU/USD bid/ask – we use mid-price as ounce price in USD.
# ---------------------------------------------------------------------------
def _fetch_from_swissquote() -> Optional[float]:
    """Fetch live gold ounce price from Swissquote public feed."""
    url = 'https://forex-data-feed.swissquote.com/public-quotes/bboquotes/instrument/XAU/USD'
    headers = {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                       'AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/120.0.0.0 Safari/537.36',
    }
    try:
        resp = requests.get(url, headers=headers, timeout=12)
        resp.raise_for_status()
        data = resp.json()
        if not data or not isinstance(data, list):
            return None
        prices = data[0].get('spreadProfilePrices', [])
        if not prices:
            return None
        bid = prices[0].get('bid', 0)
        ask = prices[0].get('ask', 0)
        if bid <= 0 or ask <= 0:
            return None
        mid = (bid + ask) / 2.0
        # Sanity check: gold is typically 500 – 15 000 USD/oz
        if mid < 500 or mid > 15000:
            print(f'[WARN] Swissquote mid-price {mid} out of sane range – ignoring.')
            return None
        print(f'[INFO] Swissquote gold price: ${mid:.2f}/oz (bid={bid}, ask={ask})')
        return mid
    except Exception as e:
        print(f'[WARN] Swissquote fetch failed: {e}')
        return None


# ---------------------------------------------------------------------------
# Source 2 – goldprice.org (original source, may 403 with rate-limiting)
# ---------------------------------------------------------------------------
def _fetch_from_goldprice_org() -> Optional[float]:
    """Fetch gold ounce price from goldprice.org API."""
    url = 'https://data-asg.goldprice.org/dbXRates/USD'
    headers = {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                       'AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/120.0.0.0 Safari/537.36',
    }
    try:
        resp = requests.get(url, headers=headers, timeout=10)
        resp.raise_for_status()
        data = resp.json()
        items = data.get('items')
        if items and len(items) > 0:
            price = items[0].get('xauPrice')
            if price is not None and float(price) > 0:
                print(f'[INFO] goldprice.org gold price: ${price}/oz')
                return float(price)
        return None
    except Exception as e:
        print(f'[WARN] goldprice.org fetch failed: {e}')
        return None


# ---------------------------------------------------------------------------
# Source 3 – Yahoo Finance (GC=F futures, requires yfinance)
# ---------------------------------------------------------------------------
def _fetch_from_yahoo() -> Optional[float]:
    """Fetch gold price from Yahoo Finance GC=F futures."""
    try:
        import yfinance as yf
        ticker = yf.Ticker('GC=F')
        data = ticker.history(period='1d')
        if data is not None and not data.empty:
            price = float(data['Close'].iloc[-1])
            if price > 0:
                print(f'[INFO] Yahoo Finance gold price: ${price:.2f}/oz')
                return price
        print('[WARN] Yahoo Finance returned no data for GC=F.')
        return None
    except Exception as e:
        print(f'[WARN] Yahoo Finance fetch failed: {e}')
        return None


# ---------------------------------------------------------------------------
# Aggregate fetcher – tries sources in priority order
# ---------------------------------------------------------------------------
def fetch_gold_price() -> Optional[float]:
    """Try multiple sources in order and return the first successful ounce price (USD)."""
    sources = [
        ('Swissquote', _fetch_from_swissquote),
        ('goldprice.org', _fetch_from_goldprice_org),
        ('Yahoo Finance', _fetch_from_yahoo),
    ]
    for name, fn in sources:
        try:
            price = fn()
            if price is not None and price > 0:
                return price
        except Exception as e:
            print(f'[ERROR] Unexpected error in {name}: {e}')
    # All sources failed – fall back to last DB value
    print('[WARN] All live gold price sources failed. Using last known DB price.')
    return get_last_known_price()


def get_last_known_price():
    """Fetches the most recent gold price from the database.
    
    Safe to call both inside and outside Flask app context.
    """
    try:
        from models import GoldPrice
        last_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
        if last_price:
            print(f'[INFO] Last known DB price: {last_price.price}')
            return last_price.price
    except RuntimeError:
        # Outside app context – cannot query DB.
        print('[WARN] get_last_known_price called outside app context – skipping.')
    except Exception as e:
        print(f'[WARN] get_last_known_price error: {e}')
    return None


def _push_to_commerce(price: float) -> None:
    """Push a fresh gold price to the Commerce API after saving it locally.

    Fire-and-forget: if Commerce is unreachable, we log a warning and
    continue — the ERP's own operation must never fail because of this.
    The Commerce gold_price table has no other writer, so a failed push
    means quotes become STALE within 90 s; the next scheduler cycle will
    restore freshness. This is an acceptable gap — it is logged for ops.
    """
    url = os.environ.get("COMMERCE_API_URL", "").rstrip("/")
    secret = os.environ.get("ERP_INTERNAL_SECRET", "")
    if not url or not secret:
        return
    try:
        import json, uuid, urllib.request
        corr_id = str(uuid.uuid4())
        body = json.dumps({"price": price}).encode()
        req = urllib.request.Request(
            f"{url}/api/internal/gold-price",
            data=body,
            headers={
                "Content-Type": "application/json",
                "X-Internal-Secret": secret,
                "X-Correlation-ID": corr_id,
            },
            method="POST",
        )
        resp = urllib.request.urlopen(req, timeout=5)
        print(f"[GoldPrice] pushed {price:.2f} to Commerce → HTTP {resp.status} correlation_id={corr_id}")
    except Exception as exc:
        print(f"[WARN] gold price push to Commerce failed: {exc}")


def _utc_now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)


def save_gold_price(app, price):
    with app.app_context():
        from models import GoldPrice
        from pricing.office_price import stamp
        now = _utc_now()
        # A price a minute (PRICE-LIVE-1): one fetched in the clock minute its last was
        # saved in replaces it -- the screens read the newest, the history keeps a price
        # a minute. The minute of the clock, not the row's age: it moves with each.
        minute = now.replace(second=0, microsecond=0)
        latest = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
        if latest is not None and latest.date and latest.date.replace(second=0, microsecond=0) == minute:
            latest.price, latest.date = price, now
            gp = stamp(latest)                          # with the office's terms of the moment (OFFICE-PRICE-1)
        else:
            gp = stamp(GoldPrice(price=price, date=now))
            db.session.add(gp)
        db.session.commit()
    _push_to_commerce(price)


# ---------------------------------------------------------------------------
# Scheduler – auto-update gold price at a configurable interval
# ---------------------------------------------------------------------------
def auto_update_gold_price(app):
    price = fetch_gold_price()
    if price:
        save_gold_price(app, price)
        print(f'[AutoUpdate] Gold price updated: ${price:.2f}/oz')
    else:
        print('[AutoUpdate] Failed to fetch gold price from all sources.')


def start_scheduler(app):
    schedule.every(1).minutes.do(auto_update_gold_price, app=app)

    def run():
        while True:
            schedule.run_pending()
            time.sleep(60)

    Thread(target=run, daemon=True).start()
