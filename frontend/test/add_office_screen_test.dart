import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/add_office_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/payload_witness.dart';

/// «إضافة مكتب» (ADR-052, the office journey release 4). What it sends is
/// kept whole in test/payloads (ADR-049 UI-2), written from the form before
/// its redesign: the redesign changes how it reads, not what reaches the
/// server -- save what it could not say before: an opening owed to the office.
class _FakeApi extends ApiService {
  final added = <Map<String, dynamic>>[];
  final updated = <Map<String, dynamic>>[];

  @override
  Future<List<dynamic>> getSuppliers() async => [
    {'id': 20, 'name': 'مكتب الراقي', 'phone': '0500000001'},
  ];

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> addOffice(Map<String, dynamic> officeData) async {
    added.add(officeData);
    return {'id': 9};
  }

  @override
  Future<void> updateOffice(int id, Map<String, dynamic> officeData) async {
    updated.add(officeData);
  }
}

const _office = {
  'id': 5,
  'name': 'مكتب الراقي',
  'phone': '0500000001',
  'contact_person': 'أبو خالد',
  'city': 'الرياض',
  'country': 'Saudi Arabia',
  'active': true,
  'supplier_id': 20,
  'supplier_name': 'مكتب الراقي',
  'supplier_default_safe_box_id': 60,
  'supplier_default_safe_box_name': 'ذهب مودع لدى مكتب الراقي',
};

Future<_FakeApi> _open(
  WidgetTester tester, {
  Map<String, dynamic>? office,
  Size size = const Size(1440, 2400),
}) async {
  final cairo = FontLoader('Cairo');
  for (final w in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
  }
  await cairo.load();
  SharedPreferences.setMockInitialValues({
    'jwt_token': 'token',
    'app_settings': jsonEncode({'main_karat': 21}),
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  final api = _FakeApi();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: AddOfficeScreen(api: api, office: office),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Future<void> _type(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(field.first);
  await tester.enterText(field.first, text);
  await tester.pumpAndSettle();
}

/// Says whose an opening balance is, where the form asks it (the redesign).
Future<void> _side(WidgetTester tester, String key, String label) async {
  final group = find.byKey(Key(key));
  if (group.evaluate().isEmpty) return;
  await tester.ensureVisible(group);
  await tester.tap(find.descendant(of: group, matching: find.text(label)));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, String label) async {
  final save = find.text(label).last;
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('it sends what it sent: a new office, ours with it', (tester) async {
    final api = await _open(tester);
    await _type(tester, 'اسم المكتب *', 'مكتب جديد');
    await _type(tester, 'رقم الهاتف', '0500000002');
    await _type(tester, 'الشخص المسؤول', 'أبو سعد');
    await _type(tester, 'رصيد افتتاحي نقدي (ر.س)', '1000');
    await _side(tester, 'office-opening-cash-side', 'لنا عنده');
    await _type(tester, 'رصيد افتتاحي ذهب (جرام مكافئ العيار الرئيسي)', '50');
    await _side(tester, 'office-opening-gold-side', 'لنا عنده');
    await _save(tester, 'إضافة المكتب');
    expect(api.added, hasLength(1));
    expectPayload('office_add_ours', api.added.single);
  });

  testWidgets('it sends what it sent: an edit saved as it was', (tester) async {
    final api = await _open(tester, office: Map.of(_office));
    await _save(tester, 'حفظ التعديلات');
    expect(api.updated, hasLength(1));
    expectPayload('office_edit_unchanged', api.updated.single);
  });

  testWidgets('an opening owed to the office is sent as owed -- the form could not say it', (tester) async {
    final api = await _open(tester);
    await _type(tester, 'اسم المكتب *', 'مكتب جديد');
    await _type(tester, 'رصيد افتتاحي نقدي (ر.س)', '1000');
    await _side(tester, 'office-opening-cash-side', 'علينا له');
    await _type(tester, 'رصيد افتتاحي ذهب (جرام مكافئ العيار الرئيسي)', '20');
    await _side(tester, 'office-opening-gold-side', 'علينا له');
    await _save(tester, 'إضافة المكتب');
    expect(api.added.single['opening_balance_cash'], -1000.0);
    expect(api.added.single['opening_balance_gold_main_karat'], -20.0);
  });

  testWidgets('an amount without whose it is is not sent', (tester) async {
    final api = await _open(tester);
    await _type(tester, 'اسم المكتب *', 'مكتب جديد');
    await _type(tester, 'رصيد افتتاحي نقدي (ر.س)', '1000');
    await _save(tester, 'إضافة المكتب');
    expect(api.added, isEmpty);
    expect(find.textContaining('لنا عنده أم علينا له'), findsOneWidget);
  });

  testWidgets('the deposit made with it is said, and the address waits folded', (tester) async {
    await _open(tester);
    expect(find.textContaining('ذهب مودع لدى'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'رقم الترخيص').hitTestable(), findsNothing);
  });

  testWidgets('two columns on a desktop, one on a phone', (tester) async {
    await _open(tester);
    final name = tester.getCenter(find.widgetWithText(TextFormField, 'اسم المكتب *'));
    final cash = tester.getCenter(find.widgetWithText(TextFormField, 'رصيد افتتاحي نقدي (ر.س)'));
    expect((name.dx - cash.dx).abs(), greaterThan(300), reason: 'side by side');

    tester.view.physicalSize = const Size(390, 2400);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final n2 = tester.getCenter(find.widgetWithText(TextFormField, 'اسم المكتب *'));
    final c2 = tester.getCenter(find.widgetWithText(TextFormField, 'رصيد افتتاحي نقدي (ر.س)'));
    expect(c2.dy, greaterThan(n2.dy), reason: 'one under the other');
  });
}
