import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/reports/vat_returns_screen.dart';

/// «إقرارات ضريبة القيمة المضافة» (ADR-043 rule 5): the server's figures shown,
/// a period previewed, then filed after a confirmation -- and the list reloaded.

class _FakeApi extends ApiService {
  final filedCalls = <(String, String)>[];
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
  Future<Map<String, dynamic>> previewVatReturn(String start, String end) async => {
        'start': start, 'end': end, 'output_vat': 0.0, 'input_vat': 8283.69, 'net': -8283.69,
        'lines': {'1400': -5739.67, '1410': -2544.02}, 'entry_number': null,
      };

  @override
  Future<Map<String, dynamic>> fileVatReturn(String start, String end) async {
    filedCalls.add((start, end));
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
}
