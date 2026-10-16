import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UI-1 (ADR-049): a request the server refuses reaches the screen as an
/// [ApiException] -- the server's code and its words -- never as
/// «Exception: ...», an English «Failed to load ...», or the raw body of the
/// reply (an nginx page on a 502).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'jwt_token': 'token'});
  });

  /// Runs [call] against a server that answers every request with [status]
  /// and [body], and returns what it threw.
  Future<Object> refusal(
    Future<Object?> Function(ApiService api) call, {
    required int status,
    required String body,
    String contentType = 'application/json',
  }) async {
    Object? thrown;
    await http.runWithClient(
      () async {
        try {
          await call(ApiService(baseUrl: 'http://test'));
        } catch (e) {
          thrown = e;
        }
      },
      () => MockClient(
        (_) async => http.Response(
          body,
          status,
          headers: {'content-type': '$contentType; charset=utf-8'},
        ),
      ),
    );
    expect(thrown, isNotNull, reason: 'the call was to fail');
    return thrown!;
  }

  const refused = '{"error": "customer_in_use", "message": "العميل له فواتير"}';
  const nginx502 = '<html><head><title>502 Bad Gateway</title></head></html>';

  test("the server's message and its code, as the server said them", () async {
    final e = await refusal(
      (a) => a.getCustomers(),
      status: 409,
      body: refused,
    );
    expect(e, isA<ApiException>());
    expect((e as ApiException).code, 'customer_in_use');
    expect(e.statusCode, 409);
    expect('$e', 'العميل له فواتير');
  });

  test('a call that said «Failed to load …» says the server instead', () async {
    final e = await refusal((a) => a.getBranches(), status: 409, body: refused);
    expect(e, isA<ApiException>());
    expect('$e', 'العميل له فواتير');
  });

  test(
    'a page instead of an answer is not shown: it is said in Arabic',
    () async {
      for (final call in <Future<Object?> Function(ApiService)>[
        (a) => a.getCustomers(),
        (a) => a.getGoldCostingSnapshot(),
      ]) {
        final e = await refusal(
          call,
          status: 502,
          body: nginx502,
          contentType: 'text/html',
        );
        expect(e, isA<ApiException>());
        expect('$e', isNot(contains('<')));
        expect('$e', isNot(contains('Exception')));
        expect('$e', contains('502'));
      }
    },
  );

  test('a bare code is for the caller: the screen gets a sentence', () async {
    final e = await refusal(
      (a) => a.getCustomers(),
      status: 403,
      body: '{"error": "permission_denied"}',
    );
    expect((e as ApiException).code, 'permission_denied');
    expect('$e', isNot(contains('permission_denied')));
    expect('$e', contains('403'));
  });

  test(
    'with no words from the server, the call says what it was doing',
    () async {
      final e = await refusal(
        (a) => a.getSafeBoxesOverview(),
        status: 500,
        body: nginx502,
        contentType: 'text/html',
      );
      expect('$e', 'تعذّر تحميل الخزائن (500)');
    },
  );

  test('the client throws no bare Exception', () {
    final source = File('lib/api_service.dart').readAsStringSync();
    expect(RegExp(r'throw Exception\(').allMatches(source).length, 0);
  });
}
