// «تحقّق من بطاقة» (ADR-085 ت2 ج2): one label read -- its piece, its facts,
// where the books have it, its tag's state and generation in the server's
// words; an unsettled attempt's tag settled here by that very value.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/tag_check_screen.dart';
import 'package:frontend/theme/app_theme.dart';

const _active = '4B4A00020000000000000101';
const _stopped = '4B4A00010000000000000101';
const _attempt = '4B4A00010000000000000301';

class _Api extends ApiService {
  final resolved = <(int, Map<String, dynamic>)>[];
  bool settledOne = false;

  @override
  Future<Map<String, dynamic>> pieceByTag(String value) async {
    if (value == _active || (value == _attempt && settledOne)) {
      return {
        'piece': {'item_code': value == _active ? 'KJ-000101' : 'KJ-000301', 'weight': 12.40, 'stones_weight': 0.35,
                  'stones_kind': 'as_gold', 'in_stock': true, 'model': {'name': 'بنجرة الشمس'}, 'size': null},
        'tag': {'state': 'active', 'generation': value == _active ? 2 : 1},
        'location': {'name': 'الذهب المعروض'},
      };
    }
    if (value == _stopped) {
      throw const ApiException(statusCode: 404, code: 'tag_stopped',
          message: 'رقاقة ملغاة — القطعة KJ-000101 — الجيل 0001 — لا تُحتسب في الجرد',
          details: {'tag': {'state': 'stopped', 'item_code': 'KJ-000101', 'generation': 1}});
    }
    throw const ApiException(statusCode: 404, code: 'tag_unconfirmed',
        message: 'رقاقة من محاولة لم تُعتمد — القطعة KJ-000301 — الجيل 0001 — أتلفها',
        details: {'tag': {'state': 'unconfirmed', 'item_code': 'KJ-000301', 'attempt_id': 77, 'unsettled': true}});
  }

  @override
  Future<Map<String, dynamic>> resolvePrintAttempt(int attemptId, Map<String, dynamic> body) async {
    resolved.add((attemptId, body));
    settledOne = true;
    return {'job': {}};
  }
}

Future<void> _open(WidgetTester tester, _Api api) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: TagCheckScreen(api: api)));
  await tester.pumpAndSettle();
}

Future<void> _read(WidgetTester tester, String value) async {
  await tester.enterText(find.byKey(const Key('check-field')), '$value\n');
  await tester.pumpAndSettle();
}

String _said(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('an adopted tag: its piece, its facts, its place, its generation', (tester) async {
    await _open(tester, _Api());
    await _read(tester, _active);
    expect(find.text('KJ-000101'), findsOneWidget);
    expect(_said(tester, 'check-state-$_active'), 'رقاقة معتمدة — الجيل 0002');
    expect(find.text('12.40 جم · فصوص 0.35 جم · بنجرة الشمس'), findsOneWidget);
    expect(_said(tester, 'check-place-$_active'), 'مكانها في الدفاتر: الذهب المعروض');
  });

  testWidgets('a stopped tag is said in the server\'s words, nothing to settle', (tester) async {
    await _open(tester, _Api());
    await _read(tester, _stopped);
    expect(_said(tester, 'check-state-$_stopped'), 'رقاقة ملغاة — القطعة KJ-000101 — الجيل 0001 — لا تُحتسب في الجرد');
    expect(find.byKey(const Key('check-settle-$_stopped')), findsNothing);
  });

  testWidgets('an unsettled attempt\'s tag is settled by the value read, then said adopted', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _read(tester, _attempt);
    await tester.tap(find.byKey(const Key('check-settle-$_attempt')));
    await tester.pumpAndSettle();
    expect(api.resolved.single.$1, 77);
    expect(api.resolved.single.$2, {'read_value': _attempt}, reason: 'the reader\'s value; the server matches it');
    expect(_said(tester, 'check-state-$_attempt'), 'رقاقة معتمدة — الجيل 0001');
  });
}
