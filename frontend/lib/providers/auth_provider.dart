import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api_service.dart';
import '../models/app_user_model.dart';

/// Why a sign-in did not succeed, as the server said it -- or that the server
/// could not be reached. [code]: the server's ('invalid_credentials',
/// 'rate_limited', 'inactive_account', 'otp_required', 'otp_invalid', ...) or
/// 'unreachable' (nobody answered).
class LoginRefusal {
  final String code;
  final String message;

  const LoginRefusal(this.code, this.message);

  static const unreachable = LoginRefusal(
    'unreachable',
    'تعذّر الاتصال بالخادم — تحقق من الاتصال ثم أعد المحاولة',
  );
}

class AuthProvider extends ChangeNotifier {
  AuthProvider({ApiService Function()? api}) : _api = api ?? (() => ApiService());

  /// The server; tests pass a fake.
  final ApiService Function() _api;

  static const _storageKey = 'auth_current_user';
  static const _refreshTokenKey = 'refresh_token';

  LoginRefusal? _loginRefusal;

  /// Why the last [login] did not succeed; null after a success.
  LoginRefusal? get loginRefusal => _loginRefusal;

  AppUserModel? _currentUser;
  bool _loading = false;
  bool _initializing = true; // صحيح فقط أثناء init() — ليس أثناء login()
  bool _needsSetup = false;
  bool _mustChangePassword = false;

  AppUserModel? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  bool get isLoading => _loading;
  bool get isInitializing => _initializing;
  bool get needsSetup => _needsSetup;
  bool get mustChangePassword => _mustChangePassword;

  String get username => _currentUser?.username ?? '';
  String get fullName {
    if (_currentUser?.fullName?.isNotEmpty ?? false) {
      return _currentUser!.fullName!;
    }
    if (_currentUser?.employee?.name.isNotEmpty ?? false) {
      return _currentUser!.employee!.name;
    }
    return _currentUser?.username ?? '';
  }

  /// صورة المستخدم — يبحث في صورة المستخدم المباشرة أولاً ثم صورة الموظف
  String? get userPhoto =>
      _currentUser?.photo?.isNotEmpty == true
          ? _currentUser!.photo
          : _currentUser?.employee?.photo;

