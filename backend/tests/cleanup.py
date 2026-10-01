"""Test cleanup that deletes posted entries, invoices or vouchers wholesale (UNPOST-001 U3).

Such a cleanup is a purge, and only a purge may do it: journal_entry_guard
refuses bulk deletes of entries, invoices and vouchers, and the database
trigger refuses deleting a posted entry. purge(lambda: ...) runs one cleanup
step inside journal_entry_guard.system_purge(); the setting it opens lasts
until the cleanup's commit. Tests only -- production code is confined to the
system resets (tests/test_posted_entry_immutable.py).
"""
from journal_entry_guard import system_purge
from models import db


def purge(step):
    with system_purge(db.session, 'test cleanup'):
        return step()
