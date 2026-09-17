#!/usr/bin/env python3
"""String Capacity Guard — every persisted string constant must fit its column.

Why this gate exists
────────────────────
SQLite ignores VARCHAR length. PostgreSQL rejects an over-length value with
StringDataRightTruncation. So a whole test suite can be green on SQLite while
the first real write fails in production. That is not hypothetical here: the
SAD engine shipped `reference_type='supplier_settlement_adjustment'` (30 chars)
into Voucher.reference_type String(20), and 76 passing tests said nothing.

The rule is deliberately stricter than the database's
────────────────────────────────────────────────────
A value is a VIOLATION when len(value) >= column length — equality included.
PostgreSQL accepts a 40-char value in VARCHAR(40), so an exact fit is not a
defect today; it is zero headroom. One rename, one suffix, one `_reversal`
appended and it becomes a production failure that no SQLite test can see.
This guard buys that margin back.

What it inspects (four forms, each naming its own column)
─────────────────────────────────────────────────────────
The hard part is not finding string literals — it is knowing which column a
literal lands in. `reference_type` exists twice with different limits:
JournalEntry String(50) and Voucher String(20). A scan that ignores the
difference either misses real overflows or invents false ones. So every form
below resolves the owning table before it compares anything, and whatever
cannot be resolved is reported as unresolved rather than guessed at.

  A. Constructor keywords     Voucher(reference_type='x')
     The class name resolves the table exactly. Highest precision.

  B. Attribute assignment     je.reference_type = 'x'
     The owner is inferred from the local variable's origin in the same
     function (`je = JournalEntry(...)` / `JournalEntry.query...`). When the
     column name is unique repo-wide, that alone resolves it. Otherwise the
     candidate is recorded as unresolved.

  C. Explicit registry        values that flow through a function call
     SAD's operation_type reaches AccountingMapping through
     get_account_id_for_mapping(), never a constructor. The AST cannot follow
     that, so those bindings are declared once, below.

  D. Model class constants    SupplierSettlementAdjustment.STATUS_APPROVED
     Read from the live classes, not the AST. A constant is matched to a
     column when the column's name appears in the constant's name, so
     STATUS_APPROVED and VALID_REASON_CODES find `status` and `reason_code`
     without a hand-maintained map.

Usage:
    python scripts/string_capacity_guard.py           # report + exit code
    python scripts/string_capacity_guard.py --all     # also list tight values
"""
from __future__ import annotations

import argparse
import ast
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
BACKEND = REPO_ROOT / "backend"

SKIP_DIRS = {
    'venv', '.venv', 'node_modules', '.git', '__pycache__', '.pytest_cache',
    'migrations_backup', '.mypy_cache',
}

# How close to the limit a passing value must get before it is worth naming.
TIGHT_MARGIN = 3


# ─────────────────────────────────────────────────────────────────────────────
# Form C — bindings the AST cannot follow
# ─────────────────────────────────────────────────────────────────────────────
# A module-level constant that is persisted through a function call rather than
# a constructor. Each entry says: this constant, in this module, ends up in
# this table.column. Keep it short — a growing list means the code is hiding
# its writes behind too many layers.
EXPLICIT_BINDINGS: list[tuple[str, str, str, str]] = [
    # module path,                                       constant,
    #                                                    table,               column
    ('backend/services/supplier_settlement_adjustment_service.py',
     'SETTLEMENT_OPERATION_TYPE', 'accounting_mapping', 'operation_type'),
    ('backend/services/supplier_settlement_adjustment_service.py',
     'ACCOUNT_TYPE_SETTLEMENT_EXPENSE', 'accounting_mapping', 'account_type'),
    ('backend/services/supplier_settlement_adjustment_service.py',
     'ACCOUNT_TYPE_SETTLEMENT_INCOME', 'accounting_mapping', 'account_type'),
    ('backend/services/supplier_settlement_adjustment_service.py',
     'ACCOUNT_TYPE_WEIGHT_SETTLEMENT_EXPENSE', 'accounting_mapping', 'account_type'),
    ('backend/services/supplier_settlement_adjustment_service.py',
     'ACCOUNT_TYPE_WEIGHT_SETTLEMENT_INCOME', 'accounting_mapping', 'account_type'),
]


