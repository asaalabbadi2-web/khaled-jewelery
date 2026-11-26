import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../settings/section_editor.dart';
import '../widgets/app_leave_guard.dart';
import '../settings/settings_editors.dart';

import '../settings/settings_opener.dart';
import '../settings/settings_registry.dart';
import '../settings/settings_search.dart';
import '../theme/app_semantic_colors.dart';

/// The settings center (settings spec v2, phase 6): a search that reaches the
/// setting itself, and an index of eleven sections in four groups -- no values
/// on its first page. A section lists what is set in it and where; the old
/// settings tabs and the owning screens stay behind it as they are until each
/// section's own page replaces them (phase 7). Every name and place is the
/// registry's (lib/settings/settings_registry.dart).
class SettingsCenterScreen extends StatefulWidget {
  const SettingsCenterScreen({super.key, this.opener = openSettingEntry, this.financialAllowed, this.api});

  final SettingsOpener opener;

  /// The API the moved sections edit through (tests pass a fake).
  final ApiService? api;

  /// Whether the user may change a financial (level-3) setting (ADR-103);
  /// null reads it from the signed-in user.
  final bool? financialAllowed;

  @override
  State<SettingsCenterScreen> createState() => _SettingsCenterScreenState();
}

class _SettingsCenterScreenState extends State<SettingsCenterScreen> {
  final _query = TextEditingController();
  SettingsSection? _section;
  String? _highlight;
  final _editor = GlobalKey<SectionEditorState>();
  late final ApiService _api = widget.api ?? ApiService();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool get _searching => _query.text.trim().isNotEmpty;

  bool get _financial {
    if (widget.financialAllowed != null) return widget.financialAllowed!;
    try {
      return context.read<AuthProvider>().hasPermission('system.financial_settings');
    } catch (_) {
      return false;
    }
  }

  /// A section's page: edited here when it has moved into the center, else
  /// what is set in it and where (phase 6).
  Widget _sectionBody(SettingsSection s, {String? highlight, Key? key}) => movedSections.contains(s)
      ? SectionEditor(key: key, section: s, api: _api, financialAllowed: _financial, highlight: highlight,
          opener: widget.opener)
      : SectionEntries(section: s, opener: widget.opener, financialAllowed: _financial);

  Future<void> _openSection(SettingsSection s, {required bool wide, String? highlight}) async {
    if (wide) {
      // Unsaved changes in the section shown are asked about first.
      if ((_editor.currentState?.isDirty ?? false) && !await AppLeaveGuard.confirmLeave(context)) return;
      if (!mounted) return;
      setState(() {
        _section = s;
        _highlight = highlight;
        _query.clear();
      });
    } else {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(sections[s]!.label)),
          body: _sectionBody(s, highlight: highlight),
        ),
      ));
    }
  }

  /// A setting of a moved section opens on its row, here; anything else where it is set.
  void _openEntry(SettingEntry e) {
    if (e.kind == SettingKind.setting && movedSections.contains(e.section)) {
      _openSection(e.section, wide: MediaQuery.sizeOf(context).width >= 1000, highlight: e.id);
    } else {
      widget.opener(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 260, child: _rail()),
                VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _searchField(),
                      Expanded(
                        child: _searching
                            ? _results()
                            : _section == null
                            ? _index(wide: true)
                            : _sectionBody(_section!, highlight: _highlight,
                                key: movedSections.contains(_section) ? _editor : ValueKey(_section)),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _searchField(),
                Expanded(child: _searching ? _results() : _index(wide: false)),
              ],
            ),
    );
  }

  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          key: const Key('settings-search'),
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'ابحث عن إعداد: الضريبة، حراري، آجل…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searching
                ? IconButton(
                    tooltip: 'مسح البحث',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(_query.clear),
                  )
                : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            final hits = searchSettings(_query.text);
            if (hits.isNotEmpty) _openEntry(hits.first.entry);
          },
        ),
      );

  Widget _rail() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ColoredBox(
      color: cs.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        children: [
          ListTile(
            key: const Key('settings-rail-index'),
            dense: true,
            selected: _section == null && !_searching,
            selectedTileColor: cs.secondaryContainer,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            title: const Text('الفهرس'),
            onTap: () async {
              if ((_editor.currentState?.isDirty ?? false) && !await AppLeaveGuard.confirmLeave(context)) return;
              if (!mounted) return;
              setState(() {
                _section = null;
                _query.clear();
              });
            },
          ),
          for (final group in SettingsGroup.values) ...[
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 12, 2),
              child: Text(groupLabels[group]!,
                  style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700)),
            ),
            for (final s in SettingsSection.values.where((s) => sections[s]!.group == group))
              ListTile(
                key: Key('settings-section-${s.name}'),
                dense: true,
                selected: _section == s && !_searching,
                selectedTileColor: cs.secondaryContainer,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                title: Text(sections[s]!.label),
                trailing: s == SettingsSection.thisDevice ? const Icon(Icons.devices_outlined, size: 18) : null,
                onTap: () => _openSection(s, wide: true),
              ),
          ],
        ],
      ),
    );
  }

  Widget _index({required bool wide}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        for (final group in SettingsGroup.values) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(groupLabels[group]!,
                style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w800)),
          ),
          for (final s in SettingsSection.values.where((s) => sections[s]!.group == group))
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              elevation: 0,
              color: cs.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: ListTile(
                key: Key('settings-index-${s.name}'),
                title: Text(sections[s]!.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(sections[s]!.summary),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => _openSection(s, wide: wide),
              ),
            ),
        ],
      ],
    );
  }

  Widget _results() {
    final hits = searchSettings(_query.text);
    final theme = Theme.of(context);
    if (hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('لا إعداد بهذا الاسم', key: const Key('settings-no-hit'), style: theme.textTheme.titleMedium),
        ),
      );
    }
    final settings = hits.where((h) => h.entry.kind == SettingKind.setting).toList();
    final links = hits.where((h) => h.entry.kind == SettingKind.link).toList();
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(text,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w800)),
        );
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (settings.isNotEmpty) header('إعدادات'),
        for (final h in settings) _hitTile(h),
        if (links.isNotEmpty) header('شاشات'),
        for (final h in links) _hitTile(h),
      ],
    );
  }

  Widget _hitTile(SettingsHit h) {
    final e = h.entry;
    final where = [
      sections[e.section]!.label,
      if (h.matchedBy != null) 'وُجد بـ «${h.matchedBy}»',
      if (e.level == 3 && !_financial) needsFinancialPermission,
    ].join(' · ');
    return ListTile(
      key: Key('settings-hit-${e.id}'),
      title: Row(children: [
        Flexible(child: Text(e.label, style: const TextStyle(fontWeight: FontWeight.w700))),
        if (e.level == 3) const LevelTag(level: 3),
        if (e.scope == SettingScope.device) const DeviceTag(),
      ]),
      subtitle: Text(where),
      trailing: const Icon(Icons.chevron_left),
      onTap: () => _openEntry(e),
    );
  }
}

