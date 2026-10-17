import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/add_customer_screen.dart';

/// UI-6 (ADR-049): a customer half typed is not thrown away by a slip of the
/// back key or of «إلغاء».
void main() {
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Directionality(
                    textDirection: TextDirection.rtl,
                    child: AddCustomerScreen(
                      api: ApiService(baseUrl: 'http://test'),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> cancel(WidgetTester tester) async {
    final button = find.text('إلغاء').last;
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('untouched, «إلغاء» leaves at once', (tester) async {
    await open(tester);
    await cancel(tester);
    expect(find.byType(AddCustomerScreen), findsNothing);
  });

  testWidgets('a name typed, «إلغاء» asks first', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextFormField).first, 'مؤسسة الأمل');
    await cancel(tester);
    expect(find.text('الخروج دون حفظ؟'), findsOneWidget);
    await tester.tap(find.text('البقاء'));
    await tester.pumpAndSettle();
    expect(find.byType(AddCustomerScreen), findsOneWidget);
  });
}