# ─────────────────────────────────────────────────────────────────────────────
# Accepted zero-headroom values
# ─────────────────────────────────────────────────────────────────────────────
# A waiver is a decision, not a silence: each entry is named here in code, so
# adding one costs a review and removing the underlying value makes this list
# stale — which the guard reports as an error of its own.
#
# Nothing in this list is broken today. PostgreSQL stores a 40-char value in
# VARCHAR(40) without complaint. What each entry has lost is the room to be
# renamed, and that is the risk being accepted.
ACCEPTED_ZERO_HEADROOM: dict[tuple[str, str, str], str] = {
    ('safe_box_transaction', 'ref_type', 'historical_gold_reconciliation_per_karat'):
        'One-off repair script (tools/maintenance/fix_sale_invoice_qty_bug_per_karat.py). '
        'Already written to production rows, so renaming it is a data migration, '
        'not an edit. Awaiting a separate decision.',
}


# ─────────────────────────────────────────────────────────────────────────────
# Findings
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Finding:
    table: str
    column: str
    value: str
    column_length: int
    source: str
    line: int
    form: str

    @property
    def length(self) -> int:
        return len(self.value)

    @property
    def headroom(self) -> int:
        return self.column_length - self.length

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.table, self.column, self.value)

    def render(self) -> str:
        return (
            'String constant exceeds or exhausts DB column capacity:\n'
            f'  table={self.table}\n'
            f'  column={self.column}\n'
            f'  value={self.value!r}\n'
            f'  length={self.length}\n'
            f'  column_length={self.column_length}\n'
            f'  source={self.source}:{self.line} (form {self.form})'
        )


def record(report, index, table, column, value, source, line, form) -> None:
    """Compare one value to one column and file the result. The only place the
    verdict is decided, so every form is judged by identical arithmetic."""
    length = index.length_for(table, column)
    if length is None:
        return
    report.checked += 1
    report.covered.add((table, column, value))
    finding = Finding(table, column, value, length, source, line, form)
    if finding.length >= length:
        report.violations.append(finding)
    elif finding.headroom <= TIGHT_MARGIN:
        report.tight.append(finding)


@dataclass(frozen=True)
class Unresolved:
    column: str
    value: str
    candidates: tuple
    source: str
    line: int


@dataclass
class GuardReport:
    violations: list = field(default_factory=list)
    tight: list = field(default_factory=list)
    unresolved: list = field(default_factory=list)
    # Every (table, column, value) actually compared. Kept so coverage can be
    # asserted directly — folding a per-feature guard into this one must not
    # silently drop what that guard used to check.
    covered: set = field(default_factory=set)
    checked: int = 0
    columns: int = 0
    files: int = 0
    stale_waivers: list = field(default_factory=list)

    @property
    def unwaived(self) -> list:
        return [v for v in self.violations if v.key not in ACCEPTED_ZERO_HEADROOM]

    @property
    def waived(self) -> list:
        return [v for v in self.violations if v.key in ACCEPTED_ZERO_HEADROOM]

    @property
    def ok(self) -> bool:
        return not self.unwaived and not self.stale_waivers


# ─────────────────────────────────────────────────────────────────────────────
# Column index
# ─────────────────────────────────────────────────────────────────────────────

