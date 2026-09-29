"""update-prod.ps1 deploys only a rehearsed release, and never half of one.

The script runs on the production machine (Windows PowerShell 5.1). These tests
run it under PowerShell 7 against a fake `docker` and a fake `curl` that record
every call and answer as the test says, in a scratch folder standing in for
C:\\Projects\\khaledjewels -- so each rule is proven without touching Docker:

- no -Rehearsed, no deploy; the same tag twice, no deploy
- a missing image stops everything before anything changes
- IMAGE_TAG is written and read back (on 29 Sep 2026 an edit that was never
  saved redeployed the old version while looking like a deploy)
- a failed migration puts the old tag back and restarts nothing
- a release that does not verify (401 / 200, image tags) is reported, not hidden
- -DryRun changes nothing; -Rollback needs no rehearsal
- -Backup dumps with the database server's own pg_dump and prints the
  rehearsal command

Skipped where pwsh is not installed.

Run:
    python -m pytest tests/test_update_prod_script.py -v
"""
import os
import pathlib
import shutil
import stat
import subprocess
import textwrap

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'update-prod.ps1'
PWSH = shutil.which('pwsh')
pytestmark = pytest.mark.skipif(PWSH is None, reason='PowerShell (pwsh) is not installed')

FAKE_DOCKER = textwrap.dedent(r'''
    #!/bin/bash
    echo "$*" >> "$FAKE_LOG"
    args="$*"
    case "$args" in
      "manifest inspect "*)
        tag="${args##*:}"
        for t in $FAKE_TAGS; do [ "$t" = "$tag" ] && exit 0; done
        exit 1 ;;
      *" pull backend scheduler nginx") exit "${FAKE_PULL_EXIT:-0}" ;;
      *"alembic upgrade head"*) exit "${FAKE_MIGRATE_EXIT:-0}" ;;
      *"alembic current"*) echo "20260925_settlement_reason_limits (head)"; exit 0 ;;
      *" up -d --force-recreate backend scheduler nginx") exit "${FAKE_UP_EXIT:-0}" ;;
      *" images --format json")
        tag=$(grep '^IMAGE_TAG=' .env.production | cut -d= -f2)
        echo "[{\"ContainerName\":\"yasargold-backend\",\"Tag\":\"$tag\"},{\"ContainerName\":\"yasargold-scheduler\",\"Tag\":\"$tag\"},{\"ContainerName\":\"yasargold-nginx\",\"Tag\":\"$tag\"}]"
        exit 0 ;;
      "exec yasargold-db printenv POSTGRES_USER") echo "yasargold"; exit 0 ;;
      "exec yasargold-db printenv POSTGRES_DB") echo "yasargold_db"; exit 0 ;;
      "exec yasargold-db pg_dump "*) exit 0 ;;
      "cp yasargold-db:"*) printf 'PGDMP-fake' > "$3"; exit 0 ;;
      "exec yasargold-db rm "*) exit 0 ;;
      "logs "*) echo "scheduler started"; exit 0 ;;
    esac
    echo "fake docker: unexpected call: $args" >&2
    exit 97
''').lstrip()

FAKE_CURL = textwrap.dedent(r'''
    #!/bin/bash
    url="${@: -1}"
    case "$url" in
      */api/auth/check-setup)
        # a backend still booting: nginx answers 502 for the first FAKE_BOOT_CALLS calls
        n=$(( $(cat "$FAKE_LOG.curl" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_LOG.curl"
        if [ "$n" -le "${FAKE_BOOT_CALLS:-0}" ]; then printf "502"; else printf "${FAKE_SETUP_CODE:-200}"; fi ;;
      */api/invoices) printf "${FAKE_ANON_CODE:-401}" ;;
      *) printf "404" ;;
    esac
''').lstrip()


