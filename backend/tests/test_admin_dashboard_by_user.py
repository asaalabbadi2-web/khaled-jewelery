from datetime import datetime

from app import app
from models import db, Employee, Invoice

import pytest

@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield



def _create_posted_invoice(
    *,
    employee_id: int,
    invoice_type: str,
    invoice_type_id: int,
    total: float,
    total_weight: float,
    posted_by: str = 'admin',
) -> Invoice:
    inv = Invoice(
        employee_id=employee_id,
        invoice_type=invoice_type,
        invoice_type_id=invoice_type_id,
        date=datetime.now(),
        total=float(total),
        total_weight=float(total_weight),
        is_posted=True,
        posted_by=posted_by,
    )
    db.session.add(inv)
    return inv


def test_admin_dashboard_groups_sales_and_purchases_by_invoice_employee(auth_headers):
    with app.app_context():
        emp1 = Employee(
            employee_code='EMP-DASH-001',
            name='موظف لوحة 1',
            salary=0.0,
            is_active=True,
        )
        emp2 = Employee(
            employee_code='EMP-DASH-002',
            name='موظف لوحة 2',
            salary=0.0,
            is_active=True,
        )
        db.session.add_all([emp1, emp2])
        db.session.flush()

        # Intentionally keep posted_by=admin for all invoices.
        # Attribution in dashboard must still use employee_id/employee.name.
        _create_posted_invoice(
            employee_id=emp1.id,
            invoice_type='بيع',
            invoice_type_id=9101,
            total=1000.0,
            total_weight=10.0,
            posted_by='admin',
        )
        _create_posted_invoice(
            employee_id=emp2.id,
            invoice_type='بيع',
            invoice_type_id=9102,
            total=2000.0,
            total_weight=20.0,
            posted_by='admin',
        )
        _create_posted_invoice(
            employee_id=emp1.id,
            invoice_type='شراء',
            invoice_type_id=9201,
            total=300.0,
            total_weight=5.0,
            posted_by='admin',
        )
        _create_posted_invoice(
            employee_id=emp2.id,
            invoice_type='شراء',
            invoice_type_id=9202,
            total=400.0,
            total_weight=6.0,
            posted_by='admin',
        )

        db.session.commit()

    with app.test_client() as client:
        resp = client.get('/api/dashboard/admin', headers=auth_headers)

    assert resp.status_code == 200
    payload = resp.get_json() or {}
    summary = (payload.get('sales_purchases_summary') or {}).get('today') or {}

    sales_rows = ((summary.get('sales') or {}).get('by_user') or [])
    purchases_rows = ((summary.get('purchases') or {}).get('by_user') or [])

    sales_by_user = {row.get('user'): row for row in sales_rows}
    purchases_by_user = {row.get('user'): row for row in purchases_rows}

    assert 'admin' not in sales_by_user
    assert 'admin' not in purchases_by_user

    assert sales_by_user['موظف لوحة 1']['value'] == 1000.0
    assert sales_by_user['موظف لوحة 2']['value'] == 2000.0
    assert sales_by_user['موظف لوحة 1']['docs'] == 1
    assert sales_by_user['موظف لوحة 2']['docs'] == 1

    assert purchases_by_user['موظف لوحة 1']['value'] == 300.0
    assert purchases_by_user['موظف لوحة 2']['value'] == 400.0
    assert purchases_by_user['موظف لوحة 1']['docs'] == 1
    assert purchases_by_user['موظف لوحة 2']['docs'] == 1

    # Regression: month and year periods must never be empty when invoices exist.
    month_summary = (payload.get('sales_purchases_summary') or {}).get('month') or {}
    year_summary = (payload.get('sales_purchases_summary') or {}).get('year') or {}
    assert (month_summary.get('sales') or {}).get('docs', 0) >= 2, 'month sales must count posted invoices'
    assert (month_summary.get('purchases') or {}).get('docs', 0) >= 2, 'month purchases must count posted invoices'
    assert (year_summary.get('sales') or {}).get('docs', 0) >= 2, 'year sales must count posted invoices'
    assert (year_summary.get('purchases') or {}).get('docs', 0) >= 2, 'year purchases must count posted invoices'
