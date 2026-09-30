"""The authentication clock is UTC: a duration must not jump with the time zone.

auth_decorators._now() was datetime.now() -- local time -- and measured the
idle timeout (now - last activity) and the blacklist TTL (token exp, a UTC
epoch, minus now). In production the zone never changes, so it looked right;
but the CI runner (UTC) running a test that switches to Asia/Riyadh saw every
session three hours idle and expired it (30 Sep 2026), and the TTL was three
hours too long all along. Every other stored time in this database is UTC.

Run:
    python -m pytest tests/test_auth_clock_is_utc.py -v
"""
import time
from datetime import datetime


def test_the_auth_clock_ignores_the_local_time_zone(monkeypatch):
    import auth_decorators
    for zone in ('Asia/Riyadh', 'UTC', 'America/New_York'):
        monkeypatch.setenv('TZ', zone)
        time.tzset()
        try:
            assert abs((auth_decorators._now() - datetime.utcnow()).total_seconds()) < 5, zone
        finally:
            monkeypatch.delenv('TZ')
            time.tzset()
