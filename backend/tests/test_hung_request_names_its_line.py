"""A request gunicorn kills for hanging leaves its stack in the log (HANG-001).

30 Sep 2026: editing invoice 3170 on production hung twice; gunicorn logged
«WORKER TIMEOUT» and, a second later, «was sent SIGKILL» -- and nothing else.
On timeout gunicorn sends SIGABRT first, but its handler is Python code, which
runs only between bytecodes: a worker blocked inside C (libpq waiting on a lock)
never runs it and dies by SIGKILL without a word. The same edit on a restored
copy took 0.4 s, so the log was the only witness and it said nothing.

faulthandler's SIGABRT handler is C, it runs at once, and it writes every
thread's Python stack to stderr -- the file and the line the request stopped on.

The case here is the one production most likely hit: a request waiting on a
PostgreSQL lock another connection holds.

Run:
    python -m pytest tests/test_hung_request_names_its_line.py -v
"""
import os
import socket
import subprocess
import sys
import textwrap
import time
import urllib.request

import psycopg2

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(BACKEND)
LOCK_KEY = 30092026


def _free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def test_a_killed_request_writes_where_it_stopped(tmp_path):
    (tmp_path / 'blocking_app.py').write_text(textwrap.dedent(f'''
        import os, psycopg2

        def waiting_on_a_lock_another_connection_holds():
            conn = psycopg2.connect(os.environ['DATABASE_URL'])
            conn.cursor().execute('select pg_advisory_lock({LOCK_KEY})')

        def app(environ, start_response):
            waiting_on_a_lock_another_connection_holds()
            start_response('200 OK', [])
            return [b'']
    '''))
    holder = psycopg2.connect(os.environ['DATABASE_URL'])
    holder.cursor().execute(f'select pg_advisory_lock({LOCK_KEY})')
    port = _free_port()
    # Production's own config file; only the timeout is shortened for the test.
    server = subprocess.Popen(
        [sys.executable, '-m', 'gunicorn', '-c', os.path.join(BACKEND, 'gunicorn.conf.py'),
         '-w', '1', '-b', f'127.0.0.1:{port}', '--timeout', '2',
         '--pythonpath', str(tmp_path), 'blocking_app:app'],
        cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(100):
            try:
                socket.create_connection(('127.0.0.1', port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        try:
            urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=15)
        except Exception:
            pass  # the worker is killed; the client sees the connection drop
        time.sleep(1)
    finally:
        server.terminate()
        log = server.communicate(timeout=30)[0]
        holder.close()

    assert 'WORKER TIMEOUT' in log, log[-2000:]
    assert 'waiting_on_a_lock_another_connection_holds' in log, (
        'gunicorn killed the hung worker and the log does not say where it stopped:\n' + log[-2000:])


def test_production_runs_the_config_with_its_settings():
    """The image starts gunicorn with the config file, and the file keeps the
    settings the command line had: 2 workers on :8001, 120 s timeout."""
    dockerfile = open(os.path.join(BACKEND, 'Dockerfile')).read()
    assert '"-c", "backend/gunicorn.conf.py"' in dockerfile
    conf = {}
    exec(open(os.path.join(BACKEND, 'gunicorn.conf.py')).read(), conf)
    assert (conf['workers'], conf['bind'], conf['timeout']) == (2, '0.0.0.0:8001', 120)
