"""Repository-wide gate: no persisted string constant may exhaust its column.

SQLite ignores VARCHAR length and PostgreSQL enforces it, so this class of bug
is invisible to a green test suite and fatal on the first production write. It
already bit once — `reference_type='supplier_settlement_adjustment'` (30 chars)
against Voucher.reference_type String(20), with 76 tests passing.

The gate itself lives in scripts/string_capacity_guard.py, next to the repo's
other architecture gates, so it can be run by hand or in CI without pytest.
This module runs it against the live SQLAlchemy metadata, proves it actually
fires, and pins the coverage it absorbed from the old SAD-only check.
"""

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / 'scripts'))

from string_capacity_guard import (  # noqa: E402
    ACCEPTED_ZERO_HEADROOM,
    ColumnIndex,
    GuardReport,
    TIGHT_MARGIN,
    run,
    scan_tree,
)


@pytest.fixture(scope='module')
def report():
    return run()


@pytest.fixture(scope='module')
def index():
    return ColumnIndex.from_app()


# ── The gate ─────────────────────────────────────────────────────────────────

def test_no_string_constant_exhausts_its_column(report):
    """Every persisted constant must be strictly shorter than its column.

    Equality fails too. PostgreSQL stores a 40-char value in VARCHAR(40)
    happily, so an exact fit is not broken today — it simply has no room left
    for the next rename, and that is the failure this gate is here to prevent.
    """
    assert not report.unwaived, (
        f'{len(report.unwaived)} string constant(s) exceed or exhaust their column:\n\n'
        + '\n\n'.join(v.render() for v in report.unwaived)
    )


def test_no_stale_declarations(report):
    """A waiver or binding that no longer matches the code is a lie in a file."""
    assert not report.stale_waivers, '\n'.join(report.stale_waivers)


def test_the_guard_actually_inspected_the_repository(report):
    """Guard against the silent failure mode: a scan that found nothing."""
    assert report.columns > 200, f'only {report.columns} String(n) columns discovered'
    assert report.checked > 1000, f'only {report.checked} constants checked'
    assert report.files > 400, f'only {report.files} files parsed'


# ── Coverage absorbed from the old SAD-only guard ────────────────────────────

SAD_BINDINGS = [
    ('voucher', 'reference_type', 'supplier_settlement'),
    ('voucher', 'voucher_type', 'adjustment'),
    ('accounting_mapping', 'operation_type', 'تسوية_مورد'),
    ('supplier_settlement_adjustment', 'status', 'approved'),
] + [
    ('accounting_mapping', 'account_type', v) for v in (
        'supplier_settlement_expense',
        'supplier_settlement_income',
        'supplier_weight_settlement_expense',
        'supplier_weight_settlement_income',
    )
] + [
    ('supplier_settlement_adjustment', 'reason_code', v) for v in (
        'ROUNDING_DIFFERENCE',
        'FINAL_SETTLEMENT_DIFFERENCE',
        'WEIGHT_DIFFERENCE',
        'DOCUMENTED_SUPPLIER_WAIVER',
        'OTHER',
    )
]


@pytest.mark.parametrize('binding', SAD_BINDINGS, ids=lambda b: f'{b[0]}.{b[1]}={b[2]}')
def test_sad_constants_are_still_covered(report, binding):
    """test_string_values_fit_their_columns was folded into this gate.

    Deleting a narrow guard in favour of a general one is only safe if the
    general one demonstrably still checks what the narrow one did — otherwise
    the refactor quietly loses coverage. So each SAD binding is pinned by name.
    """
    assert binding in report.covered, (
        f'{binding} is no longer checked — the general guard lost coverage that '
        'the SAD-specific guard used to provide.'
    )


# ── Mutation tests: prove the gate fires ─────────────────────────────────────
#
# These run the real analyzer, with the real column index read from the real
# models, over a real file on disk. Nothing about the verdict is stubbed: only
# the scanned directory differs, so a passing result here means the same code
# path that scans backend/ would have caught the same value there.

def _scan_source(source: str, index, tmp_path: Path) -> GuardReport:
    (tmp_path / 'sample.py').write_text(source, encoding='utf-8')
    report = GuardReport(columns=index.column_count)
    scan_tree(tmp_path, index, report)
    return report


VOUCHER_REFERENCE_TYPE_LENGTH = 20  # asserted against the model below


def test_the_column_under_test_is_the_length_we_think(index):
    """The mutation cases below are meaningless if this drifts."""
    assert index.length_for('voucher', 'reference_type') == VOUCHER_REFERENCE_TYPE_LENGTH


def test_over_limit_value_is_a_violation(index, tmp_path):
    value = 'x' * (VOUCHER_REFERENCE_TYPE_LENGTH + 1)
    report = _scan_source(
        f"from models import Voucher\nv = Voucher(reference_type={value!r})\n",
        index, tmp_path)

    assert len(report.violations) == 1
    found = report.violations[0]
    assert found.value == value
    assert found.length == VOUCHER_REFERENCE_TYPE_LENGTH + 1
    assert found.column_length == VOUCHER_REFERENCE_TYPE_LENGTH
    assert 'voucher' in found.render() and 'reference_type' in found.render()


