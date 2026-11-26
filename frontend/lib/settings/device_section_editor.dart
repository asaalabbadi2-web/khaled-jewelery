import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/settings_provider.dart';
import '../utils/paper_format.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/invoice_settings_sheet.dart' show InvoiceUiContext, InvoiceUiSettings;
import 'settings_registry.dart';

/// A device setting: how it is read and written on this device, and what it
/// is when it was never set -- what the screens that read it take then, not a
/// guess (the voucher print reads A4: voucher_preview_screen.dart).
class DeviceSetting {
  const DeviceSetting({required this.read, required this.write, this.options = const []});

  final Future<Object?> Function(BuildContext context) read;
  final Future<void> Function(BuildContext context, Object? value) write;

  /// A choice's (stored value, label); none is a switch.
  final List<(String, String)> options;
}

const voucherPaperKey = 'printer_paper_size_v1';
const voucherPaperSizes = ['58 مم', '80 مم', 'A4'];
const printInColorKey = 'print_in_color';

/// The settings of «هذا الجهاز», by their registry key (settings spec v2,
/// phase 7, batch 8): each read where the screens that use it read it, and
/// saved there the moment it changes -- no server, no save bar. The old tabs
/// no longer hold them (test/settings_registry_test.dart). The printer's
/// auto-connect, preview, auto-cut and preferred printer were saved and read
/// by nothing -- every print opens the system's dialog -- so they are gone
/// (the owner, 26 Nov 2026).
final Map<String, DeviceSetting> deviceSettings = {
  printInColorKey: DeviceSetting(
    read: (_) async => (await SharedPreferences.getInstance()).getBool(printInColorKey) ?? true,
    write: (_, v) async => (await SharedPreferences.getInstance()).setBool(printInColorKey, v == true),
  ),
  'invoice_ui_settings_v1.global.paper_size': DeviceSetting(
    read: (_) async => (await InvoiceUiSettings.load(InvoiceUiContext.saleNew)).paperSize,
    write: (_, v) => InvoiceUiSettings.setPaperSize('$v'),
    options: [for (final p in InvoiceUiSettings.supportedPaperSizes) (p, paperLabel(p))],
  ),
  voucherPaperKey: DeviceSetting(
    read: (_) async {
      final stored = (await SharedPreferences.getInstance()).getString(voucherPaperKey);
      return voucherPaperSizes.contains(stored) ? stored : 'A4';
    },
    write: (_, v) async => (await SharedPreferences.getInstance()).setString(voucherPaperKey, '$v'),
    options: [for (final p in voucherPaperSizes) (p, paperLabel(p))],
  ),
  // Held by the settings provider: the login screen reads it from there.
  'ui_show_gold_price_ticker_on_login_v1': DeviceSetting(
    read: (context) async => context.read<SettingsProvider>().showGoldPriceTickerOnLogin,
    write: (context, v) => context.read<SettingsProvider>().setShowGoldPriceTickerOnLogin(v == true),
  ),
};

/// «هذا الجهاز» edited in the center: each setting with its value, saved on
/// this device as it changes, said so; a save that fails puts the value back.
class DeviceSectionEditor extends StatefulWidget {
  const DeviceSectionEditor({super.key, this.highlight});

  /// The id of the setting a search opened: framed.
  final String? highlight;

  @override
  State<DeviceSectionEditor> createState() => _DeviceSectionEditorState();
}

class _DeviceSectionEditorState extends State<DeviceSectionEditor> {
  final _values = <String, Object?>{};
  Object? _error;
  bool _loaded = false;

  List<SettingEntry> get _entries => [
        for (final e in entriesOf(SettingsSection.thisDevice))
          if (e.kind == SettingKind.setting && deviceSettings.containsKey(e.key)) e,
      ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = {for (final e in _entries) e.key!: await deviceSettings[e.key]!.read(context)};
      if (!mounted) return;
      setState(() {
        _values
          ..clear()
          ..addAll(values);
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _set(SettingEntry e, Object? value) async {
    final key = e.key!;
    final before = _values[key];
    setState(() => _values[key] = value);
    try {
      await deviceSettings[key]!.write(context, value);
      if (mounted) AppFeedback.success(context, 'حُفظ على هذا الجهاز: ${e.label}');
    } catch (err) {
      if (!mounted) return;
      setState(() => _values[key] = before);
      AppFeedback.error(context, err, title: 'تعذّر الحفظ على هذا الجهاز');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (_error != null) {
      return AppErrorView(title: 'تعذّر قراءة إعدادات هذا الجهاز', error: _error, onRetry: _load);
    }
    if (!_loaded) return const AppLoadingView(summaryBlocks: 0, rows: 4);
    final info = sections[SettingsSection.thisDevice]!;
    return ListView(
      key: const Key('settings-editor-thisDevice'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(info.label, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
          child: Text('يُحفظ في هذا الجهاز وحده فور تغييره، ولا تراه الأجهزة الأخرى.',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ),
        const SizedBox(height: 8),
        for (final e in _entries) _row(e),
      ],
    );
  }

  Widget _row(SettingEntry e) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final key = e.key!;
    final setting = deviceSettings[key]!;
    final highlighted = widget.highlight == e.id;
    final on = _values[key] == true;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: highlighted ? cs.secondaryContainer : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: highlighted ? cs.primary : cs.outlineVariant, width: highlighted ? 2 : 1),
      ),
      child: Column(
        key: Key('settings-row-${e.id}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: Text(e.label, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
            if (setting.options.isEmpty) ...[
              Text(on ? 'مفعّل' : 'معطّل', style: theme.textTheme.labelMedium),
              Switch(key: Key('settings-field-${e.id}'), value: on, onChanged: (v) => _set(e, v)),
            ],
          ]),
          if (e.description.isNotEmpty)
            Text(e.description, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          if (setting.options.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final (value, label) in setting.options)
                ChoiceChip(
                  key: Key('settings-field-${e.id}-$value'),
                  label: Text(label),
                  selected: _values[key] == value,
                  onSelected: (_) => _set(e, value),
                ),
            ]),
          ],
        ],
      ),
    );
  }
}
