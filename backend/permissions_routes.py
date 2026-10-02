"""
Routes لإدارة الصلاحيات والأدوار
"""
from flask import Blueprint, jsonify, request, g

from models import db, AppUser
from permissions import (
    ROLES,
    ALL_PERMISSIONS,
    ROLE_PERMISSIONS,
    get_permissions_by_category,
    get_role_permissions,
    validate_role,
)
from auth_decorators import require_auth, require_permission

permissions_bp = Blueprint('permissions', __name__)


def _can_manage_permissions(current_user) -> bool:
    # يدعم User و AppUser (كلاهما يملك has_permission / is_admin في models.py)
    try:
        if getattr(current_user, 'is_admin', False):
            return True
        if hasattr(current_user, 'has_permission'):
            return bool(current_user.has_permission('users.change_permissions'))
    except Exception:
        return False
    return False


@permissions_bp.route('/permissions/roles', methods=['GET'])
@require_permission('users.view')
@require_auth
def get_roles():
    """احصل على قائمة الأدوار المتاحة"""
    current_user = g.current_user
    if not _can_manage_permissions(current_user):
        return jsonify({'error': 'غير مصرح'}), 403
    return jsonify({
        'success': True,
        'roles': [
            {
                'code': code,
                'name': name,
                'permissions_count': len(ROLE_PERMISSIONS.get(code, []))
            }
            for code, name in ROLES.items()
        ]
    })


@permissions_bp.route('/permissions/all', methods=['GET'])
@require_permission('users.view')
@require_auth
def get_all_permissions():
    """احصل على جميع الصلاحيات مصنفة"""
    current_user = g.current_user
    if not _can_manage_permissions(current_user):
        return jsonify({'error': 'غير مصرح'}), 403
    
    categories = get_permissions_by_category()
    
    result = []
    for category_name, perms in categories.items():
        result.append({
            'category': category_name,
            'permissions': [
                {
                    'code': code,
                    'name': name
                }
                for code, name in perms.items()
            ]
        })
    
    return jsonify({
        'success': True,
        'categories': result
    })


@permissions_bp.route('/permissions/role/<role_code>', methods=['GET'])
@require_permission('users.view')
@require_auth
def get_role_default_permissions(role_code):
    """احصل على الصلاحيات الافتراضية لدور معين"""
    current_user = g.current_user
    if not _can_manage_permissions(current_user):
        return jsonify({'error': 'غير مصرح'}), 403
    
    if not validate_role(role_code):
        return jsonify({'error': 'دور غير صحيح'}), 400
    
    permissions = get_role_permissions(role_code)
    
    # إضافة أسماء الصلاحيات
    detailed_permissions = []
    for perm_code in permissions:
        perm_name = ALL_PERMISSIONS.get(perm_code, perm_code)
        detailed_permissions.append({
            'code': perm_code,
            'name': perm_name
        })
    
    return jsonify({
        'success': True,
        'role': {
            'code': role_code,
            'name': ROLES[role_code],
            'permissions': detailed_permissions
        }
    })


@permissions_bp.route('/users/<int:user_id>/permissions', methods=['GET'])
@require_auth
def get_user_permissions(user_id):
    """احصل على صلاحيات مستخدم معين"""
    current_user = g.current_user
    # يمكن للمدير/المخوّل فقط، أو (AppUser) مشاهدة صلاحياته الشخصية
    if not _can_manage_permissions(current_user):
        if isinstance(current_user, AppUser) and current_user.id == user_id:
            pass
        else:
            return jsonify({'error': 'غير مصرح'}), 403
    
    user = AppUser.query.get(user_id)
    if not user:
        return jsonify({'error': 'المستخدم غير موجود'}), 404
    
    # الصلاحيات الافتراضية للدور
    default_permissions = get_role_permissions(user.role)
    
    # الصلاحيات المخصصة
    custom_permissions = user.permissions or {}
    
    # دمج الصلاحيات
    all_user_permissions = []
    for perm_code in ALL_PERMISSIONS.keys():
        perm_name = ALL_PERMISSIONS[perm_code]
        has_perm = user.has_permission(perm_code)
        is_default = perm_code in default_permissions
        is_custom = False
        
        if isinstance(custom_permissions, dict):
            is_custom = perm_code in custom_permissions
        elif isinstance(custom_permissions, list):
            is_custom = perm_code in custom_permissions
        
        all_user_permissions.append({
            'code': perm_code,
            'name': perm_name,
            'has_permission': has_perm,
            'is_default': is_default,
            'is_custom': is_custom
        })
    
    return jsonify({
        'success': True,
        'user': {
            'id': user.id,
            'username': user.username,
            'role': user.role,
            'role_name': ROLES.get(user.role, user.role)
        },
        'permissions': all_user_permissions
    })


