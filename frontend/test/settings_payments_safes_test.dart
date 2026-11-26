// «المدفوعات والخزائن» in the center (settings spec v2, phase 7, batch 4):
// the employee-safe switches and the three default safes are financial --
// each changed alone through its confirmation, with its reason; a safe is
// chosen among the safes of its type, said by its name, «غير نشطة» when it is
// not active; none chosen is a choice, saved as none; a safe no longer there
// is said so, not dropped; safes that cannot be read are said, with a retry;
// nothing overflows, nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/settings/section_editor.dart';
import 'package:frontend/settings/settings_registry.dart';
import 'package:frontend/theme/app_theme.dart';

import 'support/dark_text.dart';

class _Api extends ApiService {
  final saved = <(Map<String, dynamic>, Map<String, int>, String?)>[];
  final asked = <String?>[];
  int safesFailures = 0;

  final settings = <String, dynamic>{
    'employee_cash_safes_enabled': false,
    'employee_gold_safes_enabled': true,
    'main_cash_safe_box_id': 38,
    'sale_gold_safe_box_id': 30,
    'main_scrap_gold_safe_box_id': 31,
  };

  static final _safes = [
    SafeBoxModel(id: 38, name: 'خزينة النقدية الرئيسية', safeType: 'cash', accountId: 755),
    SafeBoxModel(id: 40, name: 'صندوق الفرع', safeType: 'cash', accountId: 756),
    SafeBoxModel(id: 41, name: 'صندوق قديم', safeType: 'cash', accountId: 757, isActive: false),
    SafeBoxModel(id: 30, name: 'الذهب المعروض', safeType: 'gold', accountId: 760, stockLocation: 'showroom'),
    SafeBoxModel(id: 31, name: 'ذهب الكسر الرئيسي', safeType: 'gold', accountId: 766, stockLocation: 'scrap'),
  ];

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, int>> getSettingsVersions() async => {'main_cash_safe_box_id': 6, 'employee_cash_safes_enabled': 3};

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async {
    asked.add(safeType);
    if (safesFailures > 0) {
      safesFailures--;
      throw const ApiException(statusCode: 0, code: 'network', message: 'انقطع الاتصال بالخادم');
    }
    return [for (final s in _safes) if (s.safeType == safeType) s];
  }

  @override
  Future<Map<String, dynamic>> patchSettings({
    required Map<String, dynamic> changes,
    required Map<String, int> versions,
    String? reason,
  }) async {
    saved.add((changes, versions, reason));
    settings.addAll(changes);
    return {'settings': Map.of(settings), 'versions': {for (final k in changes.keys) k: 99}};
  }
}

