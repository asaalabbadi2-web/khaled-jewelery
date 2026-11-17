import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A photo sized down on the device before it is sent (ADR-093 §7, ADR-094):
/// at most [side] px on its longer side, a JPEG within [maxBytes] -- the
/// quality lowered until it fits. Null when the bytes are not an image (a
/// damaged file throws in the decoder: it is not an image either); a
/// [FormatException] when even the lowest quality is too large.
Uint8List? downsizeToJpeg(Uint8List bytes, {required int side, required int maxBytes}) {
  img.Image? read;
  try {
    read = img.decodeImage(bytes);
  } catch (_) {
    read = null;
  }
  if (read == null) return null;
  final decoded = read;
  final fitted = decoded.width <= side && decoded.height <= side
      ? decoded
      : decoded.width >= decoded.height
          ? img.copyResize(decoded, width: side)
          : img.copyResize(decoded, height: side);
  for (final quality in const [80, 65, 50, 35]) {
    final out = img.encodeJpg(fitted, quality: quality);
    if (out.length <= maxBytes) return Uint8List.fromList(out);
  }
  throw const FormatException('الصورة كبيرة حتى بعد تصغيرها');
}
