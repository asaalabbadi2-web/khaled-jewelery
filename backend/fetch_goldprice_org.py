def fetch_gold_price_from_goldprice():  # Removing this function
    pass  # This function is empty and will be removed
import requests
import re
from bs4 import BeautifulSoup

def fetch_gold_price_from_spot():
    url = "https://goldprice.org/spot-gold.html"
    response = requests.get(url)
    soup = BeautifulSoup(response.text, "html.parser")
    prices = re.findall(r"\d{4,}\.\d+", soup.text)
    if prices:
        return float(prices[0])
    return None

if __name__ == "__main__":
    price = fetch_gold_price_from_spot()
    print("Gold price per ounce (spot):", price)
