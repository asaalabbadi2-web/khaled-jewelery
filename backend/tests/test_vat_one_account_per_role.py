"""One account per VAT role, and no fallback number (ADR-043, phase 2; rule 4).

Three of April 2026's sale returns gave their VAT back on 2210 -- the number
accounting/mappings.py fell back to for «vat_payable» before 2300 was mapped --
and the sales VAT sat on two accounts until stage-4 item 22. Input VAT fell
back to 1400, then 1500 («مدى»); the supplier purchase and its return looked
1400 / 1500 up by number again; and the customer purchase, the sale return and
the customer purchase return skipped the VAT line without a word when nothing
was mapped -- an entry short of its tax.

Now a VAT role comes from its mapping or the posting is refused, saying which
mapping is missing; nothing is written.

Run:
    python -m pytest tests/test_vat_one_account_per_role.py -v
"""
import os
import re

import pytest

from app import app as flask_app
from models import Account, AccountingMapping, db

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROLES = ('vat_payable', 'vat_receivable', 'commission_vat')


@pytest.fixture(scope='module')
def app():
    flask_app.config['TESTING'] = True
    with flask_app.app_context():
        yield flask_app


@pytest.fixture(autouse=True)
def rollback_after_each(app, db_fence):
    yield


def test_an_unmapped_vat_role_falls_back_to_no_number():
    from accounting.mappings import VatAccountNotMapped, get_account_id_for_mapping, require_vat_account
    AccountingMapping.query.filter(AccountingMapping.account_type.in_(ROLES)).update({'is_active': False},
                                                                                     synchronize_session=False)
    for number in ('2210', '1400', '1500', '1501'):
        if not Account.query.filter_by(account_number=number).first():
            db.session.add(Account(account_number=number, name=f'ح {number}', type='Liability'))
    db.session.flush()

    for operation, role in (('بيع', 'vat_payable'), ('شراء', 'vat_receivable'), ('بيع', 'commission_vat')):
        assert get_account_id_for_mapping(operation, role) is None, f'{role}: no number stands in for the mapping'
        with pytest.raises(VatAccountNotMapped) as refused:
            require_vat_account(operation, role)
        assert role in str(refused.value)


def test_a_mapped_role_is_its_account():
    from accounting.mappings import require_vat_account
    vat = Account(account_number='9230099', name='ضريبة مخرجات اختبار', type='Liability')
    db.session.add(vat)
    db.session.flush()
    AccountingMapping.query.filter_by(account_type='vat_payable').update({'is_active': False}, synchronize_session=False)
    db.session.add(AccountingMapping(operation_type='بيع', account_type='vat_payable', account_id=vat.id, is_active=True))
    db.session.flush()
    assert require_vat_account('بيع', 'vat_payable') == vat.id


def _source(path):
    with open(os.path.join(BACKEND, path), encoding='utf-8') as f:
        return f.read()


@pytest.mark.parametrize('path', ['routes/invoices.py', 'je_engine_v2.py'])
def test_no_writer_skips_the_vat_line_or_finds_its_account_by_number(path):
    source = _source(path)
    skipped = re.findall(r'\n[^\n]*(?:tax|vat)[^\n]*>\s*0[^\n]*\band\s+(?:accounts\.)?\w*vat\w*(?:acc|account)\w*[^\n]*',
                         source, flags=re.I)
    assert skipped == [], 'a VAT line skipped when its account is missing:\n' + '\n'.join(s.strip() for s in skipped)
    by_number = re.findall(r"account_number\s*=\s*'(?:1400|1500|2210|2300|1410)'", source)
    assert by_number == [], f'a VAT account looked up by number: {by_number}'
