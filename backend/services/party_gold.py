"""Gold with a party moves by a voucher naming the party (ADR-051 §5ب).

A party's gold safe («ذهب لدى الأطراف»: an office's or a supplier's, no stock
location) sits on that party's own weight account: it is what they hold of
ours, not a drawer of the shop's. Moving gold to or from it is a dealing with
the party -- a receipt from them or a payment to them, named, approved like
any voucher -- never a transfer between the shop's safes, which is born
approved and names no one. AV-2026-00012 (18 Mar 2026) moved 185.4 g from an
office to the main scrap safe by a transfer; it was a purchase paid in cash,
and stage 4 had to correct it (COR-2026-00035).
"""

REFUSAL_CODE = 'party_gold_moves_by_voucher'


def transfer_refusal(*safes):
    """The refusal when any of [safes] holds a party's gold, else None."""
    for safe in safes:
        if safe is not None and safe.holds_party_gold:
            return {
                'error': REFUSAL_CODE,
                'message': (
                    f'«{safe.name}» ذهبٌ لدى طرف، لا خزينةٌ من خزائن المحل. '
                    'يُستلم منه بسند قبض باسمه، ويُسلَّم له أو لمورد بسند صرف، لا بتحويل.'
                ),
                'safe_box_id': safe.id,
            }
    return None
