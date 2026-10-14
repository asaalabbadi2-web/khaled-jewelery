"""CHART-002 step 4c4: «is this a weight account?» is its mark (tracks_weight), the
twin is its link, and the numbering rule «7 + number» lives in accounting/twins.py.

The owner, 14 Oct 2026: the rule stays for 2027, in one function. It was written
out in some twenty places, and the writer of every entry line judged a weight
account by its first digit.
"""
import pathlib
import re
import uuid
from datetime import datetime

import pytest

from app import app as flask_app
from models import Account, JournalEntry, db

BACKEND = pathlib.Path(__file__).resolve().parents[1]
RULE = re.compile(r"""startswith\(\s*['"]7['"]|f['"]7\{|['"]7['"]\s*\+""")
# Not yet theirs: the reports (CHART-002 release 5); a repair applied in 2026 (history);
# the scenario matrix, which runs the code before this release too.
ALLOWED = {'routes/reports.py': 1, 'services/repair/chart_001.py': 1, 'tools/scenario_matrix.py': 1}
SKIP = {'venv', 'tests', 'alembic', '__pycache__', '.pytest_db'}


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app
        db.session.remove()


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_the_twin_rule_is_written_in_one_place():
    found = {}
    for path in BACKEND.rglob('*.py'):
        rel = path.relative_to(BACKEND)
        if set(rel.parts) & SKIP or rel.name.startswith('test_') or str(rel) == 'accounting/twins.py':
            continue
        n = len(RULE.findall(path.read_text(encoding='utf-8', errors='ignore')))
        if n:
            found[str(rel)] = n
    assert {f: n for f, n in found.items() if n > ALLOWED.get(f, 0)} == {}, found
    assert {f: n for f, n in ALLOWED.items() if found.get(f, 0) < n} == {}, 'shrink ALLOWED'


def test_a_weight_account_is_known_by_its_mark_not_its_first_digit():
    from dual_system_helpers import create_dual_journal_entry
    n = uuid.uuid4().int % 10**6
    weighed = Account(account_number=f'88{n:06d}', name='وزني بلا سبعة', type='Asset', transaction_type='gold',
                      tracks_weight=True)
    db.session.add(weighed)
    je = JournalEntry(entry_number=f'T-{uuid.uuid4().hex[:10]}', date=datetime(2026, 10, 14), description='t',
                      entry_type='عادي', is_posted=False)
    db.session.add(je)
    db.session.flush()

    line = create_dual_journal_entry(journal_entry_id=je.id, account_id=weighed.id, debit_21k=2.0)

    assert line.debit_weight and line.debit_weight > 0


def test_the_twin_number_is_the_rule():
    from accounting.twins import financial_number_of, numbered_as_twin, twin_number
    assert twin_number('1200022') == '71200022'
    assert financial_number_of('71200022') == '1200022'
    assert financial_number_of('1200022') is None
    assert numbered_as_twin('7210') and not numbered_as_twin('210')
