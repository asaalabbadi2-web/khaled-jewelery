import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/add_voucher_screen.dart';

import 'support/fake_voucher_api.dart';
import 'support/voucher_screen_harness.dart';

/// The voucher screen review, release 4 (the owner, 20 Oct 2026: «أليس من
/// الأسهل والأسرع الكتابة والبحث في حقل الحساب نفسه مع إتاحة إظهار القائمة؟»):
/// a party or a safe is found by typing in its own field, its matches under
/// it, the arrows and Enter take one; the whole list is a tap away.
void main() {
  setUpAll(loadCairo);

  const suppliers = [
    {
      'id': 5,
      'name': 'مورد الذهب',
      'account_id': 50,
      'supplier_code': 'S-000005',
      'balance_cash': -7784.83,
    },
    {'id': 6, 'name': 'مفيد الحبيشي', 'account_id': 60, 'supplier_code': 'S-000013'},
    {'id': 7, 'name': 'مكتب الراقي', 'account_id': 70, 'supplier_code': 'S-000020'},
  ];

  Finder party() => find.byKey(const Key('voucher-party-field'));
  Finder account() => find.byKey(const Key('voucher-line-account-0'));

  Future<void> typeIn(WidgetTester tester, Finder field, String text) async {
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  /// Enter in a field: what the keyboard sends it is «done».
  Future<void> enter(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  String shown(WidgetTester tester, Finder field) =>
      tester.widget<TextField>(field).controller!.text;

  testWidgets('a supplier is found by typing in its field, by name or code, '
      'and taken with Enter', (tester) async {
    await openVoucher(tester, api: FakeVoucherApi(suppliers: suppliers), supplierId: null);
    await typeIn(tester, party(), 'S-000013');
    expect(find.byKey(const Key('type-to-pick-option-6')), findsOneWidget);
    expect(find.byKey(const Key('type-to-pick-option-7')), findsNothing);

    await enter(tester);
    expect(shown(tester, party()), 'مفيد الحبيشي');
    expect(find.textContaining('غير جاهز للحفظ — اختر حساب السطر 1'), findsOneWidget);
  });

  testWidgets('each match says what it is: its code and what is between us', (
    tester,
  ) async {
    await openVoucher(tester, api: FakeVoucherApi(suppliers: suppliers), supplierId: null);
    await typeIn(tester, party(), 'مورد');
    final option = find.byKey(const Key('type-to-pick-option-5'));
    expect(find.descendant(of: option, matching: said('S-000005')), findsOneWidget);
    expect(find.descendant(of: option, matching: said('علينا له 7,784.83 ر.س')), findsOneWidget);
  });

  testWidgets('the arrows choose among the matches', (tester) async {
    await openVoucher(tester, api: FakeVoucherApi(suppliers: suppliers), supplierId: null);
    await typeIn(tester, party(), 'م');
    await press(tester, LogicalKeyboardKey.arrowDown);
    await enter(tester);
    // In the list's order (by name): مفيد، مكتب، مورد -- the second.
    expect(shown(tester, party()), 'مكتب الراقي');
  });

  testWidgets('a safe is found by typing in its line\'s field', (tester) async {
    await openVoucher(tester);
    await typeIn(tester, account(), 'الصند');
    await enter(tester);
    expect(shown(tester, account()), contains('الصندوق'));
    expect(find.textContaining('غير جاهز للحفظ — أدخل مبلغ السطر 1'), findsOneWidget);
  });

  testWidgets('half-typed and left, a field keeps what was chosen', (
    tester,
  ) async {
    await openVoucher(tester, api: FakeVoucherApi(suppliers: suppliers));
    expect(shown(tester, party()), 'مورد الذهب');
    await typeIn(tester, party(), 'xyz');
    await tester.tap(find.byKey(const Key('voucher-description')));
    await tester.pumpAndSettle();
    expect(shown(tester, party()), 'مورد الذهب');
  });

  testWidgets('the whole list is a tap away', (tester) async {
    await openVoucher(tester, api: FakeVoucherApi(suppliers: suppliers), supplierId: null);
    await tester.tap(find.byKey(const Key('voucher-party-show-all')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('مفيد الحبيشي').last);
    await tester.pumpAndSettle();
    expect(shown(tester, party()), 'مفيد الحبيشي');

    await tester.tap(find.byKey(const Key('voucher-line-account-show-all-0')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('a whole voucher from the keyboard: who, from where, how much, '
      'saved', (tester) async {
    final api = await openVoucher(
      tester,
      api: FakeVoucherApi(suppliers: suppliers),
      supplierId: null,
    );
    await typeIn(tester, party(), 'مفيد');
    await enter(tester);
    await typeIn(tester, account(), 'الصند');
    await enter(tester);
    await tester.enterText(cashAmount(), '250');
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('مراجعة سند صرف'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.enter);
    expect(api.created.single['supplier_id'], 6);
    expect(find.byType(AddVoucherScreen), findsNothing);
  });

  testWidgets('taken with Enter, the field keeps the focus -- the next Enter '
      'does not leave the screen', (tester) async {
    await openVoucher(tester, api: FakeVoucherApi(suppliers: suppliers), supplierId: null);
    await typeIn(tester, party(), 'مفيد');
    await enter(tester);
    final field = tester.widget<TextField>(party());
    expect(field.focusNode!.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byType(AddVoucherScreen), findsOneWidget);
  });

  testWidgets('Tab from a taken safe goes to its amount, not the list button', (
    tester,
  ) async {
    await openVoucher(tester);
    await typeIn(tester, account(), 'الصند');
    await enter(tester);
    await press(tester, LogicalKeyboardKey.tab);
    final amount = tester.widget<EditableText>(
      find.descendant(of: cashAmount(), matching: find.byType(EditableText)),
    );
    expect(amount.focusNode.hasFocus, isTrue);
  });
}
