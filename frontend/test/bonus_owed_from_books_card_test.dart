// BONUS-BOOKS-1: the card says what the books owe each employee and, where
// their approved unpaid bonuses differ, the difference -- moved in the books
// outside the bonus screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/bonus_owed_from_books_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the books owed, and the difference said', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          theme: LightTheme.theme,
          home: const Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: BonusOwedFromBooksCard(rows: [
                {'employee_name': 'مسعد المهري', 'owed_in_books': 0.0, 'approved_unpaid': 2512.5, 'difference': 2512.5},
                {'employee_name': 'يوسف الشعبي', 'owed_in_books': 12507.5, 'approved_unpaid': 6067.5, 'difference': -6440.0},
                {'employee_name': 'صالح العبادي', 'owed_in_books': 100.0, 'approved_unpaid': 100.0, 'difference': 0.0},
              ]),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('12,507.50'), findsWidgets);
    expect(find.textContaining('الدفاتر أقل بـ 2,512.50'), findsOneWidget);
    expect(find.textContaining('الدفاتر أكثر بـ 6,440.00'), findsOneWidget);
    // The employee whose books agree gets no difference line.
    expect(find.textContaining('المعتمد غير المصروف'), findsNWidgets(2));
  });
}
