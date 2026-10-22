"""2027's account numbers from the 2027 template (CHART-002; approved by the owner, 22 Oct 2026).

The owner: «أريد نسخة نظيفة ومنظمة لـ2027 بغض النظر عن 2026» -- then «اعتمد».
A fixed width a level, so an account's level is its number's length: the root
1 digit, levels 2 and 3 one more each, level 4 two more, the detail level
(the parties' accounts too) three more. A child's number begins with its
parent's; children keep the template's order, with no gaps; a weight twin is
7 + its financial number; the one weight account with no financial twin
takes the next number under its weight parent.

    python tools/chart/numbering_2027.py            # prints old -> new
    python tools/chart/numbering_2027.py --write    # writes docs/chart/numbering-2027.json's table
"""
from __future__ import annotations

import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'backend'))

from accounting.twins import twin_number  # noqa: E402 -- the one twin rule (CHART-002)

TEMPLATE = os.path.join(ROOT, 'docs', 'chart', 'chart-of-accounts-2027.json')
TABLE = os.path.join(ROOT, 'docs', 'chart', 'numbering-2027.json')
WIDTH = {2: 1, 3: 1, 4: 2, 5: 3}     # the digits a level adds to its parent's


def is_weight(account: dict) -> bool:
    """A weight account by its kind in the template, not its number."""
    return account.get('transaction_type') == 'gold'


def numbering(template: dict) -> dict:
    accounts = template['accounts']
    by = {a['account_number']: a for a in accounts}
    financial = [a for a in accounts if not is_weight(a)]
    weight = [a for a in accounts if is_weight(a)]
    kids: dict = {}
    for a in financial:
        kids.setdefault(a.get('parent_account_number') or None, []).append(a)
    for k in kids:
        kids[k].sort(key=lambda a: (len(a['account_number']), a['account_number']))

    def level(number):
        d, a = 1, by[number]
        while a.get('parent_account_number'):
            d, a = d + 1, by[a['parent_account_number']]
        return d

    new: dict = {}

    def walk(old, depth):
        for i, a in enumerate(kids.get(old, []), start=1):
            width = WIDTH[depth + 1]
            if i >= 10 ** width:
                raise ValueError(f'{old}: more children than level {depth + 1} holds')
            new[a['account_number']] = new[old] + str(i).zfill(width)
            walk(a['account_number'], depth + 1)

    for root in kids[None]:
        new[root['account_number']] = root['account_number']
        walk(root['account_number'], 1)
    for w in weight:
        twin = w.get('memo_account_number')
        if twin and twin in new:
            new[w['account_number']] = twin_number(new[twin])
    for w in sorted(weight, key=lambda a: len(a['account_number'])):
        if w['account_number'] in new:
            continue
        parent = w.get('parent_account_number')
        if parent and parent in new:
            width, i = WIDTH[level(w['account_number'])], 1
            while (candidate := new[parent] + str(i).zfill(width)) in new.values():
                i += 1
            new[w['account_number']] = candidate
        else:
            new[w['account_number']] = w['account_number']      # the weight roots
    return new


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    with open(TEMPLATE, encoding='utf-8') as fh:
        table = numbering(json.load(fh))
    if '--write' in argv:
        with open(TABLE, encoding='utf-8') as fh:
            doc = json.load(fh)
        doc['old_to_new'] = table
        with open(TABLE, 'w', encoding='utf-8') as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=1)
    else:
        for old, new in table.items():
            print(old, '->', new)


if __name__ == '__main__':
    main()
