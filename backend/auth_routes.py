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
from models import (
    db,
    User,
    Role,
    Permission,
    AppUser,
    Employee,
    AuditLog,
    TokenBlacklist,
    RefreshToken,
    LoginAttempt,
    PasswordResetToken,
    Settings,
)
from auth_decorators import (
    require_auth, require_permission, require_admin,
    generate_token, get_current_user, get_bearer_token, decode_token_raw
)
from config import JWT_REFRESH_TOKEN_EXP_DAYS, ENABLE_REDIS_CACHE

from redis_client import get_redis

from typing import Optional, Dict, Tuple

from sqlalchemy import func

from datetime import datetime, timedelta
import hashlib
import secrets

from setup_utils import is_setup_locked

try:
    import pyotp
except Exception:  # pragma: no cover
    pyotp = None

auth_bp = Blueprint('auth', __name__)


def _now() -> datetime:
    return datetime.utcnow()


def _client_ip() -> Optional[str]:
    # Behind proxies, you might want to trust X-Forwarded-For only in controlled setups.
    return request.remote_addr


def _user_agent() -> Optional[str]:
    return request.headers.get('User-Agent')


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode('utf-8')).hexdigest()


def _issue_refresh_token_for_user(user, user_type: str, days: Optional[int] = None) -> str:
    plain = secrets.token_urlsafe(48)
    token_hash = _hash_token(plain)

    expires_days = int(days if days is not None else JWT_REFRESH_TOKEN_EXP_DAYS)
    expires_at = _now() + timedelta(days=expires_days)

    session = RefreshToken(
        token_hash=token_hash,
        user_id=user.id,
        user_type=user_type,
        expires_at=expires_at,
        ip_address=_client_ip(),
        user_agent=_user_agent(),
    )
    db.session.add(session)
    db.session.commit()

    if ENABLE_REDIS_CACHE:
        r = get_redis()
        if r is not None:
            try:
                ttl = int((expires_at - _now()).total_seconds())
                if ttl > 0:
                    r.setex(f'rt:hash:{token_hash}', ttl, str(session.id))
            except Exception:
                pass
    return plain


def _rate_limit_login(username: Optional[str]) -> Optional[Tuple[bool, Dict, int]]:
    """Return (blocked_response) if too many failed attempts.

    Prefer Redis counters when available; fallback to DB aggregation.
    """
    ip = _client_ip() or ''
    user_key = (username or '').strip().lower()

    if ENABLE_REDIS_CACHE:
        r = get_redis()
        if r is not None:
            try:
                key = f'rl:login:{ip}:{user_key}'
                current = r.get(key)
                if current and int(current) >= 5:
                    return True, {
                        'success': False,
                        'message': 'محاولات كثيرة. الرجاء الانتظار دقيقة ثم المحاولة مرة أخرى',
                        'error': 'rate_limited',
                    }, 429
                return None
            except Exception:
                pass

    # DB fallback
    window_start = _now() - timedelta(minutes=1)
    try:
        recent_count = (
            LoginAttempt.query
            .filter(LoginAttempt.ip_address == ip)
            .filter(LoginAttempt.created_at >= window_start)
            .filter(LoginAttempt.username == user_key)
            .filter(LoginAttempt.success == False)  # noqa: E712
            .count()
        )
        if recent_count >= 5:
            return True, {
                'success': False,
                'message': 'محاولات كثيرة. الرجاء الانتظار دقيقة ثم المحاولة مرة أخرى',
                'error': 'rate_limited',
            }, 429
    except Exception:
        return None

    return None