@pytest.fixture
def prod(tmp_path):
    root = tmp_path / 'khaledjewels'
    root.mkdir()
    (root / 'docker-compose.prod.gitlab.yml').write_text('services: {}\n')
    (root / '.env.production').write_text('POSTGRES_USER=yasargold\nIMAGE_TAG=98ea5220\nJWT_SECRET_KEY=x\n')
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    for name, body in (('docker', FAKE_DOCKER), ('curl', FAKE_CURL)):
        path = bin_dir / name
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
    log = tmp_path / 'docker.log'
    log.write_text('')

    def run(*args, **env):
        environ = dict(os.environ, PATH=f'{bin_dir}{os.pathsep}{os.environ["PATH"]}', FAKE_LOG=str(log),
                       FAKE_TAGS='98ea5220 99e86008 11111111')
        environ.update(env)  # a test may override any of the above, FAKE_TAGS included
        result = subprocess.run([PWSH, '-NoProfile', '-File', str(SCRIPT), *args, '-Root', str(root),
                                 '-BaseUrl', 'http://prod.test', '-SettleSeconds', '8'],
                                capture_output=True, text=True, env=environ, timeout=120)
        calls = [line for line in log.read_text().splitlines() if line]
        return result, calls

    def tag():
        return next(line.split('=', 1)[1] for line in (root / '.env.production').read_text().splitlines()
                    if line.startswith('IMAGE_TAG='))

    run.root, run.tag = root, tag
    return run


def test_a_release_is_not_deployed_without_a_rehearsal(prod):
    result, calls = prod('-Tag', '99e86008', '-Deploy')
    assert result.returncode != 0 and 'rehearsal' in result.stdout
    assert prod.tag() == '98ea5220' and calls == []


def test_the_same_tag_twice_is_refused(prod):
    result, calls = prod('-Tag', '98ea5220', '-Deploy', '-Rehearsed')
    assert result.returncode != 0 and 'already runs' in result.stdout
    assert calls == []


def test_a_malformed_tag_is_refused(prod):
    result, _ = prod('-Tag', 'latest', '-Deploy', '-Rehearsed')
    assert result.returncode != 0
    assert prod.tag() == '98ea5220'


def test_a_rehearsed_release_deploys_in_order_and_verifies(prod):
    result, calls = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed')
    assert result.returncode == 0, result.stdout + result.stderr
    assert prod.tag() == '99e86008'
    assert (prod.root / '.previous-image-tag').read_text().strip() == '98ea5220'
    env = (prod.root / '.env.production').read_text()
    assert 'POSTGRES_USER=yasargold' in env and 'JWT_SECRET_KEY=x' in env, 'other lines must survive'
    order = [next(k for k, c in enumerate(calls) if key in c) for key in (
        'manifest inspect registry.gitlab.com/sasalabbadi/khaledjewels/backend:99e86008',
        ' pull backend scheduler nginx', 'alembic upgrade head', 'up -d --force-recreate backend scheduler nginx',
        'images --format json')]
    assert order == sorted(order), calls
    assert 'production now runs 99e86008' in result.stdout
    assert '-Tag 98ea5220 -Deploy -Rollback' in result.stdout


def test_a_missing_image_stops_everything_before_anything_changes(prod):
    result, calls = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed', FAKE_TAGS='98ea5220')
    assert result.returncode != 0 and 'not found' in result.stdout
    assert prod.tag() == '98ea5220'
    assert not any(' pull ' in c or 'up -d' in c for c in calls)


def test_a_failed_migration_puts_the_old_tag_back_and_restarts_nothing(prod):
    result, calls = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed', FAKE_MIGRATE_EXIT='1')
    assert result.returncode != 0 and 'migration failed' in result.stdout
    assert prod.tag() == '98ea5220'
    assert not any('up -d' in c for c in calls)


def test_a_release_that_does_not_verify_is_reported(prod):
    result, _ = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed', FAKE_ANON_CODE='200')
    assert result.returncode != 0 and 'did not verify' in result.stdout


