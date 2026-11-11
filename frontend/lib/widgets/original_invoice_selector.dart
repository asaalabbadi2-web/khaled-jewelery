import 'dart:async';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart';
import 'app_feedback.dart';

/// The original invoice of a return, chosen (the return audit, M3, 11 Nov 2026).
///
/// Found on the server as it is typed -- by its number as seen
/// (SELL-2026-1982, or 1982), its party, its amount or its weight -- a page at
/// a time; only posted invoices, each with what remains of it. It fetched
/// every invoice at each opening (1,878 sales), the rejected among them, and
/// named each by its row id.
class OriginalInvoiceSelector extends StatelessWidget {
  final ApiService api;
  final String invoiceType;
  final int? customerId;
  final int? supplierId;
  final Map<String, dynamic>? selectedInvoice;
  final ValueChanged<Map<String, dynamic>> onInvoiceSelected;

  const OriginalInvoiceSelector({
    super.key,
    required this.api,
    required this.invoiceType,
    this.customerId,
    this.supplierId,
    this.selectedInvoice,
    required this.onInvoiceSelected,
  });

  Future<void> _showSelectDialog(BuildContext context) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PickerDialog(
        api: api,
        invoiceType: invoiceType,
        customerId: customerId,
        supplierId: supplierId,
      ),
    );
    if (result != null) onInvoiceSelected(result);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final chosen = selectedInvoice;
    return Card(
      elevation: 2,
      child: ListTile(
        leading: Icon(Icons.receipt_long, color: cs.primary),
        title: Text(
          chosen != null ? 'الفاتورة ${displayNumber(chosen)}' : 'اختر الفاتورة الأصلية',
          style: TextStyle(fontWeight: chosen != null ? FontWeight.bold : FontWeight.normal),
        ),
        subtitle: Text(
          chosen != null
              ? (chosen['customer_name'] ?? chosen['supplier_name'] ?? 'غير محدد').toString()
              : 'اضغط لاختيار الفاتورة الأصلية',
        ),
        trailing: Icon(chosen != null ? Icons.check_circle : Icons.arrow_forward_ios, color: cs.primary),
        onTap: () => _showSelectDialog(context),
      ),
    );
  }

  /// An invoice's number as the shop knows it; its row id only when it has none.
  static String displayNumber(Map<String, dynamic>? invoice) {
    final number = invoice?['invoice_number']?.toString().trim() ?? '';
    if (number.isNotEmpty) return number;
    final id = invoice?['id'];
    return id != null ? '#$id' : '#---';
  }
}

class _PickerDialog extends StatefulWidget {
  const _PickerDialog({required this.api, required this.invoiceType, this.customerId, this.supplierId});

  final ApiService api;
  final String invoiceType;
  final int? customerId;
  final int? supplierId;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  static const _perPage = 20;
  final _found = <Map<String, dynamic>>[];
  String _search = '';
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    final search = _search;
    final page = reset ? 1 : _page + 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final body = await widget.api.getReturnableInvoices(
        invoiceType: widget.invoiceType,
        customerId: widget.customerId,
        supplierId: widget.supplierId,
        search: search,
        page: page,
        perPage: _perPage,
      );
      if (!mounted || search != _search) return; // a later search answered first
      setState(() {
        if (reset) _found.clear();
        _found.addAll((body['invoices'] as List? ?? const []).whereType<Map<String, dynamic>>());
        _page = page;
        _hasMore = body['has_more'] == true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppFeedback.messageOf(e);
        _loading = false;
      });
    }
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _search = value.trim();
      _load(reset: true);
    });
  }

  double _num(Object? v) => v is num ? v.toDouble() : 0.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    return AlertDialog(
      title: const Text('اختر الفاتورة الأصلية'),
      content: SizedBox(
        width: double.maxFinite,
        height: 500,
        child: Column(
          children: [
            TextField(
              key: const Key('original-invoice-search'),
              decoration: const InputDecoration(
                labelText: 'بحث: رقم الفاتورة، الاسم، المبلغ، الوزن',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: _onSearch,
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('تعذّر تحميل الفواتير: $_error', textAlign: TextAlign.center),
                      TextButton(onPressed: () => _load(reset: true), child: const Text('إعادة المحاولة')),
                    ],
                  ),
                ),
              )
            else if (_found.isEmpty)
              Expanded(
                child: Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : Text(_search.isEmpty ? 'لا توجد فواتير قابلة للإرجاع' : 'لا توجد نتائج'),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _found.length + (_hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _found.length) {
                      return Center(
                        child: _loading
                            ? const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())
                            : TextButton(
                                key: const Key('original-invoice-more'),
                                onPressed: () => _load(reset: false),
                                child: const Text('المزيد'),
                              ),
                      );
                    }
                    final invoice = _found[index];
                    final canReturn = invoice['can_return'] != false;
                    final tone = canReturn ? tones.ready : tones.blocked;
                    final date = (invoice['date'] ?? '').toString();
                    return Card(
                      key: ValueKey('original-invoice-${invoice['id']}'),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        enabled: canReturn,
                        title: Text(
                          '${OriginalInvoiceSelector.displayNumber(invoice)} · '
                          '${invoice['customer_name'] ?? invoice['supplier_name'] ?? 'غير محدد'}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          [
                            if (date.length >= 10) date.substring(0, 10),
                            'الإجمالي ${formatAmount(_num(invoice['total']))}',
                            canReturn
                                ? 'يبقى ${formatGrams(_num(invoice['remaining_grams']))} جم بـ'
                                    '${formatAmount(_num(invoice['remaining_amount']))}'
                                : 'رُدّت كلها',
                          ].join(' · '),
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: Icon(canReturn ? Icons.chevron_left : Icons.block, color: tone.fg),
                        onTap: canReturn ? () => Navigator.of(context).pop(invoice) : null,
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('إلغاء')),
      ],
    );
  }
}
