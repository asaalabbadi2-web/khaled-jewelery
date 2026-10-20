"""The main karat is the settings', never a fixed one (the owner, 20 Oct 2026).

«يمنع استخدام عيار ثابت كعيار رئيسي، فقط ديناميكي من الإعدادات» -- and when
the settings hold none: «يرفض العمل إن لم يُضبط». Measured 20 Oct 2026: the
server stood 21 in for an unset main karat about a hundred times -- a config
constant, `get_main_karat() or 21`, `.get('main_karat', 21)`, parameters
defaulting to 21, a process-wide cache, and conversions dividing by 21 outright
(the average gold cost, two invoice fallbacks, two repair tools): right only
while the setting is 21.

The law: one reader, `pricing.gold_price_service.get_main_karat()`, reads the
setting; with none (or one that is no karat) it raises MainKaratNotSet, and a
request that needs it is refused `main_karat_not_set`, saying where it is set.
A karat's own fineness (`convert_to_main_karat(w21, 21)`) is no main karat.

The ratchet holds each live file at what it has (main_karat_baseline.json);
a new fixed main karat, or a new file with one, fails. Migrations are history;
tests may name 21.

Run:
    python -m pytest tests/test_main_karat_is_the_settings.py -v
"""
import json
import os
import re

import pytest

from app import app as flask_app
from models import Account, SafeBox, Settings, db

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'main_karat_baseline.json')
SKIP_DIRS = {'venv', 'tests', 'alembic', 'devtools', '__pycache__', '.pg_backups', 'node_modules', 'scripts'}

_MAIN = r'(?:main_karat\w*|MAIN_KARAT\w*|_?mk\w*|main_k\w*|main)'
FIXED = [
    re.compile(r'\bMAIN_KARAT\b'),                                           # the config constant
    re.compile(_MAIN + r'\)?\s*or\s*21(\.0)?\b'),                            # x or 21
    re.compile(r'get_main_karat\(\)\)?\s*or\s*21(\.0)?\b'),
    re.compile(r"""['"](?:main_karat|MAIN_KARAT)['"]\s*,\s*21(\.0)?\b"""),   # .get('main_karat', 21)
    re.compile(r'\b' + _MAIN + r'\s*(?::\s*\w+\s*)?=\s*21(\.0)?\b(?!\s*[*/+-])'),   # main = 21 / x: float = 21.0
    re.compile(r'\(\s*(?:getattr\([^)]*main_karat[^)]*\)|get_main_karat\(\)|[\w.]*' + _MAIN + r')\s*,\s*21(\.0)?\)'),
    # ^ _to_float(main_karat, 21.0) -- not convert_to_main_karat(w21, 21), a karat's own fineness
    re.compile(r'main_karat[^\n]*default\s*=\s*21(\.0)?\b'),                   # a column defaulting to 21
    re.compile(r'^\s*return\s+(int\()?21(\.0)?\)?\s*$'),                       # except: return 21
    re.compile(r'(?<![\d/])/\s*21(\.0)?\b(?!\s*/)'),                         # dividing by 21 (not 18/21/22)
]


def _live_files():
    for root, dirs, files in os.walk(BACKEND):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith('.')]
        for name in files:
            if name.endswith('.py') and not name.startswith('test_') and name != 'conftest.py':
                yield os.path.join(root, name)


def _fixed_main_karats() -> dict:
    found = {}
    for path in _live_files():
        with open(path, encoding='utf-8') as fh:
            n = sum(1 for line in fh
                    if not line.lstrip().startswith('#') and any(p.search(line) for p in FIXED))
        if n:
            found[os.path.relpath(path, BACKEND)] = n
    return found


def test_no_file_holds_more_fixed_main_karats_than_its_baseline():
    with open(BASELINE, encoding='utf-8') as fh:
        baseline = json.load(fh)
    over = {f: (n, baseline.get(f, 0)) for f, n in _fixed_main_karats().items() if n > baseline.get(f, 0)}
    assert not over, f'a fixed main karat (file: (now, allowed)): {over}'


@pytest.fixture
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture
def settings(app, db_fence):
    row = Settings.query.order_by(Settings.id.asc()).first()
    if row is None:
        row = Settings()
        db.session.add(row)
        db.session.flush()
    return row


def test_with_no_main_karat_set_the_reader_refuses(settings):
    from pricing.gold_price_service import MainKaratNotSet, get_main_karat
    settings.main_karat = None
    db.session.flush()
    with pytest.raises(MainKaratNotSet):
        get_main_karat()


def test_with_no_main_karat_set_a_request_that_needs_it_is_refused(settings, auth_headers):
    settings.main_karat = None
    db.session.flush()
    safe = SafeBox.query.first()
    if safe is None:
        safe = SafeBox(name='خزينة', safe_type='cash', account_id=Account.query.first().id)
        db.session.add(safe)
        db.session.flush()
    resp = flask_app.test_client().get(f'/api/safe-boxes/{safe.id}/balance', headers=auth_headers)
    assert resp.status_code == 409, resp.get_data(as_text=True)[:300]
    body = resp.get_json()
    assert body['error'] == 'main_karat_not_set'
    assert 'الإعدادات' in body['message']


def test_the_average_gold_cost_is_in_the_settings_karat(settings):
    """gold_cost turned grams into the main karat by a constant 21."""
    from services.gold_cost import _grams
    settings.main_karat = 18
    db.session.flush()

    class Line:
        debit_18k, debit_21k, debit_22k, debit_24k = 0.0, 0.0, 0.0, 9.0
        credit_18k = credit_21k = credit_22k = credit_24k = 0.0
    assert _grams(Line()) == pytest.approx(12.0)


def test_resetting_the_settings_keeps_the_main_karat(settings, auth_headers):
    """«إعادة تعيين الإعدادات» wrote 21 over whatever karat the shop keeps."""
    from routes.system import _reset_settings
    settings.main_karat = 18
    db.session.flush()
    _reset_settings()
    assert Settings.query.first().main_karat == 18


@pytest.mark.parametrize('value', [20, None, 'x'])
def test_a_main_karat_that_is_no_karat_is_not_saved(settings, auth_headers, value):
    settings.main_karat = 21
    db.session.flush()
    resp = flask_app.test_client().put('/api/settings', headers=auth_headers, json={'main_karat': value})
    assert resp.status_code == 400, resp.get_data(as_text=True)[:300]
    assert resp.get_json()['error'] == 'invalid_main_karat'
    db.session.expire_all()
    assert Settings.query.first().main_karat == 21
