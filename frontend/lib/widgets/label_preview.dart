import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';

import '../api_service.dart';

/// A piece's label, both faces, as they read once folded (ADR-097 ط5; the
/// design the owner approved from its trial print, 27 Nov 2026): the first its
/// code -- of the kind the labels print in: a square beside the words, or
/// Code 128 a bar over them -- its weight the largest line, its karat reversed
/// in a box of ink with its stones beside it, and its number small; the second
/// the shop's name small at its top, the piece's name (both cut as the label
/// cuts them) and its size, clear of the chip's bump. The faces' words and the
/// code's kind are the server's -- the printed label's own source -- never put
/// together here. Each face 25 x 13 mm, drawn to that ratio.
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
    final kind = '${faces['code_type'] ?? 'datamatrix'}';
    final weight = faces['weight'] == null ? '' : '${faces['weight']}';
    final karat = faces['karat'] == null ? null : '${faces['karat']}';
    final stones = faces['stones'] == null ? null : '${faces['stones']}';
    final big = faceHeight * 0.3;
    final words = [
      if (weight.isNotEmpty)
        FittedBox(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(weight.substring(0, weight.length - 1),
                  style: TextStyle(fontSize: big, fontWeight: FontWeight.w700, height: 1)),
              Text(weight.substring(weight.length - 1), style: TextStyle(fontSize: big / 2, height: 1)),
            ],
          ),
        ),
      if (karat != null || stones != null)
        FittedBox(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (karat != null)
              Container(
                key: const Key('label-preview-karat'),
                padding: EdgeInsets.symmetric(horizontal: faceHeight * 0.04),
                decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(2)),
                child: Text(karat, style: TextStyle(color: paper, fontWeight: FontWeight.w700)),
              ),
            if (karat != null && stones != null) SizedBox(width: faceHeight * 0.05),
            if (stones != null) Text(stones),
          ]),
        ),
      if (number.isNotEmpty) FittedBox(child: Text(number, style: TextStyle(fontSize: faceHeight * 0.12))),
    ];
    final bar = kind == 'code128';
    final symbol = code.isEmpty
        ? null
        : BarcodeWidget(
            key: Key('label-preview-code-$kind'),
            barcode: switch (kind) {
              'qr' => Barcode.qrCode(),
              'aztec' => Barcode.aztec(),
              'code128' => Barcode.code128(),
              _ => Barcode.dataMatrix(),
            },
            data: code,
            width: bar ? faceWidth * 0.75 : faceHeight * 0.7,
            height: bar ? faceHeight * 0.26 : faceHeight * 0.7,
            drawText: false,
            color: ink,
          );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          face(
            'label-preview-first',
            bar
                ? Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [?symbol, ...words]),
                    ),
                  )
                : Row(children: [
                    ?symbol,
                    SizedBox(width: faceHeight * 0.1),
                    Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: words)),
                  ]),
          ),
          const SizedBox(width: 8),
          face(
            'label-preview-second',
            // upright, starting from the tail as Arabic does: the shop's name at its top, the piece's name
            // above the chip's bump, the size at the face's foot under it (the owner's prints, 27 Nov 2026)
            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (faces['brand'] != null)
                  FittedBox(
                    child: Text('${faces['brand']}', textDirection: TextDirection.rtl,
                        style: TextStyle(fontSize: faceHeight * 0.12, color: theme.colorScheme.onSurfaceVariant)),
                  )
                else
                  const SizedBox.shrink(),
                Padding(
                  padding: EdgeInsets.only(top: faces['brand'] != null ? 0 : faceHeight * 0.18),
                  child: faces['name'] != null
                      ? FittedBox(
                          child: Text('${faces['name']}', textDirection: TextDirection.rtl,
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                        )
                      : const SizedBox.shrink(),
                ),
                if (faces['size'] != null) FittedBox(child: Text('${faces['size']}')) else const SizedBox.shrink(),
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