class ColumnIndex:
    """Every String(n) column in the mapped models, addressable three ways."""

    def __init__(self, mappers):
        from sqlalchemy import String

        self.by_table: dict[str, dict[str, int]] = {}
        self.class_to_table: dict[str, str] = {}
        self.classes: dict[str, type] = {}

        for mapper in mappers:
            table = mapper.local_table
            if table is None:
                continue
            cls = mapper.class_
            self.class_to_table[cls.__name__] = table.name
            self.classes[cls.__name__] = cls
            cols = self.by_table.setdefault(table.name, {})
            for col in table.columns:
                if isinstance(col.type, String) and col.type.length:
                    cols[col.name] = col.type.length

        self.by_column: dict[str, list[tuple[str, int]]] = {}
        for table, cols in self.by_table.items():
            for name, length in cols.items():
                self.by_column.setdefault(name, []).append((table, length))

    @classmethod
    def from_app(cls) -> 'ColumnIndex':
        if str(BACKEND) not in sys.path:
            sys.path.insert(0, str(BACKEND))
        from app import db  # noqa: local import — needs sys.path set first
        return cls(db.Model.registry.mappers)

    @property
    def column_count(self) -> int:
        return sum(len(c) for c in self.by_table.values())

    def length_for(self, table: str, column: str) -> int | None:
        return self.by_table.get(table, {}).get(column)


# ─────────────────────────────────────────────────────────────────────────────
# AST scanning — forms A and B
# ─────────────────────────────────────────────────────────────────────────────

class _FileScanner(ast.NodeVisitor):
    """Collects candidates from one file, resolving each to a table first."""

    def __init__(self, path: Path, rel: str, index: ColumnIndex, report: GuardReport):
        self.rel = rel
        self.index = index
        self.report = report
        self.module_constants: dict[str, str] = {}
        # variable name -> model class name, per enclosing function
        self._locals: dict[str, str] = {}

    # ── value resolution ────────────────────────────────────────────────────

    def _literal(self, node) -> str | None:
        """A string this node certainly evaluates to, or None."""
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.Name):
            return self.module_constants.get(node.id)
        return None

    def _record(self, table, column, value, line, form):
        record(self.report, self.index, table, column, value, self.rel, line, form)

    # ── traversal ───────────────────────────────────────────────────────────

    def visit_Module(self, node):
        for stmt in node.body:
            if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 \
                    and isinstance(stmt.targets[0], ast.Name) \
                    and isinstance(stmt.value, ast.Constant) \
                    and isinstance(stmt.value.value, str):
                self.module_constants[stmt.targets[0].id] = stmt.value.value
        self.generic_visit(node)

    def visit_FunctionDef(self, node):
        outer, self._locals = self._locals, dict(self._locals)
        self._collect_local_types(node)
        self.generic_visit(node)
        self._locals = outer

    visit_AsyncFunctionDef = visit_FunctionDef

    def _collect_local_types(self, node):
        """Remember `je = JournalEntry(...)` and `je = JournalEntry.query...`."""
        for stmt in ast.walk(node):
            if not (isinstance(stmt, ast.Assign) and len(stmt.targets) == 1
                    and isinstance(stmt.targets[0], ast.Name)):
                continue
            target = stmt.targets[0].id
            model = self._model_of_expression(stmt.value)
            if model:
                self._locals[target] = model

    def _model_of_expression(self, node) -> str | None:
        """The model class a expression constructs or queries, if obvious."""
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name) and node.func.id in self.index.class_to_table:
                return node.func.id
            # Model.query.filter(...).first() — walk back to the root Name.
            probe = node.func
            while isinstance(probe, (ast.Attribute, ast.Call, ast.Subscript)):
                probe = probe.value if not isinstance(probe, ast.Call) else probe.func
            if isinstance(probe, ast.Name) and probe.id in self.index.class_to_table:
                return probe.id
        if isinstance(node, ast.Attribute):
            probe = node
            while isinstance(probe, ast.Attribute):
                probe = probe.value
            if isinstance(probe, ast.Name) and probe.id in self.index.class_to_table:
                return probe.id
        return None

    def visit_Call(self, node):
        # Form A — Model(column=value)
        if isinstance(node.func, ast.Name) and node.func.id in self.index.class_to_table:
            table = self.index.class_to_table[node.func.id]
            for kw in node.keywords:
                if kw.arg and self.index.length_for(table, kw.arg) is not None:
                    value = self._literal(kw.value)
                    if value is not None:
                        self._record(table, kw.arg, value, node.lineno, 'A')
        self.generic_visit(node)

    def visit_Assign(self, node):
        # Form B — instance.column = value
        if len(node.targets) == 1 and isinstance(node.targets[0], ast.Attribute):
            target = node.targets[0]
            column = target.attr
            value = self._literal(node.value)
            if value is not None and column in self.index.by_column:
                table = self._resolve_owner(target, column)
                if table:
                    self._record(table, column, value, node.lineno, 'B')
                else:
                    owners = tuple(self.index.by_column[column])
                    widest = max(length for _, length in owners)
                    if len(value) >= widest:
                        # Too long for even the most generous candidate, so the
                        # unresolved target cannot rescue it. Report it against
                        # that widest column — the kindest reading that is still
                        # a failure.
                        table = next(t for t, n in owners if n == widest)
                        self._record(table, column, value, node.lineno, 'B?')
                    else:
                        self.report.unresolved.append(
                            Unresolved(column, value, owners, self.rel, node.lineno))
        self.generic_visit(node)

    def _resolve_owner(self, target: ast.Attribute, column: str) -> str | None:
        """Which table this assignment writes to. Returns None rather than guess.

        Four ways, tried in descending order of certainty. The last one earns
        its place on a case the first three miss constantly: a variable filled
        by a factory (`journal_entry = create_journal_entry_from_voucher(...)`)
        has no visible constructor, but its name says what it holds — and the
        match only counts if that model really owns this column.
        """
        if isinstance(target.value, ast.Name):
            name = target.value.id

            # 1. The variable was built or queried here.
            model = self._locals.get(name)
            if model:
                return self.index.class_to_table[model]

            # 2. snake_case variable naming its own model.
            guess = ''.join(part.title() for part in name.split('_'))
            table = self.index.class_to_table.get(guess)
            if table and self.index.length_for(table, column) is not None:
                return table

        owners = self.index.by_column[column]

        # 3. Only one table has this column at all.
        if len(owners) == 1:
            return owners[0][0]

        # 4. Several do, but they agree on the limit — so the ambiguity cannot
        #    change the verdict, and refusing to check would be pedantry.
        lengths = {length for _, length in owners}
        if len(lengths) == 1:
            return owners[0][0]

        return None


