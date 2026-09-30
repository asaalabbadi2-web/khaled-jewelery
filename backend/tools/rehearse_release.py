#!/usr/bin/env python3
"""Rehearse a release on a copy of production before it ships -- production is never touched.

    python backend/tools/rehearse_release.py \\
        --backup ~/Downloads/yasargold-backup-2026-09-28T....zip \\
        --baseline 98ea5220 --release HEAD

--baseline is what production runs now; --release is what is about to ship (a
git ref, WORKTREE for the uncommitted working tree, or a path to a backend
directory). The backup is the one taken right before the deploy: the app's own
backup zip (database.dump + metadata.json) or a bare pg_dump custom file.

Everything happens on this machine, in scratch databases restored from the
backup and in versions exported with `git archive` (the working tree is never
checked out over). It is hermetic: outbound HTTP from the app goes nowhere, so
no price is fetched, nothing is uploaded, nobody is called.

  1. restore   the backup, with the oldest pg_restore that can read it
  2. baseline  boots on a pristine copy and answers every /api GET as a real
               signed-in account (the shop's manager by default)
  3. release   migrates a second copy exactly as the deploy does
               (alembic upgrade head), boots, and answers the same requests
  4. security  every /api route must refuse an anonymous request, unless public
  5. rollback  the baseline must boot on the MIGRATED copy and answer as before
  6. nights    the nightly jobs run N times; financial tables are fingerprinted
               around each night, and after the first night nothing may change
  7. report    one page, GREEN or RED, with every difference named

Exit status: 0 green, 1 red, 2 the rehearsal itself could not run.

It cannot click through the app in a browser (the Flutter tests and
tests/test_frontend_sends_session.py cover the client), and it cannot see what
production writes after the backup was taken.
"""
from __future__ import annotations

import argparse
import datetime
import getpass
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

TOOLS = pathlib.Path(__file__).resolve().parent
BACKEND = TOOLS.parent
REPO = BACKEND.parent
PROBE = TOOLS / 'rehearse_probe.py'

FINANCIAL_TABLES = (
    'journal_entry', 'journal_entry_line', 'voucher', 'voucher_account_line', 'invoice',
    'invoice_payment', 'invoice_item', 'safe_box_transaction', 'voucher_invoice_gold_attribution',
    'invoice_gold_obligation', 'safe_box', 'account', 'supplier', 'customer',
)
PG_BIN_PATTERNS = ('/opt/homebrew/opt/postgresql@{v}/bin', '/usr/local/opt/postgresql@{v}/bin',
                   '/usr/lib/postgresql/{v}/bin')
DEFAULT_JOBS = 'safebox_reconciliation,books_invariants'
TREE_IGNORE = shutil.ignore_patterns('venv', '.venv', '__pycache__', '.pytest_db', '.pg_backups',
                                     'node_modules', '*.db', ':memory:', '.env', '.env.*')


# ======================================================================
# Pure logic (tests/test_rehearse_release.py)
# ======================================================================

def serious_restore_errors(stderr: str) -> list:
    """pg_restore errors that matter. An archive written by a newer pg_dump
    carries `SET transaction_timeout`, which an older server rejects -- harmless."""
    return [line for line in stderr.splitlines()
            if 'error:' in line.lower() and 'transaction_timeout' not in line]


def unstable_routes(first: dict, second: dict) -> frozenset:
    """Routes that answer differently to two runs of the SAME code on identical
    data -- the clock, the database's own name, a price fetched live. Their
    differences say nothing about a release, so they are named and set aside."""
    a, b = first.get('routes', {}), second.get('routes', {})
    return frozenset(r for r in set(a) & set(b)
                     if a[r]['status'] != b[r]['status'] or a[r]['body'] != b[r]['body'])


def compare_sweeps(before: dict, after: dict, unstable=frozenset()) -> dict:
    """Route by route: status changes, body changes, routes added and removed."""
    a, b = before.get('routes', {}), after.get('routes', {})
    common = sorted(set(a) & set(b))
    return {
        'status': [(r, a[r]['status'], b[r]['status']) for r in common
                   if r not in unstable and a[r]['status'] != b[r]['status']],
        'unstable_status': [(r, a[r]['status'], b[r]['status']) for r in common
                            if r in unstable and a[r]['status'] != b[r]['status']],
        'body': [r for r in common if r not in unstable
                 and a[r]['status'] == b[r]['status'] and a[r]['body'] != b[r]['body']],
        'added': sorted(set(b) - set(a)),
        'removed': sorted(set(a) - set(b)),
    }


