"""The shop system over HTTPS on its name (ADR-098; the owner, 22 Nov 2026).

- the name (POS_HOST, pos.khaledjewels.com) is served over HTTPS with a Let's
  Encrypt certificate (DNS-01, Cloudflare); HTTP to the name is redirected to
  it, path kept;
- HTTP to the internal address is served as it is today: the fallback when
  the internet is cut (the name needs it to resolve);
- no certificate yet, or one nginx refuses: HTTP keeps serving -- a deploy
  never darkens the shop;
- the Cloudflare token is a file mounted read-only into the certificate tool
  alone: not in Git, not in .env.production, not in any other container; the
  certificates are read by nginx alone, the backend reads only the tool's
  status file;
- the tool is pinned, built by CI and deployed with the same IMAGE_TAG.

Run:
    python -m pytest tests/test_pos_https.py -v
"""
import os
import pathlib
import re
import subprocess

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPOSE = ROOT / 'docker-compose.prod.gitlab.yml'
NGINX = ROOT / 'ops' / 'nginx'
CERTBOT = ROOT / 'ops' / 'certbot'
HOST = 'pos.khaledjewels.com'


def _services():
    return yaml.safe_load(COMPOSE.read_text())['services']


def _mounts(service):
    return [str(v) for v in service.get('volumes', [])]


# ── the compose file ────────────────────────────────────────────────────────

def test_nginx_serves_both_ports_and_reads_the_certificates_read_only():
    nginx = _services()['nginx']
    assert set(nginx['ports']) == {'80:80', '443:443'}
    assert nginx['environment']['POS_HOST'] == '${POS_HOST:-}'
    assert 'tls_certs:/etc/letsencrypt:ro' in _mounts(nginx)


def test_the_certificate_tool_is_its_own_pinned_service_with_the_token_read_only():
    certbot = _services()['certbot']
    assert certbot['image'] == 'registry.gitlab.com/sasalabbadi/khaledjewels/certbot:${IMAGE_TAG:-latest}'
    assert certbot['restart'] == 'unless-stopped'
    assert 'env_file' not in certbot, 'the app secrets are not the certificate tool\'s'
    mounts = _mounts(certbot)
    assert '${CLOUDFLARE_CREDENTIALS_FILE:-./secrets/cloudflare.ini}:/run/secrets/cloudflare.ini:ro' in mounts
    assert 'tls_certs:/etc/letsencrypt' in mounts and 'tls_status:/status' in mounts
    assert set(certbot['environment']) == {'POS_HOST', 'CERTBOT_STAGING', 'CERTBOT_EMAIL'}
    from_line = (CERTBOT / 'Dockerfile').read_text().split('\n')[0]
    assert re.fullmatch(r'FROM certbot/dns-cloudflare:v\d+\.\d+\.\d+', from_line), from_line


def test_the_token_and_the_certificates_reach_no_other_container():
    for name, service in _services().items():
        mounts = ' '.join(_mounts(service))
        if name != 'certbot':
            assert 'cloudflare' not in mounts, name
            assert 'tls_status:/status' not in mounts, name
        if name not in ('certbot', 'nginx'):
            assert 'tls_certs' not in mounts, f'{name}: the private key is nginx\'s and the tool\'s alone'
    backend = _services()['backend']
    assert 'tls_status:/data/tls-status:ro' in _mounts(backend)
    assert backend['environment']['TLS_STATUS_FILE'] == '/data/tls-status/pos-cert.json'


def test_the_token_never_enters_git():
    """Asked of git where it is; in CI's image there is no git (22 Nov 2026: the
    first run of this test failed there on FileNotFoundError) -- and its copy of
    the repository holds the tracked files alone: a secrets folder there is one
    tracked."""
    ignored = (ROOT / '.gitignore').read_text().splitlines()
    assert 'secrets/' in ignored
    try:
        tracked = subprocess.run(['git', 'ls-files', 'secrets'], cwd=ROOT, capture_output=True, text=True).stdout
    except FileNotFoundError:
        folder = ROOT / 'secrets'
        tracked = '\n'.join(str(p) for p in folder.rglob('*')) if folder.exists() else ''
    assert tracked.strip() == ''


