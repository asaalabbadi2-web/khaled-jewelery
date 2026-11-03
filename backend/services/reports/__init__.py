"""The reports, each a service answering the reports' contract (REPORTS ت0-3, ADR-083).

A report reads the books -- the lines accounting.balances.counted_line_filters
counts -- and answers a `Report` (contract.py): its period, its columns, its
rows (each opening what it sums), its totals, the checks it makes of itself,
and when it was read. Its route only parses the request and returns it.
"""
