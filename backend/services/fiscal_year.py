"""A financial year's own documents (ADR-044): each year is its own database.

The owner, 12 Oct 2026: a return is of an invoice of its own year -- «المرتجع
لا يكون إلا لفاتورة من سنته» -- a 2026 sale returned in 2027 is refused. In
2027's database a 2026 invoice is not there at all; the rule is where both can
meet: a return dated in a new year against an invoice of the year before.
"""
from __future__ import annotations


class ReturnOfAnotherYear(ValueError):
    pass


def refuse_return_of_another_year(original_date, return_date) -> None:
    """Refuse a return whose date's year is not its original's."""
    if original_date is None or return_date is None:
        return
    if original_date.year != return_date.year:
        raise ReturnOfAnotherYear(
            f'المرتجع لا يكون إلا لفاتورة من سنته: الفاتورة الأصلية من {original_date.year}، '
            f'والمرتجع بتاريخ {return_date.year} (ADR-044)')
