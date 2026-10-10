"""Points-based leaderboard metric — per-item (category, karat) rule engine."""
from __future__ import annotations
from .base import RaceMetric


class PointsMetric(RaceMetric):
    """
    Ranks employees by points derived from InvoiceItem-level profit.

    Calculation:
        bucket_profit = Σ(item.profit_weight × item.karat / main_karat)
        points        = Σ_buckets(bucket_profit × multiplier(category_id, karat))

    Where multiplier comes from PointCalculator (falls back to points_per_gram
    when no rule matches).  With default rules this equals the legacy formula:
        profit_gold × points_per_gram
    because profit_gold = Σ(profit_weight × karat / main_karat) by construction.

    Covers both 'بيع' and 'شراء من عميل' invoice types.
    Attributes invoices to employees via employee_id with posted_by fallback.
    """

    def __init__(
        self,
        rules: list | None = None,
        points_source: str = 'gold_weight',
        cash_amount_per_point: float = 100.0,
        points_per_invoice: float = 1.0,
    ) -> None:
        self._rules = list(rules) if rules else []
        self._points_source = points_source or 'gold_weight'
        self._cash_amount_per_point = max(0.01, float(cash_amount_per_point or 100.0))
        self._points_per_invoice = max(0.0, float(points_per_invoice or 1.0))

    @property
    def invoice_types(self) -> list[str]:
        # A sale return takes its sale's points back in its own period, from the
        # one who sold (the owner, 10 Oct 2026).
        return ['بيع', 'شراء من عميل', 'مرتجع بيع']

    @property
    def require_employee_id(self) -> bool:
        return False

    @property
    def key(self) -> str:
        return 'points'

    @property
    def score_precision(self) -> int:
        return 0

    # ── Phase 1: collect rows ─────────────────────────────────────────────────

    @staticmethod
    def _load_invoices(base_filters: list) -> list:
        from models import Invoice
        from sqlalchemy.orm import subqueryload
        return (
            Invoice.query
            .options(subqueryload(Invoice.items))
            .filter(*base_filters)
            .all()
        )

    # ── Phase 2: infer actor ──────────────────────────────────────────────────

    @staticmethod
    def _normalize_key(value: str) -> str:
        return (value or '').strip().lower()

    @staticmethod
    def _infer_employee_id(inv) -> int | None:
        from models import AppUser, Employee
        from sqlalchemy import func as sa_func

        try:
            if getattr(inv, 'employee_id', None) not in (None, '', 0, '0', False):
                return int(inv.employee_id)
        except Exception:
            pass

        posted_by = PointsMetric._normalize_key(
            str(getattr(inv, 'posted_by', '') or '')
        )
        if not posted_by:
            return None

        try:
            app_user = AppUser.query.filter(
                sa_func.lower(sa_func.trim(AppUser.username)) == posted_by
            ).first()
            if app_user and getattr(app_user, 'employee_id', None):
                return int(app_user.employee_id)
        except Exception:
            pass

        try:
            app_user = AppUser.query.filter(
                sa_func.lower(sa_func.trim(
                    sa_func.coalesce(AppUser.full_name, '')
                )) == posted_by
            ).first()
            if app_user and getattr(app_user, 'employee_id', None):
                return int(app_user.employee_id)
        except Exception:
            pass

        try:
            emp = Employee.query.filter(
                sa_func.lower(sa_func.trim(
                    sa_func.coalesce(Employee.name, '')
                )) == posted_by
            ).first()
            if emp:
                return int(emp.id)
        except Exception:
            pass

        return None

    @staticmethod
    def _is_return(inv) -> bool:
        return str(getattr(inv, 'invoice_type', '') or '').strip() == 'مرتجع بيع'

    @staticmethod
    def _infer_actor(inv) -> tuple[int, str] | None:
        from models import Employee

        # A return is its sale's: the points go back from the one who sold it,
        # not from the one who recorded the return (1089: sold by 18, returned by 19).
        if PointsMetric._is_return(inv):
            inv = getattr(inv, 'original_invoice', None)
            if inv is None:
                return None

        emp_id = PointsMetric._infer_employee_id(inv)
        if emp_id:
            try:
                emp = Employee.query.get(emp_id)
                if emp and (emp.name or '').strip():
                    return int(emp_id), (emp.name or '').strip()
            except Exception:
                pass
            return int(emp_id), f'Employee {int(emp_id)}'

        posted_by_raw = str(getattr(inv, 'posted_by', '') or '').strip()
        if not posted_by_raw:
            return None

        try:
            import zlib
            actor_id = -int(zlib.adler32(posted_by_raw.encode('utf-8')) or 1)
        except Exception:
            actor_id = -1
        return actor_id, posted_by_raw

    # ── Phase 3: group and score ──────────────────────────────────────────────

    @staticmethod
    def _is_purchase(inv) -> bool:
        return str(getattr(inv, 'invoice_type', '') or '').strip() == 'شراء من عميل'

    def _group_and_score(
        self, invoices: list, points_per_gram: float
    ) -> tuple[dict, dict, dict, dict, dict, dict, dict]:
        """Attribute invoices to actors, then compute points via shared engine.

        Returns:
            counts, actor_name_map, sales_amount, purchase_amount,
            pts_total, pts_sales, pts_purchase
        """
        from points.engine import compute_invoices_points

        counts:          dict[int, int]   = {}
        actor_name_map:  dict[int, str]   = {}
        sales_amount:    dict[int, float] = {}
        purchase_amount: dict[int, float] = {}
        pts_total:       dict[int, float] = {}
        pts_sales:       dict[int, float] = {}
        pts_purchase:    dict[int, float] = {}

        # Phase 3a: attribute each invoice to an actor
        actor_sales_invs:    dict[int, list] = {}
        actor_purchase_invs: dict[int, list] = {}

        for inv in invoices:
            actor = self._infer_actor(inv)
            if not actor:
                continue
            actor_id, actor_name = actor
            aid = int(actor_id)
            actor_name_map[aid] = actor_name
            inv_total = float(getattr(inv, 'total', 0.0) or 0.0)
            if self._is_return(inv):
                counts.setdefault(aid, 0)
                sales_amount[aid] = sales_amount.get(aid, 0.0) - inv_total
                actor_sales_invs.setdefault(aid, []).append(inv)
                continue
            counts[aid] = counts.get(aid, 0) + 1

            if self._is_purchase(inv):
                purchase_amount[aid] = purchase_amount.get(aid, 0.0) + inv_total
                actor_purchase_invs.setdefault(aid, []).append(inv)
            else:
                sales_amount[aid] = sales_amount.get(aid, 0.0) + inv_total
                actor_sales_invs.setdefault(aid, []).append(inv)

        # Phase 3b: compute points per actor via canonical engine
        _engine_kwargs = dict(
            points_source=self._points_source,
            cash_amount_per_point=self._cash_amount_per_point,
            points_per_gram=points_per_gram,
            point_rules=self._rules,
            points_per_invoice=self._points_per_invoice,
        )

        for aid in counts:
            s_invs = actor_sales_invs.get(aid, [])
            p_invs = actor_purchase_invs.get(aid, [])
            ps = compute_invoices_points(s_invs, **_engine_kwargs) if s_invs else 0.0
            pp = compute_invoices_points(p_invs, **_engine_kwargs) if p_invs else 0.0
            pts_sales[aid]    = ps
            pts_purchase[aid] = pp
            pts_total[aid]    = ps + pp

        return (
            counts, actor_name_map, sales_amount, purchase_amount,
            pts_total, pts_sales, pts_purchase,
        )

    # ── main interface ────────────────────────────────────────────────────────

    def collect(
        self, base_filters: list, points_per_gram: float
    ) -> tuple[list[dict], list]:
        from models import Employee

        # Phase 1
        invoices = self._load_invoices(base_filters)

        # Phases 2 + 3
        (
            counts, actor_name_map, sales_amount, purchase_amount,
            pts_total, pts_sales, pts_purchase,
        ) = self._group_and_score(invoices, points_per_gram)

        # Phase 4: resolve names/photos, build ranking_raw
        real_ids = [aid for aid in counts if aid > 0]
        name_map:  dict[int, str]    = dict(actor_name_map)
        photo_map: dict[int, object] = {}
        if real_ids:
            try:
                emps = Employee.query.filter(Employee.id.in_(real_ids)).all()
                for e in emps:
                    eid = int(e.id)
                    name_map[eid]  = (e.name or '').strip() or name_map.get(eid, f'Employee {eid}')
                    photo_map[eid] = getattr(e, 'photo', None)
            except Exception:
                pass

        ranking_raw: list[dict] = []
        for actor_id in counts:
            aid = int(actor_id)
            ranking_raw.append({
                'id':              aid,
                'name':            name_map.get(aid) or f'Employee {aid}',
                'photo':           photo_map.get(aid),
                'count':           counts.get(aid, 0),
                'weight':          0.0,
                'points':          max(0, int(round(pts_total.get(aid, 0.0)))),
                'sales_amount':    round(sales_amount.get(aid, 0.0), 2),
                'purchase_amount': round(purchase_amount.get(aid, 0.0), 2),
                'points_sales':    max(0, int(round(pts_sales.get(aid, 0.0)))),
                'points_purchase': max(0, int(round(pts_purchase.get(aid, 0.0)))),
            })

        return ranking_raw, invoices

    def extract_score(self, row: dict) -> float:
        return float(int(row.get('points', 0) or 0))

    def compute_team_weight(
        self,
        base_filters: list,
        points_per_gram: float,
        aux: object = None,
    ) -> tuple[float, int]:
        from models import Invoice
        from points.engine import compute_invoices_points, returned_share

        loaded = aux if aux is not None else Invoice.query.filter(*base_filters).all()
        invoices = [inv for inv in loaded if not self._is_return(inv)]
        returns = [inv for inv in loaded if self._is_return(inv) and getattr(inv, 'original_invoice', None)]

        if self._points_source == 'profit_cash':
            total = sum(
                max(0.0, float(getattr(inv, 'profit_cash', 0.0) or 0.0))
                for inv in invoices
            )
            team_weight_g = round(total, 2)
            team_points   = int(round(total / self._cash_amount_per_point))

        elif self._points_source == 'sales_amount':
            total = sum(
                max(0.0, float(getattr(inv, 'total', 0.0) or 0.0))
                for inv in invoices
            )
            team_weight_g = round(total, 2)
            team_points   = int(round(total / self._cash_amount_per_point))

        elif self._points_source == 'invoice_count':
            count = len(invoices)
            team_weight_g = float(count)
            team_points   = int(round(count * self._points_per_invoice))

        elif self._points_source == 'sold_weight':
            total_w = sum(
                max(0.0, float(item.weight or 0.0))
                for inv in invoices
                for item in (inv.items or [])
            )
            team_weight_g = round(total_w, 3)
            team_points   = int(round(total_w * points_per_gram))

        else:  # gold_weight
            total = sum(
                max(0.0, float(getattr(inv, 'profit_gold', 0.0) or 0.0))
                for inv in invoices
            )
            team_weight_g = round(total, 3)
            team_points   = int(round(total * points_per_gram))

        # Each return takes back its sale's share: its measure and its points.
        for ret in returns:
            original = ret.original_invoice
            if not getattr(original, 'is_posted', False):
                continue
            share = returned_share(ret, original)
            if self._points_source == 'profit_cash':
                team_weight_g -= share * max(0.0, float(original.profit_cash or 0.0))
            elif self._points_source == 'sales_amount':
                team_weight_g -= share * max(0.0, float(original.total or 0.0))
            elif self._points_source == 'invoice_count':
                team_weight_g -= share
            elif self._points_source == 'sold_weight':
                team_weight_g -= share * sum(max(0.0, float(i.weight or 0.0)) for i in (original.items or []))
            else:
                team_weight_g -= share * max(0.0, float(original.profit_gold or 0.0))
        if returns:
            team_points -= int(round(-compute_invoices_points(
                returns, points_source=self._points_source,
                cash_amount_per_point=self._cash_amount_per_point,
                points_per_gram=points_per_gram, point_rules=self._rules,
                points_per_invoice=self._points_per_invoice)))
            team_weight_g = round(team_weight_g, 3)

        return team_weight_g, team_points