def fingerprint_changes(before: dict, after: dict) -> dict:
    return {t: (before.get(t), after.get(t)) for t in sorted(set(before) | set(after))
            if before.get(t) != after.get(t)}


def verdict(r: dict, accepted=()) -> list:
    """The reasons this release must not ship. Empty means green."""
    red = []
    if r.get('restore_errors'):
        red.append(f"restore: {len(r['restore_errors'])} serious pg_restore error(s)")
    for side in ('baseline_boot', 'release_boot', 'rollback_boot'):
        if r.get(side) and not r[side].get('ok'):
            red.append(f'{side.replace("_", " ")} failed')
    if r.get('migration', {}).get('returncode', 0) != 0:
        red.append('migration failed')
    anon = r.get('anonymous') or {}
    if anon.get('guard') and anon.get('open'):
        red.append(f"security: {len(anon['open'])} /api route(s) reach their view without a session")
    if r.get('baseline_guard') and anon and not anon.get('guard'):
        red.append('security: the release removes the deny-by-default guard')
    for label in ('differential', 'rollback'):
        changes = [c for c in (r.get(label) or {}).get('status', []) if c[0] not in accepted]
        if changes:
            red.append(f'{label}: {len(changes)} route(s) answer with a different status')
    for night in r.get('nights', [])[1:]:
        if night.get('changed'):
            red.append(f"night {night['n']}: financial tables changed again ({', '.join(night['changed'])})"
                       ' -- the nightly jobs are not idempotent')
    for night in r.get('nights', []):
        if not night.get('ok', True):
            red.append(f"night {night['n']}: a nightly job failed")
    return red


# ======================================================================
# The machinery
# ======================================================================

def _run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)


def pg_bins(explicit=None):
    if explicit:
        return [(0, pathlib.Path(explicit))]
    found = []
    for v in range(12, 20):
        for pattern in PG_BIN_PATTERNS:
            d = pathlib.Path(pattern.format(v=v))
            if (d / 'pg_restore').exists():
                found.append((v, d))
                break
    return found


def pick_restore_bin(dump: pathlib.Path, bins):
    for version, bindir in bins:
        if _run([bindir / 'pg_restore', '--list', dump]).returncode == 0:
            return version, bindir
    raise SystemExit(f'no pg_restore on this machine can read {dump} (tried {[v for v, _ in bins]})')


class Postgres:
    def __init__(self, bindir: pathlib.Path, user: str):
        self.bindir, self.user = bindir, user

    def url(self, db):
        return f'postgresql://{self.user}@localhost/{db}'

    def sql(self, db, statement, check=True):
        r = _run([self.bindir / 'psql', '-X', '-q', '-At', '-d', db, '-c', statement])
        if check and r.returncode != 0:
            raise RuntimeError(f'psql on {db}: {r.stderr.strip()}')
        return r.stdout.strip()

    def create(self, db, template=None):
        self.sql('postgres', f'DROP DATABASE IF EXISTS "{db}"')
        self.sql('postgres', f'CREATE DATABASE "{db}"' + (f' TEMPLATE "{template}"' if template else ''))

    def drop(self, db):
        self.sql('postgres', f'DROP DATABASE IF EXISTS "{db}"', check=False)

    def restore(self, db, dump):
        self.create(db)
        r = _run([self.bindir / 'pg_restore', '--no-owner', '--no-privileges', '-d', db, dump])
        return serious_restore_errors(r.stderr)

    def fingerprint(self, db) -> dict:
        present = set(self.sql(db, "select table_name from information_schema.tables "
                                   "where table_schema='public'").split('\n'))
        out = {}
        for t in FINANCIAL_TABLES:
            if t in present:
                n, digest = self.sql(db, f"select count(*), md5(coalesce(string_agg(x::text, '|' order by x.id), '')) "
                                         f"from {t} x").split('|')
                out[t] = f'{n}:{digest[:10]}'
        return out


def export_tree(ref: str, dest: pathlib.Path) -> str:
    """A backend version in dest/backend. Returns what it is, for the report."""
    dest.mkdir(parents=True)
    if ref == 'WORKTREE':
        shutil.copytree(BACKEND, dest / 'backend', ignore=TREE_IGNORE)
        return 'WORKTREE (uncommitted working tree)'
    if pathlib.Path(ref).is_dir():
        shutil.copytree(pathlib.Path(ref), dest / 'backend', ignore=TREE_IGNORE)
        return f'directory {ref}'
    sha = _run(['git', '-C', REPO, 'rev-parse', '--short=8', ref])
    if sha.returncode != 0:
        raise SystemExit(f'unknown git ref: {ref}')
    archive = subprocess.Popen(['git', '-C', str(REPO), 'archive', ref, 'backend'], stdout=subprocess.PIPE)
    subprocess.run(['tar', '-x', '-C', str(dest)], stdin=archive.stdout, check=True)
    archive.wait()
    return sha.stdout.strip()


