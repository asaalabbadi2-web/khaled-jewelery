"""InventoryCountService -- the count on the one reader (ADR-045 C1).

Lifecycle:
    open_session()    -> status='open'      one location (a stock safe) or every one
    populate_lines()  -> one line per (location, category, karat) of the stock,
                         its expected weight frozen at opening
    record_count()    -> counted weight and variance, status='counting'
    close_session()   -> status='closed'    (close policy below)
    approve_session() -> status='approved'  writes the difference entry

The expected weights are the stock itself (services/stock_ledger): the posted
lines on the stock safes and their category allocations. The approval writes
ONE posted entry (reference_type 'inventory_count'): per location and karat, a
safe line for what was found over and one for what was found short (a line
keeps its sign), each allocated to its categories; only their NET reaches the
shortage role's weight account («خسارة الوزن (الفقد)») or the surplus role's
(«زيادة جرد») -- the rest moved between categories, neither lost nor gained.
The books then hold, per (location, category, karat), what was counted. The
owner, 13 Oct 2026. Grams only for now: the value line comes with the two pools'
accounts (ADR-042 phase 3); 2026's last count needs none (ADR-044 opens 2027
at the opening average). Every time is passed in (clock guard).

Close policy:
    session_type='opening':  every line counted (or zero_uncounted) -- the
        catalogue's categories are listed at zero where nothing is held.
    session_type='periodic': partial close with force=True (a piece at the
        jeweller is still ours, «عند الصائغ»).
"""
from __future__ import annotations

from typing import TYPE_CHECKING, List

if TYPE_CHECKING:
    from models import InventoryCountLine, InventoryCountSession

STANDARD_KARATS = (18.0, 21.0, 22.0, 24.0)


