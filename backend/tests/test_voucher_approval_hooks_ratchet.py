"""Approving a voucher has consequences, and they must not depend on WHICH path approved it.

MEASURED ON SIX PRODUCTION SNAPSHOTS (24 Sep baseline through 28 Sep):

    approved vouchers linked to an invoice : 2,544
    of those carrying a gold debit line    :    34
    voucher_invoice_gold_attribution rows  :     0      ← in every snapshot

Zero. The attribution table has never held a single row in production, because
Settings.voucher_auto_post is TRUE and the auto-approve block inside
create_voucher() posts the GL, writes the safe-box rows, sets status='approved'
-- and never calls the two approval hooks, which live only in approve_voucher().

What that made structurally impossible:

  * invoice_open_gold_obligation() -- THE shared ceiling -- reads GoldAllocation
    and VoucherInvoiceGoldAttribution. With no attribution rows it is blind, so
    nothing could refuse a SECOND payment against an already-settled obligation.
    Invoice 3132: 24.2 g of 18k paid twice, from two different safes (accounts
    760 and 766), against a single 24.2 g obligation.
  * Phase B's `paid = cash settled AND gold settled` never sees the gold side.
  * sync_invoice_cash_payment_after_voucher_approval -- the cash symmetry writer
    -- never fires either, so a standalone voucher creates no InvoicePayment.

The bug is not in either hook. Both are correct. The bug is that approval is
implemented twice and only one copy carries its consequences. A third approval
path would reintroduce this silently, which is why this is a ratchet and not a
unit test of the hooks.

Run:
    python -m pytest tests/test_voucher_approval_hooks_ratchet.py -v
"""

import ast
from pathlib import Path

import pytest

REQUIRED_HOOKS = (
    'sync_gold_attribution_after_voucher_approval',
    'sync_invoice_cash_payment_after_voucher_approval',
)


