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


# ── A closed year's archive (ADR-044 phase 2) ──────────────────────────────
# The owner, 12 Oct 2026: a second instance, read only, on the closed year's
# database; 7 Nov: every user with his permissions. It runs with ARCHIVE_YEAR
# set; the database role it signs in with writes nothing but the sign-in's own
# rows (ops/archive/readonly_role.sql) -- the same three paths stay open here.
ARCHIVE_WRITABLE = frozenset({'/api/auth/login', '/api/auth/logout', '/api/auth/refresh', '/api/auth/2fa/verify'})
READING = frozenset({'GET', 'HEAD', 'OPTIONS'})


def archive_year() -> int | None:
    """The closed year this instance shows, or None: a working year's."""
    import os
    value = (os.getenv('ARCHIVE_YEAR') or '').strip()
    return int(value) if value.isdigit() else None


def archive_refusal(method: str, path: str) -> str | None:
    """Why a request is refused in the archive, or None."""
    year = archive_year()
    if year is None or method.upper() in READING or not path.startswith('/api/') or path in ARCHIVE_WRITABLE:
        return None
    return f'أرشيف {year} للقراءة فقط: لا يُسجَّل فيه شيء. سجّل في نظام السنة الحالية.'
