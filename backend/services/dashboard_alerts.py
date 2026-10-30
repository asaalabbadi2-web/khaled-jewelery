"""What is wrong now, for the manager's dashboard (DASH-7).

The owner, 30 Oct 2026 (agreeing to all advised): the nightly check's findings
reached only the screen «نتائج الفحص الليلي», and a safe below zero was said
nowhere. Two readings, neither invented here:

  findings  the open ones nobody has accepted (an accepted finding is true and
            no longer news -- list_findings' own 'open'), by kind, with the
            kind's title and rank from services/finding_kinds; a retired
            kind's rows are history, not news (RETIRED_KINDS)
  safes     a safe below zero, in cash or in main-karat grams -- the
            dashboard's own safe balances, passed in, not read again. A karat
            below zero in a safe whose gold is above it is the drift checks'
            concern (SAFEBOX_GOLD_DRIFT), not a safe below zero

A late settlement is the clearing card's (DASH-5) and its scheduler's finding.
Nothing here writes.
"""
from __future__ import annotations


def alerts(safe_rows: list) -> dict:
    from services.books_invariants import list_findings
    from services.finding_kinds import KIND_INFO, RETIRED_KINDS

    by_kind: dict = {}
    for f in list_findings(status='open', limit=5000):
        if f['kind'] in RETIRED_KINDS:
            continue
        k = by_kind.setdefault(f['kind'], {'kind': f['kind'], 'count': 0, 'since': f['created_at']})
        k['count'] += 1
        k['since'] = min(k['since'] or f['created_at'], f['created_at'] or k['since'])
    findings = sorted(
        ({**k, 'title': KIND_INFO.get(k['kind'], {}).get('title_ar', k['kind']),
          'since': (k['since'] or '')[:10] or None} for k in by_kind.values()),
        key=lambda k: (KIND_INFO.get(k['kind'], {}).get('rank', 999), k['kind']))

    safes = []
    for sb in safe_rows or []:
        cash = float(sb.get('balance_cash') or 0.0)
        grams = float(sb.get('total_weight_main_karat') or 0.0)
        if cash < -0.005 or grams < -0.0005:
            safes.append({'safe': sb.get('name'), 'cash': round(cash, 2) if cash < -0.005 else None,
                          'grams': round(grams, 3) if grams < -0.0005 else None})

    return {'findings': findings, 'negative_safes': safes,
            'total': sum(k['count'] for k in findings) + len(safes)}
