// Web implementation using package:web (avoids deprecated dart:html).
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<String?> pickJsonFile() {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.json,application/json'
    ..multiple = false;

  final completer = Completer<String?>();

  input.addEventListener(
    'change',
    ((web.Event _) {
      if (completer.isCompleted) return;

      unawaited(() async {
        final files = input.files;
        if (files == null || files.length == 0) {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
          return;
        }

        final file = files.item(0);
        if (file == null) {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
          return;
        }

        try {
          final jsText = await file.text().toDart;
          if (!completer.isCompleted) {
            completer.complete(jsText.toDart);
          }
        } catch (_) {
          if (!completer.isCompleted) {
            completer.completeError('Failed to read file');
          }
        }
      }());
    }).toJS,
  );

  // Trigger picker
  input.click();
  return completer.future;
}

void downloadString(String filename, String content) {
  final parts = JSArray<web.BlobPart>()..length = 1;
  parts[0] = content.toJS;
  final blob = web.Blob(
    parts,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

void downloadBytes(String filename, List<int> bytes, String mimeType) {
  final data = Uint8List.fromList(bytes);

  final jsBuffer = data.buffer.toJS;
  final jsView = JSUint8Array(
    jsBuffer,
    data.offsetInBytes,
    data.lengthInBytes,
  );

  final parts = JSArray<web.BlobPart>()..length = 1;
  parts[0] = jsView;

  final blob = web.Blob(
    parts,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
