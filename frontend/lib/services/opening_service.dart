import 'dart:convert';

import '../api_service.dart';
import '../models/opening_models.dart';

/// The opening figures' API (ADR-044, TR-2). A refusal says the server's words.
class OpeningService {
  OpeningService(this._api);
  final ApiService _api;

  Future<Opening> load(int year) async =>
      _answer(await _api.authedGet('/opening/$year'));

  Future<Opening> enter(
    int year,
    int accountId, {
    required double cash,
    required Map<String, double> karats,
    required String source,
    String? treatment,
    String? note,
  }) async => _answer(
    await _api.authedPut(
      '/opening/$year/$accountId',
      body: jsonEncode({
        'cash': cash,
        'karats': karats,
        'source': source,
        'treatment': treatment,
        'note': note,
      }),
    ),
  );

  Future<Opening> approve(int year) async =>
      _answer(await _api.authedPost('/opening/$year/approve'));

  Opening _answer(dynamic resp) {
    final body = jsonDecode(resp.body as String);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return Opening.fromJson(body as Map<String, dynamic>);
    }
    throw OpeningRefusedException(
      (body is Map ? body['message'] ?? body['error'] : null)?.toString() ??
          'تعذّر الحفظ',
    );
  }
}

class OpeningRefusedException implements Exception {
  final String message;
  const OpeningRefusedException(this.message);
  @override
  String toString() => message;
}
