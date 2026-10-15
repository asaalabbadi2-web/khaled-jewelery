"""«الربط المحاسبي»: the roles with their mappings, and every change checked and recorded (MAPPING-UI-1).

The screen draws what catalog() returns -- each role of accounting.role_registry
with, per operation, its explicit mapping, what it resolves to (explicit, or
inherited from the default), and the account's weight twin. Saving goes through
save(), removing through remove(): a role the code does not know, an account of
the wrong kind (a weight account for a cash role, or the reverse), an inactive
account, the removal of a live role's default, or of a row a required role
leans on, is refused. Who
changed what is the session's user, recorded in the audit log.
"""
from __future__ import annotations

import json

from accounting.mappings import resolve_mapping
from accounting.role_registry import DEFAULT, GROUPS, ROLES, WEIGHT, known, operations_of, required_pairs
from models import Account, AccountingMapping, AuditLog, db

AUDIT_SAVE = 'accounting_mapping_saved'
AUDIT_REMOVE = 'accounting_mapping_removed'


class MappingRefused(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


def _account_payload(account: Account | None):
    if account is None:
        return None
    twin = db.session.get(Account, account.memo_account_id) if account.memo_account_id else None
    return {'id': account.id, 'number': account.account_number, 'name': account.name,
            'tracks_weight': bool(account.tracks_weight), 'is_active': account.is_active is not False,
            'twin': ({'id': twin.id, 'number': twin.account_number, 'name': twin.name} if twin else None)}


def _source(effective: AccountingMapping | None, operation: str, key: str):
    """Where an operation's account comes from: its own row, the default's, or an alias role's."""
    if effective is None:
        return None, None
    if effective.account_type != key:
        via = ROLES.get(effective.account_type)
        return 'alias', {'role': effective.account_type, 'label': via.label if via else effective.account_type,
                         'operation': effective.operation_type}
    return ('explicit' if effective.operation_type == operation else 'default'), None


def catalog() -> dict:
    """Every role with, per operation, what the one resolver (resolve_mapping) answers."""
    rows = {(m.operation_type, m.account_type): m for m in AccountingMapping.query.filter_by(is_active=True)}
    accounts = {a.id: a for a in Account.query.filter(
        Account.id.in_({m.account_id for m in rows.values()} or {-1})).all()}
    required = required_pairs()
    roles, mapped_required = [], 0
    for key, role in ROLES.items():
        operations, overridable = [], []
        for operation in operations_of(role):
            row = rows.get((operation, key))
            is_required = (operation, key) in required
            if row is None and not is_required and operation != DEFAULT:
                overridable.append(operation)   # an optional override not set: offered, not shown
                continue
            effective = resolve_mapping(operation, key)
            if is_required and effective is not None:
                mapped_required += 1
            source, via = _source(effective, operation, key)
            operations.append({
                'operation': operation, 'required': is_required, 'mapping_id': row.id if row else None,
                'account': _account_payload(accounts.get(effective.account_id)) if effective else None,
                'source': source, 'via': via})
        if role.retired and not any(o['mapping_id'] for o in operations):
            continue        # nothing left of it to remove
        roles.append({'key': key, 'label': role.label, 'group': role.group, 'purpose': role.purpose,
                      'kind': role.kind, 'needs_twin': role.needs_twin, 'retired': role.retired,
                      'required': any(o['required'] for o in operations), 'operations': operations,
                      'overridable': [] if role.retired else overridable})
    return {'groups': list(GROUPS), 'roles': roles,
            'summary': {'required': len(required), 'required_mapped': mapped_required}}


def _refuse_unless_valid(operation: str, key: str, account: Account | None):
    role = ROLES.get(key)
    if role is None or not known(operation, key):
        raise MappingRefused('UNKNOWN_ROLE', f'لا يعرف النظام الدور ({operation} / {key})')
    if role.retired:
        raise MappingRefused('RETIRED_ROLE', f'«{role.label}» لم يعد يطلبه النظام: يُحذف ربطه ولا يُضاف')
    if account is None:
        raise MappingRefused('NO_ACCOUNT', 'الحساب غير موجود')
    if account.is_active is False:
        raise MappingRefused('INACTIVE_ACCOUNT', f'الحساب {account.account_number} موقوف')
    if (role.kind == WEIGHT) != bool(account.tracks_weight):
        wanted = 'وزنيًّا' if role.kind == WEIGHT else 'ماليًّا (غير وزني)'
        raise MappingRefused('WRONG_KIND', f'«{role.label}» يأخذ حسابًا {wanted}، و{account.account_number} '
                                           f'«{account.name}» ليس كذلك')


def _audit(action: str, *, by: str, row: AccountingMapping, before, after):
    db.session.add(AuditLog(user_name=by, action=action, entity_type='accounting_mapping', entity_id=row.id,
                            entity_number=f'{row.operation_type}/{row.account_type}', success=True,
                            details=json.dumps({'operation': row.operation_type, 'role': row.account_type,
                                                'before': before, 'after': after}, ensure_ascii=False)))


def save(operation: str, key: str, account_id: int, *, by: str) -> AccountingMapping:
    """Map *key* for *operation* to *account_id* -- checked, recorded. Not committed."""
    account = db.session.get(Account, account_id) if account_id else None
    _refuse_unless_valid(operation, key, account)
    row = AccountingMapping.query.filter_by(operation_type=operation, account_type=key).first()
    before = None
    if row is None:
        row = AccountingMapping(operation_type=operation, account_type=key, created_by=by)
        db.session.add(row)
    elif row.is_active:
        prior = db.session.get(Account, row.account_id)
        before = prior.account_number if prior else row.account_id
    row.account_id, row.is_active = account.id, True
    db.session.flush()
    _audit(AUDIT_SAVE, by=by, row=row, before=before, after=account.account_number)
    return row


def remove(mapping_id: int, *, by: str) -> None:
    """Remove a mapping -- refused when a required role would be left unresolved. Not committed."""
    row = db.session.get(AccountingMapping, mapping_id)
    if row is None:
        raise MappingRefused('NOT_FOUND', 'إعداد الربط غير موجود')
    role = ROLES.get(row.account_type)
    if row.operation_type == DEFAULT and role is not None and not role.retired:
        # A live role's default is changed, never removed: an optional one the code
        # reads (vat_settlement) creates its account again when it finds none.
        raise MappingRefused('DEFAULT_ROW', f'«{role.label}» يُغيَّر حسابه ولا يُحذف ربطه: يُحذف ربط عملية '
                                            f'بعينها، وربط دور لم يعد مستعملًا')
    # The required roles this row answers -- its own, the operations inheriting it, an alias's --
    # and which of them nothing else would answer.
    broken = sorted((op, k) for op, k in required_pairs()
                    if (answer := resolve_mapping(op, k)) is not None and answer.id == row.id
                    and resolve_mapping(op, k, excluding=row.id) is None)
    if broken:
        label = ROLES[row.account_type].label if row.account_type in ROLES else row.account_type
        asked = '، و'.join(f'«{ROLES[k].label if k in ROLES else k}» في {op}' for op, k in broken)
        raise MappingRefused('REQUIRED_ROLE', f'لا يُحذف ربط «{label}»: يقوم عليه {asked}، ولا ربط غيره. '
                                              f'يُغيَّر حسابه إن لزم')
    prior = db.session.get(Account, row.account_id)
    _audit(AUDIT_REMOVE, by=by, row=row, before=prior.account_number if prior else row.account_id, after=None)
    db.session.delete(row)
    db.session.flush()