def _approval_sites(path: Path):
    """Every function that assigns 'approved' to a .status attribute, with the
    hook names that appear in its own source."""
    src = path.read_text(encoding='utf-8')
    tree = ast.parse(src)
    out = []
    for fn in [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
        lines = [
            node.lineno for node in ast.walk(fn)
            if isinstance(node, ast.Assign)
            and any(isinstance(t, ast.Attribute) and t.attr == 'status' for t in node.targets)
            and isinstance(node.value, ast.Constant) and node.value.value == 'approved'
        ]
        if not lines:
            continue
        segment = ast.get_source_segment(src, fn) or ''
        out.append({
            'function': fn.name,
            'lines': sorted(lines),
            'hooks': tuple(h for h in REQUIRED_HOOKS if h in segment),
        })
    return out


class TestEveryApprovalPathCarriesItsConsequences:

    def test_voucher_approval_always_syncs_gold_and_cash(self):
        """The ratchet. Any route that approves a voucher must also record what
        the approval means for the invoice — both dimensions."""
        path = Path(__file__).resolve().parent.parent / 'routes' / 'vouchers.py'
        sites = _approval_sites(path)

        assert sites, 'no approval site found — has the file moved?'

        offenders = [
            f"{s['function']}() approves at line(s) {s['lines']} "
            f"but calls {len(s['hooks'])}/2 hooks "
            f"(missing: {', '.join(h for h in REQUIRED_HOOKS if h not in s['hooks'])})"
            for s in sites if len(s['hooks']) != len(REQUIRED_HOOKS)
        ]
        assert not offenders, (
            'a voucher approved without these hooks moves the GL and the safe box '
            'while leaving the invoice unaware — measured consequence: 0 attribution '
            'rows across six production snapshots, and a 24.2 g obligation paid '
            'twice because the shared ceiling had nothing to read:\n  '
            + '\n  '.join(offenders)
        )

    def test_there_is_more_than_one_approval_path_so_the_ratchet_earns_its_keep(self):
        """Documents WHY this is a ratchet: approval is implemented twice. If it
        is ever unified into one path this test may be replaced by a unit test of
        that path — but not before."""
        path = Path(__file__).resolve().parent.parent / 'routes' / 'vouchers.py'
        names = {s['function'] for s in _approval_sites(path)}
        assert len(names) >= 2, (
            f'approval now happens in one place only ({names}); consider replacing '
            'this ratchet with a direct test of that single path'
        )


# ======================================================================
# THE BEHAVIOURAL WITNESS
#
# Every other voucher test in this suite creates a voucher and then calls
# POST /vouchers/<id>/approve. Production never does that: Settings
# .voucher_auto_post is TRUE, so creation approves in place. The suite has
# therefore been validating a path production does not take -- which is the
# deepest reason this went unseen for as long as it did.
#
# This test exercises the path production actually uses.
# ======================================================================

import uuid
from datetime import datetime

from app import app, db
from models import (
    Account,
    Invoice,
    InvoiceGoldObligation,
    SafeBox,
    Settings,
    Supplier,
    Voucher,
    VoucherInvoiceGoldAttribution,
)


def _uid():
    return uuid.uuid4().hex[:8]


def _supplier_with_accounts():
    from party_account_service import ensure_supplier_accounts
    s = Supplier(supplier_code=f'SUP-{_uid()}', name=f'مورد {_uid()}')
    db.session.add(s)
    db.session.flush()
    ensure_supplier_accounts(s)
    db.session.commit()
    return s


def _gold_safe_box():
    acc = Account(
        account_number=f'99{_uid()[:4]}', name='خزينة ذهب اختبار',
        type='Asset', tracks_weight=True,
    )
    db.session.add(acc)
    db.session.flush()
    box = SafeBox(name=f'خزينة {_uid()}', safe_type='gold',
                  account_id=acc.id, is_active=True)
    db.session.add(box)
    db.session.commit()
    return box


def _purchase_invoice(supplier_id, *, total=10000.0):
    inv = Invoice(
        invoice_type_id=int(_uid(), 16) % 900000 + 1, invoice_type='شراء',
        supplier_id=supplier_id, date=datetime.now(), total=total,
        status='unpaid', amount_paid=0.0, is_posted=True,
        gold_settlement_tracked=True,
    )
    db.session.add(inv)
    db.session.flush()
    return inv


def _invoice_payment_voucher(supplier_id, gold_account_id, supplier_account_id,
                            invoice_id, weight, karat=21):
    """The shape the employee's "this payment is for invoice X" choice creates."""
    return {
        'voucher_type': 'payment',
        'date': datetime.now().isoformat(),
        'party_type': 'supplier',
        'supplier_id': supplier_id,
        'reference_type': 'invoice',
        'reference_id': invoice_id,
        'account_lines': [
            {'account_id': gold_account_id, 'line_type': 'credit',
             'amount_type': 'gold', 'amount': weight, 'karat': karat},
            {'account_id': supplier_account_id, 'line_type': 'debit',
             'amount_type': 'gold', 'amount': weight, 'karat': karat},
        ],
    }


@pytest.fixture
def auto_post_on():
    """Production's real setting. Restored afterwards."""
    with app.app_context():
        row = Settings.query.first()
        created = row is None
        if created:
            row = Settings()
            db.session.add(row)
            db.session.flush()
        before = getattr(row, 'voucher_auto_post', None)
        row.voucher_auto_post = True
        db.session.commit()
        row_id = row.id
    yield
    with app.app_context():
        row = db.session.get(Settings, row_id)
        if row is not None:
            if created:
                db.session.delete(row)
            else:
                row.voucher_auto_post = before
            db.session.commit()


class TestAutoApproveRecordsTheAttribution:

    def test_creating_an_invoice_payment_voucher_records_its_gold_attribution(
        self, auth_headers, auto_post_on
    ):
        """Measured on seven production snapshots: 0 attribution rows, ever,
        while 34 approved invoice-linked vouchers carried a gold debit line.
        This is that gap, at the route."""
        with app.app_context():
            supplier = _supplier_with_accounts()
            safe = _gold_safe_box()
            sup_account_id = int(Supplier.query.get(supplier.id).account_id)
            inv = _purchase_invoice(supplier.id)
            db.session.add(InvoiceGoldObligation(
                invoice_id=inv.id, karat=21.0, weight=100.0))
            db.session.commit()
            payload = _invoice_payment_voucher(
                supplier.id, safe.account_id, sup_account_id, inv.id, 40.0)
            invoice_id = inv.id

        with app.test_client() as client:
            resp = client.post('/api/vouchers', json=payload, headers=auth_headers)
        assert resp.status_code == 201, resp.get_data(as_text=True)
        voucher_id = resp.get_json()['id']

        with app.app_context():
            voucher = db.session.get(Voucher, voucher_id)
            assert voucher.status == 'approved', (
                'auto-post is on, so creation should have approved it; '
                f'status={voucher.status}'
            )
            rows = VoucherInvoiceGoldAttribution.query.filter_by(
                voucher_id=voucher_id).all()
            assert len(rows) == 1, (
                'an approved voucher that declares an invoice and carries gold '
                'must record its attribution — otherwise the shared ceiling has '
                'nothing to read and a second payment against the same '
                'obligation cannot be refused'
            )
            assert rows[0].invoice_id == invoice_id
            assert rows[0].karat == 21.0
            assert rows[0].weight == 40.0

    def test_a_payment_beyond_the_obligation_is_refused_at_creation(
        self, auth_headers, auto_post_on
    ):
        """Invoice 3132's actual failure: 24.2 g paid twice against a single
        24.2 g obligation, because nothing could see the first payment. With the
        attribution written, the shared ceiling refuses the second — and the
        refusal must reach the employee, not be swallowed."""
        with app.app_context():
            supplier = _supplier_with_accounts()
            safe = _gold_safe_box()
            sup_account_id = int(Supplier.query.get(supplier.id).account_id)
            inv = _purchase_invoice(supplier.id)
            db.session.add(InvoiceGoldObligation(
                invoice_id=inv.id, karat=21.0, weight=24.2))
            db.session.commit()
            first = _invoice_payment_voucher(
                supplier.id, safe.account_id, sup_account_id, inv.id, 24.2)
            second = dict(first)
            invoice_id = inv.id

        with app.test_client() as client:
            r1 = client.post('/api/vouchers', json=first, headers=auth_headers)
        assert r1.status_code == 201, r1.get_data(as_text=True)

        with app.test_client() as client:
            r2 = client.post('/api/vouchers', json=second, headers=auth_headers)

        assert r2.status_code >= 400, (
            'the second payment exhausts nothing that is left — it must be '
            f'refused, not recorded. got {r2.status_code}: '
            f'{r2.get_data(as_text=True)[:200]}'
        )
        with app.app_context():
            total = sum(
                r.weight for r in VoucherInvoiceGoldAttribution.query.filter_by(
                    invoice_id=invoice_id).all())
            assert total == 24.2, f'obligation over-evidenced: {total} g'
