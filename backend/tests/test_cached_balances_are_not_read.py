"""No one reads a balance from the cached columns -- the ledger is the balance (BALANCE-001 B3).

Accounts, customers and offices carry cached balance columns (`balance_cash`,
`balance_18k`.., `balance_gold_*`) that update_balance() moves in nine places
and posting never does. On the 2 Oct copy they had drifted far: the customers
screen showed «عميل نقدي» −2,790,158.17 against the ledger's 70,261.82, the
clearing account مدى −270,577 against 2,200. B1-B3 moved every reader that
shows a number or decides on one to the ledger; the models no longer send the
cached columns.

The ratchet: who reads them is frozen here, with the reason -- writers, the
resets, tools. A new reader fails until it is added on purpose, in review;
one that goes must leave the list. (Writing them -- `x.balance_cash -= ...`,
update_balance() -- is not reading.)

Run:
    python -m pytest tests/test_cached_balances_are_not_read.py -v
"""
import pathlib
import re

BACKEND = pathlib.Path(__file__).resolve().parents[1]
SKIP = {'tests', 'venv', '.venv', 'alembic', 'migrations', '_archived', 'graphify-out', 'backups', '__pycache__',
        'instance', 'temp_pdfs', 'tools', 'devtools', 'node_modules', '.pytest_db'}
CACHED = ('balance_cash', 'balance_18k', 'balance_21k', 'balance_22k', 'balance_24k',
          'balance_gold_18k', 'balance_gold_21k', 'balance_gold_22k', 'balance_gold_24k')
READ = re.compile(r'\.(' + '|'.join(CACHED) + r')\b(?!\s*(=|\+=|-=)(?!=))')

ALLOWED = {
    'routes/system.py::_rebuild_all_account_balances': 'rebuilds the cached columns from the ledger',
    'routes/system.py::_reset_transactions': 'the system reset zeroes them',
    'routes/system.py::_reset_nuclear_transactions': 'the system reset zeroes them',
    'dual_system_helpers.py::create_dual_journal_entry': 'a writer of the customer cache; reads it to print before/after',
    'dual_system_helpers.py::get_account_balances': 'dead: only the ungated test_dual_system.py calls it',
    'models.py::get_total_weight': 'dead: only get_account_balances calls it',
    'models.py::get_weight_by_karat': 'dead: nothing calls it',
    'routes/__init__.py::_account_weight_balance_main_karat': 'called by tools/ only (diagnostics, maintenance)',
    'audit_transaction_type_both.py::_gather_info': 'a one-off audit script, not served',
}


def readers():
    found = set()
    for p in BACKEND.rglob('*.py'):
        rel = p.relative_to(BACKEND)
        if set(rel.parts) & SKIP or rel.name.startswith('test_') or rel.name == 'conftest.py':
            continue
        fn = '<module>'
        for line in p.read_text(encoding='utf-8', errors='ignore').split('\n'):
            m = re.match(r'\s*def (\w+)', line)
            if m:
                fn = m.group(1)
            if READ.search(line) and not line.strip().startswith('#'):
                found.add(f'{rel.as_posix()}::{fn}')
    return found


def test_no_new_reader_of_the_cached_balances():
    new = sorted(readers() - set(ALLOWED))
    assert not new, ('these read a balance from the cached columns -- read the ledger '
                     '(services/live_balances, services/party_live_balances): ' + ', '.join(new))


def test_the_list_only_shrinks():
    gone = sorted(set(ALLOWED) - readers())
    assert not gone, f'remove from ALLOWED, they no longer read them: {gone}'


def test_every_entry_says_why():
    assert all(why.strip() for why in ALLOWED.values())
