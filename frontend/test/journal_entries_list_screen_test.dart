import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/journal_entries_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The journal entries list (ADR-050 ر٠): posting puts an entry in the
/// balances -- it was one press, now asked first, saying which entry and its
/// totals; a refusal says the server's reason (it said «فشل ترحيل القيد»);
/// deleting is one dialog with its required reason (it was two).
class _Accountant extends AuthProvider {
  @override
  String get username => 'accountant';

  @override
  bool hasPermission(String key) => true;
}

const _entry = {
  'id': 7,
  'entry_number': 'JE-2026-00042',
  'description': 'قيد تسوية فرق صندوق',
  'date': '2026-10-20T10:00:00',
  'is_posted': false,
  'entry_type': 'عادي',
  'cash_total': 1500.0,
  'gold_total_main_karat': 0.0,
  'line_count': 2,
};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  /// Opens the list on one unposted entry, runs [steps], and returns what
  /// was sent: «METHOD path?query». [refuse]: the server refuses a write
  /// with this message.
  Future<List<String>> open(
    WidgetTester tester,
    Future<void> Function() steps, {
    String? refuse,
  }) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);

    final sent = <String>[];
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthProvider>(
                create: (_) => _Accountant(),
              ),
              ChangeNotifierProvider.value(value: settings),
            ],
            child: MaterialApp(
              theme: LightTheme.theme,
              home: const Directionality(
                textDirection: TextDirection.rtl,
                child: JournalEntriesListScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await steps();
      },
      () => MockClient((request) async {
        final path = request.url.path;
        if (request.method != 'GET') {
          final query = request.url.query;
          sent.add(
            '${request.method} ${path.replaceFirst(RegExp(r'^.*/api'), '')}'
            '${query.isEmpty ? '' : '?$query'}',
          );
          if (refuse != null) {
            return json({'error': 'refused', 'message': refuse}, 400);
          }
          return json({'success': true});
        }
        if (path.endsWith('/journal_entries')) {
          return json({
            'journal_entries': [_entry],
            'total': 1,
            'pages': 1,
            'current_page': 1,
            'per_page': 25,
          });
        }
        return json([]);
      }),
    );
    return sent;
  }

  Future<void> act(WidgetTester tester, String label) async {
    // The row's actions sit at the end of a wide table: brought into view.
    await tester.ensureVisible(find.byTooltip('الإجراءات').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('الإجراءات').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('posting asks first, saying the entry; going back posts '
      'nothing', (tester) async {
    final sent = await open(tester, () async {
      await act(tester, 'ترحيل');
      expect(find.text('ترحيل القيد؟'), findsOneWidget);
      expect(find.textContaining('JE-2026-00042'), findsWidgets);
      // The dialog says the entry's cash -- the table says it too.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('1,500.00'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
    });
    expect(sent, isEmpty);
  });

  testWidgets('confirmed, the entry is posted once', (tester) async {
    final sent = await open(tester, () async {
      await act(tester, 'ترحيل');
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
    });
    expect(sent, ['POST /journal-entries/post/7']);
  });

  testWidgets('a refused posting says the server\'s reason', (tester) async {
    await open(
      refuse: 'القيد غير متوازن: المدين لا يساوي الدائن',
      tester,
      () async {
        await act(tester, 'ترحيل');
        await tester.tap(find.byKey(const Key('confirm-action')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('القيد غير متوازن: المدين لا يساوي الدائن'),
          findsOneWidget,
        );
      },
    );
  });

  testWidgets('deleting is one dialog, its reason required', (tester) async {
    final sent = await open(tester, () async {
      await act(tester, 'حذف');
      expect(find.text('حذف القيد؟'), findsOneWidget);
      final delete = find.byKey(const Key('confirm-action'));
      expect(tester.widget<FilledButton>(delete).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('confirm-reason')),
        'أُدخل مرتين',
      );
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
    });
    expect(sent, hasLength(1));
    expect(sent.single, startsWith('DELETE /journal-entries/7?reason='));
  });
}
