"""The 2027 database from 2026's closed one (ADR-044 phase 4) -- TR-1a: the chart and its roles.

services/transition_2027.py. The application runs on the 2027 database
(DATABASE_URL): a new, empty database -- its tables are made as the
application starts on it, then it is stamped at the migrations' head. 2026's
database (--source) is read through its own connection, never written.

    createdb yasargold_2027
    DATABASE_URL=postgresql:///yasargold_2027 python tools/transition_2027.py --source postgresql:///yasargold_2026
    ... --apply --by <name>

Dry run by default: everything is written, reported, then rolled back.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--source', required=True, help="2026's closed database URL (read only)")
    ap.add_argument('--apply', action='store_true', help='commit (default: dry run)')
    ap.add_argument('--by', default='transition_2027', help='who applies it (recorded)')
    args = ap.parse_args(argv)

    from sqlalchemy import create_engine

    from app import app               # makes the 2027 database's tables on an empty one
    from models import db
    from services.books_invariants import check_roles_not_mapped
    from services.transition_2027 import build_chart_and_roles

    source = create_engine(args.source, execution_options={'postgresql_readonly': True})
    with app.app_context():
        try:
            report = build_chart_and_roles(source)
            report['roles_not_mapped'] = [f.subject_key for f in check_roles_not_mapped()]
            if args.apply:
                db.session.commit()
                # alembic makes its table 32 wide; the head's name is longer --
                # production's is 64, so is 2027's
                db.session.execute(db.text('CREATE TABLE IF NOT EXISTS alembic_version '
                                           '(version_num VARCHAR(64) NOT NULL PRIMARY KEY)'))
                db.session.commit()
                from alembic import command
                from alembic.config import Config
                command.stamp(Config(os.path.join(os.path.dirname(__file__), '..', 'alembic.ini')), 'head')
            else:
                db.session.rollback()
        except Exception:
            db.session.rollback()
            raise
    print(json.dumps({'applied': bool(args.apply), **report}, ensure_ascii=False, indent=1, default=str))


if __name__ == '__main__':
    main()
