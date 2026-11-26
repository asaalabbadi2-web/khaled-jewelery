"""The main karat is not changed once the books carry a weight (D9, the owner; ADR-105).

Every weight the books equate is written in the main karat at its writing and
never rewritten (dual_system_helpers' debit_weight / credit_weight, the
weight_main_karat columns, the analytics): changed after them, it would mix two
units in one ledger. A journal line carrying a weight in any karat -- posted or
not, deleted or not: it was written in the main karat all the same -- locks it.
A new book, before its first weighed line (the 2027 database, ADR-044), chooses
it freely.
"""
from sqlalchemy import or_

from models import JournalEntryLine, db

_WEIGHTS = ('debit_18k', 'credit_18k', 'debit_21k', 'credit_21k', 'debit_22k', 'credit_22k',
            'debit_24k', 'credit_24k', 'debit_weight', 'credit_weight')


def weighed():
    """A journal line carrying a weight in any karat -- the filter."""
    return or_(*[getattr(JournalEntryLine, c) != 0 for c in _WEIGHTS])


def locked() -> bool:
    """Whether any journal line carries a weight."""
    return db.session.query(JournalEntryLine.query.filter(weighed()).exists()).scalar()
