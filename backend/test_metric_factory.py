"""Tests for MetricFactory and RaceMetric implementations."""
import pytest
from metrics import MetricFactory
from metrics.weight_metric import WeightMetric
from metrics.count_metric import CountMetric
from metrics.points_metric import PointsMetric


class TestMetricFactory:
    def test_weight_returns_weight_metric(self):
        m = MetricFactory.create('weight')
        assert isinstance(m, WeightMetric)

    def test_count_returns_count_metric(self):
        m = MetricFactory.create('count')
        assert isinstance(m, CountMetric)

    def test_points_returns_points_metric(self):
        m = MetricFactory.create('points')
        assert isinstance(m, PointsMetric)

    def test_unknown_metric_raises_value_error(self):
        with pytest.raises(ValueError, match='Unknown metric'):
            MetricFactory.create('unknown')

    def test_empty_string_raises_value_error(self):
        with pytest.raises(ValueError):
            MetricFactory.create('')

    def test_valid_names_contains_all_three(self):
        names = MetricFactory.valid_names()
        assert set(names) == {'weight', 'count', 'points'}


class TestMetricProperties:
    def test_weight_key(self):
        assert MetricFactory.create('weight').key == 'weight_g'

    def test_count_key(self):
        assert MetricFactory.create('count').key == 'count'

    def test_points_key(self):
        assert MetricFactory.create('points').key == 'points'

    def test_weight_score_precision(self):
        assert MetricFactory.create('weight').score_precision == 3

    def test_count_score_precision(self):
        assert MetricFactory.create('count').score_precision == 0

    def test_points_score_precision(self):
        assert MetricFactory.create('points').score_precision == 0

    def test_weight_invoice_types(self):
        assert MetricFactory.create('weight').invoice_types == ['بيع']

    def test_count_invoice_types(self):
        assert MetricFactory.create('count').invoice_types == ['بيع']

    def test_points_invoice_types(self):
        # A return takes its original's points back: a sale's (the owner, 10 Oct
        # 2026, ADR-041), a customer purchase's (22 Oct 2026).
        assert MetricFactory.create('points').invoice_types == ['بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء']

    def test_weight_requires_employee_id(self):
        assert MetricFactory.create('weight').require_employee_id is True

    def test_count_requires_employee_id(self):
        assert MetricFactory.create('count').require_employee_id is True

    def test_points_does_not_require_employee_id(self):
        assert MetricFactory.create('points').require_employee_id is False


class TestExtractScore:
    def test_weight_extract_score(self):
        m = MetricFactory.create('weight')
        row = {'weight': 123.456, 'count': 5, 'points': 0}
        assert m.extract_score(row) == 123.456

    def test_count_extract_score(self):
        m = MetricFactory.create('count')
        row = {'weight': 123.456, 'count': 5, 'points': 0}
        assert m.extract_score(row) == 5.0

    def test_points_extract_score(self):
        m = MetricFactory.create('points')
        row = {'weight': 0.0, 'count': 3, 'points': 1500}
        assert m.extract_score(row) == 1500.0

    def test_weight_extract_score_missing_key(self):
        m = MetricFactory.create('weight')
        assert m.extract_score({}) == 0.0

    def test_count_extract_score_none_value(self):
        m = MetricFactory.create('count')
        assert m.extract_score({'count': None}) == 0.0

    def test_points_extract_score_none_value(self):
        m = MetricFactory.create('points')
        assert m.extract_score({'points': None}) == 0.0
