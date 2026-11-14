import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/reports/vat_returns_screen.dart';

/// «إقرارات ضريبة القيمة المضافة» (ADR-043 rule 5): the server's figures shown,
/// a period previewed, then filed after a confirmation -- and the list reloaded.

class _FakeApi extends ApiService {
  final filedCalls = <(String, String)>[];
  final previewFigures = <(num?, num?)>[];
  final fileFigures = <(num?, num?)>[];
  int listCalls = 0;
  final _filed = <Map<String, dynamic>>[
    {'start': '2026-04-01', 'end': '2026-06-30', 'output_vat': 0.0, 'input_vat': 10782.9,
     'net': -10782.9, 'entry_number': 'VAT-2026-00001', 'filed_by': 'admin'},
  ];

  @override
  Future<List<Map<String, dynamic>>> getVatReturns() async {
    listCalls++;
    return List.of(_filed);
  }

  @override
  Future<Map<String, dynamic>> previewVatReturn(String start, String end,
      {num? filedOutputVat, num? filedInputVat}) async {
    previewFigures.add((filedOutputVat, filedInputVat));
    if (filedOutputVat == null) {
      return {
        'start': start, 'end': end, 'output_vat': 0.0, 'input_vat': 8283.69, 'net': -8283.69,
        'books_output_vat': 0.0, 'books_input_vat': 8283.69, 'non_recoverable': 0.0,
        'lines': {'1400': -5739.67, '1410': -2544.02}, 'entry_number': null,
      };
    }
    // the server's as filed: the output it declares, all the books lack of it an
    // expense; the input as typed, against the books' 8,283.69 -- a difference
    // refuses the filing until it is recorded on its vouchers (14 Nov 2026)
    final input = filedInputVat ?? 8283.69;
    return {
      'start': start, 'end': end, 'output_vat': 22286.79, 'input_vat': input,
      'net': ((22286.79 - input) * 100).round() / 100,
      'books_output_vat': 0.0, 'books_input_vat': 8283.69, 'non_recoverable': 22286.79,
      'input_difference': ((input - 8283.69) * 100).round() / 100,
      'lines': {'1400': -5739.67, '1410': -2544.02, '5402': 22286.79}, 'entry_number': null,
    };
  }

  @override
  Future<Map<String, dynamic>> fileVatReturn(String start, String end,
      {num? filedOutputVat, num? filedInputVat}) async {
    filedCalls.add((start, end));
    fileFigures.add((filedOutputVat, filedInputVat));
    _filed.add({'start': start, 'end': end, 'output_vat': 0.0, 'input_vat': 8283.69, 'net': -8283.69,
                'entry_number': 'VAT-2026-00002'});
    return {'entry_number': 'VAT-2026-00002', 'net': -8283.69};
  }
}

void main() {
  testWidgets('a period is previewed, then filed after a confirmation', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: VatReturnsScreen(api: api)));
    await tester.pumpAndSettle();

    expect(find.text('2026-04-01 — 2026-06-30'), findsOneWidget, reason: 'the filed return');
    expect(find.textContaining('VAT-2026-00001'), findsOneWidget);

    await tester.tap(find.byKey(const Key('vat-return-preview')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('vat-return-net'))).data, '8,283.69',
        reason: "the server's net, unsigned");
    expect(find.textContaining('مستحقة لكم'), findsWidgets, reason: 'more input than output: due back');

    await tester.tap(find.byKey(const Key('vat-return-file')));
    await tester.pumpAndSettle();
    expect(api.filedCalls, isEmpty, reason: 'nothing before the confirmation');
    await tester.tap(find.byKey(const Key('vat-return-confirm')));
    await tester.pumpAndSettle();
    expect(api.filedCalls, hasLength(1));
    expect(api.listCalls, 2, reason: 'the list reloaded');
    expect(find.textContaining('VAT-2026-00002'), findsWidgets);
  });

  testWidgets('the return as filed: its figures sent, an input the books lack shown and not filed, '
      'the input as in the books filed as previewed', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);     // a phone
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: VatReturnsScreen(api: api)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('vat-return-filed-output')), '٢٢٢٨٦٫٧٩');   // Arabic digits
    await tester.enterText(find.byKey(const Key('vat-return-filed-input')), '18149.11');
    await tester.tap(find.byKey(const Key('vat-return-preview')));
    await tester.pumpAndSettle();
    expect(api.previewFigures.last, (22286.79, 18149.11));
    expect(tester.widget<Text>(find.byKey(const Key('vat-return-books'))).data,
        'في الدفاتر: مخرجات 0.00 · مدخلات 8,283.69');
    expect(tester.widget<Text>(find.byKey(const Key('vat-return-non-recoverable'))).data,
        'ضريبة غير قابلة للاسترداد (مصروف): 22,286.79');
    // the statement holds 9,865.42 the books do not: shown, and not filed
    expect(tester.widget<Text>(find.byKey(const Key('vat-return-input-difference'))).data,
        startsWith('ضريبة المدخلات في الإقرار تخالف الدفاتر بـ 9,865.42'));
    await tester.ensureVisible(find.byKey(const Key('vat-return-file')));
    expect(tester.widget<FilledButton>(find.byKey(const Key('vat-return-file'))).onPressed, isNull);

    // a figure changed after the preview: the preview is gone, nothing to file
    await tester.enterText(find.byKey(const Key('vat-return-filed-input')), '8283.6');
    await tester.pump();
    expect(find.byKey(const Key('vat-return-file')), findsNothing);
    // recorded on their vouchers, the books hold the statement's input: filed
    await tester.enterText(find.byKey(const Key('vat-return-filed-input')), '8283.69');
    await tester.tap(find.byKey(const Key('vat-return-preview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vat-return-input-difference')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('vat-return-net'))).data, '14,003.10');

    await tester.ensureVisible(find.byKey(const Key('vat-return-file')));
    await tester.tap(find.byKey(const Key('vat-return-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('vat-return-confirm')));
    await tester.pumpAndSettle();
    expect(api.fileFigures.single, (22286.79, 8283.69), reason: 'filed what was previewed');
    expect(tester.takeException(), isNull);
  });
}
