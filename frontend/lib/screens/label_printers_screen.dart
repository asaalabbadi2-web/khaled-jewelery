import 'package:flutter/material.dart';

import '../api_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import 'reader_check_screen.dart';

/// «إعداد الطابعات» (ADR-097 ط5; the manager's, system.settings): each label
/// printer on the shop's network -- a record, not a setting -- its address,
/// on or off, its state asked, its font installed once, a calibration, a
/// test label with no tag. What the printer says is the server's words.
class LabelPrintersScreen extends StatefulWidget {
  const LabelPrintersScreen({super.key, this.api});
  final ApiService? api;

  @override
  State<LabelPrintersScreen> createState() => _LabelPrintersScreenState();
}

class _LabelPrintersScreenState extends State<LabelPrintersScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  List<Map<String, dynamic>>? _printers;
  Object? _error;
  final Map<int, Map<String, dynamic>> _states = {};
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final printers = ((await _api.labelPrinters())['printers'] as List? ?? []).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() => _printers = printers);
      for (final p in printers) {
        _ask(p['id'] as int);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _ask(int id) async {
    try {
      final state = await _api.labelPrinterStatus(id);
      if (mounted) setState(() => _states[id] = state['status'] as Map<String, dynamic>);
    } catch (_) {}
  }

  Future<void> _act(int id, String action) async {
    setState(() => _busy.add(id));
    try {
      final done = await _api.labelPrinterAction(id, action);
      if (mounted) AppFeedback.success(context, '${done['message']}');
      await _load();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _edit([Map<String, dynamic>? printer]) async {
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PrinterDialog(printer: printer),
    );
    if (body == null || !mounted) return;
    try {
      if (printer == null) {
        await _api.addLabelPrinter(body);
      } else {
        await _api.updateLabelPrinter(printer['id'] as int, body);
      }
      await _load();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _switch(Map<String, dynamic> printer, bool on) async {
    try {
      await _api.updateLabelPrinter(printer['id'] as int, {'is_active': on});
      await _load();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final printers = _printers;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('إعداد الطابعات'),
          actions: [
            // a reader set up once, checked here before a count relies on it (ADR-085 ت0)
            TextButton.icon(
              key: const Key('printers-reader-check'),
              // the bar's own ink: a text button's is the bar's colour, unseen on it
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).appBarTheme.foregroundColor),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => ReaderCheckScreen(api: _api))),
              icon: const Icon(Icons.sensors),
              label: const Text('فحص القارئ'),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('printers-add'),
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('إضافة طابعة'),
        ),
        body: _error != null && printers == null
            ? AppErrorView(title: 'تعذّر تحميل الطابعات', error: _error!, onRetry: _load)
            : printers == null
                ? const AppLoadingView()
                : printers.isEmpty
                    ? const AppEmptyView(
                        title: 'لا طابعة بطاقات بعد',
                        hint: 'أضف الطابعة بعنوانها على شبكة المحل، ثم حمّل الخط واطبع بطاقة تجربة.',
                        icon: Icons.print_disabled,
                      )
                    : ListView(
                        padding: const EdgeInsets.all(16),
                        children: [for (final p in printers) _card(context, p)],
                      ),
      ),
    );
  }

  Widget _card(BuildContext context, Map<String, dynamic> p) {
    final theme = Theme.of(context);
    final id = p['id'] as int;
    final state = _states[id];
    final ready = state?['ready'] == true;
    final busy = _busy.contains(id);
    Widget action(String key, String text, IconData icon, String what) => OutlinedButton.icon(
          key: Key('printer-$key-$id'),
          onPressed: busy ? null : () => _act(id, what),
          icon: Icon(icon),
          label: Text(text),
        );
    return Card(
      key: Key('printer-$id'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: Text('${p['name']}', style: theme.textTheme.titleMedium)),
              Switch(
                key: Key('printer-active-$id'),
                value: p['is_active'] == true,
                onChanged: (on) => _switch(p, on),
              ),
            ]),
            Text('${p['host']}:${p['port']}', textDirection: TextDirection.ltr, textAlign: TextAlign.right),
            const SizedBox(height: 8),
            Text(
              state == null ? 'تُسأل الطابعة…' : (ready ? 'جاهزة' : '${state['message']}'),
              key: Key('printer-state-$id'),
              style: TextStyle(color: ready ? theme.colorScheme.primary : theme.colorScheme.error),
            ),
            Text(
              p['font_installed_at'] == null ? 'الخط العربي لم يُحمَّل بعد' : 'الخط العربي محمَّل',
              key: Key('printer-font-state-$id'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                key: Key('printer-ask-$id'),
                onPressed: () => _ask(id),
                icon: const Icon(Icons.refresh),
                label: const Text('فحص'),
              ),
              action('font', 'تحميل الخط', Icons.font_download_outlined, 'install-font'),
              action('calibrate', 'معايرة', Icons.straighten, 'calibrate'),
              action('test', 'بطاقة تجربة', Icons.print, 'test-label'),
              TextButton.icon(
                key: Key('printer-edit-$id'),
                onPressed: () => _edit(p),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('تعديل'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// A printer's name, its address on the network and its port.
class _PrinterDialog extends StatefulWidget {
  const _PrinterDialog({this.printer});
  final Map<String, dynamic>? printer;

  @override
  State<_PrinterDialog> createState() => _PrinterDialogState();
}

class _PrinterDialogState extends State<_PrinterDialog> {
  late final _name = TextEditingController(text: '${widget.printer?['name'] ?? ''}');
  late final _host = TextEditingController(text: '${widget.printer?['host'] ?? ''}');
  late final _port = TextEditingController(text: '${widget.printer?['port'] ?? 9100}');

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(widget.printer == null ? 'إضافة طابعة' : 'تعديل الطابعة'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              key: const Key('printer-name'), controller: _name,
              decoration: const InputDecoration(labelText: 'اسم الطابعة')),
          TextField(
            key: const Key('printer-host'),
            controller: _host,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(labelText: 'عنوانها على الشبكة', hintText: '192.168.1.50'),
          ),
          TextField(
            key: const Key('printer-port'),
            controller: _port,
            textDirection: TextDirection.ltr,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'المنفذ'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('إلغاء')),
          FilledButton(
            key: const Key('printer-save'),
            onPressed: () {
              if (_name.text.trim().isEmpty || _host.text.trim().isEmpty) return;
              Navigator.of(context).pop({
                'name': _name.text.trim(),
                'host': _host.text.trim(),
                'port': int.tryParse(_port.text.trim()) ?? 9100,
              });
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }
}
