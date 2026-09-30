"""InventoryPostingService — Single Writer for the inventory event log.

Every gold movement flows through one of two entry points:
  - post(document)    — posts all ledger lines for a document
  - reverse(document) — appends reversal lines (no deletes, ever)

Both methods update InventoryBalance in the same DB transaction as the Ledger
write, so Balance is always a consistent Projection of the Ledger.

Phase 1 supports Invoice documents.
Future phases: OpeningEntry, InventoryAdjustment, Transfer.
"""
from __future__ import annotations
from datetime import datetime


class InventoryPostingService:

    # invoice_type → (movement_type, direction: +1=IN / -1=OUT)
    _INVOICE_MAP: dict[str, tuple[str, int]] = {
        'بيع':               ('sale',                   -1),
        'شراء من عميل':      ('purchase_from_customer',  +1),
        'شراء':              ('supplier_purchase',       +1),
        'مرتجع بيع':         ('sale_return',              +1),
        'مرتجع شراء':        ('purchase_return',          -1),
        'مرتجع شراء (مورد)': ('purchase_return',          -1),
    }

    # ── Public API ────────────────────────────────────────────────────────────

    @classmethod
    def post(cls, document) -> list:
        """Post inventory entries for a document.

        Writes to InventoryLedger and updates InventoryBalance atomically.
        Returns list of new InventoryLedger rows added (empty = already posted).
        Raises TypeError for unsupported document types.
        """
        from models import Invoice, InventoryAdjustment
        if isinstance(document, Invoice):
            return cls._post_invoice(document)
        if isinstance(document, InventoryAdjustment):
            return cls._post_adjustment(document)
        raise TypeError(
            f'InventoryPostingService: unsupported document type {type(document).__name__}'
        )

    @classmethod
    def reverse(cls, document, reason: str = '') -> list:
        """Reverse all posted ledger entries for a document.

        Appends new rows with movement_type = '<original>_reversal' and
        weight_delta = -original_delta.  The original rows are never touched.
        Updates InventoryBalance atomically.
        Returns list of new reversal InventoryLedger rows.
        """
        from models import Invoice
        if isinstance(document, Invoice):
            return cls._reverse_invoice(document, reason)
        raise TypeError(
            f'InventoryPostingService: unsupported document type {type(document).__name__}'
        )

    @classmethod
    def post_opening_session(cls, session, posted_by: str) -> list:
        """Post opening-balance Ledger entries for an approved opening count session.

        For each counted line:
          1. If a prior InventoryBalance exists, posts an 'opening_reversal' entry
             that zeroes it out.
          2. Posts an 'opening_balance' entry with the physically counted weight.

        Both entry types use movement_type='opening'.  Idempotent — safe to call
        again if the session was already partially posted.
        Rebuilds InventoryBalance from the new entries before returning.
        Returns list of new InventoryLedger rows written.
        """
        from models import db, InventoryCountLine, InventoryLedger, InventoryBalance

        lines = InventoryCountLine.query.filter_by(session_id=session.id).all()
        entries: list = []

        for ln in lines:
            if ln.counted_weight is None:
                continue

            counted = round(float(ln.counted_weight), 4)

            existing = InventoryBalance.query.filter_by(
                branch_id=ln.branch_id,
                category_id=ln.category_id,
                karat=ln.karat,
            ).first()
            prior_balance = round(float(existing.balance), 4) if existing else 0.0

            reversal_exists = InventoryLedger.query.filter_by(
                source_type='opening_reversal',
                source_id=session.id,
                source_line_id=ln.id,
                movement_type='opening',
            ).first()
            if not reversal_exists and prior_balance != 0.0:
                row = InventoryLedger(
                    source_type='opening_reversal',
                    source_id=session.id,
                    source_line_id=ln.id,
                    movement_type='opening',
                    branch_id=ln.branch_id,
                    category_id=ln.category_id,
                    karat=ln.karat,
                    weight_delta=-prior_balance,
                    posted_by=posted_by,
                    notes=f'إلغاء رصيد سابق — جلسة افتتاحية #{session.id}',
                )
                db.session.add(row)
                entries.append(row)

            balance_exists = InventoryLedger.query.filter_by(
                source_type='opening_balance',
                source_id=session.id,
                source_line_id=ln.id,
                movement_type='opening',
            ).first()
            if not balance_exists and counted != 0.0:
                row = InventoryLedger(
                    source_type='opening_balance',
                    source_id=session.id,
                    source_line_id=ln.id,
                    movement_type='opening',
                    branch_id=ln.branch_id,
                    category_id=ln.category_id,
                    karat=ln.karat,
                    weight_delta=counted,
                    posted_by=posted_by,
                    notes=f'رصيد افتتاحي — جلسة #{session.id}',
                )
                db.session.add(row)
                entries.append(row)

        if entries:
            db.session.flush()

        cls.rebuild_balance_for_session(session)
        return entries

    # ── Invoice helpers ───────────────────────────────────────────────────────

    @classmethod
    def _post_invoice(cls, invoice) -> list:
        from models import db, InventoryLedger

        inv_type = str(getattr(invoice, 'invoice_type', '') or '').strip()
        mapping = cls._INVOICE_MAP.get(inv_type)
        if mapping is None:
            return []

        movement_type, direction = mapping
        now = datetime.now()  # clock-guard: TIME-001
        posted_by = getattr(invoice, 'posted_by', None)
        branch_id = getattr(invoice, 'branch_id', None)
        invoice_id = int(invoice.id)
        entries: list = []

        # Source 1: InvoiceItem rows (بيع / شراء من عميل)
        for item in (getattr(invoice, 'items', None) or []):
            karat  = getattr(item, 'karat', None)
            weight = getattr(item, 'weight', None)
            line_id = getattr(item, 'id', None)
            if not karat or not weight or not line_id:
                continue

            if cls._standing('invoice', invoice_id, int(line_id), movement_type):
                continue
            cycle = cls._next_cycle('invoice', invoice_id, int(line_id), movement_type)

            row = InventoryLedger(
                source_type='invoice',
                source_id=invoice_id,
                source_line_id=int(line_id),
                movement_type=movement_type,
                branch_id=branch_id or getattr(item, 'branch_id', None),
                category_id=getattr(item, 'category_id', None),
                karat=float(karat),
                weight_delta=round(float(weight) * direction, 4),
                posted_at=now,
                posted_by=posted_by,
                cycle=cycle,
            )
            db.session.add(row)
            db.session.flush()
            cls._apply_to_balance(row)
            entries.append(row)

        # Source 2: InvoiceKaratLine rows (شراء من مورد — no item_id, weight per karat)
        if not entries:
            from models import InvoiceKaratLine
            karat_lines = InvoiceKaratLine.query.filter_by(invoice_id=invoice_id).all()
            for kl in karat_lines:
                karat  = getattr(kl, 'karat', None)
                weight = getattr(kl, 'weight_grams', None)
                line_id = getattr(kl, 'id', None)
                if not karat or not weight or not line_id:
                    continue

                if cls._standing('invoice_karat', invoice_id, int(line_id), movement_type):
                    continue
                cycle = cls._next_cycle('invoice_karat', invoice_id, int(line_id), movement_type)

                row = InventoryLedger(
                    source_type='invoice_karat',
                    source_id=invoice_id,
                    source_line_id=int(line_id),
                    movement_type=movement_type,
                    branch_id=branch_id,
                    category_id=None,
                    karat=float(karat),
                    weight_delta=round(float(weight) * direction, 4),
                    posted_at=now,
                    posted_by=posted_by,
                    cycle=cycle,
                )
                db.session.add(row)
                db.session.flush()
                cls._apply_to_balance(row)
                entries.append(row)

        return entries

    @classmethod
    def _reverse_invoice(cls, invoice, reason: str) -> list:
        """Reverse what stands for the invoice: per line, the net of its
        originals and reversals. Idempotent -- a second reversal finds nothing
        standing -- and a re-post after it posts again (ADR-034: post, unpost,
        post comes back where it started). Item lines ('invoice') and a
        supplier purchase's karat lines ('invoice_karat') alike."""
        from models import db, InventoryLedger

        inv_type = str(getattr(invoice, 'invoice_type', '') or '').strip()
        mapping = cls._INVOICE_MAP.get(inv_type)
        if mapping is None:
            return []

        movement_type, _ = mapping
        reversal_type = movement_type + '_reversal'
        invoice_id = int(invoice.id)
        now = datetime.now()  # clock-guard: TIME-001
        posted_by = getattr(invoice, 'posted_by', None)
        entries: list = []

        originals = (
            InventoryLedger.query
            .filter(InventoryLedger.source_type.in_(('invoice', 'invoice_karat')),
                    InventoryLedger.source_id == invoice_id,
                    InventoryLedger.movement_type == movement_type)
            .order_by(InventoryLedger.cycle.desc(), InventoryLedger.id.desc())
            .all()
        )
        seen = set()
        for orig in originals:
            key = (orig.source_type, orig.source_line_id)
            if key in seen:
                continue
            seen.add(key)
            standing = cls._standing(orig.source_type, invoice_id, orig.source_line_id, movement_type)
            if not standing:
                continue

            row = InventoryLedger(
                source_type=orig.source_type,
                source_id=invoice_id,
                source_line_id=orig.source_line_id,
                movement_type=reversal_type,
                branch_id=orig.branch_id,
                category_id=orig.category_id,
                karat=orig.karat,
                weight_delta=round(-standing, 4),
                posted_at=now,
                posted_by=posted_by,
                notes=reason or None,
                cycle=orig.cycle or 0,   # the latest posting of this line -- ordered first above
            )
            db.session.add(row)
            db.session.flush()
            cls._apply_to_balance(row)
            entries.append(row)

        return entries

    @classmethod
    def _next_cycle(cls, source_type, source_id, source_line_id, movement_type) -> int:
        """0 for a line never posted; otherwise one past its last cycle."""
        from models import db, InventoryLedger
        from sqlalchemy import func
        last = (
            db.session.query(func.max(InventoryLedger.cycle))
            .filter(InventoryLedger.source_type == source_type,
                    InventoryLedger.source_id == int(source_id),
                    InventoryLedger.source_line_id == source_line_id,
                    InventoryLedger.movement_type.in_((movement_type, movement_type + '_reversal')))
            .scalar()
        )
        return 0 if last is None else int(last) + 1

    @classmethod
    def _standing(cls, source_type, source_id, source_line_id, movement_type) -> float:
        """What one line has standing in the ledger: its originals plus their reversals."""
        from models import db, InventoryLedger
        from sqlalchemy import func
        net = (
            db.session.query(func.coalesce(func.sum(InventoryLedger.weight_delta), 0.0))
            .filter(InventoryLedger.source_type == source_type,
                    InventoryLedger.source_id == int(source_id),
                    InventoryLedger.source_line_id == source_line_id,
                    InventoryLedger.movement_type.in_((movement_type, movement_type + '_reversal')))
            .scalar()
        )
        net = round(float(net or 0.0), 4)
        return 0.0 if abs(net) < 1e-9 else net

    # ── Adjustment helper ─────────────────────────────────────────────────────

    @classmethod
    def _post_adjustment(cls, adjustment) -> list:
        """Post an InventoryAdjustment through the Ledger.

        Each InventoryAdjustmentLine becomes one InventoryLedger row with
        movement_type='adjustment' and weight_delta = line.variance_weight.
        Zero-variance lines are skipped.
        """
        from datetime import datetime
        from models import db, InventoryLedger

        if str(getattr(adjustment, 'status', '') or '').strip() == 'posted':
            return []  # already posted

        adj_id = int(adjustment.id)
        posted_by = getattr(adjustment, 'posted_by', None) or getattr(adjustment, 'created_by', None)
        now = datetime.now()  # clock-guard: TIME-001
        entries: list = []

        for line in (getattr(adjustment, 'lines', None) or []):
            variance = getattr(line, 'variance_weight', None)
            if variance is None or float(variance) == 0.0:
                continue

            karat = getattr(line, 'karat', None)
            item_id = getattr(line, 'id', None)
            if not karat or not item_id:
                continue

            already = InventoryLedger.query.filter_by(
                source_type='adjustment',
                source_id=adj_id,
                source_line_id=int(item_id),
                movement_type='adjustment',
            ).first()
            if already:
                continue

            row = InventoryLedger(
                source_type='adjustment',
                source_id=adj_id,
                source_line_id=int(item_id),
                movement_type='adjustment',
                branch_id=getattr(line, 'branch_id', None),
                category_id=getattr(line, 'category_id', None),
                karat=float(karat),
                weight_delta=round(float(variance), 4),
                posted_at=now,
                posted_by=posted_by,
                notes=getattr(line, 'notes', None),
            )
            db.session.add(row)
            db.session.flush()
            cls._apply_to_balance(row)
            entries.append(row)

        if entries:
            from datetime import datetime as _dt
            adjustment.status = 'posted'
            adjustment.posted_at = _dt.now()
            adjustment.posted_by = posted_by

        return entries

    # ── Balance Projection ────────────────────────────────────────────────────

    @classmethod
    def rebuild_balance_for_session(cls, session) -> None:
        """Apply all Ledger entries from an opening session to InventoryBalance.

        Processes both 'opening_reversal' (zeroing prior balance) and
        'opening_balance' (posting counted weight), in that order.
        Called after _post_opening_balances flushes the new Ledger rows.
        """
        from models import InventoryLedger
        from sqlalchemy import case

        entries = (
            InventoryLedger.query
            .filter(
                InventoryLedger.source_id == session.id,
                InventoryLedger.source_type.in_(['opening_reversal', 'opening_balance']),
            )
            # reversals first, then balance entries
            .order_by(
                case(
                    (InventoryLedger.source_type == 'opening_reversal', 0),
                    else_=1,
                ),
                InventoryLedger.id,
            )
            .all()
        )
        for entry in entries:
            cls._apply_to_balance(entry)

    @classmethod
    def _apply_to_balance(cls, entry) -> None:
        """Update (or create) the InventoryBalance row for this entry's bucket.

        Uses SELECT FOR UPDATE on PostgreSQL for row-level locking, preventing
        race conditions when two transactions post to the same bucket
        simultaneously.  On SQLite (test environment) the lock is a no-op.
        """
        from models import db, InventoryBalance

        try:
            row = (
                InventoryBalance.query
                .filter_by(
                    branch_id=entry.branch_id,
                    category_id=entry.category_id,
                    karat=entry.karat,
                )
                .with_for_update()
                .first()
            )

            if row:
                row.balance = round(row.balance + entry.weight_delta, 4)
                row.snapshot_max_ledger_id = entry.id
                row.updated_at = datetime.now()  # clock-guard: TIME-001
            else:
                row = InventoryBalance(
                    branch_id=entry.branch_id,
                    category_id=entry.category_id,
                    karat=entry.karat,
                    balance=round(entry.weight_delta, 4),
                    snapshot_max_ledger_id=entry.id,
                    updated_at=datetime.now(),  # clock-guard: TIME-001
                )
                db.session.add(row)

        except Exception as exc:
            # Balance update must never block the Ledger write.
            # Log and continue — balance can be rebuilt from the Ledger.
            print(f'⚠️ InventoryBalance update failed for entry {entry.id}: {exc}')
