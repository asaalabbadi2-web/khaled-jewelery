import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';

import '../api_service.dart';

/// A piece's label, both faces, as they read once folded (ADR-097 ط5): the
/// first its DataMatrix, its number, its karat and weight; the second its
/// name (cut as the label cuts it) and its stones and size. The faces' words
/// are the server's -- the printed label's own source -- never put together
/// here. Each face 25 x 13 mm, drawn to that ratio.
class LabelPreview extends StatelessWidget {
  const LabelPreview({super.key, required this.faces, this.width = 300});

  final Map<String, dynamic> faces;

  /// The two faces' width together, in logical pixels.
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faceWidth = (width - 8) / 2;
    final faceHeight = faceWidth * 13 / 25;
    final paper = theme.colorScheme.surfaceContainerLowest;
    final ink = theme.colorScheme.onSurface;
    Widget face(String key, Widget child) => Container(
          key: Key(key),
          width: faceWidth,
          height: faceHeight,
          padding: EdgeInsets.all(faceHeight * 0.1),
          decoration: BoxDecoration(
            color: paper,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: DefaultTextStyle(style: TextStyle(color: ink, fontSize: faceHeight * 0.16), child: child),
        );
    final code = '${faces['code'] ?? ''}';
    final number = '${faces['number'] ?? ''}';
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          face(
            'label-preview-first',
            Row(children: [
              if (code.isNotEmpty)
                BarcodeWidget(
                  barcode: Barcode.dataMatrix(),
                  data: code,
                  width: faceHeight * 0.7,
                  height: faceHeight * 0.7,
                  drawText: false,
                  color: ink,
                ),
              SizedBox(width: faceHeight * 0.1),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FittedBox(child: Text(number, style: const TextStyle(fontWeight: FontWeight.w700))),
                    if (faces['facts'] != null) FittedBox(child: Text('${faces['facts']}')),
                  ],
                ),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          face(
            'label-preview-second',
            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // read upright once folded: the name at its edge, the marks by the fold
                if (faces['name'] != null)
                  FittedBox(
                    child: Text('${faces['name']}', textDirection: TextDirection.rtl,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  )
                else
                  const SizedBox.shrink(),
                if (faces['marks'] != null) FittedBox(child: Text('${faces['marks']}')) else const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A piece's label preview read from the server, once a piece: drawn once
/// read; nothing when it cannot be read -- a preview never stops the work.
class PieceLabelPreview extends StatefulWidget {
  const PieceLabelPreview({super.key, required this.api, required this.pieceId, this.width = 300});

  final ApiService api;
  final int pieceId;
  final double width;

  @override
  State<PieceLabelPreview> createState() => _PieceLabelPreviewState();
}

class _PieceLabelPreviewState extends State<PieceLabelPreview> {
  late Future<Map<String, dynamic>> _faces = widget.api.labelPreview(widget.pieceId);

  @override
  void didUpdateWidget(PieceLabelPreview old) {
    super.didUpdateWidget(old);
    if (old.pieceId != widget.pieceId) _faces = widget.api.labelPreview(widget.pieceId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _faces,
      builder: (context, snapshot) {
        final faces = snapshot.data?['faces'] as Map<String, dynamic>?;
        if (faces == null) return const SizedBox.shrink();
        return LabelPreview(faces: faces, width: widget.width);
      },
    );
  }
}