def _record_login_attempt(username: Optional[str], success: bool, failure_reason: Optional[str] = None) -> None:
    user_key = (username or '').strip().lower()
    ip = _client_ip()

    db.session.add(LoginAttempt(
        username=user_key,
        ip_address=ip,
        user_agent=_user_agent(),
        success=bool(success),
        failure_reason=failure_reason,
    ))
    db.session.commit()

    if not success and ENABLE_REDIS_CACHE:
        r = get_redis()
        if r is not None:
            try:
                key = f'rl:login:{ip or ""}:{user_key}'
                value = r.incr(key)
                if value == 1:
                    r.expire(key, 60)
            except Exception:
                pass


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
        data = request.get_json() or {}
        username = data.get('username')
        password = data.get('password')
        remember_me = bool(data.get('remember_me', False))
        otp_code = data.get('otp')

        blocked = _rate_limit_login(username)
        if blocked:
            _, payload, status = blocked
            return jsonify(payload), status
        
        username = (str(username) if username is not None else '').strip()
        password = (str(password) if password is not None else '')
        username_key = username.lower()

        if not username or not password:
            return jsonify({
                'success': False,
                'message': 'يجب إدخال اسم المستخدم وكلمة المرور'
            }), 400
        
        # 1) محاولة تسجيل الدخول عبر AppUser (مرتبط بالموظفين)
        app_user = AppUser.query.filter_by(username=username).first()
        if app_user is None:
            # Postgres equality is case-sensitive; also tolerate accidental whitespace in stored usernames.
            app_user = AppUser.query.filter(
                func.lower(func.trim(AppUser.username)) == username_key
            ).first()
        if app_user and app_user.check_password(password):
            if not app_user.is_active:
                _record_login_attempt(username, success=False, failure_reason='inactive_account')
                return jsonify({'success': False, 'message': 'هذا الحساب غير نشط', 'error': 'inactive_account'}), 403

            # 2FA enforcement (optional)
            if getattr(app_user, 'two_factor_enabled', False):
                if not pyotp:
                    return jsonify({'success': False, 'message': 'ميزة التحقق الثنائي غير مفعلة على الخادم'}), 500
                if not otp_code:
                    _record_login_attempt(username, success=False, failure_reason='otp_required')
                    return jsonify({'success': False, 'message': 'رمز التحقق مطلوب', 'error': 'otp_required'}), 401
                secret = getattr(app_user, 'totp_secret', None)
                if not secret:
                    return jsonify({'success': False, 'message': 'حسابك لا يحتوي على إعدادات تحقق ثنائي صحيحة'}), 500
                totp = pyotp.TOTP(secret)
                if not totp.verify(str(otp_code).strip(), valid_window=1):
                    _record_login_attempt(username, success=False, failure_reason='otp_invalid')
                    return jsonify({'success': False, 'message': 'رمز التحقق غير صحيح', 'error': 'otp_invalid'}), 401

            app_user.last_login_at = datetime.utcnow()
            db.session.commit()

            token = generate_token(app_user)
            refresh_token = _issue_refresh_token_for_user(
                app_user,
                user_type='app_user',
                days=(30 if remember_me else None),
            )

            _record_login_attempt(username, success=True)

            AuditLog.log_action(
                user_name=app_user.username,
                action='login_success',
                entity_type='Auth',
                entity_id=app_user.id,
                ip_address=_client_ip(),
                user_agent=_user_agent(),
                success=True,
            )
            return jsonify({
                'success': True,
                'message': 'تم تسجيل الدخول بنجاح',
                'token': token,
                'refresh_token': refresh_token,
                'user': app_user.to_dict(include_employee=True),
                'user_type': 'app_user',
            }), 200

        # 2) fallback: المستخدم القديم User
        user = User.query.filter_by(username=username).first()
        if user is None:
            user = User.query.filter(
                func.lower(func.trim(User.username)) == username_key
            ).first()

        if not user or not user.check_password(password):
            _record_login_attempt(username, success=False, failure_reason='invalid_credentials')

            AuditLog.log_action(
                user_name=(username or 'unknown'),
                action='login_failed',
                entity_type='Auth',
                entity_id=0,
                ip_address=_client_ip(),
                user_agent=_user_agent(),
                success=False,
                error_message='invalid_credentials',
            )
            return jsonify({'success': False, 'message': 'اسم المستخدم أو كلمة المرور غير صحيحة', 'error': 'invalid_credentials'}), 401

        if not user.is_active:
            _record_login_attempt(username, success=False, failure_reason='inactive_account')
            return jsonify({'success': False, 'message': 'هذا الحساب غير نشط', 'error': 'inactive_account'}), 403

        user.last_login = datetime.utcnow()
        db.session.commit()

        token = generate_token(user)
        refresh_token = _issue_refresh_token_for_user(
            user,
            user_type='user',
            days=(30 if remember_me else None),
        )

        _record_login_attempt(username, success=True)

        AuditLog.log_action(
            user_name=user.username,
            action='login_success',
            entity_type='Auth',
            entity_id=user.id,
            ip_address=_client_ip(),
            user_agent=_user_agent(),
            success=True,
        )

        return jsonify({
            'success': True,
            'message': 'تم تسجيل الدخول بنجاح',
            'token': token,
            'refresh_token': refresh_token,
            'user': user.to_dict(include_roles=True, include_permissions=True),
            'user_type': 'user',
        }), 200
        
    except Exception as e:
        try:
            db.session.rollback()
        except Exception:
            pass
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/auth/logout', methods=['POST'])
@require_auth
def logout():
    """تسجيل الخروج: يحظر access token الحالي ويقوم بإلغاء refresh token (إن توفر)."""
    try:
        user = g.current_user
        token = get_bearer_token()
        payload = decode_token_raw(token) if token else None

        # blacklist current access token
        if payload and payload.get('jti') and payload.get('exp'):
            exp_dt = datetime.utcfromtimestamp(payload['exp']) if isinstance(payload['exp'], (int, float)) else None
            if exp_dt:
                exists = TokenBlacklist.query.filter_by(jti=payload['jti']).first()
                if not exists:
                    db.session.add(TokenBlacklist(
                        jti=payload['jti'],
                        token_type='access',
                        expires_at=exp_dt,
                        reason='logout',
                    ))

                if ENABLE_REDIS_CACHE:
                    r = get_redis()
                    if r is not None:
                        try:
                            ttl = int((exp_dt - _now()).total_seconds())
                            if ttl > 0:
                                r.setex(f'bl:jti:{payload["jti"]}', ttl, '1')
                            else:
                                r.set(f'bl:jti:{payload["jti"]}', '1')
                        except Exception:
                            pass

        # revoke refresh token if provided
        data = request.get_json(silent=True) or {}
        refresh_plain = data.get('refresh_token')
        if refresh_plain:
            token_hash = _hash_token(str(refresh_plain))
            session = RefreshToken.query.filter_by(token_hash=token_hash, is_revoked=False).first()
            if session:
                session.is_revoked = True
                session.revoked_at = _now()
                session.revoked_reason = 'logout'

                if ENABLE_REDIS_CACHE:
                    r = get_redis()
                    if r is not None:
                        try:
                            r.delete(f'rt:hash:{token_hash}')
                        except Exception:
                            pass

        db.session.commit()

        AuditLog.log_action(
            user_name=getattr(user, 'username', 'unknown'),
            action='logout',
            entity_type='Auth',
            entity_id=getattr(user, 'id', 0),
            ip_address=_client_ip(),
            user_agent=_user_agent(),
            success=True,
        )

        return jsonify({'success': True, 'message': 'تم تسجيل الخروج بنجاح'}), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@auth_bp.route('/auth/refresh', methods=['POST'])
def refresh_access_token():
    """Rotate refresh token and issue a new access token."""
    try:
        data = request.get_json() or {}
        refresh_plain = data.get('refresh_token')
        if not refresh_plain:
            return jsonify({'success': False, 'message': 'refresh_token مطلوب'}), 400

        token_hash = _hash_token(str(refresh_plain))
        session = RefreshToken.query.filter_by(token_hash=token_hash, is_revoked=False).first()
        if not session:
            return jsonify({'success': False, 'message': 'جلسة غير صالحة', 'error': 'invalid_refresh'}), 401

        if session.expires_at and session.expires_at < _now():
            session.is_revoked = True
            session.revoked_at = _now()
            session.revoked_reason = 'expired'
            db.session.commit()
            return jsonify({'success': False, 'message': 'انتهت الجلسة', 'error': 'refresh_expired'}), 401

        # Load user
        user = None
        if session.user_type == 'app_user':
            user = AppUser.query.get(session.user_id)
        else:
            user = User.query.get(session.user_id)
        if not user or not getattr(user, 'is_active', True):
            session.is_revoked = True
            session.revoked_at = _now()
            session.revoked_reason = 'user_inactive'
            db.session.commit()
            return jsonify({'success': False, 'message': 'الحساب غير متاح', 'error': 'user_inactive'}), 403

        # rotate refresh token
        session.is_revoked = True
        session.revoked_at = _now()
        session.revoked_reason = 'rotated'
        session.last_used_at = _now()

        new_refresh = _issue_refresh_token_for_user(user, user_type=session.user_type)
        new_access = generate_token(user)

        db.session.commit()
        return jsonify({
            'success': True,
            'token': new_access,
            'refresh_token': new_refresh,
        }), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@auth_bp.route('/auth/sessions', methods=['GET'])