  /// تحديث الصورة محلياً بعد رفع ناجح
  void _updateLocalPhoto(String? photoBase64) {
    if (_currentUser == null) return;
    // تحديث صورة المستخدم المباشرة
    var updated = _currentUser!.copyWith(photo: photoBase64);
    // تحديث صورة الموظف المرتبط أيضاً (إذا وُجد)
    final emp = updated.employee;
    if (emp != null) {
      updated = updated.copyWith(
        employee: EmployeeSummary(
          id: emp.id,
          name: emp.name,
          employeeCode: emp.employeeCode,
          goldSafeBoxId: emp.goldSafeBoxId,
          cashSafeBoxId: emp.cashSafeBoxId,
          photo: photoBase64,
        ),
      );
    }
    _currentUser = updated;
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) {
      if (_currentUser != null) {
        prefs.setString(_storageKey, json.encode(_currentUser!.toStorageMap()));
      }
    });
  }

  /// رفع أو حذف صورة المستخدم — يعمل مع جميع المستخدمين بدون موظف مرتبط
  Future<void> updateUserPhoto(ApiService api, String? photoBase64) async {
    await api.updateCurrentUserPhoto(photoBase64);
    _updateLocalPhoto(photoBase64);
  }

  String get role => _currentUser?.role ?? '';
  String get roleDisplayName {
    switch (role) {
      case 'system_admin':
        return 'مسؤول نظام';
      case 'manager':
        return 'مدير';
      case 'accountant':
        return 'محاسب';
      case 'storekeeper':
        return 'أمين مخزون';
      case 'employee':
        return 'بائع';
      default:
        return role;
    }
  }

  /// التحقق من كون المستخدم مسؤول نظام
  bool get isSystemAdmin => role == 'system_admin';

  /// التحقق من كون المستخدم مدير أو أعلى
  bool get isManager => ['system_admin', 'manager'].contains(role);

  /// التحقق من كون المستخدم محاسب أو أعلى
  bool get isAccountant =>
      ['system_admin', 'manager', 'accountant'].contains(role);

  Future<void> init() async {
    _loading = true;
    _initializing = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      await _ensureJwtToken(prefs);
      final raw = prefs.getString(_storageKey);

      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = json.decode(raw) as Map<String, dynamic>;
          _currentUser = AppUserModel.fromStorageMap(decoded);
          _mustChangePassword = _currentUser?.mustChangePassword ?? false;
          _needsSetup = false;
          return;
        } catch (error) {
          if (kDebugMode) {
            debugPrint('AuthProvider.init decode error: $error');
          }
          await prefs.remove(_storageKey);
        }
      }

      // لم يتم العثور على مستخدم محفوظ - تحقق من حالة الإعداد
      final needsSetup = await _checkSetup();
      if (needsSetup) {
        return;
      }
    } finally {
      _loading = false;
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> _ensureJwtToken(SharedPreferences prefs) async {
    final jwtToken = prefs.getString('jwt_token');
    if (jwtToken == null || jwtToken.isEmpty) {
      final legacy = prefs.getString('auth_token');
      if (legacy != null && legacy.isNotEmpty) {
        await prefs.setString('jwt_token', legacy);
        await prefs.setString('flutter.jwt_token', legacy);
      }
    }
  }

  Future<bool> _checkSetup() async {
    try {
      final api = ApiService();
      final response = await api.checkSetup();

      if (response['needs_setup'] == true) {
        // النظام يحتاج تهيئة أولية (لا نقوم بتسجيل دخول وهمي)
        _needsSetup = true;
        return true;
      }

      _needsSetup = false;
      return false;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('AuthProvider._checkSetup error: $error');
      }
      return false;
    }
  }

  Future<bool> completeInitialSetup({
    String adminUsername = 'admin',
    bool keepNeedsSetup = true,
    required String companyName,
    required String adminFullName,
    required String adminPassword,
  }) async {
    if (_loading) {
      return false;
    }

    _loading = true;
    notifyListeners();

    try {
      final api = ApiService();
      final response = await api.setupInitialSystem(
        username: adminUsername,
        password: adminPassword,
        fullName: adminFullName,
        companyName: companyName,
      );

      if (response['success'] == true) {
        final token = response['token'] as String?;
        final refreshToken = response['refresh_token'] as String?;
        final userData = response['user'] as Map<String, dynamic>?;

        if (token == null || token.isEmpty || userData == null) {
          return false;
        }

        final prefs = await SharedPreferences.getInstance();
        // Save tokens under canonical and legacy/prefixed keys for backward compatibility.
        await prefs.setString('jwt_token', token);
        await prefs.setString('flutter.jwt_token', token);
        await prefs.setString('auth_token', token);
        if (refreshToken != null && refreshToken.isNotEmpty) {
          await prefs.setString(_refreshTokenKey, refreshToken);
          await prefs.setString('flutter.refresh_token', refreshToken);
        }

        var parsedUser = AppUserModel.fromJson(userData);
        final isAdmin = userData['is_admin'] == true;
        if (isAdmin && parsedUser.role.isEmpty) {
          parsedUser = parsedUser.copyWith(role: 'system_admin');
        }
        final serverRole = (userData['role'] ?? userData['role_code'])
            ?.toString();
        if (serverRole != null && serverRole.isNotEmpty) {
          parsedUser = parsedUser.copyWith(role: serverRole);
        } else if (isAdmin) {
          parsedUser = parsedUser.copyWith(role: 'system_admin');
        }

        _currentUser = parsedUser;
        _needsSetup = keepNeedsSetup;

        await prefs.setString(
          _storageKey,
          json.encode(_currentUser!.toStorageMap()),
        );

        return true;
      }

      return false;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('AuthProvider.completeInitialSetup error: $error');
      }
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void markSetupCompleted() {
    _needsSetup = false;
    notifyListeners();
  }

  Future<bool> login(String username, String password, {String? otp}) async {
    if (_loading) {
      return false;
    }

    _loading = true;
    _loginRefusal = null;
    notifyListeners();

    try {
      final api = _api();

      // محاولة تسجيل الدخول بـ JWT أولاً
      try {
        final response = await api.loginWithToken(username, password, otp: otp);

        if (response['success'] == true) {
          final token = response['token'] as String;
          final refreshToken = response['refresh_token'] as String?;
          final userData = response['user'] as Map<String, dynamic>;

          // حفظ Token وبيانات المستخدم
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            'jwt_token',
            token,
          ); // استخدام jwt_token بدلاً من auth_token
          await prefs.setString('auth_token', token); // للتوافق مع الكود القديم
          if (refreshToken != null && refreshToken.isNotEmpty) {
            await prefs.setString(_refreshTokenKey, refreshToken);
          }
          await prefs.setString('username', userData['username']);
          await prefs.setString('full_name', userData['full_name']);
          await prefs.setBool('is_admin', userData['is_admin'] ?? false);

          // ✅ استخدم الدور + الصلاحيات كما تأتي من السيرفر
          // هذا مهم لتجنّب 403 عند تبديل المستخدمين ولإظهار/إخفاء الميزات بشكل صحيح.
          var parsedUser = AppUserModel.fromJson(userData);
          final isAdmin = userData['is_admin'] == true;
          if (isAdmin && parsedUser.role.isEmpty) {
            parsedUser = parsedUser.copyWith(role: 'system_admin');
          }
          // بعض استجابات السيرفر قد لا تضع role بشكل متسق، فنعطي أولوية للحقول المتاحة.
          final serverRole = (userData['role'] ?? userData['role_code'])
              ?.toString();
          if (serverRole != null && serverRole.isNotEmpty) {
            parsedUser = parsedUser.copyWith(role: serverRole);
          } else if (isAdmin) {
            parsedUser = parsedUser.copyWith(role: 'system_admin');
          }

          _currentUser = parsedUser;
          _mustChangePassword = parsedUser.mustChangePassword;

          await prefs.setString(
            _storageKey,
            json.encode(_currentUser!.toStorageMap()),
          );

          return true;
        }
      } on LoginRefused catch (refused) {
        // The server answered and said no: its reason is the screen's. Not asked
        // again -- the old method posts the same credentials to the same route,
        // so each wrong password cost two of the five attempts a minute.
        _loginRefusal = LoginRefusal(refused.code, refused.message);
        return false;
      } on http.ClientException {
        _loginRefusal = LoginRefusal.unreachable;
        return false;
      } on TimeoutException {
        _loginRefusal = LoginRefusal.unreachable;
        return false;
      } catch (jwtError) {
        if (kDebugMode) {
          debugPrint('JWT login failed, trying old method: $jwtError');
        }

        // Fallback to old login method
        final user = await api.login(username, password);
        _currentUser = user;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_storageKey, json.encode(user.toStorageMap()));
        // Also ensure tokens are saved under canonical keys if fallback login returned a token-like field
        // (legacy flow may not provide tokens).

        return true;
      }

      _loginRefusal ??= const LoginRefusal('invalid_credentials', 'اسم المستخدم أو كلمة المرور غير صحيحة');
      return false;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('AuthProvider.login error: $error');
      }
      _loginRefusal ??= const LoginRefusal('invalid_credentials', 'اسم المستخدم أو كلمة المرور غير صحيحة');
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void clearMustChangePassword() {
    _mustChangePassword = false;
    if (_currentUser != null && _currentUser!.mustChangePassword) {
      _currentUser = _currentUser!.copyWith(mustChangePassword: false);
    }
    notifyListeners();
  }

  Future<void> logout() async {
    // Best-effort server-side logout (blacklist/revoke). Ignore failures.
    try {
      final prefs = await SharedPreferences.getInstance();
      final refreshToken = prefs.getString(_refreshTokenKey);
      final api = ApiService();
      await api.logoutServerSide(refreshToken: refreshToken);
    } catch (_) {}

    _currentUser = null;
    _needsSetup = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    await prefs.remove('jwt_token');
    await prefs.remove('auth_token');
    await prefs.remove(_refreshTokenKey);
    await prefs.remove('flutter.jwt_token');
    await prefs.remove('flutter.refresh_token');
    await prefs.remove('username');
    await prefs.remove('full_name');
    await prefs.remove('is_admin');
    notifyListeners();
  }

  bool hasPermission(String permissionKey) {
    if (_currentUser == null) {
      return false;
    }

    // مسؤول النظام لديه كل الصلاحيات
    if (_currentUser!.role == 'system_admin') {
      return true;
    }

    // The server's answer: the role's grants with the overrides on top
    // (ADR-036). The overrides alone hid from a role what it was allowed.
    final effective = _currentUser!.effectivePermissions;
    if (effective != null) {
      return effective.contains(permissionKey);
    }

    final permissions = _currentUser!.permissions;
    if (permissions == null) {
      return false;
    }

    // يدعم شكلين: قائمة أكواد أو dict {code: true}
    if (permissions is List) {
      return permissions.contains(permissionKey);
    }

    if (permissions is Map) {
      final value = permissions[permissionKey];
      if (value is bool) {
        return value;
      }
    }

    return false;
  }

  /// التحقق من امتلاك أي صلاحية من قائمة
  bool hasAnyPermission(List<String> permissionKeys) {
    return permissionKeys.any((key) => hasPermission(key));
  }

  /// التحقق من امتلاك جميع الصلاحيات من قائمة
  bool hasAllPermissions(List<String> permissionKeys) {
    return permissionKeys.every((key) => hasPermission(key));
  }
}
