import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/app_feedback.dart';
import 'package:http/http.dart' as http;

import 'support/shots.dart';

/// UI-1 (ADR-049): what a screen tells the user is said in the user's words.
void main() {
  group('what an error says', () {
    String said(Object e) => AppFeedback.messageOf(e);

    test("a refusal says the server's words", () {
      const e = ApiException(
        statusCode: 409,
        code: 'customer_in_use',
        message: 'العميل له فواتير',
      );
      expect(said(e), 'العميل له فواتير');
    });

    test('a lost network, a timeout, an unreadable reply: a sentence each', () {
      expect(
        said(http.ClientException('Failed to fetch')),
        AppFeedback.networkMessage,
      );
      expect(said(TimeoutException('x')), AppFeedback.timeoutMessage);
      expect(said(const FormatException('x')), AppFeedback.unreadableMessage);
    });

    test("a screen's words are kept; only the exception's are replaced", () {
      expect(
        said('فشل حفظ الفاتورة: Exception: الوزن مطلوب'),
        'فشل حفظ الفاتورة: الوزن مطلوب',
      );
      expect(
        said(
          'فشل حفظ الفاتورة: ClientException: Failed to fetch, uri=http://x',
        ),
        'فشل حفظ الفاتورة: ${AppFeedback.networkMessage}',
      );
      expect(said(Exception('الوزن مطلوب')), 'الوزن مطلوب');
    });
  });

  group('how it is shown', () {
    setUpAll(() async {
      final cairo = FontLoader('Cairo');
      for (final w in ['Regular', 'SemiBold', 'Bold']) {
        cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
      }
      await cairo.load();
    });

    Future<BuildContext> pump(WidgetTester tester, ThemeData theme) async {
      tester.view.physicalSize = const Size(1200, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: Builder(
                builder: (context) {
                  ctx = context;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      return ctx;
    }

    for (final (name, theme) in [
      ('light', LightTheme.theme),
      ('dark', DarkTheme.theme),
    ]) {
      testWidgets('an error, with its heading, in the $name theme', (
        tester,
      ) async {
        final context = await pump(tester, theme);
        AppFeedback.error(
          context,
          'فشل حفظ السند: Exception: الخزنة لا تكفي',
          title: 'لم يُحفظ السند',
        );
        await tester.pumpAndSettle();
        expect(find.text('فشل حفظ السند: الخزنة لا تكفي'), findsOneWidget);
        expect(find.textContaining('Exception'), findsNothing);
        expect(find.text('لم يُحفظ السند'), findsOneWidget);
        await shot(tester, 'feedback_error_$name');
      });

      testWidgets('a success replaces what was shown, in the $name theme', (
        tester,
      ) async {
        final context = await pump(tester, theme);
        AppFeedback.error(context, 'خطأ سابق');
        await tester.pumpAndSettle();
        AppFeedback.success(context, 'حُفظ السند');
        await tester.pumpAndSettle();
        expect(find.text('خطأ سابق'), findsNothing);
        expect(find.text('حُفظ السند'), findsOneWidget);
        await shot(tester, 'feedback_success_$name');
      });
    }

    testWidgets('without a messenger it says nothing and does not fail', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );
      AppFeedback.info(ctx, 'لا أحد يسمع');
      expect(tester.takeException(), isNull);
    });
  });
}