@require_auth
def list_sessions():
    """List sessions (matches Flutter expectations).

    Response: JSON array of sessions.
    """
    user = g.current_user
    include_all = str(request.args.get('include_all', '')).strip().lower() in ('1', 'true', 'yes', 'y', 'on')

    query = RefreshToken.query
    if include_all and getattr(user, 'is_admin', False):
        query = query.order_by(RefreshToken.created_at.desc()).limit(200)
    else:
        user_type = 'app_user' if isinstance(user, AppUser) else 'user'
        query = (
            query
            .filter_by(user_id=user.id, user_type=user_type)
            .order_by(RefreshToken.created_at.desc())
            .limit(50)
        )

    sessions = query.all()
    payload = []
    now = _now()
    for s in sessions:
        is_active = (not bool(s.is_revoked)) and (s.expires_at is None or s.expires_at > now)
        payload.append({
            'id': s.id,
            'ip_address': s.ip_address,
            'user_agent': s.user_agent,
            'device_info': getattr(s, 'device_fingerprint', None),
            'created_at': s.created_at.isoformat() if s.created_at else None,
            'last_activity': (s.last_used_at or s.created_at).isoformat() if (s.last_used_at or s.created_at) else None,
            'is_active': bool(is_active),
        })
    return jsonify(payload), 200


@auth_bp.route('/auth/sessions/<int:session_id>', methods=['DELETE'])
@require_auth
def terminate_session(session_id: int):
    user = g.current_user
    session = RefreshToken.query.get(session_id)
    if not session:
        return jsonify({'success': False, 'message': 'الجلسة غير موجودة'}), 404

    # Allow owner or admin.
    is_owner = False
    if isinstance(user, AppUser):
        is_owner = session.user_type == 'app_user' and session.user_id == user.id
    else:
        is_owner = session.user_type == 'user' and session.user_id == user.id

    if not (is_owner or getattr(user, 'is_admin', False)):
        return jsonify({'success': False, 'message': 'غير مصرح'}), 403

    session.is_revoked = True
    session.revoked_at = _now()
    session.revoked_reason = 'terminated'

    if ENABLE_REDIS_CACHE:
        r = get_redis()
        if r is not None:
            try:
                r.delete(f'rt:hash:{session.token_hash}')
            except Exception:
                pass

    db.session.commit()
    return jsonify({'success': True}), 200


@auth_bp.route('/auth/sessions/all', methods=['DELETE'])
@require_auth
def terminate_all_sessions():
    user = g.current_user
    user_type = 'app_user' if isinstance(user, AppUser) else 'user'

    sessions = RefreshToken.query.filter_by(user_id=user.id, user_type=user_type, is_revoked=False).all()
    for s in sessions:
        s.is_revoked = True
        s.revoked_at = _now()
        s.revoked_reason = 'terminate_all'

        if ENABLE_REDIS_CACHE:
            r = get_redis()
            if r is not None:
                try:
                    r.delete(f'rt:hash:{s.token_hash}')
                except Exception:
                    pass

    db.session.commit()
    return jsonify({'success': True}), 200


@auth_bp.route('/auth/sessions/<int:session_id>/revoke', methods=['POST'])
@require_auth
def revoke_session(session_id: int):
    user = g.current_user
    user_type = 'app_user' if isinstance(user, AppUser) else 'user'
    session = RefreshToken.query.get(session_id)
    if not session or session.user_id != user.id or session.user_type != user_type:
        return jsonify({'success': False, 'message': 'الجلسة غير موجودة'}), 404
    session.is_revoked = True
    session.revoked_at = _now()
    session.revoked_reason = 'user_revoked'
    db.session.commit()
    return jsonify({'success': True, 'message': 'تم إلغاء الجلسة'}), 200


@auth_bp.route('/auth/password-reset/admin-create', methods=['POST'])
@require_admin
def admin_create_password_reset():
    """Admin generates a password reset token for a user/app_user."""
    try:
        data = request.get_json() or {}
        user_type = (data.get('user_type') or 'app_user').strip()
        user_id = data.get('user_id')
        username = data.get('username')

        target = None
        if user_id is not None:
            target = (AppUser.query.get(user_id) if user_type == 'app_user' else User.query.get(user_id))
        elif username:
            target = (AppUser.query.filter_by(username=username).first() if user_type == 'app_user' else User.query.filter_by(username=username).first())

        if not target:
            return jsonify({'success': False, 'message': 'المستخدم غير موجود'}), 404

        plain = secrets.token_urlsafe(32)
        token_hash = _hash_token(plain)
        expires_at = _now() + timedelta(minutes=15)

        rec = PasswordResetToken(
            token_hash=token_hash,
            user_id=target.id,
            user_type=('app_user' if user_type == 'app_user' else 'user'),
            expires_at=expires_at,
        )
        db.session.add(rec)
        db.session.commit()

        # Return token only when explicitly allowed or in admin flow.
        return jsonify({
            'success': True,
            'expires_at': expires_at.isoformat(),
            'token': plain,
        }), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@auth_bp.route('/auth/password-reset/confirm', methods=['POST'])
