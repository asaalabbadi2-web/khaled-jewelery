"""The gold price scheduler alone, for the local copy (scripts/local-copy-from-latest-backup.sh).

Production runs every scheduler in its own container (backend/run_schedulers.py);
gunicorn starts none. The local copy needs the price to move as it does there
(PRICE-LIVE-1, every 15 seconds) -- and only that: the clearing settlement
would post vouchers into the copy, the backup would write files.

    python scripts/local_gold_price_scheduler.py      (DATABASE_URL set)
"""
import os
import sys
import time

BACKEND = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'backend')
sys.path.insert(0, os.path.abspath(BACKEND))
os.chdir(os.path.abspath(BACKEND))

from app import app  # noqa: E402
from gold_price_scheduler import start_gold_price_scheduler  # noqa: E402

if __name__ == '__main__':
    start_gold_price_scheduler(app)
    print('[local] gold price scheduler running', flush=True)
    while True:
        time.sleep(3600)
