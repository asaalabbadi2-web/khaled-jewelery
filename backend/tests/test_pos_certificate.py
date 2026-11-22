"""The certificate tool's attempts and what «صحة النظام» says of them (ADR-098 §5).

- each attempt writes its status: when, its result (issued, renewed, not due,
  failed with its reason), the last renewal, the expiry;
- «not due» is not a failure: the tool runs twice a day and renews at 30 days;
- the manager is warned when the last attempt failed -- not only when the
  days run low -- under 20 days left, when the tool has gone silent, when it
  wrote nothing, and when the certificate is a staging one no browser trusts;
- a staging certificate is replaced when the tool is told production, and the
  other way only when said.

Run:
    python -m pytest tests/test_pos_certificate.py -v
"""
import importlib.util
import json
import pathlib
from datetime import datetime, timedelta

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
NOW = datetime(2026, 11, 22, 10, 0, 0)


@pytest.fixture(scope='module')
def tool():
    spec = importlib.util.spec_from_file_location('pos_cert', ROOT / 'ops' / 'certbot' / 'pos_cert.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _cert(serial, days, staging=False):
    return {'serial': serial, 'expires_at': (NOW + timedelta(days=days)).isoformat() + 'Z', 'staging': staging}


# ── the attempt ─────────────────────────────────────────────────────────────

def test_the_command_is_dns_01_for_the_one_name(tool):
    cmd = tool.certbot_command('pos.khaledjewels.com', staging=False, email='', credentials='/run/secrets/c.ini')
    assert cmd[:2] == ['certbot', 'certonly'] and '--dns-cloudflare' in cmd
    assert cmd[cmd.index('--dns-cloudflare-credentials') + 1] == '/run/secrets/c.ini'
    assert cmd[cmd.index('-d') + 1] == 'pos.khaledjewels.com' and cmd[cmd.index('--cert-name') + 1] == 'pos'
    assert '--keep-until-expiring' in cmd and '--non-interactive' in cmd and '--agree-tos' in cmd
    assert '--register-unsafely-without-email' in cmd and '--staging' not in cmd
    assert '*' not in ' '.join(cmd), 'the one name, never a wildcard'
    staged = tool.certbot_command('pos-test.khaledjewels.com', staging=True, email='a@b.c', credentials='c')
    assert '--staging' in staged and staged[staged.index('-m') + 1] == 'a@b.c'


@pytest.mark.parametrize('before, after, code, result', [
    (None, 'S1', 0, 'issued'),
    ('S1', 'S2', 0, 'renewed'),
    ('S1', 'S1', 0, 'not_due'),
    ('S1', 'S1', 1, 'failed'),
    (None, None, 0, 'failed'),
])
def test_each_attempt_is_said_by_what_it_did(tool, before, after, code, result):
    status = tool.next_status({}, now=NOW, host='pos.khaledjewels.com', staging=False,
                              before=before and _cert(before, 40), after=after and _cert(after, 89),
                              returncode=code, output='line one\nAn unexpected error occurred: bad token\n')
    assert status['result'] == result
    assert status['attempt_at'] == NOW.isoformat() + 'Z'
    if result == 'failed':
        assert status['error'] and len(status['error']) <= 300
    else:
        assert status['error'] is None


def test_the_reason_said_is_the_one_after_certbots_heading(tool):
    output = ('Saving debug log\nAn unexpected error occurred:\nService busy; retry later.\n'
              'Ask for help or search for solutions at https://community.letsencrypt.org.\n')
    status = tool.next_status({}, now=NOW, host='h', staging=False, before=_cert('S1', 40), after=_cert('S1', 40),
                              returncode=1, output=output)
    assert status['error'] == 'An unexpected error occurred: Service busy; retry later.'


def test_after_a_failure_the_next_attempt_is_within_the_hour(tool):
    assert tool.next_sleep({'result': 'failed'}, every=43200, retry=3600) == 3600
    assert tool.next_sleep({'result': 'not_due'}, every=43200, retry=3600) == 43200
    assert tool.next_sleep({'result': 'failed'}, every=600, retry=3600) == 600, 'never later than the usual'


def test_the_last_renewal_is_kept_through_attempts_that_renew_nothing(tool):
    first = tool.next_status({}, now=NOW, host='h', staging=False, before=None, after=_cert('S1', 90),
                             returncode=0, output='')
    later = NOW + timedelta(days=3)
    quiet = tool.next_status(first, now=later, host='h', staging=False, before=_cert('S1', 87),
                             after=_cert('S1', 87), returncode=0, output='')
    failed = tool.next_status(quiet, now=later + timedelta(hours=12), host='h', staging=False,
                              before=_cert('S1', 87), after=_cert('S1', 87), returncode=1, output='boom')
    assert quiet['last_renewed_at'] == first['last_renewed_at'] == NOW.isoformat() + 'Z'
    assert failed['last_renewed_at'] == first['last_renewed_at']
    assert failed['expires_at'] == quiet['expires_at'], 'the certificate still served is said'


def test_a_renewal_made_by_hand_between_attempts_is_said_renewed(tool):
    first = tool.next_status({}, now=NOW, host='h', staging=False, before=None, after=_cert('S1', 90),
                             returncode=0, output='')
    assert first['serial'] == 'S1'
    later = NOW + timedelta(hours=12)
    after_hand = tool.next_status(first, now=later, host='h', staging=False, before=_cert('S2', 90),
                                  after=_cert('S2', 90), returncode=0, output='')
    assert after_hand['result'] == 'renewed' and after_hand['last_renewed_at'] == later.isoformat() + 'Z'
    quiet = tool.next_status(after_hand, now=later + timedelta(hours=12), host='h', staging=False,
                             before=_cert('S2', 90), after=_cert('S2', 90), returncode=0, output='')
    assert quiet['result'] == 'not_due'


def test_a_staging_certificate_is_replaced_when_told_production(tool):
    cmd = tool.certbot_command('h', staging=False, email='', credentials='c', current=_cert('S1', 80, staging=True))
    assert '--force-renewal' in cmd and '--break-my-certs' not in cmd
    back = tool.certbot_command('h', staging=True, email='', credentials='c', current=_cert('S1', 80))
    assert '--force-renewal' in back and '--break-my-certs' in back
    same = tool.certbot_command('h', staging=False, email='', credentials='c', current=_cert('S1', 80))
    assert '--force-renewal' not in same


def test_no_token_file_is_a_failure_said_without_running_certbot(tool, tmp_path):
    ran = []
    status = tool.attempt({'POS_HOST': 'h', 'CERTBOT_STAGING': '0'}, run=lambda cmd: ran.append(cmd) or (0, ''),
                          now=NOW, credentials=str(tmp_path / 'missing.ini'), live=str(tmp_path / 'live'),
                          previous={})
    assert ran == [] and status['result'] == 'failed' and 'Cloudflare' in status['error']


def test_without_a_name_the_tool_rests(tool, tmp_path):
    status = tool.attempt({'POS_HOST': ''}, run=lambda cmd: pytest.fail('ran'), now=NOW,
                          credentials='x', live=str(tmp_path), previous={})
    assert status['result'] == 'disabled'


def test_the_status_file_is_written_whole(tool, tmp_path):
    path = tmp_path / 'pos-cert.json'
    tool.write_status(str(path), {'result': 'not_due'})
    assert json.loads(path.read_text()) == {'result': 'not_due'}
    assert list(tmp_path.iterdir()) == [path], 'no half-written file left beside it'


# ── what «صحة النظام» says ──────────────────────────────────────────────────

def _said(tmp_path, monkeypatch, status, now=NOW):
    from services.dashboard_health import certificate
    path = tmp_path / 'pos-cert.json'
    if status is not None:
        path.write_text(json.dumps(status))
    monkeypatch.setenv('TLS_STATUS_FILE', str(path))
    return certificate(now)


def _status(**kw):
    base = {'host': 'pos.khaledjewels.com', 'staging': False, 'attempt_at': NOW.isoformat() + 'Z',
            'result': 'not_due', 'error': None, 'last_renewed_at': (NOW - timedelta(days=10)).isoformat() + 'Z',
            'expires_at': (NOW + timedelta(days=80)).isoformat() + 'Z'}
    return {**base, **kw}


def test_a_healthy_certificate_says_its_expiry_and_its_last_renewal(tmp_path, monkeypatch):
    said = _said(tmp_path, monkeypatch, _status())
    assert said['state'] == 'ok' and said['reasons'] == [] and said['days_left'] == 80
    assert said['last_renewed_at'] == _status()['last_renewed_at']


def test_the_last_attempt_failed_is_a_warning_whatever_the_days_left(tmp_path, monkeypatch):
    said = _said(tmp_path, monkeypatch, _status(result='failed', error='bad token'))
    assert said['state'] == 'alert' and said['reasons'] == ['failed'] and said['error'] == 'bad token'


def test_under_twenty_days_is_a_warning(tmp_path, monkeypatch):
    said = _said(tmp_path, monkeypatch, _status(expires_at=(NOW + timedelta(days=19)).isoformat() + 'Z'))
    assert said['reasons'] == ['expiring'] and said['days_left'] == 19


def test_a_silent_tool_is_a_warning(tmp_path, monkeypatch):
    said = _said(tmp_path, monkeypatch, _status(), now=NOW + timedelta(hours=27))
    assert said['reasons'] == ['stale']


def test_no_status_written_is_a_warning(tmp_path, monkeypatch):
    assert _said(tmp_path, monkeypatch, None)['reasons'] == ['missing']


def test_a_staging_certificate_is_a_warning(tmp_path, monkeypatch):
    assert _said(tmp_path, monkeypatch, _status(staging=True))['reasons'] == ['staging']


def test_a_shop_without_https_yet_says_nothing_to_alarm(tmp_path, monkeypatch):
    assert _said(tmp_path, monkeypatch, {'result': 'disabled', 'attempt_at': NOW.isoformat() + 'Z'})['state'] == 'disabled'


def test_not_configured_is_not_said(monkeypatch):
    from services.dashboard_health import certificate
    monkeypatch.delenv('TLS_STATUS_FILE', raising=False)
    assert certificate(NOW) is None
