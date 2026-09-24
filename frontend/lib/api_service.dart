import 'dart:convert';

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueNotifier,
        debugPrint,
        defaultTargetPlatform,
        kDebugMode,
        kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models/app_user_model.dart';
import 'models/attendance_model.dart';
import 'models/employee_model.dart';
import 'models/payroll_model.dart';
import 'models/safe_box_model.dart';

const String _envApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

String _resolveApiBaseUrl() {
  String trimTrailingSlash(String value) {
    var v = value.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  if (_envApiBaseUrl.isNotEmpty) {
    final configured = trimTrailingSlash(_envApiBaseUrl);
    if (kIsWeb) {
      // Support relative base URLs for web deployments (e.g. /api behind nginx).
      // Docker builds often pass API_BASE_URL=/api.
      final isAbsolute =
          configured.startsWith('http://') || configured.startsWith('https://');
      if (isAbsolute) return configured;

      final origin = Uri.base.origin;
      if (configured.startsWith('/')) {
        return trimTrailingSlash('$origin$configured');
      }
      // Relative path without leading slash.
      return trimTrailingSlash('$origin/$configured');
    }

    return configured;
  }

  if (kIsWeb) {
    // Web builds may be deployed behind a reverse proxy where the backend is
    // reachable via the same origin (e.g. https://example.com/api).
    // In dev/LAN setups, the frontend is often served from :<random_port>
    // while the backend runs on :8001.
    final base = Uri.base;
    final rawHost = base.host;

    // On Flutter web dev servers the URL can sometimes be opened as
    // http://0.0.0.0:<port>/ which is not a routable destination host.
    // Also, some environments resolve `localhost` to IPv6 ::1 while the
    // backend binds IPv4 only; using 127.0.0.1 avoids that class of issues.
    final host =
        (rawHost.isEmpty || rawHost == '0.0.0.0' || rawHost == 'localhost')
        ? '127.0.0.1'
        : rawHost;

    final scheme = base.scheme.isNotEmpty ? base.scheme : 'http';
    final port = base.hasPort ? base.port : 0;

    final isDefaultHttp = scheme == 'http' && (port == 0 || port == 80);
    final isDefaultHttps = scheme == 'https' && (port == 0 || port == 443);
    final isDefaultPort = isDefaultHttp || isDefaultHttps;

    // If we're on a default port (80/443), assume production-style same-origin.
    if (isDefaultPort) {
      return '$scheme://$host/api';
    }

    // Otherwise, prefer the historical dev convention (backend on :8001).
    return '$scheme://$host:8001/api';
  }

  if (defaultTargetPlatform == TargetPlatform.android) {
    // عندما نعمل من داخل محاكي أندرويد نحتاج 10.0.2.2 للإشارة إلى جهاز التطوير
    return 'http://10.0.2.2:8001/api';
  }

  return 'http://127.0.0.1:8001/api';
}

class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;
  final Map<String, dynamic> details;

  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details = const {},
  });

  @override
  String toString() => message;
}

class ApiAuthException implements Exception {
  final String? code;
  final String message;

  ApiAuthException(this.message, {this.code});

  @override
  String toString() => message;
}

class ApiService {
  /// When set, the app should force a logout and return to login.
  /// Used to avoid infinite refresh loops when the server rejects refresh.
  static final ValueNotifier<ApiAuthException?> authInvalidation =
      ValueNotifier<ApiAuthException?>(null);

  final String _baseUrl;

  Future<String>? _refreshInFlight;

  ApiService({String? baseUrl}) : _baseUrl = baseUrl ?? _resolveApiBaseUrl();

  /// Exposes the resolved API base URL for use outside of [ApiService]
  /// (e.g. building temporary PDF upload URLs in utility functions).
  static String get resolvedBaseUrl => _resolveApiBaseUrl();

