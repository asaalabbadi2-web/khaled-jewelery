from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from webdriver_manager.chrome import ChromeDriverManager
import time
from threading import Thread
import os
import schedule
import requests
from bs4 import BeautifulSoup
import datetime
from models import db

def fetch_gold_price():
    """
    Fetches the gold price from the goldprice.org API.
    The new logic directly accesses the first item in the list.
    """
    try:
        url = "https://data-asg.goldprice.org/dbXRates/USD"
        headers = {
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36'
        }
        response = requests.get(url, headers=headers)
        response.raise_for_status()
        data = response.json()

        # Directly access the price from the first item in the list
        if data.get('items') and len(data['items']) > 0:
            price = data['items'][0].get('xauPrice')
            if price is not None:
                print(f"[INFO] Gold price fetched successfully: {price}")
                return float(price)

        print("[ERROR] 'xauPrice' not found in API response.")
        return fetch_gold_price_fallback()

    except requests.exceptions.RequestException as e:
        print(f"[ERROR] Exception in fetch_gold_price (goldprice.org API): {e}")
        return fetch_gold_price_fallback()
    except (ValueError, KeyError, IndexError) as e:
        print(f"[ERROR] Error parsing goldprice.org API response: {e}")
        return fetch_gold_price_fallback()

def fetch_gold_price_fallback():
    # في حالة الفشل، حاول استخدام Yahoo Finance كبديل
    print("[INFO] Attempting to fetch gold price from Yahoo Finance as a fallback.")
    import yfinance as yf
    try:
        ticker = yf.Ticker("GC=F")
        data = ticker.history(period="1d")
        if not data.empty:
            price = data['Close'].iloc[-1]
            return float(price)
        else:
            print("[ERROR] لا توجد بيانات من Yahoo Finance.")
            return get_last_known_price()
    except Exception as e_yahoo:
        print(f"[ERROR] Exception in fetch_gold_price (Yahoo): {e_yahoo}")
        return get_last_known_price()

def get_last_known_price():
    """Fetches the most recent gold price from the database."""
    from backend.models import GoldPrice
    print("[INFO] Fetching last known gold price from database.")
    last_price = GoldPrice.query.order_by(GoldPrice.date.desc()).first()
    if last_price:
        print(f"[INFO] Found last known price: {last_price.price}")
        return last_price.price
    else:
        print("[WARNING] No gold price found in the database.")
        return None

def save_gold_price(app, price):
    with app.app_context():
        from backend.models import GoldPrice
        gp = GoldPrice(price=price, date=datetime.datetime.now())
        db.session.add(gp)
        db.session.commit()


# جدولة تحديث تلقائي لسعر الذهب كل ساعة
def auto_update_gold_price(app):
    price = fetch_gold_price()
    if price:
        save_gold_price(app, price)
        print(f"[AutoUpdate] تم تحديث سعر الذهب تلقائياً: {price}")
    else:
        print("[AutoUpdate] لم يتم جلب سعر الذهب.")

def start_scheduler(app):
    # Pass the app instance to the job
    schedule.every(1).minutes.do(auto_update_gold_price, app=app)
    def run():
        while True:
            schedule.run_pending()
            time.sleep(60)
    Thread(target=run, daemon=True).start()


# class GoldPrice(db.Model):
#     id = db.Column(db.Integer, primary_key=True)
#     price = db.Column(db.Float, nullable=False)
#     date = db.Column(db.DateTime, default=db.func.now())
