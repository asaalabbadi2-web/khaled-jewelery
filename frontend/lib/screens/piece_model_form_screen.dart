import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../api_service.dart';
import '../theme/app_tokens.dart';
import '../utils/photo_resize.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

/// The photo sized down on the device (ADR-093 §7): at most [photoSide] px,
/// a JPEG within what the server takes, and its [thumbnailSide] px thumbnail
/// for the lists -- each then sent to the attachments' store (ADR-094); null
/// when the bytes are not an image. The thumbnail 480 px (the owner, 27 Nov
/// 2026: «صور الموديلات تبدو متدنية الدقه»): a list's box of 140 points is 280
/// to 420 pixels on a phone, a reader or a Mac -- 240 was stretched.
const photoSide = 1200;
const thumbnailSide = 480;
const _photoMaxBytes = 580000;
const _thumbnailMaxBytes = 150000;

({Uint8List photo, Uint8List thumbnail})? modelPhotoPair(Uint8List bytes) {
  final photo = downsizeToJpeg(bytes, side: photoSide, maxBytes: _photoMaxBytes);
  if (photo == null) return null;
  return (photo: photo, thumbnail: downsizeToJpeg(photo, side: thumbnailSide, maxBytes: _thumbnailMaxBytes)!);
}

/// A model's photo: its [bytes] when just chosen, else the attachment
/// [attachmentId] read through the server (ADR-094) -- each read once, kept
/// in memory for the screens that show it again; a placeholder when none.
class ModelImage extends StatefulWidget {
  const ModelImage({super.key, this.api, this.attachmentId, this.bytes, this.height, this.fullId});

  final ApiService? api;
  final int? attachmentId;
  final Uint8List? bytes;
  final double? height;

  /// The model's photo itself, opened whole on a tap (the owner, 27 Nov 2026): its engraving is what
  /// tells one model from another, and a list's box is too small for it.
  final int? fullId;

  static final _read = <int, Future<Uint8List>>{};

  /// For a test: what was read is forgotten.
  static void forgetRead() => _read.clear();

  @override
  State<ModelImage> createState() => _ModelImageState();
}

class _ModelImageState extends State<ModelImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(ModelImage old) {
    super.didUpdateWidget(old);
    if (old.attachmentId != widget.attachmentId || old.bytes != widget.bytes) _read();
  }

  Future<void> _read() async {
    if (widget.bytes != null) {
      setState(() => _bytes = widget.bytes);
      return;
    }
    final id = widget.attachmentId;
    final api = widget.api;
    if (id == null || api == null) {
      setState(() => _bytes = null);
      return;
    }
    try {
      final reading = ModelImage._read.putIfAbsent(id, () => api.attachmentBytes(id));
      final bytes = await reading;
      if (mounted && widget.attachmentId == id) setState(() => _bytes = bytes);
    } catch (_) {
      ModelImage._read.remove(id); // read again next time
      if (mounted) setState(() => _bytes = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bytes = _bytes;
    final frame = Container(
      height: widget.height,
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: bytes == null
          ? LayoutBuilder(
              // small (a list's leading box): the icon alone, the words with room
              builder: (context, box) => box.maxHeight < 96
                  ? Icon(Icons.image_outlined, color: cs.onSurfaceVariant, semanticLabel: 'لا صورة بعد')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.image_outlined, size: 40, color: cs.onSurfaceVariant),
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          'لا صورة بعد',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
            )
          : Image.memory(bytes, fit: BoxFit.cover, width: double.infinity),
    );
    if (bytes == null || widget.fullId == null || widget.api == null) return frame;
    // the whole frame answers the tap, not the image alone -- still decoding, it has no height yet
    return Semantics(
      button: true,
      label: 'افتح الصورة كاملة',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showModelPhoto(context, widget.api!, widget.fullId!),
        child: MouseRegion(cursor: SystemMouseCursors.zoomIn, child: frame),
      ),
    );
  }
}

