"""A card's way to pay receives; it never pays out (17 Oct 2026).

A method whose safe is a clearing safe (مدى، فيزا، تابي، تمارا) puts the money
in the processor's hands until the settlement brings it to the bank: the
clearing account is money owed to us. A sale takes it in; a sale's return
gives it back through the processor. A purchase -- from a supplier or a
customer -- or a supplier's return is paid from our cash or bank, never from
what the processor owes us. On the 16 Oct production copy the four card
methods listed «شراء جديد», «مرتجع شراء كسر» and «مرتجع شراء جديد» too; none
was ever paid that way (every card payment is a sale's).
"""
from __future__ import annotations

CLEARING = 'clearing'
CLEARING_INVOICE_TYPES = ('بيع', 'مرتجع بيع')


def clearing_pays_out(safe_box, invoice_types) -> list:
    """The types a clearing method may not be set for (none for any other safe)."""
    if safe_box is None or (getattr(safe_box, 'safe_type', '') or '').strip().lower() != CLEARING:
        return []
    return [t for t in (invoice_types or []) if t not in CLEARING_INVOICE_TYPES]


def refusal(name, bad) -> dict:
    return {
        'error': 'clearing_method_pays_out',
        'message': (f'وسيلة الدفع «{name}» تُحصّل عبر شركة البطاقات، فلا يُدفع منها: '
                    'تُضبط لفواتير البيع ومرتجع البيع فقط.'),
        'invoice_types': bad,
    }
