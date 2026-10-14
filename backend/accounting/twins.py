"""A financial account and its weight twin: the numbering rule, in one place (CHART-002 step 4c4).

The owner, 14 Oct 2026: the rule stays -- a twin is numbered «7 + its financial
account's number» -- and 2027's numbering table follows it. But «is this a
weight account?» is the account's own mark (tracks_weight), never its first
digit, and a twin is found by its link (memo_account_id), never by a number.
The rule was written out in some twenty places; it is here alone, used only
where an account has no twin yet and one is being numbered.
"""
from __future__ import annotations

TWIN_PREFIX = '7'


def _digits(value) -> str:
    return ''.join(ch for ch in str(value or '').strip() if ch.isdigit())


def twin_number(financial_number) -> str:
    """The number a financial account's weight twin takes."""
    digits = _digits(financial_number)
    if not digits:
        raise ValueError('Invalid financial account number')
    return TWIN_PREFIX + digits


def financial_number_of(twin_number_value) -> str | None:
    """The financial number a twin's number was made from -- None when it was not."""
    digits = _digits(twin_number_value)
    if len(digits) < 2 or digits[:len(TWIN_PREFIX)] != TWIN_PREFIX:
        return None
    return digits[len(TWIN_PREFIX):]


def numbered_as_twin(number) -> bool:
    """Whether *number* follows the twin rule -- for a number not yet an account."""
    return financial_number_of(number) is not None
