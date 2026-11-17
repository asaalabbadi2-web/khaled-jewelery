import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_tokens.dart';

/// The scrap purchase's photos (ADR-094; the owner, 17 Nov 2026): sized down
/// on the device, each sent as it is taken and kept by the server pending
/// under its sender; the invoice saved names those sent. A photo not sent
/// is never lost in silence: the screen asks before saving without it.
const goldPhotoSide = 1600;
const goldPhotoMaxBytes = 1900000; // under the server's 2 MB
const goldPhotosMax = 10; // the owner, 17 Nov 2026

class GoldPhoto {
  GoldPhoto(this.bytes);

  final Uint8List bytes;
  int? id; // the server's, once sent
  bool sending = false;
  Object? error;

  bool get sent => id != null;
}

/// What a save sends: the ids sent; and what waits or failed, to be asked about.
({List<int> ids, int sending, int failed}) goldPhotosToSave(List<GoldPhoto> photos) => (
      ids: [for (final p in photos) if (p.id != null) p.id!],
      sending: photos.where((p) => p.sending).length,
      failed: photos.where((p) => !p.sending && p.id == null).length,
    );

/// The strip of photos being taken: each its state -- sending, sent, or not
/// sent with a way to send it again -- and its removal.
class GoldPhotoStrip extends StatelessWidget {
  const GoldPhotoStrip({super.key, required this.photos, required this.onRemove, required this.onRetry});

  final List<GoldPhoto> photos;
  final void Function(int index) onRemove;
  final void Function(int index) onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 120,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpace.sm),
        itemBuilder: (context, i) {
          final photo = photos[i];
          return SizedBox(
            key: Key('gold-photo-$i'),
            width: 120,
            height: 120,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  child: Image.memory(photo.bytes, fit: BoxFit.cover),
                ),
                if (photo.sending)
                  Container(
                    color: cs.surface.withValues(alpha: 0.6),
                    alignment: Alignment.center,
                    child: const CircularProgressIndicator(semanticsLabel: 'تُرفع الصورة'),
                  )
                else if (!photo.sent)
                  Material(
                    color: cs.errorContainer.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    child: InkWell(
                      key: Key('gold-photo-retry-$i'),
                      onTap: () => onRetry(i),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.cloud_off, color: cs.onErrorContainer),
                          Text('لم تُرفع — أعد المحاولة',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onErrorContainer)),
                        ],
                      ),
                    ),
                  )
                else
                  Positioned(
                    bottom: AppSpace.xs,
                    right: AppSpace.xs,
                    child: Icon(Icons.cloud_done, color: cs.primary, semanticLabel: 'رُفعت'),
                  ),
                Positioned(
                  top: AppSpace.xs,
                  left: AppSpace.xs,
                  child: IconButton.filled(
                    key: Key('gold-photo-remove-$i'),
                    tooltip: 'إزالة الصورة',
                    onPressed: () => onRemove(i),
                    icon: const Icon(Icons.close, size: 18),
                    style: IconButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                      minimumSize: const Size(28, 28),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The photos an invoice was saved with, read through the server -- shown in
/// its preview; a photo opened, large.
class InvoicePhotos extends StatefulWidget {
  const InvoicePhotos({super.key, required this.api, required this.invoiceId});

  final ApiService api;
  final int invoiceId;

  @override
  State<InvoicePhotos> createState() => _InvoicePhotosState();
}

class _InvoicePhotosState extends State<InvoicePhotos> {
  List<Uint8List>? _photos;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final listed = await widget.api.invoiceAttachments(widget.invoiceId);
      final bytes = <Uint8List>[];
      for (final a in listed) {
        bytes.add(await widget.api.attachmentBytes(a['id'] as int));
      }
      if (mounted) setState(() => _photos = bytes);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) {
      return Text('تعذّر تحميل صور الفاتورة', key: const Key('invoice-photos-failed'), style: theme.textTheme.bodySmall);
    }
    final photos = _photos;
    if (photos == null) return const LinearProgressIndicator(minHeight: 2);
    if (photos.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('invoice-photos'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('صور الذهب (${photos.length})', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpace.sm),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: photos.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpace.sm),
            itemBuilder: (context, i) => InkWell(
              key: Key('invoice-photo-$i'),
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(child: InteractiveViewer(child: Image.memory(photos[i]))),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.control),
                child: Image.memory(photos[i], width: 96, height: 96, fit: BoxFit.cover),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
