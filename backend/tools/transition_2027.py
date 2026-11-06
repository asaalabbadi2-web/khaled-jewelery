"""The 2027 database from 2026's closed one (ADR-044 phase 4) -- TR-1: the chart, its roles, the master data; TR-3: the approved opening's waiting riyals; TR-4c: the opening entries.

services/transition_2027.py. The application runs on the 2027 database
(DATABASE_URL): a new, empty database -- its tables are made as the
application starts on it, then it is stamped at the migrations' head. 2026's
database (--source) is read through its own connection, never written.

    createdb yasargold_2027
    DATABASE_URL=postgresql:///yasargold_2027 python tools/transition_2027.py --source postgresql:///yasargold_2026
    ... --apply --by <name>

Dry run by default: everything is written, reported, then rolled back.
An opening the owner has not approved in 2026's database does not open 2027
(TR-3); a rehearsal before the approval says --without-opening.
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
    ap.add_argument('--without-opening', action='store_true',
                    help='a rehearsal before the owner approves the opening: its waiting riyals not carried')
    args = ap.parse_args(argv)

    from sqlalchemy import create_engine

    from app import app               # makes the 2027 database's tables on an empty one
    from models import db
    from datetime import date, datetime

    from services.books_invariants import CHECKS, check_roles_not_mapped
    from services.transition_2027 import _Accounts, build_chart_and_roles, carry_master_data, carry_waiting, \
        write_opening

    source = create_engine(args.source, execution_options={'postgresql_readonly': True})
    with app.app_context():
        try:
            report = build_chart_and_roles(source)
            with source.connect() as conn:
                accounts = _Accounts(conn)     # one translation for the master data and the opening
            report.update(carry_master_data(source, opens_on=date(2027, 1, 1), accounts=accounts))
            if args.without_opening:
                report['opening'] = 'not carried: a rehearsal before the approval'
            else:
                report['opening'] = carry_waiting(source, year=2027)
                report['opening_entries'] = write_opening(source, year=2027, accounts=accounts, by=args.by,
                                                          now=datetime.now())
            report['roles_not_mapped'] = [f.subject_key for f in check_roles_not_mapped()]
            report['nightly_checks'] = {k: len(fn()) for k, fn in CHECKS.items()}
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