def test_exact_limit_value_is_a_violation(index, tmp_path):
    """The whole point of the stricter-than-the-database rule."""
    value = 'x' * VOUCHER_REFERENCE_TYPE_LENGTH
    report = _scan_source(
        f"from models import Voucher\nv = Voucher(reference_type={value!r})\n",
        index, tmp_path)

    assert len(report.violations) == 1
    assert report.violations[0].headroom == 0


def test_under_limit_value_passes(index, tmp_path):
    value = 'x' * (VOUCHER_REFERENCE_TYPE_LENGTH - 1)
    report = _scan_source(
        f"from models import Voucher\nv = Voucher(reference_type={value!r})\n",
        index, tmp_path)

    assert report.violations == []
    assert len(report.tight) == 1, 'a one-char margin should still be reported as tight'


def test_comfortable_value_is_neither_violation_nor_tight(index, tmp_path):
    report = _scan_source(
        "from models import Voucher\nv = Voucher(reference_type='ok')\n",
        index, tmp_path)

    assert report.violations == []
    assert report.tight == []


def test_the_right_column_is_chosen_when_the_name_is_ambiguous(index, tmp_path):
    """reference_type is String(20) on voucher and String(50) on journal_entry.

    A 30-char value is fatal for one and fine for the other. Conflating them is
    exactly the mistake that made this class of bug hard to see, so the guard
    must resolve the owning table before judging anything.
    """
    value = 'x' * 30
    report = _scan_source(
        'from models import JournalEntry, Voucher\n'
        f'a = JournalEntry(reference_type={value!r})\n',
        index, tmp_path)
    assert report.violations == [], 'JournalEntry.reference_type holds 50 — this fits'

    report = _scan_source(
        'from models import Voucher\n'
        f'b = Voucher(reference_type={value!r})\n',
        index, tmp_path)
    assert len(report.violations) == 1, 'Voucher.reference_type holds 20 — this does not'


def test_module_level_constants_are_resolved(index, tmp_path):
    """The real offender reached its column through a constant, not a literal."""
    value = 'x' * (VOUCHER_REFERENCE_TYPE_LENGTH + 5)
    report = _scan_source(
        'from models import Voucher\n'
        f'REF = {value!r}\n'
        'v = Voucher(reference_type=REF)\n',
        index, tmp_path)

    assert len(report.violations) == 1
    assert report.violations[0].value == value


def test_attribute_assignment_is_resolved_by_variable_name(index, tmp_path):
    """`voucher.reference_type = ...` names its own model, and that is enough."""
    value = 'x' * (VOUCHER_REFERENCE_TYPE_LENGTH + 2)
    report = _scan_source(
        f"voucher = make_it()\nvoucher.reference_type = {value!r}\n",
        index, tmp_path)

    assert len(report.violations) == 1
    assert report.violations[0].table == 'voucher'


def test_unresolvable_owner_is_reported_not_guessed(index, tmp_path):
    """A short value on an ambiguous column must not be invented into a failure."""
    report = _scan_source(
        "thing = fetch()\nthing.reference_type = 'invoice'\n",
        index, tmp_path)

    assert report.violations == []
    assert len(report.unresolved) == 1
    assert report.unresolved[0].column == 'reference_type'


def test_value_too_long_for_every_candidate_still_fails(index, tmp_path):
    """Ambiguity is not a licence. If no candidate column could hold it, it fails."""
    value = 'x' * 60  # longer than journal_entry(50), the most generous candidate
    report = _scan_source(
        f"thing = fetch()\nthing.reference_type = {value!r}\n",
        index, tmp_path)

    assert len(report.violations) == 1
    assert report.unresolved == []


# ── The findings this gate was built to surface ──────────────────────────────

def test_known_zero_headroom_value_is_detected_and_waived_explicitly(report):
    """The 40/40 case must be found, named, and accepted on the record.

    It is waived rather than fixed because the value is already written to
    production rows: renaming it is a data migration, not an edit. The waiver
    keeps it visible, and test_no_stale_declarations makes the waiver expire
    on its own the moment the value goes away.
    """
    key = ('safe_box_transaction', 'ref_type',
           'historical_gold_reconciliation_per_karat')

    assert key in ACCEPTED_ZERO_HEADROOM, 'the waiver was removed without a decision'
    assert key in {v.key for v in report.waived}, (
        'the guard no longer detects the known 40/40 value'
    )


def test_the_39_of_40_value_is_reported_as_tight(report):
    """One character of headroom is a finding, even though it is not a failure."""
    tight = {(t.table, t.column, t.value): t for t in report.tight}
    key = ('safe_box_transaction', 'ref_type',
           'historical_clearing_adjustment_reversal')

    assert key in tight, 'the 39/40 value is no longer surfaced'
    assert tight[key].headroom == 1
    assert tight[key].headroom <= TIGHT_MARGIN