class Tree:
    def __init__(self, root: pathlib.Path, pg: Postgres, work: pathlib.Path, env_extra: dict):
        self.backend, self.pg, self.work, self.env_extra = root / 'backend', pg, work, env_extra

    def env(self, db):
        env = {k: os.environ[k] for k in ('PATH', 'HOME', 'LANG', 'LC_ALL', 'TMPDIR') if k in os.environ}
        env.update(self.env_extra, DATABASE_URL=self.pg.url(db), PYTHONPATH=str(self.backend),
                   BYPASS_AUTH_FOR_DEVELOPMENT='0', PYTHONHASHSEED='0')
        # Postgres cancels a runaway query itself -- a client-side alarm cannot, and
        # the query it abandoned kept running and stalled the requests after it.
        env['PGOPTIONS'] = f"-c statement_timeout={int(self.env_extra.get('_STATEMENT_TIMEOUT_S', 120)) * 1000}"
        # Hermetic: a rehearsal must not fetch prices, upload, or call anyone. Outbound
        # HTTP goes to a closed local port and fails at once; the app falls back to
        # what it saved -- which also keeps two runs' answers comparable.
        for var in ('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy'):
            env[var] = 'http://127.0.0.1:9'
        env['NO_PROXY'] = env['no_proxy'] = 'localhost,127.0.0.1'
        return env

    def probe(self, command, db, *extra, label=None, timeout=1800) -> dict:
        # label keeps two runs of the same command on the same copy apart
        # (the control and the rollback sweep once overwrote each other's file).
        out = self.work / f'{self.backend.parent.name}-{label or command}-{db}.json'
        r = _run([sys.executable, PROBE, command, '--out', out, *extra], cwd=self.backend,
                 env=self.env(db), timeout=timeout)
        if out.exists():
            return json.loads(out.read_text(encoding='utf-8'))
        return {'ok': False, 'error': (r.stderr or r.stdout)[-4000:]}

    def migrate(self, db) -> dict:
        r = _run([sys.executable, '-m', 'alembic', 'upgrade', 'head'], cwd=self.backend,
                 env=self.env(db), timeout=1800)
        return {'returncode': r.returncode, 'tail': (r.stdout + r.stderr)[-1500:]}


def _refresh_sessions(pg: Postgres, db):
    """Copied data is old: the idle-session timeout would reject every token.
    Scratch copies only -- this is exactly the kind of write production never sees."""
    pg.sql(db, "update session_activity set last_activity_at = timezone('utc', now()) where user_type = 'app_user'",
           check=False)


def _extract(backup: pathlib.Path, work: pathlib.Path):
    if zipfile.is_zipfile(backup):
        with zipfile.ZipFile(backup) as z:
            z.extract('database.dump', work)
            meta = json.loads(z.read('metadata.json')) if 'metadata.json' in z.namelist() else {}
        return work / 'database.dump', meta
    return backup, {}


def _sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


# ======================================================================
# The report
# ======================================================================

