import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_service.dart';
import '../models/app_user_model.dart';

class AuthProvider extends ChangeNotifier {
  static const _storageKey = 'auth_current_user';

  AppUserModel? _currentUser;
  bool _loading = false;

  AppUserModel? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  bool get isLoading => _loading;

  String get username => _currentUser?.username ?? '';
  String get role => _currentUser?.role ?? '';

  Future<void> init() async {
    _loading = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);

      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = json.decode(raw) as Map<String, dynamic>;
          _currentUser = AppUserModel.fromStorageMap(decoded);
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
        return; // تم تسجيل الدخول التلقائي في _checkSetup
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> _checkSetup() async {
    try {
      final api = ApiService();
      final response = await api.checkSetup();

      if (response['needs_setup'] == true) {
        // تسجيل دخول تلقائي بالمستخدم الافتراضي
        final defaultUserData =
            response['default_user'] as Map<String, dynamic>;
        _currentUser = AppUserModel.fromJson(defaultUserData);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _storageKey,
          json.encode(_currentUser!.toStorageMap()),
        );

        notifyListeners();
        return true;
      }

      return false;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('AuthProvider._checkSetup error: $error');
      }
      return false;
    }
  }

  Future<bool> login(String username, String password) async {
    if (_loading) {
      return false;
    }

    _loading = true;
    notifyListeners();

    try {
      final api = ApiService();
      
      // محاولة تسجيل الدخول بـ JWT أولاً
      try {
        final response = await api.loginWithToken(username, password);
        
        if (response['success'] == true) {
          final token = response['token'] as String;
          final userData = response['user'] as Map<String, dynamic>;
          
          // حفظ Token وبيانات المستخدم
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('jwt_token', token); // استخدام jwt_token بدلاً من auth_token
          await prefs.setString('auth_token', token); // للتوافق مع الكود القديم
          await prefs.setString('username', userData['username']);
          await prefs.setString('full_name', userData['full_name']);
          await prefs.setBool('is_admin', userData['is_admin'] ?? false);
          
          // تحويل لـ AppUserModel
          _currentUser = AppUserModel(
            id: userData['id'] ?? 0,
            username: userData['username'],
            role: userData['is_admin'] == true ? 'admin' : 'user',
            permissions: {}, // سيتم تحميل الصلاحيات لاحقاً
            employeeId: null,
            isActive: userData['is_active'] ?? true,
            lastLoginAt: DateTime.now(),
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            employee: null,
          );
          
          await prefs.setString(_storageKey, json.encode(_currentUser!.toStorageMap()));
          
          return true;
        }
      } catch (jwtError) {
        if (kDebugMode) {
          debugPrint('JWT login failed, trying old method: $jwtError');
        }
        
        // Fallback to old login method
        final user = await api.login(username, password);
        _currentUser = user;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_storageKey, json.encode(user.toStorageMap()));

        return true;
      }
      
      return false;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('AuthProvider.login error: $error');
      }
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    await prefs.remove('jwt_token');
    await prefs.remove('auth_token');
    await prefs.remove('username');
    await prefs.remove('full_name');
    await prefs.remove('is_admin');
    notifyListeners();
  }

  bool hasPermission(String permissionKey) {
    if (_currentUser == null) {
      return false;
    }

    if (_currentUser!.role == 'admin') {
      return true;
    }

    final permissions = _currentUser!.permissions;
    if (permissions == null) {
      return false;
    }

    final value = permissions[permissionKey];
    if (value is bool) {
      return value;
    }
    return false;
  }
}