/// A model's photo whole, pinched or wheeled to look closer.
Future<void> showModelPhoto(BuildContext context, ApiService api, int photoId) => showDialog<void>(
      context: context,
      builder: (dialog) => Dialog(
        key: const Key('model-photo-full'),
        insetPadding: const EdgeInsets.all(AppSpace.md),
        child: Stack(children: [
          InteractiveViewer(
            maxScale: 6,
            child: ModelImage(api: api, attachmentId: photoId),
          ),
          PositionedDirectional(
            top: 4,
            end: 4,
            child: IconButton.filledTonal(
              tooltip: 'إغلاق',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(dialog).pop(),
            ),
          ),
        ]),
      ),
    );

/// What a square [side] frame shows of a photo of [image] size, laid to cover it and moved by
/// [transform]: the rectangle in the photo's own pixels, within it.
Rect cropRectOf(Size image, double side, Matrix4 transform) {
  final cover = side / math.min(image.width, image.height);
  final inverse = Matrix4.inverted(transform);
  final a = MatrixUtils.transformPoint(inverse, Offset.zero) / cover;
  final b = MatrixUtils.transformPoint(inverse, Offset(side, side)) / cover;
  final cut = Rect.fromPoints(a, b).intersect(Offset.zero & image);
  return Rect.fromLTRB(cut.left.roundToDouble(), cut.top.roundToDouble(), cut.right.roundToDouble(),
      cut.bottom.roundToDouble());
}

/// A photo chosen, cut to a square the piece fills (the owner, 27 Nov 2026): its frame moved and zoomed
/// -- or kept as it is. Null when the dialog is left; the bytes when not an image.
Future<Uint8List?> cropToPiece(BuildContext context, Uint8List bytes) async {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) return bytes;                       // not an image: said where it is sized down
  return showDialog<Uint8List>(context: context, builder: (_) => _CropDialog(bytes: bytes, image: decoded!));
}

class _CropDialog extends StatefulWidget {
  const _CropDialog({required this.bytes, required this.image});

  final Uint8List bytes;
  final img.Image image;

  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  static const _side = 300.0;
  late final _size = Size(widget.image.width.toDouble(), widget.image.height.toDouble());
  late final _cover = _side / math.min(_size.width, _size.height);
  // laid to cover the square, centred
  late final _transform = TransformationController(Matrix4.identity()
    ..translateByDouble((_side - _size.width * _cover) / 2, (_side - _size.height * _cover) / 2, 0, 1));

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _cut() {
    final r = cropRectOf(_size, _side, _transform.value);
    final cut = img.copyCrop(widget.image,
        x: r.left.toInt(), y: r.top.toInt(), width: r.width.toInt(), height: r.height.toInt());
    Navigator.of(context).pop(Uint8List.fromList(img.encodeJpg(cut, quality: 95)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('قصّ الصورة حول القطعة'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('حرّك الصورة وكبّرها حتى تملأ القطعة المربع', style: theme.textTheme.bodySmall),
        const SizedBox(height: AppSpace.sm),
        Container(
          key: const Key('crop-frame'),
          width: _side,
          height: _side,
          decoration: BoxDecoration(border: Border.all(color: theme.colorScheme.primary, width: 2)),
          child: ClipRect(
            child: InteractiveViewer(
              transformationController: _transform,
              constrained: false,
              minScale: 1,
              maxScale: 8,
              boundaryMargin: EdgeInsets.zero,
              child: SizedBox(
                width: _size.width * _cover,
                height: _size.height * _cover,
                child: Image.memory(widget.bytes, fit: BoxFit.fill),
              ),
            ),
          ),
        ),
      ]),
      actions: [
        TextButton(
          key: const Key('crop-skip'),
          onPressed: () => Navigator.of(context).pop(widget.bytes),
          child: const Text('استخدمها كما هي'),
        ),
        FilledButton(key: const Key('crop-use'), onPressed: _cut, child: const Text('قصّ')),
      ],
    );
  }
}

