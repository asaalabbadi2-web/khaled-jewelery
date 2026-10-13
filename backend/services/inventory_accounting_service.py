"""InventoryAccountingService — GL integration layer for inventory movements.

Architectural boundary:
    InventoryAdjustmentService  (knows about variances)
            ↓
    InventoryAccountingService  (knows about Chart of Accounts)
            ↓
    JournalEntryBuilder         (Phase 5: builds JE lines per bucket)
            ↓
    JournalEntry                (persisted GL record)

This separation means:
  - InventoryAdjustmentService never imports Account or JournalEntry
  - New inventory document types (transfer, manufacturing, reclass) each
    call InventoryAccountingService with their own logic — no GL code leaks
    into the business layer
  - GL mapping (which account per karat/category) lives in one place

Phase 5 status:
    post_adjustment_to_gl() is a stub that logs intent.
    Phase 5 will replace the stub body with real JE creation using
    the accounting mapping table (AccountingMapping / Settings).

Public API (stable — Phase 5 fills the bodies):
    InventoryAccountingService.post_count_differences(session, by=, now=)  # ADR-045 C1, live
    InventoryAccountingService.post_adjustment_to_gl(adjustment)
    InventoryAccountingService.post_opening_entry_to_gl(opening)   # future
    InventoryAccountingService.post_transfer_to_gl(transfer)       # future
"""
from __future__ import annotations
from typing import Optional

ROLE_SHORTAGE = 'inventory_count_shortage'
ROLE_SURPLUS = 'inventory_count_surplus'
REFERENCE_TYPE = 'inventory_count'

from services.inventory_accounting_policy import (
    InventoryAccountingPolicy,
    DefaultInventoryPolicy,
)


