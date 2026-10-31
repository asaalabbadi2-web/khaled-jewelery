from threading import Thread
import time
import os
import schedule
import requests
import datetime
from typing import NamedTuple, Optional
from models import db


class Quote(NamedTuple):
    """A source's ounce price and when it last quoted it (PRICE-MARKET-1): the
    market is closed when that moment is old. at is None when the source does
    not say -- such a quote cannot be judged and is taken as live."""
    price: float
    at: Optional[datetime.datetime]     # UTC, naive
    source: str


def _utc_from_ms(ms) -> Optional[datetime.datetime]:
    try:
        return datetime.datetime.fromtimestamp(float(ms) / 1000.0, tz=datetime.timezone.utc).replace(tzinfo=None)
    except (TypeError, ValueError, OverflowError, OSError):
        return None


# ---------------------------------------------------------------------------
# Source 1 – Swissquote public forex feed (free, no API key, reliable)
# Returns XAU/USD bid/ask – we use mid-price as ounce price in USD.
# ---------------------------------------------------------------------------
def _fetch_from_swissquote() -> Optional[Quote]:
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
        # ts: its last quote -- Friday's close all weekend (PRICE-MARKET-1).
        return Quote(mid, _utc_from_ms(data[0].get('ts')), 'Swissquote')
    except Exception as e:
        print(f'[WARN] Swissquote fetch failed: {e}')
        return None


# ---------------------------------------------------------------------------
# Source 2 – goldprice.org (original source, may 403 with rate-limiting)
# ---------------------------------------------------------------------------
def _fetch_from_goldprice_org() -> Optional[Quote]:
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
                return Quote(float(price), _utc_from_ms(data.get('tsj')), 'goldprice.org')
        return None
    except Exception as e:
        print(f'[WARN] goldprice.org fetch failed: {e}')
        return None


# ---------------------------------------------------------------------------
# Source 3 – Yahoo Finance (GC=F futures, requires yfinance)
# ---------------------------------------------------------------------------
def _fetch_from_yahoo() -> Optional[Quote]:
    """Fetch gold price from Yahoo Finance GC=F futures."""
    try:
        import yfinance as yf
        ticker = yf.Ticker('GC=F')
        data = ticker.history(period='1d')
        if data is not None and not data.empty:
            price = float(data['Close'].iloc[-1])
            if price > 0:
                print(f'[INFO] Yahoo Finance gold price: ${price:.2f}/oz')
                return Quote(price, None, 'Yahoo Finance')     # a day's close: it does not say when
        print('[WARN] Yahoo Finance returned no data for GC=F.')
        return None
    except Exception as e:
        print(f'[WARN] Yahoo Finance fetch failed: {e}')
        return None


# ---------------------------------------------------------------------------
# Aggregate fetcher – tries sources in priority order
# ---------------------------------------------------------------------------
def fetch_gold_quote() -> Optional[Quote]:
    """The first source that answers, with when it last quoted (PRICE-MARKET-1)."""
    sources = [
        ('Swissquote', _fetch_from_swissquote),
        ('goldprice.org', _fetch_from_goldprice_org),
        ('Yahoo Finance', _fetch_from_yahoo),
    ]
    for name, fn in sources:
        try:
            quote = fn()
            if quote is not None and quote.price > 0:
                return quote
        except Exception as e:
            print(f'[ERROR] Unexpected error in {name}: {e}')
    print('[WARN] All live gold price sources failed.')
    return None


def fetch_gold_price() -> Optional[float]:
    """The first source's ounce price (USD), or None when none answers.

    It returned the last saved price when every source failed, and its callers
    saved it as a new one: a stale price that read as live (31 Oct 2026)."""
    quote = fetch_gold_quote()
    return quote.price if quote is not None else None


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
# The market, open or closed, as its source says (PRICE-MARKET-1)
# ---------------------------------------------------------------------------
# The owner, 31 Oct 2026: «سعر الذهب العالمي يغلق في عطلة نهاية الأسبوع وغيرها،
# أليس من الأفضل أن يُسجَّل مغلق بدل التحديث التلقائي دون جدوى؟» -- each weekend
# saved ~1,300 rows a day at one price. The source says when it last quoted:
# older than the policy's minutes, the market is closed -- the weekend, a
# holiday, the summer hour's change alike, no calendar of them kept here.