/// How a photo is chosen: the device's gallery or camera (tests give bytes).
typedef PhotoPicker = Future<Uint8List?> Function(BuildContext context);

Future<Uint8List?> pickModelPhoto(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('من المعرض'),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('بالكاميرا'),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
        ],
      ),
    ),
  );
  if (source == null) return null;
  final picked = await ImagePicker().pickImage(
    source: source,
    maxWidth: photoSide.toDouble(),
    maxHeight: photoSide.toDouble(),
    imageQuality: 85,
    requestFullMetadata: false,
  );
  return picked == null ? null : await picked.readAsBytes();
}

/// «إعداد الموديل» (ADR-093 M1): its photo, name, category, supplier's code,
/// expected wage, stones, and the sizes it comes in -- of its category's
/// size system. A piece's wage is its invoice's: this one is compared at
/// receiving, never given to a piece. The laws are the server's.
class PieceModelFormScreen extends StatefulWidget {
  const PieceModelFormScreen({
    super.key,
    required this.api,
    this.modelId,
    this.categoryId,
    this.pickPhoto = pickModelPhoto,
  });

  final ApiService api;
  final int? modelId;
  final int? categoryId;
  final PhotoPicker pickPhoto;

  @override
  State<PieceModelFormScreen> createState() => _PieceModelFormScreenState();
}