def test_a_dry_run_changes_nothing(prod):
    result, calls = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed', '-DryRun')
    assert result.returncode == 0, result.stdout + result.stderr
    assert prod.tag() == '98ea5220' and calls == []
    assert not (prod.root / '.previous-image-tag').exists()
    assert 'not checked' in result.stdout and ' exist' not in result.stdout, \
        'a dry run checks no image, so it must not say they exist'


def test_every_command_it_prints_goes_through_the_bat_wrapper(prod):
    """A stock Windows client refuses to run a .ps1 directly (execution policy
    Restricted); update-prod.bat passes -ExecutionPolicy Bypass. The commands the
    script prints are pasted as they are -- a rollback under pressure among them --
    so each must be the form that runs. On 29 Sep 2026 the first real backup
    printed `.\\update-prod.ps1 -Tag 2d0b1e37 -Deploy -Rehearsed`."""
    backup, _ = prod('-Tag', '99e86008', '-Backup')
    refused, _ = prod('-Tag', '99e86008', '-Deploy')
    down, _ = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed', FAKE_UP_EXIT='1')
    prod.root.joinpath('.env.production').write_text('IMAGE_TAG=98ea5220\n')
    deployed, _ = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed')
    printed = backup.stdout + refused.stdout + down.stdout + deployed.stdout
    assert '.\\update-prod.ps1' not in printed, printed
    assert '.\\update-prod.bat -Tag 99e86008 -Deploy -Rehearsed' in backup.stdout
    assert '.\\update-prod.bat -Tag 99e86008 -Backup' in refused.stdout
    assert '.\\update-prod.bat -Tag 98ea5220 -Deploy -Rollback' in down.stdout, down.stdout
    assert '.\\update-prod.bat -Tag 98ea5220 -Deploy -Rollback' in deployed.stdout


def test_a_rollback_needs_no_rehearsal(prod):
    result, _ = prod('-Tag', '11111111', '-Deploy', '-Rollback')
    assert result.returncode == 0, result.stdout + result.stderr
    assert prod.tag() == '11111111'


def test_a_backup_uses_the_servers_own_pg_dump_and_prints_the_rehearsal(prod):
    result, calls = prod('-Tag', '99e86008', '-Backup')
    assert result.returncode == 0, result.stdout + result.stderr
    assert any(c.startswith('exec yasargold-db pg_dump -U yasargold -Fc') and c.endswith('yasargold_db')
               for c in calls), calls
    dumps = list((prod.root / 'backups').glob('pre-99e86008-*.dump'))
    assert len(dumps) == 1 and dumps[0].read_bytes().startswith(b'PGDMP')
    assert '--baseline 98ea5220 --release 99e86008' in result.stdout
    assert prod.tag() == '98ea5220', 'a backup never changes the running tag'


def test_a_deploy_never_pulls_or_restarts_the_database(prod):
    """The database changes only on purpose, never as a side effect of an app
    deploy: `postgres:16` is a moving tag, so pulling every image could replace
    the server with a build nobody rehearsed. (The recreation seen on 29 Sep
    2026 had a second cause, the database reading IMAGE_TAG through env_file --
    tests/test_production_compose.py.)"""
    result, calls = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed')
    assert result.returncode == 0, result.stdout + result.stderr
    moves = [c for c in calls if ' pull' in c or ' up ' in c]
    assert moves and all(c.endswith('backend scheduler nginx') for c in moves), moves


def test_verification_waits_for_a_backend_that_is_still_booting(prod):
    """No healthcheck guards the backend: right after a restart nginx answers 502
    until gunicorn is up. A fixed 5-second wait reported a sound release as broken
    -- an invitation to roll back for nothing. It retries until 200 or the limit."""
    result, _ = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed', FAKE_BOOT_CALLS='3')
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'check-setup -> 200' in result.stdout


def test_a_backend_that_never_comes_up_is_reported(prod):
    result, _ = prod('-Tag', '99e86008', '-Deploy', '-Rehearsed', FAKE_BOOT_CALLS='999')
    assert result.returncode != 0 and 'did not verify' in result.stdout
    assert 'check-setup -> 502' in result.stdout
