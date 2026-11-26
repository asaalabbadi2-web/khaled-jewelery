import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils.dart' show NormalizeNumberFormatter;
import '../utils/currency_utils.dart' as cu;
import '../utils/currency_utils.dart' show formatAmount;
import '../widgets/app_feedback.dart';
import '../widgets/app_leave_guard.dart';
import '../widgets/app_state_views.dart';
import 'financial_change_dialog.dart';
import 'settings_editors.dart';
import 'settings_opener.dart';
import 'settings_registry.dart';

/// A section of the center edited in place (settings spec v2 §6–7; ADR-102):
/// each setting with its value written beside its control; what changed is
/// saved together -- only what changed, at the version seen -- from the bar
/// that shows when something did. A key another user moved since is a
/// conflict the user settles key by key, their values kept; a refused or
/// failed save keeps them too. A financial (level-3) setting is changed alone,
/// through its confirmation: before and after, its effect, how far it is
/// undone, and its reason (ADR-103). Leaving with changes unsaved asks first.
class SectionEditor extends StatefulWidget {
  const SectionEditor({
    super.key,
    required this.section,
    required this.api,
    this.financialAllowed = false,
    this.highlight,
    this.onDirtyChanged,
    this.opener = openSettingEntry,
  });

  final SettingsSection section;
  final SettingsOpener opener;
  final ApiService api;
  final bool financialAllowed;

  /// The id of the setting a search opened: framed, and brought into view.
  final String? highlight;
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<SectionEditor> createState() => SectionEditorState();
}

class SectionEditorState extends State<SectionEditor> {
  final _initial = <String, Object?>{};
  final _draft = <String, Object?>{};
  final _versions = <String, int>{};
  final _text = <String, TextEditingController>{};
  final _rowKeys = <String, GlobalKey>{};
  Object? _loadError;
  bool _loaded = false;
  bool _saving = false;
  String? _barError;
  List<Map<String, dynamic>> _conflicts = const [];
  bool _wasDirty = false;
  String _currency = '';

  List<SettingEntry> get _entries => editedIn(widget.section);

  List<String> get dirtyKeys => [
        for (final e in _entries)
          if (!editors[e.key]!.same(_initial[e.key], _draft[e.key])) e.key!,
      ];

