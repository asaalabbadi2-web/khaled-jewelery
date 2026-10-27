import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Shared PDF asset cache — font bytes, default logo, SAR tinted symbols.
///
/// Caches raw BYTES only (not pw.Font objects). pw.Font.ttf() parsing is
/// intentionally deferred to the first print because parsing a large Arabic
/// font synchronously on the main thread causes a multi-second freeze.
class PdfSarCache {
  PdfSarCache._();

  // The source SAR asset is very high resolution (3000x3353).
  // Downscale once before tinting to avoid expensive per-pixel work.
  static const int _sarMaxDimension = 320;

  // ── Font bytes (raw, not parsed) ──────────────────────────────────────────
  static Uint8List? _fontRegBytes;
  static Uint8List? _fontBoldBytes;

  static Uint8List? get fontRegBytes => _fontRegBytes;
  static Uint8List? get fontBoldBytes => _fontBoldBytes;

  // ── Default logo ──────────────────────────────────────────────────────────
  static Uint8List? _defaultLogoBytes;
  static Uint8List? get defaultLogoBytes => _defaultLogoBytes;

  // ── SAR tinted PNGs ───────────────────────────────────────────────────────
  static Uint8List? _rawSarBytes;
  static final Map<int, Uint8List> _tinted = {};

  /// Raw tinted bytes for a colour — null if not yet warmed.
  static Uint8List? tintedBytes(PdfColor c) => _tinted[_key(c)];

  // ── Public API ────────────────────────────────────────────────────────────

  /// No-op — kept for API compatibility.
  /// All assets are loaded lazily at first print to avoid startup freeze.
  static Future<void> preload() async {}

  /// Returns a [pw.ImageProvider] for the SAR symbol tinted in [c].
  /// Uses pure-Dart image package — no dart:ui, no GPU, no freeze.
  static Future<pw.ImageProvider?> tinted(PdfColor c) async {
    final key = _key(c);
    if (_tinted.containsKey(key)) return pw.MemoryImage(_tinted[key]!);

    final src = _rawSarBytes ?? await _loadRawSar();
    if (src == null) return null;
    _rawSarBytes ??= src;

    final bytes = _tintSync(src, c);
    if (bytes == null) return null;
    _tinted[key] = bytes;
    return pw.MemoryImage(bytes);
  }