  int? _decodeJwtExpSeconds(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      final normalized = base64Url.normalize(parts[1]);
      final payload = json.decode(utf8.decode(base64Url.decode(normalized)));
      if (payload is Map<String, dynamic>) {
        final exp = payload['exp'];
        if (exp is int) return exp;
        if (exp is num) return exp.toInt();
      }
    } catch (_) {
      // ignore
    }
    return null;
  }

  bool _isJwtExpiringSoon(
    String token, {
    Duration leeway = const Duration(seconds: 60),
  }) {
    final exp = _decodeJwtExpSeconds(token);
    if (exp == null) return false;
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return exp <= (nowSeconds + leeway.inSeconds);
  }

  Future<String> _refreshAccessTokenFromStorage() async {
    // Coalesce concurrent refreshes to a single in-flight Future.
    final existing = _refreshInFlight;
    if (existing != null) return existing;

    final Future<String> future = (() async {
      final prefs = await SharedPreferences.getInstance();

      // Support legacy / prefixed keys that may exist in production (e.g. "flutter.refresh_token").
      final refreshToken =
          prefs.getString('refresh_token') ??
          prefs.getString('flutter.refresh_token') ??
          prefs.getString('refreshToken');

      if (refreshToken == null || refreshToken.isEmpty) {
        // No refresh token available -> force re-login.
        await prefs.remove('jwt_token');
        await prefs.remove('flutter.jwt_token');
        await prefs.remove('auth_token');
        await prefs.remove('flutter.auth_token');
        await prefs.remove('refresh_token');
        await prefs.remove('flutter.refresh_token');
        await prefs.remove('auth_current_user');
        final err = ApiAuthException(
          'لا توجد جلسة صالحة. الرجاء تسجيل الدخول مرة أخرى',
          code: 'authentication_required',
        );
        ApiService.authInvalidation.value = err;
        throw err;
      }

      try {
        final refreshed = await refreshAccessToken(refreshToken);
        final newAccess = refreshed['token']?.toString();
        final newRefresh = refreshed['refresh_token']?.toString();

        if (newAccess == null || newAccess.isEmpty) {
          throw ApiAuthException('فشل تحديث الجلسة');
        }

        // Persist under both canonical and prefixed keys to migrate older installs.
        await prefs.setString('jwt_token', newAccess);
        await prefs.setString('flutter.jwt_token', newAccess);
        if (newRefresh != null && newRefresh.isNotEmpty) {
          await prefs.setString('refresh_token', newRefresh);
          await prefs.setString('flutter.refresh_token', newRefresh);
        }
        return newAccess;
      } on ApiAuthException catch (e) {
        // Break infinite refresh loops: if refresh is rejected, clear stored session.
        final code = (e.code ?? '').toLowerCase();
        final fatal =
            code == 'session_expired' ||
            code == 'invalid_refresh' ||
            code == 'refresh_expired' ||
            code == 'authentication_required';

        if (fatal) {
          await prefs.remove('jwt_token');
          await prefs.remove('flutter.jwt_token');
          await prefs.remove('auth_token');
          await prefs.remove('flutter.auth_token');
          await prefs.remove('refresh_token');
          await prefs.remove('flutter.refresh_token');
          await prefs.remove('auth_current_user');
          ApiService.authInvalidation.value = e;
        }
        rethrow;
      }
    })();

    _refreshInFlight = future;
    try {
      return await future;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<http.Response> _authedGet(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    var token = await _requireAuthToken();
    var response = await http.get(
      uri,
      headers: {
        ..._jsonHeaders(token: token),
        ...?headers,
      },
    );
    if (response.statusCode == 401) {
      token = await _refreshAccessTokenFromStorage();
      response = await http.get(
        uri,
        headers: {
          ..._jsonHeaders(token: token),
          ...?headers,
        },
      );
    }
    return response;
  }

  Future<http.Response> _authedDelete(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    var token = await _requireAuthToken();
    var response = await http.delete(
      uri,
      headers: {
        ..._jsonHeaders(token: token),
        ...?headers,
      },
    );
    if (response.statusCode == 401) {
      token = await _refreshAccessTokenFromStorage();
      response = await http.delete(
        uri,
        headers: {
          ..._jsonHeaders(token: token),
          ...?headers,
        },
      );
    }
    return response;
  }

  Future<http.Response> _authedPost(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    var token = await _requireAuthToken();
    var response = await http.post(
      uri,
      headers: {
        ..._jsonHeaders(token: token),
        ...?headers,
      },
      body: body,
    );
    if (response.statusCode == 401) {
      token = await _refreshAccessTokenFromStorage();
      response = await http.post(
        uri,
        headers: {
          ..._jsonHeaders(token: token),
          ...?headers,
        },
        body: body,
      );
    }
    return response;
  }

  Future<http.Response> _authedPut(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    var token = await _requireAuthToken();
    var response = await http.put(
      uri,
      headers: {
        ..._jsonHeaders(token: token),
        ...?headers,
      },
      body: body,
    );
    if (response.statusCode == 401) {
      token = await _refreshAccessTokenFromStorage();
      response = await http.put(
        uri,
        headers: {
          ..._jsonHeaders(token: token),
          ...?headers,
        },
        body: body,
      );
    }
    return response;
  }

  Future<http.Response> _authedPatch(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    var token = await _requireAuthToken();
    var response = await http.patch(
      uri,
      headers: {
        ..._jsonHeaders(token: token),
        ...?headers,
      },
      body: body,
    );
    if (response.statusCode == 401) {
      token = await _refreshAccessTokenFromStorage();
      response = await http.patch(
        uri,
        headers: {
          ..._jsonHeaders(token: token),
          ...?headers,
        },
        body: body,
      );
    }
    return response;
  }

  Future<http.Response> _authedMultipartPost(
    Uri uri, {
    required Map<String, String> fields,
    required List<int> fileBytes,
    required String fileField,
    required String filename,
  }) async {
    Future<http.Response> sendWithToken(String token) async {
      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';
      request.fields.addAll(fields);
      request.files.add(
        http.MultipartFile.fromBytes(fileField, fileBytes, filename: filename),
      );
      final streamed = await request.send();
      return http.Response.fromStream(streamed);
    }

    var token = await _requireAuthToken();
    var response = await sendWithToken(token);
    if (response.statusCode == 401) {
      token = await _refreshAccessTokenFromStorage();
      response = await sendWithToken(token);
    }
    return response;
  }

  String _errorMessageFromResponse(http.Response response) {
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        final detailShort = decoded['detail_short']?.toString();
        final detail = decoded['detail']?.toString();
        final msg = decoded['message']?.toString();
        if (msg != null && msg.isNotEmpty) {
          final hasDetail = (detailShort != null && detailShort.isNotEmpty) ||
              (detail != null && detail.isNotEmpty);
          if (hasDetail) {
            return '$msg\n${detailShort ?? detail}';
          }
          return msg;
        }
        final err = decoded['error']?.toString();
        if (err != null && err.isNotEmpty) {
          final hasDetail = (detailShort != null && detailShort.isNotEmpty) ||
              (detail != null && detail.isNotEmpty);
          if (hasDetail) {
            return '$err\n${detailShort ?? detail}';
          }
          return err;
        }
        if (detailShort != null && detailShort.isNotEmpty) return detailShort;
        if (detail != null && detail.isNotEmpty) return detail;
      }
    } catch (_) {
      // ignore
    }
    try {
      return utf8.decode(response.bodyBytes);
    } catch (_) {
      return response.body;
    }
  }

  // ── Public HTTP helpers (for feature-specific service classes) ────────────
  // These delegate to the private authed methods while building the full URL
  // from the same _baseUrl, so callers only need to pass a path like '/inventory/balance'.

  Future<http.Response> authedGet(
    String path, {
    Map<String, String>? queryParams,
  }) {
    final uri = Uri.parse('$_baseUrl$path')
        .replace(queryParameters: queryParams?.isNotEmpty == true ? queryParams : null);
    return _authedGet(uri);
  }

  Future<http.Response> authedPost(String path, {Object? body}) =>
      _authedPost(Uri.parse('$_baseUrl$path'), body: body);

  Future<http.Response> authedPut(String path, {Object? body}) =>
      _authedPut(Uri.parse('$_baseUrl$path'), body: body);

  // Customer Methods
  Future<List<dynamic>> getCustomers() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/customers'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<List<Map<String, dynamic>>> getCustomersGoldBalances({
    bool ensureAccounts = false,
  }) async {
    final uri = Uri.parse('$_baseUrl/customers/gold-balances').replace(
      queryParameters: ensureAccounts ? {'ensure_accounts': '1'} : null,
    );
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      return const [];
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> addCustomer(
    Map<String, dynamic> customerData,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/customers'),
      body: json.encode(customerData),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<void> deleteCustomer(int id) async {
    final response = await _authedDelete(Uri.parse('$_baseUrl/customers/$id'));
    if (response.statusCode != 200) {
      // Changed from 204 to 200
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<void> updateCustomer(int id, Map<String, dynamic> customerData) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/customers/$id'),
      body: json.encode(customerData),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  // Supplier Methods
  Future<List<dynamic>> getSuppliers() async {
    final uri = Uri.parse('$_baseUrl/suppliers');
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> addSupplier(
    Map<String, dynamic> supplierData,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/suppliers'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(supplierData),
    );
    if (response.statusCode == 201) {
      return json.decode(response.body);
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<void> updateSupplier(int id, Map<String, dynamic> supplierData) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/suppliers/$id'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(supplierData),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> deleteSupplier(int id) async {
    final response = await _authedDelete(Uri.parse('$_baseUrl/suppliers/$id'));
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // ignore
    }
    return const {'result': 'success'};
  }

  // ── Supplier Settlement Adjustments (تسويات فروقات الموردين) ─────────────
  //
  // كل قرار محاسبي يتخذه الخادم: الاتجاه والمبالغ والحسابات والحدود. الواجهة
  // ترسل السبب والملاحظة فقط، وتعرض ما يعود. رموز الأخطاء تُمرَّر كما هي في
  // ApiException.code ليقرر مستدعيها كيف يعرضها.

  /// يرفع ApiException حاملًا رمز الخطأ من الخادم كما هو.
  Never _throwSettlementError(http.Response response) {
    Map<String, dynamic>? parsed;
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {
      parsed = null;
    }
    final code = parsed?['error']?.toString();
    throw ApiException(
      statusCode: response.statusCode,
      code: (code == null || code.isEmpty) ? 'http_error' : code,
      message: _errorMessageFromResponse(response),
      details: parsed ?? const {},
    );
  }

  Map<String, dynamic> _decodeSettlementResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _throwSettlementError(response);
    }
    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    return const {};
  }

  Future<List<dynamic>> getSupplierSettlementAdjustments(
    int supplierId, {
    String? status,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/suppliers/$supplierId/settlement-adjustments',
    ).replace(
      queryParameters: (status == null || status.isEmpty)
          ? null
          : {'status': status},
    );
    final body = _decodeSettlementResponse(await _authedGet(uri));
    final rows = body['adjustments'];
    return rows is List ? rows : const [];
  }

  /// ينشئ مسودة. السبب والملاحظة فقط — كل ما عداهما يقرره الخادم.
  Future<Map<String, dynamic>> createSupplierSettlementAdjustment(
    int supplierId, {
    required String reasonCode,
    String? note,
  }) async {
    final payload = <String, dynamic>{'reason_code': reasonCode};
    if (note != null && note.trim().isNotEmpty) {
      payload['note'] = note.trim();
    }
    final response = await _authedPost(
      Uri.parse('$_baseUrl/suppliers/$supplierId/settlement-adjustments'),
      body: json.encode(payload),
    );
    return _decodeSettlementResponse(response);
  }

  Future<Map<String, dynamic>> getSupplierSettlementAdjustment(int id) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/supplier-settlement-adjustments/$id'),
    );
    return _decodeSettlementResponse(response);
  }

  /// ما الذي سيقرره الترحيل الآن — دون أن يكتب شيئًا.
  ///
  /// الخادم هو من يحسب المكافئ بالعيار الرئيسي وحدود السياسة والمستهلك من
  /// الفترة وحالة الأهلية. الواجهة تعرضها كما وصلت ولا تشتق أيًّا منها.
  Future<Map<String, dynamic>> getSupplierSettlementPreview(int id) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/supplier-settlement-adjustments/$id/preview'),
    );
    return _decodeSettlementResponse(response);
  }

  /// يعيد قراءة الرصيد الحي داخل اللقطة. للمسودة فقط.
  Future<Map<String, dynamic>> recalculateSupplierSettlementAdjustment(
    int id,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/supplier-settlement-adjustments/$id/recalculate'),
      body: json.encode(const {}),
    );
    return _decodeSettlementResponse(response);
  }

  /// صلاحية الاعتماد الإداري للسبب OTHER تُشتق في الخادم من هوية المستخدم.
  Future<Map<String, dynamic>> approveSupplierSettlementAdjustment(
    int id,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/supplier-settlement-adjustments/$id/approve'),
      body: json.encode(const {}),
    );
    return _decodeSettlementResponse(response);
  }

  Future<Map<String, dynamic>> postSupplierSettlementAdjustment(int id) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/supplier-settlement-adjustments/$id/post'),
      body: json.encode(const {}),
    );
    return _decodeSettlementResponse(response);
  }

  /// يعكس تسوية مرحّلة بوثيقة جديدة. القيد الأصلي لا يُعدَّل.
  Future<Map<String, dynamic>> reverseSupplierSettlementAdjustment(
    int id, {
    required String reason,
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/supplier-settlement-adjustments/$id/reverse'),
      body: json.encode({'reason': reason}),
    );
    return _decodeSettlementResponse(response);
  }

  Future<Map<String, dynamic>> cancelSupplierSettlementAdjustment(
    int id, {
    required String reason,
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/supplier-settlement-adjustments/$id/cancel'),
      body: json.encode({'reason': reason}),
    );
    return _decodeSettlementResponse(response);
  }

  // Office Methods (مكاتب تسكير الذهب)
  Future<List<dynamic>> getOffices({bool? activeOnly}) async {
    final uri = Uri.parse('$_baseUrl/offices').replace(
      queryParameters: activeOnly == null ? null : {'active': '$activeOnly'},
    );
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> getOffice(int id) async {
    final uri = Uri.parse('$_baseUrl/offices/$id');
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> addOffice(
    Map<String, dynamic> officeData,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/offices'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(officeData),
    );
    if (response.statusCode == 201) {
      return json.decode(response.body);
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<void> updateOffice(int id, Map<String, dynamic> officeData) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/offices/$id'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(officeData),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<void> deleteOffice(int id) async {
    final response = await _authedDelete(Uri.parse('$_baseUrl/offices/$id'));
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<void> activateOffice(int id) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/offices/$id/activate'),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  // Branch Methods (فروع المعرض/المحل)
  Future<List<Map<String, dynamic>>> getBranches({
    bool activeOnly = false,
  }) async {
    final queryParams = <String, String>{};
    if (activeOnly) queryParams['active'] = 'true';

    final uri = Uri.parse(
      '$_baseUrl/branches',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is List) {
        return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      return [];
    } else {
      throw Exception('Failed to load branches');
    }
  }

  Future<Map<String, dynamic>> createBranch({
    required String name,
    String? branchCode,
    bool active = true,
  }) async {
    final payload = <String, dynamic>{
      'name': name,
      'active': active,
      if (branchCode != null && branchCode.trim().isNotEmpty)
        'branch_code': branchCode.trim(),
    };

    final response = await _authedPost(
      Uri.parse('$_baseUrl/branches'),
      body: json.encode(payload),
    );

    if (response.statusCode == 201) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);
    }

    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> updateBranch(
    int id, {
    String? name,
    String? branchCode,
    bool? active,
  }) async {
    final payload = <String, dynamic>{};
    if (name != null) payload['name'] = name;
    if (branchCode != null) payload['branch_code'] = branchCode;
    if (active != null) payload['active'] = active;

    final response = await _authedPut(
      Uri.parse('$_baseUrl/branches/$id'),
      body: json.encode(payload),
    );

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);
    }

    throw Exception(_errorMessageFromResponse(response));
  }

  Future<void> deactivateBranch(int id) async {
    final response = await _authedDelete(Uri.parse('$_baseUrl/branches/$id'));
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> activateBranch(int id) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/branches/$id/activate'),
    );
    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> getOfficeBalance(int id) async {
    final response = await http.get(Uri.parse('$_baseUrl/offices/$id/balance'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load office balance');
    }
  }

  Future<Map<String, dynamic>> getOfficesStatistics() async {
    final response = await http.get(Uri.parse('$_baseUrl/offices/statistics'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load offices statistics');
    }
  }

  // Office Reservations (حجوزات الذهب للمكاتب)
  Future<Map<String, dynamic>> getOfficeReservations({
    int? officeId,
    String? status,
    String? paymentStatus,
    String? dateFrom,
    String? dateTo,
    int? limit,
    int? page,
    int? perPage,
    String? orderBy,
    String? orderDirection,
  }) async {
    final queryParams = <String, String>{};
    if (officeId != null) queryParams['office_id'] = officeId.toString();
    if (status != null && status.isNotEmpty) queryParams['status'] = status;
    if (paymentStatus != null && paymentStatus.isNotEmpty) {
      queryParams['payment_status'] = paymentStatus;
    }
    if (limit != null) queryParams['limit'] = limit.toString();
    if (dateFrom != null && dateFrom.isNotEmpty) {
      queryParams['date_from'] = dateFrom;
    }
    if (dateTo != null && dateTo.isNotEmpty) {
      queryParams['date_to'] = dateTo;
    }
    if (page != null) queryParams['page'] = page.toString();
    if (perPage != null) queryParams['per_page'] = perPage.toString();
    if (orderBy != null && orderBy.isNotEmpty) {
      queryParams['order_by'] = orderBy;
    }
    if (orderDirection != null && orderDirection.isNotEmpty) {
      queryParams['order_direction'] = orderDirection;
    }

    final uri = Uri.parse(
      '$_baseUrl/office-reservations',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);

    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> getOfficeReservation(int id) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/office-reservations/$id'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> createOfficeReservation(
    Map<String, dynamic> reservationData,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/office-reservations'),
      body: json.encode(reservationData),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> settleOfficeReservation(
    int reservationId, {
    double? executionPricePerGram,
    DateTime? settlementDate,
    String? createdBy,
  }) async {
    final payload = <String, dynamic>{
      if (executionPricePerGram != null)
        'execution_price_per_gram': executionPricePerGram,
      if (settlementDate != null)
        'settlement_date': settlementDate.toIso8601String(),
      if (createdBy != null) 'created_by': createdBy,
    };

    final response = await _authedPost(
      Uri.parse('$_baseUrl/office-reservations/$reservationId/settle'),
      body: json.encode(payload),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> cancelOfficeReservation(
    int reservationId, {
    String? cancelledBy,
    String? reason,
  }) async {
    final payload = <String, dynamic>{
      if (cancelledBy != null) 'cancelled_by': cancelledBy,
      if (reason != null) 'reason': reason,
    };

    final response = await _authedPost(
      Uri.parse('$_baseUrl/office-reservations/$reservationId/cancel'),
      body: json.encode(payload),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  // Item Methods
  Future<List<dynamic>> getItems({
    bool? inStockOnly,
    int? categoryId,
    int? excludeCategoryId,
  }) async {
    Uri uri = Uri.parse('$_baseUrl/items');

    final queryParameters = <String, String>{};
    if (inStockOnly != null) {
      queryParameters['in_stock_only'] = inStockOnly ? 'true' : 'false';
    }
    if (categoryId != null) {
      queryParameters['category_id'] = categoryId.toString();
    }
    if (excludeCategoryId != null) {
      queryParameters['exclude_category_id'] = excludeCategoryId.toString();
    }
    if (queryParameters.isNotEmpty) {
      uri = uri.replace(queryParameters: queryParameters);
    }

    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load items');
    }
  }

  /// 🆕 البحث عن صنف بالباركود
  Future<Map<String, dynamic>> searchItemByBarcode(
    String barcode, {
    int? categoryId,
    int? excludeCategoryId,
  }) async {
    var uri = Uri.parse('$_baseUrl/items/search/barcode/$barcode');
    final queryParameters = <String, String>{};
    if (categoryId != null) {
      queryParameters['category_id'] = categoryId.toString();
    }
    if (excludeCategoryId != null) {
      queryParameters['exclude_category_id'] = excludeCategoryId.toString();
    }
    if (queryParameters.isNotEmpty) {
      uri = uri.replace(queryParameters: queryParameters);
    }

    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else if (response.statusCode == 404) {
      throw Exception('الصنف غير موجود');
    } else {
      throw Exception('Failed to search item by barcode');
    }
  }

  Future<Map<String, dynamic>> addItem(Map<String, dynamic> itemData) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/items'),
      body: json.encode(itemData),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// 🚀 إضافة سريعة لعدة أصناف
  Future<Map<String, dynamic>> quickAddItems(Map<String, dynamic> data) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/items/quick-add'),
      body: json.encode(data),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// ♻️ إعادة مزامنة حالة توافر الأصناف
  Future<Map<String, dynamic>> rebuildItemStockStatus() async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/items/rebuild-stock'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// 🔄 استنساخ صنف موجود
  Future<Map<String, dynamic>> cloneItem(
    int id,
    Map<String, dynamic> data,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/items/$id/clone'),
      body: json.encode(data),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> updateItem(
    int id,
    Map<String, dynamic> itemData,
  ) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/items/$id'),
      body: json.encode(itemData),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<void> deleteItem(int id) async {
    final response = await _authedDelete(Uri.parse('$_baseUrl/items/$id'));
    if (response.statusCode != 200) {
      // Changed from 204 to 200
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  // ============================================
  // 📁 Category Methods - تصنيفات الأصناف
  // ============================================

  /// جلب جميع التصنيفات
  Future<List<dynamic>> getCategories() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/categories'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load categories');
    }
  }

  /// جلب تصنيف واحد
  Future<Map<String, dynamic>> getCategory(int id) async {
    final response = await _authedGet(Uri.parse('$_baseUrl/categories/$id'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load category');
    }
  }

  /// إضافة تصنيف جديد
  Future<Map<String, dynamic>> addCategory(
    Map<String, dynamic> categoryData,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/categories'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(categoryData),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'Failed to add category');
    }
  }

  /// تعديل تصنيف
  Future<Map<String, dynamic>> updateCategory(
    int id,
    Map<String, dynamic> categoryData,
  ) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/categories/$id'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(categoryData),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'Failed to update category');
    }
  }

  /// حذف تصنيف
  Future<void> deleteCategory(int id) async {
    final response = await _authedDelete(Uri.parse('$_baseUrl/categories/$id'));
    if (response.statusCode != 200) {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'Failed to delete category');
    }
  }

  // ============================================
  // 🧾 Purchase Items - قائمة أصناف الشراء المبسطة
  // ============================================

  Future<List<dynamic>> getPurchaseItems() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/purchase-items'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load purchase items');
    }
  }

  Future<Map<String, dynamic>> createPurchaseItem({
    required String name,
    required String karat,
    String? description,
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/purchase-items'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({
        'name': name,
        'karat': karat,
        if (description != null) 'description': description,
      }),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'Failed to create purchase item');
    }
  }

  Future<void> deletePurchaseItem(int id) async {
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/purchase-items/$id'),
    );
    if (response.statusCode != 200) {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'Failed to delete purchase item');
    }
  }

  // Invoice Methods
  Future<Map<String, dynamic>> getInvoices({
    int page = 1,
    int perPage = 50,
    String sortBy = 'date',
    String sortOrder = 'desc',
    String search = '',
    String searchType = 'all',
    String status = 'all',
    String? invoiceType,
    List<String>? invoiceTypes,
    String? invoiceGroup,
    String? party,
    String? creator,
    int? employeeId,
    String? karat,
    String? goldType,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final Map<String, String> queryParameters = {
      'page': page.toString(),
      'per_page': perPage.toString(),
      'sort_by': sortBy,
      'sort_order': sortOrder,
      'search': search,
      'search_type': searchType,
      'status': status,
    };

    if (invoiceType != null && invoiceType != 'الكل') {
      queryParameters['invoice_type'] = invoiceType;
    }
    if (invoiceTypes != null && invoiceTypes.isNotEmpty) {
      queryParameters['invoice_types'] = invoiceTypes.join(',');
    }
    if (invoiceGroup != null && invoiceGroup != 'all') {
      queryParameters['invoice_group'] = invoiceGroup;
    }
    if (party != null && party.trim().isNotEmpty) {
      queryParameters['party'] = party.trim();
    }
    if (creator != null && creator.trim().isNotEmpty) {
      queryParameters['creator'] = creator.trim();
    }
    if (employeeId != null) {
      queryParameters['employee_id'] = employeeId.toString();
    }
    if (karat != null && karat.trim().isNotEmpty) {
      queryParameters['karat'] = karat.trim();
    }
    if (goldType != null && goldType != 'all') {
      queryParameters['gold_type'] = goldType;
    }
    if (dateFrom != null) {
      queryParameters['date_from'] = dateFrom.toIso8601String();
    }
    if (dateTo != null) {
      // Ensure the full end day is included: date pickers return midnight (00:00:00),
      // which would exclude every invoice created later that day.
      final endOfDay = DateTime(dateTo.year, dateTo.month, dateTo.day, 23, 59, 59, 999);
      queryParameters['date_to'] = endOfDay.toIso8601String();
    }

    final uri = Uri.parse(
      '$_baseUrl/invoices',
    ).replace(queryParameters: queryParameters);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load invoices (HTTP ${response.statusCode})',
      );
    }
  }

  /// Get invoice details by ID (includes items and payments)
  Future<Map<String, dynamic>> getInvoiceById(int invoiceId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/invoices/$invoiceId'),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load invoice details (status: ${response.statusCode})',
      );
    }
  }

  Future<Map<String, dynamic>> addInvoice(Map<String, dynamic> invoice) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/invoices'),
      body: json.encode(invoice),
    );

    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    Map<String, dynamic>? parsed;
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        parsed = decoded;
      }
    } catch (_) {
      parsed = null;
    }

    final errorCode = parsed?['error']?.toString().trim();
    if (errorCode == 'tax_policy_mismatch') {
      final lineIndex = parsed?['line_index'];
      final karat = parsed?['karat'];

      String expectedPart = '';
      if (parsed?.containsKey('expected_gold_tax') == true) {
        expectedPart =
            'المتوقع (ذهب): ${parsed?['expected_gold_tax']} | المرسل: ${parsed?['received_gold_tax']}';
      } else if (parsed?.containsKey('expected_wage_tax') == true) {
        expectedPart =
            'المتوقع (أجور): ${parsed?['expected_wage_tax']} | المرسل: ${parsed?['received_wage_tax']}';
      }

      final parts = <String>[
        'تعذر حفظ الفاتورة بسبب عدم توافق الضريبة مع سياسة النظام الحالية.',
        if (lineIndex != null || karat != null)
          'السطر: ${lineIndex ?? '-'} | العيار: ${karat ?? '-'}',
        if (expectedPart.isNotEmpty) expectedPart,
        'حدّث إعدادات الضريبة/الإعفاءات ثم أعد المحاولة.',
      ];

      throw ApiException(
        statusCode: response.statusCode,
        code: errorCode!,
        message: parts.join('\n'),
        details: parsed ?? const {},
      );
    }

    if (errorCode == 'supplier_account_missing' ||
        errorCode == 'customer_account_missing') {
      final msg = (parsed?['message']?.toString().trim().isNotEmpty == true)
          ? parsed!['message'].toString().trim()
          : _errorMessageFromResponse(response);
      final details = parsed?['details']?.toString().trim();

      throw ApiException(
        statusCode: response.statusCode,
        code: errorCode!,
        message: (details == null || details.isEmpty)
            ? msg
            : '$msg\n\nتفاصيل: $details',
        details: parsed ?? const {},
      );
    }

    throw ApiException(
      statusCode: response.statusCode,
      code: (errorCode == null || errorCode.isEmpty) ? 'http_error' : errorCode,
      message: _errorMessageFromResponse(response),
      details: parsed ?? const {},
    );
  }

  Future<void> deleteInvoice(int invoiceId) async {
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/invoices/$invoiceId'),
    );

    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// Edit an unposted (draft / pending-approval) invoice.
  /// The backend deletes the old invoice and re-creates it via add_invoice,
  /// preserving the same invoice_type_id (display number).
  Future<Map<String, dynamic>> updateUnpostedInvoice(
    int invoiceId,
    Map<String, dynamic> invoiceData,
  ) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/invoices/$invoiceId'),
      body: json.encode(invoiceData),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw Exception('Invalid server response');
    }

    Map<String, dynamic>? parsed;
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}

    final errorCode = parsed?['error']?.toString().trim();
    throw ApiException(
      statusCode: response.statusCode,
      code: (errorCode == null || errorCode.isEmpty) ? 'http_error' : errorCode,
      message: _errorMessageFromResponse(response),
      details: parsed ?? const {},
    );
  }

  /// تغيير موظف الفاتورة — للفواتير غير المرحّلة فقط
  Future<void> reassignInvoiceEmployee(int invoiceId, int newEmployeeId) async {
    final response = await _authedPatch(
      Uri.parse('$_baseUrl/invoices/$invoiceId/reassign-employee'),
      body: json.encode({'employee_id': newEmployeeId}),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// Add a payment to an existing invoice (used for settling remaining amounts)
  Future<Map<String, dynamic>> addInvoicePayment({
    required int invoiceId,
    required int paymentMethodId,
    required double amount,
    String? notes,
  }) async {
    final payload = <String, dynamic>{
      'payment_method_id': paymentMethodId,
      'amount': amount,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    };

    final response = await _authedPost(
      Uri.parse('$_baseUrl/invoices/$invoiceId/payments'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    throw ApiException(
      statusCode: response.statusCode,
      code: 'invoice_payment_failed',
      message: _errorMessageFromResponse(response),
      details: const {},
    );
  }

  // Gold Price Methods
  Future<Map<String, dynamic>> getGoldPrice() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/gold_price'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load gold price');
    }
  }

  /// Public gold price endpoint (no auth). Useful for the login screen.
  Future<Map<String, dynamic>> getGoldPricePublic() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/public/gold_price'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> updateGoldPrice({double? priceUsdPerOz}) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/gold_price/update'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: priceUsdPerOz != null
          ? json.encode({'price': priceUsdPerOz})
          : null,
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to update gold price');
    }
  }

  /// آخر 24 ساعة من أسعار الذهب — للـ sparkline
  Future<List<Map<String, dynamic>>> getGoldPrice24h() async {
    try {
      final response =
          await _authedGet(Uri.parse('$_baseUrl/gold_price/24h'));
      if (response.statusCode == 200) {
        final raw =
            (json.decode(utf8.decode(response.bodyBytes))['points'] as List?) ??
                [];
        return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('⚠️ Error getting gold price 24h: $e');
      return [];
    }
  }

  // ============================================
  // 💾 Backup / Restore
  // ============================================

  Future<List<int>> downloadSystemBackupZip() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/system/backup/download'),
      headers: const {'Accept': 'application/zip'},
    );

    if (response.statusCode == 200) {
      return response.bodyBytes;
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> restoreSystemBackupZip({
    required List<int> zipBytes,
    required String filename,
  }) async {
    final response = await _authedMultipartPost(
      Uri.parse('$_baseUrl/system/backup/restore'),
      fields: const {'confirm': 'RESTORE'},
      fileBytes: zipBytes,
      fileField: 'file',
      filename: filename,
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return {'status': 'success'};
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  // ============================================
  // 📥 Import: Sales Invoices (Excel)
  // ============================================

  Future<Map<String, dynamic>> importSalesInvoicesFromExcel({
    required List<int> fileBytes,
    required String filename,
    required bool apply,
    bool asCategories = false,
    String? sheetName,
  }) => importDocumentsFromExcel(
    fileBytes: fileBytes,
    filename: filename,
    apply: apply,
    endpointPath: '/devtools/import/sales-invoices',
    sheetName: sheetName,
    extraFields: {'as_categories': asCategories ? '1' : '0'},
  );

  /// Generic Excel import for any document type.
  /// [endpointPath] is the path relative to the API base, e.g.
  /// `'/devtools/import/sales-invoices'`.
  Future<Map<String, dynamic>> importDocumentsFromExcel({
    required List<int> fileBytes,
    required String filename,
    required bool apply,
    required String endpointPath,
    String? sheetName,
    Map<String, String>? extraFields,
  }) async {
    final fields = <String, String>{'apply': apply ? '1' : '0'};
    if (sheetName != null && sheetName.trim().isNotEmpty) {
      fields['sheet'] = sheetName.trim();
    }

    if (extraFields != null && extraFields.isNotEmpty) {
      fields.addAll(extraFields);
    }

    final response = await _authedMultipartPost(
      Uri.parse('$_baseUrl$endpointPath'),
      fields: fields,
      fileBytes: fileBytes,
      fileField: 'file',
      filename: filename,
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return {'success': true};
    }

    throw Exception(_errorMessageFromResponse(response));
  }

  // ============================================
  // ☁️ Server-side Google Drive (Service Account)
  // ============================================

  Future<Map<String, dynamic>> getDriveBackupStatus() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/system/backup/drive/status'),
    );
    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> uploadSystemBackupToDriveServerSide() async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/system/backup/drive/upload'),
      headers: const {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({}),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return {'status': 'success'};
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<List<Map<String, dynamic>>> listDriveBackupsServerSide({
    int pageSize = 20,
  }) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/system/backup/drive/list?page_size=$pageSize'),
    );
    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['files'] is List) {
        return List<Map<String, dynamic>>.from(decoded['files'] as List);
      }
      return <Map<String, dynamic>>[];
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<List<int>> downloadDriveBackupServerSide(String fileId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/system/backup/drive/download/$fileId'),
      headers: const {'Accept': 'application/octet-stream'},
    );
    if (response.statusCode == 200) {
      return response.bodyBytes;
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  // Gold Costing (Moving Average)
  Future<Map<String, dynamic>> getGoldCostingSnapshot() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/gold-costing'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load gold costing snapshot: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> calculateGoldCostingCogs(
    double weightGrams,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/gold-costing/cogs'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'weight_grams': weightGrams}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to calculate gold costing COGS: ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> recomputeGoldCosting({int? limit}) async {
    Uri uri = Uri.parse('$_baseUrl/gold-costing/recompute');
    if (limit != null) {
      uri = uri.replace(queryParameters: {'limit': limit.toString()});
    }

    final response = await _authedPost(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to recompute gold costing: ${response.body}');
    }
  }

  // Statement Methods
  Future<Map<String, dynamic>> getAccountStatement(int accountId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/accounts/$accountId/statement'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> getAccountStatementMerged(int accountId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/accounts/$accountId/statement_merged'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> getCustomerStatement(int customerId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/customers/$customerId/statement'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> getSupplierStatement(int supplierId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/suppliers/$supplierId/statement'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// Invoices of this supplier that still have room to evidence a gold
  /// settlement. Used to let the employee PICK an invoice when declaring what a
  /// gold payment is for — attribution is a choice, and a choice needs visible
  /// candidates.
  Future<List<Map<String, dynamic>>> getSupplierOpenGoldObligations(
    int supplierId,
  ) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/suppliers/$supplierId/open-gold-obligations'),
    );
    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      final list = (decoded is Map<String, dynamic>)
          ? (decoded['invoices'] as List<dynamic>? ?? const [])
          : const [];
      return list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> getSupplierLedger(
    int supplierId, {
    int page = 1,
    int perPage = 50,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final queryParameters = <String, String>{
      'page': page.toString(),
      'per_page': perPage.toString(),
    };

    if (dateFrom != null) {
      queryParameters['date_from'] = dateFrom.toIso8601String();
    }
    if (dateTo != null) {
      final endOfDay = DateTime(dateTo.year, dateTo.month, dateTo.day, 23, 59, 59, 999);
      queryParameters['date_to'] = endOfDay.toIso8601String();
    }

    final uri = Uri.parse(
      '$_baseUrl/suppliers/$supplierId/ledger',
    ).replace(queryParameters: queryParameters);
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load supplier ledger: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getSupplierBalance(int supplierId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/suppliers/$supplierId/balance'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load supplier balance: ${response.body}');
    }
  }

  // Account Methods
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async {
    try {
      final uri = Uri.parse('$_baseUrl/accounts').replace(
        queryParameters: skipBalances ? {'skip_balances': '1'} : null,
      );
      final response = await _authedGet(uri).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Connection timeout - تأكد من تشغيل Backend');
        },
      );

      if (response.statusCode == 200) {
        return json.decode(utf8.decode(response.bodyBytes));
      } else {
        throw Exception('Failed to load accounts: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('خطأ في الاتصال بالـ API: $e');
    }
  }

  Future<Map<String, dynamic>> getAccountById(int accountId) async {
    final response =
        await _authedGet(Uri.parse('$_baseUrl/accounts/$accountId')).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception('Connection timeout - تأكد من تشغيل Backend');
          },
        );

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      throw Exception('Invalid account payload');
    }

    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> getAccountsBalances() async {
    try {
      final response =
          await _authedGet(Uri.parse('$_baseUrl/accounts/balances')).timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw Exception('Connection timeout - تأكد من تشغيل Backend');
            },
          );

      if (response.statusCode == 200) {
        return json.decode(utf8.decode(response.bodyBytes));
      } else {
        throw Exception('Failed to load balances: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('خطأ في جلب الأرصدة: $e');
    }
  }

  /// Export chart of accounts as JSON (raw payload)
  Future<String> exportAccounts() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/accounts/export'));
    if (response.statusCode == 200) {
      return utf8.decode(response.bodyBytes);
    } else {
      throw Exception(
        'Failed to export accounts: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// Import chart of accounts from raw JSON string payload
  Future<Map<String, dynamic>> importAccountsFromJsonString(
    String jsonPayload,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/accounts/import'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: jsonPayload,
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    try {
      return json.decode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw Exception('Failed to import accounts: ${response.statusCode}');
    }
  }

  Future<Map<String, dynamic>> addAccount(
    Map<String, dynamic> accountData,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/accounts'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(accountData),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> getNextAccountNumber(String parentNumber) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/accounts/next-number/$parentNumber'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to get next account number: ${utf8.decode(response.bodyBytes)}',
      );
    }
  }

  Future<Map<String, dynamic>> validateAccountNumber({
    required String accountNumber,
    required String parentAccountNumber,
    int? excludeAccountId,
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/accounts/validate-number'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({
        'account_number': accountNumber,
        'parent_account_number': parentAccountNumber,
        if (excludeAccountId != null) 'exclude_account_id': excludeAccountId,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    // The backend returns useful error payloads even on 400
    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw Exception('Failed to validate account number');
  }

  Future<void> updateAccount(int id, Map<String, dynamic> accountData) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/accounts/$id'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(accountData),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> deleteAccount(int id, {bool? deleteParallel}) async {
    Uri uri = Uri.parse('$_baseUrl/accounts/$id');
    if (deleteParallel != null) {
      uri = uri.replace(queryParameters: {'delete_parallel': deleteParallel.toString()});
    }
    final response = await _authedDelete(uri);
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
    return json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  // Journal Entry Methods
  Future<List<dynamic>> getJournalEntries() async {
    final uri = Uri.parse(
      '$_baseUrl/journal_entries',
    ).replace(queryParameters: {'format': 'list'});
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load journal entries');
    }
  }

  Future<Map<String, dynamic>> getJournalEntriesPage({
    int page = 1,
    int perPage = 20,
    String sortBy = 'date',
    String sortOrder = 'desc',
    String search = '',
    String searchType = 'all',
    String status = 'all',
    String entryType = 'all',
    int? accountId,
    String? creator,
    DateTime? dateFrom,
    DateTime? dateTo,
    double? minCash,
    double? maxCash,
  }) async {
    final Map<String, String> queryParameters = {
      'page': page.toString(),
      'per_page': perPage.toString(),
      'sort_by': sortBy,
      'sort_order': sortOrder,
      'search': search,
      'search_type': searchType,
      'status': status,
      'entry_type': entryType,
    };

    if (accountId != null) {
      queryParameters['account_id'] = accountId.toString();
    }
    if (creator != null && creator.trim().isNotEmpty) {
      queryParameters['creator'] = creator.trim();
    }
    if (dateFrom != null) {
      queryParameters['date_from'] = dateFrom.toIso8601String();
    }
    if (dateTo != null) {
      final endOfDay = DateTime(dateTo.year, dateTo.month, dateTo.day, 23, 59, 59, 999);
      queryParameters['date_to'] = endOfDay.toIso8601String();
    }
    if (minCash != null) {
      queryParameters['min_cash'] = minCash.toString();
    }
    if (maxCash != null) {
      queryParameters['max_cash'] = maxCash.toString();
    }

    final uri = Uri.parse(
      '$_baseUrl/journal_entries',
    ).replace(queryParameters: queryParameters);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final body = utf8.decode(response.bodyBytes);
      String detail = 'Failed to load journal entries';
      try {
        final decoded = json.decode(body);
        if (decoded is Map) {
          detail = (decoded['message'] ?? decoded['error'] ?? detail).toString();
        }
      } catch (_) {}
      throw Exception('$detail (${response.statusCode})');
    }
  }

  Future<Map<String, dynamic>> getJournalEntryById(int id) async {
    final response = await _authedGet(Uri.parse('$_baseUrl/journal_entries/$id'));
    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return Map<String, dynamic>.from(decoded as Map);
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> addJournalEntry(
    Map<String, dynamic> entryData,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/journal_entries'),
      body: json.encode(entryData),
    );
    if (response.statusCode == 201) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw Exception('Invalid server response');
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<void> updateJournalEntry(
    int id,
    Map<String, dynamic> entryData,
  ) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/journal_entries/$id'),
      body: json.encode(entryData),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  // ===== نظام الحذف الآمن (Soft Delete) =====

  Future<Map<String, dynamic>> softDeleteJournalEntry(
    int id,
    String deletedBy,
    String reason,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/journal_entries/$id/soft_delete'),
      body: json.encode({'deleted_by': deletedBy, 'reason': reason}),
    );

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw Exception('Invalid server response');
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> restoreJournalEntry(
    int id,
    String restoredBy,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/journal_entries/$id/restore'),
      body: json.encode({'restored_by': restoredBy}),
    );

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw Exception('Invalid server response');
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<List<dynamic>> getDeletedJournalEntries() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/journal_entries/deleted'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load deleted journal entries');
    }
  }

  Future<void> deleteJournalEntry(int id) async {
    // الحذف النهائي (Hard Delete) - للاستخدام الإداري فقط
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/journal_entries/$id'),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  // General Ledger
  // General Ledger - Updated with filters
  Future<Map<String, dynamic>> getGeneralLedgerAll({
    int? accountId,
    String? startDate,
    String? endDate,
    bool showBalances = true,
    bool karatDetail = false,
    int page = 1,
    int perPage = 2000,
  }) async {
    final queryParams = <String, String>{};

    if (accountId != null) queryParams['account_id'] = accountId.toString();
    if (startDate != null) queryParams['start_date'] = startDate;
    if (endDate != null) queryParams['end_date'] = endDate;
    queryParams['show_balances'] = showBalances.toString();
    queryParams['karat_detail'] = karatDetail.toString();
    queryParams['page'] = page.toString();
    queryParams['per_page'] = perPage.toString();

    final uri = Uri.parse(
      '$_baseUrl/general_ledger_all',
    ).replace(queryParameters: queryParams);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load general ledger: ${response.statusCode} ${_errorMessageFromResponse(response)}',
      );
    }
  }

  // Account Ledger - New endpoint
  Future<Map<String, dynamic>> getAccountLedger(
    int accountId, {
    String? startDate,
    String? endDate,
    bool karatDetail = true,
  }) async {
    final queryParams = <String, String>{};

    if (startDate != null) queryParams['start_date'] = startDate;
    if (endDate != null) queryParams['end_date'] = endDate;
    queryParams['karat_detail'] = karatDetail.toString();

    final uri = Uri.parse(
      '$_baseUrl/account_ledger/$accountId',
    ).replace(queryParameters: queryParams);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load account ledger: ${response.statusCode} ${utf8.decode(response.bodyBytes)}',
      );
    }
  }

  // Trial Balance
  Future<Map<String, dynamic>> getTrialBalance({
    String? startDate,
    String? endDate,
    bool karatDetail = false,
  }) async {
    // Build query parameters
    final queryParams = <String, String>{};
    if (startDate != null) queryParams['start_date'] = startDate;
    if (endDate != null) queryParams['end_date'] = endDate;
    if (karatDetail) queryParams['karat_detail'] = 'true';

    final uri = Uri.parse(
      '$_baseUrl/trial_balance',
    ).replace(queryParameters: queryParams);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load trial balance');
    }
  }

  Future<Map<String, dynamic>> getSalesOverviewReport({
    DateTime? startDate,
    DateTime? endDate,
    String groupBy = 'day',
    bool includeUnposted = false,
    String? goldType,
  }) async {
    final queryParams = <String, String>{'group_by': groupBy};

    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }

    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }

    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }

    if (goldType != null && goldType.isNotEmpty) {
      queryParams['gold_type'] = goldType;
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/sales_overview',
    ).replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load sales overview report: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getAnalyticsSummary({
    required String groupBy,
    DateTime? startDate,
    DateTime? endDate,
    bool postedOnly = true,
  }) async {
    final queryParams = <String, String>{
      'group_by': groupBy,
      'posted_only': postedOnly ? 'true' : 'false',
    };

    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }

    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }

    final uri = Uri.parse(
      '$_baseUrl/analytics/summary',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } else {
      throw Exception('Failed to load analytics summary: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getAdminDashboard() async {
    final uri = Uri.parse('$_baseUrl/dashboard/admin');
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } else {
      throw Exception('Failed to load admin dashboard: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getSystemAlerts({
    String? severity,
    bool? reviewed,
  }) async {
    final queryParams = <String, String>{};
    if (severity != null && severity.trim().isNotEmpty) {
      queryParams['severity'] = severity.trim().toLowerCase();
    }
    if (reviewed != null) {
      queryParams['reviewed'] = reviewed ? 'true' : 'false';
    }

    final uri = Uri.parse(
      '$_baseUrl/system-alerts',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } else {
      throw Exception('Failed to load system alerts: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> reviewSystemAlert(int alertId) async {
    final uri = Uri.parse('$_baseUrl/system-alerts/$alertId/review');
    final response = await _authedPut(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } else {
      throw Exception('Failed to review alert: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getIncomeStatementReport({
    DateTime? startDate,
    DateTime? endDate,
    String groupBy = 'month',
    bool includeUnposted = false,
  }) async {
    final queryParams = <String, String>{'group_by': groupBy};

    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }

    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }

    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/income_statement',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return {'summary': {}, 'series': []};
    } else {
      throw Exception(
        'Failed to load income statement report: ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> getGramProfitReport({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final uri = Uri.parse('$_baseUrl/reports/gram_profit').replace(
      queryParameters: {
        'start_date': startDate.toIso8601String().split('T').first,
        'end_date': endDate.toIso8601String().split('T').first,
      },
    );
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return {};
    } else {
      throw Exception('Failed to load gram profit report: ${response.body}');
    }
  }


  Future<Map<String, dynamic>> getSalesByCustomerReport({
    DateTime? startDate,
    DateTime? endDate,
    bool includeUnposted = false,
    int limit = 25,
    String orderBy = 'net_value',
    bool ascending = false,
  }) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'order_by': orderBy,
      'order_direction': ascending ? 'asc' : 'desc',
    };

    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }

    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }

    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/sales_by_customer',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load sales by customer report: ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> getSalesByKaratReport({
    DateTime? startDate,
    DateTime? endDate,
    bool includeUnposted = false,
  }) async {
    final queryParams = <String, String>{};
    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }
    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }
    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }
    final uri = Uri.parse(
      '$_baseUrl/reports/sales_by_karat',
    ).replace(queryParameters: queryParams);
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load sales by karat report: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getSalesByItemReport({
    DateTime? startDate,
    DateTime? endDate,
    bool includeUnposted = false,
    int limit = 25,
    String orderBy = 'net_value',
    bool ascending = false,
  }) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'order_by': orderBy,
      'order_direction': ascending ? 'asc' : 'desc',
    };

    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }

    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }

    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/sales_by_item',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load sales by item report: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getInventoryStatusReport({
    List<num>? karats,
    bool includeZeroStock = false,
    bool includeUnposted = false,
    int? limit,
    String orderBy = 'market_value',
    bool ascending = false,
    int slowDays = 45,
  }) async {
    final queryParams = <String, String>{
      'order_by': orderBy,
      'order_direction': ascending ? 'asc' : 'desc',
      'slow_days': slowDays.toString(),
    };

    if (limit != null) {
      queryParams['limit'] = limit.toString();
    }

    if (karats != null && karats.isNotEmpty) {
      queryParams['karats'] = karats.map((k) => k.toString()).join(',');
    }

    if (includeZeroStock) {
      queryParams['include_zero_stock'] = 'true';
    }

    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/inventory_status',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load inventory status report: ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> getLowStockReport({
    bool includeZeroStock = false,
    bool includeUnposted = false,
    List<num>? karats,
    int? officeId,
    double? thresholdQuantity,
    double? thresholdWeight,
    int limit = 150,
    String sortBy = 'severity',
    bool ascending = false,
  }) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'sort_by': sortBy,
      'sort_direction': ascending ? 'asc' : 'desc',
    };

    if (includeZeroStock) {
      queryParams['include_zero_stock'] = 'true';
    }

    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }

    if (karats != null && karats.isNotEmpty) {
      queryParams['karats'] = karats.map((k) => k.toString()).join(',');
    }

    if (officeId != null) {
      queryParams['office_id'] = officeId.toString();
    }

    if (thresholdQuantity != null) {
      queryParams['threshold_quantity'] = thresholdQuantity.toString();
    }

    if (thresholdWeight != null) {
      queryParams['threshold_weight'] = thresholdWeight.toString();
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/low_stock',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load low stock report: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getInventoryMovementReport({
    DateTime? startDate,
    DateTime? endDate,
    String groupInterval = 'day',
    bool includeUnposted = false,
    bool includeReturns = true,
    List<num>? karats,
    List<int>? officeIds,
    int movementsLimit = 200,
  }) async {
    final queryParams = <String, String>{
      'group_interval': groupInterval,
      'movements_limit': movementsLimit.toString(),
    };

    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }

    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }

    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }

    if (!includeReturns) {
      queryParams['include_returns'] = 'false';
    }

    if (karats != null && karats.isNotEmpty) {
      queryParams['karats'] = karats.map((k) => k.toString()).join(',');
    }

    if (officeIds != null && officeIds.isNotEmpty) {
      queryParams['office_ids'] = officeIds
          .map((id) => id.toString())
          .join(',');
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/inventory_movement',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load inventory movement report: ${response.body}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Category Weight Tracking (جرد الأوزان حسب التصنيف)
  // ---------------------------------------------------------------------------
  /// Endpoint: GET /category-weight/balances?safe_box_id=&category_id=
  Future<List<Map<String, dynamic>>> getCategoryWeightBalances({
    int? safeBoxId,
    int? categoryId,
    int? karat,
    bool groupByKarat = false,
    String? goldType,
  }) async {
    final queryParams = <String, String>{};
    if (safeBoxId != null) queryParams['safe_box_id'] = safeBoxId.toString();
    if (categoryId != null) queryParams['category_id'] = categoryId.toString();
    if (karat != null) queryParams['karat'] = karat.toString();
    if (groupByKarat) queryParams['group_by_karat'] = 'true';
    if (goldType != null && goldType.trim().isNotEmpty) {
      queryParams['gold_type'] = goldType.trim();
    }

    final uri = Uri.parse(
      '$_baseUrl/category-weight/balances',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);

    final response = await _authedGet(uri);
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }

    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
    }

    return const [];
  }

  /// Endpoint: GET /category-weight/movements?safe_box_id=&category_id=&invoice_id=&limit=
  Future<List<Map<String, dynamic>>> getCategoryWeightMovements({
    int? safeBoxId,
    int? categoryId,
    int? invoiceId,
    int? karat,
    String? goldType,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 200,
  }) async {
    final queryParams = <String, String>{'limit': limit.toString()};
    if (safeBoxId != null) queryParams['safe_box_id'] = safeBoxId.toString();
    if (categoryId != null) queryParams['category_id'] = categoryId.toString();
    if (invoiceId != null) queryParams['invoice_id'] = invoiceId.toString();
    if (karat != null) queryParams['karat'] = karat.toString();
    if (goldType != null && goldType.trim().isNotEmpty) {
      queryParams['gold_type'] = goldType.trim();
    }
    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }
    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }

    final uri = Uri.parse(
      '$_baseUrl/category-weight/movements',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }

    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
    }

    return const [];
  }

  /// إنشاء حركة تعديل يدوي لأوزان التصنيفات (رصيد افتتاحي/تصحيح)
  /// Endpoint: POST /category-weight/adjustments
  Future<Map<String, dynamic>> createCategoryWeightAdjustments({
    required String goldType,
    required List<Map<String, dynamic>> lines,
    String? createdBy,
    String? note,
    DateTime? date,
  }) async {
    final payload = <String, dynamic>{'gold_type': goldType, 'lines': lines};

    if (createdBy != null && createdBy.trim().isNotEmpty) {
      payload['created_by'] = createdBy.trim();
    }
    if (note != null && note.trim().isNotEmpty) {
      payload['note'] = note.trim();
    }
    if (date != null) {
      payload['date'] = date.toIso8601String().split('T').first;
    }

    final response = await _authedPost(
      Uri.parse('$_baseUrl/category-weight/adjustments'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> getSalesVsPurchasesTrend({
    DateTime? startDate,
    DateTime? endDate,
    String groupInterval = 'day',
    bool includeUnposted = false,
    String? goldType,
  }) async {
    final queryParams = <String, String>{'group_interval': groupInterval};

    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }
    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }
    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }
    if (goldType != null && goldType.isNotEmpty) {
      queryParams['gold_type'] = goldType;
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/sales_vs_purchases_trend',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load sales vs purchases trend: ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> getCustomerBalancesAgingReport({
    DateTime? cutoffDate,
    bool includeZeroBalances = false,
    bool includeUnposted = false,
    int? customerGroupId,
    int topLimit = 5,
  }) async {
    final queryParams = <String, String>{'top_limit': topLimit.toString()};

    if (cutoffDate != null) {
      queryParams['cutoff_date'] = cutoffDate
          .toIso8601String()
          .split('T')
          .first;
    }

    if (includeZeroBalances) {
      queryParams['include_zero_balances'] = 'true';
    }

    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }

    if (customerGroupId != null) {
      queryParams['customer_group_id'] = customerGroupId.toString();
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/customer_balances_aging',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load customer balances aging report: ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> getGoldPriceHistoryReport({
    DateTime? startDate,
    DateTime? endDate,
    String groupInterval = 'day',
    int limit = 180,
  }) async {
    final queryParams = <String, String>{
      'group_interval': groupInterval,
      'limit': limit.toString(),
    };

    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }

    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/gold_price_history',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load gold price history report: ${response.body}',
      );
    }
  }

  Future<Map<String, dynamic>> getGoldPositionReport({
    bool includeZero = false,
    double? minVariance,
    List<String>? safeTypes,
    List<int>? officeIds,
    List<num>? karats,
  }) async {
    final queryParams = <String, String>{};

    if (includeZero) {
      queryParams['include_zero'] = 'true';
    }

    if (minVariance != null) {
      queryParams['min_variance'] = minVariance.toString();
    }

    if (safeTypes != null && safeTypes.isNotEmpty) {
      queryParams['safe_types'] = safeTypes.join(',');
    }

    if (officeIds != null && officeIds.isNotEmpty) {
      queryParams['office_ids'] = officeIds
          .map((id) => id.toString())
          .join(',');
    }

    if (karats != null && karats.isNotEmpty) {
      queryParams['karats'] = karats.map((k) => k.toString()).join(',');
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/gold_position',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load gold position report: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getEmployeeScrapLedgerReport({
    DateTime? startDate,
    DateTime? endDate,
    int? branchId,
    bool includeUnposted = true,
    bool includeUnassigned = true,
  }) async {
    final queryParams = <String, String>{};

    if (startDate != null) {
      queryParams['start_date'] = startDate.toIso8601String().split('T').first;
    }

    if (endDate != null) {
      queryParams['end_date'] = endDate.toIso8601String().split('T').first;
    }

    if (branchId != null) {
      queryParams['branch_id'] = branchId.toString();
    }

    if (includeUnposted) {
      queryParams['include_unposted'] = 'true';
    }

    if (!includeUnassigned) {
      queryParams['include_unassigned'] = 'false';
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/employee_scrap_ledger',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);

    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to load employee scrap ledger report: ${response.body}',
      );
    }
  }

  // Hybrid System - Customer & Supplier Code Methods

  /// Get next available customer code (C-000001, C-000002, ...)
  Future<Map<String, dynamic>> getNextCustomerCode() async {
    final response = await http.get(Uri.parse('$_baseUrl/customers/next-code'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to get next customer code');
    }
  }

  /// Get next available supplier code (S-000001, S-000002, ...)
  Future<Map<String, dynamic>> getNextSupplierCode() async {
    final response = await http.get(Uri.parse('$_baseUrl/suppliers/next-code'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to get next supplier code');
    }
  }

  // Settings Methods
  Future<Map<String, dynamic>> getSettings() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/settings').replace(
        queryParameters: {'_ts': '${DateTime.now().millisecondsSinceEpoch}'},
      ),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// نقل حركات الكسر التاريخية من صندوق الكسر لخزائن الموظفين الصحيحة
  Future<Map<String, dynamic>> migrateScrapGoldToEmployeeSafes() async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/admin/migrate-scrap-gold-to-employee-safes'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  /// مزامنة القيود اليتيمة — ترحيل قيود مرتبطة بفواتير مرحّلة لكنها غير مرحّلة
  Future<Map<String, dynamic>> syncOrphanJournalEntries() async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/admin/sync-orphan-entries'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    }
    throw Exception(_errorMessageFromResponse(response));
  }

  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> settingsData) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/settings'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(settingsData),
    );
    if (response.statusCode != 200) {
      throw Exception(_errorMessageFromResponse(response));
    }
    return json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// إعدادات التسكير الوزني (auto-close)
  Future<Map<String, dynamic>> getWeightClosingSettings() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/weight-closing/settings'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> updateWeightClosingSettings(
    Map<String, dynamic> payload,
  ) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/weight-closing/settings'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// قائمة بروفايلات التسكير الوزني
  Future<List<Map<String, dynamic>>> getWeightClosingProfiles() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/weight-closing/profiles'),
    );

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      final profiles = decoded is Map<String, dynamic>
          ? (decoded['profiles'] as List<dynamic>? ?? const [])
          : const <dynamic>[];

      return profiles
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }

    throw Exception(_errorMessageFromResponse(response));
  }

  /// تنفيذ بروفايل التسكير الوزني
  Future<Map<String, dynamic>> executeWeightClosingProfile(
    Map<String, dynamic> payload,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/weight-closing/execute-profile'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    throw Exception(_errorMessageFromResponse(response));
  }

  // System Methods

  /// إعادة تهيئة النظام مع دعم خيارات متعددة
  Future<Map<String, dynamic>> resetSystem({
    String? resetType,
    String? confirmToken,
  }) async {
    final body = <String, dynamic>{};
    if (resetType != null) {
      body['reset_type'] = resetType;
    }
    if (confirmToken != null && confirmToken.trim().isNotEmpty) {
      body['confirm'] = confirmToken.trim();
    }

    final response = await _authedPost(
      Uri.parse('$_baseUrl/system/reset'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(body),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// الحصول على معلومات النظام قبل إعادة التهيئة
  Future<Map<String, dynamic>> getSystemResetInfo() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/system/reset/info'));

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// تصفير أو إعادة بناء متوسط التكلفة المتحرك
  Future<Map<String, dynamic>> resetGoldCosting({
    required String mode,
    int? limit,
  }) async {
    final Map<String, dynamic> payload = {'mode': mode};
    if (limit != null) {
      payload['limit'] = limit;
    }

    final response = await _authedPost(
      Uri.parse('$_baseUrl/gold-costing/reset'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  // Return Invoice Methods (New)

  /// Get returnable invoices with optional filters
  Future<Map<String, dynamic>> getReturnableInvoices({
    String? invoiceType,
    int? customerId,
    int? supplierId,
  }) async {
    final Map<String, String> queryParams = {};
    if (invoiceType != null) queryParams['invoice_type'] = invoiceType;
    if (customerId != null) queryParams['customer_id'] = customerId.toString();
    if (supplierId != null) queryParams['supplier_id'] = supplierId.toString();

    final uri = Uri.parse(
      '$_baseUrl/invoices/returnable',
    ).replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);

    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// Check if an invoice can be returned
  Future<Map<String, dynamic>> checkCanReturn(int invoiceId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/invoices/$invoiceId/can-return'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  /// Get all returns for a specific invoice
  Future<Map<String, dynamic>> getInvoiceReturns(int invoiceId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/invoices/$invoiceId/returns'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  // ============================================================================
  // Vouchers Methods (سندات القبض والصرف)
  // ============================================================================

  /// Get all vouchers with optional filters and pagination
  Future<Map<String, dynamic>> getVouchers({
    int page = 1,
    int perPage = 20,
    String? type, // receipt, payment, adjustment
    String? status, // active, cancelled
    String? dateFrom,
    String? dateTo,
    String? search,
    String? searchType,
    String? creator,
    String? party,
    String? sortBy,
    String? sortOrder,
    String? referenceType, // invoice, voucher, journal_entry, manual
    int? referenceId,
  }) async {
    final Map<String, String> queryParameters = {
      'page': page.toString(),
      'per_page': perPage.toString(),
    };

    if (type != null && type != 'all') {
      queryParameters['type'] = type;
    }
    if (status != null && status != 'all') {
      queryParameters['status'] = status;
    }
    if (dateFrom != null) {
      queryParameters['date_from'] = dateFrom;
    }
    if (dateTo != null) {
      queryParameters['date_to'] = dateTo;
    }
    if (search != null && search.isNotEmpty) {
      queryParameters['search'] = search;
    }
    if (searchType != null && searchType.isNotEmpty && searchType != 'all') {
      queryParameters['search_type'] = searchType;
    }
    if (creator != null && creator.isNotEmpty) {
      queryParameters['creator'] = creator;
    }
    if (party != null && party.isNotEmpty) {
      queryParameters['party'] = party;
    }
    if (sortBy != null && sortBy.isNotEmpty) {
      queryParameters['sort_by'] = sortBy;
    }
    if (sortOrder != null && sortOrder.isNotEmpty) {
      queryParameters['sort_order'] = sortOrder;
    }

    if (referenceType != null && referenceType.isNotEmpty) {
      queryParameters['reference_type'] = referenceType;
    }
    if (referenceId != null) {
      queryParameters['reference_id'] = referenceId.toString();
    }

    final uri = Uri.parse(
      '$_baseUrl/vouchers',
    ).replace(queryParameters: queryParameters);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load vouchers');
    }
  }

  Future<List<Map<String, dynamic>>> getVouchersForInvoice(
    int invoiceId, {
    int page = 1,
    int perPage = 50,
  }) async {
    final result = await getVouchers(
      page: page,
      perPage: perPage,
      referenceType: 'invoice',
      referenceId: invoiceId,
    );
    final raw = result['vouchers'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  /// Get single voucher by ID
  Future<Map<String, dynamic>> getVoucher(int voucherId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/vouchers/$voucherId'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load voucher');
    }
  }

  /// Create new voucher
  Future<Map<String, dynamic>> createVoucher(
    Map<String, dynamic> voucherData,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/vouchers'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(voucherData),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to create voucher: ${response.body}');
    }
  }

  /// Approve a pending voucher (creates journal entry on backend)
  Future<Map<String, dynamic>> approveVoucher(
    int voucherId, {
    String? approvedBy,
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/vouchers/$voucherId/approve'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'approved_by': approvedBy ?? 'user'}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to approve voucher: ${response.body}');
    }
  }

  // ---------------------------------------------------------------------------
  // Shift Closing (Gold)
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> getShiftClosingGoldSummary({
    String? from,
    String? to,
  }) async {
    final queryParams = <String, String>{};
    if (from != null && from.trim().isNotEmpty) queryParams['from'] = from;
    if (to != null && to.trim().isNotEmpty) queryParams['to'] = to;

    final uri = Uri.parse(
      '$_baseUrl/shift-closing/summary-gold',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);

    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception('Failed to load gold shift summary: ${response.body}');
  }

  /// Update existing voucher
  Future<Map<String, dynamic>> updateVoucher(
    int voucherId,
    Map<String, dynamic> voucherData,
  ) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/vouchers/$voucherId'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(voucherData),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to update voucher: ${response.body}');
    }
  }

  /// Delete voucher
  Future<void> deleteVoucher(int voucherId) async {
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/vouchers/$voucherId'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to delete voucher');
    }
  }

  /// Cancel voucher
  Future<Map<String, dynamic>> cancelVoucher(
    int voucherId,
    String reason,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/vouchers/$voucherId/cancel'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'reason': reason}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to cancel voucher: ${response.body}');
    }
  }

  /// Get vouchers statistics
  Future<Map<String, dynamic>> getVouchersStats() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/vouchers/stats'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load vouchers stats');
    }
  }

  // ========================================
  // 💳 Payment Methods APIs
  // ========================================

  /// جلب جميع وسائل الدفع
  Future<List<dynamic>> getPaymentMethods() async {
    final response = await http.get(Uri.parse('$_baseUrl/payment-methods'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load payment methods');
    }
  }

  /// جلب وسائل الدفع النشطة فقط
  Future<List<dynamic>> getActivePaymentMethods() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/payment-methods/active'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load active payment methods');
    }
  }

  /// تصحيح وسيلة الدفع لدفعة فاتورة (قبل التسوية فقط).
  /// correctionAmount اختياري: إن كان أقل من مبلغ الدفعة الكامل، يُقسَّم
  /// الصف الأصلي بين الوسيلتين بدل تصحيحه بالكامل (انظر is_partial في الرد).
  Future<Map<String, dynamic>> correctInvoicePaymentMethod({
    required int invoiceId,
    required int paymentId,
    required int newPaymentMethodId,
    required String reason,
    double? correctionAmount,
  }) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/invoices/$invoiceId/payments/$paymentId/correct-method'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: json.encode({
        'new_payment_method_id': newPaymentMethodId,
        'reason': reason,
        if (correctionAmount != null) 'correction_amount': correctionAmount,
      }),
    );
    final data = json.decode(utf8.decode(response.bodyBytes));
    if (response.statusCode == 200) return data as Map<String, dynamic>;
    throw Exception(
      (data is Map ? data['message'] ?? data['error'] : null) ??
          'Failed to correct payment method',
    );
  }

  /// تقسيم دفعة فاتورة واحدة بين 2+ وسائل دفع دفعة واحدة (atomic) — بديل عن
  /// استدعاء correctInvoicePaymentMethod عدة مرات. كل عنصر في splits:
  /// `{'payment_method_id': int, 'amount': double}`.
  Future<Map<String, dynamic>> splitInvoicePaymentMethod({
    required int invoiceId,
    required int paymentId,
    required String reason,
    required List<Map<String, dynamic>> splits,
  }) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/invoices/$invoiceId/payments/$paymentId/correct-method'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: json.encode({
        'reason': reason,
        'splits': splits,
      }),
    );
    final data = json.decode(utf8.decode(response.bodyBytes));
    if (response.statusCode == 200) return data as Map<String, dynamic>;
    throw Exception(
      (data is Map ? data['message'] ?? data['error'] : null) ??
          'Failed to split payment method',
    );
  }

  /// جلب الحسابات البنكية المتاحة
  Future<List<dynamic>> getBankAccounts() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/payment-methods/bank-accounts'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load bank accounts');
    }
  }

  /// جلب أنواع الفواتير المتاحة لوسائل الدفع
  Future<Map<String, dynamic>> getPaymentInvoiceTypeOptions() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/payment-methods/invoice-types'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load payment invoice types: ${response.body}');
    }
  }

  /// إضافة وسيلة دفع جديدة
  Future<Map<String, dynamic>> createPaymentMethod({
    required String paymentType,
    required String name,
    int? parentAccountId, // 🆕 أصبح اختياري للتوافق
    int? defaultSafeBoxId, // 🆕 الخزينة الافتراضية
    double commissionRate = 0.0,
    double commissionFixedAmount = 0.0,
    String commissionTiming = 'invoice',
    int settlementDays = 0, // 🆕
    bool autoSettlementEnabled = false,
    String settlementScheduleType = 'days',
    int? settlementWeekday,
    int? settlementBankSafeBoxId,
    int? feeExpenseAccountId,
    double minSettlementAmount = 0.0,
    String settlementMode = 'bulk',
    int depositDelayDays = 0,
    String depositScheduleType = 'days',
    int? depositWeekday,
    bool isActive = true,
    List<String>? applicableInvoiceTypes,
  }) async {
    final payload = <String, dynamic>{
      'payment_type': paymentType,
      'name': name,
      'commission_rate': commissionRate,
      'commission_fixed_amount': commissionFixedAmount,
      'commission_timing': commissionTiming,
      'settlement_days': settlementDays,
      'auto_settlement_enabled': autoSettlementEnabled,
      'settlement_schedule_type': settlementScheduleType,
      'settlement_weekday': settlementWeekday,
      'settlement_bank_safe_box_id': settlementBankSafeBoxId,
      'min_settlement_amount': minSettlementAmount,
      'settlement_mode': settlementMode,
      'deposit_delay_days': depositDelayDays,
      'deposit_schedule_type': depositScheduleType,
      'deposit_weekday': depositWeekday,
      'is_active': isActive,
    };
    if (defaultSafeBoxId != null) {
      payload['default_safe_box_id'] = defaultSafeBoxId;
    } else if (parentAccountId != null) {
      // للتوافق مع الكود القديم
      payload['parent_account_id'] = parentAccountId;
    }

    if (applicableInvoiceTypes != null && applicableInvoiceTypes.isNotEmpty) {
      payload['applicable_invoice_types'] = applicableInvoiceTypes;
    }

    // إرسال حساب مصروف العمولة (اختياري)
    payload['fee_expense_account_id'] = feeExpenseAccountId;

    final response = await http.post(
      Uri.parse('$_baseUrl/payment-methods'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );
    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to create payment method: ${response.body}');
    }
  }

  /// تعديل وسيلة دفع
  Future<Map<String, dynamic>> updatePaymentMethod(
    int id, {
    required String paymentType,
    required String name,
    required double commissionRate,
    double? commissionFixedAmount,
    String commissionTiming = 'invoice',
    int settlementDays = 0,
    bool? autoSettlementEnabled,
    String? settlementScheduleType,
    int? settlementWeekday,
    int? settlementBankSafeBoxId,
    int? feeExpenseAccountId,
    double minSettlementAmount = 0.0,
    String settlementMode = 'bulk',
    int depositDelayDays = 0,
    String depositScheduleType = 'days',
    int? depositWeekday,
    required bool isActive,
    int? defaultSafeBoxId,
    List<String>? applicableInvoiceTypes,
  }) async {
    final payload = <String, dynamic>{
      'payment_type': paymentType,
      'name': name,
      'commission_rate': commissionRate,
      'commission_timing': commissionTiming,
      'settlement_days': settlementDays,
      'is_active': isActive,
      // Always include to allow clearing (null) explicitly.
      'default_safe_box_id': defaultSafeBoxId,
    };

    if (commissionFixedAmount != null) {
      payload['commission_fixed_amount'] = commissionFixedAmount;
    }

    if (autoSettlementEnabled != null) {
      payload['auto_settlement_enabled'] = autoSettlementEnabled;
    }
    if (settlementScheduleType != null) {
      payload['settlement_schedule_type'] = settlementScheduleType;
    }
    if (settlementWeekday != null || settlementScheduleType == 'weekday') {
      // Send weekday when provided, and allow clearing by sending null explicitly.
      payload['settlement_weekday'] = settlementWeekday;
    }
    if (settlementBankSafeBoxId != null || (autoSettlementEnabled == true)) {
      payload['settlement_bank_safe_box_id'] = settlementBankSafeBoxId;
    }

    // إرسال حساب مصروف العمولة (يُسمح بإرسال null لمسح الربط)
    payload['fee_expense_account_id'] = feeExpenseAccountId;
    payload['min_settlement_amount'] = minSettlementAmount;
    payload['settlement_mode'] = settlementMode;
    payload['deposit_delay_days'] = depositDelayDays;
    payload['deposit_schedule_type'] = depositScheduleType;
    payload['deposit_weekday'] = depositWeekday;

    if (applicableInvoiceTypes != null && applicableInvoiceTypes.isNotEmpty) {
      payload['applicable_invoice_types'] = applicableInvoiceTypes;
    }

    final response = await http.put(
      Uri.parse('$_baseUrl/payment-methods/$id'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to update payment method: ${response.body}');
    }
  }

  /// حذف وسيلة دفع
  Future<Map<String, dynamic>> deletePaymentMethod(int id) async {
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/payment-methods/$id'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
    );
    if (response.statusCode == 200 || response.statusCode == 204) {
      if (response.bodyBytes.isEmpty) return <String, dynamic>{};
      final decoded = utf8.decode(response.bodyBytes);
      if (decoded.trim().isEmpty) return <String, dynamic>{};
      final parsed = json.decode(decoded);
      if (parsed is Map<String, dynamic>) return parsed;
      return <String, dynamic>{};
    }

    String details = response.body;
    try {
      details = utf8.decode(response.bodyBytes);
    } catch (_) {
      // ignore
    }
    throw Exception('Failed to delete payment method: $details');
  }

  /// حفظ ترتيب طرق الدفع
  Future<void> updatePaymentMethodsOrder(
    List<Map<String, dynamic>> methods,
  ) async {
    // تحديث display_order لكل طريقة دفع
    final updates = methods.asMap().entries.map((entry) {
      return {
        'id': entry.value['id'],
        'display_order': entry.key + 1, // الترتيب يبدأ من 1
      };
    }).toList();

    final response = await http.put(
      Uri.parse('$_baseUrl/payment-methods/update-order'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'methods': updates}),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to update payment methods order: ${response.body}',
      );
    }
  }

  /// جلب أنواع وسائل الدفع (ديناميكي من القاعدة)
  Future<List<dynamic>> getPaymentTypes() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/payment-types'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
    );

    if (response.statusCode == 200) {
      return json.decode(response.body) as List<dynamic>;
    } else {
      throw Exception('Failed to load payment types');
    }
  }

  // ==================== Accounting Mapping Methods ====================

  /// الحصول على جميع إعدادات الربط المحاسبي
  Future<List<dynamic>> getAccountingMappings({String? operationType}) async {
    String url = '$_baseUrl/accounting-mappings';
    if (operationType != null) {
      url += '?operation_type=$operationType';
    }

    final uri = Uri.parse(url);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    } else {
      throw Exception('Failed to load accounting mappings');
    }
  }

  /// إنشاء أو تحديث إعداد ربط محاسبي
  Future<Map<String, dynamic>> createAccountingMapping({
    required String operationType,
    required String accountType,
    required int accountId,
    double? allocationPercentage,
    String? description,
    bool isActive = true,
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/accounting-mappings'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({
        'operation_type': operationType,
        'account_type': accountType,
        'account_id': accountId,
        'allocation_percentage': allocationPercentage,
        'description': description,
        'is_active': isActive,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to create accounting mapping: ${response.body}');
    }
  }

  /// إنشاء عدة إعدادات ربط دفعة واحدة
  Future<Map<String, dynamic>> batchCreateAccountingMappings(
    List<Map<String, dynamic>> mappings,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/accounting-mappings/batch'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'mappings': mappings}),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to batch create accounting mappings: ${response.body}',
      );
    }
  }

  /// حذف إعداد ربط محاسبي
  Future<void> deleteAccountingMapping(int mappingId) async {
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/accounting-mappings/$mappingId'),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to delete accounting mapping');
    }
  }

  /// الحصول على الحساب المرتبط لعملية معينة
  Future<Map<String, dynamic>> getMappedAccount({
    required String operationType,
    required String accountType,
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/accounting-mappings/get-account'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({
        'operation_type': operationType,
        'account_type': accountType,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to get mapped account: ${response.body}');
    }
  }

  // ==================== App Config ====================

  /// جلب إعدادات بسيطة يحتاجها العميل (مثل الحسابات التجميعية للسندات)
  Future<Map<String, dynamic>> getAppConfig() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/app-config'));

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    }
    throw Exception('Failed to load app config: ${response.body}');
  }

  // ---------------------------------------------------------------------------
  // Employees API
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getEmployees({
    int page = 1,
    int perPage = 20,
    String? search,
    String? department,
    // null → active only (default), true → active, false → inactive, special: pass isActive=null with showAll=true for all
    bool? isActive = true,
    bool showAll = false,
  }) async {
    final queryParameters = <String, String>{
      'page': page.toString(),
      'per_page': perPage.toString(),
    };

    if (search != null && search.isNotEmpty) {
      queryParameters['search'] = search;
    }
    if (department != null && department.isNotEmpty) {
      queryParameters['department'] = department;
    }
    if (showAll) {
      queryParameters['is_active'] = 'all';
    } else if (isActive != null) {
      queryParameters['is_active'] = isActive ? 'true' : 'false';
    }

    final uri = Uri.parse(
      '$_baseUrl/employees',
    ).replace(queryParameters: queryParameters);

    final token = await _requireAuthToken();
    final response = await http.get(uri, headers: _jsonHeaders(token: token));

    if (response.statusCode == 200) {
      final raw =
          json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final employeesJson = raw['employees'] as List<dynamic>? ?? [];
      final employees = employeesJson
          .map((e) => EmployeeModel.fromJson(e as Map<String, dynamic>))
          .toList();

      return {
        'employees': employees,
        'total': raw['total'] ?? employees.length,
        'pages': raw['pages'] ?? 1,
        'current_page': raw['current_page'] ?? page,
        'per_page': raw['per_page'] ?? perPage,
      };
    } else {
      throw Exception('Failed to load employees: ${response.body}');
    }
  }

  Future<EmployeeModel> getEmployee(int employeeId) async {
    final token = await _requireAuthToken();
    final response = await http.get(
      Uri.parse('$_baseUrl/employees/$employeeId'),
      headers: _jsonHeaders(token: token),
    );

    if (response.statusCode == 200) {
      return EmployeeModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to load employee: ${response.body}');
    }
  }

  Future<EmployeeModel> createEmployee(Map<String, dynamic> payload) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/employees'),
      headers: _jsonHeaders(token: token),
      body: json.encode(_normalizePayload(payload)),
    );

    if (response.statusCode == 201) {
      return EmployeeModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<EmployeeModel> updateEmployee(
    int employeeId,
    Map<String, dynamic> payload,
  ) async {
    final token = await _requireAuthToken();
    final response = await http.put(
      Uri.parse('$_baseUrl/employees/$employeeId'),
      headers: _jsonHeaders(token: token),
      body: json.encode(_normalizePayload(payload)),
    );

    if (response.statusCode == 200) {
      return EmployeeModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to update employee: ${response.body}');
    }
  }

  /// Upload or clear the current user's profile photo.
  /// Uses /auth/me/photo — works for all users (with or without employee).
  Future<void> updateCurrentUserPhoto(String? photoBase64) async {
    final token = await _requireAuthToken();
    final response = await http.patch(
      Uri.parse('$_baseUrl/auth/me/photo'),
      headers: _jsonHeaders(token: token),
      body: json.encode({'photo': photoBase64}),
    );
    if (response.statusCode != 200) {
      throw Exception('فشل تحديث الصورة: ${response.body}');
    }
  }

  /// Upload or clear an employee profile photo (for admin use).
  Future<void> updateEmployeePhoto(int employeeId, String? photoBase64) async {
    final token = await _requireAuthToken();
    final response = await http.patch(
      Uri.parse('$_baseUrl/employees/$employeeId/photo'),
      headers: _jsonHeaders(token: token),
      body: json.encode({'photo': photoBase64}),
    );
    if (response.statusCode != 200) {
      throw Exception('فشل تحديث صورة الموظف: ${response.body}');
    }
  }

  Future<EmployeeModel> ensureEmployeeSetup(
    int employeeId, {
    bool ensurePersonalAccount = true,
    bool ensurePayablesAccounts = true,
    bool ensureCashSafe = true,
    bool ensureGoldSafe = true,
  }) async {
    final token = await _requireAuthToken();
    final payload = {
      'ensure_personal_account': ensurePersonalAccount,
      'ensure_payables_accounts': ensurePayablesAccounts,
      'ensure_cash_safe': ensureCashSafe,
      'ensure_gold_safe': ensureGoldSafe,
    };

    final response = await http.post(
      Uri.parse('$_baseUrl/employees/$employeeId/ensure-setup'),
      headers: _jsonHeaders(token: token),
      body: json.encode(_normalizePayload(payload)),
    );

    if (response.statusCode == 200) {
      return EmployeeModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<Map<String, dynamic>> bulkEnsureAllEmployeesSetup() async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/employees/bulk-ensure-setup'),
      headers: _jsonHeaders(token: token),
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } else {
      throw Exception(_errorMessageFromResponse(response));
    }
  }

  Future<void> deleteEmployee(int employeeId) async {
    final token = await _requireAuthToken();
    final response = await http.delete(
      Uri.parse('$_baseUrl/employees/$employeeId'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to delete employee: ${response.body}');
    }
  }

  Future<bool> toggleEmployeeActive(int employeeId) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/employees/$employeeId/toggle-active'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode == 200) {
      final raw =
          json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return raw['is_active'] as bool? ?? false;
    } else {
      throw Exception('Failed to toggle employee status: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> createUserFromEmployee({
    required int employeeId,
    required String username,
    required String password,
    required String email,
    required String phone,
    String role = 'staff',
  }) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/app-users/from-employee'),
      headers: _jsonHeaders(token: token),
      body: json.encode({
        'employee_id': employeeId,
        'username': username,
        'password': password,
        'email': email,
        'phone': phone,
        'role': role,
      }),
    );

    if (response.statusCode == 201) {
      final data =
          json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return data['app_user'] as Map<String, dynamic>;
    } else {
      final error =
          json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      throw Exception(
        error['message'] ?? 'Failed to create user from employee',
      );
    }
  }

  Future<List<PayrollModel>> getEmployeePayroll(int employeeId) async {
    final token = await _requireAuthToken();
    final response = await http.get(
      Uri.parse('$_baseUrl/employees/$employeeId/payroll'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode == 200) {
      final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      return raw
          .map((e) => PayrollModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      throw Exception('Failed to load employee payroll: ${response.body}');
    }
  }

  Future<List<AttendanceModel>> getEmployeeAttendance(
    int employeeId, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final queryParameters = <String, String>{};
    if (startDate != null) {
      queryParameters['start_date'] = startDate
          .toIso8601String()
          .split('T')
          .first;
    }
    if (endDate != null) {
      queryParameters['end_date'] = endDate.toIso8601String().split('T').first;
    }

    final uri = Uri.parse(
      '$_baseUrl/employees/$employeeId/attendance',
    ).replace(queryParameters: queryParameters);
    final token = await _requireAuthToken();
    final response = await http.get(uri, headers: _jsonHeaders(token: token));

    if (response.statusCode == 200) {
      final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      return raw
          .map((e) => AttendanceModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      throw Exception('Failed to load attendance: ${response.body}');
    }
  }

  // ---------------------------------------------------------------------------
  // Users & Authentication API
  // ---------------------------------------------------------------------------

  Future<List<AppUserModel>> getUsers({
    bool? isActive,
    String? role,
    String? search,
  }) async {
    final queryParameters = <String, String>{};
    if (isActive != null) {
      queryParameters['is_active'] = isActive ? 'true' : 'false';
    }
    if (role != null && role.isNotEmpty) {
      queryParameters['role'] = role;
    }
    if (search != null && search.isNotEmpty) {
      queryParameters['search'] = search;
    }

    final uri = Uri.parse(
      '$_baseUrl/app-users',
    ).replace(queryParameters: queryParameters);

    final token = await _requireAuthToken();
    final response = await http.get(uri, headers: _jsonHeaders(token: token));

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));

      // بعض النسخ تعيد قائمة مباشرة، ونسخ أخرى تعيد خريطة تحتوي على app_users/users/data
      List<dynamic> rawList;
      if (decoded is List) {
        rawList = decoded;
      } else if (decoded is Map) {
        rawList =
            (decoded['app_users'] ??
                    decoded['users'] ??
                    decoded['data'] ??
                    decoded['results'] ??
                    decoded['items'] ??
                    decoded['rows'] ??
                    decoded.values.firstWhere(
                      (v) => v is List,
                      orElse: () => <dynamic>[],
                    ))
                as List<dynamic>;
      } else {
        throw Exception('Unexpected users response format');
      }

      return rawList
          .map((e) => AppUserModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      throw Exception('Failed to load users: ${response.body}');
    }
  }

  Future<AppUserModel?> getUserByEmployeeId(int employeeId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/app-users/by-employee/$employeeId'),
    );
    if (response.statusCode == 200) {
      final decoded =
          json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final raw = decoded['app_user'];
      if (raw == null) return null;
      if (raw is Map<String, dynamic>) {
        return AppUserModel.fromJson(raw);
      }
      return AppUserModel.fromJson(Map<String, dynamic>.from(raw as Map));
    }
    throw Exception(_readApiErrorMessage(response, 'فشل في جلب حساب الموظف'));
  }

  Future<AppUserModel> createUser(Map<String, dynamic> payload) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/app-users'),
      body: json.encode(_normalizePayload(payload)),
    );

    if (response.statusCode == 201) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        final raw =
            (decoded['app_user'] ?? decoded['user'] ?? decoded) as Object?;
        if (raw is Map<String, dynamic>) {
          return AppUserModel.fromJson(raw);
        }
      }
      throw Exception('Unexpected create user response format');
    }

    throw Exception(_readApiErrorMessage(response, 'فشل في إنشاء المستخدم'));
  }

  Future<AppUserModel> updateUser(
    int userId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/app-users/$userId'),
      body: json.encode(_normalizePayload(payload)),
    );

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        final raw =
            (decoded['app_user'] ?? decoded['user'] ?? decoded) as Object?;
        if (raw is Map<String, dynamic>) {
          return AppUserModel.fromJson(raw);
        }
      }
      throw Exception('Unexpected update user response format');
    }

    throw Exception(_readApiErrorMessage(response, 'فشل في تحديث المستخدم'));
  }

  Future<Map<String, dynamic>> deleteUser(int userId) async {
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/app-users/$userId'),
    );
    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return <String, dynamic>{'success': true};
    }
    throw Exception(_readApiErrorMessage(response, 'فشل في حذف المستخدم'));
  }

  Future<bool> toggleUserActive(int userId) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/app-users/$userId/toggle-active'),
    );
    if (response.statusCode == 200) {
      final decoded =
          json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

      // supported shapes:
      // { success: true, is_active: bool, ... }
      // { is_active: bool }
      final isActive =
          (decoded['is_active'] as bool?) ??
          ((decoded['app_user'] is Map)
              ? (decoded['app_user'] as Map)['is_active'] as bool?
              : null);

      return isActive ?? false;
    }

    throw Exception(
      _readApiErrorMessage(response, 'فشل في تغيير حالة المستخدم'),
    );
  }

  Future<void> resetUserPassword(int userId, String newPassword) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/app-users/$userId/reset-password'),
      body: json.encode({'new_password': newPassword}),
    );

    if (response.statusCode != 200) {
      throw Exception(
        _readApiErrorMessage(response, 'فشل في إعادة تعيين كلمة المرور'),
      );
    }
  }

  Future<AppUserModel> login(String username, String password) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'username': username, 'password': password}),
    );

    if (response.statusCode == 200) {
      final raw =
          json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (raw['user'] is Map<String, dynamic>) {
        return AppUserModel.fromJson(raw['user'] as Map<String, dynamic>);
      }
      throw Exception('Unexpected login response');
    } else {
      throw Exception('Login failed: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> checkSetup() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/auth/check-setup'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } else {
      throw Exception('Check setup failed: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> setupInitialSystem({
    String username = 'admin',
    required String password,
    String? fullName,
    String? companyName,
  }) async {
    final payload = <String, dynamic>{
      'username': username,
      'password': password,
      if (fullName != null) 'full_name': fullName,
      if (companyName != null) 'company_name': companyName,
    };

    final response = await http.post(
      Uri.parse('$_baseUrl/auth/setup-initial'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );

    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (response.statusCode == 200) {
      return decoded as Map<String, dynamic>;
    }

    if (decoded is Map && decoded['message'] is String) {
      throw Exception(decoded['message']);
    }

    throw Exception('فشل تهيئة النظام');
  }

  // ---------------------------------------------------------------------------
  // Setup Wizard APIs
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> testDatabaseConnection({
    String? token,
    required String host,
    int port = 5432,
    required String dbName,
    required String username,
    required String password,
  }) async {
    final payload = {
      'host': host,
      'port': port,
      'db_name': dbName,
      'username': username,
      'password': password,
    };

    final response = await http.post(
      Uri.parse('$_baseUrl/setup/test-db'),
      headers: _jsonHeaders(token: token),
      body: json.encode(payload),
    );

    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      if (response.statusCode == 200) return decoded;
      final msg = decoded['message']?.toString();
      throw Exception(msg?.isNotEmpty == true ? msg : 'فشل اختبار الاتصال');
    }
    throw Exception('فشل اختبار الاتصال');
  }

  Future<Map<String, dynamic>> saveStoreSettings({
    String? token,
    required String companyName,
    String? currencySymbol,
    String? companyTaxNumber,
    String? companyLogoBase64,
  }) async {
    final payload = <String, dynamic>{
      'company_name': companyName,
      if (currencySymbol != null) 'currency_symbol': currencySymbol,
      if (companyTaxNumber != null) 'company_tax_number': companyTaxNumber,
      if (companyLogoBase64 != null) 'company_logo_base64': companyLogoBase64,
    };

    final response = await http.post(
      Uri.parse('$_baseUrl/setup/store-settings'),
      headers: _jsonHeaders(token: token),
      body: json.encode(payload),
    );

    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      if (response.statusCode == 200) return decoded;
      final msg = decoded['message']?.toString();
      throw Exception(msg?.isNotEmpty == true ? msg : 'فشل حفظ إعدادات المتجر');
    }
    throw Exception('فشل حفظ إعدادات المتجر');
  }

  Future<Map<String, dynamic>> writeEnvProduction({
    required String token,
    required String host,
    int port = 5432,
    required String dbName,
    required String username,
    required String password,
    bool restartContainers = false,
  }) async {
    final payload = {
      'db': {
        'host': host,
        'port': port,
        'db_name': dbName,
        'username': username,
        'password': password,
      },
      'restart_containers': restartContainers,
    };

    final response = await http.post(
      Uri.parse('$_baseUrl/setup/write-env-production'),
      headers: _jsonHeaders(token: token),
      body: json.encode(payload),
    );

    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      if (response.statusCode == 200) return decoded;
      final msg = decoded['message']?.toString();
      throw Exception(
        msg?.isNotEmpty == true ? msg : 'فشل إنشاء ملف الإعدادات',
      );
    }
    throw Exception('فشل إنشاء ملف الإعدادات');
  }

  // ---------------------------------------------------------------------------
  // Home Leaderboard (Gamification)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getHomeLeaderboard({
    String period = 'today',
    String metric = 'weight',
  }) async {
    final uri = Uri.parse('$_baseUrl/home/leaderboard').replace(
      queryParameters: {
        'period': period,
        'metric': metric,
        '_ts': '${DateTime.now().millisecondsSinceEpoch}',
      },
    );

    final response = await _authedGet(uri);
    final decoded = json.decode(utf8.decode(response.bodyBytes));

    if (response.statusCode == 200) {
      if (decoded is Map<String, dynamic>) return decoded;
      throw Exception('Unexpected leaderboard response');
    }

    try {
      if (decoded is Map<String, dynamic>) {
        final msg = decoded['message']?.toString();
        final err = decoded['error']?.toString();
        throw Exception(
          msg?.isNotEmpty == true ? msg : (err ?? 'فشل تحميل لوحة الصدارة'),
        );
      }
    } catch (_) {
      // fallthrough
    }
    throw Exception('Failed to load leaderboard: ${response.body}');
  }

  Future<Map<String, dynamic>> getSalesRaceConfig() async {
    final uri = Uri.parse('$_baseUrl/sales-race/config');
    final response = await _authedGet(uri);
    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (response.statusCode == 200 && decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw Exception('فشل تحميل إعدادات سباق المبيعات');
  }

  Future<Map<String, dynamic>> updateSalesRaceConfig(
    Map<String, dynamic> data,
  ) async {
    final uri = Uri.parse('$_baseUrl/sales-race/config');
    final response = await _authedPut(uri, body: json.encode(data));
    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (response.statusCode == 200 && decoded is Map<String, dynamic>) {
      return decoded;
    }
    final msg = decoded is Map ? (decoded['message'] ?? decoded['error']) : null;
    throw Exception(msg?.toString() ?? 'فشل حفظ إعدادات سباق المبيعات');
  }

  // ---------------------------------------------------------------------------
  // Payroll API
  // ---------------------------------------------------------------------------

  Future<List<PayrollModel>> getPayroll({
    int? employeeId,
    int? year,
    int? month,
    String? status,
  }) async {
    final queryParameters = <String, String>{};
    if (employeeId != null) {
      queryParameters['employee_id'] = employeeId.toString();
    }
    if (year != null) {
      queryParameters['year'] = year.toString();
    }
    if (month != null) {
      queryParameters['month'] = month.toString();
    }
    if (status != null && status.isNotEmpty) {
      queryParameters['status'] = status;
    }

    final uri = Uri.parse(
      '$_baseUrl/payroll',
    ).replace(queryParameters: queryParameters);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      return raw
          .map((e) => PayrollModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      throw Exception('Failed to load payroll: ${response.body}');
    }
  }

  Future<PayrollModel> createPayroll(Map<String, dynamic> payload) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/payroll'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(_normalizePayload(payload)),
    );

    if (response.statusCode == 201) {
      return PayrollModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to create payroll entry: ${response.body}');
    }
  }

  Future<PayrollModel> updatePayroll(
    int payrollId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/payroll/$payrollId'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(_normalizePayload(payload)),
    );

    if (response.statusCode == 200) {
      return PayrollModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to update payroll entry: ${response.body}');
    }
  }

  Future<void> deletePayroll(int payrollId) async {
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/payroll/$payrollId'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to delete payroll entry: ${response.body}');
    }
  }

  /// الحصول على حسابات الدفع المتاحة (نقدية، بنك، شيك)
  Future<List<Map<String, dynamic>>> getPaymentAccounts() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/payroll/payment-accounts'),
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(utf8.decode(response.bodyBytes));
      return data.cast<Map<String, dynamic>>();
    } else {
      try {
        final decoded = json.decode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic>) {
          final msg = decoded['message']?.toString();
          final err = decoded['error']?.toString();
          throw Exception(
            msg?.isNotEmpty == true ? msg : (err ?? 'فشل تحميل حسابات الدفع'),
          );
        }
      } catch (_) {
        // fallthrough
      }
      throw Exception('Failed to fetch payment accounts: ${response.body}');
    }
  }

  Future<PayrollModel> markPayrollPaid(
    int payrollId, {
    DateTime? paidDate,
    int? voucherId,
    int? paymentAccountId, // ✅ حساب الدفع (نقدية/بنك/شيك)
    double? advanceDeductionAmount, // ✅ خصم من سلفة الموظف ضمن نفس السند
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/payroll/$payrollId/mark-paid'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(
        {
          'paid_date': paidDate?.toIso8601String().split('T').first,
          'voucher_id': voucherId,
          'payment_account_id': paymentAccountId, // ✅ إرسال حساب الدفع
          'advance_deduction_amount': advanceDeductionAmount,
        }..removeWhere((key, value) => value == null),
      ),
    );

    if (response.statusCode == 200) {
      return PayrollModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      // استخراج رسالة عربية واضحة من الـ JSON إن وُجدت
      String msg = response.body;
      try {
        final decoded = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        msg = (decoded['message'] as String?) ??
            (decoded['error'] as String?) ??
            response.body;
      } catch (_) {}
      throw Exception(msg);
    }
  }

  Future<Map<String, dynamic>> postPayrollAccrual(
    int payrollId, {
    String? createdBy,
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/payroll/$payrollId/post-accrual'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(
        {'created_by': createdBy}..removeWhere((key, value) => value == null),
      ),
    );

    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (response.statusCode == 200) {
      if (decoded is Map<String, dynamic>) return decoded;
      throw Exception('Unexpected response from post-accrual');
    }

    try {
      if (decoded is Map<String, dynamic>) {
        final msg = decoded['message']?.toString();
        final err = decoded['error']?.toString();
        throw Exception(
          msg?.isNotEmpty == true ? msg : (err ?? 'فشل ترحيل الاستحقاق'),
        );
      }
    } catch (_) {
      // fallthrough
    }
    throw Exception('Failed to post payroll accrual: ${response.body}');
  }

  Future<PayrollModel> clonePayroll(
    int payrollId, {
    required int month,
    required int year,
    String? createdBy,
  }) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/payroll/$payrollId/clone'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({
        'month': month,
        'year': year,
        if (createdBy != null) 'created_by': createdBy,
      }),
    );

    if (response.statusCode == 201) {
      return PayrollModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      String msg = response.body;
      try {
        final decoded = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        msg = (decoded['message'] as String?) ?? (decoded['error'] as String?) ?? response.body;
      } catch (_) {}
      throw Exception(msg);
    }
  }

  Future<Map<String, dynamic>> bulkApprovePayroll({
    List<int>? ids,
    int? year,
    int? month,
    String? createdBy,
  }) async {
    final body = <String, dynamic>{};
    if (ids != null) body['ids'] = ids;
    if (year != null) body['year'] = year;
    if (month != null) body['month'] = month;
    if (createdBy != null) body['created_by'] = createdBy;

    final response = await _authedPost(
      Uri.parse('$_baseUrl/payroll/bulk-approve'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(body),
    );
    final decoded = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode == 200) return decoded;
    throw Exception((decoded['message'] ?? decoded['error']) ?? response.body);
  }

  Future<Map<String, dynamic>> bulkCancelPayroll({
    List<int>? ids,
    int? year,
    int? month,
  }) async {
    final body = <String, dynamic>{};
    if (ids != null) body['ids'] = ids;
    if (year != null) body['year'] = year;
    if (month != null) body['month'] = month;

    final response = await _authedPost(
      Uri.parse('$_baseUrl/payroll/bulk-cancel'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(body),
    );
    final decoded = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode == 200) return decoded;
    throw Exception((decoded['message'] ?? decoded['error']) ?? response.body);
  }

  // ---------------------------------------------------------------------------
  // Attendance API
  // ---------------------------------------------------------------------------

  Future<List<AttendanceModel>> getAttendance({
    int? employeeId,
    DateTime? startDate,
    DateTime? endDate,
    String? status,
  }) async {
    final queryParameters = <String, String>{};
    if (employeeId != null) {
      queryParameters['employee_id'] = employeeId.toString();
    }
    if (startDate != null) {
      queryParameters['start_date'] = startDate
          .toIso8601String()
          .split('T')
          .first;
    }
    if (endDate != null) {
      queryParameters['end_date'] = endDate.toIso8601String().split('T').first;
    }
    if (status != null && status.isNotEmpty) {
      queryParameters['status'] = status;
    }

    final uri = Uri.parse(
      '$_baseUrl/attendance',
    ).replace(queryParameters: queryParameters);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      final raw = json.decode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      return raw
          .map((e) => AttendanceModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      throw Exception('Failed to load attendance list: ${response.body}');
    }
  }

  Future<AttendanceModel> createAttendance(Map<String, dynamic> payload) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/attendance'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(_normalizePayload(payload)),
    );

    if (response.statusCode == 201) {
      return AttendanceModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to create attendance record: ${response.body}');
    }
  }

  Future<AttendanceModel> updateAttendance(
    int attendanceId,
    Map<String, dynamic> payload,
  ) async {
    final token = await _requireAuthToken();
    final response = await http.put(
      Uri.parse('$_baseUrl/attendance/$attendanceId'),
      headers: _jsonHeaders(token: token),
      body: json.encode(_normalizePayload(payload)),
    );

    if (response.statusCode == 200) {
      return AttendanceModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to update attendance record: ${response.body}');
    }
  }

  Future<void> deleteAttendance(int attendanceId) async {
    final token = await _requireAuthToken();
    final response = await http.delete(
      Uri.parse('$_baseUrl/attendance/$attendanceId'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to delete attendance record: ${response.body}');
    }
  }

  // ---------------------------------------------------------------------------
  // SafeBox API (إدارة الخزائن)
  // ---------------------------------------------------------------------------
  /// الحصول على جميع الخزائن أو حسب النوع
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async {
    final queryParams = <String, String>{};
    if (safeType != null) queryParams['safe_type'] = safeType;
    if (isActive != null) queryParams['is_active'] = isActive.toString();
    if (karat != null) queryParams['karat'] = karat.toString();
    if (includeAccount) queryParams['include_account'] = 'true';
    if (includeBalance) queryParams['include_balance'] = 'true';
    final uri = Uri.parse(
      '$_baseUrl/safe-boxes',
    ).replace(queryParameters: queryParams);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(utf8.decode(response.bodyBytes));
      return data
          .map((json) => SafeBoxModel.fromJson(json as Map<String, dynamic>))
          .toList();
    } else {
      throw Exception('Failed to load safe boxes: ${response.body}');
    }
  }

  /// الحصول على أرصدة الخزائن من الـ Ledger (SafeBoxTransaction)
  /// Endpoint: GET /safe-boxes/balances?type=gold
  Future<List<SafeBoxModel>> getSafeBoxBalances({
    String? type,
    bool? isActive,
    DateTime? from,
    DateTime? to,
  }) async {
    final queryParams = <String, String>{};
    if (type != null && type.trim().isNotEmpty) queryParams['type'] = type;
    if (isActive != null) queryParams['is_active'] = isActive.toString();
    if (from != null) queryParams['from'] = from.toIso8601String();
    if (to != null) queryParams['to'] = to.toIso8601String();

    final uri = Uri.parse(
      '$_baseUrl/safe-boxes/balances',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);

    final response = await _authedGet(uri);
    if (response.statusCode != 200) {
      throw Exception('Failed to load safe box balances: ${response.body}');
    }

    final decoded = json.decode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      final rows = decoded['rows'];
      if (rows is List) {
        return rows
            .whereType<Map<String, dynamic>>()
            .map((j) => SafeBoxModel.fromJson(j))
            .toList();
      }
    }
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((j) => SafeBoxModel.fromJson(j))
          .toList();
    }

    return <SafeBoxModel>[];
  }

  /// رصيد الفصوص لكل خزينة ذهب (معلوماتي فقط — لا يؤثر على الأرصدة الذهبية).
  /// Endpoint: GET /safe-boxes/stones-balance
  Future<Map<int, Map<String, double>>> getStonesBalance({int? safeBoxId}) async {
    final params = safeBoxId != null ? {'safe_box_id': safeBoxId.toString()} : null;
    final uri = Uri.parse('$_baseUrl/safe-boxes/stones-balance')
        .replace(queryParameters: params);
    final response = await _authedGet(uri);
    if (response.statusCode != 200) return {};
    final decoded = json.decode(utf8.decode(response.bodyBytes));
    final safes = decoded['safes'] as List? ?? [];
    final result = <int, Map<String, double>>{};
    for (final s in safes.whereType<Map<String, dynamic>>()) {
      final id = s['safe_box_id'];
      if (id == null) continue;
      final byKarat = (s['by_karat'] as Map<String, dynamic>?) ?? {};
      result[(id as num).toInt()] = {
        'total': (s['stones_balance'] as num? ?? 0).toDouble(),
        '18': (byKarat['18'] as num? ?? 0).toDouble(),
        '21': (byKarat['21'] as num? ?? 0).toDouble(),
        '22': (byKarat['22'] as num? ?? 0).toDouble(),
        '24': (byKarat['24'] as num? ?? 0).toDouble(),
      };
    }
    return result;
  }

  /// مطابقة أرصدة الخزن (Ledger) مع دفتر الأستاذ (GL) لحسابات الخزن.
  /// Endpoint: GET /safe-boxes/reconciliation
  Future<Map<String, dynamic>> getSafeBoxesReconciliation({
    String? safeType,
    bool? isActive,
    int? safeBoxId,
    bool includeKeyed = false,
    double threshold = 0.01,
    List<String> ignoreRefTypes = const ['shift_closing_settlement'],
  }) async {
    final queryParams = <String, String>{
      'threshold': threshold.toString(),
    };
    if (safeType != null && safeType.trim().isNotEmpty) {
      queryParams['safe_type'] = safeType.trim().toLowerCase();
    }
    if (isActive != null) {
      queryParams['is_active'] = isActive ? 'true' : 'false';
    }
    if (safeBoxId != null) {
      queryParams['safe_box_id'] = safeBoxId.toString();
    }
    if (includeKeyed) {
      queryParams['include_keyed'] = 'true';
    }
    if (ignoreRefTypes.isNotEmpty) {
      queryParams['ignore_ref_types'] = ignoreRefTypes.join(',');
    }

    final uri = Uri.parse(
      '$_baseUrl/safe-boxes/reconciliation',
    ).replace(queryParameters: queryParams);

    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    }

    throw Exception(
      'Failed to load safe-box reconciliation: ${response.body}',
    );
  }

  /// إنشاء سند تحويل بين الخزائن (ذهب أو نقدي) وتحديث الـ Ledger فوراً.
  /// Endpoint: POST /safe-boxes/transfer-voucher
  ///
  /// ملاحظة: هذه الدالة لا تؤثر على أي شاشة/تدفق ما لم يتم استدعاؤها.
  /// تصحيح عيار داخل نفس الخزينة الذهبية (تصحيح خطأ تسجيل).
  /// Endpoint: POST /safe-boxes/{id}/correct-karat

  /// تسجيل عملية تكسير أو تجديد.
  /// Endpoint: POST /melting-renewal
  Future<Map<String, dynamic>> createMeltingRenewal({
    required String operationType, // 'melting' | 'renewal'
    required int fromSafeBoxId,
    required int toSafeBoxId,
    required int fromKarat,
    int? toKarat,
    required double goldWeight,
    double? stonesWeight,
    int? stonesRevenueAccountId,
    int? stonesExpenseAccountId,
    double? damageWageAmount,
    int? damageWageAccountId,
    String? notes,
  }) async {
    final payload = <String, dynamic>{
      'operation_type': operationType,
      'from_safe_box_id': fromSafeBoxId,
      'to_safe_box_id': toSafeBoxId,
      'from_karat': fromKarat,
      if (toKarat != null) 'to_karat': toKarat,
      'gold_weight': goldWeight,
      if (stonesWeight != null && stonesWeight > 0) 'stones_weight': stonesWeight,
      if (stonesRevenueAccountId != null) 'stones_revenue_account_id': stonesRevenueAccountId,
      if (stonesExpenseAccountId != null) 'stones_expense_account_id': stonesExpenseAccountId,
      if (damageWageAmount != null && damageWageAmount > 0) 'damage_wage_amount': damageWageAmount,
      if (damageWageAccountId != null) 'damage_wage_account_id': damageWageAccountId,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    };
    final response = await _authedPost(
      Uri.parse('$_baseUrl/melting-renewal'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );
    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode == 201 || response.statusCode == 200) {
      final decoded = json.decode(bodyStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'raw': decoded};
    }
    throw Exception(bodyStr);
  }

  Future<Map<String, dynamic>> correctSafeBoxKarat({
    required int safeBoxId,
    required int fromKarat,
    required int toKarat,
    required double weight,
    String? notes,
  }) async {
    final payload = <String, dynamic>{
      'from_karat': fromKarat,
      'to_karat': toKarat,
      'weight': weight,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    };

    final response = await _authedPost(
      Uri.parse('$_baseUrl/safe-boxes/$safeBoxId/correct-karat'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );

    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode == 201 || response.statusCode == 200) {
      final decoded = json.decode(bodyStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'raw': decoded};
    }
    throw Exception(bodyStr);
  }

  Future<Map<String, dynamic>> createSafeBoxTransferVoucher({
    required int fromSafeBoxId,
    required int toSafeBoxId,
    Map<String, double>? weights,
    Map<String, double>? stonesWeights,
    double? amountCash,
    String? notes,
    DateTime? date,
    String? approvedBy,
  }) async {
    final hasWeights = weights != null && weights.isNotEmpty;
    final hasCash = amountCash != null && amountCash > 0;

    if (hasWeights && hasCash) {
      throw ArgumentError('Provide either weights or amountCash, not both');
    }
    if (!hasWeights && !hasCash) {
      throw ArgumentError('Provide weights (gold) or amountCash (cash)');
    }

    final hasStones = stonesWeights != null &&
        stonesWeights.values.any((v) => v > 0);

    final payload = <String, dynamic>{
      'from_safe_box_id': fromSafeBoxId,
      'to_safe_box_id': toSafeBoxId,
      if (hasWeights) 'weights': weights,
      if (hasWeights && hasStones) 'stones': stonesWeights,
      if (hasCash) 'amount_cash': amountCash,
      if (notes != null) 'notes': notes,
      if (date != null) 'date': date.toIso8601String(),
      if (approvedBy != null) 'approved_by': approvedBy,
    };

    final response = await _authedPost(
      Uri.parse('$_baseUrl/safe-boxes/transfer-voucher'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );

    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode == 201 || response.statusCode == 200) {
      final decoded = json.decode(bodyStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'raw': decoded};
    }

    throw Exception(bodyStr);
  }

  /// إنشاء تسوية مستحقات تحصيل (Clearing → Bank) مع إثبات العمولة عند التسوية.
  /// Endpoint: POST /clearing/settlements
  Future<Map<String, dynamic>> createClearingSettlement({
    required int clearingSafeBoxId,
    required int bankSafeBoxId,
    required double grossAmount,
    double feeAmount = 0.0,
    int? feeAccountId,
    DateTime? settlementDate,
    String? referenceNumber,
    String? notes,
    String? description,
    String? createdBy,
    List<int>? invoicePaymentIds,
  }) async {
    final payload = <String, dynamic>{
      'clearing_safe_box_id': clearingSafeBoxId,
      'bank_safe_box_id': bankSafeBoxId,
      'gross_amount': grossAmount,
      'fee_amount': feeAmount,
      if (feeAccountId != null) 'fee_account_id': feeAccountId,
      if (settlementDate != null)
        'settlement_date': settlementDate.toIso8601String(),
      if (referenceNumber != null) 'reference_number': referenceNumber,
      if (notes != null) 'notes': notes,
      if (description != null) 'description': description,
      if (createdBy != null) 'created_by': createdBy,
      if (invoicePaymentIds != null) 'invoice_payment_ids': invoicePaymentIds,
    };

    final response = await _authedPost(
      Uri.parse('$_baseUrl/clearing/settlements'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );

    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode == 201 || response.statusCode == 200) {
      final decoded = json.decode(bodyStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'raw': decoded};
    }

    throw Exception(bodyStr);
  }

  /// تسوية فردية — سند لكل معاملة
  /// Endpoint: POST /clearing/settlements/per-transaction
  Future<Map<String, dynamic>> createPerTransactionSettlement({
    required int clearingSafeBoxId,
    required int bankSafeBoxId,
    double? commissionRate,
    double? commissionFixed,
    int? feeAccountId,
    DateTime? settlementDate,
    String? createdBy,
  }) async {
    final payload = <String, dynamic>{
      'clearing_safe_box_id': clearingSafeBoxId,
      'bank_safe_box_id': bankSafeBoxId,
      if (commissionRate != null) 'commission_rate': commissionRate,
      if (commissionFixed != null) 'commission_fixed': commissionFixed,
      if (feeAccountId != null) 'fee_account_id': feeAccountId,
      if (settlementDate != null)
        'settlement_date': settlementDate.toIso8601String(),
      if (createdBy != null) 'created_by': createdBy,
    };

    final response = await _authedPost(
      Uri.parse('$_baseUrl/clearing/settlements/per-transaction'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(payload),
    );

    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode == 201 || response.statusCode == 200) {
      final decoded = json.decode(bodyStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'raw': decoded};
    }

    throw Exception(bodyStr);
  }

  /// المعاملات المعلّقة للتسوية الفردية
  /// Endpoint: GET /clearing/settlements/pending-transactions
  Future<Map<String, dynamic>> getPendingSettlementTransactions({
    required int clearingSafeBoxId,
  }) async {
    final uri = Uri.parse('$_baseUrl/clearing/settlements/pending-transactions')
        .replace(
          queryParameters: {
            'clearing_safe_box_id': clearingSafeBoxId.toString(),
          },
        );

    final response = await _authedGet(uri);
    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode == 200) {
      final decoded = json.decode(bodyStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'raw': decoded};
    }

    throw Exception(bodyStr);
  }

  Future<Map<String, dynamic>> runAutoClearingSettlementsNow() async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/clearing/settlements/auto-run'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(<String, dynamic>{}),
    );

    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode == 200) {
      final decoded = json.decode(bodyStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'raw': decoded};
    }

    throw Exception(bodyStr);
  }

  /// الحصول على خزينة محددة
  Future<SafeBoxModel> getSafeBox(int id, {bool includeBalance = true}) async {
    final queryParams = <String, String>{};
    if (includeBalance) queryParams['include_balance'] = 'true';
    queryParams['include_account'] = 'true';

    final uri = Uri.parse(
      '$_baseUrl/safe-boxes/$id',
    ).replace(queryParameters: queryParams);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return SafeBoxModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to load safe box: ${response.body}');
    }
  }

  /// إنشاء خزينة جديدة
  Future<SafeBoxModel> createSafeBox(SafeBoxModel safeBox) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/safe-boxes'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(safeBox.toJson()),
    );

    if (response.statusCode == 201) {
      return SafeBoxModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to create safe box: ${response.body}');
    }
  }

  /// تحديث خزينة
  Future<SafeBoxModel> updateSafeBox(int id, SafeBoxModel safeBox) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/safe-boxes/$id'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(safeBox.toJson()),
    );

    if (response.statusCode == 200) {
      return SafeBoxModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to update safe box: ${response.body}');
    }
  }

  /// حذف خزينة
  Future<void> deleteSafeBox(int id) async {
    final response = await _authedDelete(Uri.parse('$_baseUrl/safe-boxes/$id'));
    if (response.statusCode != 200) {
      final bodyStr = utf8.decode(response.bodyBytes);
      try {
        final decoded = json.decode(bodyStr);
        if (decoded is Map<String, dynamic>) {
          final msg =
              (decoded['message'] as String?) ??
              (decoded['error'] as String?) ??
              'Failed to delete safe box';
          // Keep full JSON in exception string so callers can parse details if needed.
          throw Exception('$msg | $bodyStr');
        }
      } catch (_) {
        // ignore JSON parsing failures
      }

      throw Exception('Failed to delete safe box: $bodyStr');
    }
  }

  /// الحصول على الخزينة الافتراضية حسب النوع
  Future<SafeBoxModel> getDefaultSafeBox(String safeType) async {
    final response = await _authedGet(
      Uri.parse(
        '$_baseUrl/safe-boxes/default/$safeType?include_balance=true&include_account=true',
      ),
    );

    if (response.statusCode == 200) {
      return SafeBoxModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to load default safe box: ${response.body}');
    }
  }

  /// الحصول على خزينة الذهب حسب العيار
  Future<SafeBoxModel> getGoldSafeBox(int karat) async {
    final response = await _authedGet(
      Uri.parse(
        '$_baseUrl/safe-boxes/gold/$karat?include_balance=true&include_account=true',
      ),
    );

    if (response.statusCode == 200) {
      return SafeBoxModel.fromJson(
        json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } else {
      throw Exception('Failed to load gold safe box: ${response.body}');
    }
  }

  /// Ledger-based balance for a safe box (cash only)
  Future<Map<String, dynamic>> getSafeBoxLedgerBalance(
    int safeBoxId, {
    String? from,
    String? to,
  }) async {
    final queryParams = <String, String>{};
    if (from != null && from.trim().isNotEmpty) queryParams['from'] = from;
    if (to != null && to.trim().isNotEmpty) queryParams['to'] = to;
    final uri = Uri.parse(
      '$_baseUrl/safe-boxes/$safeBoxId/balance',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception('Failed to load safe balance: ${response.body}');
  }

  /// ميزان مراجعة الأوزان (مطابقة خزائن الذهب ↔ الحسابات الوزنية المرتبطة)
  /// Endpoint: GET /reports/gold-weight-trial-balance?date=YYYY-MM-DD
  Future<Map<String, dynamic>> getGoldWeightTrialBalance({
    DateTime? date,
  }) async {
    final queryParams = <String, String>{};
    if (date != null) {
      // Backend expects date only.
      final yyyy = date.year.toString().padLeft(4, '0');
      final mm = date.month.toString().padLeft(2, '0');
      final dd = date.day.toString().padLeft(2, '0');
      queryParams['date'] = '$yyyy-$mm-$dd';
    }

    final uri = Uri.parse(
      '$_baseUrl/reports/gold-weight-trial-balance',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);

    final response = await _authedGet(uri);
    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode == 200) {
      final decoded = json.decode(bodyStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'raw': decoded};
    }

    throw Exception(bodyStr);
  }

  /// الحصول على خزائن الدفع النشطة (نقدي + بنكي + مستحقات تحصيل)
  Future<List<SafeBoxModel>> getPaymentSafeBoxes() async {
    final safeBoxes = await getSafeBoxes(
      isActive: true,
      includeAccount: true,
      includeBalance: true,
    );

    // فلترة خزائن الدفع فقط (لا تشمل الذهب)
    return safeBoxes
        .where(
          (sb) =>
              sb.safeType == 'cash' ||
              sb.safeType == 'bank' ||
              sb.safeType == 'clearing',
        )
        .toList();
  }

  Map<String, dynamic> _normalizePayload(Map<String, dynamic> payload) {
    final normalized = <String, dynamic>{};
    payload.forEach((key, value) {
      if (value is DateTime) {
        normalized[key] = value.toIso8601String();
      } else if (value is bool) {
        normalized[key] = value;
      } else {
        normalized[key] = value;
      }
    });
    normalized.removeWhere((key, value) => value == null);
    return normalized;
  }

  // Generic HTTP Methods
  Future<dynamic> get(String endpoint) async {
    final uri = Uri.parse('$_baseUrl$endpoint');
    // Try unauthenticated first (for public endpoints). If server rejects with 401,
    // retry with authentication so protected endpoints work transparently.
    var response = await http.get(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    if (response.statusCode == 401) {
      final authed = await _authedGet(uri);
      if (authed.statusCode == 200) {
        return json.decode(utf8.decode(authed.bodyBytes));
      }
      throw Exception('GET request failed: ${authed.body}');
    }

    throw Exception('GET request failed: ${response.body}');
  }

  Future<dynamic> post(String endpoint, Map<String, dynamic> data) async {
    final uri = Uri.parse('$_baseUrl$endpoint');
    // Try unauthenticated first, then retry authenticated if server responds 401.
    var response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(data),
    );
    if (response.statusCode == 200 || response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    if (response.statusCode == 401) {
      final authed = await _authedPost(
        uri,
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: json.encode(data),
      );
      if (authed.statusCode == 200 || authed.statusCode == 201) {
        return json.decode(utf8.decode(authed.bodyBytes));
      }
      throw Exception('POST request failed: ${authed.body}');
    }

    throw Exception('POST request failed: ${response.body}');
  }

  Future<dynamic> put(String endpoint, Map<String, dynamic> data) async {
    final uri = Uri.parse('$_baseUrl$endpoint');
    var response = await http.put(
      uri,
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode(data),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    if (response.statusCode == 401) {
      final authed = await _authedPut(
        uri,
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: json.encode(data),
      );
      if (authed.statusCode == 200) {
        return json.decode(utf8.decode(authed.bodyBytes));
      }
      throw Exception('PUT request failed: ${authed.body}');
    }

    throw Exception('PUT request failed: ${response.body}');
  }

  Future<void> delete(String endpoint) async {
    final uri = Uri.parse('$_baseUrl$endpoint');
    var response = await http.delete(uri);
    if (response.statusCode == 200 || response.statusCode == 204) return;

    if (response.statusCode == 401) {
      final authed = await _authedDelete(uri);
      if (authed.statusCode == 200 || authed.statusCode == 204) return;
      throw Exception('DELETE request failed: ${authed.body}');
    }

    throw Exception('DELETE request failed: ${response.body}');
  }

  // =========================================
  // Posting Management Methods
  // =========================================

  /// Get posting statistics (no auth required)
  Future<Map<String, dynamic>> getPostingStats() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/posting/stats'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load posting stats');
    }
  }

  /// Get unposted invoices
  Future<Map<String, dynamic>> getUnpostedInvoices() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/invoices/unposted'));

    if (response.statusCode == 401) {
      throw Exception('انتهت صلاحية الجلسة. الرجاء تسجيل الدخول مرة أخرى');
    } else if (response.statusCode == 403) {
      throw Exception('ليس لديك صلاحية الوصول لهذه الميزة');
    } else if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final errorData = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(errorData['message'] ?? 'فشل تحميل الفواتير غير المرحلة');
    }
  }

  /// Get posted invoices
  Future<Map<String, dynamic>> getPostedInvoices() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/invoices/posted'));

    if (response.statusCode == 401) {
      throw Exception('انتهت صلاحية الجلسة. الرجاء تسجيل الدخول مرة أخرى');
    } else if (response.statusCode == 403) {
      throw Exception('ليس لديك صلاحية الوصول لهذه الميزة');
    } else if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final errorData = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(errorData['message'] ?? 'فشل تحميل الفواتير المرحلة');
    }
  }

  /// Get unposted journal entries
  Future<Map<String, dynamic>> getUnpostedJournalEntries() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/journal-entries/unposted'),
    );

    if (response.statusCode == 401) {
      throw Exception('انتهت صلاحية الجلسة. الرجاء تسجيل الدخول مرة أخرى');
    } else if (response.statusCode == 403) {
      throw Exception('ليس لديك صلاحية الوصول لهذه الميزة');
    } else if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final errorData = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(errorData['message'] ?? 'فشل تحميل القيود غير المرحلة');
    }
  }

  /// Get posted journal entries
  Future<Map<String, dynamic>> getPostedJournalEntries() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/journal-entries/posted'),
    );

    if (response.statusCode == 401) {
      throw Exception('انتهت صلاحية الجلسة. الرجاء تسجيل الدخول مرة أخرى');
    } else if (response.statusCode == 403) {
      throw Exception('ليس لديك صلاحية الوصول لهذه الميزة');
    } else if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final errorData = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(errorData['message'] ?? 'فشل تحميل القيود المرحلة');
    }
  }

  /// Fetch unposted invoices for the pending-approval Dialog
  Future<Map<String, dynamic>> getPendingPostInvoices({int limit = 10}) async {
    final uri = Uri.parse('$_baseUrl/invoices/pending-post')
        .replace(queryParameters: {'limit': '$limit'});
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    }
    return {'invoices': [], 'total': 0, 'showing': 0};
  }

  /// Post a single invoice
  Future<Map<String, dynamic>> postInvoice(
    int invoiceId,
    String postedBy,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/invoices/post/$invoiceId'),
      body: json.encode({'posted_by': postedBy}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to post invoice: ${response.body}');
    }
  }

  /// Post multiple invoices
  Future<Map<String, dynamic>> postInvoicesBatch(
    List<int> invoiceIds,
    String postedBy,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/invoices/post-batch'),
      body: json.encode({'invoice_ids': invoiceIds, 'posted_by': postedBy}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to post invoices batch: ${response.body}');
    }
  }

  /// Unpost an invoice
  Future<Map<String, dynamic>> unpostInvoice(int invoiceId) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/invoices/unpost/$invoiceId'),
      body: json.encode({}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to unpost invoice: ${response.body}');
    }
  }

  /// Unpost multiple invoices (batch)
  Future<Map<String, dynamic>> unpostInvoicesBatch(List<int> invoiceIds) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/invoices/unpost-batch'),
      body: json.encode({'invoice_ids': invoiceIds}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to unpost invoices batch: ${response.body}');
    }
  }

  /// Approve and fully post a large-discount invoice (manager/admin)
  Future<Map<String, dynamic>> approveLargeDiscountInvoice(
    int invoiceId,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/invoices/approve-large-discount/$invoiceId'),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    if (response.statusCode == 401) {
      throw Exception('انتهت صلاحية الجلسة. الرجاء تسجيل الدخول مرة أخرى');
    }
    if (response.statusCode == 403) {
      throw Exception('ليس لديك صلاحية اعتماد وترحيل هذه الفاتورة');
    }

    Map<String, dynamic>? parsed;
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        parsed = decoded;
      }
    } catch (_) {
      parsed = null;
    }

    final msg = parsed?['message']?.toString() ?? 'فشل اعتماد وترحيل الفاتورة';
    throw Exception('$msg (status: ${response.statusCode})');
  }

  /// Approve and fully post an invoice that requires manager approval.
  /// This is a generic endpoint (works for below_cost / large_discount ...).
  Future<Map<String, dynamic>> approveInvoice(int invoiceId) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/invoices/approve/$invoiceId'),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    if (response.statusCode == 401) {
      throw Exception('انتهت صلاحية الجلسة. الرجاء تسجيل الدخول مرة أخرى');
    }
    if (response.statusCode == 403) {
      throw Exception('ليس لديك صلاحية اعتماد وترحيل هذه الفاتورة');
    }

    Map<String, dynamic>? parsed;
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        parsed = decoded;
      }
    } catch (_) {
      parsed = null;
    }

    final msg = parsed?['message']?.toString() ?? 'فشل اعتماد وترحيل الفاتورة';
    throw Exception('$msg (status: ${response.statusCode})');
  }

  Future<Map<String, dynamic>> rejectInvoice(int invoiceId, {String? reason}) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/invoices/$invoiceId/reject'),
      body: json.encode({'reason': reason ?? ''}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    Map<String, dynamic>? parsed;
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    final msg = parsed?['message']?.toString() ?? 'فشل رفض الفاتورة';
    throw Exception('$msg (status: ${response.statusCode})');
  }

  Future<Map<String, dynamic>> getPendingActions() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/pending-actions'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    return {
      'pending_reservations': [],
      'pending_invoices': [],
      'total_pending_reservations': 0,
      'total_pending_invoices': 0,
    };
  }

  /// Post a single journal entry
  Future<Map<String, dynamic>> postJournalEntry(
    int entryId,
    String postedBy,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/journal-entries/post/$entryId'),
      body: json.encode({'posted_by': postedBy}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to post journal entry: ${response.body}');
    }
  }

  /// Post multiple journal entries
  Future<Map<String, dynamic>> postJournalEntriesBatch(
    List<int> entryIds,
    String postedBy,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/journal-entries/post-batch'),
      body: json.encode({'entry_ids': entryIds, 'posted_by': postedBy}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to post journal entries batch: ${response.body}');
    }
  }

  /// Unpost a journal entry
  Future<Map<String, dynamic>> unpostJournalEntry(int entryId) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/journal-entries/unpost/$entryId'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to unpost journal entry: ${response.body}');
    }
  }

  /// Unpost multiple journal entries (batch)
  Future<Map<String, dynamic>> unpostJournalEntriesBatch(
    List<int> entryIds,
  ) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/journal-entries/unpost-batch'),
      body: json.encode({'entry_ids': entryIds}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        'Failed to unpost journal entries batch: ${response.body}',
      );
    }
  }

  /// Delete an unposted journal entry (soft delete on backend)
  Future<Map<String, dynamic>> deleteUnpostedJournalEntry(
    int entryId, {
    String? reason,
  }) async {
    final base = Uri.parse('$_baseUrl/journal-entries/$entryId');
    final uri = (reason == null || reason.trim().isEmpty)
        ? base
        : base.replace(queryParameters: {'reason': reason.trim()});

    final response = await _authedDelete(uri);

    if (response.statusCode == 401) {
      throw Exception('انتهت صلاحية الجلسة. الرجاء تسجيل الدخول مرة أخرى');
    }
    if (response.statusCode == 403) {
      throw Exception('ليس لديك صلاحية حذف القيود');
    }

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return {'success': true};
    }

    Map<String, dynamic>? parsed;
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {
      parsed = null;
    }

    final msg = parsed?['message']?.toString() ?? 'فشل حذف القيد';
    throw Exception('$msg (status: ${response.statusCode})');
  }

  // ==========================================
  // 📋 Audit Log APIs
  // ==========================================

  /// Get audit logs with optional filters
  Future<Map<String, dynamic>> getAuditLogs({
    int limit = 100,
    String? userName,
    String? action,
    String? entityType,
    int? entityId,
    bool? success,
    String? fromDate,
    String? toDate,
  }) async {
    final queryParams = <String, String>{'limit': limit.toString()};

    if (userName != null) queryParams['user_name'] = userName;
    if (action != null) queryParams['action'] = action;
    if (entityType != null) queryParams['entity_type'] = entityType;
    if (entityId != null) queryParams['entity_id'] = entityId.toString();
    if (success != null) queryParams['success'] = success.toString();
    if (fromDate != null) queryParams['from_date'] = fromDate;
    if (toDate != null) queryParams['to_date'] = toDate;

    final token = await _requireAuthToken();
    final uri = Uri.parse(
      '$_baseUrl/audit-logs',
    ).replace(queryParameters: queryParams);
    final response = await http.get(uri, headers: _jsonHeaders(token: token));

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load audit logs');
    }
  }

  /// Get audit log detail
  Future<Map<String, dynamic>> getAuditLogDetail(int logId) async {
    final token = await _requireAuthToken();

    final response = await http.get(
      Uri.parse('$_baseUrl/audit-logs/$logId'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load audit log detail');
    }
  }

  /// Get audit logs by entity
  Future<Map<String, dynamic>> getAuditLogsByEntity(
    String entityType,
    int entityId,
  ) async {
    final token = await _requireAuthToken();

    final response = await http.get(
      Uri.parse('$_baseUrl/audit-logs/entity/$entityType/$entityId'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load audit logs by entity');
    }
  }

  /// Get audit logs by user
  Future<Map<String, dynamic>> getAuditLogsByUser(
    String userName, {
    int limit = 100,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/audit-logs/user/$userName',
    ).replace(queryParameters: {'limit': limit.toString()});
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load audit logs by user');
    }
  }

  /// Get failed audit logs
  Future<Map<String, dynamic>> getFailedAuditLogs({int limit = 50}) async {
    final uri = Uri.parse(
      '$_baseUrl/audit-logs/failed',
    ).replace(queryParameters: {'limit': limit.toString()});
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load failed audit logs');
    }
  }

  /// Get audit log statistics
  Future<Map<String, dynamic>> getAuditStats() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/audit-logs/stats'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load audit stats');
    }
  }

  // ==========================================
  // 🧾 Shift Closing APIs
  // ==========================================

  Future<Map<String, dynamic>> getShiftClosingSummary({
    String? from,
    String? to,
  }) async {
    final queryParams = <String, String>{};
    if (from != null) queryParams['from'] = from;
    if (to != null) queryParams['to'] = to;

    final uri = Uri.parse(
      '$_baseUrl/shift-closing/summary',
    ).replace(queryParameters: queryParams.isEmpty ? null : queryParams);
    final response = await _authedGet(uri);

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception('Failed to load shift closing summary');
  }

  Future<Map<String, dynamic>> submitShiftClosingReport({
    required List<Map<String, dynamic>> entries,
    String? from,
    String? to,
    String? notes,
    bool? settleCash,
    double? openingCashAmount,
    Map<String, double>? goldActuals,
  }) async {
    final payload = <String, dynamic>{'entries': entries};
    if (from != null) payload['from'] = from;
    if (to != null) payload['to'] = to;
    if (notes != null && notes.trim().isNotEmpty) {
      payload['notes'] = notes.trim();
    }

    if (settleCash == true) payload['settle_cash'] = true;
    if (openingCashAmount != null && openingCashAmount > 0) {
      payload['opening_cash_amount'] = openingCashAmount;
    }

    if (goldActuals != null && goldActuals.isNotEmpty) {
      payload['gold_actuals'] = {
        for (final e in goldActuals.entries) e.key: e.value,
      };
    }

    final response = await _authedPost(
      Uri.parse('$_baseUrl/shift-closing/close'),
      body: json.encode(payload),
    );

    if (response.statusCode == 201 || response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception('Failed to submit shift closing report');
  }

  // ==========================================
  // 🔐 Authentication & Authorization Methods
  // ==========================================

  /// Login user with JWT authentication and get token
  Future<Map<String, dynamic>> loginWithToken(
    String username,
    String password,
  ) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'username': username, 'password': password}),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل تسجيل الدخول');
    }
  }

  /// Username recovery (public). Returns a generic success message.
  /// In development, backend may return `debug_username` when enabled.
  Future<Map<String, dynamic>> forgotUsername({
    required String identifier,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/auth/forgot-username'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'identifier': identifier}),
    );

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return {'message': decoded.toString()};
    }

    throw Exception(_readApiErrorMessage(response, 'فشل استعادة اسم المستخدم'));
  }

  /// Password reset request (public). Returns a generic success message.
  /// In development, backend may return `debug_otp` when enabled.
  Future<Map<String, dynamic>> forgotPassword({
    required String identifier,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/auth/forgot-password'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'identifier': identifier}),
    );

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return {'message': decoded.toString()};
    }

    throw Exception(
      _readApiErrorMessage(response, 'فشل إرسال رمز إعادة التعيين'),
    );
  }

  /// Confirm password reset with OTP/token (public).
  Future<Map<String, dynamic>> confirmPasswordReset({
    required String otpOrToken,
    required String newPassword,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/auth/password-reset/confirm'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'otp': otpOrToken, 'new_password': newPassword}),
    );

    if (response.statusCode == 200) {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      return {'message': decoded.toString()};
    }

    throw Exception(_readApiErrorMessage(response, 'فشل تأكيد إعادة التعيين'));
  }

  /// Refresh access token using refresh token (rotating).
  Future<Map<String, dynamic>> refreshAccessToken(String refreshToken) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/auth/refresh'),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: json.encode({'refresh_token': refreshToken}),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }

    final error = json.decode(utf8.decode(response.bodyBytes));
    throw Exception(error['message'] ?? 'فشل تحديث الجلسة');
  }

  /// Logout server-side (blacklist access token + revoke refresh token).
  Future<void> logoutServerSide({String? refreshToken}) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/auth/logout'),
      body: json.encode({
        if (refreshToken != null && refreshToken.isNotEmpty)
          'refresh_token': refreshToken,
      }),
    );

    if (response.statusCode != 200) {
      // Keep logout best-effort from the client perspective.
      if (kDebugMode) {
        debugPrint('logoutServerSide failed: ${response.body}');
      }
    }
  }

  /// Get current user info
  Future<Map<String, dynamic>> getCurrentUser(String token) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/auth/me'),
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to get current user');
    }
  }

  /// Change password
  Future<Map<String, dynamic>> changePassword(
    String token,
    String oldPassword,
    String newPassword,
  ) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/auth/change-password'),
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
      body: json.encode({
        'old_password': oldPassword,
        'new_password': newPassword,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل تغيير كلمة المرور');
    }
  }

  /// Get all roles
  Future<Map<String, dynamic>> getRoles(
    String token, {
    bool includeUsers = false,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/roles',
    ).replace(queryParameters: {'include_users': includeUsers.toString()});

    var response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load roles');
    }
  }

  /// Get role by ID
  Future<Map<String, dynamic>> getRole(String token, int roleId) async {
    final uri = Uri.parse('$_baseUrl/roles/$roleId');
    var response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load role');
    }
  }

  /// Create new role
  Future<Map<String, dynamic>> createRole(
    String token,
    String name,
    String nameAr,
    String? description,
    List<int> permissionIds,
  ) async {
    final uri = Uri.parse('$_baseUrl/roles');
    final body = json.encode({
      'name': name,
      'name_ar': nameAr,
      'description': description,
      'permission_ids': permissionIds,
    });

    var response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
      body: body,
    );

    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
        body: body,
      );
    }

    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل إنشاء الدور');
    }
  }

  /// Update role
  Future<Map<String, dynamic>> updateRole(
    String token,
    int roleId,
    Map<String, dynamic> roleData,
  ) async {
    final uri = Uri.parse('$_baseUrl/roles/$roleId');
    final body = json.encode(roleData);

    var response = await http.put(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
      body: body,
    );

    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.put(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
        body: body,
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل تحديث الدور');
    }
  }

  /// Delete role
  Future<Map<String, dynamic>> deleteRole(String token, int roleId) async {
    final uri = Uri.parse('$_baseUrl/roles/$roleId');
    var response = await http.delete(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.delete(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل حذف الدور');
    }
  }

  /// Get all permissions
  Future<Map<String, dynamic>> getPermissions(
    String token, {
    String? category,
  }) async {
    final uri = category != null
        ? Uri.parse(
            '$_baseUrl/permissions',
          ).replace(queryParameters: {'category': category})
        : Uri.parse('$_baseUrl/permissions');

    var response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load permissions');
    }
  }

  /// Manage user roles (add or remove)
  Future<Map<String, dynamic>> manageUserRoles(
    String token,
    int userId,
    String action, // 'add' or 'remove'
    List<int> roleIds,
  ) async {
    final uri = Uri.parse('$_baseUrl/users/$userId/roles');
    final body = json.encode({'action': action, 'role_ids': roleIds});

    var response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
      body: body,
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
        body: body,
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل إدارة أدوار المستخدم');
    }
  }

  /// Get user permissions (legacy token-based endpoint)
  ///
  /// Note: The newer permissions system uses JWT auto-refresh + in-flight
  /// token handling. Prefer the newer `getUserPermissions(int userId)` method
  /// near the bottom of this file.
  Future<Map<String, dynamic>> getUserPermissionsWithToken(
    String token,
    int userId,
  ) async {
    final uri = Uri.parse('$_baseUrl/users/$userId/permissions');
    var response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to load user permissions');
    }
  }

  // ==========================================
  // 👤 إدارة المستخدمين (JWT)
  // ==========================================

  /// List users with JWT authentication
  Future<Map<String, dynamic>> listUsersWithAuth(
    String token, {
    String? search,
    bool? isActive,
    String? role,
    int page = 1,
    int perPage = 50,
  }) async {
    final queryParams = <String, String>{
      'page': page.toString(),
      'per_page': perPage.toString(),
    };

    if (search != null && search.isNotEmpty) {
      queryParams['search'] = search;
    }
    if (isActive != null) {
      queryParams['is_active'] = isActive.toString();
    }
    if (role != null && role.isNotEmpty) {
      queryParams['role'] = role;
    }

    final uri = Uri.parse(
      '$_baseUrl/users',
    ).replace(queryParameters: queryParams);

    var response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل تحميل المستخدمين');
    }
  }

  /// Get single user by ID with JWT
  Future<Map<String, dynamic>> getUserById(String token, int userId) async {
    final uri = Uri.parse('$_baseUrl/users/$userId');
    var response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل تحميل المستخدم');
    }
  }

  /// Create new user with JWT
  Future<Map<String, dynamic>> createUserWithAuth(
    String token, {
    required String username,
    required String password,
    required String fullName,
    bool isAdmin = false,
    bool isActive = true,
    List<int>? roleIds,
  }) async {
    final uri = Uri.parse('$_baseUrl/users');
    final body = json.encode({
      'username': username,
      'password': password,
      'full_name': fullName,
      'is_admin': isAdmin,
      'is_active': isActive,
      if (roleIds != null) 'role_ids': roleIds,
    });

    var response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
      body: body,
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
        body: body,
      );
    }

    if (response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل إنشاء المستخدم');
    }
  }

  /// Update user with JWT
  Future<Map<String, dynamic>> updateUserWithAuth(
    String token,
    int userId, {
    String? fullName,
    bool? isAdmin,
    bool? isActive,
    String? password,
  }) async {
    final body = <String, dynamic>{};
    if (fullName != null) body['full_name'] = fullName;
    if (isAdmin != null) body['is_admin'] = isAdmin;
    if (isActive != null) body['is_active'] = isActive;
    if (password != null && password.isNotEmpty) body['password'] = password;

    final uri = Uri.parse('$_baseUrl/users/$userId');
    final encodedBody = json.encode(body);
    var response = await http.put(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
      body: encodedBody,
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.put(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
        body: encodedBody,
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل تحديث المستخدم');
    }
  }

  /// Delete user with JWT
  Future<Map<String, dynamic>> deleteUserWithAuth(
    String token,
    int userId,
  ) async {
    final uri = Uri.parse('$_baseUrl/users/$userId');
    var response = await http.delete(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.delete(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل حذف المستخدم');
    }
  }

  /// Toggle user active status with JWT
  Future<Map<String, dynamic>> toggleUserActiveWithAuth(
    String token,
    int userId,
  ) async {
    final uri = Uri.parse('$_baseUrl/users/$userId/toggle-active');
    var response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 401) {
      final refreshed = await _refreshAccessTokenFromStorage();
      response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $refreshed',
        },
      );
    }

    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['message'] ?? 'فشل تغيير حالة المستخدم');
    }
  }

  // ==========================================
  // 🔐 Helpers: Token Handling
  // ==========================================

  Future<String> _requireAuthToken() async {
    final prefs = await SharedPreferences.getInstance();
    // Try canonical keys first, then fall back to older/prefixed keys.
    final jwtToken =
        prefs.getString('jwt_token') ??
        prefs.getString('flutter.jwt_token') ??
        prefs.getString('auth_token') ??
        prefs.getString('flutter.auth_token');

    if (jwtToken != null && jwtToken.isNotEmpty) {
      // If we found a prefixed/legacy token, migrate it to the canonical key(s).
      await prefs.setString('jwt_token', jwtToken);
      await prefs.setString('flutter.jwt_token', jwtToken);

      // Proactively refresh if token is expired/near-expiry to avoid 401s.
      if (_isJwtExpiringSoon(jwtToken)) {
        try {
          return await _refreshAccessTokenFromStorage();
        } catch (_) {
          // Fall back to existing token; request wrapper may retry or caller may handle 401.
          return jwtToken;
        }
      }
      return jwtToken;
    }

    throw Exception(
      'يجب تسجيل الدخول أولاً. الرجاء تسجيل الخروج والدخول مرة أخرى',
    );
  }

  Future<String?> getStoredRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('refresh_token');
    if (token != null && token.isNotEmpty) {
      return token;
    }
    return null;
  }

  Future<String?> getStoredToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token =
        prefs.getString('jwt_token') ??
        prefs.getString('flutter.jwt_token') ??
        prefs.getString('auth_token') ??
        prefs.getString('flutter.auth_token');
    if (token != null && token.isNotEmpty) {
      return token;
    }
    return null;
  }

  Map<String, String> _jsonHeaders({String? token}) {
    return {
      'Content-Type': 'application/json; charset=UTF-8',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  // ==========================================
  // 🎁 Bonus System APIs
  // ==========================================

  Future<List<dynamic>> getBonusRules({bool? isActive}) async {
    final token = await _requireAuthToken();
    final queryParams = isActive != null ? '?is_active=$isActive' : '';
    final response = await http.get(
      Uri.parse('$_baseUrl/bonus-rules$queryParams'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode == 200) {
      final parsed = json.decode(utf8.decode(response.bodyBytes));
      // API يعيد {'success': true, 'rules': [...], 'count': n}
      if (parsed is Map<String, dynamic> && parsed['rules'] is List) {
        return parsed['rules'] as List<dynamic>;
      }
      if (parsed is List) return parsed; // توافق مع استجابة قديمة
      throw Exception('تنسيق غير متوقع لقواعد المكافآت');
    } else {
      throw Exception('فشل في تحميل قواعد المكافآت');
    }
  }

  Future<Map<String, dynamic>> createBonusRule(
    Map<String, dynamic> data,
  ) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/bonus-rules'),
      headers: _jsonHeaders(token: token),
      body: json.encode(data),
    );
    if (response.statusCode == 201) {
      final parsed = json.decode(utf8.decode(response.bodyBytes));
      // API يعيد {'success': true, 'rule': {...}}
      if (parsed is Map<String, dynamic> && parsed['rule'] is Map) {
        return parsed['rule'] as Map<String, dynamic>;
      }
      return parsed as Map<String, dynamic>;
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(
        error is Map<String, dynamic>
            ? (error['error'] ??
                  error['message'] ??
                  'فشل في إنشاء قاعدة المكافأة')
            : 'فشل في إنشاء قاعدة المكافأة',
      );
    }
  }

  Future<void> updateBonusRule(int id, Map<String, dynamic> data) async {
    final token = await _requireAuthToken();
    final response = await http.put(
      Uri.parse('$_baseUrl/bonus-rules/$id'),
      headers: _jsonHeaders(token: token),
      body: json.encode(data),
    );
    if (response.statusCode != 200) {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(
        error is Map<String, dynamic>
            ? (error['error'] ??
                  error['message'] ??
                  'فشل في تحديث قاعدة المكافأة')
            : 'فشل في تحديث قاعدة المكافأة',
      );
    }
  }

  Future<void> deleteBonusRule(int id) async {
    final token = await _requireAuthToken();
    final response = await http.delete(
      Uri.parse('$_baseUrl/bonus-rules/$id'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode != 200) {
      throw Exception('فشل في حذف قاعدة المكافأة');
    }
  }

  Future<List<dynamic>> getInvoiceTypes() async {
    // ✅ Prefer backend list (includes 'شراء من عميل'/'شراء')
    // Fallback to a safe static list for older servers.
    try {
      final token = await _requireAuthToken();
      final response = await http.get(
        Uri.parse('$_baseUrl/invoice-types'),
        headers: _jsonHeaders(token: token),
      );

      if (response.statusCode == 200) {
        final parsed = json.decode(utf8.decode(response.bodyBytes));
        if (parsed is Map<String, dynamic> && parsed['invoice_types'] is List) {
          return parsed['invoice_types'] as List<dynamic>;
        }
        if (parsed is List) return parsed;
      }
    } catch (_) {
      // ignore and fallback
    }

    return [
      'بيع',
      'شراء من عميل',
      'مرتجع بيع',
      'مرتجع شراء',
      'شراء',
      'مرتجع شراء (مورد)',
    ];
  }

  Future<List<dynamic>> getBonuses({
    int? employeeId,
    String? status,
    String? dateFrom,
    String? dateTo,
  }) async {
    final token = await _requireAuthToken();
    final queryParams = <String>[];
    if (employeeId != null) queryParams.add('employee_id=$employeeId');
    if (status != null) queryParams.add('status=$status');
    if (dateFrom != null) queryParams.add('date_from=$dateFrom');
    if (dateTo != null) queryParams.add('date_to=$dateTo');

    final query = queryParams.isNotEmpty ? '?${queryParams.join('&')}' : '';
    final response = await http.get(
      Uri.parse('$_baseUrl/bonuses$query'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode == 200) {
      final parsed = json.decode(utf8.decode(response.bodyBytes));
      if (parsed is Map<String, dynamic> && parsed['bonuses'] is List) {
        return parsed['bonuses'] as List<dynamic>;
      }
      if (parsed is List) return parsed;
      throw Exception('تنسيق غير متوقع للمكافآت');
    } else {
      throw Exception('فشل في تحميل المكافآت');
    }
  }

  Future<Map<String, dynamic>> createBonus(Map<String, dynamic> data) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/bonuses'),
      headers: _jsonHeaders(token: token),
      body: json.encode(data),
    );
    if (response.statusCode == 200 || response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? error['message'] ?? 'فشل في إنشاء المكافأة');
    }
  }

  Future<Map<String, dynamic>> calculateBonuses({
    String? dateFrom,
    String? dateTo,
    int? employeeId,
  }) async {
    final token = await _requireAuthToken();
    final data = <String, dynamic>{};
    // ✅ استخدم مفاتيح backend الحالية (period_start/period_end) مع الحفاظ على التوافق
    if (dateFrom != null) {
      data['period_start'] = dateFrom;
      data['date_from'] = dateFrom; // توافق عكسي إذا كان الخادم قديماً
    }
    if (dateTo != null) {
      data['period_end'] = dateTo;
      data['date_to'] = dateTo;
    }
    if (employeeId != null) data['employee_id'] = employeeId;

    final response = await http.post(
      Uri.parse('$_baseUrl/bonuses/calculate'),
      headers: _jsonHeaders(token: token),
      body: json.encode(data),
    );
    if (response.statusCode == 200 || response.statusCode == 201) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'فشل في حساب المكافآت');
    }
  }

  Future<void> approveBonus(int id) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/bonuses/$id/approve'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode != 200) {
      final bodyText = utf8.decode(response.bodyBytes);
      String? cleanMessage;
      try {
        final decoded = json.decode(bodyText);
        if (decoded is Map) {
          final msg = decoded['message'] ?? decoded['error'];
          if (msg != null) cleanMessage = msg.toString();
        }
      } catch (_) {
        // ignore JSON parsing errors
      }
      throw Exception(
        cleanMessage ?? (bodyText.isNotEmpty ? bodyText : 'فشل في الموافقة على المكافأة'),
      );
    }
  }

  Future<void> rejectBonus(int id) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/bonuses/$id/reject'),
      headers: _jsonHeaders(token: token),
    );
    if (response.statusCode != 200) {
      final bodyText = utf8.decode(response.bodyBytes);
      String? cleanMessage;
      try {
        final decoded = json.decode(bodyText);
        if (decoded is Map) {
          final msg = decoded['message'] ?? decoded['error'];
          if (msg != null) cleanMessage = msg.toString();
        }
      } catch (_) {
        // ignore JSON parsing errors
      }
      throw Exception(
        cleanMessage ?? (bodyText.isNotEmpty ? bodyText : 'فشل في رفض المكافأة'),
      );
    }
  }

  Future<void> payBonus(
    int id, {
    required int safeBoxId,
    String paymentMethod = 'cash',
  }) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/bonuses/$id/pay'),
      headers: _jsonHeaders(token: token),
      body: json.encode({
        'safe_box_id': safeBoxId,
        'payment_method': paymentMethod,
        'created_by': 'admin',
      }),
    );
    if (response.statusCode != 200) {
      final bodyText = utf8.decode(response.bodyBytes);
      String? cleanMessage;
      try {
        final decoded = json.decode(bodyText);
        if (decoded is Map) {
          final msg = decoded['message'] ?? decoded['error'];
          if (msg != null) cleanMessage = msg.toString();
        }
      } catch (_) {
        // ignore JSON parsing errors
      }
      throw Exception(
        cleanMessage ?? (bodyText.isNotEmpty ? bodyText : 'فشل في صرف المكافأة'),
      );
    }
  }

  Future<void> updateBonus(int id, Map<String, dynamic> data) async {
    final token = await _requireAuthToken();
    final response = await http.put(
      Uri.parse('$_baseUrl/bonuses/$id'),
      headers: _jsonHeaders(token: token),
      body: json.encode(data),
    );
    if (response.statusCode != 200) {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'فشل في تحديث المكافأة');
    }
  }

  Future<Map<String, dynamic>> bulkApproveBonuses(List<int> ids) async {
    final token = await _requireAuthToken();
    final response = await http.post(
      Uri.parse('$_baseUrl/bonuses/bulk-approve'),
      headers: _jsonHeaders(token: token),
      // يدعم مفاتيح backend الحالية (ids) مع الحفاظ على توافق الاسم السابق (bonus_ids)
      body: json.encode({'ids': ids, 'bonus_ids': ids}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final bodyText = utf8.decode(response.bodyBytes);
      try {
        final decoded = json.decode(bodyText);
        if (decoded is Map) {
          final message = decoded['message'] ?? decoded['error'];
          if (message != null) throw Exception(message.toString());
        }
      } catch (_) {
        // ignore JSON parsing errors and fall back to raw text
      }
      throw Exception(
        bodyText.isNotEmpty ? bodyText : 'فشل في الموافقة الجماعية',
      );
    }
  }

  Future<Map<String, dynamic>> bulkRejectBonuses(
    List<int> ids, {
    String? reason,
  }) async {
    // يدعم مفاتيح backend الحالية (ids) مع الحفاظ على توافق الاسم السابق (bonus_ids)
    final data = <String, dynamic>{'ids': ids, 'bonus_ids': ids};
    if (reason != null) data['reason'] = reason;

    final response = await _authedPost(
      Uri.parse('$_baseUrl/bonuses/bulk-reject'),
      body: json.encode(data),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final bodyText = utf8.decode(response.bodyBytes);
      try {
        final decoded = json.decode(bodyText);
        if (decoded is Map) {
          final message = decoded['message'] ?? decoded['error'];
          if (message != null) throw Exception(message.toString());
        }
      } catch (_) {
        // ignore JSON parsing errors and fall back to raw text
      }
      throw Exception(bodyText.isNotEmpty ? bodyText : 'فشل في الرفض الجماعي');
    }
  }

  Future<Map<String, dynamic>> getBonusesPayablesReport() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/reports/bonuses-payables'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('فشل في تحميل تقرير المكافآت المستحقة');
    }
  }

  // ==========================================
  // 🔐 Security & Authentication APIs
  // ==========================================

  Future<Map<String, dynamic>> setup2FA() async {
    final response = await _authedPost(Uri.parse('$_baseUrl/auth/2fa/setup'));
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'فشل في إعداد المصادقة الثنائية');
    }
  }

  Future<Map<String, dynamic>> verify2FA(String code) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/auth/2fa/verify'),
      body: json.encode({'code': code}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'رمز التحقق غير صحيح');
    }
  }

  Future<void> disable2FA() async {
    final response = await _authedPost(Uri.parse('$_baseUrl/auth/2fa/disable'));
    if (response.statusCode != 200) {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'فشل في تعطيل المصادقة الثنائية');
    }
  }

  Future<Map<String, dynamic>> getPasswordPolicy() async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/auth/password-policy'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('فشل في تحميل سياسة كلمات المرور');
    }
  }

  Future<void> updatePasswordPolicy(Map<String, dynamic> data) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/auth/password-policy'),
      body: json.encode(data),
    );
    if (response.statusCode != 200) {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'فشل في تحديث سياسة كلمات المرور');
    }
  }

  Future<List<dynamic>> getSessions({bool includeAll = false}) async {
    final query = includeAll ? '?include_all=true' : '';
    final response = await _authedGet(
      Uri.parse('$_baseUrl/auth/sessions$query'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('فشل في تحميل الجلسات');
    }
  }

  Future<void> terminateSession(String sessionId) async {
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/auth/sessions/$sessionId'),
    );
    if (response.statusCode != 200) {
      throw Exception('فشل في إنهاء الجلسة');
    }
  }

  Future<void> terminateAllSessions() async {
    final response = await _authedDelete(
      Uri.parse('$_baseUrl/auth/sessions/all'),
    );
    if (response.statusCode != 200) {
      throw Exception('فشل في إنهاء جميع الجلسات');
    }
  }

  // ==========================================
  // 📊 Advanced Reports APIs
  // ==========================================

  Future<Map<String, dynamic>> getJson(
    String endpoint, {
    Map<String, String>? queryParameters,
  }) async {
    var uri = Uri.parse('$_baseUrl/$endpoint');
    if (queryParameters != null && queryParameters.isNotEmpty) {
      uri = uri.replace(queryParameters: queryParameters);
    }
    final response = await _authedGet(uri);
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('فشل في تحميل البيانات من $endpoint');
    }
  }

  // ==========================================
  // 🔐 Permissions APIs
  // ==========================================

  String _readApiErrorMessage(http.Response response, String fallback) {
    try {
      final decoded = json.decode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        final message = decoded['message'] ?? decoded['error'];
        if (message is String && message.trim().isNotEmpty) {
          return message;
        }
      }
    } catch (_) {
      // ignore
    }
    return fallback;
  }

  /// احصل على قائمة الأدوار المتاحة
  Future<List<dynamic>> getPermissionRoles() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/permissions/roles'));
    if (response.statusCode == 200) {
      final data = json.decode(utf8.decode(response.bodyBytes));
      return data['roles'] as List<dynamic>;
    } else {
      throw Exception(_readApiErrorMessage(response, 'فشل في تحميل الأدوار'));
    }
  }

  /// احصل على جميع الصلاحيات مصنفة
  Future<List<dynamic>> getAllPermissions() async {
    final response = await _authedGet(Uri.parse('$_baseUrl/permissions/all'));
    if (response.statusCode == 200) {
      final data = json.decode(utf8.decode(response.bodyBytes));
      return data['categories'] as List<dynamic>;
    } else {
      throw Exception(_readApiErrorMessage(response, 'فشل في تحميل الصلاحيات'));
    }
  }

  /// احصل على الصلاحيات الافتراضية لدور معين
  Future<Map<String, dynamic>> getRoleDefaultPermissions(
    String roleCode,
  ) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/permissions/role/$roleCode'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(utf8.decode(response.bodyBytes));
      return data['role'] as Map<String, dynamic>;
    } else {
      throw Exception(
        _readApiErrorMessage(response, 'فشل في تحميل صلاحيات الدور'),
      );
    }
  }

  /// احصل على صلاحيات مستخدم معين
  Future<Map<String, dynamic>> getUserPermissions(int userId) async {
    final response = await _authedGet(
      Uri.parse('$_baseUrl/users/$userId/permissions'),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception(
        _readApiErrorMessage(response, 'فشل في تحميل صلاحيات المستخدم'),
      );
    }
  }

  /// تحديث صلاحيات مستخدم
  Future<Map<String, dynamic>> updateUserPermissions(
    int userId,
    Map<String, dynamic> data,
  ) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/users/$userId/permissions'),
      body: json.encode(data),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'فشل في تحديث الصلاحيات');
    }
  }

  /// تحديث دور مستخدم
  Future<Map<String, dynamic>> updateUserRole(
    int userId,
    String role, {
    bool resetPermissions = false,
  }) async {
    final response = await _authedPut(
      Uri.parse('$_baseUrl/users/$userId/role'),
      body: json.encode({'role': role, 'reset_permissions': resetPermissions}),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    } else {
      final error = json.decode(utf8.decode(response.bodyBytes));
      throw Exception(error['error'] ?? 'فشل في تحديث الدور');
    }
  }

  // ────────────────────────────────────────────────────────────
  // Goal Achievements — إنجازات الأهداف
  // ────────────────────────────────────────────────────────────

  /// يرجع قائمة الإنجازات التي لم يشاهدها المستخدم بعد
  Future<List<Map<String, dynamic>>> getUnseenAchievements() async {
    try {
      final response =
          await _authedGet(Uri.parse('$_baseUrl/achievements/unseen'));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final list = data['achievements'] as List? ?? [];
        return list.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('❌ Error loading achievements: $e');
      return [];
    }
  }

  /// يضع علامة "تمت المشاهدة" على الإنجاز
  Future<void> markAchievementSeen(int id) async {
    try {
      await _authedPost(
        Uri.parse('$_baseUrl/achievements/$id/mark-seen'),
        body: '{}',
      );
    } catch (e) {
      debugPrint('❌ Error marking achievement seen: $e');
    }
  }

  /// يفحص أداء الموظف المرتبط بالمستخدم الحالي ويُنشئ
  /// GoalAchievement تلقائياً إن تحقق الهدف الشخصي.
  /// يُستدعى عند كل عودة للشاشة الرئيسية.
  Future<List<Map<String, dynamic>>> checkGoalProgress() async {
    try {
      final response = await _authedPost(
        Uri.parse('$_baseUrl/achievements/check-progress'),
        body: '{}',
      );
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final list = data['achievements'] as List? ?? [];
        return list.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('❌ Error checking goal progress: $e');
      return [];
    }
  }

  /// تحديث أهداف الأداء الشخصية للموظف
  Future<Map<String, dynamic>> updateEmployeeGoals(
    int employeeId,
    Map<String, dynamic> goals,
  ) async {
    final token = await _requireAuthToken();
    // إرسال الـ payload كاملاً بما فيه null لإمكانية مسح القيم
    final body = <String, dynamic>{};
    goals.forEach((key, value) {
      if (value is DateTime) {
        body[key] = value.toIso8601String();
      } else {
        body[key] = value;
      }
    });
    final response = await http.put(
      Uri.parse('$_baseUrl/employees/$employeeId/goals'),
      headers: _jsonHeaders(token: token),
      body: json.encode(body),
    );
    if (response.statusCode == 200) {
      return json.decode(utf8.decode(response.bodyBytes));
    }
    throw Exception('فشل تحديث أهداف الموظف: ${response.statusCode}');
  }

  /// 🎯 POST /employees/{id}/goal-check
  /// يتحقق من الأهداف الشخصية للموظف ويعيد الإنجازات غير المشاهدة.
  Future<List<Map<String, dynamic>>> checkEmployeeGoals(int employeeId) async {
    final response = await _authedPost(
      Uri.parse('$_baseUrl/employees/$employeeId/goal-check'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(utf8.decode(response.bodyBytes));
      final list = data['achievements'] as List? ?? [];
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// وضع علامة "مشاهَد" على إنجاز هدف شخصي
  Future<void> markGoalAchievementSeen(int achievementId) async {
    try {
      await _authedPost(
        Uri.parse('$_baseUrl/goal-achievements/$achievementId/mark-seen'),
        body: '{}',
      );
    } catch (e) {
      debugPrint('❌ markGoalAchievementSeen error: $e');
    }
  }
}

