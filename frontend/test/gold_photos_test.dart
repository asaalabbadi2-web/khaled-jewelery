// The scrap purchase's photos are kept (ADR-094; the owner, 17 Nov 2026):
// «صور الذهب في شراء الكسر لا تُحفظ إطلاقًا» -- the screen sent their count.
// Now each photo is sized down and sent as it is taken; the invoice saved
// names those sent; a photo not sent is asked about before the save --
// never lost in silence; the invoice's preview shows its photos, read
// through the server.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/scrap_purchase_invoice_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/gold_photos.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_sales_api.dart';

Uint8List _png(int w, int h) => Uint8List.fromList(img.encodePng(img.Image(width: w, height: h)));

class _PhotoApi extends FakeSalesApi {
  _PhotoApi({this.failFirst = 0}) : super(categories: const [{'id': 1, 'name': 'كسر', 'karat': 21}]);

  int failFirst;
  final sent = <Uint8List>[];

  @override
  Future<Map<String, dynamic>> uploadAttachment(List<int> bytes,
      {String role = 'scrap_gold_photo', String filename = 'photo.jpg'}) async {
    if (failFirst > 0) {
      failFirst--;
      throw ApiException.text('انقطع الاتصال');
    }
    sent.add(Uint8List.fromList(bytes));
    return {'id': 40 + sent.length, 'kind': 'jpeg'};
  }

  @override
  Future<List<Map<String, dynamic>>> invoiceAttachments(int invoiceId) async => [
        {'id': 41},
        {'id': 42},
      ];

  @override
  Future<Uint8List> attachmentBytes(int id) async => _png(40, 30);
}

Future<void> _open(WidgetTester tester, _PhotoApi api, {List<Uint8List> Function()? picked, bool editing = false}) async {
  SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21})});
  tester.view.physicalSize = const Size(1440, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => AuthProvider()),
      ChangeNotifierProvider.value(value: settings),
    ],
    child: MaterialApp(
      theme: LightTheme.theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: ScrapPurchaseInvoiceScreen(
          customers: const [
            {'id': 8, 'name': 'عميل نقدي'},
          ],
          apiService: api,
          editInvoiceId: editing ? 5 : null,
          editInvoiceData: editing
              ? {
                  'customer_id': 8,
                  'branch_id': 1,
                  'items': [
                    {'name': 'كسر', 'karat': 21, 'standing_weight': 10.0, 'stones_weight': 0.0, 'weight': 10.0,
                     'wage': 0, 'quantity': 1, 'price': 4000},
                  ],
                  'payments': [],
                }
              : null,
          pickGoldPhotos: (_) async => picked?.call() ?? [_png(3200, 2400)],
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  // the photos and notes are folded until asked for (the owner, 25 Oct 2026)
  await tester.ensureVisible(find.byKey(const Key('scrap-extras')));
  await tester.tap(find.text('صور الذهب وملاحظات الشراء'));
  await tester.pumpAndSettle();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _readyLine(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('scrap-entry-category')), 'كس');
  await tester.pumpAndSettle();
  await tester.tap(find.text('كسر').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('scrap-entry-standing')), '10');
  await tester.enterText(find.byKey(const Key('scrap-entry-amount')), '4000');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('quick-pay-1')));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _settle(tester);
}