  /// Resize [bytes] to [size]×[size] — pure Dart, safe to call anywhere.
  static Uint8List? resizePng(Uint8List bytes, int size) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      return Uint8List.fromList(
        img.encodePng(img.copyResize(decoded, width: size, height: size)),
      );
    } catch (_) {
      return bytes;
    }
  }

  /// The logo for a black-and-white print: its marks black, the rest as it
  /// was -- grayscale left a gold logo a faint gray (PRINT-2). A pixel darker
  /// than near-white is ink; its transparency is kept. The original bytes
  /// on failure.
  static Uint8List toBlackAndWhitePng(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      final out = decoded.convert(numChannels: 4);
      for (final pixel in out) {
        final luminance = (0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b) / pixel.maxChannelValue;
        final v = luminance < 0.85 ? 0 : pixel.maxChannelValue;
        pixel
          ..r = v
          ..g = v
          ..b = v;
      }
      return Uint8List.fromList(img.encodePng(out));
    } catch (_) {
      return bytes;
    }
  }

  // ── Lazy asset loaders — called from buildBytes(), never at startup ──────────

  /// Ensures Cairo font bytes are in cache. Fast no-op on subsequent calls.
  static Future<void> ensureFontBytes() async {
    if (_fontRegBytes != null && _fontBoldBytes != null) return;
    try {
      _fontRegBytes ??= (await rootBundle.load(
        'assets/fonts/Cairo-Regular.ttf',
      )).buffer.asUint8List();
      _fontBoldBytes ??= (await rootBundle.load(
        'assets/fonts/Cairo-Bold.ttf',
      )).buffer.asUint8List();
    } catch (_) {}
  }

  /// Ensures the default logo bytes are in cache.
  static Future<void> ensureDefaultLogo() async {
    if (_defaultLogoBytes != null) return;
    try {
      final raw = (await rootBundle.load(
        'assets/KHGL.png',
      )).buffer.asUint8List();
      _defaultLogoBytes = resizePng(raw, 128) ?? raw;
    } catch (_) {}
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  static Uint8List? _tintSync(Uint8List src, PdfColor c) {
    try {
      final decoded = img.decodePng(src);
      if (decoded == null) return null;
      final r = (c.red * 255).round();
      final g = (c.green * 255).round();
      final b = (c.blue * 255).round();
      for (final pixel in decoded) {
        if (pixel.a > 0) {
          pixel.r = r;
          pixel.g = g;
          pixel.b = b;
        }
      }
      return Uint8List.fromList(img.encodePng(decoded));
    } catch (_) {
      return null;
    }
  }

  /// Lazy SAR loader — called from [tinted] on first use.
  static Future<Uint8List?> _loadRawSar() async {
    if (_rawSarBytes != null) return _rawSarBytes;
    try {
      final rawBytes = (await rootBundle.load(
        'assets/sar_new_symbol.png',
      )).buffer.asUint8List();
      final result = await compute(
        _processSarInIsolate,
        _SarInput(rawBytes, _sarMaxDimension),
      );
      if (result == null) return null;
      _rawSarBytes = result.normalizedBytes;
      _tinted[_key(const PdfColor.fromInt(0xFF8B6914))] = result.amberBytes;
      _tinted[_key(const PdfColor.fromInt(0xFF1A1A1A))] = result.darkBytes;
      return _rawSarBytes;
    } catch (_) {
      return null;
    }
  }

  static int _key(PdfColor c) =>
      ((c.alpha * 255).round() << 24) |
      ((c.red * 255).round() << 16) |
      ((c.green * 255).round() << 8) |
      (c.blue * 255).round();
}

// ── Isolate helpers (top-level — required by compute()) ──────────────────────

class _SarInput {
  final Uint8List rawBytes;
  final int maxDimension;
  const _SarInput(this.rawBytes, this.maxDimension);
}

class _SarResult {
  final Uint8List normalizedBytes;
  final Uint8List amberBytes; // #8B6914
  final Uint8List darkBytes;  // #1A1A1A
  const _SarResult(this.normalizedBytes, this.amberBytes, this.darkBytes);
}

/// Runs in a compute isolate: normalize + tint. Pure Dart, no dart:ui.
_SarResult? _processSarInIsolate(_SarInput input) {
  try {
    final decoded = img.decodeImage(input.rawBytes);
    if (decoded == null) return null;

    // Downscale if larger than maxDimension.
    final maxSide = decoded.width > decoded.height ? decoded.width : decoded.height;
    final img.Image normalized;
    if (maxSide <= input.maxDimension) {
      normalized = decoded;
    } else {
      final scale = input.maxDimension / maxSide;
      normalized = img.copyResize(
        decoded,
        width: (decoded.width * scale).round().clamp(1, input.maxDimension),
        height: (decoded.height * scale).round().clamp(1, input.maxDimension),
        interpolation: img.Interpolation.linear,
      );
    }
    final normalizedBytes = Uint8List.fromList(img.encodePng(normalized));

    return _SarResult(
      normalizedBytes,
      _tintImgBytes(normalized, 0xFF8B6914),
      _tintImgBytes(normalized, 0xFF1A1A1A),
    );
  } catch (_) {
    return null;
  }
}

Uint8List _tintImgBytes(img.Image src, int argb) {
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  final clone = src.clone();
  for (final pixel in clone) {
    if (pixel.a > 0) { pixel.r = r; pixel.g = g; pixel.b = b; }
  }
  return Uint8List.fromList(img.encodePng(clone));
}
