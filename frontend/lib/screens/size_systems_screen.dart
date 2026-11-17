import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

/// «أنظمة المقاسات» (ADR-093 M0; the owner, 17 Nov 2026): the sizes the
/// categories share -- «مقاسات البناجر عندنا 17، 18، 19 وهكذا» and other
/// systems beside it. A system's sizes in their order, each with its
/// optional measurement and the pieces it holds; the categories that follow
/// it. The laws are the server's -- one spelling, a size a piece holds stays,
/// a system a category follows stays: this screen sends and says.
class SizeSystemsScreen extends StatefulWidget {
  const SizeSystemsScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<SizeSystemsScreen> createState() => _SizeSystemsScreenState();
}

class _SizeSystemsScreenState extends State<SizeSystemsScreen> {
  List<Map<String, dynamic>>? _systems;
  Object? _error;
  int? _selectedId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final systems = await widget.api.getSizeSystems();
      if (!mounted) return;
      setState(() {
        _systems = systems;
        if (_selectedId == null ||
            !systems.any((s) => s['id'] == _selectedId)) {
          _selectedId = systems.isEmpty ? null : systems.first['id'] as int;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic>? get _selected =>
      _systems?.where((s) => s['id'] == _selectedId).firstOrNull;

  /// One write: the system it returns replaces its row; a refusal is said.
  Future<void> _write(Future<Map<String, dynamic>> Function() send,
      {String? done}) async {
    setState(() => _busy = true);
    try {
      final system = await send();
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      if (system['id'] is int) setState(() => _selectedId = system['id'] as int);
      if (done != null) AppFeedback.success(context, done);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newSystem() async {
    final result = await _systemDialog(context);
    if (result == null) return;
    await _write(
      () => widget.api.createSizeSystem(
        name: result.name,
        measurementLabel: result.measurementLabel,
      ),
      done: 'أُنشئ النظام «${result.name}»',
    );
  }

  Future<void> _editSystem(Map<String, dynamic> system) async {
    final result = await _systemDialog(context, system: system);
    if (result == null) return;
    await _write(() => widget.api.updateSizeSystem(
          system['id'] as int,
          name: result.name,
          measurementLabel: result.measurementLabel,
        ));
  }

  Future<void> _deleteSystem(Map<String, dynamic> system) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('حذف «${system['name']}»؟'),
        content: const Text('يُحذف النظام ومقاساته. لا يُحذف نظام يتبعه تصنيف.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            key: const Key('size-system-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    setState(() => _busy = true);
    try {
      await widget.api.deleteSizeSystem(system['id'] as int);
      if (!mounted) return;
      _selectedId = null;
      await _load();
      if (mounted) AppFeedback.success(context, 'حُذف النظام');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addSize(Map<String, dynamic> system) async {
    final result = await _sizeDialog(context, system: system);
    if (result == null) return;
    await _write(() => widget.api.addSize(
          system['id'] as int,
          label: result.label,
          measurement: result.measurement,
        ));
  }

  Future<void> _editSize(
      Map<String, dynamic> system, Map<String, dynamic> size) async {
    final result = await _sizeDialog(context, system: system, size: size);
    if (result == null) return;
    await _write(() => widget.api.updateSize(
          size['id'] as int,
          label: result.label,
          measurement: result.measurement,
        ));
  }

  Future<void> _reorder(
      Map<String, dynamic> system, int oldIndex, int newIndex) async {
    final ids = [
      for (final s in (system['sizes'] as List)) (s as Map)['id'] as int,
    ];
    if (newIndex > oldIndex) newIndex -= 1;
    ids.insert(newIndex, ids.removeAt(oldIndex));
    await _write(() => widget.api.reorderSizes(system['id'] as int, ids));
  }

  @override
  Widget build(BuildContext context) {
    final systems = _systems;
    return Scaffold(
      appBar: AppBar(
        title: const Text('أنظمة المقاسات'),
        actions: [
          if (systems != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: AppSpace.sm),
              child: TextButton.icon(
                key: const Key('size-system-new'),
                onPressed: _busy ? null : _newSystem,
                icon: const Icon(Icons.add),
                label: const Text('نظام جديد'),
              ),
            ),
        ],
      ),
      body: _error != null
          ? AppErrorView(
              title: 'تعذّر تحميل أنظمة المقاسات',
              error: _error,
              onRetry: _load,
            )
          : systems == null
              ? const AppLoadingView(summaryBlocks: 1)
              : systems.isEmpty
                  ? AppEmptyView(
                      title: 'لا أنظمة مقاسات بعد',
                      hint: 'أنشئ نظام محلك، مثل «مقاسات البناجر»: 17، 18، 19 …',
                      icon: Icons.straighten,
                      actionLabel: 'نظام جديد',
                      actionIcon: Icons.add,
                      onAction: _newSystem,
                    )
                  : _body(context, systems),
    );
  }

  Widget _body(BuildContext context, List<Map<String, dynamic>> systems) {
    final theme = Theme.of(context);
    final system = _selected;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            for (final s in systems)
              ChoiceChip(
                key: Key('size-system-${s['id']}'),
                selected: s['id'] == _selectedId,
                label: Text('${s['name']}'),
                onSelected: (_) => setState(() => _selectedId = s['id'] as int),
              ),
          ],
        ),
        if (system != null) ...[
          const SizedBox(height: AppSpace.lg),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('${system['name']}',
                            style: theme.textTheme.titleLarge),
                      ),
                      IconButton(
                        key: const Key('size-system-edit'),
                        tooltip: 'تعديل الاسم',
                        onPressed: _busy ? null : () => _editSystem(system),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        key: const Key('size-system-delete'),
                        tooltip: 'حذف النظام',
                        onPressed: _busy ? null : () => _deleteSystem(system),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  Text(
                    _followers(system),
                    key: const Key('size-system-followers'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          _sizes(context, system),
          const SizedBox(height: AppSpace.md),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              key: const Key('size-add'),
              onPressed: _busy ? null : () => _addSize(system),
              icon: const Icon(Icons.add),
              label: const Text('إضافة مقاس'),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            'المقاس يُكتب بإملاء واحد: «١٨» تُحفظ 18، و«2,6» تُحفظ 2.6. '
            'اسحب المقاس لتغيير ترتيبه. مقاس تحمله قطعة لا يُحذف، '
            'وتصحيح إملائه يصل إلى قطعه.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  static String _followers(Map<String, dynamic> system) {
    final names = [
      for (final c in (system['categories'] as List? ?? const []))
        '${(c as Map)['name']}',
    ];
    return names.isEmpty ? 'لا يتبعه تصنيف بعد' : 'يتبعه: ${names.join(' · ')}';
  }

  Widget _sizes(BuildContext context, Map<String, dynamic> system) {
    final theme = Theme.of(context);
    final sizes = [
      for (final s in (system['sizes'] as List? ?? const []))
        Map<String, dynamic>.from(s as Map),
    ];
    if (sizes.isEmpty) {
      return const AppEmptyView(
        title: 'لا مقاسات في هذا النظام',
        icon: Icons.straighten,
      );
    }
    final unit = (system['measurement_label'] as String?)?.trim();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorder: (from, to) {
          if (!_busy) _reorder(system, from, to);
        },
        children: [
          for (var i = 0; i < sizes.length; i++)
            ListTile(
              key: Key('size-${sizes[i]['id']}'),
              leading: ReorderableDragStartListener(
                index: i,
                child: const Icon(Icons.drag_indicator),
              ),
              title: Text(
                '${sizes[i]['label']}',
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.start,
                style: theme.textTheme.titleMedium,
              ),
              subtitle: Text(_sizeLine(sizes[i], unit)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: Key('size-edit-${sizes[i]['id']}'),
                    tooltip: 'تعديل المقاس',
                    onPressed:
                        _busy ? null : () => _editSize(system, sizes[i]),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    key: Key('size-delete-${sizes[i]['id']}'),
                    tooltip: (sizes[i]['pieces'] as int? ?? 0) > 0
                        ? 'تحمله قطع: لا يُحذف'
                        : 'حذف المقاس',
                    onPressed: _busy || (sizes[i]['pieces'] as int? ?? 0) > 0
                        ? null
                        : () => _write(
                              () => widget.api.deleteSize(sizes[i]['id'] as int),
                            ),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _sizeLine(Map<String, dynamic> size, String? unit) {
    final pieces = size['pieces'] as int? ?? 0;
    final measurement = size['measurement'];
    final parts = <String>[
      if (measurement != null)
        '${unit == null || unit.isEmpty ? 'القياس' : unit}: $measurement',
      pieces == 0 ? 'لا تحمله قطعة' : 'تحمله $pieces قطعة',
    ];
    return parts.join(' · ');
  }
}

Future<({String name, String? measurementLabel})?> _systemDialog(
  BuildContext context, {
  Map<String, dynamic>? system,
}) async {
  final name = TextEditingController(text: '${system?['name'] ?? ''}');
  final unit =
      TextEditingController(text: '${system?['measurement_label'] ?? ''}');
  final form = GlobalKey<FormState>();
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(system == null ? 'نظام مقاسات جديد' : 'تعديل النظام'),
      content: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('size-system-name'),
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'اسم النظام',
                hintText: 'مثل: مقاسات البناجر',
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'اكتب اسم النظام' : null,
            ),
            const SizedBox(height: AppSpace.md),
            TextFormField(
              key: const Key('size-system-unit'),
              controller: unit,
              decoration: const InputDecoration(
                labelText: 'ما يُقاس (اختياري)',
                hintText: 'مثل: القطر الداخلي — مم',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          key: const Key('size-system-save'),
          onPressed: () {
            if (form.currentState!.validate()) Navigator.pop(context, true);
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
  if (saved != true) return null;
  final label = unit.text.trim();
  return (name: name.text.trim(), measurementLabel: label.isEmpty ? null : label);
}

Future<({String label, String? measurement})?> _sizeDialog(
  BuildContext context, {
  required Map<String, dynamic> system,
  Map<String, dynamic>? size,
}) async {
  final label = TextEditingController(text: '${size?['label'] ?? ''}');
  final measurement =
      TextEditingController(text: '${size?['measurement'] ?? ''}');
  final unit = (system['measurement_label'] as String?)?.trim();
  final form = GlobalKey<FormState>();
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(size == null ? 'مقاس جديد في «${system['name']}»' : 'تعديل المقاس'),
      content: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('size-label'),
              controller: label,
              autofocus: true,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'المقاس'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'اكتب المقاس' : null,
            ),
            const SizedBox(height: AppSpace.md),
            TextFormField(
              key: const Key('size-measurement'),
              controller: measurement,
              textDirection: TextDirection.ltr,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: unit == null || unit.isEmpty
                    ? 'القياس (اختياري)'
                    : '$unit (اختياري)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          key: const Key('size-save'),
          onPressed: () {
            if (form.currentState!.validate()) Navigator.pop(context, true);
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
  if (saved != true) return null;
  final m = measurement.text.trim();
  return (label: label.text.trim(), measurement: m.isEmpty ? null : m);
}