def closed_after() -> datetime.timedelta:
    """POLICY: how old the source's last quote may be and the market still open."""
    try:
        return datetime.timedelta(minutes=max(float(os.getenv('GOLD_MARKET_CLOSED_AFTER_MINUTES', 15)), 1.0))
    except ValueError:
        return datetime.timedelta(minutes=15)


def closed_check_every() -> datetime.timedelta:
    """POLICY: how often a closed market's source is asked whether it opened."""
    try:
        return datetime.timedelta(seconds=max(float(os.getenv('GOLD_MARKET_CLOSED_CHECK_SECONDS', 300)), 15.0))
    except ValueError:
        return datetime.timedelta(seconds=300)


def market_answer(state) -> dict:
    """The market as the screens read it."""
    from pricing import price_clock
    if state is None:
        return {'open': True, 'last_quote_at': None, 'checked_at': None, 'unavailable': False}
    return {
        'open': state.is_open is not False,
        'last_quote_at': price_clock.iso_utc(state.last_quote_at) if state.last_quote_at else None,
        'checked_at': price_clock.iso_utc(state.checked_at) if state.checked_at else None,
        'unavailable': state.unavailable_since is not None,
    }


def refresh_due(now: datetime.datetime) -> bool:
    """Whether the source is to be asked now: always while the market is open;
    while it is closed, once in closed_check_every."""
    from models import GoldMarketState
    state = GoldMarketState.query.first()
    if state is None or state.is_open is not False or state.checked_at is None:
        return True
    return now - state.checked_at >= closed_check_every()


def refresh_gold_price(app, fetch=None) -> str:
    """Ask the source and keep what it says: 'saved' (open, a price saved),
    'closed' (its last quote is old: nothing saved), 'unavailable' (no source
    answered: nothing saved, the last price not passed off as new)."""
    from models import GoldMarketState
    from pricing import price_clock
    with app.app_context():
        now = price_clock.utc_now()
        quote = (fetch or fetch_gold_quote)()
        state = GoldMarketState.query.first()
        if state is None:
            state = GoldMarketState()
            db.session.add(state)
        state.checked_at = now
        if quote is None:
            state.unavailable_since = state.unavailable_since or now
            db.session.commit()
            return 'unavailable'
        state.unavailable_since = None
        state.source = quote.source
        state.last_quote_at = quote.at
        state.is_open = quote.at is None or now - quote.at <= closed_after()
        is_open = state.is_open
        db.session.commit()
    if is_open:
        save_gold_price(app, quote.price)
        return 'saved'
    _push_to_commerce(quote.price)      # the storefront keeps its last price, as it did
    return 'closed'


def keep_commerce_fresh(app) -> None:
    """While the market is closed and not asked, the storefront still hears the
    last price at each tick -- it reads a price older than 90 s as stale."""
    if not (os.environ.get('COMMERCE_API_URL') and os.environ.get('ERP_INTERNAL_SECRET')):
        return
    with app.app_context():
        from models import GoldPrice
        latest = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
        price = latest.price if latest else None
    if price:
        _push_to_commerce(price)


# ---------------------------------------------------------------------------
# Scheduler – auto-update gold price at a configurable interval
# ---------------------------------------------------------------------------
def auto_update_gold_price(app):
    print(f'[AutoUpdate] gold price: {refresh_gold_price(app)}')


def start_scheduler(app):
    schedule.every(1).minutes.do(auto_update_gold_price, app=app)

    def run():
        while True:
            schedule.run_pending()
            time.sleep(60)

    Thread(target=run, daemon=True).start()
