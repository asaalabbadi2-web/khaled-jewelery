// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/home_screen_enhanced.dart';

void main() {
  testWidgets('HomeScreen shows app title and Add Customer button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: HomeScreenEnhanced()));

    // تحقق من وجود عنوان التطبيق
    expect(find.text('Yasar POS'), findsOneWidget);

    // تحقق من وجود زر إضافة عميل
    expect(find.widgetWithText(ElevatedButton, 'Add Customer'), findsOneWidget);
  });
}
