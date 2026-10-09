"""backup_postgres_to_gdrive.ps1 -- the off-site PostgreSQL backup.

Each rule is proven by running the real script under PowerShell 7 with the real
rclone against a *local* crypt remote (a scratch config in tmp_path; the
operator's rclone.conf is never touched). pg_dump / pg_restore / docker are
small shims, so no database or Docker is needed:

- a remote that is not a crypt remote is refused (a dump never leaves in clear text)
- -DryRun creates, uploads and deletes nothing
- a dump is verified before it gets its final name; garbage or empty output with
  exit code 0 is rejected and leaves no .partial behind
- the upload is checked, and a remote holding older files does not fail the check
- passwords never reach a log or a command line (docker gets `-e PGPASSWORD`, no value)
- local retention never goes below the newest KeepLocalMin files
- remote retention deletes only yasargold_pg_*.dump older than the limit, and only
  when enough recent backups exist remotely

Skipped where pwsh or rclone is not installed. PowerShell 5.1 (the Windows
default) is not exercised here -- the script avoids 7-only syntax, but run it
once under powershell.exe before relying on it.

Run:
    python -m pytest tests/test_backup_postgres_to_gdrive_script.py -v
"""
import os
import pathlib
import shutil
import stat
import subprocess
import textwrap
import time

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'backup_postgres_to_gdrive.ps1'
PWSH = shutil.which('pwsh')
RCLONE = shutil.which('rclone')
pytestmark = pytest.mark.skipif(
    PWSH is None or RCLONE is None, reason='pwsh and rclone are required'
)

FAKE_PG_DUMP = textwrap.dedent('''
    #!/bin/bash
    while [ $# -gt 0 ]; do [ "$1" = "--file" ] && f=$2; shift; done
    case "$FAKE_DUMP" in
      garbage) echo "this is not a dump" > "$f" ;;
      empty)   : > "$f" ;;
      *)       printf 'PGDMP\\001 table t\\n' > "$f" ;;
    esac
    exit 0
''').lstrip()

FAKE_PG_RESTORE = textwrap.dedent('''
    #!/bin/bash
    f="${@: -1}"
    head -c 5 "$f" | grep -q PGDMP || { echo "pg_restore: error: not a valid archive" >&2; exit 1; }
    echo "; Archive created"
    echo "1; 1259 16385 TABLE public t yasargold"
''').lstrip()

FAKE_DOCKER = textwrap.dedent('''
    #!/bin/bash
    echo "ARGS: $*" >> "$FAKE_LOG"
    echo "ENV_PGPASSWORD=${PGPASSWORD:-}" >> "$FAKE_LOG"
    m() { echo "$1" | sed "s#^/tmp/#$FAKE_CONT/#"; }
    case "$1" in
      exec) shift; [ "$1" = "-e" ] && shift 2; shift
            case "$1" in
              pg_dump) shift; while [ $# -gt 0 ]; do [ "$1" = "--file" ] && f=$(m "$2"); shift; done
                       printf 'PGDMP\\001 table t\\n' > "$f" ;;
              pg_restore) shift; head -c 5 "$(m "$2")" | grep -q PGDMP && echo "1; 1259 TABLE t" || exit 1 ;;
              sh) f=$(echo "$3" | sed 's/.*< //'); wc -c < "$(m "$f")" ;;
              rm) shift 2; rm -f "$(m "$1")" ;;
            esac ;;
      cp) cp "$(m "${2#*:}")" "$3" ;;
    esac
''').lstrip()