def render(r: dict, red: list, accepted) -> str:
    lines = [f"# Release rehearsal — {'🟢 GREEN' if not red else '🔴 RED'}", '',
             f"- **Backup:** `{r['backup']}` (sha256 `{r['backup_sha256'][:16]}…`) {r.get('backup_meta') or ''}",
             f"- **Baseline (production now):** `{r['baseline_ref']}` · **Release:** `{r['release_ref']}`",
             f"- **pg_restore:** {r['pg_restore']} · **Python:** {sys.version.split()[0]} · **At:** {r['at']}",
             f"- **Signed-in account for the sweeps:** {r.get('as', '?')}", '']
    if red:
        lines += ['## Why it must not ship', ''] + [f'- ❌ {x}' for x in red] + ['']
    lines += ['## Steps', '',
              f"- Restore: {'clean' if not r['restore_errors'] else r['restore_errors'][:5]}",
              f"- Schema: `{r['alembic_before']}` → `{r['alembic_after']}`",
              f"- Boot: baseline {'✅' if r['baseline_boot'].get('ok') else '❌'} · release "
              f"{'✅' if r['release_boot'].get('ok') else '❌'} · rollback (baseline on migrated copy) "
              f"{'✅' if r['rollback_boot'].get('ok') else '❌'}"]
    anon = r['anonymous']
    if anon.get('ok'):
        lines.append(f"- Security: {'guard present' if anon['guard'] else 'no deny-by-default guard'} · "
                     f"{anon['public']} public route(s) · {len(anon['open'])} open: {anon['open'][:10]}")
    lines.append(f"- Noise: {len(r.get('noise', []))} route(s) answer differently to two runs of the same code "
                 f"on identical copies — set aside, not compared: {r.get('noise', [])}")
    if r.get('phases'):
        lines.append('- Sweep timing (import / sign-in / requests, seconds): ' + ' · '.join(
            f"{k} {v['import']}/{v['sign_in']}/{v['requests']}" for k, v in r['phases'].items() if v))
    if r.get('slowest'):
        lines.append('- Slowest routes (release): ' + ', '.join(f'`{k}` {ms / 1000:.1f}s' for ms, k in r['slowest']))
    for label, title in (('differential', 'Differential (baseline → release, same copy)'),
                         ('rollback', 'Rollback (baseline before migration → baseline after it)')):
        d = r[label]
        lines += ['', f'### {title}', '',
                  f"- status changes: {len(d['status'])}" + (' (accepted: ' + ', '.join(accepted) + ')' if accepted else '')]
        lines += [f'  - `{route}`: {a} → {b}' for route, a, b in d['status']]
        if d.get('unstable_status'):
            lines.append(f"- status changes on noisy routes (not judged): {d['unstable_status']}")
        lines.append(f"- body changes (same status — review): {len(d['body'])}")
        lines += [f'  - `{route}`' for route in d['body'][:40]]
        if d['added'] or d['removed']:
            lines.append(f"- routes added: {d['added'][:20]} · removed: {d['removed'][:20]}")
    lines += ['', '### Nights', '']
    for night in r['nights']:
        lines.append(f"- night {night['n']}: ran {night.get('ran')} · financial tables changed: "
                     f"{night['changed'] or 'none'}" + (f" · ERROR {night.get('error', '')[:200]}" if not night.get('ok', True) else ''))
    return '\n'.join(lines) + '\n'


