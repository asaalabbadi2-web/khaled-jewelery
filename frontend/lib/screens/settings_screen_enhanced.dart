import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import 'settings_center_screen.dart';

/// What is left of the old settings screen (settings spec v2, phase 7
/// cleanup): every setting moved into the settings center, but one -- the
/// voucher auto-post, held where it was set until the owner's decision D2
/// (settings_editors.heldBack). Its switch, its words and its save are the old
/// tab's: the key alone, through PUT /settings, as it was sent before.
class SettingsScreenEnhanced extends StatefulWidget {
  const SettingsScreenEnhanced({super.key, this.api});

  /// The API it reads the setting through (tests pass a fake).
  final ApiService? api;

  @override
  State<SettingsScreenEnhanced> createState() => _SettingsScreenEnhancedState();
}

class _SettingsScreenEnhancedState extends State<SettingsScreenEnhanced> {
  late final ApiService _api = widget.api ?? ApiService();
  bool? _saved;
  bool _value = false;
  Object? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final settings = await _api.getSettings();
      final raw = settings['voucher_auto_post'];
      final on = raw == true || raw == 1 || raw == 'true';
      if (!mounted) return;
      setState(() {
        _saved = on;
        _value = on;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<SettingsProvider>().updateSettings({'voucher_auto_post': _value});
      if (!mounted) return;
      setState(() => _saved = _value);
      AppFeedback.success(context, 'حُفظ: ترحيل السندات تلقائيًا عند الحفظ');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'تعذّر الحفظ');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final Widget body;
    if (_error != null) {
      body = AppErrorView(title: 'تعذّر تحميل الإعدادات', error: _error, onRetry: _load);
    } else if (_saved == null) {
      body = const AppLoadingView(summaryBlocks: 0, rows: 2);
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            key: const Key('held-settings-note'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.info_outline, color: cs.primary),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('الإعدادات كلها في مركز الإعدادات، إلا هذا: يبقى هنا حتى القرار D2.'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsCenterScreen()),
                ),
                child: const Text('افتح المركز'),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: cs.surfaceContainerLow,
            child: SwitchListTile.adaptive(
              key: const Key('held-voucher-auto-post'),
              value: _value,
              onChanged: _saving ? null : (v) => setState(() => _value = v),
              title: const Text('ترحيل السندات تلقائياً عند الحفظ'),
              subtitle: const Text(
                'عند التفعيل سيتم إنشاء قيد محاسبي فور حفظ السند. عند الإيقاف ستُحفظ السندات غير مُرحّلة وتحتاج للترحيل/الموافقة يدوياً.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              key: const Key('held-save'),
              onPressed: _saving || _value == _saved ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('حفظ'),
            ),
          ),
        ],
      );
    }
    return Scaffold(appBar: AppBar(title: const Text('ترحيل السندات')), body: body);
  }
}
