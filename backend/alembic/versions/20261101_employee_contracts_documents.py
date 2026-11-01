"""employee_contracts_documents: an employee's contracts and documents (EMP-3, ش3)

SCHEMA, additive, with the owner's list of kinds. The owner, 1 Nov 2026: the
documents followed «ما يُعمل به في الأنظمة المماثلة، وإن كان ممكنًا أن يكون ضبط
الأيام اختياريًا». On the 1 Nov copy nothing of an employee's contract or
documents was kept. Seeded: the kinds alone -- the national id, the
residence permit, the passport, the work permit, the health certificate, the
driving licence -- each with no alert days (his to set, none = no alert).

Impact: three new tables, six rows in one. Idempotent (the boot's create_all
may come first, ADR-023's pattern); a kind already there is kept. Downgrade
drops the tables.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261101_employee_contracts_documents'
down_revision = '20261101_employee_safe_keys'
branch_labels = None
depends_on = None

KINDS = ('الهوية الوطنية', 'الإقامة', 'جواز السفر', 'رخصة العمل', 'الشهادة الصحية', 'رخصة القيادة')


def upgrade():
    inspector = sa.inspect(op.get_bind())
    if not inspector.has_table('employee_contract'):
        op.create_table(
            'employee_contract',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('employee_id', sa.Integer(), sa.ForeignKey('employee.id'), nullable=False, index=True),
            sa.Column('kind', sa.String(20), nullable=False),
            sa.Column('start_date', sa.Date(), nullable=False),
            sa.Column('end_date', sa.Date(), nullable=True),
            sa.Column('probation_end', sa.Date(), nullable=True),
            sa.Column('notes', sa.Text(), nullable=True),
            sa.Column('created_by', sa.String(100), nullable=True),
            sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
        )
    if not inspector.has_table('employee_document_type'):
        op.create_table(
            'employee_document_type',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('name', sa.String(100), nullable=False, unique=True),
            sa.Column('alert_days', sa.Integer(), nullable=True),
            sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()),
        )
    if not inspector.has_table('employee_document'):
        op.create_table(
            'employee_document',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('employee_id', sa.Integer(), sa.ForeignKey('employee.id'), nullable=False, index=True),
            sa.Column('type_id', sa.Integer(), sa.ForeignKey('employee_document_type.id'), nullable=False,
                      index=True),
            sa.Column('number', sa.String(60), nullable=True),
            sa.Column('issued_on', sa.Date(), nullable=True),
            sa.Column('expires_on', sa.Date(), nullable=True),
            sa.Column('notes', sa.Text(), nullable=True),
            sa.Column('created_by', sa.String(100), nullable=True),
            sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
        )
    bind = op.get_bind()
    for name in KINDS:
        if bind.execute(sa.text('SELECT 1 FROM employee_document_type WHERE name = :n'), {'n': name}).first() is None:
            bind.execute(sa.text('INSERT INTO employee_document_type (name, is_active) VALUES (:n, :a)'),
                         {'n': name, 'a': True})


def downgrade():
    op.drop_table('employee_document')
    op.drop_table('employee_document_type')
    op.drop_table('employee_contract')
