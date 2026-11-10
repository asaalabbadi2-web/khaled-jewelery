// أيقونتا التكسير والتجديد (المالك، 10 نوفمبر 2026): بلغة أيقونات التطبيق --
// Material، لون واحد هو لون موضعها كأي Icon، وخطّ 2. التكسير مطرقة فوق ماسة
// مشروخة، والتجديد الماسة نفسها بين سهمي التدوير. ملفّا الـ SVG هما المرجع.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/gold_operation_icon.dart';

import 'support/shots.dart';

void main() {
  test('each icon is in one colour, its place\'s: currentColor and nothing else', () {
    for (final op in GoldOperation.values) {
      final svg = File(op.asset).readAsStringSync();
      expect(RegExp(r'#[0-9A-Fa-f]{3,8}\b').hasMatch(svg), isFalse, reason: '${op.asset} names a colour');
      expect(RegExp(r'rgb|hsl').hasMatch(svg), isFalse, reason: op.asset);
      expect(svg, contains('currentColor'), reason: op.asset);
      expect(svg, isNot(contains('Gradient')), reason: op.asset);
      expect(svg, isNot(contains('filter')), reason: op.asset);
    }
  });

  /// What is drawn: the file without its masks (a mask cuts, it draws nothing).
  String drawn(String svg) => svg.replaceAll(RegExp(r'<defs>[\s\S]*?</defs>'), '');

  // The owner (10 Nov 2026): «تطابق ايقونات النظام». A Material icon's line
  // is 2 of 24; the first drawing's 1.5 was lighter than its neighbours.
  test('every line drawn is 2 of 24, as a Material icon\'s', () {
    for (final op in GoldOperation.values) {
      final widths = RegExp(r'stroke-width="([\d.]+)"')
          .allMatches(drawn(File(op.asset).readAsStringSync()))
          .map((m) => m.group(1))
          .toSet();
      expect(widths, {'2'}, reason: op.asset);
    }
  });

  // A crack, a scratch: cut by a mask, never painted in a background's colour
  // -- the icon sits on light, dark and the gold bar alike.
  test('what is cut is cut by a mask: nothing drawn but currentColor', () {
    for (final op in GoldOperation.values) {
      final svg = File(op.asset).readAsStringSync();
      expect(svg, contains('mask="url(#'), reason: op.asset);
      final paints = RegExp(r'(?:fill|stroke)="([^"]+)"').allMatches(drawn(svg)).map((m) => m.group(1)).toSet();
      expect(paints.difference({'currentColor', 'none'}), isEmpty, reason: '${op.asset}: $paints');
    }
  });

  // The owner (10 Nov 2026): a diamond renewed between the two arrows of
  // rotation, and a diamond cracked under a hammer -- the same diamond.
  test('both carry the same diamond', () {
    final gem = RegExp(r'data-part="gem"[^>]*\sd="([^"]+)"');
    final shapes = [
      for (final op in GoldOperation.values) gem.firstMatch(File(op.asset).readAsStringSync())?.group(1),
    ];
    expect(shapes, everyElement(isNotNull));
    expect(shapes.toSet(), hasLength(1));
  });

  testWidgets('it takes its place\'s colour and size, as an Icon does', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: const Scaffold(
          body: Column(
            children: [
              IconTheme(
                data: IconThemeData(color: Color(0xFF445566), size: 32),
                child: GoldOperationIcon(GoldOperation.breaking),
              ),
              GoldOperationIcon(GoldOperation.renewal, color: Color(0xFF112233), size: 18),
            ],
          ),
        ),
      ),
    );
    final svgs = tester.widgetList<SvgPicture>(find.byType(SvgPicture)).toList();
    SvgTheme? themeOf(SvgPicture p) => (p.bytesLoader as SvgAssetLoader).theme;
    expect(themeOf(svgs[0])?.currentColor, const Color(0xFF445566));
    expect(svgs[0].width, 32);
    expect(svgs[0].matchTextDirection, isFalse);
    expect(themeOf(svgs[1])?.currentColor, const Color(0xFF112233));
    expect(svgs[1].width, 18);
    expect(svgs[1].matchTextDirection, isFalse, reason: 'a rotation, as autorenew: not mirrored');
  });

  test('«التجديد والتكسير» uses the two icons, not the generic ones', () {
    final screen = File('lib/screens/melting_renewal_screen.dart').readAsStringSync();
    expect(screen, isNot(contains('Icons.recycling')));
    expect(screen, isNot(contains('Icons.auto_fix_high')));
    // The tabs, the run button and the banner: each operation's own icon.
    expect('GoldOperationIcon('.allMatches(screen).length, greaterThanOrEqualTo(3));
    expect(screen, contains('GoldOperation.renewal'));
    expect(screen, contains('GoldOperation.breaking'));
  });

  // A sheet to look at: both icons at 24, 32 and 48 beside the app's own
  // Material icons, in the colours they are given on the light and the dark
  // surface and on the light theme's gold bar, and once large. Drawn only
  // with --dart-define=SHOT_DIR=<dir> --update-goldens.
  testWidgets('sheet', (tester) async {
    if (shotDir.isEmpty) return;
    // The app's Material icons, to draw them beside ours (tests draw boxes
    // without their font).
    final font = File(
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    await tester.runAsync(() async {
      final bytes = await font.readAsBytes();
      await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    });
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget row(ThemeData theme, Color bg, Color Function(GoldOperation) colorOf) => Container(
      color: bg,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          for (final s in [24.0, 32.0, 48.0])
            for (final op in GoldOperation.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9),
                child: GoldOperationIcon(op, size: s, color: colorOf(op)),
              ),
          const SizedBox(width: 18),
          for (final icon in [Icons.diamond_outlined, Icons.scale_outlined, Icons.payments_outlined, Icons.inventory_2_outlined])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Icon(icon, size: 24, color: colorOf(GoldOperation.renewal)),
            ),
        ],
      ),
    );
    final light = LightTheme.theme;
    final dark = DarkTheme.theme;
    final ls = AppSemanticColors.light;
    final ds = AppSemanticColors.dark;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: light,
        home: Material(
          color: Colors.white,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row(light, light.colorScheme.surface, (_) => light.colorScheme.onSurface),
              row(light, light.colorScheme.surface, (op) => op == GoldOperation.breaking ? ls.warning.fg : ls.gold.fg),
              row(dark, dark.colorScheme.surface, (op) => op == GoldOperation.breaking ? ds.warning.fg : ds.gold.fg),
              row(light, light.colorScheme.primary, (_) => light.colorScheme.onPrimary),
              Row(
                children: [
                  for (final op in GoldOperation.values)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: GoldOperationIcon(op, size: 192, color: ls.gold.fg),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await shot(tester, 'gold_operation_icons');
  });
}