def confirm_password_reset():
    """Reset password using a reset token."""
    try:
        data = request.get_json() or {}
        token_plain = data.get('token')
        new_password = data.get('new_password')

        if not token_plain or not new_password:
            return jsonify({'success': False, 'message': 'token و new_password مطلوبين'}), 400
        if len(str(new_password)) < 6:
            return jsonify({'success': False, 'message': 'كلمة المرور يجب أن تكون 6 أحرف على الأقل'}), 400

        token_hash = _hash_token(str(token_plain))
        rec = PasswordResetToken.query.filter_by(token_hash=token_hash).first()
        if not rec or rec.is_used:
            return jsonify({'success': False, 'message': 'توكن غير صالح', 'error': 'invalid_token'}), 401
        if rec.expires_at and rec.expires_at < _now():
            return jsonify({'success': False, 'message': 'انتهت صلاحية التوكن', 'error': 'token_expired'}), 401

        target = AppUser.query.get(rec.user_id) if rec.user_type == 'app_user' else User.query.get(rec.user_id)
        if not target:
            return jsonify({'success': False, 'message': 'المستخدم غير موجود'}), 404

        target.set_password(str(new_password))
        rec.is_used = True
        rec.used_at = _now()
        rec.used_ip = _client_ip()

        # revoke all refresh tokens for this user
        RefreshToken.query.filter_by(user_id=target.id, user_type=rec.user_type, is_revoked=False).update({
            'is_revoked': True,
            'revoked_at': _now(),
            'revoked_reason': 'password_reset',
        })

        db.session.commit()
        return jsonify({'success': True, 'message': 'تم إعادة تعيين كلمة المرور'}), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@auth_bp.route('/auth/2fa/setup', methods=['POST'])
@require_auth
def setup_2fa():
    """Generate a TOTP secret for AppUser and return provisioning URI."""
    user = g.current_user
    if not isinstance(user, AppUser):
        return jsonify({'success': False, 'message': 'ميزة التحقق الثنائي متاحة لحسابات AppUser فقط'}), 400
    if not pyotp:
        return jsonify({'success': False, 'message': 'pyotp غير مثبت على الخادم'}), 500

    secret = pyotp.random_base32()
    user.totp_secret = secret
    user.two_factor_enabled = False
    user.two_factor_verified_at = None
    db.session.commit()

    issuer = 'YasarGoldPOS'
    uri = pyotp.totp.TOTP(secret).provisioning_uri(name=user.username, issuer_name=issuer)
    return jsonify({'success': True, 'otpauth_uri': uri}), 200


@auth_bp.route('/auth/2fa/enable', methods=['POST'])
@require_auth
def enable_2fa():
    user = g.current_user
    if not isinstance(user, AppUser):
        return jsonify({'success': False, 'message': 'ميزة التحقق الثنائي متاحة لحسابات AppUser فقط'}), 400
    if not pyotp:
        return jsonify({'success': False, 'message': 'pyotp غير مثبت على الخادم'}), 500

    data = request.get_json() or {}
    code = data.get('otp')
    if not code:
        return jsonify({'success': False, 'message': 'otp مطلوب'}), 400

    if not user.totp_secret:
        return jsonify({'success': False, 'message': 'الرجاء تنفيذ setup أولاً'}), 400

    totp = pyotp.TOTP(user.totp_secret)
    if not totp.verify(str(code).strip(), valid_window=1):
        return jsonify({'success': False, 'message': 'رمز التحقق غير صحيح'}), 401

    user.two_factor_enabled = True
    user.two_factor_verified_at = _now()
    db.session.commit()
    return jsonify({'success': True, 'message': 'تم تفعيل التحقق الثنائي'}), 200


@auth_bp.route('/auth/2fa/verify', methods=['POST'])
@require_auth
def verify_2fa():
    """Alias endpoint for Flutter: verifies code and enables 2FA."""
    user = g.current_user
    if not isinstance(user, AppUser):
        return jsonify({'success': False, 'error': 'ميزة التحقق الثنائي متاحة لحسابات AppUser فقط'}), 400
    if not pyotp:
        return jsonify({'success': False, 'error': 'pyotp غير مثبت على الخادم'}), 500

    data = request.get_json() or {}
    code = data.get('code') or data.get('otp')
    if not code:
        return jsonify({'success': False, 'error': 'رمز التحقق مطلوب'}), 400
    if not user.totp_secret:
        return jsonify({'success': False, 'error': 'الرجاء تنفيذ setup أولاً'}), 400

    totp = pyotp.TOTP(user.totp_secret)
    if not totp.verify(str(code).strip(), valid_window=1):
        return jsonify({'success': False, 'error': 'رمز التحقق غير صحيح'}), 401

    user.two_factor_enabled = True
    user.two_factor_verified_at = _now()
    db.session.commit()
    return jsonify({'success': True, 'message': 'تم تفعيل المصادقة الثنائية'}), 200


@auth_bp.route('/auth/2fa/disable', methods=['POST'])
@require_auth
def disable_2fa():
    user = g.current_user
    if not isinstance(user, AppUser):
        return jsonify({'success': False, 'message': 'ميزة التحقق الثنائي متاحة لحسابات AppUser فقط'}), 400
    if not pyotp:
        return jsonify({'success': False, 'message': 'pyotp غير مثبت على الخادم'}), 500

    # Flutter client calls this endpoint without a code.
    # If a code is provided, validate it. Otherwise allow disable as a best-effort.
    data = request.get_json(silent=True) or {}
    code = data.get('otp') or data.get('code')
    if code and user.two_factor_enabled and user.totp_secret:
        totp = pyotp.TOTP(user.totp_secret)
        if not totp.verify(str(code).strip(), valid_window=1):
            return jsonify({'success': False, 'message': 'رمز التحقق غير صحيح'}), 401

    user.two_factor_enabled = False
    user.totp_secret = None
    user.two_factor_verified_at = None
    db.session.commit()
    return jsonify({'success': True, 'message': 'تم إيقاف التحقق الثنائي'}), 200


@auth_bp.route('/auth/password-policy', methods=['GET'])
@require_admin
def get_password_policy():
    settings = Settings.query.first()
    policy = (settings.to_dict().get('password_policy') if settings else None) or {
        'min_length': 6,
        'require_numbers': False,
    }
    return jsonify(policy), 200


@auth_bp.route('/auth/password-policy', methods=['PUT'])
@require_admin
def update_password_policy():
    data = request.get_json() or {}
    min_length = int(data.get('min_length') or 6)
    require_numbers = bool(data.get('require_numbers', False))
    policy = {
        'min_length': max(4, min_length),
        'require_numbers': require_numbers,
    }

    settings = Settings.query.first()
    if not settings:
        settings = Settings()
        db.session.add(settings)
    import json as _json
    settings.password_policy = _json.dumps(policy, ensure_ascii=False)
    db.session.commit()
    return jsonify({'success': True, 'policy': policy}), 200


