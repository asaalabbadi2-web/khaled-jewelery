import 'package:flutter/material.dart';

import '../api_service.dart';
import '../utils/currency_utils.dart' show formatGrams;
import '../widgets/app_state_views.dart';

/// «استلامات بلا فاتورة» (ADR-087 R2): a supplier's gold received, its
/// invoice not yet completed -- in the books, its wage not yet. Each is
/// completed from here; before the year's count, none should be left.
class PendingReceiptsScreen extends StatefulWidget {
  const PendingReceiptsScreen({super.key, this.api, this.onComplete});
  final ApiService? api;

  /// Opens the purchase screen completing the receipt; true when it was.
  final Future<bool?> Function(BuildContext context, Map<String, dynamic> receipt)? onComplete;

  @override
  State<PendingReceiptsScreen> createState() => _PendingReceiptsScreenState();
}

class _PendingReceiptsScreenState extends State<PendingReceiptsScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  List<Map<String, dynamic>>? _receipts;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final receipts = await _api.pendingReceipts();
      if (mounted) setState(() => _receipts = receipts);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _complete(Map<String, dynamic> receipt) async {
    final done = await widget.onComplete?.call(context, receipt);
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final receipts = _receipts;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('استلامات بلا فاتورة')),
        body: _error != null
            ? AppErrorView(title: 'تعذّر تحميل الاستلامات', error: _error, onRetry: _load)
            : receipts == null
            ? const AppLoadingView()
            : receipts.isEmpty
            ? const AppEmptyView(
                title: 'لا استلام ينتظر فاتورته',
                icon: Icons.task_alt,
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [for (final r in receipts) _tile(context, r)],
                ),
              ),
      ),
    );
  }

  Widget _tile(BuildContext context, Map<String, dynamic> r) {
    final weights = (r['weight_by_karat'] as Map? ?? {}).entries
        .map((e) => 'عيار ${e.key}: ${formatGrams((e.value as num).toDouble(), decimals: 2)} جم')
        .join(' · ');
    final paper = r['supplier_invoice_number'];
    return Card(
      child: ListTile(
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text('${r['supplier_name'] ?? '-'} — ${r['invoice_number'] ?? ''}'),
        subtitle: Text([
          (r['date'] as String? ?? '').split('T').first,
          if (paper != null) 'ورقة المورد $paper',
          weights,
        ].join('\n')),
        isThreeLine: true,
        trailing: FilledButton(
          key: Key('complete-${r['id']}'),
          onPressed: widget.onComplete == null ? null : () => _complete(r),
          child: const Text('استكمال الفاتورة'),
        ),
      ),
    );
  }
}
