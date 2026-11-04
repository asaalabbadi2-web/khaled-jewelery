"""The reports' contract: one shape every report answers (REPORTS ت0-3, ADR-083 law 6).

So one screen shows, exports and prints any report (the shell, ت1):

  id, title       which report
  period          {'start', 'end'} (ISO dates; either may be None) -- or an 'as_of'
  basis           where its figures come from: 'posted_entries' (the books) or
                  'documents' (an analysis, reconciled to the books in total)
  columns         [{'key', 'label', 'kind', 'signed'}]; kind: text | money | grams | count | percent;
                  signed: its sign means something (a balance), shown so
  rows            [{<column key>: value, ..., 'drill': {'kind', 'id'} | None,
                   'style': None | 'heading' | 'subtotal' | 'finding' | 'note'}] -- a
                  statement's sections, their totals, a line said apart, a note beside
                  (not summed)
  totals          {<column key>: value}
  checks          [{'key', 'label', 'ok'}] -- what the report checks of itself
  read_at         when it was read (the caller's clock, ADR-015)
"""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field

BASES = ('posted_entries', 'documents')
KINDS = ('text', 'money', 'grams', 'count', 'percent', 'date')   # date: YYYY-MM-DD, never the wide column


@dataclass(frozen=True)
class Column:
    key: str
    label: str
    kind: str = 'text'
    signed: bool = False

    def __post_init__(self):
        if self.kind not in KINDS:
            raise ValueError(f'a column is {"|".join(KINDS)}, not {self.kind!r}')


@dataclass(frozen=True)
class Check:
    key: str
    label: str
    ok: bool


@dataclass
class Report:
    id: str
    title: str
    basis: str
    columns: list
    rows: list
    totals: dict
    read_at: dt.datetime
    start: dt.date | None = None
    end: dt.date | None = None
    checks: list = field(default_factory=list)

    def __post_init__(self):
        if self.basis not in BASES:
            raise ValueError(f'a report is read from {"|".join(BASES)}, not {self.basis!r}')

    def to_dict(self) -> dict:
        return {
            'id': self.id, 'title': self.title, 'basis': self.basis,
            'period': {'start': self.start.isoformat() if self.start else None,
                       'end': self.end.isoformat() if self.end else None},
            'columns': [{'key': c.key, 'label': c.label, 'kind': c.kind, 'signed': c.signed} for c in self.columns],
            'rows': self.rows, 'totals': self.totals,
            'checks': [{'key': c.key, 'label': c.label, 'ok': c.ok} for c in self.checks],
            'read_at': self.read_at.isoformat(),
        }
