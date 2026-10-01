"""Production loads the app once; code must never load it a second time (EDIT-002).

gunicorn loads `backend.wsgi:app`, so the running module is `backend.app`.
Code that says `from app import app` does not find it under that name and runs
app.py a second time: a second Flask app, with its own engine and its own
sessions. Since the routes migration (0232533, 13 Jul 2026) the invoice edit
did exactly that, then called add_invoice inside the second app -- the delete
of the old invoice on one connection, the new invoice on another. Two
transactions where one was meant; and once EDIT-001 kept the number
(30 Sep 2026), the new invoice's INSERT waited on the old one's uncommitted
DELETE for the same (invoice_type, invoice_type_id), and the request waited on
itself until gunicorn killed it. Invoice 3170, three times on production; the
HANG-001 trace named routes/invoices.py:1196 -> 4295.

The gate imports the app as `app`, where the second load cannot happen, so
these tests run a subprocess that loads it the way gunicorn does.

Run:
    python -m pytest tests/test_the_app_is_loaded_once.py -v
"""
import json
import os
import subprocess
import sys
import textwrap

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(BACKEND)

PROBE = textwrap.dedent('''
    import ast, json, os, sys
    sys.path.insert(0, %(repo)r)
    import backend.wsgi                       # as gunicorn loads it
    app = backend.wsgi.app
    backend_dir = %(backend)r

    def bare_app_imports(path):
        """`from app import ...` / `import app` outside an `if __name__ == '__main__'` block."""
        tree = ast.parse(open(path, encoding='utf-8').read())
        main_blocks = set()
        for node in ast.walk(tree):
            if (isinstance(node, ast.If) and isinstance(node.test, ast.Compare)
                    and getattr(node.test.left, 'id', None) == '__name__'):
                main_blocks.update(id(n) for n in ast.walk(node))
        found = []
        for node in ast.walk(tree):
            if id(node) in main_blocks:
                continue
            if isinstance(node, ast.ImportFrom) and node.module == 'app' and node.level == 0:
                found.append(node.lineno)
            elif isinstance(node, ast.Import) and any(a.name == 'app' for a in node.names):
                found.append(node.lineno)
        return found

    loaded = sorted({os.path.realpath(m.__file__) for m in list(sys.modules.values())
                     if getattr(m, '__file__', None)
                     and os.path.realpath(m.__file__).startswith(backend_dir + os.sep)
                     and os.sep + 'venv' + os.sep not in m.__file__})
    offenders = {os.path.relpath(p, backend_dir): lines for p in loaded
                 for lines in [bare_app_imports(p)] if lines
                 and os.path.relpath(p, backend_dir) not in ('app.py', 'wsgi.py')}

    # The edit itself, with add_invoice stubbed to fail: the route rolls back,
    # so the database is left as it was (the invoice is removed at the end).
    import routes.invoices as inv
    from auth_decorators import generate_token
    from models import Invoice, User, db
    from datetime import datetime
    seen = {}
    def stub(**kw):
        from flask import current_app, jsonify
        seen['same_app'] = current_app._get_current_object() is app
        return jsonify({'error': 'stub'}), 418
    inv.add_invoice = stub
    with app.app_context():
        row = Invoice(invoice_type='شراء من عميل', invoice_type_id=987654, date=datetime(2026, 9, 29),
                      total=1.0, is_posted=False)
        db.session.add(row)
        db.session.commit()
        invoice_id = row.id
        token = generate_token(User.query.filter_by(username='admin').first())
    try:
        resp = app.test_client().put(f'/api/invoices/{invoice_id}', json={'items': []},
                                     headers={'Authorization': f'Bearer {token}'})
        status = resp.status_code
    finally:
        with app.app_context():
            db.session.delete(Invoice.query.get(invoice_id))   # one row, through the ORM: bulk deletes are refused (U3)
            db.session.commit()
    print('PROBE' + json.dumps({'offenders': offenders, 'status': status,
                                'same_app': seen.get('same_app'),
                                'second_app_loaded': 'app' in sys.modules}))
''') % {'repo': REPO, 'backend': os.path.realpath(BACKEND)}


def _probe():
    env = dict(os.environ, BYPASS_AUTH_FOR_DEVELOPMENT='0')
    out = subprocess.run([sys.executable, '-c', PROBE], cwd=REPO, env=env,
                         capture_output=True, text=True, timeout=300)
    line = next((l for l in out.stdout.splitlines() if l.startswith('PROBE')), None)
    assert line, out.stdout[-2000:] + out.stderr[-3000:]
    return json.loads(line[len('PROBE'):])


def test_the_app_is_loaded_once():
    result = _probe()
    # The edit ran inside the app that received the request.
    assert result['status'] == 418, result
    assert result['same_app'] is True, f'add_invoice ran inside a second app -- another connection: {result}'
    assert result['second_app_loaded'] is False, 'app.py was loaded a second time, as `app`'
    # And no module the running app loads can do it: `from app import` in
    # runtime code runs app.py again under gunicorn (the class, not the case).
    assert result['offenders'] == {}, result['offenders']
