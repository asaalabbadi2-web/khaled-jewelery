// ADR-097 ط5 (the owner, 20 Nov 2026): a label's preview, both faces, from
// the server's words; the printers' setup, the manager's; the items' barcode
// screen never a piece's.

import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/app_user_model.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/barcode_print_screen.dart';
import 'package:frontend/screens/label_printers_screen.dart';
import 'package:frontend/screens/piece_station_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/label_preview.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _faces = {
  'code': 'KJ-000124',
  'number': 'KJ-000124',
  'weight': '12.40g',
  'karat': '21K',
  'name': 'طقم ذهب إيطالي مرصع…',
  'brand': 'مجوهرات خالد',
  'code_type': 'datamatrix',
  'stones': 'St 0.35g',
  'size': 'Sz 18',
};

class _Api extends ApiService {
  int previews = 0;
  final actions = <String>[];
  final updates = <Map<String, dynamic>>[];
  final added = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> printers = [
    {'id': 1, 'name': 'طابعة المعرض', 'host': '192.168.254.254', 'port': 9100, 'is_active': true,
     'font_installed_at': null},
  ];

  @override
  Future<Map<String, dynamic>> labelPreview(int pieceId) async {
    previews++;
    return {'faces': _faces};
  }

  @override
  Future<Map<String, dynamic>> labelPrinters() async => {'printers': printers};