  bool get isDirty => dirtyKeys.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final settings = await widget.api.getSettings();
      final versions = await widget.api.getSettingsVersions();
      if (!mounted) return;
      setState(() {
        _currency = '${settings['currency_symbol'] ?? ''}';
        for (final e in _entries) {
          final key = e.key!;
          final spec = editors[key]!;
          final value = spec.read(settings[key]);
          _initial[key] = value;
          _draft[key] = value;
          _versions[key] = versions[key] ?? 0;
          if (spec.kind == EditorKind.text || spec.kind == EditorKind.currency) {
            _text[key] = TextEditingController(text: '${value ?? ''}');
          }
          _rowKeys[e.id] = GlobalKey();
        }
        _loaded = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final row = _rowKeys[widget.highlight]?.currentContext;
        if (row != null) Scrollable.ensureVisible(row, alignment: 0.2, duration: const Duration(milliseconds: 300));
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _set(String key, Object? value) {
    setState(() {
      _draft[key] = value;
      _barError = null;
    });
    _notifyDirty();
  }

  void _notifyDirty() {
    final now = isDirty;
    if (now != _wasDirty) {
      _wasDirty = now;
      widget.onDirtyChanged?.call(now);
    }
  }

  void discard() {
    setState(() {
      for (final k in _initial.keys) {
        _draft[k] = _initial[k];
        _text[k]?.text = '${_initial[k] ?? ''}';
      }
      _conflicts = const [];
      _barError = null;
    });
    _notifyDirty();
  }

  String _labelOf(String key) => settingsRegistry.firstWhere((e) => e.key == key).label;

  Future<void> save() async {
    final keys = dirtyKeys;
    if (keys.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final result = await widget.api.patchSettings(
        changes: {for (final k in keys) k: editors[k]!.write(_draft[k])},
        versions: {for (final k in keys) k: _versions[k] ?? 0},
      );
      if (!mounted) return;
      final saved = (result['versions'] as Map?) ?? const {};
      setState(() {
        for (final k in keys) {
          _initial[k] = _draft[k];
          _versions[k] = (saved[k] as num?)?.toInt() ?? _versions[k]!;
        }
        _saving = false;
        _conflicts = const [];
        _barError = null;
      });
      _notifyDirty();
      AppFeedback.success(context, 'حُفظ: ${keys.map(_labelOf).join('، ')}');
      _refreshApp();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (e.statusCode == 409) {
          _conflicts = [for (final c in (e.details['conflicts'] as List? ?? const [])) (c as Map).cast<String, dynamic>()];
          _barError = null;
        } else {
          _barError = e.message;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _barError = AppFeedback.messageOf(e);
      });
    }
  }

  void _refreshApp() {
    try {
      context.read<SettingsProvider>().fetchSettings();
    } catch (_) {}
  }

  /// Take the other user's value: it is the one now, and the key is no
  /// longer among this user's changes.
  void acceptTheirs(Map<String, dynamic> c) {
    final key = c['key'] as String;
    final value = editors[key]!.read(c['current']);
    setState(() {
      _initial[key] = value;
      _draft[key] = value;
      _text[key]?.text = '${value ?? ''}';
      _versions[key] = (c['current_version'] as num).toInt();
      _conflicts = [for (final x in _conflicts) if (x['key'] != key) x];
    });
    _notifyDirty();
  }

  /// Keep this user's value: saved over the other's, knowingly.
  void keepMine(Map<String, dynamic> c) {
    final key = c['key'] as String;
    setState(() {
      _initial[key] = editors[key]!.read(c['current']);
      _versions[key] = (c['current_version'] as num).toInt();
      _conflicts = [for (final x in _conflicts) if (x['key'] != key) x];
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final info = sections[widget.section]!;
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('تعذّر تحميل الإعدادات: ${AppFeedback.messageOf(_loadError!)}',
              style: TextStyle(color: cs.error)),
        ),
      );
    }
    if (!_loaded) return const AppLoadingView(summaryBlocks: 0, rows: 6);
    final showBar = isDirty || _conflicts.isNotEmpty || _barError != null;
    return AppLeaveGuard(
      controllers: const [],
      isDirty: () => isDirty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              key: Key('settings-editor-${widget.section.name}'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(info.label, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
                  child: Text('للمنشأة كلها: يُحفظ في الخادم ويسري على كل الأجهزة.',
                      style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
                const SizedBox(height: 8),
                for (final e in _entries) _row(e),
                if (widget.section == SettingsSection.tax && _draft['tax_enabled'] == true) _taxExamples(),
                for (final e in entriesOf(widget.section).where((e) => e.kind == SettingKind.link))
                  Card(
                    margin: const EdgeInsets.only(top: 8),
                    elevation: 0,
                    color: cs.surfaceContainerHigh,
                    child: ListTile(
                      key: Key('settings-entry-${e.id}'),
                      title: Text(e.label),
                      subtitle: e.description.isEmpty ? null : Text(e.description),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () => widget.opener(context, e),
                    ),
                  ),
              ],
            ),
          ),
          if (showBar) _bar(),
        ],
      ),
    );
  }

  Widget _row(SettingEntry e) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final key = e.key!;
    final spec = editors[key]!;
    final dirty = !spec.same(_initial[key], _draft[key]);
    final enabled = spec.dependsOn == null || _draft[spec.dependsOn] == true;
    final highlighted = widget.highlight == e.id;
    final financial = e.level == 3;
    final control = financial ? _financialControl(e, spec, enabled) : _control(e, spec, enabled);
    return Container(
      key: _rowKeys[e.id],
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: highlighted ? cs.secondaryContainer : (dirty ? cs.tertiaryContainer : null),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: highlighted ? cs.primary : cs.outlineVariant, width: highlighted ? 2 : 1),
      ),
      child: Column(
        key: Key('settings-row-${e.id}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Text(dirty ? '${e.label} ●' : e.label,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (financial || spec.kind == EditorKind.toggle) control,
          ]),
          if (e.description.isNotEmpty)
            Text(e.description, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          if (e.level >= 2 && e.effect != null)
            Text(e.effect!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          if (!financial && spec.kind != EditorKind.toggle) ...[const SizedBox(height: 6), control],
          if (financial && !widget.financialAllowed)
            Text(needsFinancialPermission, key: Key('settings-needs-permission-$key'),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  /// A financial setting: its value said, and changed alone through its
  /// confirmation (ADR-102, ADR-103) -- never with the section's bar.
  Widget _financialControl(SettingEntry e, EditorSpec spec, bool enabled) {
    final key = e.key!;
    final theme = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(
        child: Text(spec.display(_draft[key]), key: Key('settings-value-$key'),
            style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
      ),
      const SizedBox(width: 8),
      OutlinedButton(
        key: Key('settings-change-$key'),
        onPressed: enabled && widget.financialAllowed ? () => _changeFinancial(e, spec) : null,
        child: const Text('تغيير…'),
      ),
    ]);
  }

  Future<void> _changeFinancial(SettingEntry e, EditorSpec spec) async {
    final key = e.key!;
    String? staleNote;
    final saved = await showFinancialChange(
      context,
      entry: e,
      spec: spec,
      current: _draft[key],
      save: (value, reason) async {
        try {
          final result = await widget.api.patchSettings(
            changes: {key: value},
            versions: {key: _versions[key] ?? 0},
            reason: reason,
          );
          if (!mounted) return (error: null, stale: false);
          final versions = (result['versions'] as Map?) ?? const {};
          setState(() {
            _initial[key] = spec.read(value); // as the server keeps it, read back
            _draft[key] = _initial[key];
            _versions[key] = (versions[key] as num?)?.toInt() ?? _versions[key]!;
          });
          return (error: null, stale: false);
        } on ApiException catch (err) {
          if (err.statusCode != 409) return (error: err.message, stale: false);
          final c = [for (final x in (err.details['conflicts'] as List? ?? const [])) (x as Map)]
              .where((x) => x['key'] == key)
              .firstOrNull;
          if (c != null && mounted) {
            setState(() {
              _initial[key] = spec.read(c['current']);
              _draft[key] = _initial[key];
              _versions[key] = (c['current_version'] as num).toInt();
            });
          }
          staleNote = '«${e.label}»: غيّره ${c?['changed_by'] ?? 'مستخدم آخر'} بعد أن فتحت الصفحة؛ '
                'القيمة الآن ${spec.display(_draft[key])}. راجعها ثم غيّرها من جديد إن أردت.';
          return (error: staleNote, stale: true);
        } catch (err) {
          return (error: AppFeedback.messageOf(err), stale: false);
        }
      },
    );
    if (!mounted) return;
    if (saved == true) {
      AppFeedback.success(context, 'حُفظ: ${e.label}');
      _refreshApp();
    } else if (staleNote != null) {
      AppFeedback.warning(context, staleNote!);
    }
  }

  /// The old tax tab's worked examples, at the rate now set.
  Widget _taxExamples() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final rate = ((_draft['tax_rate'] as num?) ?? 0).toDouble();
    Widget money(double v, {TextStyle? style}) =>
        cu.CurrencyText(amount: v, symbol: _currency, style: style ?? theme.textTheme.bodyMedium);
    return Card(
      key: const Key('settings-tax-examples'),
      margin: const EdgeInsets.only(top: 8),
      elevation: 0,
      color: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('أمثلة حسابية بالنسبة الحالية', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final amount in const [1000.0, 5000.0, 10000.0])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Wrap(spacing: 12, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                money(amount),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('ضريبة: ', style: theme.textTheme.bodyMedium),
                  money(amount * rate / 100),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('الإجمالي: ', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                  money(amount * (1 + rate / 100), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                ]),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _control(SettingEntry e, EditorSpec spec, bool enabled) {
    final key = e.key!;
    final theme = Theme.of(context);
    switch (spec.kind) {
      case EditorKind.toggle:
        final on = _draft[key] == true;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Text(on ? 'مفعّل' : 'معطّل', style: theme.textTheme.labelMedium),
          Switch(key: Key('settings-field-$key'), value: on, onChanged: enabled ? (v) => _set(key, v) : null),
        ]);
      case EditorKind.text:
        return TextField(
          key: Key('settings-field-$key'),
          controller: _text[key],
          enabled: enabled,
          keyboardType: spec.digits ? TextInputType.number : TextInputType.text,
          inputFormatters: spec.digits ? [NormalizeNumberFormatter()] : null,
          decoration: InputDecoration(isDense: true, hintText: spec.hint, border: const OutlineInputBorder()),
          onChanged: (v) => _set(key, v),
        );
      case EditorKind.percent:
        final v = ((_draft[key] as num?) ?? 0).toDouble().clamp(0, spec.max).toDouble();
        return Row(children: [
          Expanded(
            child: Slider(
              key: Key('settings-field-$key'),
              value: v,
              min: 0,
              max: spec.max,
              divisions: (spec.max / spec.step).round(),
              label: '${formatAmount(v, decimals: 1)}%',
              onChanged: enabled ? (x) => _set(key, x) : null,
            ),
          ),
          Text('${formatAmount(v, decimals: 1)}%', style: theme.textTheme.titleSmall),
        ]);
      case EditorKind.karats:
        return KaratChips(
            keyPrefix: 'settings-field-$key', value: _draft[key], onChanged: enabled ? (v) => _set(key, v) : null);
      case EditorKind.choice:
        return Wrap(spacing: 8, runSpacing: 6, children: [
          for (final (value, label) in spec.options)
            ChoiceChip(
              key: Key('settings-field-$key-$value'),
              label: Text(label),
              selected: _draft[key] == value,
              onSelected: enabled ? (_) => _set(key, value) : null,
            ),
        ]);
      case EditorKind.currency:
        final current = '${_draft[key] ?? ''}';
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final (value, label) in spec.options)
              ChoiceChip(
                key: Key('settings-field-$key-${spec.options.indexWhere((o) => o.$1 == value)}'),
                label: value == cu.kSarNewSymbol
                    ? cu.SarSymbolImage(size: 18, color: theme.colorScheme.onSurface)
                    : Text(label),
                selected: current == value,
                onSelected: (_) {
                  _text[key]?.text = '$value';
                  _set(key, value);
                },
              ),
          ]),
          if (current != cu.kSarNewSymbol) ...[
            const SizedBox(height: 6),
            TextField(
              key: Key('settings-field-$key'),
              controller: _text[key],
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              onChanged: (v) => _set(key, v),
            ),
          ],
        ]);
    }
  }

  Widget _bar() {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final tone = _conflicts.isNotEmpty || _barError != null ? tones.blocked : tones.warning;
    final n = dirtyKeys.length;
    return Material(
      key: const Key('settings-save-bar'),
      color: tone.container,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in _conflicts) _conflictCard(c),
              if (_barError != null)
                Text('تعذّر الحفظ: $_barError', key: const Key('settings-save-error'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: tone.onContainer)),
              Row(children: [
                Expanded(
                  child: Text(
                    _conflicts.isNotEmpty
                        ? 'غيّر مستخدم آخر بعض هذه الإعدادات بعد أن فتحتها: راجعها ثم احفظ'
                        : n == 1
                        ? 'تعديل واحد لم يُحفظ في هذا القسم'
                        : n == 2
                        ? 'تعديلان لم يُحفظا في هذا القسم'
                        : '$n تعديلات لم تُحفظ في هذا القسم',
                    style: theme.textTheme.bodyMedium?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(key: const Key('settings-discard'), onPressed: _saving ? null : discard,
                    child: const Text('تجاهل التعديلات')),
                const SizedBox(width: 6),
                FilledButton(
                  key: const Key('settings-save'),
                  onPressed: _saving || _conflicts.isNotEmpty || !isDirty ? null : save,
                  child: Text(_barError != null ? 'إعادة المحاولة' : 'حفظ'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _conflictCard(Map<String, dynamic> c) {
    final theme = Theme.of(context);
    final key = c['key'] as String;
    String said(Object? v) => '${v ?? '—'}';
    return Card(
      key: Key('settings-conflict-$key'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('«${_labelOf(key)}»: غيّره ${c['changed_by'] ?? 'مستخدم آخر'} بعد أن فتحت الصفحة',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text('الآن: ${said(c['current'])} · قيمتك: ${said(c['yours'])}', style: theme.textTheme.bodyMedium),
          Wrap(spacing: 8, children: [
            TextButton(key: Key('settings-take-theirs-$key'), onPressed: () => acceptTheirs(c),
                child: const Text('اعتمد قيمته')),
            TextButton(key: Key('settings-keep-mine-$key'), onPressed: () => keepMine(c),
                child: const Text('احفظ قيمتي فوقها')),
          ]),
        ]),
      ),
    );
  }
}
