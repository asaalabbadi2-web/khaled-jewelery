import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/pdf_print_ink.dart';
import 'package:frontend/pdf/pdf_sar_cache.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';

/// PRINT-2: black and white prints black and white. Every color the PDF
/// builders write is read as ink (black, or white on a dark band) or as a
/// fill (white, or a dark band in black) -- no gray between.
void main() {
  const bw = PdfInk(blackAndWhite: true);
  const color = PdfInk(blackAndWhite: false);

  final builders = [
    'lib/pdf/invoice_pdf_builder.dart',
    'lib/pdf/voucher_pdf_builder.dart',
    'lib/pdf/account_statement_pdf_builder.dart',
  ];
  final literal = RegExp(r"0xFF([0-9A-Fa-f]{6})|'#([0-9A-Fa-f]{6})'");
  final colors = <String>{
    for (final path in builders)
      for (final m in literal.allMatches(File(path).readAsStringSync()))
        (m.group(1) ?? m.group(2))!.toUpperCase(),
  };

  bool pure(PdfColor c) => c == PdfColors.black || c == PdfColors.white;

  test('the builders\' colors are found', () {
    expect(colors, contains('DDDDDD')); // the invoice's
    expect(colors, contains('EBEBEB')); // the voucher's
    expect(colors, contains('F5EFE0')); // the statement's
  });

  test('every color, as ink or as fill, is black or white', () {
    for (final hex in colors) {
      final c = PdfColor.fromInt(int.parse('FF$hex', radix: 16));
      expect(pure(bw.ink(c)), isTrue, reason: 'ink $hex');
      expect(pure(bw.fill(c)), isTrue, reason: 'fill $hex');
    }
  });

  test('the faint grays print black as ink, the light backgrounds white', () {
    for (final hex in ['888888', 'DDDDDD', '444444', '8B6914', 'E8D899', 'EBEBEB']) {
      expect(bw.ink(PdfColor.fromInt(int.parse('FF$hex', radix: 16))), PdfColors.black, reason: hex);
    }
    for (final hex in ['F0F0F0', 'FBF7EE', 'FCFAF5', 'FFE2DE', 'EAF5EF', 'F7F6F2']) {
      expect(bw.fill(PdfColor.fromInt(int.parse('FF$hex', radix: 16))), PdfColors.white, reason: hex);
    }
  });

  test('white text on a dark band stays readable', () {
    expect(bw.ink(PdfColors.white), PdfColors.white);
    expect(bw.fill(const PdfColor.fromInt(0xFF1A1A1A)), PdfColors.black);
  });

  test('no hairline in black and white', () {
    expect(bw.rule(0.35), 0.8);
    expect(bw.rule(1.2), 1.2);
    expect(color.rule(0.35), 0.35);
  });

  test('a color print is unchanged', () {
    const gold = PdfColor.fromInt(0xFF8B6914);
    expect(color.ink(gold), gold);
    expect(color.fill(gold), gold);
  });

  test('the logo prints its marks black, not a faint gray', () {
    final logo = img.Image(width: 3, height: 1, numChannels: 4)
      ..setPixelRgba(0, 0, 0xC9, 0xA8, 0x4C, 255) // the gold of the logo
      ..setPixelRgba(1, 0, 255, 255, 255, 255)
      ..setPixelRgba(2, 0, 0xC9, 0xA8, 0x4C, 0);
    final out = img.decodePng(PdfSarCache.toBlackAndWhitePng(img.encodePng(logo)))!;
    expect([out.getPixel(0, 0).r, out.getPixel(0, 0).a], [0, 255], reason: 'gold is ink');
    expect(out.getPixel(1, 0).r, 255, reason: 'white stays white');
    expect(out.getPixel(2, 0).a, 0, reason: 'transparent stays transparent');
  });

  // Every color in a builder goes through the rule: a color written straight
  // into one would print gray again. A line marked «// raw:» says why not
  // (a color print's gradient, the SAR symbol's tint, a named palette).
  for (final path in builders) {
    test('$path writes no color past the rule', () {
      final lines = File(path).readAsLinesSync();
      final raw = <String>[
        for (final (i, line) in lines.indexed)
          if (RegExp(r'PdfColor\.from(Int|Hex)\(|(?<![_A-Za-z])PdfColors\.(?!white\b|black\b)').hasMatch(line) &&
              !RegExp(r'ink\(|fill\(|// raw:').hasMatch(line))
            '${i + 1}: ${line.trim()}',
      ];
      expect(raw, isEmpty);
    });
  }
}
