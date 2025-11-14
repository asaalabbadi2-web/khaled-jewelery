"""
Routes للمصادقة والصلاحيات
============================

Endpoints:
- POST /api/auth/login - تسجيل الدخول
- POST /api/auth/logout - تسجيل الخروج
- GET /api/auth/me - معلومات المستخدم الحالي
- GET /api/roles - عرض جميع الأدوار
- POST /api/roles - إنشاء دور جديد
- PUT /api/roles/<id> - تعديل دور
- DELETE /api/roles/<id> - حذف دور
- GET /api/permissions - عرض جميع الصلاحيات
- POST /api/users/<id>/roles - إضافة/إزالة أدوار للمستخدم
"""

from flask import Blueprint, request, jsonify, g
from models import db, User, Role, Permission
from auth_decorators import (
    require_auth, require_permission, require_admin,
    generate_token, get_current_user
)
from datetime import datetime

auth_bp = Blueprint('auth', __name__)


# ==========================================
# 🔐 المصادقة (Authentication)
# ==========================================

@auth_bp.route('/auth/login', methods=['POST'])
def login():
    """
    تسجيل الدخول
    
    Body:
    {
        "username": "admin",
        "password": "admin123"
    }
    
    Returns:
    {
        "success": true,
        "token": "eyJ0eXAi...",
        "user": {...}
    }
    """
    try:
        data = request.get_json()
        username = data.get('username')
        password = data.get('password')
        
        if not username or not password:
            return jsonify({
                'success': False,
                'message': 'يجب إدخال اسم المستخدم وكلمة المرور'
            }), 400
        
        # البحث عن المستخدم
        user = User.query.filter_by(username=username).first()
        
        if not user or not user.check_password(password):
            return jsonify({
                'success': False,
                'message': 'اسم المستخدم أو كلمة المرور غير صحيحة'
            }), 401
        
        if not user.is_active:
            return jsonify({
                'success': False,
                'message': 'هذا الحساب غير نشط'
            }), 403
        
        # تحديث آخر تسجيل دخول
        user.last_login = datetime.utcnow()
        db.session.commit()
        
        # إنشاء token
        token = generate_token(user)
        
        return jsonify({
            'success': True,
            'message': 'تم تسجيل الدخول بنجاح',
            'token': token,
            'user': user.to_dict(include_roles=True, include_permissions=True)
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/auth/check-setup', methods=['GET'])
def check_setup_status():
    """فحص ما إذا كان النظام بحاجة لإعداد مستخدم أولي"""
    try:
        active_users = User.query.filter_by(is_active=True).count()

        if active_users == 0:
            return jsonify({
                'success': True,
                'needs_setup': True,
                'default_user': {
                    'username': 'admin',
                    'full_name': 'مدير النظام',
                    'role': 'admin',
                    'is_active': True,
                }
            }), 200

        return jsonify({
            'success': True,
            'needs_setup': False
        }), 200

    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/auth/me', methods=['GET'])
@require_auth
def get_current_user_info():
    """
    الحصول على معلومات المستخدم الحالي
    
    Headers:
    Authorization: Bearer <token>
    
    Returns:
    {
        "success": true,
        "user": {...}
    }
    """
    user = g.current_user
    return jsonify({
        'success': True,
        'user': user.to_dict(include_roles=True, include_permissions=True)
    }), 200


@auth_bp.route('/auth/change-password', methods=['POST'])
@require_auth
def change_password():
    """
    تغيير كلمة المرور
    
    Body:
    {
        "old_password": "admin123",
        "new_password": "newpassword"
    }
    """
    try:
        data = request.get_json()
        user = g.current_user
        
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        
        if not old_password or not new_password:
            return jsonify({
                'success': False,
                'message': 'يجب إدخال كلمة المرور القديمة والجديدة'
            }), 400
        
        if not user.check_password(old_password):
            return jsonify({
                'success': False,
                'message': 'كلمة المرور القديمة غير صحيحة'
            }), 401
        
        if len(new_password) < 6:
            return jsonify({
                'success': False,
                'message': 'كلمة المرور يجب أن تكون 6 أحرف على الأقل'
            }), 400
        
        user.set_password(new_password)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم تغيير كلمة المرور بنجاح'
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 👥 الأدوار (Roles)
# ==========================================

@auth_bp.route('/roles', methods=['GET'])
@require_permission('role.view')
def get_roles():
    """
    عرض جميع الأدوار
    
    Query params:
    - include_users: true/false (عرض عدد المستخدمين)
    """
    try:
        include_users = request.args.get('include_users', 'false').lower() == 'true'
        
        roles = Role.query.order_by(Role.name).all()
        
        return jsonify({
            'success': True,
            'roles': [role.to_dict(
                include_permissions=True,
                include_users_count=include_users
            ) for role in roles],
            'total': len(roles)
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/roles/<int:role_id>', methods=['GET'])
@require_permission('role.view')
def get_role(role_id):
    """الحصول على دور محدد"""
    try:
        role = Role.query.get(role_id)
        if not role:
            return jsonify({
                'success': False,
                'message': 'الدور غير موجود'
            }), 404
        
        return jsonify({
            'success': True,
            'role': role.to_dict(include_permissions=True, include_users_count=True)
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/roles', methods=['POST'])
@require_permission('role.create')
def create_role():
    """
    إنشاء دور جديد
    
    Body:
    {
        "name": "supervisor",
        "name_ar": "مشرف",
        "description": "...",
        "permission_ids": [1, 2, 3, ...]
    }
    """
    try:
        data = request.get_json()
        user = g.current_user
        
        # التحقق من الحقول المطلوبة
        if not data.get('name') or not data.get('name_ar'):
            return jsonify({
                'success': False,
                'message': 'يجب إدخال اسم الدور بالإنجليزية والعربية'
            }), 400
        
        # التحقق من عدم وجود دور بنفس الاسم
        existing = Role.query.filter_by(name=data['name']).first()
        if existing:
            return jsonify({
                'success': False,
                'message': 'يوجد دور بنفس الاسم'
            }), 400
        
        # إنشاء الدور
        role = Role(
            name=data['name'],
            name_ar=data['name_ar'],
            description=data.get('description'),
            created_by=user.username
        )
        
        # إضافة الصلاحيات
        permission_ids = data.get('permission_ids', [])
        if permission_ids:
            permissions = Permission.query.filter(Permission.id.in_(permission_ids)).all()
            role.permissions = permissions
        
        db.session.add(role)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم إنشاء الدور بنجاح',
            'role': role.to_dict(include_permissions=True)
        }), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/roles/<int:role_id>', methods=['PUT'])
@require_permission('role.edit')
def update_role(role_id):
    """تعديل دور"""
    try:
        role = Role.query.get(role_id)
        if not role:
            return jsonify({
                'success': False,
                'message': 'الدور غير موجود'
            }), 404
        
        if role.is_system:
            return jsonify({
                'success': False,
                'message': 'لا يمكن تعديل أدوار النظام'
            }), 400
        
        data = request.get_json()
        
        # تحديث البيانات
        if 'name_ar' in data:
            role.name_ar = data['name_ar']
        if 'description' in data:
            role.description = data['description']
        if 'is_active' in data:
            role.is_active = data['is_active']
        
        # تحديث الصلاحيات
        if 'permission_ids' in data:
            permissions = Permission.query.filter(
                Permission.id.in_(data['permission_ids'])
            ).all()
            role.permissions = permissions
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم تحديث الدور بنجاح',
            'role': role.to_dict(include_permissions=True)
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/roles/<int:role_id>', methods=['DELETE'])
@require_permission('role.delete')
def delete_role(role_id):
    """حذف دور"""
    try:
        role = Role.query.get(role_id)
        if not role:
            return jsonify({
                'success': False,
                'message': 'الدور غير موجود'
            }), 404
        
        if role.is_system:
            return jsonify({
                'success': False,
                'message': 'لا يمكن حذف أدوار النظام'
            }), 400
        
        # التحقق من عدم وجود مستخدمين
        if role.users.count() > 0:
            return jsonify({
                'success': False,
                'message': f'لا يمكن حذف الدور لأنه مُسند لـ {role.users.count()} مستخدم'
            }), 400
        
        db.session.delete(role)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم حذف الدور بنجاح'
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 🔑 الصلاحيات (Permissions)
# ==========================================

@auth_bp.route('/permissions', methods=['GET'])
@require_permission('role.view')
def get_permissions():
    """
    عرض جميع الصلاحيات
    
    Query params:
    - category: فلترة حسب التصنيف
    """
    try:
        category = request.args.get('category')
        
        query = Permission.query.filter_by(is_active=True)
        
        if category:
            query = query.filter_by(category=category)
        
        permissions = query.order_by(Permission.category, Permission.code).all()
        
        # تجميع حسب التصنيف
        by_category = {}
        for perm in permissions:
            if perm.category not in by_category:
                by_category[perm.category] = []
            by_category[perm.category].append(perm.to_dict())
        
        return jsonify({
            'success': True,
            'permissions': [p.to_dict() for p in permissions],
            'by_category': by_category,
            'total': len(permissions)
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 👤 إدارة المستخدمين (CRUD)
# ==========================================

@auth_bp.route('/users', methods=['GET'])
@require_permission('user.view')
def list_users():
    """
    عرض قائمة المستخدمين
    
    Query params:
    - search: للبحث في username و full_name
    - is_active: true/false
    - role: اسم الدور
    - page: رقم الصفحة (افتراضي 1)
    - per_page: عدد النتائج في الصفحة (افتراضي 50)
    """
    try:
        # Query parameters
        search = request.args.get('search', '').strip()
        is_active = request.args.get('is_active')
        role = request.args.get('role')
        page = request.args.get('page', 1, type=int)
        per_page = request.args.get('per_page', 50, type=int)
        
        # بناء Query
        query = User.query
        
        if search:
            query = query.filter(
                db.or_(
                    User.username.ilike(f'%{search}%'),
                    User.full_name.ilike(f'%{search}%')
                )
            )
        
        if is_active is not None:
            active_bool = is_active.lower() == 'true'
            query = query.filter(User.is_active == active_bool)
        
        if role:
            query = query.join(User.roles).filter(Role.name == role)
        
        # Pagination
        pagination = query.order_by(User.created_at.desc()).paginate(
            page=page, per_page=per_page, error_out=False
        )
        
        return jsonify({
            'success': True,
            'users': [user.to_dict(include_roles=True) for user in pagination.items],
            'total': pagination.total,
            'page': page,
            'per_page': per_page,
            'pages': pagination.pages
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/users/<int:user_id>', methods=['GET'])
@require_permission('user.view')
def get_user(user_id):
    """الحصول على بيانات مستخدم واحد"""
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({
                'success': False,
                'message': 'المستخدم غير موجود'
            }), 404
        
        return jsonify({
            'success': True,
            'user': user.to_dict(include_roles=True, include_permissions=True)
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/users', methods=['POST'])
@require_permission('user.create')
def create_user():
    """
    إنشاء مستخدم جديد
    
    Body:
    {
        "username": "user123",
        "password": "password123",
        "full_name": "اسم المستخدم",
        "is_admin": false,
        "is_active": true,
        "role_ids": [1, 2]
    }
    """
    try:
        data = request.get_json()
        
        # التحقق من البيانات المطلوبة
        username = data.get('username', '').strip()
        password = data.get('password', '').strip()
        full_name = data.get('full_name', '').strip()
        
        if not username:
            return jsonify({
                'success': False,
                'message': 'اسم المستخدم مطلوب'
            }), 400
        
        if not password:
            return jsonify({
                'success': False,
                'message': 'كلمة المرور مطلوبة'
            }), 400
        
        # التحقق من عدم تكرار اسم المستخدم
        existing = User.query.filter_by(username=username).first()
        if existing:
            return jsonify({
                'success': False,
                'message': 'اسم المستخدم موجود مسبقاً'
            }), 400
        
        # إنشاء المستخدم
        user = User(
            username=username,
            full_name=full_name,
            is_admin=data.get('is_admin', False),
            is_active=data.get('is_active', True)
        )
        user.set_password(password)
        
        # إضافة الأدوار
        role_ids = data.get('role_ids', [])
        if role_ids:
            roles = Role.query.filter(Role.id.in_(role_ids)).all()
            user.roles = roles
        
        db.session.add(user)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم إنشاء المستخدم بنجاح',
            'user': user.to_dict(include_roles=True)
        }), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/users/<int:user_id>', methods=['PUT'])
@require_permission('user.edit')
def update_user(user_id):
    """
    تحديث بيانات مستخدم
    
    Body:
    {
        "full_name": "الاسم الجديد",
        "is_admin": false,
        "is_active": true,
        "password": "كلمة مرور جديدة (اختياري)"
    }
    """
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({
                'success': False,
                'message': 'المستخدم غير موجود'
            }), 404
        
        data = request.get_json()
        
        # تحديث البيانات
        if 'full_name' in data:
            user.full_name = data['full_name'].strip()
        
        if 'is_admin' in data:
            user.is_admin = data['is_admin']
        
        if 'is_active' in data:
            user.is_active = data['is_active']
        
        # تحديث كلمة المرور (اختياري)
        if 'password' in data and data['password']:
            user.set_password(data['password'])
        
        user.updated_at = datetime.utcnow()
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم تحديث المستخدم بنجاح',
            'user': user.to_dict(include_roles=True)
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/users/<int:user_id>', methods=['DELETE'])
@require_permission('user.delete')
def delete_user(user_id):
    """حذف مستخدم"""
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({
                'success': False,
                'message': 'المستخدم غير موجود'
            }), 404
        
        # منع حذف المستخدم الحالي
        if g.current_user.id == user_id:
            return jsonify({
                'success': False,
                'message': 'لا يمكنك حذف حسابك الخاص'
            }), 400
        
        username = user.username
        db.session.delete(user)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': f'تم حذف المستخدم {username} بنجاح'
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/users/<int:user_id>/toggle-active', methods=['POST'])
@require_permission('user.edit')
def toggle_user_active(user_id):
    """تفعيل/تعطيل حساب مستخدم"""
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({
                'success': False,
                'message': 'المستخدم غير موجود'
            }), 404
        
        # منع تعطيل المستخدم الحالي
        if g.current_user.id == user_id:
            return jsonify({
                'success': False,
                'message': 'لا يمكنك تعطيل حسابك الخاص'
            }), 400
        
        user.is_active = not user.is_active
        user.updated_at = datetime.utcnow()
        db.session.commit()
        
        status = 'تفعيل' if user.is_active else 'تعطيل'
        
        return jsonify({
            'success': True,
            'message': f'تم {status} حساب {user.username}',
            'is_active': user.is_active
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


# ==========================================
# 👤 إدارة أدوار المستخدمين
# ==========================================

@auth_bp.route('/users/<int:user_id>/roles', methods=['POST'])
@require_permission('user.manage_roles')
def manage_user_roles(user_id):
    """
    إضافة أو إزالة أدوار للمستخدم
    
    Body:
    {
        "action": "add" | "remove",
        "role_ids": [1, 2, 3]
    }
    """
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({
                'success': False,
                'message': 'المستخدم غير موجود'
            }), 404
        
        data = request.get_json()
        action = data.get('action')
        role_ids = data.get('role_ids', [])
        
        if action not in ['add', 'remove']:
            return jsonify({
                'success': False,
                'message': 'action يجب أن تكون add أو remove'
            }), 400
        
        roles = Role.query.filter(Role.id.in_(role_ids)).all()
        
        if action == 'add':
            for role in roles:
                if role not in user.roles:
                    user.roles.append(role)
            message = f'تم إضافة {len(roles)} دور للمستخدم'
        else:  # remove
            for role in roles:
                if role in user.roles:
                    user.roles.remove(role)
            message = f'تم إزالة {len(roles)} دور من المستخدم'
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': message,
            'user': user.to_dict(include_roles=True)
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/users/<int:user_id>/permissions', methods=['GET'])
@require_auth
def get_user_permissions(user_id):
    """الحصول على جميع صلاحيات مستخدم"""
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({
                'success': False,
                'message': 'المستخدم غير موجود'
            }), 404
        
        # التحقق من الصلاحية (المستخدم يمكنه رؤية صلاحياته فقط)
        current_user = g.current_user
        if current_user.id != user_id and not current_user.is_admin:
            return jsonify({
                'success': False,
                'message': 'غير مصرح لك بعرض صلاحيات هذا المستخدم'
            }), 403
        
        permissions = user.get_all_permissions()
        
        return jsonify({
            'success': True,
            'permissions': [perm.to_dict() for perm in permissions],
            'total': len(permissions)
        }), 200
        
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500
