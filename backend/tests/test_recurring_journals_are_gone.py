"""«القيود الدورية» gone -- the period expenses do their work (ADR-090, phase 11).

It wrote an entry from a fixed template: no balance, no voucher, no lock, no
weight; on production no template, no entry pointing at one, and a screen
that hard-coded a local address. One canonical implementation: the period
expenses (ADR-090) and their nightly accrual. This holds it gone.

Run:
    python -m pytest tests/test_recurring_journals_are_gone.py -v
"""
import importlib.util
import os

from app import app as flask_app
from models import JournalEntry, db

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def test_no_route_no_module_no_table():
    assert importlib.util.find_spec('recurring_journal_system') is None
    assert importlib.util.find_spec('recurring_journal_routes') is None
    assert not [r for r in flask_app.url_map.iter_rules() if 'recurring' in r.rule]
    assert not {'recurring_journal_template', 'recurring_journal_line'} & set(db.metadata.tables)
    assert 'recurring_template_id' not in JournalEntry.__table__.columns


def test_no_screen_offers_it():
    lib = os.path.join(ROOT, 'frontend', 'lib')
    mentions = []
    for base, _, files in os.walk(lib):
        for name in files:
            if name.endswith('.dart'):
                path = os.path.join(base, name)
                text = open(path, encoding='utf-8').read()
                if 'RecurringTemplate' in text or "'recurring_entries'" in text or 'القيود الدورية' in text:
                    mentions.append(os.path.relpath(path, lib))
    assert mentions == []