void main() {
  test('a save sends the photos sent, and counts what waits or failed', () {
    final sent = GoldPhoto(Uint8List(1))..id = 7;
    final waiting = GoldPhoto(Uint8List(1))..sending = true;
    final failed = GoldPhoto(Uint8List(1))..error = 'x';
    final state = goldPhotosToSave([sent, waiting, failed]);
    expect(state.ids, [7]);
    expect((state.sending, state.failed), (1, 1));
  });

  testWidgets('a photo is sized down and sent as it is taken', (tester) async {
    final api = _PhotoApi();
    await _open(tester, api);
    await tester.ensureVisible(find.byKey(const Key('gold-photo-gallery')));
    await tester.tap(find.byKey(const Key('gold-photo-gallery')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(1));
    final sent = img.decodeImage(api.sent.single)!;
    expect((sent.width, sent.height), (goldPhotoSide, 1200), reason: '3200 x 2400 sized down to 1600');
    expect(img.findDecoderForData(api.sent.single), isA<img.JpegDecoder>());
    expect(find.text('الصور: 1 من $goldPhotosMax'), findsOneWidget);
  });

  testWidgets('a photo not sent says so and is sent again on asking', (tester) async {
    final api = _PhotoApi(failFirst: 1);
    await _open(tester, api);
    await tester.ensureVisible(find.byKey(const Key('gold-photo-gallery')));
    await tester.tap(find.byKey(const Key('gold-photo-gallery')));
    await tester.pumpAndSettle();
    expect(find.text('لم تُرفع — أعد المحاولة'), findsOneWidget);
    await tester.tap(find.byKey(const Key('gold-photo-retry-0')));
    await tester.pumpAndSettle();
    expect(find.text('لم تُرفع — أعد المحاولة'), findsNothing);
    expect(api.sent, hasLength(1));
  });

  testWidgets('saved, the invoice names its photos; a photo not sent is asked about first', (tester) async {
    final api = _PhotoApi(failFirst: 1);
    await _open(tester, api, picked: () => [_png(800, 600), _png(640, 480)]);
    await _readyLine(tester);
    await tester.ensureVisible(find.byKey(const Key('gold-photo-gallery')));
    await tester.tap(find.byKey(const Key('gold-photo-gallery')));
    await tester.pumpAndSettle();
    await _save(tester);
    expect(find.text('1 صورة لم تُرفع'), findsOneWidget);
    expect(api.added, isEmpty, reason: 'nothing saved while asked');
    await tester.tap(find.byKey(const Key('gold-photos-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gold-photo-retry-0')));
    await tester.pumpAndSettle();
    await _save(tester);
    expect(find.text('1 صورة لم تُرفع'), findsNothing);
    await tester.tap(find.text('حفظ الفاتورة').last);
    await _settle(tester);
    if (find.text('متابعة').evaluate().isNotEmpty) {
      await tester.tap(find.text('متابعة'));
      await _settle(tester);
    }
    expect(api.added.single['attachment_ids'], [42, 41], reason: 'in the photos\' order: the first sent again last');
    expect(api.added.single.containsKey('gold_images_count'), isFalse);
  });

  testWidgets('saving without the photo not sent is the user\'s choice', (tester) async {
    final api = _PhotoApi(failFirst: 1);
    await _open(tester, api, picked: () => [_png(800, 600)]);
    await _readyLine(tester);
    await tester.ensureVisible(find.byKey(const Key('gold-photo-gallery')));
    await tester.tap(find.byKey(const Key('gold-photo-gallery')));
    await tester.pumpAndSettle();
    await _save(tester);
    await tester.tap(find.byKey(const Key('gold-photos-save-without')));
    await _settle(tester);
    await tester.tap(find.text('حفظ الفاتورة').last);
    await _settle(tester);
    if (find.text('متابعة').evaluate().isNotEmpty) {
      await tester.tap(find.text('متابعة'));
      await _settle(tester);
    }
    expect(api.added.single['attachment_ids'], isEmpty);
  });

  testWidgets('editing an invoice: photos are added when it is made, and said so', (tester) async {
    await _open(tester, _PhotoApi(), editing: true);
    expect(find.byKey(const Key('gold-photos-edit-note')), findsOneWidget);
    expect(find.byKey(const Key('gold-photo-gallery')), findsNothing);
  });

  testWidgets('an invoice\'s preview shows its photos, read through the server', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: InvoicePhotos(api: _PhotoApi(), invoiceId: 9)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('صور الذهب (2)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('invoice-photo-0')));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });
}
