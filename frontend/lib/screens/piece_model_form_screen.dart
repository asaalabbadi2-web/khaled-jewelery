import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api_service.dart';
import '../theme/app_tokens.dart';
import '../utils/photo_resize.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

/// The photo sized down on the device (ADR-093 §7): at most [photoSide] px,
/// a JPEG within what the server takes, and its [thumbnailSide] px thumbnail
/// for the lists -- data URIs; null when the bytes are not an image.
const photoSide = 1200;
const thumbnailSide = 240;
const _photoMaxBytes = 580000; // under the server's 600 KB
const _thumbnailMaxBytes = 58000;

({String photo, String thumbnail})? modelPhotoPair(Uint8List bytes) {
  final photo = downsizeToJpeg(bytes, side: photoSide, maxBytes: _photoMaxBytes);
  if (photo == null) return null;
  final thumbnail = downsizeToJpeg(photo, side: thumbnailSide, maxBytes: _thumbnailMaxBytes)!;
  return (
    photo: 'data:image/jpeg;base64,${base64Encode(photo)}',
    thumbnail: 'data:image/jpeg;base64,${base64Encode(thumbnail)}',
  );
}

/// A data URI's image, or a placeholder.
class ModelImage extends StatelessWidget {
  const ModelImage({super.key, required this.uri, this.height});

  final String? uri;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final data = uri;
    Uint8List? bytes;
    if (data != null && data.contains(',')) {
      try {
        bytes = base64Decode(data.substring(data.indexOf(',') + 1));
      } catch (_) {
        bytes = null;
      }
    }
    return Container(
      height: height,
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
  String? _photo;
  String? _thumbnail;
  bool _photoChanged = false;
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
          _photo = model['photo'] as String?;
          _thumbnail = model['thumbnail'] as String?;
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

  Future<void> _choosePhoto() async {
    final bytes = await widget.pickPhoto(context);
    if (bytes == null || !mounted) return;
    try {
      final pair = modelPhotoPair(bytes);
      if (pair == null) {
        AppFeedback.error(context, 'الملف ليس صورة');
        return;
      }
      setState(() {
        _photo = pair.photo;
        _thumbnail = pair.thumbnail;
        _photoChanged = true;
      });
    } on FormatException catch (e) {
      AppFeedback.error(context, e.message);
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
      if (!_editing || _photoChanged) 'photo': _photo,
      if (!_editing || _photoChanged) 'thumbnail': _thumbnail,
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
          child: ModelImage(uri: _photo ?? _thumbnail, height: 220),
        ),
        const SizedBox(height: AppSpace.sm),
        OutlinedButton.icon(
          key: const Key('model-photo'),
          onPressed: _saving ? null : _choosePhoto,
          icon: const Icon(Icons.photo_camera_outlined),
          label: Text(_photo == null ? 'إضافة صورة' : 'تغيير الصورة'),
        ),
        if (_photo != null)
          TextButton(
            key: const Key('model-photo-remove'),
            onPressed: _saving
                ? null
                : () => setState(() {
                      _photo = null;
                      _thumbnail = null;
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
