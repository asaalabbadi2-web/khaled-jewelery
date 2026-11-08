"""Only the containers that run the app read .env.production.

The file holds IMAGE_TAG and every app secret (JWT_SECRET_KEY,
FLASK_SECRET_KEY, DATABASE_URL). `db` and `nginx` read it whole through
`env_file`, so:

- every deploy changed IMAGE_TAG and thereby the database container's
  environment, and Compose recreated yasargold-db in the middle of the
  migration step -- on 29 Sep 2026, twice, even after update-prod.ps1 stopped
  pulling or restarting it (the first time it was blamed on a new postgres:16
  build; the version had not changed: 16.15 before and after);
- the database server and the web server held secrets neither uses.

The database needs POSTGRES_DB, POSTGRES_USER and POSTGRES_PASSWORD, which its
`environment` block already takes from `--env-file` (and `environment` wins over
`env_file` anyway); nginx serves a static config baked into its image.

Run:
    python -m pytest tests/test_production_compose.py -v
"""
import pathlib

import yaml

COMPOSE = pathlib.Path(__file__).resolve().parents[2] / 'docker-compose.prod.gitlab.yml'


def _services():
    return yaml.safe_load(COMPOSE.read_text())['services']


def test_the_database_does_not_read_the_app_env_file():
    db = _services()['db']
    assert 'env_file' not in db, 'db must not read .env.production: IMAGE_TAG would recreate it on every deploy'
    assert set(db['environment']) == {'POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD'}


def test_nginx_holds_no_app_secret():
    assert 'env_file' not in _services()['nginx']


def test_the_app_containers_still_read_it():
    services = _services()
    for name in ('backend', 'scheduler'):
        assert services[name].get('env_file') == '.env.production', name


def test_every_service_comes_back_on_its_own():
    """No service had a restart policy (found 29 Sep 2026). The scheduler exits
    on purpose when a critical scheduler fails (fail-closed, S1/S2) -- designed
    for an orchestrator that restarts it; with none it stayed dead, silently.
    And after the machine restarted, nothing came back until someone ran
    `docker compose up`. `unless-stopped`: a container that dies, or a machine
    that reboots, comes back; one stopped on purpose stays stopped."""
    for name, service in _services().items():
        assert service.get('restart') == 'unless-stopped', name


ROOT = pathlib.Path(__file__).resolve().parents[2]


def _first(text, *marks):
    places = [text.find(m) for m in marks if text.find(m) >= 0]
    return min(places) if places else -1


def test_every_deploy_recipe_migrates_before_the_app_starts():
    """The app's start writes the models' tables and columns (create_all,
    schema_guard): started on new code first, the migrations then meet them and
    fail, and a backfill never runs (Phase 16C; a local copy on 9 Nov 2026).
    Every recipe says `alembic upgrade head` before `up -d` -- the compose
    file's own header said the opposite."""
    header = ''.join(l for l in COMPOSE.read_text().splitlines(keepends=True) if l.startswith('#'))
    recipes = {
        'docker-compose.prod.gitlab.yml (its header)': header,
        '.gitlab-ci.yml': (ROOT / '.gitlab-ci.yml').read_text(),
        'update-prod.ps1': (ROOT / 'update-prod.ps1').read_text(),
    }
    for name, text in recipes.items():
        migrate = _first(text, 'alembic upgrade head')
        start = _first(text, 'up -d', "'up', '-d'")
        assert migrate >= 0 and start >= 0, f'{name}: says both steps'
        assert migrate < start, f'{name}: the migration first, then the app'