@auth_bp.route('/auth/security-summary', methods=['GET'])
@require_admin
def security_summary():
    """Lightweight security KPIs for dashboard."""
    since = _now() - timedelta(hours=24)

    failed_logins_24h = LoginAttempt.query.filter(LoginAttempt.created_at >= since).filter(LoginAttempt.success == False).count()  # noqa: E712
    successful_logins_24h = LoginAttempt.query.filter(LoginAttempt.created_at >= since).filter(LoginAttempt.success == True).count()  # noqa: E712
    active_sessions = RefreshToken.query.filter_by(is_revoked=False).filter(RefreshToken.expires_at >= _now()).count()
    blacklisted_tokens = TokenBlacklist.query.filter(TokenBlacklist.expires_at >= _now()).count()

    # top IPs for failed logins
    try:
        top_ips = (
            db.session.query(LoginAttempt.ip_address, db.func.count(LoginAttempt.id))
            .filter(LoginAttempt.created_at >= since)
            .filter(LoginAttempt.success == False)  # noqa: E712
            .group_by(LoginAttempt.ip_address)
            .order_by(db.func.count(LoginAttempt.id).desc())
            .limit(5)
            .all()
        )
        top_ips_payload = [{'ip': ip, 'count': int(cnt)} for ip, cnt in top_ips]
    except Exception:
        top_ips_payload = []

    return jsonify({
        'failed_logins_24h': int(failed_logins_24h),
        'successful_logins_24h': int(successful_logins_24h),
        'active_sessions': int(active_sessions),
        'blacklisted_tokens': int(blacklisted_tokens),
        'top_failed_ips': top_ips_payload,
    }), 200


@auth_bp.route('/auth/check-setup', methods=['GET'])
def check_setup_status():
    """فحص ما إذا كان النظام بحاجة لإعداد مستخدم أولي"""
    try:
        locked = bool(is_setup_locked())

        active_users = User.query.filter_by(is_active=True).count()
        active_app_users = AppUser.query.filter_by(is_active=True).count()
        needs_setup = (active_users + active_app_users) == 0

        settings = Settings.query.first()
        policy = None
        if settings and getattr(settings, 'password_policy', None):
            try:
                import json as _json
                policy = _json.loads(settings.password_policy)
            except Exception:
                policy = None

        if needs_setup:
            return jsonify({
                'success': True,
                'needs_setup': True,
                'setup_locked': locked,
                'message': (
                    'النظام يحتاج إعداد مستخدم أولي. '
                    + ('ملف .env.production موجود (تم قفل جزء إعداد البيئة). يمكنك إنشاء المدير ثم متابعة العمل.' if locked else '')
                ).strip(),
                # Backward compatibility for older Flutter flows
                'default_user': {
                    'username': 'admin',
                    'full_name': 'مدير النظام',
                    'role': 'system_admin',
                    'is_active': True,
                },
                'company_name': (settings.company_name if settings else 'مجوهرات خالد'),
                'password_policy': policy or {
                    'min_length': 6,
                    'require_numbers': False,
                },
            }), 200

        return jsonify({
            'success': True,
            'needs_setup': False,
            'setup_locked': locked,
            'message': ('واجهة التهيئة مقفلة. احذف ملف .env.production لإعادة التهيئة.' if locked else None),
        }), 200

    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/auth/setup-initial', methods=['POST'])
def setup_initial_admin():
    """Initial bootstrap: create the first admin user and basic settings.

    Allowed only when there are no active users (User/AppUser).

    Body:
    {
      "username": "admin",           # optional, defaults to admin
      "full_name": "مدير النظام",   # optional
      "password": "...",            # required
      "company_name": "..."         # optional
    }
    """
    try:
        # Guard: allow setup only on empty system
        active_users = User.query.filter_by(is_active=True).count()
        active_app_users = AppUser.query.filter_by(is_active=True).count()
        if (active_users + active_app_users) > 0:
            if is_setup_locked():
                return jsonify({
                    'success': False,
                    'message': 'واجهة التهيئة مقفلة. احذف ملف .env.production لإعادة التهيئة.',
                    'error': 'setup_locked',
                }), 403
            return jsonify({
                'success': False,
                'message': 'تم إعداد النظام مسبقاً',
                'error': 'already_setup',
            }), 409

        data = request.get_json() or {}
        username = (data.get('username') or 'admin')
        full_name = (data.get('full_name') or 'مدير النظام')
        password = (data.get('password') or '')
        company_name = (data.get('company_name') or '').strip()

        username = str(username).strip()
        full_name = str(full_name).strip() if full_name is not None else 'مدير النظام'
        password = str(password)

        if not username:
            return jsonify({'success': False, 'message': 'اسم المستخدم مطلوب', 'error': 'username_required'}), 400
        if not password:
            return jsonify({'success': False, 'message': 'كلمة المرور مطلوبة', 'error': 'password_required'}), 400

        settings = Settings.query.first()
        # Password policy
        min_length = 6
        require_numbers = False
        if settings and getattr(settings, 'password_policy', None):
            try:
                import json as _json
                decoded = _json.loads(settings.password_policy)
                if isinstance(decoded, dict):
                    min_length = int(decoded.get('min_length') or min_length)
                    require_numbers = bool(decoded.get('require_numbers', require_numbers))
            except Exception:
                pass

        if len(password) < max(4, min_length):
            return jsonify({
                'success': False,
                'message': f'كلمة المرور يجب أن تكون {max(4, min_length)} أحرف على الأقل',
                'error': 'weak_password',
            }), 400
        if require_numbers and not any(ch.isdigit() for ch in password):
            return jsonify({
                'success': False,
                'message': 'كلمة المرور يجب أن تحتوي على رقم واحد على الأقل',
                'error': 'weak_password',
            }), 400

        # Ensure Settings exists and update minimal identity info
        if not settings:
            settings = Settings()
            db.session.add(settings)
        if company_name:
            settings.company_name = company_name

        # Prevent collisions (even though system is empty, handle edge cases)
        if User.query.filter(func.lower(func.trim(User.username)) == username.lower()).first() is not None:
            return jsonify({'success': False, 'message': 'اسم المستخدم مستخدم بالفعل', 'error': 'username_taken'}), 409
        if AppUser.query.filter(func.lower(func.trim(AppUser.username)) == username.lower()).first() is not None:
            return jsonify({'success': False, 'message': 'اسم المستخدم مستخدم بالفعل', 'error': 'username_taken'}), 409

        # Create legacy User (for older parts of the system)
        user = User(
            username=username,
            full_name=(full_name or 'مدير النظام'),
            is_active=True,
            is_admin=True,
            created_by='setup',
        )
        user.set_password(password)
        db.session.add(user)

        # Create AppUser (for Flutter / permissions)
        app_user = AppUser(
            username=username,
            full_name=(full_name or 'مدير النظام'),
            role='system_admin',
            is_active=True,
        )
        app_user.set_password(password)
        db.session.add(app_user)
        db.session.commit()

        # Issue tokens for the AppUser (Flutter expects this)
        token = generate_token(app_user)
        refresh_token = _issue_refresh_token_for_user(app_user, user_type='app_user', days=30)

        return jsonify({
            'success': True,
            'message': 'تم إعداد النظام بنجاح',
            'token': token,
            'refresh_token': refresh_token,
            'user': app_user.to_dict(include_employee=True),
            'user_type': 'app_user',
        }), 200

    except IntegrityError:
        db.session.rollback()
        return jsonify({'success': False, 'message': 'اسم المستخدم مستخدم بالفعل', 'error': 'username_taken'}), 409
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


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
    if isinstance(user, AppUser):
        return jsonify({'success': True, 'user': user.to_dict(include_employee=True), 'user_type': 'app_user'}), 200
    return jsonify({'success': True, 'user': user.to_dict(include_roles=True, include_permissions=True), 'user_type': 'user'}), 200


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


