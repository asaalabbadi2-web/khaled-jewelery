// The posting settings, in their own page (D12): each a financial setting,
// changed alone -- its value now and after, what it does, its reason, required
// -- through PATCH at the version seen (ADR-102, ADR-103), never the old PUT of
// all four on every flip; another user's change since is read again, said so;
// whoever lacks the permission is told, the switches not offered; the
// approval-before-posting switch, saved and read by nothing, is gone (the
// owner, 26 Nov 2026); the page's reset touches its local preferences only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/posting_management_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Auth extends AuthProvider {
  _Auth({this.admin = false});
  final bool admin;

  @override
  bool get isSystemAdmin => admin;

  @override
  bool hasPermission(String key) => admin;
}

class _Api extends ApiService {
  final saved = <(Map<String, dynamic>, Map<String, int>, String?)>[];
  Object? fail;
  int putCalls = 0;
  final settings = <String, dynamic>{'auto_post_invoices': false, 'auto_post_entries': true, 'allow_unposting': true};

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, int>> getSettingsVersions() async => {'auto_post_invoices': 4, 'allow_unposting': 6};

  @override
  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> settings) async {
    putCalls++;
    return settings;
  }

  @override
  Future<Map<String, dynamic>> patchSettings({
    required Map<String, dynamic> changes,
    required Map<String, int> versions,
    String? reason,
  }) async {
    saved.add((changes, versions, reason));
    final f = fail;
    if (f != null) {
      fail = null;
      throw f;
    }
    settings.addAll(changes);
    return {'settings': Map.of(settings), 'versions': {for (final k in changes.keys) k: 99}};
  }

  @override
  Future<Map<String, dynamic>> getPostingStats() async => {'stats': {}};
  @override
  Future<Map<String, dynamic>> getUnpostedInvoices() async => {'invoices': []};
  @override
  Future<Map<String, dynamic>> getPostedInvoices() async => {'invoices': []};
  @override
  Future<Map<String, dynamic>> getUnpostedJournalEntries() async => {'entries': []};
  @override
  Future<Map<String, dynamic>> getPostedJournalEntries() async => {'entries': []};
}

void main() {
  Future<_Api> open(WidgetTester tester, {bool admin = true, bool? financial}) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: _Auth(admin: admin)),
        ChangeNotifierProvider<SettingsProvider>(create: (_) => SettingsProvider(fetch: () async => {})),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: PostingManagementScreen(api: api, financialAllowed: financial ?? admin),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('إعدادات الترحيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إعدادات الترحيل'));
    await tester.pumpAndSettle();
    return api;
  }

  SwitchListTile tile(WidgetTester tester, String title) => tester.widget<SwitchListTile>(
      find.ancestor(of: find.text(title), matching: find.byType(SwitchListTile)).first);

  testWidgets('a posting setting is changed alone, with its reason, through PATCH', (tester) async {
    final api = await open(tester);
    expect(tile(tester, 'ترحيل الفواتير تلقائياً').value, isFalse);
    await tester.tap(find.text('ترحيل الفواتير تلقائياً'));
    await tester.pumpAndSettle();
    expect(api.saved, isEmpty, reason: 'not before its confirmation');
    expect(tester.widget<FilledButton>(find.byKey(const Key('confirm-action'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('confirm-reason')), 'الترحيل عند الحفظ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    final (changes, versions, reason) = api.saved.single;
    expect(changes, {'auto_post_invoices': true}, reason: 'that key alone');
    expect(versions, {'auto_post_invoices': 4});
    expect(reason, 'الترحيل عند الحفظ');
    expect(api.putCalls, 0, reason: 'never the old PUT of all four');
    expect(tile(tester, 'ترحيل الفواتير تلقائياً').value, isTrue);
  });

  testWidgets('going back changes nothing', (tester) async {
    final api = await open(tester);
    await tester.tap(find.text('السماح بإلغاء الترحيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تراجع'));
    await tester.pumpAndSettle();
    expect(api.saved, isEmpty);
    expect(tile(tester, 'السماح بإلغاء الترحيل').value, isTrue);
  });

  testWidgets('another user changed it since: read again, said so', (tester) async {
    final api = await open(tester);
    api.fail = const ApiException(statusCode: 409, code: 'settings_conflict', message: 'تعارض');
    api.settings['allow_unposting'] = false;
    await tester.tap(find.text('السماح بإلغاء الترحيل'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('confirm-reason')), 'سبب');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(find.textContaining('غيّره مستخدم آخر'), findsOneWidget);
    expect(tile(tester, 'السماح بإلغاء الترحيل').value, isFalse, reason: 'the value now, read again');
  });

  testWidgets('without the financial permission: said, and not offered', (tester) async {
    await open(tester, admin: false);
    expect(find.byKey(const Key('posting-needs-permission')), findsOneWidget);
    expect(tile(tester, 'ترحيل الفواتير تلقائياً').onChanged, isNull);
    expect(tile(tester, 'السماح بإلغاء الترحيل').onChanged, isNull);
    expect(tile(tester, 'ترحيل القيود تلقائياً').onChanged, isNull, reason: "the system admin's alone");
  });

  testWidgets('the approval-before-posting switch, read by nothing, is gone', (tester) async {
    await open(tester);
    expect(find.text('طلب موافقة قبل الترحيل'), findsNothing);
    final src = File('lib/screens/posting_management_screen.dart').readAsStringSync();
    expect(src.contains("'require_approval_before_post'"), isFalse);
    expect(src.contains('updateSettings('), isFalse, reason: 'no posting setting saved through PUT');
  });
}
