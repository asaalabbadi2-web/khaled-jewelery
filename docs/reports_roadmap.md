# Reports Roadmap

## Immediate Targets

1. **Sales by Customer** ✅ _Delivered_
   - Metrics: total documents, gross/net sales value, net weight (normalized to main karat), average invoice value, outstanding balance.
   - Visuals: ranked customer table, bar chart comparing top customers by net sales.
   - Filters: date range, include unposted (customer group pending as future enhancement).

2. **Sales by Item** ✅ _Delivered_
   - Metrics: quantity/weight sold, net sales value, returns, average price per gram.
   - Visuals: summary tiles, bar chart for top items, sortable table.
   - Filters: date range, include unposted, limit/order controls.

3. **Inventory Status** ✅ _Delivered (v1)_
   - Metrics: recorded/calculated/effective weights, valuation gaps, slow-moving counts.
   - Visuals: summary tiles, top-value bar chart, status-aware table.
   - Filters: karat chips, zero-stock toggle, slow-days threshold, ordering/limit controls.

Next set of targets:

4. **Inventory Movement Timeline** ✅ _Delivered (v1)_
   - Metrics: inbound/outbound weights by day/week, net movement, document counts.
   - Visuals: dual-line timeline chart, ledger table, movement list.
   - Filters: date range, group interval, karat chips, office chips, include returns/unposted, limit controls.

5. **Sales vs Purchases Trend** ✅ _Delivered (v1)_
   - Metrics: daily/weekly totals for sales and purchases, margin by weight/value.
   - Visuals: dual-line chart plus timeline table with summary chips.
   - Filters: date range, gold type, posted toggle, grouping interval.

6. **Customer Balances Aging** ✅ _Delivered (v1)_
   - Metrics: outstanding gold/cash buckets (current/30/60/90), credit totals, top overdue customers.
   - Visuals: grouped bar chart for cash/weight plus drill-down table with bucket breakdowns.
   - Filters: cutoff date picker, zero-balance toggle, include unposted toggle, customer group filter.

7. **Low Stock Items** ✅ _Delivered (v1)_
   - Metrics: on-hand quantity, normalized weight, shortage deltas, days since movement, analysis count.
   - Visuals: responsive summary tiles, critical-items bar chart, sortable table with status chips.
   - Filters: karat multi-select, office filter, shortage thresholds, include zero/unposted toggles, sort and limit controls.

8. **Gold Price History** ✅ _Delivered (v1)_
   - Metrics: average USD price, SAR conversion (24K & main karat), absolute/percentage change, volatility, extrema points.
   - Visuals: summary tiles, latest-price snapshot, smooth line chart, trend-aware period table.
   - Filters: date range picker, grouping interval (day/week/month), limit selector for number of buckets.

## Sequencing Rationale

- Start with **Sales by Customer**: leverages existing sales data aggregation and extends current API.
- Follow with **Sales by Item** once customer aggregation pattern is stable.
- Move to **Inventory Status** after confirming inventory APIs expose required balances.

## Backend Considerations

- Reuse invoice queries with grouping (customers/items) and respect posted/unposted filters.
- Ensure weight conversions rely on existing `convert_to_main_karat` utilities.
- Provide paginated responses for potentially large result sets.

## Frontend Considerations

- Extend `ApiService` with strongly-typed models for customer/item summaries.
- Reuse summary card components and chart widget with configuration hooks.
- Introduce shared filter widgets (date range, toggle) to avoid duplication.