@auth_bp.route('/users/<int:user_id>/reset-password', methods=['POST'])
@require_permission('user.edit')
def reset_user_password(user_id):
    """تعيين كلمة مرور جديدة لمستخدم بواسطة المشرف."""
    try:
        user = User.query.get(user_id)
        if not user:
            return jsonify({'success': False, 'message': 'المستخدم غير موجود'}), 404

        data = request.get_json(silent=True) or {}
        new_password = data.get('new_password') or data.get('password')

        if not new_password or len(str(new_password)) < 6:
            return jsonify({
                'success': False,
                'message': 'كلمة المرور مطلوبة ويجب ألا تقل عن 6 أحرف'
            }), 400

        user.set_password(str(new_password))
        user.updated_at = datetime.utcnow()
        db.session.commit()

        return jsonify({'success': True, 'message': 'تم تحديث كلمة المرور'}), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


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


@auth_bp.route('/legacy/users/<int:user_id>/permissions', methods=['GET'])
@require_auth
def get_user_permissions_legacy(user_id):
    """(Legacy) الحصول على جميع صلاحيات مستخدم (نظام الصلاحيات القديم)."""
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


# ==========================================
# 👥 AppUser Management
# ==========================================

_APPUSER_ROLE_ORDER = {
    'employee': 1,
    'accountant': 2,
    'manager': 3,
    'system_admin': 4,
}


def _normalize_app_user_role(role: Optional[str]) -> str:
    raw = (role or '').strip().lower()
    if raw in ('staff', 'employee'):
        return 'employee'
    if raw in ('admin', 'system_admin', 'system-admin', 'systemadmin', 'sysadmin'):
        return 'system_admin'
    if raw in ('manager', 'accountant'):
        return raw
    # safest default
    return 'employee'


def _actor_app_user_role(actor) -> str:
    """Return normalized role for current actor (supports legacy User)."""
    if isinstance(actor, AppUser):
        return _normalize_app_user_role(getattr(actor, 'role', None))
    if isinstance(actor, User):
        return 'system_admin' if bool(getattr(actor, 'is_admin', False)) else 'employee'
    return 'employee'


def _has_any_system_admin() -> bool:
    return AppUser.query.filter_by(role='system_admin').count() > 0


def _can_create_role(actor_role: str, requested_role: str) -> bool:
    """Strict rule: system_admin can create any; manager can create employee only."""
    if actor_role == 'system_admin':
        return True
    if actor_role == 'manager':
        return requested_role == 'employee'
    return False


def _forbidden(message: str, error: str = 'forbidden', status: int = 403):
    return jsonify({'success': False, 'error': error, 'message': message}), status