def _exe(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


@pytest.fixture
def env(tmp_path):
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    _exe(bin_dir / 'pg_dump', FAKE_PG_DUMP)
    _exe(bin_dir / 'pg_restore', FAKE_PG_RESTORE)
    _exe(bin_dir / 'docker', FAKE_DOCKER)
    (tmp_path / 'container').mkdir()
    store = tmp_path / 'store'
    store.mkdir()

    conf = tmp_path / 'rclone.conf'
    e = dict(os.environ, RCLONE_CONFIG=str(conf), PATH=f'{bin_dir}:{os.environ["PATH"]}',
             FAKE_LOG=str(tmp_path / 'docker.log'), FAKE_CONT=str(tmp_path / 'container'))
    def rclone(*args):
        return subprocess.run([RCLONE, *args], env=e, capture_output=True, text=True, check=True).stdout
    rclone('config', 'create', 'plain', 'local')
    rclone('config', 'create', 'crypt', 'crypt', f'remote={store}',
           f'password={rclone("obscure", "pw-one").strip()}',
           f'password2={rclone("obscure", "pw-two").strip()}',
           'filename_encryption=standard', 'directory_name_encryption=true')

    class Env:
        pass
    o = Env()
    o.tmp, o.env, o.store, o.rclone = tmp_path, e, store, rclone
    o.backups = tmp_path / 'backups'

    def run(*extra, fake_dump='good', url='postgresql://u:SECRETPW@localhost/db', remote='crypt:', docker=False):
        e2 = dict(e, FAKE_DUMP=fake_dump)
        args = [PWSH, '-NoProfile', '-File', str(SCRIPT), '-BackupDir', str(o.backups), '-RcloneRemote', remote]
        args += ['-UseDockerPgDump'] if docker else ['-DatabaseUrl', url]
        r = subprocess.run(args + list(extra), env=e2, capture_output=True, text=True)
        o.log = (r.stdout or '') + (r.stderr or '')
        return r.returncode
    o.run = run

    def remote_names():
        return sorted(x for x in o.rclone('lsf', 'crypt:').split('\n') if x)
    o.remote_names = remote_names
    o.local = lambda: sorted(p.name for p in o.backups.glob('yasargold_pg_*.dump'))

    def seed_remote(**ages_days):
        d = tmp_path / 'seed'
        d.mkdir(exist_ok=True)
        for name, age in ages_days.items():
            f = d / name
            f.write_text(name)
            t = time.time() - age * 86400
            os.utime(f, (t, t))
        o.rclone('copy', str(d), 'crypt:')
    o.seed_remote = seed_remote

    def seed_local(**ages_days):
        o.backups.mkdir(exist_ok=True)
        for name, age in ages_days.items():
            f = o.backups / name
            f.write_text(name)
            t = time.time() - age * 86400
            os.utime(f, (t, t))
    o.seed_local = seed_local
    return o


def test_unencrypted_remote_is_refused(env):
    assert env.run(remote='plain:') == 1
    assert 'not \'crypt\'' in env.log
    assert env.local() == []
    assert env.remote_names() == []


def test_dry_run_changes_nothing(env):
    env.seed_remote(**{'yasargold_pg_old.dump': 200})
    assert env.run('-DryRun') == 0
    assert env.local() == []
    assert env.remote_names() == ['yasargold_pg_old.dump']
    assert 'yasargold_pg_old.dump: Skipped delete as --dry-run' in env.log


def test_backup_is_verified_uploaded_encrypted_and_checked(env):
    assert env.run() == 0
    (name,) = env.local()
    assert name.startswith('yasargold_pg_') and name.endswith('Z.dump')
    assert not list(env.backups.glob('*.partial'))
    assert env.remote_names() == [name]
    on_disk = [p.name for p in env.store.rglob('*') if p.is_file()]
    assert on_disk and all('yasargold' not in n for n in on_disk), 'remote names must be encrypted'
    assert '0 differences found' in env.log


@pytest.mark.parametrize('kind', ['garbage', 'empty'])
def test_bad_dump_with_exit_zero_is_rejected(env, kind):
    assert env.run(fake_dump=kind) == 1
    assert 'failed verification' in env.log
    assert env.local() == [] and not list(env.backups.glob('*.partial'))
    assert env.remote_names() == []


def test_remote_holding_older_files_does_not_fail_the_check(env):
    env.seed_remote(**{'yasargold_pg_older.dump': 10})
    assert env.run() == 0
    assert len(env.remote_names()) == 2


def test_passwords_never_reach_logs_or_docker_command_line(env):
    env.run(fake_dump='garbage')
    assert 'SECRETPW' not in env.log
    code = env.run('-DockerPassword', 'DOCKERPW', docker=True)
    assert code == 0
    docker_log = (env.tmp / 'docker.log').read_text()
    assert 'ARGS: exec -e PGPASSWORD yasargold-db pg_dump' in docker_log
    assert 'DOCKERPW' not in ''.join(l for l in docker_log.splitlines() if l.startswith('ARGS'))
    assert 'DOCKERPW' not in env.log
    for log in (env.backups / 'logs').glob('*.log'):
        assert 'SECRETPW' not in log.read_text() and 'DOCKERPW' not in log.read_text()
    assert not list((env.tmp / 'container').iterdir()), 'container temp file must be removed'


def test_local_retention_keeps_the_newest_ones_whatever_their_age(env):
    env.seed_local(**{
        'yasargold_pg_a.dump': 2, 'yasargold_pg_b.dump': 20,
        'yasargold_pg_c.dump': 30, 'yasargold_pg_d.dump': 40,
    })
    assert env.run() == 0
    kept = env.local()
    assert 'yasargold_pg_a.dump' in kept and 'yasargold_pg_b.dump' in kept  # newest 3 incl. today's
    assert 'yasargold_pg_c.dump' not in kept and 'yasargold_pg_d.dump' not in kept


def test_remote_retention_deletes_only_old_dumps_and_only_with_enough_recent_ones(env):
    recent = {f'yasargold_pg_r{i}.dump': i for i in range(1, 8)}
    env.seed_remote(**recent, **{'yasargold_pg_old.dump': 100, 'rclone-test.txt': 200})
    assert env.run() == 0
    names = env.remote_names()
    assert 'yasargold_pg_old.dump' not in names
    assert 'rclone-test.txt' in names, 'only yasargold_pg_*.dump may be deleted'
    assert all(n in names for n in recent)


def test_remote_retention_is_skipped_when_few_recent_backups_exist(env):
    env.seed_remote(**{'yasargold_pg_r1.dump': 1, 'yasargold_pg_old.dump': 100})
    assert env.run() == 0
    assert 'yasargold_pg_old.dump' in env.remote_names()
    assert 'remote retention skipped' in env.log


def test_second_run_while_one_is_running_is_refused(env):
    env.backups.mkdir()
    holder = subprocess.Popen([PWSH, '-NoProfile', '-Command',
        f'$f=[IO.File]::Open("{env.backups}/.backup.lock","OpenOrCreate","ReadWrite","None"); Start-Sleep 8'])
    try:
        time.sleep(2)
        assert env.run() == 1
        assert 'already in progress' in env.log
    finally:
        holder.kill()


def test_not_enough_disk_space_stops_before_dumping(env):
    assert env.run('-MinFreeSpaceMB', '999999999') == 1
    assert 'not enough free disk space' in env.log
    assert env.local() == []