const _sizes = {'wide': Size(1400, 1000), 'tablet': Size(820, 1180), 'phone': Size(390, 860)};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<_Api> open(WidgetTester tester, {Size size = const Size(1000, 1600), bool dark = false, _Api? api}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = api ?? _Api();
    await tester.pumpWidget(MaterialApp(
      theme: dark ? DarkTheme.theme : LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Scaffold(
        body: SectionEditor(
            section: SettingsSection.paymentsSafes, api: a, financialAllowed: true, opener: (_, _) async {}),
      ),
    ));
    await tester.pumpAndSettle();
    return a;
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  String textOf(WidgetTester tester, Key key) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(key), matching: find.byType(Text), matchRoot: true))
      .map((t) => t.data ?? '')
      .join(' ');

  Future<void> pick(WidgetTester tester, String key, String label) async {
    await tester.tap(find.byKey(Key('financial-safe-$key')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> confirmWith(WidgetTester tester, String reason) async {
    await tester.enterText(find.byKey(const Key('financial-reason')), reason);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the section and a safe\'s confirmation fit and read',
          (tester) async {
        await open(tester, size: size, dark: dark);
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'settings-change-main_cash_safe_box_id');
        await tester.tap(find.byKey(const Key('financial-safe-main_cash_safe_box_id')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('each safe is said by its name, read once per type', (tester) async {
    final api = await open(tester);
    expect(api.asked..sort(), ['cash', 'gold']);
    expect(textOf(tester, const Key('settings-value-main_cash_safe_box_id')), 'خزينة النقدية الرئيسية');
    expect(textOf(tester, const Key('settings-value-sale_gold_safe_box_id')), 'الذهب المعروض');
    expect(textOf(tester, const Key('settings-value-main_scrap_gold_safe_box_id')), 'ذهب الكسر الرئيسي');
    expect(textOf(tester, const Key('settings-value-employee_gold_safes_enabled')), 'مفعّل');
    expect(find.byType(Switch), findsNothing);
    expect(find.byKey(const Key('settings-entry-safe_boxes')), findsOneWidget, reason: 'a safe is made in «الخزائن»');
  });

  testWidgets('the main cash safe is chosen among cash safes, alone, with its reason', (tester) async {
    final api = await open(tester);
    await tapKey(tester, 'settings-change-main_cash_safe_box_id');
    await tester.tap(find.byKey(const Key('financial-safe-main_cash_safe_box_id')));
    await tester.pumpAndSettle();
    expect(find.text('صندوق قديم (غير نشطة)'), findsOneWidget, reason: 'an inactive safe is said so');
    final menu = find.byWidgetPredicate((w) => w is DropdownMenuItem<int?>);
    expect(find.descendant(of: menu, matching: find.text('الذهب المعروض')), findsNothing,
        reason: 'a gold safe is no cash safe');
    expect(find.descendant(of: menu, matching: find.text('صندوق الفرع')), findsWidgets);
    await tester.tap(find.text('صندوق الفرع').last);
    await tester.pumpAndSettle();
    expect(textOf(tester, const Key('financial-after')), contains('صندوق الفرع'));
    await confirmWith(tester, 'الفرع الجديد');
    final (changes, versions, reason) = api.saved.single;
    expect(changes, {'main_cash_safe_box_id': 40});
    expect(versions, {'main_cash_safe_box_id': 6});
    expect(reason, 'الفرع الجديد');
    expect(textOf(tester, const Key('settings-value-main_cash_safe_box_id')), 'صندوق الفرع');
  });

  testWidgets('none chosen is a choice, saved as none', (tester) async {
    final api = await open(tester);
    await tapKey(tester, 'settings-change-main_scrap_gold_safe_box_id');
    await pick(tester, 'main_scrap_gold_safe_box_id', '— غير محدد —');
    await confirmWith(tester, 'سبب');
    expect(api.saved.single.$1, {'main_scrap_gold_safe_box_id': null});
    expect(textOf(tester, const Key('settings-value-main_scrap_gold_safe_box_id')), 'غير محدد');
  });

  testWidgets('a safe no longer there is said so, and kept until changed', (tester) async {
    final api = _Api()..settings['sale_gold_safe_box_id'] = 99;
    await open(tester, api: api);
    expect(textOf(tester, const Key('settings-value-sale_gold_safe_box_id')), 'خزينة رقم 99 (غير موجودة حاليًا)');
    await tapKey(tester, 'settings-change-sale_gold_safe_box_id');
    expect(tester.widget<FilledButton>(find.byKey(const Key('financial-confirm'))).onPressed, isNull,
        reason: 'still 99: nothing changed');
  });

  testWidgets('an employee-safe switch is flipped through its confirmation', (tester) async {
    final api = await open(tester);
    await tapKey(tester, 'settings-change-employee_cash_safes_enabled');
    expect(textOf(tester, const Key('financial-after')), contains('مفعّل'));
    await confirmWith(tester, 'لكل موظف صندوقه');
    expect(api.saved.single.$1, {'employee_cash_safes_enabled': true});
    expect(api.saved.single.$2, {'employee_cash_safes_enabled': 3});
  });

  testWidgets('safes that cannot be read are said, with a retry', (tester) async {
    final api = _Api()..safesFailures = 1;
    await open(tester, api: api);
    expect(find.text('تعذّر تحميل الإعدادات'), findsOneWidget);
    expect(find.byKey(const Key('settings-change-main_cash_safe_box_id')), findsNothing);
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(textOf(tester, const Key('settings-value-main_cash_safe_box_id')), 'خزينة النقدية الرئيسية');
  });
}