@auth_bp.route('/app-users', methods=['GET'])
@require_auth
def get_app_users():
    """الحصول على قائمة مستخدمي النظام"""
    try:
        app_users = AppUser.query.all()
        return jsonify({
            'success': True,
            'app_users': [u.to_dict(include_employee=True) for u in app_users],
            'total': len(app_users)
        }), 200
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/app-users/<int:app_user_id>', methods=['GET'])
@require_auth
def get_app_user(app_user_id):
    """الحصول على تفاصيل مستخدم"""
    try:
        app_user = AppUser.query.get(app_user_id)
        if not app_user:
            return jsonify({
                'success': False,
                'message': 'المستخدم غير موجود'
            }), 404
        
        return jsonify({
            'success': True,
            'app_user': app_user.to_dict(include_employee=True)
        }), 200
    except Exception as e:
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/app-users/from-employee', methods=['POST'])
@require_auth
def create_app_user_from_employee():
    """إنشاء حساب مستخدم من موظف"""
    try:
        actor = g.current_user
        actor_role = _actor_app_user_role(actor)
        data = request.get_json()
        employee_id = data.get('employee_id')
        username = data.get('username')
        password = data.get('password')
        role = _normalize_app_user_role(data.get('role', 'employee'))
        permissions = data.get('permissions')
        
        if not employee_id or not username or not password:
            return jsonify({
                'success': False,
                'message': 'يجب إدخال معرف الموظف واسم المستخدم وكلمة المرور'
            }), 400
        
        # التحقق من وجود الموظف
        employee = Employee.query.get(employee_id)
        if not employee:
            return jsonify({
                'success': False,
                'message': 'الموظف غير موجود'
            }), 404
        
        # التحقق من عدم وجود حساب سابق للموظف
        existing_user = AppUser.query.filter_by(employee_id=employee_id).first()
        if existing_user:
            return jsonify({
                'success': False,
                'message': 'يوجد حساب مستخدم مرتبط بهذا الموظف بالفعل'
            }), 409
        
        # التحقق من عدم تكرار اسم المستخدم
        if AppUser.query.filter_by(username=username).first():
            return jsonify({
                'success': False,
                'message': 'اسم المستخدم موجود مسبقاً'
            }), 409

        # قواعد إنشاء الحسابات حسب الدور
        if role == 'system_admin':
            if _has_any_system_admin() and actor_role != 'system_admin':
                return _forbidden('إنشاء مسؤول نظام متاح لمسؤول النظام فقط')
        if not _can_create_role(actor_role, role):
            return _forbidden('غير مصرح بإنشاء هذا الدور')
        if permissions is not None and actor_role != 'system_admin':
            return _forbidden('تعديل الصلاحيات متاح لمسؤول النظام فقط')
        
        # إنشاء المستخدم
        if permissions is None and role == 'manager' and actor_role == 'system_admin':
            permissions = {
                'bonus.calculate': True,
                'bonus.approve': True,
                'bonus.pay': True,
                'bonus_rule.create': True,
                'bonus_rule.update': True,
                'bonus_rule.delete': True,
            }

        app_user = AppUser(
            username=username,
            full_name=employee.name,
            employee_id=employee_id,
            role=role,
            permissions=permissions,
        )
        app_user.set_password(password)
        
        db.session.add(app_user)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم إنشاء حساب المستخدم بنجاح',
            'app_user': app_user.to_dict(include_employee=True)
        }), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/app-users', methods=['POST'])
@require_auth
def create_app_user():
    """إنشاء AppUser (مع/بدون ربط موظف).

    Body:
    {
        "username": "slh",
        "password": "...",
        "role": "staff",
        "employee_id": 123,            # optional
        "full_name": "...",           # optional
        "permissions": {...} | [...],  # optional
        "is_active": true              # optional
    }
    """
    try:
        actor = g.current_user
        actor_role = _actor_app_user_role(actor)
        data = request.get_json() or {}

        username = data.get('username')
        password = data.get('password')
        role = _normalize_app_user_role(data.get('role', 'employee'))
        employee_id = data.get('employee_id')
        full_name = data.get('full_name')
        permissions = data.get('permissions')
        is_active = data.get('is_active', True)

        # قواعد إنشاء الحسابات حسب الدور
        if role == 'system_admin':
            # إنشاء أول مسؤول نظام مسموح فقط عند عدم وجود أي system_admin، أو بواسطة system_admin قائم.
            if _has_any_system_admin() and actor_role != 'system_admin':
                return _forbidden('إنشاء مسؤول نظام متاح لمسؤول النظام فقط')
        if not _can_create_role(actor_role, role):
            return _forbidden('غير مصرح بإنشاء هذا الدور')
        if permissions is not None and actor_role != 'system_admin':
            return _forbidden('تعديل الصلاحيات متاح لمسؤول النظام فقط')

        if permissions is None and role == 'manager' and actor_role == 'system_admin':
            permissions = {
                'bonus.calculate': True,
                'bonus.approve': True,
                'bonus.pay': True,
                'bonus_rule.create': True,
                'bonus_rule.update': True,
                'bonus_rule.delete': True,
            }

        if not username or not password:
            return jsonify({
                'success': False,
                'message': 'يجب إدخال اسم المستخدم وكلمة المرور'
            }), 400

        if AppUser.query.filter_by(username=username).first():
            return jsonify({
                'success': False,
                'message': 'اسم المستخدم موجود مسبقاً'
            }), 409

        employee = None
        if employee_id is not None:
            employee = Employee.query.get(employee_id)
            if not employee:
                return jsonify({
                    'success': False,
                    'message': 'الموظف غير موجود'
                }), 404

            existing_user = AppUser.query.filter_by(employee_id=employee_id).first()
            if existing_user:
                return jsonify({
                    'success': False,
                    'message': 'يوجد حساب مستخدم مرتبط بهذا الموظف بالفعل'
                }), 409

        if not full_name and employee is not None:
            full_name = employee.name

        app_user = AppUser(
            username=username,
            full_name=full_name,
            employee_id=employee_id,
            role=role,
            permissions=permissions,
            is_active=bool(is_active),
        )
        app_user.set_password(password)

        db.session.add(app_user)
        db.session.commit()

        return jsonify({
            'success': True,
            'message': 'تم إنشاء حساب المستخدم بنجاح',
            'app_user': app_user.to_dict(include_employee=True)
        }), 201

    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/app-users/<int:app_user_id>/toggle-active', methods=['POST'])
@require_auth
def toggle_app_user_active(app_user_id):
    """تبديل حالة تفعيل AppUser."""
    try:
        actor = g.current_user
        app_user = AppUser.query.get(app_user_id)
        if not app_user:
            return jsonify({'success': False, 'message': 'المستخدم غير موجود'}), 404

        # منع تعطيل الحساب الحالي (فقط إذا كان المستخدم الحالي AppUser)
        if isinstance(actor, AppUser) and actor.id == app_user_id:
            return jsonify({
                'success': False,
                'error': 'self_action_not_allowed',
                'message': 'لا يمكنك تعطيل حسابك الخاص'
            }), 400

        # تحديد دور المنفذ (يدعم User legacy عبر is_admin)
        actor_role = None
        if isinstance(actor, AppUser):
            actor_role = getattr(actor, 'role', None) or 'employee'
        elif isinstance(actor, User):
            actor_role = 'system_admin' if bool(getattr(actor, 'is_admin', False)) else 'employee'
        else:
            actor_role = 'employee'

        # قواعد الصلاحيات المطلوبة: المدير يعطل الموظف فقط
        if actor_role == 'system_admin':
            allowed = True
        elif actor_role == 'manager':
            allowed = (app_user.role == 'employee')
        else:
            allowed = False

        if not allowed:
            return jsonify({
                'success': False,
                'error': 'forbidden',
                'message': 'غير مصرح بتعطيل/تفعيل هذا المستخدم'
            }), 403

        # منع تعطيل آخر مسؤول نظام فعّال
        if app_user.role == 'system_admin' and bool(app_user.is_active):
            active_admins = AppUser.query.filter_by(role='system_admin', is_active=True).count()
            if active_admins <= 1:
                return jsonify({
                    'success': False,
                    'error': 'last_admin_protection',
                    'message': 'لا يمكن تعطيل آخر مسؤول نظام فعّال'
                }), 400

        app_user.is_active = not bool(app_user.is_active)
        db.session.commit()

        return jsonify({
            'success': True,
            'is_active': app_user.is_active,
            'app_user': app_user.to_dict(include_employee=True)
        }), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@auth_bp.route('/app-users/<int:app_user_id>/reset-password', methods=['POST'])
