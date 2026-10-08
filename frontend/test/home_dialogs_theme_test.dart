import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/goal_achievement_celebration.dart';
import 'package:frontend/widgets/pending_approvals_dialog.dart';
import 'package:provider/provider.dart';

/// ثيم-٠: النافذتان اللتان تُفتحان من الشاشة الرئيسية -- «بانتظار الإجراء»
/// والاحتفال بتحقيق الهدف -- تأخذان ألوانهما من الثيم، فتُرسمان في الوضعين.
/// الحدّ على الألوان المكتوبة فيهما صفر في `theme_raw_color_ratchet_test.dart`.
class _PendingApi extends ApiService {
  @override
  Future<Map<String, dynamic>> getPendingActions() async => {
    'pending_invoices': [
      for (final t in ['بيع', 'شراء من عميل', 'مرتجع بيع'])
        {
          'id': t.length,
          'invoice_number': 'INV-$t',
          'invoice_type': t,
          'party_name': 'عميل',
          'total_amount': 1500.0,
          'created_by_name': 'موظف',
          'created_at': '2026-10-08T10:00:00',
        },
    ],
    'pending_reservations': [],
    'system_alerts': [
      {'title': 'المجدول متوقف', 'message': 'رسالة', 'what_to_do': 'أعد التشغيل'},
    ],
    'total_pending_invoices': 3,
    'total_pending_reservations': 0,
  };
}

const dir = String.fromEnvironment('SHOT_DIR');

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<void> pump(WidgetTester tester, ThemeData theme, Widget child) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AuthProvider(),
        child: MaterialApp(
          theme: theme,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(body: Center(child: child)),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
  }

  for (final (name, theme) in [
    ('light', LightTheme.theme),
    ('dark', DarkTheme.theme),
  ]) {
    testWidgets('«بانتظار الإجراء» draws in the $name theme', (tester) async {
      await pump(
        tester,
        theme,
        PendingApprovalsDialog(api: _PendingApi(), isArabic: true),
      );
      await tester.pumpAndSettle();
      expect(find.text('INV-بيع'), findsOneWidget);
      expect(find.text('المجدول متوقف'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (dir.isNotEmpty) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('$dir/approvals_$name.png'),
        );
      }
    });

    testWidgets('the goal celebration draws in the $name theme', (
      tester,
    ) async {
      await pump(
        tester,
        theme,
        GoalAchievementOverlay(
          achievement: GoalAchievement(
            employeeName: 'سارة أحمد',
            goalName: 'هدف المبيعات الشهري',
            bonusAmount: 500,
            currency: 'ر.س',
            metrics: const {},
            achievedAt: DateTime(2026, 10, 8),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('سارة'), findsWidgets);
      expect(tester.takeException(), isNull);
      if (dir.isNotEmpty) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('$dir/celebration_$name.png'),
        );
      }
      // Its own timers: the confetti stops at 5 s, the overlay closes at 15 s.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 16));
    });
  }
}