class InventoryCountService:

    # ── Open ──────────────────────────────────────────────────────────────────

    @classmethod
    def open_session(cls, branch_id, opened_by: str, now, notes: str = '', blind_count: bool = True,
                     session_type: str = 'periodic', safe_box_id=None) -> 'InventoryCountSession':
        """Open a count of one stock safe (safe_box_id) or of every one (None).

        Raises ValueError when a session of that scope is open or awaits
        approval, or the safe is not a stock location.
        """
        from models import InventoryCountSession, SafeBox, db

        if session_type not in ('periodic', 'opening'):
            raise ValueError(f'session_type غير صالح: {session_type}')
        # A count is of one location (ADR-086 law 2): every location at once
        # was one session nobody could finish -- #5, 397 lines, open from 14 Oct.
        if safe_box_id is None:
            raise ValueError('جلسة الجرد لموقع واحد: اختر الموقع')
        # The full count is blind as a periodic one (the owner, 6 Nov 2026: «عدّ
        # أعمى») -- its lines' expected weights are never shown; its review says
        # each karat's books against the counted.
        box = db.session.get(SafeBox, int(safe_box_id))
        if box is None or not box.stock_location:
            raise ValueError('الخزينة المختارة ليست موقع مخزون')
        statuses = ['open', 'counting', 'closed']
        older = InventoryCountSession.query.filter(InventoryCountSession.safe_box_id.is_(None),
                                                   InventoryCountSession.status.in_(statuses)).first()
        if older is not None:
            raise ValueError(f'جلسة جرد قديمة لكل المواقع (#{older.id}) ما زالت قائمة — تُلغى أولاً')
        active = InventoryCountSession.query.filter(
            InventoryCountSession.safe_box_id == int(safe_box_id),
            InventoryCountSession.status.in_(statuses)).first()
        if active is not None and active.status == 'closed':
            raise ValueError(f'جلسة جرد بانتظار الاعتماد (#{active.id}) لهذا الموقع — اعتمدها أولاً قبل فتح جلسة جديدة.')
        if active:
            raise ValueError(f'جلسة جرد مفتوحة بالفعل (#{active.id}) لهذا الموقع — أغلقها أولاً قبل فتح جلسة جديدة.')

        session = InventoryCountSession(
            branch_id=branch_id, safe_box_id=safe_box_id, status='open', session_type=session_type,
            snapshot_ledger_id=None, blind_count=blind_count, opened_by=opened_by, opened_at=now,
            notes=notes or None)
        db.session.add(session)
        db.session.flush()
        return session

    @staticmethod
    def _scope(session) -> set:
        from models import SafeBox, db
        if session.safe_box_id is not None:
            return {int(session.safe_box_id)}
        # A count of all leaves out what no one counts on the floor: a deposit
        # with an office, confirmed by its statement on its own (ADR-052) --
        # zeroed here, the year's opening count would write it off.
        from models import UNCOUNTED_WITH_ALL
        return {sid for (sid,) in db.session.query(SafeBox.id).filter(
            SafeBox.stock_location.isnot(None), SafeBox.stock_location.notin_(UNCOUNTED_WITH_ALL)).all()}

    @staticmethod
    def _line(session, safe_box_id, category_id, karat):
        from models import InventoryCountLine
        q = InventoryCountLine.query.filter_by(session_id=session.id, safe_box_id=safe_box_id,
                                               karat=float(karat))
        q = q.filter(InventoryCountLine.category_id.is_(None)) if category_id is None \
            else q.filter(InventoryCountLine.category_id == int(category_id))
        return q.first()

    # ── Lines from the stock ──────────────────────────────────────────────────

    @classmethod
    def populate_lines(cls, session) -> List['InventoryCountLine']:
        """One line per (location, category, karat) the stock holds, its expected
        weight frozen now. Idempotent."""
        from models import InventoryCountLine, db
        from services.stock_ledger import stock_balances

        if session.status not in ('open', 'counting'):
            raise ValueError(f'لا يمكن ملء الأسطر — حالة الجلسة: {session.status}')
        scope = cls._scope(session)
        created = []
        for row in stock_balances():
            if row['safe_box_id'] not in scope:
                continue
            if cls._line(session, row['safe_box_id'], row['category_id'], row['karat']) is not None:
                continue
            line = InventoryCountLine(session_id=session.id, branch_id=session.branch_id,
                                      safe_box_id=row['safe_box_id'], category_id=row['category_id'],
                                      karat=float(row['karat']), expected_weight=round(float(row['grams']), 4))
            db.session.add(line)
            created.append(line)
        if created:
            db.session.flush()
        return created

    @classmethod
    def populate_opening_lines(cls, session) -> List['InventoryCountLine']:
        """The full count's lines (the owner, 6 Nov 2026: «حسب نوع الموقع»): what
        the location holds, and at zero the active categories of its kind -- the
        worked ones for the showroom (and a workshop, a transit), the scrap ones
        for a scrap store, none more for a custody. A stopped category is never
        listed; a category missing is added as it is counted. Idempotent."""
        from models import Category, InventoryCountLine, SafeBox, db

        created = cls.populate_lines(session)
        for safe_box_id in sorted(cls._scope(session)):
            kind = db.session.get(SafeBox, safe_box_id).stock_location
            if kind in ('custody', 'deposit'):
                continue
            categories = Category.query.filter(Category.is_active.is_(True),
                                               Category.is_scrap.is_(kind == 'scrap')).order_by(Category.name)
            for cat in categories:
                try:
                    karats = [float(cat.karat)] if cat.karat else list(STANDARD_KARATS)
                except (TypeError, ValueError):
                    karats = list(STANDARD_KARATS)
                for karat in karats:
                    if cls._line(session, safe_box_id, cat.id, karat) is not None:
                        continue
                    line = InventoryCountLine(session_id=session.id, branch_id=session.branch_id,
                                              safe_box_id=safe_box_id, category_id=cat.id, karat=karat,
                                              expected_weight=0.0)
                    db.session.add(line)
                    created.append(line)
        if created:
            db.session.flush()
        return created

    # ── Record ────────────────────────────────────────────────────────────────

    @classmethod
    def record_count(cls, session, category_id, karat: float, counted_weight: float, counted_by: str = '',
                     *, now, safe_box_id=None) -> 'InventoryCountLine':
        """Record (or update) the counted weight of one line; a line the stock did
        not hold is created at an expected zero."""
        from models import InventoryCountLine, db

        if session.status not in ('open', 'counting'):
            raise ValueError(f'لا يمكن تسجيل عد — حالة الجلسة: {session.status}')
        if safe_box_id is None:
            safe_box_id = session.safe_box_id
        if safe_box_id is None:
            raise ValueError('حدّد موقع العدّ (الخزينة) — الجلسة تشمل كل المواقع')
        if int(safe_box_id) not in cls._scope(session):
            raise ValueError('الخزينة ليست ضمن مواقع هذه الجلسة')
        weight = float(counted_weight)
        if weight < 0:
            raise ValueError('الوزن المعدود لا يكون سالبًا')
        # Two places: the scale's and the invoices' (ADR-085, ADR-086 law 4).
        if abs(round(weight, 2) - weight) > 1e-9:
            raise ValueError('الوزن بخانتين عشريتين (0.01 جم)، كما يقرأ الميزان')
        line = cls._line(session, int(safe_box_id), category_id, karat)
        if line is None:
            line = InventoryCountLine(session_id=session.id, branch_id=session.branch_id,
                                      safe_box_id=int(safe_box_id), category_id=category_id,
                                      karat=float(karat), expected_weight=0.0)
            db.session.add(line)
        line.counted_weight = round(float(counted_weight), 4)
        line.variance = round(line.counted_weight - float(line.expected_weight or 0.0), 4)
        line.counted_by = counted_by or None
        line.counted_at = now
        if session.status == 'open':
            session.status = 'counting'
        db.session.flush()
        return line

    # ── Review ────────────────────────────────────────────────────────────────

    @staticmethod
    def karat_review(session) -> list:
        """Per karat of the counted lines: the books (their expected weights,
        frozen at opening), the counted and the difference -- what the approval
        writes per (location, karat). A category's expected means nothing
        before the stock is classified; the karat's total does (ADR-086)."""
        by = {}
        for line in session.lines:
            if line.counted_weight is None:
                continue
            r = by.setdefault(float(line.karat), {'books': 0.0, 'counted': 0.0})
            r['books'] += float(line.expected_weight or 0.0)
            r['counted'] += float(line.counted_weight)
        return [{'karat': k, 'books': round(r['books'], 3), 'counted': round(r['counted'], 3),
                 'difference': round(r['counted'] - r['books'], 3)} for k, r in sorted(by.items())]

    # ── Close ─────────────────────────────────────────────────────────────────

    @classmethod
    def close_session(cls, session, force: bool = False, zero_uncounted: bool = False, *, now) -> int:
        """Close the session; the number of lines left uncounted (or zeroed)."""
        from models import InventoryCountLine, db

        if session.status not in ('open', 'counting'):
            raise ValueError(f'لا يمكن إغلاق جلسة بحالة: {session.status}')
        session_type = session.session_type or 'periodic'
        uncounted_q = InventoryCountLine.query.filter_by(session_id=session.id).filter(
            InventoryCountLine.counted_weight.is_(None))
        uncounted = uncounted_q.count()
        if uncounted:
            if session_type == 'opening' and zero_uncounted:
                for ln in uncounted_q.all():
                    ln.counted_weight = 0.0
                    ln.variance = round(0.0 - float(ln.expected_weight or 0.0), 4)
                    ln.counted_at = now
                db.session.flush()
                uncounted = 0
            elif session_type == 'opening':
                raise ValueError(f'جلسة الرصيد الافتتاحي تتطلب عدّ جميع الأصناف — يوجد {uncounted} صنف لم يُعدّ. '
                                 f'أدخل الوزن الفعلي أو اضغط "سجّل الباقي كصفر" إذا لم يتوفر.')
            elif not force:
                raise ValueError(f'يوجد {uncounted} صنف لم يُعدّ — أكمل العدّ أو استخدم "إغلاق مع تحذير" '
                                 f'إذا كانت بعض القطع خارج المحل.')
        session.status = 'closed'
        session.closed_at = now
        return uncounted

    # ── Approve ───────────────────────────────────────────────────────────────

    @classmethod
    def approve_session(cls, session, approved_by: str, *, now, adjustment_reason: str = '',
                        adjustment_note: str = '') -> tuple:
        """Approve a closed session and write its difference entry.

        Returns (session, entry) -- entry None when nothing differs. Runs in the
        caller's transaction; a refusal (an unmapped role) refuses the approval.
        """
        if session.status != 'closed':
            raise ValueError(f'يجب إغلاق الجلسة أولاً — الحالة الحالية: {session.status}')
        from services.inventory_accounting_service import InventoryAccountingService
        entry = InventoryAccountingService.post_count_differences(
            session, by=approved_by, now=now, reason=adjustment_reason, note=adjustment_note)
        session.status = 'approved'
        session.approved_by = approved_by
        session.approved_at = now
        session.entry_id = entry.id if entry is not None else None
        return session, entry