# ======================================================================

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--backup', required=True, type=pathlib.Path)
    ap.add_argument('--baseline', required=True, help='what production runs now (git ref)')
    ap.add_argument('--release', default='HEAD', help='git ref, WORKTREE, or a backend directory')
    ap.add_argument('--role', default='manager', help='app_user role to sign in as (admin = users.admin)')
    ap.add_argument('--nights', type=int, default=2)
    ap.add_argument('--jobs', default=DEFAULT_JOBS)
    ap.add_argument('--accept', action='append', default=[], metavar='ROUTE',
                    help='a status change on this route is intended (repeatable; named in the report)')
    ap.add_argument('--report', type=pathlib.Path)
    ap.add_argument('--keep', action='store_true', help='keep scratch databases and exported trees')
    ap.add_argument('--statement-timeout', type=int, default=120, metavar='SECONDS',
                    help='Postgres cancels any single query slower than this (default 120)')
    ap.add_argument('--pg-bin')
    ap.add_argument('--pg-user', default=getpass.getuser())
    args = ap.parse_args(argv)

    if not args.backup.exists():
        print(f'no such backup: {args.backup}', file=sys.stderr)
        return 2
    stamp = datetime.datetime.now().strftime('%m%d_%H%M%S')
    work = pathlib.Path(tempfile.mkdtemp(prefix='rehearsal-'))
    dbs = {k: f'rh_{stamp}_{k}' for k in ('pristine', 'base', 'rel')}
    r = {'at': datetime.datetime.now().isoformat(timespec='seconds'), 'backup': args.backup.name}
    pg = None
    try:
        dump, meta = _extract(args.backup, work)
        r['backup_sha256'] = _sha256(args.backup)
        r['backup_meta'] = f"({meta.get('created_at', '')} {meta.get('format', '')})".replace('( )', '') if meta else ''
        version, bindir = pick_restore_bin(dump, pg_bins(args.pg_bin))
        r['pg_restore'] = f'{version} ({bindir})'
        pg = Postgres(bindir, args.pg_user)

        env_extra = {'JWT_SECRET_KEY': 'rehearsal-' + hashlib.sha1(stamp.encode()).hexdigest(),
                     '_STATEMENT_TIMEOUT_S': str(args.statement_timeout)}
        baseline = Tree(work / 'baseline', pg, work, env_extra)
        release = Tree(work / 'release', pg, work, env_extra)
        r['baseline_ref'] = export_tree(args.baseline, work / 'baseline')
        r['release_ref'] = export_tree(args.release, work / 'release')
        r['baseline_guard'] = (baseline.backend / 'api_auth_guard.py').exists()

        print(f"[1/7] restoring {args.backup.name} with pg_restore {version} …", flush=True)
        r['restore_errors'] = pg.restore(dbs['pristine'], dump)
        # pg_restore brings the data, not the planner statistics; production has them.
        pg.sql(dbs['pristine'], 'ANALYZE', check=False)
        pg.create(dbs['base'], template=dbs['pristine'])
        pg.create(dbs['rel'], template=dbs['pristine'])
        for db in (dbs['base'], dbs['rel']):
            _refresh_sessions(pg, db)
        r['alembic_before'] = pg.sql(dbs['base'], 'select version_num from alembic_version', check=False)

        print('[2/7] baseline: boot + sweep …', flush=True)
        r['baseline_boot'] = baseline.probe('boot', dbs['base'])
        base_sweep = baseline.probe('sweep', dbs['base'], '--role', args.role)
        r['as'] = base_sweep.get('as')

        # Control: the SAME baseline code on the second copy, before it is migrated.
        # Whatever differs here is noise, and every later comparison is made on
        # this copy against this sweep.
        control_sweep = baseline.probe('sweep', dbs['rel'], '--role', args.role, label='control-sweep')
        noise = unstable_routes(base_sweep, control_sweep)
        r['noise'] = sorted(noise)

        print('[3/7] release: migrate + boot + sweep …', flush=True)
        r['migration'] = release.migrate(dbs['rel'])
        r['alembic_after'] = pg.sql(dbs['rel'], 'select version_num from alembic_version', check=False)
        r['release_boot'] = release.probe('boot', dbs['rel'])
        rel_sweep = release.probe('sweep', dbs['rel'], '--role', args.role)
        r['differential'] = compare_sweeps(control_sweep, rel_sweep, noise)
        r['slowest'] = sorted(((v.get('ms') or 0, k) for k, v in rel_sweep.get('routes', {}).items()),
                              reverse=True)[:5]

        print('[4/7] security …', flush=True)
        r['anonymous'] = release.probe('anonymous', dbs['rel'])

        print('[5/7] rollback: baseline on the migrated copy …', flush=True)
        r['rollback_boot'] = baseline.probe('boot', dbs['rel'])
        rollback_sweep = baseline.probe('sweep', dbs['rel'], '--role', args.role, label='rollback-sweep')
        r['rollback'] = compare_sweeps(control_sweep, rollback_sweep, noise)

        print(f'[6/7] {args.nights} night(s) of {args.jobs} …', flush=True)
        r['nights'] = []
        for n in range(1, args.nights + 1):
            before = pg.fingerprint(dbs['rel'])
            ran = release.probe('jobs', dbs['rel'], '--names', args.jobs)
            after = pg.fingerprint(dbs['rel'])
            r['nights'].append({'n': n, 'ok': ran.get('ok', False), 'ran': ran.get('ran'),
                                'error': ran.get('error', ''),
                                'changed': sorted(fingerprint_changes(before, after))})

        for key in ('baseline_boot', 'release_boot', 'rollback_boot'):
            r[key] = r.get(key) or {'ok': False}
        r['phases'] = {name: sweep.get('phases') for sweep, name in (
            (base_sweep, 'baseline'), (control_sweep, 'control'), (rel_sweep, 'release'), (rollback_sweep, 'rollback'))}
        for sweep, name in ((base_sweep, 'baseline sweep'), (control_sweep, 'control sweep'),
                            (rel_sweep, 'release sweep'), (rollback_sweep, 'rollback sweep')):
            if not sweep.get('ok'):
                r.setdefault('probe_errors', []).append(f"{name}: {sweep.get('error', '')[-300:]}")

        red = verdict(r, accepted=args.accept) + r.get('probe_errors', [])
        print('[7/7] report', flush=True)
        report = render(r, red, args.accept)
        path = args.report or (work / f'rehearsal-{stamp}.md')
        path.write_text(report, encoding='utf-8')
        print(report)
        print(f'report: {path}')
        return 1 if red else 0
    except subprocess.TimeoutExpired as exc:
        print(f'rehearsal could not finish: {exc}', file=sys.stderr)
        return 2
    finally:
        if not args.keep:
            if pg is not None:
                for db in dbs.values():
                    pg.drop(db)
            if args.report is None:
                # keep only the report, next to where the user can find it
                for child in work.iterdir():
                    if child.is_dir():
                        shutil.rmtree(child, ignore_errors=True)
                    elif not child.name.startswith('rehearsal-'):
                        child.unlink(missing_ok=True)
            else:
                shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
