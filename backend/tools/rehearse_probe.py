"""The half of tools/rehearse_release.py that runs INSIDE a release tree.

rehearse_release.py exports two versions of the backend (what production runs,
and what is about to ship) and runs this file against each, with
PYTHONPATH=<tree>/backend and DATABASE_URL=<scratch copy>. So every import below
of `app`, `models`, ... is that tree's own code, never the working copy's.

Each command writes its result as JSON to --out and exits non-zero if it could
not run. Nothing in the application imports this file.

    python tools/rehearse_probe.py boot      --out r.json
    python tools/rehearse_probe.py sweep     --out r.json [--role manager] [--exclude REGEX]
    python tools/rehearse_probe.py anonymous --out r.json
    python tools/rehearse_probe.py jobs      --out r.json --names safebox_reconciliation,books_invariants
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import traceback

# Keys whose values change between two identical runs; dropped before comparing bodies.
VOLATILE_KEY = re.compile(
    r'^(generated_at|timestamp|server_time|now|as_of|elapsed\w*|duration\w*|took_ms|request_id|ran_at)$', re.I)

# GET routes a rehearsal must not call: they build backups, reach external
# services, or hand out one-time files.
DEFAULT_EXCLUDE = r'/system/backup/|/system/reset/|/temp-pdf/'

# Nightly jobs that are safe to run on a copy: they read the books and, at most,
# write findings or statement rows. Money-moving jobs (clearing settlement) are
# deliberately absent.
JOBS = {
    'safebox_reconciliation': ('safebox_reconciliation_scheduler', 'SafeboxReconciliationScheduler', 'repair_job'),
    'books_invariants': ('books_invariants_scheduler', 'BooksInvariantsScheduler', 'job'),
}


def normalize(obj):
    """Drop volatile keys, recursively, so two identical answers compare equal."""
    if isinstance(obj, dict):
        return {k: normalize(v) for k, v in obj.items() if not VOLATILE_KEY.match(str(k))}
    if isinstance(obj, list):
        return [normalize(v) for v in obj]
    return obj


def body_digest(data: bytes) -> str:
    try:
        payload = json.dumps(normalize(json.loads(data.decode('utf-8'))), sort_keys=True, ensure_ascii=False)
        return hashlib.sha1(payload.encode('utf-8')).hexdigest()[:12]
    except (ValueError, UnicodeDecodeError):
        return 'raw:' + hashlib.sha1(data).hexdigest()[:12]


def sample_url(rule) -> str:
    from werkzeug.routing import FloatConverter, IntegerConverter, UUIDConverter

    def value(name):
        conv = rule._converters.get(name)
        if isinstance(conv, IntegerConverter):
            return '1'
        if isinstance(conv, FloatConverter):
            return '1.0'
        if isinstance(conv, UUIDConverter):
            return '00000000-0000-0000-0000-000000000000'
        return 'x'
    return re.sub(r'<(?:[^:<>]+:)?([^<>]+)>', lambda m: value(m.group(1)), rule.rule)


def cmd_boot(args) -> dict:
    from app import app
    return {'ok': True, 'rules': sum(1 for _ in app.url_map.iter_rules())}


def cmd_sweep(args) -> dict:
    """Every /api GET route, as one real signed-in account, in a fixed order."""
    from app import app
    from auth_decorators import generate_token
    from models import AppUser, User

    with app.app_context():
        user = AppUser.query.filter_by(role=args.role, is_active=True).first() if args.role != 'admin' else None
        who = f'app_user:{args.role}'
        if user is None:
            user = User.query.filter_by(is_admin=True, is_active=True).first()
            who = 'users:admin'
        token = generate_token(user)

    # No per-request alarm: a Python signal cannot cancel a query already running
    # on the server -- it kept running there and stalled the requests after it.
    # The orchestrator sets PGOPTIONS statement_timeout; Postgres cancels cleanly.
    exclude = re.compile(args.exclude)
    client = app.test_client()
    routes = {}
    for rule in sorted(app.url_map.iter_rules(), key=lambda r: r.rule):
        if not rule.rule.startswith('/api/') or 'GET' not in rule.methods or exclude.search(rule.rule):
            continue
        started = time.monotonic()
        try:
            resp = client.get(sample_url(rule), headers={'Authorization': f'Bearer {token}'})
            routes[rule.rule] = {'status': resp.status_code, 'body': body_digest(resp.get_data()),
                                 'ms': int((time.monotonic() - started) * 1000)}
        except Exception as exc:  # a route that raises is a finding, not a crash of the rehearsal
            routes[rule.rule] = {'status': f'EXC {type(exc).__name__}', 'body': None,
                                 'ms': int((time.monotonic() - started) * 1000)}
    return {'ok': True, 'as': who, 'routes': routes}


def cmd_anonymous(args) -> dict:
    """Which /api routes an anonymous request reaches. Request hooks only: no view runs."""
    from app import app
    try:
        from api_auth_guard import PUBLIC_API_ROUTES
        guard = True
    except ImportError:
        PUBLIC_API_ROUTES, guard = {}, False

    open_routes = []
    for rule in app.url_map.iter_rules():
        if not rule.rule.startswith('/api/'):
            continue
        for method in sorted(rule.methods - {'HEAD', 'OPTIONS'}):
            if (rule.rule, method) in PUBLIC_API_ROUTES:
                continue
            with app.test_request_context(sample_url(rule), method=method):
                resp = app.preprocess_request()
            status = None if resp is None else (resp[1] if isinstance(resp, tuple) else getattr(resp, 'status_code', resp))
            if status != 401:
                open_routes.append(f'{method} {rule.rule}')
    return {'ok': True, 'guard': guard, 'public': len(PUBLIC_API_ROUTES), 'open': sorted(open_routes)}


def cmd_jobs(args) -> dict:
    """One night: each named job, through the entry point its scheduler calls."""
    import importlib
    from app import app

    ran, absent = [], []
    for name in [n for n in args.names.split(',') if n]:
        module_name, class_name, method = JOBS[name]
        try:
            cls = getattr(importlib.import_module(module_name), class_name)
        except (ImportError, AttributeError):
            absent.append(name)
            continue
        getattr(cls(app), method)()
        ran.append(name)
    return {'ok': True, 'ran': ran, 'absent': absent}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('command', choices=['boot', 'sweep', 'anonymous', 'jobs'])
    parser.add_argument('--out', required=True)
    parser.add_argument('--role', default='manager')
    parser.add_argument('--exclude', default=DEFAULT_EXCLUDE)
    parser.add_argument('--names', default='')
    args = parser.parse_args(argv)
    try:
        result = globals()[f'cmd_{args.command}'](args)
        code = 0
    except Exception:
        result, code = {'ok': False, 'error': traceback.format_exc()[-4000:]}, 1
    with open(args.out, 'w', encoding='utf-8') as fh:
        json.dump(result, fh, ensure_ascii=False, indent=1, sort_keys=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
