"""The VAT, for the manager's dashboard (DASH-8).

The owner, 30 Oct 2026 (agreeing to all advised): the dashboard said nothing of
the VAT. By the return's own reading (services/vat_return.period_vat -- what a
return would close), in the returns screen's quarters:

  quarter       this quarter so far: output, input, their net -- accruing
  last_quarter  the last whole one, and whether a return covers it
  owed          what the filed returns left on the settlement account
                (2301 on production): credit owed to the authority, debit
                due back -- paid by a voucher on it (ADR-043)
  policy        today's (services/vat_policy): sales charged VAT, input
                recovered -- why an output may be nothing (production: sales
                not charged from 2 May 2026)

Nothing here writes.
"""
from __future__ import annotations

from datetime import date, timedelta


def _quarter_start(day: date) -> date:
    return date(day.year, (day.month - 1) // 3 * 3 + 1, 1)


def _net(start: date, end: date) -> dict:
    from services.vat_return import period_vat
    output, input_ = period_vat(start, end)
    out, inp = round(sum(output.values()), 2), round(sum(input_.values()), 2)
    return {'start': start.isoformat(), 'end': end.isoformat(), 'output_vat': out, 'input_vat': inp,
            'net': round(out - inp, 2)}


def vat_due(today: date) -> dict:
    from accounting.mappings import DEFAULT_MAPPING_OPERATION_TYPE, get_account_id_for_mapping
    from models import VatReturn
    from services.live_balances import live_balances_by_account_ids
    from services.vat_policy import policy_on
    from services.vat_return import SETTLEMENT_ROLE

    this_start = _quarter_start(today)
    last_end = this_start - timedelta(days=1)
    last_start = _quarter_start(last_end)
    last = _net(last_start, last_end)
    last['filed'] = VatReturn.query.filter(VatReturn.period_start <= last_start,
                                           VatReturn.period_end >= last_end).first() is not None
    settlement = get_account_id_for_mapping(DEFAULT_MAPPING_OPERATION_TYPE, SETTLEMENT_ROLE)
    balance = float((live_balances_by_account_ids([settlement]).get(settlement) or {}).get('cash') or 0.0) \
        if settlement else 0.0
    policy = policy_on(today)
    return {'quarter': _net(this_start, today), 'last_quarter': last, 'owed': round(-balance, 2),
            'policy': {'sales_vat_charged': policy.sales_vat_charged,
                       'input_vat_recoverable': policy.input_vat_recoverable}}