def test_ci_builds_the_tool_and_the_deploy_waits_for_it():
    ci = yaml.safe_load((ROOT / '.gitlab-ci.yml').read_text())
    script = '\n'.join(ci['build-certbot']['script'])
    assert '-f ops/certbot/Dockerfile' in script and '/certbot:$CI_COMMIT_SHORT_SHA' in script
    assert 'build-certbot' in ci['deploy-production']['needs']


# ── nginx: the name over HTTPS, the address as today ───────────────────────

def test_the_address_is_served_over_http_as_today():
    default = (NGINX / 'default.conf').read_text()
    assert 'listen 80 default_server;' in default
    assert 'include /etc/nginx/snippets/app.conf;' in default
    assert 'return 301' not in default, 'the fallback is never redirected'
    app = (NGINX / 'app.conf').read_text()
    assert 'location /api/' in app and 'proxy_pass http://backend:8001;' in app


def test_the_name_is_redirected_and_served_over_https():
    https = (NGINX / 'pos-https.conf.template').read_text()
    redirect, secure = https.split('server {')[1:3]
    assert 'listen 80;' in redirect and 'server_name ${POS_HOST};' in redirect
    assert 'return 301 https://${POS_HOST}$request_uri;' in redirect
    assert 'listen 443 ssl;' in secure and 'server_name ${POS_HOST};' in secure
    assert 'ssl_certificate /etc/letsencrypt/live/pos/fullchain.pem;' in secure
    assert 'ssl_certificate_key /etc/letsencrypt/live/pos/privkey.pem;' in secure
    assert 'include /etc/nginx/snippets/app.conf;' in secure
    assert 'Strict-Transport-Security' not in https, 'no HSTS until renewal has held two months'


def test_the_web_image_carries_the_switch():
    docker = (ROOT / 'frontend' / 'Dockerfile').read_text()
    for line in ('COPY ops/nginx/app.conf /etc/nginx/snippets/app.conf',
                 'COPY ops/nginx/pos-https.conf.template /etc/nginx/pos-https.conf.template',
                 'COPY ops/nginx/40-pos-https.sh /docker-entrypoint.d/40-pos-https.sh'):
        assert line in docker, line
    assert 'EXPOSE 80 443' in docker


@pytest.fixture
def switch(tmp_path):
    """The entrypoint's switch, run as sh with its paths in a folder and nginx stubbed."""
    conf, certs = tmp_path / 'conf.d', tmp_path / 'live' / 'pos'
    conf.mkdir()
    log = tmp_path / 'nginx.log'

    def run(host, *, cert=True, nginx_ok=True):
        if cert:
            certs.mkdir(parents=True, exist_ok=True)
            (certs / 'fullchain.pem').write_text('chain')
            (certs / 'privkey.pem').write_text('key')
        stub = tmp_path / 'nginx'
        stub.write_text(f'#!/bin/sh\necho "$@" >> {log}\n' + ('' if nginx_ok else '[ "$1" = "-t" ] && exit 1\n') + 'exit 0\n')
        stub.chmod(0o755)
        env = {**os.environ, 'POS_HOST': host, 'POS_HTTPS_CONF': str(conf / 'pos-https.conf'),
               'POS_HTTPS_TEMPLATE': str(NGINX / 'pos-https.conf.template'), 'POS_CERT_DIR': str(certs),
               'NGINX_BIN': str(stub), 'POS_HTTPS_ONCE': '1'}
        subprocess.run(['sh', str(NGINX / '40-pos-https.sh')], env=env, check=True, capture_output=True)
        made = conf / 'pos-https.conf'
        return made.read_text() if made.exists() else None

    return run


def test_with_its_certificate_the_name_is_switched_on(switch):
    made = switch(HOST)
    assert made is not None and f'server_name {HOST};' in made and '${POS_HOST}' not in made
    assert '$request_uri' in made, "nginx's own variables are left as they are"


def test_without_a_certificate_http_keeps_serving(switch):
    assert switch(HOST, cert=False) is None


def test_without_a_name_nothing_is_switched_on(switch):
    assert switch('') is None


def test_a_name_that_is_not_a_hostname_is_refused(switch):
    assert switch('pos.khaledjewels.com; return 200') is None
    assert switch('pos.khaledjewels.com\nlisten 81') is None


def test_a_certificate_nginx_refuses_is_switched_off_again(switch):
    assert switch(HOST, nginx_ok=False) is None
