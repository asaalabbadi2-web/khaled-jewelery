import time


def start_all_schedulers(app):
	"""Start all background schedulers.

	In production (gunicorn multi-worker), do NOT run this inside the web workers.
	Run it in a dedicated process/container (see docker-compose.prod.yml).
	"""
	# Bonus scheduler (optional)
	try:
		from bonus_scheduler import start_bonus_scheduler
		start_bonus_scheduler(app)
	except Exception as exc:
		print(f"[WARNING] Bonus scheduler not started: {exc}")

	# Gold price scheduler
	try:
		from gold_price_scheduler import start_gold_price_scheduler
		start_gold_price_scheduler(app)
	except Exception as exc:
		print(f"[WARNING] Gold price scheduler not started: {exc}")

	# Backup scheduler
	try:
		from backup_scheduler import start_backup_scheduler
		start_backup_scheduler(app)
	except Exception as exc:
		print(f"[WARNING] Backup scheduler not started: {exc}")

	# Clearing settlement scheduler
	try:
		from clearing_settlement_scheduler import start_clearing_settlement_scheduler
		start_clearing_settlement_scheduler(app)
	except Exception as exc:
		print(f"[WARNING] Clearing settlement scheduler not started: {exc}")


def run_forever(poll_seconds: float = 3600.0):
	"""Keep the scheduler process alive."""
	while True:
		time.sleep(poll_seconds)
