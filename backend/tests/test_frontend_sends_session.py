"""Every HTTP call the Flutter app makes carries the session -- or targets a public route.

The server refuses any /api request without a session unless api_auth_guard
lists its route as public (tests/test_api_authentication_by_default.py). A
Flutter call that sends no token therefore works only against a public route;
against any other it gets 401 in production and the screen behind it fails.
When the guard went in, 13 ApiService methods (payment methods, offices, next
customer/supplier code, posting stats) and the direct-print PDF upload sent no
token: they had only ever worked because the routes behind them were open.

This reads every raw http.get/post/put/delete/patch call in frontend/lib and
checks it against the server's own public list -- one source of truth for what
may be called before sign-in. Static by nature: it reads source, so a call
built in an unusual shape may need its pattern taught here.

Run:
    python -m pytest tests/test_frontend_sends_session.py -v
"""
import pathlib
import re

FRONTEND_LIB = pathlib.Path(__file__).resolve().parents[2] / 'frontend' / 'lib'

CALL = re.compile(r'http\.(get|post|put|delete|patch)\(')
CARRIES_SESSION = ('Authorization', '_jsonHeaders(token:', 'sessionHeaders(')

# Calls that knowingly go out without a session, keyed by (file, enclosing method).
KNOWN_TOKENLESS = {
    ('api_service.dart', 'get'): 'generic helper: tries without a session, retries with one on 401 (_authedGet)',
    ('api_service.dart', 'post'): 'generic helper: tries without a session, retries with one on 401 (_authedPost)',
    ('api_service.dart', 'put'): 'generic helper: tries without a session, retries with one on 401 (_authedPut)',
    ('api_service.dart', 'delete'): 'generic helper: tries without a session, retries with one on 401 (_authedDelete)',
    ('screens/recurring_templates_screen.dart', '*'):
        'DEBT: hard-codes http://127.0.0.1:8001, so it never reached the server in production; '
        'RecurringTemplatesListScreen is the working screen',
}

_METHOD_SIG = re.compile(r'^\s*(?:static\s+)?(?:Future(?:<.*>)?|void|[A-Z]\w*(?:<.*>)?)\s+(\w+)\s*\(')


def _enclosing_method(source: str, offset: int) -> str:
    for line in reversed(source[:offset].split('\n')):
        m = _METHOD_SIG.match(line)
        if m:
            return m.group(1)
    return '?'


def _called_path(call: str):
    """The /api path a call targets, from the string inside Uri.parse(...)."""
    m = re.search(r"Uri\.parse\(\s*'([^']*)'", call) or re.search(r"Uri\.parse\(\s*\"([^\"]*)\"", call)
    if not m:
        return None
    url = m.group(1)
    tail = re.sub(r'^\$\{?[A-Za-z_]+\}?', '', url)  # drop the leading base-url variable
    tail = tail.split('?')[0]
    if not tail.startswith('/api/'):
        tail = '/api' + tail
    return tail


def _public_patterns():
    from api_auth_guard import PUBLIC_API_ROUTES
    patterns = []
    for rule, method in PUBLIC_API_ROUTES:
        rx = re.sub(r'<[^>]+>', r'[^/]+', rule)
        patterns.append((re.compile('^' + rx + '$'), method))
    return patterns


def tokenless_calls(lib: pathlib.Path = FRONTEND_LIB):
    """[(relative file, method, line, HTTP verb, path)] for calls without a session."""
    found = []
    for f in sorted(lib.rglob('*.dart')):
        source = f.read_text(encoding='utf-8', errors='ignore')
        for m in CALL.finditer(source):
            i, depth = m.end(), 1
            while i < len(source) and depth:
                depth += {'(': 1, ')': -1}.get(source[i], 0)
                i += 1
            call = source[m.start():i]
            if any(marker in call for marker in CARRIES_SESSION):
                continue
            found.append((str(f.relative_to(lib)), _enclosing_method(source, m.start()),
                          source.count('\n', 0, m.start()) + 1, m.group(1).upper(), _called_path(call)))
    return found


def test_every_flutter_call_carries_a_session_or_targets_a_public_route():
    public = _public_patterns()
    offenders = []
    for rel, method, line, verb, path in tokenless_calls():
        if (rel, method) in KNOWN_TOKENLESS or (rel, '*') in KNOWN_TOKENLESS:
            continue
        # Dart interpolation in the path matches a route converter.
        normalized = re.sub(r'\$\{[^}]+\}|\$\w+', 'x', path or '')
        if path and any(rx.match(normalized) and verb == m for rx, m in public):
            continue
        offenders.append(f'{rel}:{line} {method}() {verb} {path}')
    assert offenders == [], (
        'Flutter calls that send no session to a route the server protects -- they get 401 in '
        'production. Send the token (_jsonHeaders(token: await _requireAuthToken()), or '
        'ApiService().sessionHeaders() outside ApiService):\n  ' + '\n  '.join(offenders))


def test_the_known_tokenless_list_has_no_stale_entries():
    seen = {(rel, method) for rel, method, *_ in tokenless_calls()}
    seen_files = {rel for rel, *_ in tokenless_calls()}
    stale = [k for k in KNOWN_TOKENLESS
             if (k[1] == '*' and k[0] not in seen_files) or (k[1] != '*' and k not in seen)]
    assert stale == [], f'entries that no longer match a token-less call -- remove them: {stale}'