@require_auth
def reset_app_user_password(app_user_id):
    """إعادة تعيين كلمة المرور لـ AppUser."""
    try:
        app_user = AppUser.query.get(app_user_id)
        if not app_user:
            return jsonify({'success': False, 'message': 'المستخدم غير موجود'}), 404

        data = request.get_json() or {}
        new_password = data.get('new_password') or data.get('password')
        if not new_password:
            return jsonify({'success': False, 'message': 'يجب إدخال كلمة المرور الجديدة'}), 400

        app_user.set_password(new_password)
        db.session.commit()

        return jsonify({'success': True, 'message': 'تم تحديث كلمة المرور بنجاح'}), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@auth_bp.route('/app-users/<int:app_user_id>', methods=['PUT'])
@require_auth
def update_app_user(app_user_id):
    """تحديث بيانات مستخدم"""
    try:
        actor = g.current_user
        actor_role = _actor_app_user_role(actor)
        app_user = AppUser.query.get(app_user_id)
        if not app_user:
            return jsonify({
                'success': False,
                'message': 'المستخدم غير موجود'
            }), 404

        data = request.get_json() or {}

        target_role = _normalize_app_user_role(getattr(app_user, 'role', None))

        # المدير يعدّل الموظف فقط
        if actor_role == 'manager' and target_role != 'employee':
            return _forbidden('غير مصرح بتعديل هذا المستخدم')

        # منع تعديل الدور إلا لمسؤول النظام
        if 'role' in data:
            new_role = _normalize_app_user_role(data.get('role'))
            if new_role != target_role and actor_role != 'system_admin':
                return _forbidden('تغيير الدور متاح لمسؤول النظام فقط')
            # منع ترقية إلى system_admin إلا لمسؤول النظام (وبعد وجود مسؤول نظام)
            if new_role == 'system_admin' and actor_role != 'system_admin':
                return _forbidden('إنشاء/تعيين مسؤول نظام متاح لمسؤول النظام فقط')
            data['role'] = new_role

        # منع تعديل الصلاحيات إلا لمسؤول النظام
        if 'permissions' in data and actor_role != 'system_admin':
            return _forbidden('تعديل الصلاحيات متاح لمسؤول النظام فقط')

        # منع تعديل is_active من هذا المسار إلا لمسؤول النظام (واحمِ آخر مسؤول نظام)
        if 'is_active' in data and actor_role != 'system_admin':
            return _forbidden('تغيير حالة التفعيل متاح لمسؤول النظام فقط')
        if 'is_active' in data and actor_role == 'system_admin':
            desired_active = bool(data.get('is_active'))
            # منع تعطيل النفس (AppUser فقط)
            if isinstance(actor, AppUser) and actor.id == app_user_id and not desired_active:
                return jsonify({
                    'success': False,
                    'error': 'self_action_not_allowed',
                    'message': 'لا يمكنك تعطيل حسابك الخاص'
                }), 400
            if target_role == 'system_admin' and bool(app_user.is_active) and not desired_active:
                active_admins = AppUser.query.filter_by(role='system_admin', is_active=True).count()
                if active_admins <= 1:
                    return jsonify({
                        'success': False,
                        'error': 'last_admin_protection',
                        'message': 'لا يمكن تعطيل آخر مسؤول نظام فعّال'
                    }), 400

        # دعم ربط/فك ربط المستخدم بموظف
        # ملاحظة: الربط مهم لاحتساب المكافآت لأن BonusCalculator يعتمد على employee.user_account
        if 'employee_id' in data:
            employee_id = data.get('employee_id')
            if employee_id is None:
                app_user.employee_id = None
            else:
                employee = Employee.query.get(employee_id)
                if not employee:
                    return jsonify({
                        'success': False,
                        'message': 'الموظف غير موجود'
                    }), 404

                existing_user = AppUser.query.filter(
                    AppUser.employee_id == employee_id,
                    AppUser.id != app_user.id,
                ).first()
                if existing_user:
                    return jsonify({
                        'success': False,
                        'message': 'يوجد حساب مستخدم مرتبط بهذا الموظف بالفعل'
                    }), 409

                app_user.employee_id = employee_id
                # إذا لم يُرسل full_name، اجعله يتبع اسم الموظف لسهولة التتبع
                if not data.get('full_name'):
                    app_user.full_name = employee.name
        
        if 'full_name' in data:
            app_user.full_name = data['full_name']
        if 'role' in data:
            app_user.role = data['role']
        if 'permissions' in data:
            app_user.permissions = data['permissions']
        if 'is_active' in data:
            app_user.is_active = data['is_active']
        if 'password' in data and data['password']:
            app_user.set_password(data['password'])
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم تحديث بيانات المستخدم بنجاح',
            'app_user': app_user.to_dict(include_employee=True)
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500


@auth_bp.route('/app-users/<int:app_user_id>', methods=['DELETE'])
@require_auth
def delete_app_user(app_user_id):
    """حذف مستخدم"""
    try:
        app_user = AppUser.query.get(app_user_id)
        if not app_user:
            return jsonify({
                'success': False,
                'message': 'المستخدم غير موجود'
            }), 404
        
        db.session.delete(app_user)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم حذف المستخدم بنجاح'
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({
            'success': False,
            'message': str(e)
        }), 500
