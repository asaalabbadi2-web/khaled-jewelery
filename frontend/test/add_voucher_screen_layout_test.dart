import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';

import 'support/fake_voucher_api.dart';
import 'support/shots.dart';
import 'support/voucher_screen_harness.dart';

/// The voucher screen review, release 2 (the owner, 20 Oct 2026: «تأكد أن
/// تصميمها يلبي سهولة الاستخدام»): the screen asks in the order the employee
/// decides -- who, with their balance; cash or gold; from where; how much;
/// for which invoices -- says each thing once, and says the voucher in one
/// sentence beside its save.
void main() {
  setUpAll(loadCairo);

  /// A supplier who is owed cash and 21k, and owes us 24k (debit less credit).
  const owed = [
    {
      'id': 5,
      'name': 'مورد الذهب',
      'account_id': 50,
      'supplier_code': 'S-000005',
      'balance_cash': -7784.83,
      'balance_gold_18k': 0.0,
      'balance_gold_21k': -2748.71,
      'balance_gold_22k': 0.0,
      'balance_gold_24k': 2265.87,
    },
  ];

  Future<void> pickSafe(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.byKey(const Key('voucher-line-account-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voucher-line-account-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(name).last);
    await tester.pumpAndSettle();
  }

  Finder kind() => find.byKey(const Key('voucher-line-kind-0'));
  Finder account() => find.byKey(const Key('voucher-line-account-0'));

  testWidgets('cash or gold is asked before where from, and choosing a safe '
      'does not move it', (tester) async {
    await openVoucher(tester);
    expect(
      tester.getCenter(kind()).dy,
      lessThan(tester.getCenter(account()).dy),
    );

    final before = tester.getCenter(kind());
    await pickSafe(tester, 'الصندوق');
    expect(
      tester.getCenter(kind()),
      before,
      reason:
          'the safe\'s balance '
          'used to be put above the choice, which then moved under the hand',
    );
  });

  testWidgets('the party is said with what is between us', (tester) async {
    await openVoucher(tester, api: FakeVoucherApi(suppliers: owed));
    final balance = find.byKey(const Key('voucher-party-balance'));
    expect(balance, findsOneWidget);
    expect(said('علينا له 7,784.83 ر.س'), findsOneWidget);
    expect(said('علينا له 2,748.710 جم عيار 21'), findsOneWidget);
    expect(said('لنا عنده 2,265.870 جم عيار 24'), findsOneWidget);
  });

  testWidgets('each thing is said once, in the employee\'s words', (
    tester,
  ) async {
    await openVoucher(tester);
    expect(find.text('سند صرف'), findsOneWidget, reason: 'the title, once');
    expect(find.textContaining('مؤشرات السند'), findsNothing);
    expect(find.textContaining('المورد المختار'), findsNothing);
    expect(find.textContaining('سطر الطرف'), findsNothing);
    expect(find.textContaining('مجموع النقد'), findsNothing);
  });

  testWidgets('the voucher is said in one sentence beside its save', (
    tester,
  ) async {
    await openVoucher(tester);
    await pickSafe(tester, 'الصندوق');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'المبلغ (ريال) *').first,
      '500',
    );
    await tester.pumpAndSettle();
    final summary = find.byKey(const Key('voucher-summary'));
    expect(summary, findsOneWidget);
    expect(
      tester
          .widget<Text>(summary)
          .data!
          .replaceAll(RegExp('[\u2066-\u2069]'), ''),
      'تصرف 500.00 ر.س من الصندوق إلى مورد الذهب',
    );
  });

  testWidgets('what is written about the voucher waits folded', (tester) async {
    await openVoucher(tester);
    expect(find.byKey(const Key('voucher-details')), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'اسم المستلم').hitTestable(),
      findsNothing,
    );
  });

  testWidgets('every quick template can be seen and reached', (tester) async {
    await openVoucher(tester);
    for (final title in [
      'دفعة لمورد',
      'راتب موظف',
      'سلفة موظف',
      'مكافأة موظف',
      'مصروف تشغيلي',
    ]) {
      expect(find.text(title).hitTestable(), findsOneWidget, reason: title);
    }
  });

  testWidgets('two columns on a desktop, one on a phone, nothing overflows', (
    tester,
  ) async {
    await openVoucher(tester);
    final party = tester.getCenter(find.byKey(const Key('voucher-party-card')));
    expect((party.dx - tester.getCenter(kind()).dx).abs(), greaterThan(300));

    tester.view.physicalSize = const Size(390, 2400);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final p2 = tester.getCenter(find.byKey(const Key('voucher-party-card')));
    expect(tester.getCenter(kind()).dy, greaterThan(p2.dy));
  });

  testWidgets('on a phone the sentence is read over a save as wide as the '
      'screen, not squeezed a word to a line', (tester) async {
    await openVoucher(tester, size: const Size(390, 844));
    await pickSafe(tester, 'الصندوق');
    final amount = find.widgetWithText(TextFormField, 'المبلغ (ريال) *').first;
    await tester.ensureVisible(amount);
    await tester.enterText(amount, '500');
    await tester.pumpAndSettle();
    final summary = tester.getRect(find.byKey(const Key('voucher-summary')));
    final save = tester.getRect(find.text('حفظ السند').last);
    expect(summary.bottom, lessThanOrEqualTo(save.top), reason: 'above it');
    expect(summary.height, lessThan(120), reason: 'two or three lines at most');
  });

  testWidgets('the expense template leaves the expense to the employee, and '
      'offers operating expenses only (the owner, 20 Oct 2026)', (
    tester,
  ) async {
    final api = FakeVoucherApi(
      appConfig: const {
        'account_groups': {
          'expenses': {
            'account_id': 90,
            'subtree_ids': [90, 93, 94, 91, 92],
          },
          'operating_expenses': {
            'account_id': 94,
            'subtree_ids': [94, 91, 92],
          },
        },
      },
    );
    await openVoucher(tester, api: api);
    await tester.tap(find.text('مصروف تشغيلي'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('خسارة الوزن'),
      findsNothing,
      reason: 'the first expense in the tree was chosen for them',
    );

    await tester.tap(find.text('اختر حساب المصروف'));
    await tester.pumpAndSettle();
    expect(find.textContaining('كهرباء'), findsOneWidget);
    expect(
      find.textContaining('مشتريات ذهب'),
      findsNothing,
      reason: 'a purchase is cost of sales, not an operating expense',
    );
    expect(find.textContaining('مورد الذهب'), findsNothing);
  });

  testWidgets('a safe\'s balance is said once, and its shortfall under the '
      'amount', (tester) async {
    await openVoucher(tester);
    await pickSafe(tester, 'الصندوق');
    final amount = find.widgetWithText(TextFormField, 'المبلغ (ريال) *').first;
    await tester.enterText(amount, '500');
    await tester.pumpAndSettle();
    expect(said('100,000.00'), findsOneWidget);
    expect(find.textContaining('لا يغطي'), findsNothing);

    await tester.enterText(amount, '150000');
    await tester.pumpAndSettle();
    expect(find.textContaining('لا يغطي'), findsOneWidget);
  });

  group('the party picker (the voucher screen review, release 3)', () {
    const many = [
      {
        'id': 5,
        'name': 'مورد الذهب',
        'account_id': 50,
        'supplier_code': 'S-000005',
        'phone': '0500000005',
        'balance_cash': -7784.83,
        'balance_gold_21k': -2748.71,
        'balance_gold_24k': 2265.87,
      },
      {
        'id': 6,
        'name': 'مفيد الحبيشي',
        'account_id': 60,
        'supplier_code': 'S-000013',
      },
      {
        'id': 7,
        'name': 'مكتب الراقي',
        'account_id': 70,
        'supplier_code': 'S-000020',
      },
    ];

    Finder search() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );

    Future<void> openPicker(WidgetTester tester, {int more = 0}) async {
      final suppliers = [
        ...many,
        for (var i = 0; i < more; i++)
          {'id': 100 + i, 'name': 'مورد $i', 'account_id': 200 + i},
      ];
      await openVoucher(
        tester,
        api: FakeVoucherApi(suppliers: suppliers),
        supplierId: null,
      );
      // The whole list, the field's button away.
      await tester.tap(find.byKey(const Key('voucher-party-show-all')));
      await tester.pumpAndSettle();
    }

    testWidgets('it takes the typing at once', (tester) async {
      await openPicker(tester);
      await tester.enterText(search(), 'مفيد');
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(search());
      expect(field.autofocus, isTrue);
      expect(find.text('مكتب الراقي'), findsNothing);
    });

    testWidgets('each party with its code, phone and what is between us -- '
        'its gold in one figure, in the main karat (the owner, 20 Oct 2026)', (
      tester,
    ) async {
      await openPicker(tester);
      expect(said('S-000005'), findsOneWidget);
      expect(said('0500000005'), findsOneWidget);
      expect(said('علينا له 7,784.83 ر.س'), findsOneWidget);
      // -2,748.710 of 21 and +2,265.870 of 24 (2,589.566 of 21).
      expect(said('علينا له 159.144 جم بالعيار 21'), findsOneWidget);
      expect(said('جم عيار 24'), findsNothing);
    });

    testWidgets('it keeps its height while it is searched', (tester) async {
      await openPicker(tester, more: 20);
      // The dialog's surface, not the barrier around it.
      final dialog = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Material),
          )
          .first;
      final before = tester.getRect(dialog);
      await tester.enterText(search(), 'مفيد');
      await tester.pumpAndSettle();
      expect(
        tester.getRect(dialog),
        before,
        reason:
            'the one result moved from '
            'under the hand as the list shrank',
      );
    });
  });

  testWidgets(
    'a safe is offered with what it holds, not a kind already chosen',
    (tester) async {
      await openVoucher(tester);
      await tester.tap(find.text('ذهب').first);
      await tester.pumpAndSettle();
      // Under the field as it is typed in ...
      await tester.tap(find.byKey(const Key('voucher-line-account-0')));
      await tester.pumpAndSettle();
      final option = find.byKey(const Key('type-to-pick-option-80'));
      expect(
        find.descendant(
          of: option,
          matching: said('فيها 410.600 جم بالعيار 21'),
        ),
        findsOneWidget,
      );
      expect(find.text('كلاهما'), findsNothing);

      // ... and in the whole list.
      await tester.tap(
        find.byKey(const Key('voucher-line-account-show-all-0')),
      );
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(
          of: sheet,
          matching: said('فيها 410.600 جم بالعيار 21'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('كلاهما')),
        findsNothing,
      );
      final search = tester.widget<TextField>(
        find.descendant(of: sheet, matching: find.byType(TextField)),
      );
      expect(search.autofocus, isTrue);
    },
  );

  testWidgets('an invoice is listed whole, with what is left on it said so, '
      'on a phone too', (tester) async {
    await openVoucher(
      tester,
      size: const Size(390, 1600),
      api: FakeVoucherApi(
        openCash: const [
          {
            'invoice_id': 12,
            'invoice_number': 'SUPP-2026-005',
            'date': '2026-02-12T00:00:00',
            'open_cash': 6104.0,
            'open_main_karat': 921.8,
          },
        ],
      ),
    );
    expect(
      find.text('SUPP-2026-005'),
      findsOneWidget,
      reason: 'the number alone on its line, not cut',
    );
    expect(said('المتبقي: 6,104.00 ر.س'), findsOneWidget);
  });

  // ADR-050 ر٠: a failed load is said, with a retry -- it was a message
  // over an empty form that took typing, with no accounts to pick.
  testWidgets('a failed load is said, with a retry, and no form to type in', (
    tester,
  ) async {
    final api = FakeVoucherApi(failLoads: 1);
    await openVoucher(tester, api: api);

    expect(find.text('تعذّر تحميل بيانات السند'), findsOneWidget);
    expect(find.text('حفظ السند'), findsNothing);
    expect(account(), findsNothing);

    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(find.text('تعذّر تحميل بيانات السند'), findsNothing);
    expect(account(), findsOneWidget);
  });

  // The owner, 22 Oct 2026: «الشريط العلوي لشاشة إنشاء السند في الوضع
  // الداكن لا تطابق باقي الصفحات فلونه ذهبي فاتح والأزرار بنفس اللون».
  testWidgets('its bar is the theme\'s, its button apart from it, in the '
      'dark theme too', (tester) async {
    await openVoucher(
      tester,
      theme: DarkTheme.theme,
      size: const Size(1440, 1000),
    );
    await shot(tester, 'voucher_dark_bar');
    final bar = tester.widget<AppBar>(find.byType(AppBar).last);
    expect(bar.backgroundColor, isNull, reason: 'the theme\'s bar');
    final barColor = Theme.of(
      tester.element(find.byType(AppBar).last),
    ).appBarTheme.backgroundColor;
    final later = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byKey(const Key('voucher-later')),
        matching: find.text('إكمال لاحقاً'),
      ),
    );
    final said = later.text.style?.color;
    expect(said, isNotNull);
    expect(said, isNot(barColor), reason: 'the button apart from its bar');
  });
}
