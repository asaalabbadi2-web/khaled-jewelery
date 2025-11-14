import 'package:flutter/material.dart';
import '../api_service.dart';

/// Widget مشترك لاختيار الفاتورة الأصلية للمرتجعات
/// يعرض dialog مع قائمة الفواتير القابلة للإرجاع
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
    final bool isAr = Localizations.localeOf(context).languageCode == 'ar';

    try {
      // Fetch returnable invoices
      final response = await api.getReturnableInvoices(
        invoiceType: invoiceType,
        customerId: customerId,
        supplierId: supplierId,
      );

      if (!context.mounted) return;

      final invoices = response['invoices'] as List<dynamic>;

      if (invoices.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isAr
                  ? 'لا توجد فواتير قابلة للإرجاع'
                  : 'No returnable invoices found',
            ),
          ),
        );
        return;
      }

      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            isAr ? 'اختر الفاتورة الأصلية' : 'Select Original Invoice',
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: invoices.length,
              itemBuilder: (context, index) {
                final invoice = invoices[index];
                final canReturn = invoice['can_return'] ?? true;
                final invoiceDate = invoice['date'] ?? '';
                final invoiceTotal = invoice['total'] ?? 0.0;
                final invoiceNumber = _displayInvoiceNumber(invoice);

                return Card(
                  elevation: 2,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: canReturn
                          ? Colors.green.shade100
                          : Colors.red.shade100,
                      child: Text(
                        invoiceNumber,
                        style: TextStyle(
                          color: canReturn
                              ? Colors.green.shade800
                              : Colors.red.shade800,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    title: Text(
                      invoice['customer_name'] ??
                          invoice['supplier_name'] ??
                          (isAr ? 'غير محدد' : 'Unknown'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${isAr ? "التاريخ" : "Date"}: $invoiceDate',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          '${isAr ? "المبلغ" : "Total"}: ${invoiceTotal.toStringAsFixed(2)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    trailing: Icon(
                      canReturn ? Icons.check_circle : Icons.block,
                      color: canReturn ? Colors.green : Colors.red,
                    ),
                    enabled: canReturn,
                    onTap: canReturn
                        ? () => Navigator.of(context).pop(invoice)
                        : null,
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
          ],
        ),
      );

      if (result != null) {
        onInvoiceSelected(result);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAr ? 'خطأ في تحميل الفواتير: $e' : 'Error loading invoices: $e',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Card(
      elevation: 2,
      child: ListTile(
        leading: const Icon(Icons.receipt_long, color: Color(0xFFF7C873)),
        title: Text(
          selectedInvoice != null
              ? '${isAr ? "الفاتورة" : "Invoice"} ${_displayInvoiceNumber(selectedInvoice)}'
              : (isAr ? 'اختر الفاتورة الأصلية' : 'Select Original Invoice'),
          style: TextStyle(
            fontWeight: selectedInvoice != null
                ? FontWeight.bold
                : FontWeight.normal,
          ),
        ),
        subtitle: selectedInvoice != null
            ? Text(
                selectedInvoice!['customer_name'] ??
                    selectedInvoice!['supplier_name'] ??
                    (isAr ? 'غير محدد' : 'Unknown'),
              )
            : Text(
                isAr
                    ? 'اضغط لاختيار الفاتورة الأصلية'
                    : 'Tap to select original invoice',
              ),
        trailing: Icon(
          selectedInvoice != null
              ? Icons.check_circle
              : Icons.arrow_forward_ios,
          color: selectedInvoice != null
              ? Colors.green
              : const Color(0xFFF7C873),
        ),
        onTap: () => _showSelectDialog(context),
      ),
    );
  }

  String _displayInvoiceNumber(Map<String, dynamic>? invoice) {
    if (invoice == null) {
      return '#---';
    }

    final rawNumber = invoice['invoice_number'];
    if (rawNumber != null) {
      final trimmed = rawNumber.toString().trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }

    final id = invoice['id'];
    return id != null ? '#${id.toString()}' : '#---';
  }
}
