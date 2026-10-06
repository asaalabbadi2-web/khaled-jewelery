import 'package:flutter/material.dart';

import '../api_service.dart';
import '../utils/bidi.dart';

/// The public holiday calendar (ADR-037): days the banks deposit nothing.
/// A payment method that skips public holidays moves its deposit to the next
/// day that is not one. The owner keeps it -- the two Eids, National Day ...
class PublicHolidaysDialog extends StatefulWidget {
  final ApiService api;

  const PublicHolidaysDialog({super.key, required this.api});

  static Future<void> show(BuildContext context, {required ApiService api}) =>
      showDialog<void>(
        context: context,
        builder: (_) => PublicHolidaysDialog(api: api),
      );

  @override
  State<PublicHolidaysDialog> createState() => _PublicHolidaysDialogState();
}

class _PublicHolidaysDialogState extends State<PublicHolidaysDialog> {
  final _nameController = TextEditingController();
  DateTime? _date;
  List<Map<String, dynamic>> _holidays = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.api.getPublicHolidays();
      if (!mounted) return;
      setState(() {
        _holidays = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _add() async {
    final name = _nameController.text.trim();
    if (_date == null || name.isEmpty) {
      setState(() => _error = 'اختر التاريخ واكتب اسم الإجازة');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.addPublicHoliday(date: _iso(_date!), name: name);
      _nameController.clear();
      _date = null;
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    try {
      await widget.api.deletePublicHoliday(id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('تقويم الإجازات الرسمية'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'أيام لا يودع فيها البنك. تتجاوزها وسيلة الدفع التي اختارت «لا إيداع في الإجازات الرسمية».',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event),
                    label: Text(_date == null ? 'التاريخ' : ltrIsolate(_iso(_date!))),
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _date ?? now,
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 3),
                      );
                      if (picked != null) setState(() => _date = picked);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'اسم الإجازة',
                      hintText: 'عيد الفطر',
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'إضافة',
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add_circle_outline),
                  onPressed: _saving ? null : _add,
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const Divider(height: 24),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_holidays.isEmpty)
              Text('لا إجازات مسجّلة.', style: theme.textTheme.bodySmall)
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final h in _holidays)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.beach_access_outlined),
                        title: Text('${h['name']}'),
                        subtitle: Text(ltrIsolate('${h['date']}')),
                        trailing: IconButton(
                          tooltip: 'حذف',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(h['id'] as int),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
      ],
    );
  }
}
