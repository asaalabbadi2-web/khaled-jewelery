"""copy-backups.ps1 puts every automatic backup on the external drive, checked.

The app writes a backup every night at 02:00 (Asia/Riyadh) into the Docker
volume behind /data/backups -- on the production disk, and it keeps only the
last 7. The owner's choice (29 Sep 2026): a Windows scheduled task copies each
one to D:\\yasargold-recovery\\auto, where 30 days are kept. The task, not a
bind mount: an unplugged drive then fails the copy, never the app's start.

These tests run the script under PowerShell 7 against a fake `docker` whose
container is a scratch folder, so each rule is proven without Docker:

- a new backup is copied, verified (a zip holding a PostgreSQL dump), and only
  then given its name; one already on the drive is not copied again
- a drive that is not connected copies nothing and fails loudly
- a broken archive is not kept, and the others are still copied
- a newest backup older than 26 hours fails the run: the app stopped backing up
- 30 days are kept on the drive, and never fewer than the newest 7

Skipped where pwsh is not installed.

Run:
    python -m pytest tests/test_copy_backups_script.py -v
"""
import io
import os
import pathlib
import shutil
import stat
import subprocess
import textwrap
import zipfile
from datetime import datetime, timedelta

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'copy-backups.ps1'
PWSH = shutil.which('pwsh')
pytestmark = pytest.mark.skipif(PWSH is None, reason='PowerShell (pwsh) is not installed')

FAKE_DOCKER = textwrap.dedent(r'''
    #!/bin/bash
    echo "$*" >> "$FAKE_LOG"
    case "$1" in
      exec)
        [ -n "$FAKE_DOCKER_DOWN" ] && { echo "cannot connect to the Docker daemon" >&2; exit 1; }
        ls -1 "$FAKE_VOLUME"; exit 0 ;;
      cp)
        src="${2#*:}"; cp "$FAKE_VOLUME/$(basename "$src")" "$3"; exit $? ;;
    esac
    echo "fake docker: unexpected call: $*" >&2
    exit 97
''').lstrip()


def _zip(dump=b'PGDMP\x01\x0e\x00 real dump bytes', name='database.dump'):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr(name, dump)
        z.writestr('metadata.json', '{"db_backend": "postgres"}')
    return buf.getvalue()


def _name(hours_ago):
    return 'yasargold-backup-' + (datetime.utcnow() - timedelta(hours=hours_ago)).strftime('%Y%m%d-%H%M%S') + '.zip'


@pytest.fixture
def box(tmp_path):
    volume = tmp_path / 'volume'
    drive = tmp_path / 'drive' / 'auto'
    volume.mkdir()
    drive.mkdir(parents=True)
    root = tmp_path / 'khaledjewels'
    root.mkdir()
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    docker = bin_dir / 'docker'
    docker.write_text(FAKE_DOCKER)
    docker.chmod(docker.stat().st_mode | stat.S_IEXEC)
    log = tmp_path / 'docker.log'
    log.write_text('')

    def run(*args, destination=None, **env):
        environ = dict(os.environ, PATH=f'{bin_dir}{os.pathsep}{os.environ["PATH"]}',
                       FAKE_LOG=str(log), FAKE_VOLUME=str(volume))
        environ.update(env)
        result = subprocess.run(
            [PWSH, '-NoProfile', '-File', str(SCRIPT), '-Destination', str(destination or drive),
             '-Root', str(root), *args],
            capture_output=True, text=True, env=environ, timeout=120)
        return result

    run.volume, run.drive, run.root = volume, drive, root
    return run


def test_new_backups_are_copied_checked_and_named_only_when_sound(box):
    new, old = _name(3), _name(27)
    archive = _zip()
    (box.volume / new).write_bytes(archive)
    (box.volume / old).write_bytes(_zip())
    (box.drive / old).write_bytes(b'already here')          # not copied again
    result = box()
    assert result.returncode == 0, result.stdout + result.stderr
    assert (box.drive / new).read_bytes() == archive
    assert (box.drive / old).read_bytes() == b'already here'
    assert not list(box.drive.glob('*.partial'))
    assert 'copied 1' in result.stdout
    assert (box.root / 'logs' / 'backup-copy.log').read_text().count('copied 1') == 1


def test_a_drive_that_is_not_connected_copies_nothing_and_fails(box, tmp_path):
    (box.volume / _name(3)).write_bytes(_zip())
    result = box(destination=tmp_path / 'unplugged' / 'auto')
    assert result.returncode != 0 and 'external drive' in result.stdout
    assert 'external drive' in (box.root / 'logs' / 'backup-copy.log').read_text()


def test_a_broken_archive_is_not_kept_and_the_others_still_are(box):
    good, not_zip, no_dump, not_pg = _name(1), _name(2), _name(3), _name(4)
    (box.volume / good).write_bytes(_zip())
    (box.volume / not_zip).write_bytes(b'half-written')
    (box.volume / no_dump).write_bytes(_zip(name='other.bin'))
    (box.volume / not_pg).write_bytes(_zip(dump=b'SQLite format 3'))
    result = box()
    assert result.returncode != 0
    assert (box.drive / good).exists()
    for bad in (not_zip, no_dump, not_pg):
        assert not (box.drive / bad).exists(), bad
    assert not list(box.drive.glob('*.partial'))
    assert result.stdout.count('REFUSED') == 3


def test_a_stale_newest_backup_fails_the_run(box):
    (box.volume / _name(30)).write_bytes(_zip())
    result = box()
    assert result.returncode != 0 and 'hours old' in result.stdout
    assert len(list(box.drive.glob('*.zip'))) == 1, 'it is still copied'


def test_no_backup_at_all_fails_the_run(box):
    result = box()
    assert result.returncode != 0 and 'no automatic backup' in result.stdout


def test_docker_unreachable_fails_the_run(box):
    result = box(FAKE_DOCKER_DOWN='1')
    assert result.returncode != 0 and 'docker' in result.stdout.lower()


def test_thirty_days_are_kept_and_never_fewer_than_seven(box):
    (box.volume / _name(1)).write_bytes(_zip())
    for days in (2, 3, 4, 5, 6, 10, 29, 31, 45, 60):
        (box.drive / _name(24 * days)).write_bytes(_zip())
    result = box()
    assert result.returncode == 0, result.stdout + result.stderr
    assert len(list(box.drive.glob('*.zip'))) == 8          # 31, 45 and 60 days removed

    for p in box.drive.glob('*.zip'):
        p.unlink()
    for days in range(40, 50):
        (box.drive / _name(24 * days)).write_bytes(_zip())  # all older than 30 days
    result = box()
    assert result.returncode == 0, result.stdout + result.stderr
    kept = sorted(p.name for p in box.drive.glob('*.zip'))
    assert len(kept) == 7, kept                              # the fresh copy + the 6 newest old ones