class InventoryAccountingService:

    @classmethod
    def post_adjustment_to_gl(
        cls,
        adjustment,
        policy: Optional[InventoryAccountingPolicy] = None,
    ) -> None:
        """Create GL journal entries for an inventory adjustment.

        Args:
            adjustment: InventoryAdjustment instance (status='posted')
            policy:     InventoryAccountingPolicy that decides which accounts
                        to use per line. Defaults to DefaultInventoryPolicy.

        Phase 5 implementation will:
            1. Resolve policy (default if None)
            2. Per line: call policy.accounts_for_line(line) → AccountPair
            3. Build JournalEntry + JournalEntryLine rows
            4. Post the JE (is_posted=True inside same transaction)
            5. Set adjustment.gl_entry_id = je.id
        """
        if policy is None:
            policy = DefaultInventoryPolicy()

        lines = list(getattr(adjustment, 'lines', None) or [])
        total_variance = sum(float(getattr(l, 'variance_weight', 0) or 0) for l in lines)

        print(
            f'[GL STUB Phase 5] Adjustment #{adjustment.id} ready for GL posting — '
            f'branch={adjustment.branch_id}, '
            f'lines={len(lines)}, '
            f'net_variance={round(total_variance, 4)}g, '
            f'policy={policy.label()}, '
            f'reason={adjustment.reason!r}. '
            f'Replace this stub in Phase 5 with InventoryAccountingService._build_je().'
        )
        # Phase 5: uncomment and implement
        # je = cls._build_je(adjustment, policy)
        # adjustment.gl_entry_id = je.id

    # ── The count's differences (ADR-045 C1) ──────────────────────────────────

    @staticmethod
    def _weight_account(role):
        from accounting.mappings import get_account_id_for_mapping
        from models import Account, db
        account_id = get_account_id_for_mapping('افتراضي', role)
        account = db.session.get(Account, account_id) if account_id else None
        if account is None or not account.memo_account_id:
            raise ValueError(f'حساب «{role}» غير مربوط في الربط المحاسبي (أو بلا توأم وزني): '
                             f'يُضبط قبل اعتماد الجرد')
        return int(account.memo_account_id)

    @classmethod
    def post_count_differences(cls, session, *, by, now, reason='', note=''):
        """The approved count's difference entry (ADR-045 C1), or None when
        nothing differs -- see services/inventory_count_service. Refuses (ValueError)
        when a role is not mapped."""
        from accounting.reference_number_service import generate_journal_entry_number
        from dimensions_service import compute_line_analytics
        from models import InventoryCountLine, JournalEntry, JournalEntryLine, SafeBox, db
        from pricing.karat_service import convert_to_main_karat
        from services.repair.entries import write_safe_rows
        from services.stock_ledger import TOLERANCE, allocate

        lines = [l for l in InventoryCountLine.query.filter_by(session_id=session.id).all()
                 if l.counted_weight is not None and abs(float(l.variance or 0.0)) > TOLERANCE]
        if not lines:
            return None
        shortage_w, surplus_w = cls._weight_account(ROLE_SHORTAGE), cls._weight_account(ROLE_SURPLUS)

        # (safe, karat) -> [(category_id, grams)]. Per (safe, karat): a safe line
        # for what was found over, one for what was found short (a line keeps its
        # sign -- the allocation law), each allocated to its categories; between
        # them only the NET is a shortage or a surplus -- the rest moved from one
        # category to another, neither lost nor gained (31 Dec classifies ~22 kg).
        groups = {}
        for l in lines:
            groups.setdefault((int(l.safe_box_id), int(round(l.karat))), []).append(
                (l.category_id, round(float(l.variance), 4)))
        accounts = {int(s.id): int(s.account_id) for s in SafeBox.query.filter(
            SafeBox.id.in_([g[0] for g in groups])).all()}

        description = f'فروق جرد — الجلسة #{session.id}' + (f' — {reason}' if reason else '') + (f' — {note}' if note else '')
        entry = JournalEntry(
            entry_number=generate_journal_entry_number('JE', entry_date=now), date=now,
            description=description[:200], entry_type='عادي', reference_type=REFERENCE_TYPE,
            reference_id=session.id, is_posted=True, is_draft=False, posted_at=now, posted_by=by, created_by=by)
        db.session.add(entry)
        db.session.flush()

        def side(karat, grams, debit):
            main = round(convert_to_main_karat(grams, karat), 6)
            return ({f'debit_{karat}k': grams, 'debit_weight': main} if debit
                    else {f'credit_{karat}k': grams, 'credit_weight': main})

        specs, safe_lines = [], []
        for (safe_id, karat), parts in sorted(groups.items()):
            over = [(c, v) for c, v in parts if v > 0]
            short = [(c, v) for c, v in parts if v < 0]
            found, missing = round(sum(v for _, v in over), 4), round(-sum(v for _, v in short), 4)
            for grams, debit, allocated in ((found, True, over), (missing, False, short)):
                if grams > 0:
                    spec = dict(account_id=accounts[safe_id], description=description[:200], **side(karat, grams, debit))
                    specs.append(spec)
                    safe_lines.append((spec, karat, allocated))
            net = round(found - missing, 4)
            if net > 0:
                specs.append(dict(account_id=surplus_w, description=description[:200], **side(karat, net, False)))
            elif net < 0:
                specs.append(dict(account_id=shortage_w, description=description[:200], **side(karat, -net, True)))

        made = {}
        for spec in specs:
            line = JournalEntryLine(journal_entry_id=entry.id, **spec)
            line.analytic_amount_cash, line.analytic_weight_24k, line.analytic_weight_main = \
                compute_line_analytics(db.session, line)
            db.session.add(line)
            made[id(spec)] = line
        db.session.flush()
        for spec, karat, parts in safe_lines:
            for category_id, v in parts:
                if category_id is not None:
                    allocate(made[id(spec)], karat, category_id, v, by=by, now=now)
        write_safe_rows(entry, specs, by, ref_type=REFERENCE_TYPE)
        return entry

    # ── Phase 5 skeleton (not active) ─────────────────────────────────────────

    @classmethod
    def _build_je(cls, adjustment) -> object:  # → JournalEntry
        """Build and post a JournalEntry for an adjustment.

        Each InventoryAdjustmentLine becomes two JE lines:
            Positive variance:
                DR  inventory_account     variance_weight (weight debit)
                CR  adjustment_account    variance_weight (weight credit)
            Negative variance:
                DR  adjustment_account    |variance_weight| (cash/weight debit)
                CR  inventory_account     |variance_weight| (weight credit)

        Account lookup order:
            1. AccountingMapping keyed by (category_id, karat)
            2. Settings.default_inventory_account_id as fallback
            3. Hard-coded fallback (raises if missing)
        """
        raise NotImplementedError(
            'InventoryAccountingService._build_je() is Phase 5 — not yet implemented.'
        )
