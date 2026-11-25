"""The settings change log is append-only -- in the database itself (ADR-102).

What a setting was, who changed it and why is the record the owner reads when
VAT, the main karat or a posting rule moved: a row once written is never
edited or deleted. The one definition of an append-only log is
append_only_trigger.py; this names it for settings_change, for the migration
20261125_settings_change and the test database's DDL.
"""

from append_only_trigger import drop_sql, install_sql

INSTALL_SQL = install_sql('settings_change')
DROP_SQL = drop_sql('settings_change')
