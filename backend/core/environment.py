"""Which environment this is -- one answer (RESET-1, COSTING-LOCK-1).

Production refuses the wipes and the zeroing of the moving average whatever
else the environment says; this is the one place that says what production is.
"""
from __future__ import annotations

import os

_NAMES = ('YASAR_ENV', 'APP_ENV', 'ENV', 'FLASK_ENV', 'PYTHON_ENV')


def is_production() -> bool:
    for name in _NAMES:
        value = (os.getenv(name) or '').strip().lower()
        if value:
            return value in ('prod', 'production')
    return False
