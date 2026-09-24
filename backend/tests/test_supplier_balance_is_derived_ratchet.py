"""Architecture ratchet: a supplier's cash/gold balance is DERIVED, never cached.

The five columns `Supplier.balance_cash` and `Supplier.balance_gold_18k/21k/22k/24k`
were deleted because they drifted from the ledger by **21,121.06 g across 24
suppliers in real production** — an incremental `+=` writer inside
`create_dual_journal_entry()` against a recompute reader
(`compute_live_supplier_balances()`) that applied different rules. Three
separate serving paths were answering the same question differently, and
`/suppliers/<id>/weight-summary` was multiplying the stale weights by live gold
prices to produce monetary valuations.

This is the third cache drift this codebase has produced (`Invoice.amount_paid`,
then `InvoiceGoldObligation.weight_remaining_main_karat`, then this), so the
rule gets a machine rather than a comment:

    nothing may store, write, or repair a supplier balance.
    the only answer comes from compute_live_supplier_balances().

Run:
    python -m pytest tests/test_supplier_balance_is_derived_ratchet.py -v
"""

import re
from pathlib import Path

import pytest
from sqlalchemy import inspect as sa_inspect

from app import app as flask_app
from models import Supplier, db

BACKEND = Path(__file__).resolve().parent.parent

CACHED_COLUMNS = (
    'balance_cash',
    'balance_gold_18k',
    'balance_gold_21k',
    'balance_gold_22k',
    'balance_gold_24k',
)

# Files that legitimately mention these names without caching a supplier
# balance: this ratchet itself, and the migration that drops the columns.
ALLOWED_FILES = {
    'tests/test_supplier_balance_is_derived_ratchet.py',
    'alembic/versions/20260924_drop_supplier_cached_balances.py',
}

# Customer and Office keep their own same-named columns for now — a separate,
# explicitly deferred decision. Their modules are therefore out of this
# ratchet's scope, but a supplier write inside them would still be caught by
# the `supplier.` prefix requirement below.
SKIPPED_DIRS = ('tests/', 'devtools/', 'tools/', 'alembic/versions/', 'venv/', '.git/')


def _strip_comment(line: str) -> str:
    """Everything before the first '#'.

    A ratchet that cannot tell code from prose fires on the very comment that
    documents it — this one did, on the note in dual_system_helpers.py quoting
    the line it replaced. Real assignment code can never sit after a '#', so
    truncating there is sound for finding writes. It would miss a write on a
    line whose earlier string literal contains '#', which no assignment to
    these columns plausibly does.
    """
    return line.split('#', 1)[0]


def _python_sources():
    for path in BACKEND.rglob('*.py'):
        rel = path.relative_to(BACKEND).as_posix()
        if rel in ALLOWED_FILES:
            continue
        if any(rel.startswith(d) for d in SKIPPED_DIRS):
            continue
        yield rel, path.read_text(encoding='utf-8', errors='ignore')


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


class TestNoCachedColumn:

    def test_the_columns_do_not_exist_on_the_model(self, app):
        for column in CACHED_COLUMNS:
            assert not hasattr(Supplier, column), (
                f'Supplier.{column} is back. A supplier balance is derived from the '
                f'ledger via compute_live_supplier_balances(), never stored.'
            )

    def test_the_columns_do_not_exist_in_the_database(self, app):
        columns = {c['name'] for c in sa_inspect(db.engine).get_columns('supplier')}
        leaked = sorted(set(CACHED_COLUMNS) & columns)
        assert not leaked, f'these cached balance columns are back in the schema: {leaked}'


class TestNoWriter:

    def test_no_module_references_a_supplier_balance_column(self):
        """Catches `supplier.balance_cash += ...` / `= ...` / `-= ...`, the
        `setattr(supplier, 'balance_gold_21k', ...)` spelling, and any
        `Supplier.balance_*` class reference.

        Note for whoever extends this: `Customer` and `Office` keep identically
        named columns on purpose, so the rule is deliberately scoped to the
        `supplier` / `Supplier` spellings. Beware the reverse trap too —
        `routes/reports.py` has a loop variable named `supplier` that actually
        holds a `Customer` (`Customer.customer_type == 'مورد'`), which is why
        this checks writes and class references rather than every read."""
        columns = '|'.join(CACHED_COLUMNS)
        patterns = [
            re.compile(r'\bsupplier\s*\.\s*(' + columns + r')\s*(\+=|-=|=(?!=))'),
            re.compile(r'setattr\s*\(\s*supplier\s*,\s*[\'"](' + columns + r')[\'"]'),
            # The CLASS attribute, not the instance: `Supplier.balance_cash: 0.0`
            # inside a bulk `query.update({...})`. Two of these survived in
            # routes/system.py's reset paths when this ratchet only looked for
            # the lowercase instance spelling, and they would have raised
            # AttributeError the moment a system reset ran.
            re.compile(r'\bSupplier\s*\.\s*(' + columns + r')\b'),
        ]
        offenders = []
        for rel, source in _python_sources():
            for line_no, line in enumerate(source.splitlines(), start=1):
                code = _strip_comment(line)
                if any(p.search(code) for p in patterns):
                    offenders.append(f'{rel}:{line_no}: {line.strip()}')

        assert not offenders, (
            'a supplier balance is being written. It must be derived instead:\n  '
            + '\n  '.join(offenders)
        )

    def test_create_dual_journal_entry_does_not_touch_supplier_balances(self):
        """The specific writer that caused the 21kg drift: an incremental `+=`
        inside the central posting helper, which every GL path funnels through
        and which no reversal path ever undid."""
        source = (BACKEND / 'dual_system_helpers.py').read_text(encoding='utf-8')
        code_only = '\n'.join(_strip_comment(l) for l in source.splitlines())
        for column in CACHED_COLUMNS:
            assert f'supplier.{column}' not in code_only, (
                f'dual_system_helpers.py still touches supplier.{column}'
            )


class TestNoRepairPath:

    def test_no_repair_endpoint_for_supplier_balances(self):
        """With nothing cached there is nothing to repair. A "repair balances"
        route would reintroduce the GL -> repair -> stored-balance model that
        was just removed."""
        offenders = []
        for rel, source in _python_sources():
            if 'repair-historical-balances' in source or 'repair_supplier_historical_balances' in source:
                offenders.append(rel)
        assert not offenders, (
            'a supplier balance repair path is back in: ' + ', '.join(offenders)
        )

    def test_no_frontend_button_invokes_a_balance_repair(self):
        frontend = BACKEND.parent / 'frontend' / 'lib'
        if not frontend.exists():
            pytest.skip('frontend not present in this checkout')
        offenders = []
        for path in frontend.rglob('*.dart'):
            text = path.read_text(encoding='utf-8', errors='ignore')
            if 'repairSupplierHistoricalBalances' in text or 'repair-historical-balances' in text:
                offenders.append(path.relative_to(frontend).as_posix())
        assert not offenders, (
            'the frontend still calls a supplier balance repair: ' + ', '.join(offenders)
        )