def scan_tree(root: Path, index: ColumnIndex, report: GuardReport) -> None:
    for path in sorted(root.rglob('*.py')):
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        try:
            tree = ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
        except (SyntaxError, UnicodeDecodeError):
            continue
        report.files += 1
        try:
            rel = str(path.relative_to(REPO_ROOT))
        except ValueError:
            # Scanning outside the repo — the mutation tests do exactly this.
            rel = str(path)
        _FileScanner(path, rel, index, report).visit(tree)


# ─────────────────────────────────────────────────────────────────────────────
# Forms C and D
# ─────────────────────────────────────────────────────────────────────────────

def check_explicit_bindings(index: ColumnIndex, report: GuardReport) -> None:
    for rel_path, constant, table, column in EXPLICIT_BINDINGS:
        path = REPO_ROOT / rel_path
        if not path.exists():
            report.stale_waivers.append(
                f'EXPLICIT_BINDINGS points at a missing file: {rel_path}')
            continue
        tree = ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
        value = None
        for stmt in tree.body:
            if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 \
                    and isinstance(stmt.targets[0], ast.Name) \
                    and stmt.targets[0].id == constant \
                    and isinstance(stmt.value, ast.Constant) \
                    and isinstance(stmt.value.value, str):
                value, line = stmt.value.value, stmt.lineno
        if value is None:
            report.stale_waivers.append(
                f'EXPLICIT_BINDINGS names {constant} in {rel_path}, but no such '
                'module-level string constant exists any more.')
            continue
        if index.length_for(table, column) is None:
            report.stale_waivers.append(
                f'EXPLICIT_BINDINGS targets {table}.{column}, which is not a '
                'String(n) column.')
            continue
        record(report, index, table, column, value, rel_path, line, 'C')


