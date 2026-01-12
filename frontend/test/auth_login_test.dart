import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';

void main() {
  group('Auth API integration', () {
    final api = ApiService(baseUrl: 'http://127.0.0.1:8001/api');

    test(
      'loginWithToken returns admin user',
      () async {
        // NOTE: flutter_test binds HttpClient and blocks real network.
        // This test is meant as an integration check; run it via an integration harness.
        final response = await api.loginWithToken('admin', 'admin123');
        expect(response['success'], isTrue);
        expect(response['user'], isA<Map<String, dynamic>>());
        expect(response['user']['username'], equals('admin'));
        expect(
          response['token'],
          isA<String>().having((t) => t.isNotEmpty, 'not empty', isTrue),
        );
      },
      skip: 'Requires real HTTP; flutter_test blocks network',
    );
  });
}