@permissions_bp.route('/users/<int:user_id>/permissions', methods=['PUT'])
@require_auth
def update_user_permissions(user_id):
    """تحديث صلاحيات مستخدم"""
    current_user = g.current_user
    if not current_user.has_permission('users.change_permissions'):
        return jsonify({'error': 'غير مصرح بتغيير الصلاحيات'}), 403
    
    user = AppUser.query.get(user_id)
    if not user:
        return jsonify({'error': 'المستخدم غير موجود'}), 404
    
    # لا يمكن تعديل صلاحيات مسؤول النظام إلا من مسؤول آخر
    if user.role == 'system_admin' and not current_user.is_admin:
        return jsonify({'error': 'لا يمكن تعديل صلاحيات مسؤول النظام'}), 403
    
    data = request.get_json()
    
    # تحديث الدور إذا تم إرساله
    if 'role' in data:
        new_role = data['role']
        if not validate_role(new_role):
            return jsonify({'error': 'دور غير صحيح'}), 400
        
        # فقط مسؤول النظام يمكنه تعيين دور system_admin
        if new_role == 'system_admin' and not current_user.is_admin:
            return jsonify({'error': 'غير مصرح بتعيين دور مسؤول النظام'}), 403
        
        user.role = new_role
    
    # تحديث الصلاحيات المخصصة
    if 'permissions' in data:
        permissions = data['permissions']
        
        # التحقق من صحة الصلاحيات
        if isinstance(permissions, dict):
            # تصفية الصلاحيات غير الصحيحة
            valid_permissions = {
                k: v for k, v in permissions.items()
                if k in ALL_PERMISSIONS
            }
            user.permissions = valid_permissions
        elif isinstance(permissions, list):
            # تصفية الصلاحيات غير الصحيحة
            valid_permissions = [
                p for p in permissions
                if p in ALL_PERMISSIONS
            ]
            user.permissions = valid_permissions
        else:
            user.permissions = None
    
    db.session.commit()
    
    return jsonify({
        'success': True,
        'message': 'تم تحديث الصلاحيات بنجاح',
        'user': user.to_dict()
    })


@permissions_bp.route('/users/<int:user_id>/role', methods=['PUT'])
@require_auth
def update_user_role(user_id):
    """تحديث دور المستخدم"""
    current_user = g.current_user
    if not current_user.has_permission('users.change_permissions'):
        return jsonify({'error': 'غير مصرح'}), 403
    
    user = AppUser.query.get(user_id)
    if not user:
        return jsonify({'error': 'المستخدم غير موجود'}), 404
    
    data = request.get_json()
    new_role = data.get('role')
    
    if not new_role or not validate_role(new_role):
        return jsonify({'error': 'دور غير صحيح'}), 400
    
    # فقط مسؤول النظام يمكنه تعيين/تعديل دور system_admin
    if (new_role == 'system_admin' or user.role == 'system_admin') and not current_user.is_admin:
        return jsonify({'error': 'غير مصرح بتعديل مسؤول النظام'}), 403
    
    user.role = new_role
    
    # إعادة ضبط الصلاحيات المخصصة عند تغيير الدور
    if data.get('reset_permissions', False):
        user.permissions = None
    
    db.session.commit()
    
    return jsonify({
        'success': True,
        'message': f'تم تحديث الدور إلى {ROLES[new_role]}',
        'user': user.to_dict()
    })