def check_model_constants(index: ColumnIndex, report: GuardReport) -> None:
    """Class-level constants on the models themselves.

    A constant is matched to a column when the column's name occurs in the
    constant's name — STATUS_APPROVED to `status`, VALID_REASON_CODES to
    `reason_code` — so new enums are covered the day they are written, with no
    list to remember to update.
    """
    for class_name, cls in sorted(index.classes.items()):
        table = index.class_to_table[class_name]
        columns = index.by_table.get(table, {})
        if not columns:
            continue
        for attr in sorted(vars(cls)):
            if not attr.isupper():
                continue
            raw = getattr(cls, attr, None)
            if isinstance(raw, str):
                values = [raw]
            elif isinstance(raw, (set, frozenset, tuple, list)) and raw \
                    and all(isinstance(v, str) for v in raw):
                values = sorted(raw)
            else:
                continue
            lowered = attr.lower()
            for column in sorted(columns):
                if column not in lowered:
                    continue
                for value in values:
                    record(report, index, table, column, value,
                           f'{class_name}.{attr}', 0, 'D')


def check_waivers_are_live(report: GuardReport) -> None:
    """A waiver for a value that no longer exists is a lie waiting to be read."""
    found = {v.key for v in report.violations}
    for key in ACCEPTED_ZERO_HEADROOM:
        if key not in found:
            table, column, value = key
            report.stale_waivers.append(
                f'ACCEPTED_ZERO_HEADROOM still waives {table}.{column}={value!r}, '
                'but the guard no longer finds it. Delete the waiver.')


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def run() -> GuardReport:
    index = ColumnIndex.from_app()
    report = GuardReport(columns=index.column_count)
    scan_tree(BACKEND, index, report)
    check_explicit_bindings(index, report)
    check_model_constants(index, report)
    check_waivers_are_live(report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--all', action='store_true',
                        help='also list values that pass but have little headroom')
    args = parser.parse_args()

    report = run()

    print(f'string_capacity_guard: {report.columns} String(n) columns · '
          f'{report.checked} persisted constants checked · {report.files} files')

    if report.unwaived:
        print(f'\n❌ {len(report.unwaived)} violation(s):\n')
        for v in report.unwaived:
            print(v.render(), '\n')

    if report.waived:
        print(f'\n⚠️  {len(report.waived)} accepted zero-headroom value(s):')
        for v in report.waived:
            print(f'   {v.length}/{v.column_length}  {v.table}.{v.column} = {v.value!r}')
            print(f'      {ACCEPTED_ZERO_HEADROOM[v.key]}')

    if report.stale_waivers:
        print(f'\n❌ {len(report.stale_waivers)} stale declaration(s):')
        for msg in report.stale_waivers:
            print(f'   {msg}')

    if args.all and report.tight:
        print(f'\n… {len(report.tight)} value(s) within {TIGHT_MARGIN} chars of the limit:')
        for t in sorted(set(report.tight), key=lambda f: f.headroom):
            print(f'   {t.length}/{t.column_length}  {t.table}.{t.column} = {t.value!r}')

    if report.unresolved:
        print(f'\n… {len(report.unresolved)} assignment(s) whose table could not be '
              'resolved (reported, never guessed):')
        for u in sorted(set(report.unresolved), key=lambda u: (u.column, u.value))[:10]:
            lengths = ', '.join(f'{t}({n})' for t, n in u.candidates)
            print(f'   {u.column} = {u.value!r} → {lengths}  @{u.source}:{u.line}')

    print('\n✅ string_capacity_guard: OK' if report.ok
          else '\n❌ string_capacity_guard: FAILED')
    return 0 if report.ok else 1


if __name__ == '__main__':
    sys.exit(main())
