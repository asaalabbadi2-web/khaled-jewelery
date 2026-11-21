"""Every device on the deployed build at its next load (the owner, 21 Nov 2026).

A Flutter web build registers a service worker that keeps the app on the
device: after a deploy, a device -- the handheld reader once -- went on
showing the old build until its site data was cleared. So:

- the production image builds with no service worker (`--pwa-strategy none`);
- nginx revalidates the app's code and manifests on every load (`no-cache`:
  an unchanged file costs a 304), the index never stored.

Run:
    python -m pytest tests/test_web_build_is_never_stale.py -v
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
DOCKERFILE = (ROOT / 'frontend' / 'Dockerfile').read_text(encoding='utf-8')
NGINX = (ROOT / 'ops' / 'nginx' / 'default.conf').read_text(encoding='utf-8')


def _block(pattern: str) -> str:
    found = re.search(pattern + r'\s*\{([^}]*)\}', NGINX)
    assert found, pattern
    return found.group(1)


def test_the_production_web_build_keeps_no_copy_on_the_device():
    builds = [line for line in DOCKERFILE.replace('\\\n', ' ').splitlines() if 'flutter build web' in line]
    assert builds, 'the image builds the web app'
    assert all('--pwa-strategy none' in b for b in builds), 'no service worker keeping an old build'


def test_nginx_revalidates_the_app_s_code_and_never_stores_its_index():
    code = _block(r'location ~\* \\\.\(js\|mjs\|json\|wasm\)\$')
    assert 'Cache-Control "no-cache" always' in code
    assert 'try_files $uri =404' in code, 'a file missing is a 404, never the index served as code'
    assert 'Cache-Control "no-store" always' in _block(r'location = /index\.html')
