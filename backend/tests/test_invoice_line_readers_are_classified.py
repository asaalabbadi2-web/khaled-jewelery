"""Every reader of an invoice's lines is classified for the correction (ADR-056, ت-2).

A correction puts a posted line right in place (the owner, 22 Oct 2026). What
reads invoice lines then sees the right lines -- unless it wrote from them at
posting, or must read the invoice as it was posted (the points). Each module
that names InvoiceItem or InvoiceKaratLine is in this map, with how the
correction reaches it (docs/plans/invoice-correction-study.md §8); a new one
fails here until it is classified, and a classified one that no longer reads
them must be struck.

  write    -- writes from the lines at posting; the correction writes its own
              difference (its entry, safe rows, allocations), never re-runs it
  derived  -- reads the lines as they are: sees the corrected line
  rule     -- reads them by an explicit rule (the points: as posted, plus the
              correction's difference in its own period)
  admin    -- schema, resets, the model itself: no figure
  correction -- the correction itself

Run:
    python -m pytest tests/test_invoice_line_readers_are_classified.py -v
"""
import os
import re

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP = {'venv', 'tests', 'alembic', 'migrations', 'tools', '_archived', 'graphify-out', 'backups', '__pycache__',
        'instance', 'repair'}          # services/repair: one-off repairs of the past, not readers of today
NAMES = re.compile(r'\bInvoice(Item|KaratLine)\b')

READERS = {
    'models.py': 'admin',
    'schema_guard.py': 'admin',
    'routes/system.py': 'admin',                     # the reset and the counts
    'internal_routes.py': 'write',                   # an internal order's invoice
    'routes/invoices.py': 'write',                   # add_invoice; its lists read the lines as they are
    'posting_routes.py': 'write',                    # invoice_gold_plan, safe rows at posting
    'routes/office_reservations.py': 'write',        # the reservation's purchase invoice
    'services/stock_ledger.py': 'write',             # allocate_invoice at posting
    'services/purchase_stones.py': 'write',          # a supplier line's stones at posting
    'services/sale_stones.py': 'write',              # a sale line's stones sold by their value (ت6ج)
    'services/gold_allocation_service.py': 'write',  # the supplier's gold owed (ت-4: from the corrected lines)
    'category_weight_tracking.py': 'write',          # category weight movements at posting
    'routes/reports.py': 'derived',                  # sales by item, by karat, the dashboard, gram profit
    'routes/__init__.py': 'derived',                 # an invoice's main-karat weight
    'routes/catalog.py': 'derived',                  # whether an item was invoiced
    'summary_routes.py': 'derived',                  # top items
    'services/categories.py': 'derived',             # a return's line inherits its original's category
    'services/return_lines.py': 'derived',           # a return's share of its original
    'services/return_vat.py': 'derived',             # a return's VAT from its original's lines
    'services/gold_acquisition_reconciliation.py': 'derived',
    'metrics/points_metric.py': 'rule',              # the race: as posted + the correction in its period
    'points/engine.py': 'rule',
    'services/invoice_corrections.py': 'correction',
}


def _readers() -> set:
    found = set()
    for root, dirs, files in os.walk(BACKEND):
        dirs[:] = [d for d in dirs if d not in SKIP]
        for name in files:
            if not name.endswith('.py') or name.startswith('test_'):
                continue
            path = os.path.join(root, name)
            with open(path, encoding='utf-8') as fh:
                if NAMES.search(fh.read()):
                    found.add(os.path.relpath(path, BACKEND))
    return found


def test_every_reader_of_invoice_lines_is_classified():
    unclassified = _readers() - set(READERS)
    assert not unclassified, (f'modules reading invoice lines with no place in the correction\'s map: '
                              f'{sorted(unclassified)} -- classify each in READERS (study §8)')


def test_the_map_names_no_module_that_no_longer_reads_them():
    stale = set(READERS) - _readers()
    assert not stale, f'classified but no longer reading invoice lines: {sorted(stale)} -- strike them'


def test_every_class_is_known():
    assert set(READERS.values()) <= {'write', 'derived', 'rule', 'admin', 'correction'}