/// A section's entries: each setting with where it is set today, each screen
/// it links to -- read-only; its own page comes in phase 7.

class SectionEntries extends StatelessWidget {
  const SectionEntries({super.key, required this.section, required this.opener, this.financialAllowed = false});

  final SettingsSection section;
  final SettingsOpener opener;
  final bool financialAllowed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final info = sections[section]!;
    final device = section == SettingsSection.thisDevice;
    final entries = entriesOf(section);
    final settings = entries.where((e) => e.kind == SettingKind.setting).toList();
    final links = entries.where((e) => e.kind == SettingKind.link).toList();
    return ListView(
      key: Key('settings-section-view-${section.name}'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(info.label, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: device ? tones.info.container : cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            device
                ? 'يُحفظ في هذا الجهاز وحده، ولا تراه الأجهزة الأخرى.'
                : 'للمنشأة كلها: يُحفظ في الخادم ويسري على كل الأجهزة.',
            style: theme.textTheme.bodySmall?.copyWith(color: device ? tones.info.onContainer : cs.onSurfaceVariant),
          ),
        ),
        for (final e in settings)
          ListTile(
            key: Key('settings-entry-${e.id}'),
            contentPadding: EdgeInsets.zero,
            title: Row(children: [
              Flexible(child: Text(e.label, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (e.level >= 2) LevelTag(level: e.level),
            ]),
            subtitle: Text([
              if (e.description.isNotEmpty) e.description,
              if (e.effect != null) e.effect!,
              if (e.level == 3 && !financialAllowed) needsFinancialPermission,
              'يُضبط اليوم في: ${legacyTabNames[e.legacyTab ?? 0]}',
            ].join('\n')),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => opener(context, e),
          ),
        if (links.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('شاشات مرتبطة', style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
          for (final e in links)
            Card(
              margin: const EdgeInsets.only(top: 6),
              elevation: 0,
              color: cs.surfaceContainerHigh,
              child: ListTile(
                key: Key('settings-entry-${e.id}'),
                title: Text(e.label),
                subtitle: e.description.isEmpty ? null : Text(e.description),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => opener(context, e),
              ),
            ),
        ],
      ],
    );
  }
}

class LevelTag extends StatelessWidget {
  const LevelTag({super.key, required this.level});
  final int level;

  @override
  Widget build(BuildContext context) {
    final tones = AppSemanticColors.of(context);
    final tone = level == 3 ? tones.blocked : tones.warning;
    return Container(
      margin: const EdgeInsetsDirectional.only(start: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(999)),
      child: Text(level == 3 ? 'مالي' : 'تشغيلي',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w700)),
    );
  }
}

class DeviceTag extends StatelessWidget {
  const DeviceTag({super.key});

  @override
  Widget build(BuildContext context) {
    final tone = AppSemanticColors.of(context).info;
    return Container(
      margin: const EdgeInsetsDirectional.only(start: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(999)),
      child: Text('هذا الجهاز',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w700)),
    );
  }
}
