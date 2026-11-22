"""The shop name's certificate (ADR-098): Let's Encrypt by DNS-01 through
Cloudflare, attempted at start and every CERTBOT_EVERY seconds (12 hours) --
within CERTBOT_RETRY (an hour) after a failure -- each attempt's status
written for «صحة النظام» to read.

One command for every attempt -- `certbot certonly --keep-until-expiring`:
with no certificate it issues one, with one due (30 days left of 90) it renews
it, otherwise it does nothing («not_due»: not a failure). A staging
certificate is replaced when told production (and the other way only when
told staging). The token is a file mounted read-only into this container
alone (/run/secrets/cloudflare.ini); it is never read here, never printed.

The status file (/status/pos-cert.json), written whole:
    host, staging, attempt_at, result (issued | renewed | not_due | failed |
    disabled), error (failed only), last_renewed_at, expires_at, serial.

A renewal is a serial other than the one the last status recorded -- so one
made by hand between two attempts (`certbot renew --force-renewal`) is said
renewed at the next attempt, not «not due».

tests/test_pos_certificate.py. Standard library and `cryptography` only (both
in the certbot image).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

CREDENTIALS = '/run/secrets/cloudflare.ini'
LIVE = '/etc/letsencrypt/live/pos'
STATUS = '/status/pos-cert.json'
EVERY = 12 * 3600
RETRY = 3600
PROPAGATION = 30


def _iso(when: datetime) -> str:
    return when.replace(tzinfo=None, microsecond=0).isoformat() + 'Z'


def certbot_command(host, *, staging, email, credentials, current=None) -> list:
    cmd = ['certbot', 'certonly', '--dns-cloudflare', '--dns-cloudflare-credentials', credentials,
           '--dns-cloudflare-propagation-seconds', str(PROPAGATION),
           '-d', host, '--cert-name', 'pos', '--keep-until-expiring', '--non-interactive', '--agree-tos']
    cmd += ['-m', email] if email else ['--register-unsafely-without-email']
    if staging:
        cmd.append('--staging')
    if current is not None and bool(current.get('staging')) != bool(staging):
        cmd.append('--force-renewal')
        if staging:
            cmd.append('--break-my-certs')
    return cmd


def read_certificate(live) -> dict | None:
    path = os.path.join(live, 'cert.pem')
    if not os.path.isfile(path):
        return None
    from cryptography import x509
    with open(path, 'rb') as f:
        cert = x509.load_pem_x509_certificate(f.read())
    expires = getattr(cert, 'not_valid_after_utc', None) or cert.not_valid_after.replace(tzinfo=timezone.utc)
    issuer = cert.issuer.rfc4514_string()
    return {'serial': format(cert.serial_number, 'x'), 'expires_at': _iso(expires), 'staging': 'STAGING' in issuer.upper()}


def _reason(output: str) -> str:
    """The line that says why -- certbot heads it «An unexpected error
    occurred:» and says the reason on the next line."""
    lines = [l.strip() for l in (output or '').splitlines() if l.strip()]
    at = next((i for i in range(len(lines) - 1, -1, -1) if 'error' in lines[i].lower()), None)
    if at is None:
        return (lines[-1] if lines else 'certbot failed')[:300]
    said = lines[at]
    if said.endswith(':') and at + 1 < len(lines):
        said = f'{said} {lines[at + 1]}'
    return said[:300]


def next_sleep(status, *, every, retry) -> int:
    """After a failure the next attempt is within the hour (a busy service,
    a moment without internet), never later than the usual."""
    return min(every, retry) if (status or {}).get('result') == 'failed' else every


def next_status(previous, *, now, host, staging, before, after, returncode, output) -> dict:
    """What one attempt did, and what stays from those before it."""
    if returncode != 0:
        result, error = 'failed', _reason(output)
    elif after is None:
        result, error = 'failed', 'certbot wrote no certificate'
    else:
        known = (previous or {}).get('serial') or (before or {}).get('serial')
        if known is None:
            result, error = 'issued', None
        elif after['serial'] != known:
            result, error = 'renewed', None
        else:
            result, error = 'not_due', None
    served = after or before
    renewed = _iso(now) if result in ('issued', 'renewed') else (previous or {}).get('last_renewed_at')
    return {'host': host, 'staging': bool(served['staging']) if served else bool(staging),
            'attempt_at': _iso(now), 'result': result, 'error': error, 'last_renewed_at': renewed,
            'expires_at': served['expires_at'] if served else None,
            'serial': served['serial'] if served else None}


def attempt(env, *, run, now, credentials=CREDENTIALS, live=LIVE, previous=None) -> dict:
    host = (env.get('POS_HOST') or '').strip()
    if not host:
        return {'host': None, 'attempt_at': _iso(now), 'result': 'disabled', 'error': None,
                'last_renewed_at': None, 'expires_at': None, 'staging': False, 'serial': None}
    staging = (env.get('CERTBOT_STAGING') or '0').strip() in ('1', 'true', 'yes')
    before = read_certificate(live)
    if not os.path.isfile(credentials):
        status = next_status(previous, now=now, host=host, staging=staging, before=before, after=before,
                             returncode=1, output='error: the Cloudflare token file is missing')
        return status
    code, output = run(certbot_command(host, staging=staging, email=(env.get('CERTBOT_EMAIL') or '').strip(),
                                       credentials=credentials, current=before))
    return next_status(previous, now=now, host=host, staging=staging, before=before,
                       after=read_certificate(live), returncode=code, output=output)


def write_status(path, status) -> None:
    folder = os.path.dirname(path) or '.'
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix='.pos-cert-')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(status, f)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def _read_status(path) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _run(cmd):
    done = subprocess.run(cmd, capture_output=True, text=True)
    return done.returncode, (done.stdout or '') + (done.stderr or '')


def main() -> None:
    path = os.environ.get('CERTBOT_STATUS', STATUS)
    every = int(os.environ.get('CERTBOT_EVERY', EVERY))
    retry = int(os.environ.get('CERTBOT_RETRY', RETRY))
    while True:
        status = attempt(os.environ, run=_run, now=datetime.now(timezone.utc), previous=_read_status(path))
        write_status(path, status)
        print(f"pos-cert: {status['result']}" + (f" -- {status['error']}" if status['error'] else ''), flush=True)
        time.sleep(next_sleep(status, every=every, retry=retry))


if __name__ == '__main__':
    sys.exit(main())
