import 'package:flutter/material.dart';

import '../api_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

/// «الأقسام» (ADR-093 amendment; the owner, 21 Nov 2026): the kind with no
/// karat, over its categories -- «أساور» over «سوار ذهب 18» and «سوار ذهب 21».
/// A grouping only: no balance. Each category's section is the owner's: a
/// category with none is offered the server's suggestion -- its name with no
/// karat and nothing in brackets -- written in its field, saved only when the
/// owner presses «حفظ». Scrap takes none, and is not listed.
class ItemSectionsScreen extends StatefulWidget {
  const ItemSectionsScreen({super.key, this.api});
  final ApiService? api;

  @override
  State<ItemSectionsScreen> createState() => _ItemSectionsScreenState();
}

class _ItemSectionsScreenState extends State<ItemSectionsScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  List<Map<String, dynamic>>? _sections;
  List<Map<String, dynamic>>? _rows;
  final Map<int, TextEditingController> _fields = {};
  Object? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final results = await Future.wait([_api.itemSections(), _api.itemSectionSuggestions()]);
      if (!mounted) return;
      final sections = (results[0]['sections'] as List? ?? []).cast<Map<String, dynamic>>();
      final rows = (results[1]['categories'] as List? ?? []).cast<Map<String, dynamic>>();
      final names = {for (final s in sections) s['id']: '${s['name']}'};
      for (final c in _fields.values) {
        c.dispose();
      }
      _fields.clear();
      for (final r in rows) {
        final current = names[r['section_id']];
        _fields[r['category_id'] as int] =
            TextEditingController(text: current ?? '${r['suggested'] ?? ''}');
      }
      setState(() {
        _sections = sections;
        _rows = rows;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String? _currentName(Map<String, dynamic> row) {
    final id = row['section_id'];
    if (id == null) return null;
    final found = (_sections ?? const []).where((s) => s['id'] == id);
    return found.isEmpty ? null : '${found.first['name']}';
  }

  String _typed(int categoryId) => (_fields[categoryId]?.text ?? '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

  /// The rows whose field says other than the section they are in.
  List<Map<String, dynamic>> get _changes => [
        for (final r in _rows ?? const <Map<String, dynamic>>[])
          if (_typed(r['category_id'] as int) != (_currentName(r) ?? ''))
            {'category_id': r['category_id'], 'section_name': _typed(r['category_id'] as int)},
      ];

  Future<void> _save() async {
    final changes = _changes;
    if (changes.isEmpty) return;
    setState(() => _saving = true);
    try {
      await _api.assignItemSections(changes);
      if (!mounted) return;
      AppFeedback.success(context, 'حُفظت أقسام ${changes.length} تصنيف');
      await _load();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rename(Map<String, dynamic> section) async {
    final controller = TextEditingController(text: '${section['name']}');
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('اسم القسم'),
          content: TextField(key: const Key('section-rename'), controller: controller, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialog).pop(), child: const Text('إلغاء')),
            FilledButton(
              key: const Key('section-rename-save'),
              onPressed: () => Navigator.of(dialog).pop(controller.text),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await _act(() => _api.updateItemSection(section['id'] as int, {'name': name}));
  }

  Future<void> _act(Future<Object?> Function() call) async {
    try {
      await call();
      await _load();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final changes = _rows == null ? 0 : _changes.length;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('الأقسام')),
        floatingActionButton: _rows == null
            ? null
            : FloatingActionButton.extended(
                key: const Key('sections-save'),
                onPressed: changes == 0 || _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(changes == 0 ? 'لا تغيير' : 'حفظ ($changes)'),
              ),
        body: _error != null && _rows == null
            ? AppErrorView(title: 'تعذّر تحميل الأقسام', error: _error!, onRetry: _load)
            : _rows == null
                ? const AppLoadingView()
                : _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final names = [for (final s in _sections ?? const <Map<String, dynamic>>[]) '${s['name']}'];
    return Align(
      alignment: Alignment.topCenter,
      // narrow (the owner, 22 Nov 2026): a category beside its section, not across the screen
      child: ConstrainedBox(
        key: const Key('sections-body'),
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            // three short lines, not one block of three sentences
            for (final (i, rule) in const [
              'القسم هو النوع بلا عيار، فوق تصنيفاته: «أساور» فوق «سوار ذهب 18» و«سوار ذهب 21».',
              'يُجرد به ويُجمع به، ولا رصيد له.',
              'التصنيف الذي لا قسم له مكتوب في حقله اقتراح؛ عدّل ما تريد ثم احفظ، ولا يُحفظ شيء قبل ذلك.',
            ].indexed)
              Padding(
                key: Key('sections-rule-$i'),
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('•  ', style: theme.textTheme.bodyMedium),
                  Expanded(child: Text(rule, style: theme.textTheme.bodyMedium)),
                ]),
              ),
            const SizedBox(height: 16),
            if ((_sections ?? const []).isNotEmpty) ...[
              Text('الأقسام', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in _sections!)
                  InputChip(
                    key: Key('section-${s['id']}'),
                    label: Text('${s['name']} (${(s['categories'] as List).length})'),
                    onPressed: () => _rename(s),
                    onDeleted: (s['categories'] as List).isEmpty
                        ? () => _act(() => _api.deleteItemSection(s['id'] as int))
                        : null,
                  ),
              ]),
              const SizedBox(height: 16),
            ],
            Text('التصنيفات', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(flex: 2, child: Text('التصنيف', style: theme.textTheme.labelLarge)),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: Text('القسم', style: theme.textTheme.labelLarge)),
            ]),
            const Divider(),
            for (final r in _rows!) _row(context, r, names),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> r, List<String> names) {
    final theme = Theme.of(context);
    final id = r['category_id'] as int;
    final current = _currentName(r);
    final typed = _typed(id);
    final changed = typed != (current ?? '');
    final suggested = current == null && typed.isNotEmpty && typed == '${r['suggested'] ?? ''}';
    return Padding(
      key: Key('section-row-$id'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          flex: 2,
          child: Text(
            '${r['category_name']}${r['is_active'] == false ? ' (موقوف)' : ''}',
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: changed ? FontWeight.w700 : null),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: TextField(
            key: Key('section-field-$id'),
            controller: _fields[id],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'بلا قسم',
              helperText: suggested ? 'مقترح — يُحفظ إن حفظت' : (changed ? 'سيتغيّر' : null),
              suffixIcon: names.isEmpty
                  ? null
                  : PopupMenuButton<String>(
                      key: Key('section-pick-$id'),
                      tooltip: 'اختر قسمًا',
                      icon: const Icon(Icons.arrow_drop_down),
                      onSelected: (name) => setState(() => _fields[id]!.text = name),
                      itemBuilder: (_) => [for (final n in names) PopupMenuItem(value: n, child: Text(n))],
                    ),
            ),
          ),
        ),
      ]),
    );
  }
}