  @override
  Future<Map<String, dynamic>> labelPrinterStatus(int printerId) async => {
        'status': {'ready': false, 'stops': ['paper_out'], 'message': 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'},
      };

  @override
  Future<Map<String, dynamic>> labelPrinterAction(int printerId, String action, {bool frame = false}) async {
    actions.add(frame ? '$action+frame' : action);
    return {'message': action == 'install-font' ? 'الخط في ذاكرة الطابعة' : 'طُبعت بطاقة تجربة بلا رقاقة'};
  }

  @override
  Future<Map<String, dynamic>> updateLabelPrinter(int printerId, Map<String, dynamic> body) async {
    updates.add(body);
    return {'printer': printers.first};
  }

  @override
  Future<Map<String, dynamic>> addLabelPrinter(Map<String, dynamic> body) async {
    added.add(body);
    return {'printer': body};
  }

  @override
  Future<List<Map<String, dynamic>>> piecesPending() async => [];

  @override
  Future<Map<String, dynamic>> printJobsOpen() async => {'jobs': [], 'counts': {}};
}

Future<void> _show(WidgetTester tester, Widget screen, {List<String>? permissions}) async {
  SharedPreferences.setMockInitialValues({
    'jwt_token': 't',
    if (permissions != null)
      'auth_current_user': jsonEncode(AppUserModel.fromJson({
        'id': 3, 'username': 'u', 'full_name': 'م', 'role': 'manager', 'is_active': true, 'is_admin': false,
        'employee_id': 1, 'effective_permissions': permissions, 'permissions': null, 'must_change_password': false,
      }).toStorageMap()),
  });
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final auth = AuthProvider();
  await auth.init();
  await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>.value(
    value: auth,
    child: MaterialApp(theme: LightTheme.theme, home: screen),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a preview draws both faces from the server\'s words, read once', (tester) async {
    final api = _Api();
    Widget tree(double width) => MaterialApp(
          theme: LightTheme.theme,
          home: Scaffold(body: Center(child: PieceLabelPreview(api: api, pieceId: 124, width: width))),
        );
    await tester.pumpWidget(tree(300));
    await tester.pumpAndSettle();
    Finder on(String face, String said) => find.descendant(of: find.byKey(Key(face)), matching: find.text(said));
    for (final said in ['KJ-000124', '12.40', 'g', '21K', 'St 0.35g']) {
      expect(on('label-preview-first', said), findsOneWidget, reason: '$said on the code\'s face');
    }
    for (final said in ['مجوهرات خالد', 'طقم ذهب إيطالي مرصع…', 'Sz 18']) {
      expect(on('label-preview-second', said), findsOneWidget, reason: '$said on the chip\'s face');
    }
    // the owner's approved design (27 Nov 2026): the weight the largest line, the karat reversed
    final sizes = {
      for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(LabelPreview), matching: find.byType(Text))))
        t.data: tester.getSize(find.byWidget(t)).height,
    };
    expect(sizes['12.40'], greaterThan(sizes.entries.where((e) => e.key != '12.40').map((e) => e.value).reduce(
        (a, b) => a > b ? a : b)), reason: 'the weight the largest line on the label');
    final box = tester.widget<Container>(find.byKey(const Key('label-preview-karat')));
    final ink = Theme.of(tester.element(find.byType(LabelPreview))).colorScheme.onSurface;
    expect((box.decoration as BoxDecoration).color, ink, reason: 'the karat in a box of ink');
    expect(find.descendant(of: find.byKey(const Key('label-preview-karat')), matching: find.text('21K')), findsOneWidget);
    await tester.pumpWidget(tree(320));                 // the same piece, rebuilt
    await tester.pumpAndSettle();
    expect(api.previews, 1, reason: 'not asked again at each rebuild');
  });

  // The owner, 27 Nov 2026: «اعداد لتحديد اي رمز يطبع QR, DM, BC وغيرها» -- the preview draws the code the
  // label prints, its kind the server's.
  for (final kind in ['datamatrix', 'qr', 'aztec', 'code128']) {
    testWidgets('the preview draws its code in the kind the labels print: $kind', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(body: Center(child: LabelPreview(faces: {..._faces, 'code_type': kind}))),
      ));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const Key('label-preview-first')),
          matching: find.byKey(Key('label-preview-code-$kind'))), findsOneWidget);
      expect(find.byType(BarcodeWidget), findsOneWidget, reason: 'one code, not two');
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
    });
  }

  testWidgets('the printers: their state said, the font, a test label, on or off, one added', (tester) async {
    final api = _Api();
    await _show(tester, LabelPrintersScreen(api: api));
    expect(find.text('انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'), findsOneWidget);
    expect(find.text('الخط العربي لم يُحمَّل بعد'), findsOneWidget);
    await tester.tap(find.byKey(const Key('printer-font-1')));
    await tester.pumpAndSettle();
    expect(api.actions, ['install-font']);
    await tester.tap(find.text('بطاقة تجربة'));
    await tester.pumpAndSettle();
    expect(api.actions.last, 'test-label');
    await tester.tap(find.byKey(const Key('printer-test-frame-1')));
    await tester.pumpAndSettle();
    expect(api.actions.last, 'test-label+frame', reason: 'the faces and the chip\'s bump drawn');
    await tester.tap(find.byKey(const Key('printer-active-1')));
    await tester.pumpAndSettle();
    expect(api.updates.single, {'is_active': false});
    await tester.tap(find.byKey(const Key('printers-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('printer-name')), 'طابعة الكاونتر');
    await tester.enterText(find.byKey(const Key('printer-host')), '192.168.1.60');
    await tester.tap(find.byKey(const Key('printer-save')));
    await tester.pumpAndSettle();
    expect(api.added.single, {'name': 'طابعة الكاونتر', 'host': '192.168.1.60', 'port': 9100});
  });

  testWidgets('«فحص القارئ» is seen on the top bar and opens the reader\'s check', (tester) async {
    await _show(tester, LabelPrintersScreen(api: _Api()));
    final key = find.byKey(const Key('printers-reader-check'));
    final ink = tester.widget<RichText>(find.descendant(of: key, matching: find.byType(RichText)).first).text.style?.color;
    final bar = Theme.of(tester.element(find.byType(AppBar))).appBarTheme;
    expect(ink, bar.foregroundColor, reason: 'the bar\'s ink: a text button\'s own is the bar\'s colour, unseen');
    await tester.tap(key);
    await tester.pumpAndSettle();
    expect(find.text('ما يكتبه القارئ'), findsOneWidget);
  });

  testWidgets('the printers\' setup is offered to its manager only', (tester) async {
    await _show(tester, PieceStationScreen(api: _Api()), permissions: ['items.view', 'items.create']);
    expect(find.byKey(const Key('station-printers-setup')), findsNothing, reason: 'a coder');
    await _show(tester, PieceStationScreen(api: _Api()),
        permissions: ['items.view', 'items.create', 'system.settings']);
    expect(find.byKey(const Key('station-printers-setup')), findsOneWidget, reason: 'its manager');
  });

  testWidgets('the items\' barcode screen never prints a piece, nor a price, nor an EAN-13', (tester) async {
    await _show(tester, const BarcodePrintScreen(barcode: 'KJ-000124', itemName: 'بنجرة', itemCode: 'KJ-000124'));
    expect(find.byKey(const Key('barcode-piece-refused')), findsOneWidget);
    expect(find.byKey(const Key('barcode-print')), findsNothing);
    await _show(tester, const BarcodePrintScreen(barcode: '6281234567890', itemName: 'علبة هدايا', itemCode: 'GB-1'));
    expect(find.byKey(const Key('barcode-print')), findsOneWidget);
    await tester.tap(find.byKey(const Key('barcode-type')));
    await tester.pumpAndSettle();
    expect(find.text('EAN-13'), findsNothing);
    expect(find.text('السعر'), findsNothing);
  });
}
