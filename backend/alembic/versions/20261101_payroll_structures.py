"""payroll_structures: salary structures, contribution schemes, the payroll's policy (PAYROLL-2)

SCHEMA, additive, with the owner's decisions of 1 Nov 2026 («اودع ثم أكمل»):
  - a salary is a structure from a day on -- basic, housing, transport, other
    («الشائع والمعمول به وما تنصح به أنت»);
  - contributions are schemes an employee is in, not his nationality («الفكرة
    أعم وليس مربوطة بجنسية») -- the GOSI's two seeded, editable and dated;
  - each employee is paid by bank or cash («تحتمل الاثنين معًا»);
  - every ratio is the owner's to edit («النسب ... قابلة للتعديل»): the policy
    is settings' JSON, seeded here, never a number in the code.

Impact: three new tables, four employee columns, one settings column, two
schemes and the policy seeded. Idempotent: the boot's create_all and schema
guard may have made the tables and columns first (ADR-023's pattern). The
seeds are written only when absent. Downgrade drops what it added.
"""
import json

from alembic import op
import sqlalchemy as sa

revision = '20261101_payroll_structures'
down_revision = '20261031_gold_market_state'
branch_labels = None
depends_on = None

# The GOSI's rates as of the seed day (Saudi: annuities 9/9, occupational
# hazards 0/2, SANED 0.75/0.75 on basic + housing up to 45,000; non-Saudi:
# occupational hazards 0/2) -- data from here on, edited in the schemes' screen.
SCHEMES = (
    ('مشترك سعودي', (
        ('annuities', 'المعاشات', 9.0, 9.0),
        ('occupational_hazards', 'الأخطار المهنية', 0.0, 2.0),
        ('saned', 'ساند', 0.75, 0.75),
    )),
    ('مشترك غير سعودي', (
        ('occupational_hazards', 'الأخطار المهنية', 0.0, 2.0),
    )),
)
BASE, CAP, FROM = 'basic_housing', 45000.0, '2026-01-01'

POLICY = {
    'housing_ratio': 0.25,
    'transport_ratio': 0.10,
    'advance_cap_ratio': 0.10,
    'advance_installments': 3,
    'attendance_enabled': False,
    'day_divisor': 30,
    'overtime_premium_ratio': 0.5,
}


def _columns(table):
    return {c['name'] for c in sa.inspect(op.get_bind()).get_columns(table)}


def upgrade():
    inspector = sa.inspect(op.get_bind())
    if not inspector.has_table('contribution_scheme'):
        op.create_table(
            'contribution_scheme',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('name', sa.String(100), nullable=False, unique=True),
            sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.true()),
            sa.Column('notes', sa.Text(), nullable=True),
        )
    if not inspector.has_table('contribution_component'):
        op.create_table(
            'contribution_component',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('scheme_id', sa.Integer(), sa.ForeignKey('contribution_scheme.id'), nullable=False, index=True),
            sa.Column('code', sa.String(40), nullable=False),
            sa.Column('name', sa.String(100), nullable=False),
            sa.Column('base', sa.String(20), nullable=False),
            sa.Column('employee_rate', sa.Float(), nullable=False, server_default='0'),
            sa.Column('employer_rate', sa.Float(), nullable=False, server_default='0'),
            sa.Column('base_cap', sa.Float(), nullable=True),
            sa.Column('effective_from', sa.Date(), nullable=False),
            sa.UniqueConstraint('scheme_id', 'code', 'effective_from', name='_contribution_day_uc'),
        )
    if not inspector.has_table('salary_structure'):
        op.create_table(
            'salary_structure',
            sa.Column('id', sa.Integer(), primary_key=True),
            sa.Column('employee_id', sa.Integer(), sa.ForeignKey('employee.id'), nullable=False, index=True),
            sa.Column('effective_from', sa.Date(), nullable=False),
            sa.Column('basic', sa.Float(), nullable=False, server_default='0'),
            sa.Column('housing', sa.Float(), nullable=False, server_default='0'),
            sa.Column('transport', sa.Float(), nullable=False, server_default='0'),
            sa.Column('other_allowances', sa.Float(), nullable=False, server_default='0'),
            sa.Column('notes', sa.Text(), nullable=True),
            sa.Column('created_by', sa.String(100), nullable=True),
            sa.Column('created_at', sa.DateTime(), nullable=False, server_default=sa.func.now()),
            sa.UniqueConstraint('employee_id', 'effective_from', name='_salary_structure_day_uc'),
        )

    employee = _columns('employee')
    for name, type_ in (('contribution_scheme_id', sa.Integer()), ('payment_method', sa.String(10)),
                        ('iban', sa.String(34)), ('bank_name', sa.String(100))):
        if name not in employee:
            op.add_column('employee', sa.Column(name, type_, nullable=True))
    if 'payroll_policy' not in _columns('settings'):
        op.add_column('settings', sa.Column('payroll_policy', sa.Text(), nullable=True))

    bind = op.get_bind()
    for scheme, components in SCHEMES:
        scheme_id = bind.execute(sa.text('SELECT id FROM contribution_scheme WHERE name = :n'), {'n': scheme}).scalar()
        if scheme_id is not None:
            continue
        scheme_id = bind.execute(sa.text('INSERT INTO contribution_scheme (name, is_active) '
                                         'VALUES (:n, :a) RETURNING id'), {'n': scheme, 'a': True}).scalar()
        for code, name, employee_rate, employer_rate in components:
            bind.execute(sa.text(
                'INSERT INTO contribution_component (scheme_id, code, name, base, employee_rate, '
                'employer_rate, base_cap, effective_from) VALUES (:s, :c, :n, :b, :ee, :er, :cap, :f)'),
                {'s': scheme_id, 'c': code, 'n': name, 'b': BASE, 'ee': employee_rate, 'er': employer_rate,
                 'cap': CAP, 'f': FROM})
    bind.execute(sa.text('UPDATE settings SET payroll_policy = :p WHERE payroll_policy IS NULL'),
                 {'p': json.dumps(POLICY)})


def downgrade():
    op.drop_column('settings', 'payroll_policy')
    for name in ('bank_name', 'iban', 'payment_method', 'contribution_scheme_id'):
        op.drop_column('employee', name)
    op.drop_table('salary_structure')
    op.drop_table('contribution_component')
    op.drop_table('contribution_scheme')