class _PieceModelFormScreenState extends State<PieceModelFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _wage = TextEditingController();
  bool _stones = false;
  int? _categoryId;
  final _sizeIds = <int>{};
  List<Map<String, dynamic>>? _categories;
  List<Map<String, dynamic>> _systems = const [];
  Map<String, dynamic>? _model;
  // the photo chosen now, its ids once sent; else the model's ids (ADR-094)
  Uint8List? _photoBytes;
  int? _photoId;
  int? _thumbnailId;
  bool _photoChanged = false;
  bool _sendingPhoto = false;
  Object? _error;
  bool _saving = false;

  bool get _editing => widget.modelId != null;

  @override
  void initState() {
    super.initState();
    _categoryId = widget.categoryId;
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _wage.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final categories = await widget.api.getCategories();
      final systems = await widget.api.getSizeSystems();
      final model =
          _editing ? await widget.api.getPieceModel(widget.modelId!) : null;
      if (!mounted) return;
      setState(() {
        _categories = [
          for (final c in categories)
            if ((c as Map)['is_scrap'] != true) Map<String, dynamic>.from(c),
        ];
        _systems = systems;
        _model = model;
        if (model != null) {
          _name.text = '${model['name'] ?? ''}';
          _code.text = '${model['supplier_code'] ?? ''}';
          final wage = model['expected_wage_per_gram'];
          _wage.text = wage == null ? '' : '$wage';
          _stones = model['has_stones'] == true;
          _categoryId = (model['category'] as Map)['id'] as int;
          _sizeIds
            ..clear()
            ..addAll([for (final s in model['sizes'] as List) (s as Map)['id'] as int]);
          _photoId = model['photo_id'] as int?;
          _thumbnailId = model['thumbnail_id'] as int?;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic>? get _category =>
      _categories?.where((c) => c['id'] == _categoryId).firstOrNull;

  Map<String, dynamic>? get _system {
    final id = _category?['size_system_id'];
    return id == null ? null : _systems.where((s) => s['id'] == id).firstOrNull;
  }

  /// A photo chosen: sized down here, then the photo and its thumbnail
  /// sent to the store; the model saved links them.
  Future<void> _choosePhoto() async {
    final picked = await widget.pickPhoto(context);
    if (picked == null || !mounted) return;
    // cut to the piece, or kept whole (the owner, 27 Nov 2026)
    final bytes = await cropToPiece(context, picked);
    if (bytes == null || !mounted) return;
    ({Uint8List photo, Uint8List thumbnail})? pair;
    try {
      pair = modelPhotoPair(bytes);
    } on FormatException catch (e) {
      AppFeedback.error(context, e.message);
      return;
    }
    if (pair == null) {
      AppFeedback.error(context, 'الملف ليس صورة');
      return;
    }
    setState(() => _sendingPhoto = true);
    try {
      final photo = await widget.api.uploadAttachment(pair.photo, role: 'model_photo');
      final thumbnail = await widget.api.uploadAttachment(pair.thumbnail, role: 'model_thumbnail');
      if (!mounted) return;
      setState(() {
        _photoBytes = pair!.photo;
        _photoId = photo['id'] as int;
        _thumbnailId = thumbnail['id'] as int;
        _photoChanged = true;
      });
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم تُرفع الصورة');
    } finally {
      if (mounted) setState(() => _sendingPhoto = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final body = <String, dynamic>{
      'category_id': _categoryId,
      'name': _name.text.trim(),
      'supplier_code': _code.text.trim(),
      'expected_wage_per_gram': _wage.text.trim(),
      'has_stones': _stones,
      'size_ids': _sizeIds.toList(),
      if (!_editing || _photoChanged) 'photo_id': _photoId,
      if (!_editing || _photoChanged) 'thumbnail_id': _thumbnailId,
    };
    try {
      if (_editing) {
        await widget.api.updatePieceModel(widget.modelId!, body);
      } else {
        await widget.api.createPieceModel(body);
      }
      if (!mounted) return;
      AppFeedback.success(context, 'حُفظ الموديل «${body['name']}»');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setActive(bool active) async {
    setState(() => _saving = true);
    try {
      await widget.api.updatePieceModel(widget.modelId!, {'is_active': active});
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('حذف «${_model?['name']}»؟'),
        content: const Text('لا قطعة منه بعد، فيُحذف. الموديل الذي له قطع يُوقف ولا يُحذف.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            key: const Key('model-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    setState(() => _saving = true);
    try {
      await widget.api.deletePieceModel(widget.modelId!);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'إعداد الموديل' : 'موديل جديد')),
      body: _error != null
          ? AppErrorView(title: 'تعذّر تحميل الموديل', error: _error, onRetry: _load)
          : _categories == null
              ? const AppLoadingView(summaryBlocks: 1)
              : Form(key: _form, child: _body(context)),
      bottomNavigationBar: _categories == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    FilledButton.icon(
                      key: const Key('model-save'),
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.check),
                      label: const Text('حفظ'),
                    ),
                    if (_editing && _model?['is_active'] != false)
                      OutlinedButton(
                        key: const Key('model-stop'),
                        onPressed: _saving ? null : () => _setActive(false),
                        child: const Text('إيقاف'),
                      ),
                    if (_editing && _model?['is_active'] == false)
                      OutlinedButton(
                        key: const Key('model-restart'),
                        onPressed: _saving ? null : () => _setActive(true),
                        child: const Text('إعادة تشغيل'),
                      ),
                    if (_editing && (_model?['pieces'] as int? ?? 0) == 0)
                      TextButton(
                        key: const Key('model-delete'),
                        onPressed: _saving ? null : _delete,
                        child: const Text('حذف'),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final photo = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: ModelImage(api: widget.api, bytes: _photoBytes, attachmentId: _photoId, height: 220),
        ),
        const SizedBox(height: AppSpace.sm),
        OutlinedButton.icon(
          key: const Key('model-photo'),
          onPressed: _saving || _sendingPhoto ? null : _choosePhoto,
          icon: _sendingPhoto
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.photo_camera_outlined),
          label: Text(_sendingPhoto ? 'تُرفع الصورة' : (_photoId == null ? 'إضافة صورة' : 'تغيير الصورة')),
        ),
        if (_photoId != null)
          TextButton(
            key: const Key('model-photo-remove'),
            onPressed: _saving
                ? null
                : () => setState(() {
                      _photoBytes = null;
                      _photoId = null;
                      _thumbnailId = null;
                      _photoChanged = true;
                    }),
            child: const Text('إزالة الصورة'),
          ),
        Text('تُصغَّر قبل الحفظ (أقصاها $photoSide بكسل)', style: theme.textTheme.bodySmall),
      ],
    );
    final fields = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const Key('model-name'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'اسم الموديل'),
          validator: (v) => (v ?? '').trim().isEmpty ? 'اكتب اسم الموديل' : null,
        ),
        const SizedBox(height: AppSpace.md),
        DropdownButtonFormField<int>(
          key: const Key('model-category'),
          initialValue: _categoryId,
          decoration: const InputDecoration(labelText: 'التصنيف'),
          items: [
            for (final c in _categories!)
              DropdownMenuItem(value: c['id'] as int, child: Text('${c['name']}')),
          ],
          validator: (v) => v == null ? 'اختر التصنيف' : null,
          onChanged: (_model?['pieces'] as int? ?? 0) > 0
              ? null
              : (v) => setState(() {
                    _categoryId = v;
                    _sizeIds.clear();
                  }),
        ),
        const SizedBox(height: AppSpace.md),
        TextFormField(
          key: const Key('model-code'),
          controller: _code,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(labelText: 'رمز المورد (اختياري)'),
        ),
        const SizedBox(height: AppSpace.md),
        TextFormField(
          key: const Key('model-wage'),
          controller: _wage,
          textDirection: TextDirection.ltr,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'الأجرة المتوقّعة للجرام (اختياري)'),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          'أجرة القطعة من فاتورة المورد وحدها. هذه الأجرة للمقارنة: ينبّه الاستلام '
          'إذا اختلفت الفاتورة عنها، وتعديلها لا يغيّر أجرة أي قطعة.',
          key: const Key('model-wage-note'),
          style: theme.textTheme.bodySmall,
        ),
        SwitchListTile.adaptive(
          key: const Key('model-stones'),
          contentPadding: EdgeInsets.zero,
          value: _stones,
          title: const Text('بفصوص'),
          subtitle: const Text('تُوزن فصوص كل قطعة في المحطة'),
          onChanged: (v) => setState(() => _stones = v),
        ),
      ],
    );
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        LayoutBuilder(
          builder: (context, box) => box.maxWidth >= 760
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 260, child: photo),
                    const SizedBox(width: AppSpace.xl),
                    Expanded(child: fields),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [photo, const SizedBox(height: AppSpace.lg), fields],
                ),
        ),
        const SizedBox(height: AppSpace.lg),
        _sizes(context),
        if (_editing) ...[
          const SizedBox(height: AppSpace.md),
          Text(
            'في المخزون منه: ${_model?['pieces'] ?? 0} قطعة',
            key: const Key('model-pieces'),
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ],
    );
  }

  Widget _sizes(BuildContext context) {
    final theme = Theme.of(context);
    final system = _system;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('المقاسات التي يأتي بها', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpace.xs),
            if (_category == null)
              Text('اختر التصنيف أولًا', style: theme.textTheme.bodySmall)
            else if (system == null)
              Text(
                '«${_category!['name']}» بلا نظام مقاسات: اختره من تعديل التصنيف، '
                'أو احفظ الموديل بلا مقاسات.',
                key: const Key('model-no-system'),
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text('من نظام «${system['name']}»', style: theme.textTheme.bodySmall),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: [
                  for (final s in system['sizes'] as List)
                    FilterChip(
                      key: Key('model-size-${(s as Map)['id']}'),
                      selected: _sizeIds.contains(s['id']),
                      label: Text('${s['label']}', textDirection: TextDirection.ltr),
                      onSelected: (on) => setState(() {
                        on ? _sizeIds.add(s['id'] as int) : _sizeIds.remove(s['id']);
                      }),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
