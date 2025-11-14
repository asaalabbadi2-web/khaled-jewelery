"""
Decorators للمصادقة والتفويض
================================

يحتوي على:
- @require_auth: التحقق من تسجيل الدخول
- @require_permission: التحقق من الصلاحيات
- get_current_user: الحصول على المستخدم الحالي
"""

from functools import wraps
from flask import request, jsonify, g
import jwt
from datetime import datetime, timedelta
from models import User, db

# مفتاح JWT (يجب نقله إلى config.py في الإنتاج)
JWT_SECRET_KEY = 'yasar-gold-secret-key-2025'  # ⚠️ تغيير هذا في الإنتاج!
JWT_ALGORITHM = 'HS256'
JWT_EXPIRATION_HOURS = 24


def generate_token(user):
    """
    إنشاء JWT token للمستخدم
    
    Parameters:
    -----------
    user : User
        كائن المستخدم
    
    Returns:
    --------
    str
        JWT token
    """
    payload = {
        'user_id': user.id,
        'username': user.username,
        'is_admin': user.is_admin,
        'exp': datetime.utcnow() + timedelta(hours=JWT_EXPIRATION_HOURS),
        'iat': datetime.utcnow()
    }
    
    return jwt.encode(payload, JWT_SECRET_KEY, algorithm=JWT_ALGORITHM)


def decode_token(token):
    """
    فك تشفير JWT token
    
    Parameters:
    -----------
    token : str
        JWT token
    
    Returns:
    --------
    dict or None
        البيانات المُفككة أو None في حالة الفشل
    """
    try:
        payload = jwt.decode(token, JWT_SECRET_KEY, algorithms=[JWT_ALGORITHM])
        return payload
    except jwt.ExpiredSignatureError:
        return None  # Token منتهي الصلاحية
    except jwt.InvalidTokenError:
        return None  # Token غير صالح


def get_current_user():
    """
    الحصول على المستخدم الحالي من token
    
    Returns:
    --------
    User or None
        كائن المستخدم أو None
    """
    # التحقق من وجود token في header
    auth_header = request.headers.get('Authorization')
    if not auth_header or not auth_header.startswith('Bearer '):
        return None
    
    token = auth_header.split('Bearer ')[1]
    payload = decode_token(token)
    
    if not payload:
        return None
    
    # الحصول على المستخدم من قاعدة البيانات
    user = User.query.get(payload['user_id'])
    
    # التحقق من أن المستخدم نشط
    if user and user.is_active:
        return user
    
    return None


def require_auth(f):
    """
    Decorator للتحقق من تسجيل الدخول
    
    Usage:
    ------
    @app.route('/protected')
    @require_auth
    def protected_route():
        user = g.current_user
        return {'message': f'Hello {user.username}'}
    """
    @wraps(f)
    def decorated_function(*args, **kwargs):
        user = get_current_user()
        
        if not user:
            return jsonify({
                'success': False,
                'message': 'يجب تسجيل الدخول أولاً',
                'error': 'authentication_required'
            }), 401
        
        # حفظ المستخدم في g للوصول إليه في الدالة
        g.current_user = user
        
        # تحديث آخر تسجيل دخول
        if not user.last_login or (datetime.utcnow() - user.last_login).seconds > 3600:
            user.last_login = datetime.utcnow()
            db.session.commit()
        
        return f(*args, **kwargs)
    
    return decorated_function


def require_permission(permission_code):
    """
    Decorator للتحقق من صلاحية محددة
    
    Parameters:
    -----------
    permission_code : str
        كود الصلاحية المطلوبة (مثل: 'invoice.post')
    
    Usage:
    ------
    @app.route('/invoices/post/<int:id>')
    @require_permission('invoice.post')
    def post_invoice(id):
        # الكود هنا يُنفذ فقط إذا كان المستخدم لديه صلاحية invoice.post
        return {'message': 'Posted'}
    """
    def decorator(f):
        @wraps(f)
        @require_auth  # يجب تسجيل الدخول أولاً
        def decorated_function(*args, **kwargs):
            user = g.current_user
            
            # المدير الرئيسي لديه جميع الصلاحيات
            if user.is_admin:
                return f(*args, **kwargs)
            
            # التحقق من الصلاحية
            if not user.has_permission(permission_code):
                return jsonify({
                    'success': False,
                    'message': f'ليس لديك صلاحية لتنفيذ هذا الإجراء',
                    'error': 'permission_denied',
                    'required_permission': permission_code
                }), 403
            
            return f(*args, **kwargs)
        
        return decorated_function
    
    return decorator


def require_any_permission(*permission_codes):
    """
    Decorator للتحقق من امتلاك أي صلاحية من المُحددة
    
    Parameters:
    -----------
    *permission_codes : str
        أكواد الصلاحيات المطلوبة
    
    Usage:
    ------
    @app.route('/reports')
    @require_any_permission('report.view', 'report.financial')
    def view_reports():
        return {'reports': []}
    """
    def decorator(f):
        @wraps(f)
        @require_auth
        def decorated_function(*args, **kwargs):
            user = g.current_user
            
            # المدير الرئيسي لديه جميع الصلاحيات
            if user.is_admin:
                return f(*args, **kwargs)
            
            # التحقق من امتلاك أي صلاحية
            has_any = any(user.has_permission(code) for code in permission_codes)
            
            if not has_any:
                return jsonify({
                    'success': False,
                    'message': f'ليس لديك صلاحية لتنفيذ هذا الإجراء',
                    'error': 'permission_denied',
                    'required_permissions': list(permission_codes)
                }), 403
            
            return f(*args, **kwargs)
        
        return decorated_function
    
    return decorator


def require_admin(f):
    """
    Decorator للتحقق من كون المستخدم مدير
    
    Usage:
    ------
    @app.route('/admin/settings')
    @require_admin
    def admin_settings():
        return {'settings': {}}
    """
    @wraps(f)
    @require_auth
    def decorated_function(*args, **kwargs):
        user = g.current_user
        
        if not user.is_admin:
            return jsonify({
                'success': False,
                'message': 'هذه الصفحة متاحة للمديرين فقط',
                'error': 'admin_required'
            }), 403
        
        return f(*args, **kwargs)
    
    return decorated_function


def optional_auth(f):
    """
    Decorator اختياري للمصادقة - لا يفشل إذا لم يكن المستخدم مسجل دخول
    
    Usage:
    ------
    @app.route('/public-with-benefits')
    @optional_auth
    def public_route():
        user = g.get('current_user')  # قد يكون None
        if user:
            return {'message': f'Welcome back {user.username}'}
        return {'message': 'Welcome guest'}
    """
    @wraps(f)
    def decorated_function(*args, **kwargs):
        user = get_current_user()
        g.current_user = user  # قد يكون None
        return f(*args, **kwargs)
    
    return decorated_function
