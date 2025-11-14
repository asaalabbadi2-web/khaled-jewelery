import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

/// شاشة معاينة وطباعة السند
class VoucherPreviewScreen extends StatefulWidget {
  final Map<String, dynamic> voucherData;
  final String voucherType; // 'receipt' or 'payment'

  const VoucherPreviewScreen({
    Key? key,
    required this.voucherData,
    required this.voucherType,
  }) : super(key: key);

  @override
  State<VoucherPreviewScreen> createState() => _VoucherPreviewScreenState();
}

class _VoucherPreviewScreenState extends State<VoucherPreviewScreen> {
  String _currencySymbol = 'ر.س';
  int _currencyDecimalPlaces = 2;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);
    setState(() {
      _currencySymbol = settings.currencySymbol;
      _currencyDecimalPlaces = settings.decimalPlaces;
    });
  }

  String _formatCash(double value) {
    return NumberFormat.currency(
      symbol: _currencySymbol,
      decimalDigits: _currencyDecimalPlaces,
    ).format(value);
  }

  String _formatWeight(double value) {
    return '${value.toStringAsFixed(3)} جرام';
  }

  bool get _isReceipt => widget.voucherType == 'receipt';
  String get _voucherTitle => _isReceipt ? 'سند قبض' : 'سند صرف';
  Color get _voucherColor => _isReceipt ? AppColors.success : AppColors.error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('معاينة $_voucherTitle'),
        backgroundColor: AppColors.darkGold,
        actions: [
          IconButton(
            icon: const Icon(Icons.print),
            onPressed: _printVoucher,
            tooltip: 'طباعة',
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareVoucher,
            tooltip: 'مشاركة',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: _buildVoucherPreview(),
      ),
    );
  }

  Widget _buildVoucherPreview() {
    final date =
        widget.voucherData['date'] ??
        DateFormat('yyyy-MM-dd').format(DateTime.now());
    final description = widget.voucherData['description'] ?? '';
    final notes = widget.voucherData['notes'] ?? '';
    final receiverName = widget.voucherData['receiver_name'] ?? '';
    final accountLines =
        widget.voucherData['account_lines'] as List<dynamic>? ?? [];
    final partyType = widget.voucherData['party_type'] ?? '';

    // حساب المجاميع
    double totalCash = 0;
    Map<double, double> totalGoldByKarat = {};

    for (var line in accountLines) {
      if (line['amount_type'] == 'cash') {
        totalCash += (line['amount'] as num).toDouble();
      } else if (line['amount_type'] == 'gold') {
        final karat = (line['karat'] as num).toDouble();
        final amount = (line['amount'] as num).toDouble();
        totalGoldByKarat[karat] = (totalGoldByKarat[karat] ?? 0) + amount;
      }
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _voucherColor.withValues(alpha: 0.3), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // رأس السند
            _buildHeader(),
            const Divider(height: 32, thickness: 2),

            // معلومات السند
            _buildInfoSection(date, partyType, receiverName),
            const SizedBox(height: 24),

            // البيان
            if (description.isNotEmpty) ...[
              _buildDescriptionSection(description),
              const SizedBox(height: 24),
            ],

            // سطور الحسابات
            _buildAccountLinesSection(accountLines),
            const SizedBox(height: 24),

            // المجاميع
            _buildTotalsSection(totalCash, totalGoldByKarat),
            const SizedBox(height: 24),

            // الملاحظات
            if (notes.isNotEmpty) ...[
              _buildNotesSection(notes),
              const SizedBox(height: 24),
            ],

            // التوقيعات
            _buildSignaturesSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _voucherColor.withValues(alpha: 0.1),
            _voucherColor.withValues(alpha: 0.05),
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _voucherColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _voucherColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _isReceipt ? Icons.south : Icons.north,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _voucherTitle,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: _voucherColor,
                    ),
                  ),
                  Text(
                    'نظام ياسار للذهب',
                    style: TextStyle(fontSize: 14, color: AppColors.deepGold),
                  ),
                ],
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'رقم السند',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              Text(
                widget.voucherData['id']?.toString() ?? '---',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoSection(String date, String partyType, String receiverName) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.lightGold.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildInfoItem(Icons.calendar_today, 'التاريخ', date),
              _buildInfoItem(
                Icons.person,
                'الطرف',
                partyType == 'customer'
                    ? 'عميل'
                    : partyType == 'supplier'
                    ? 'مورد'
                    : partyType == 'employee'
                    ? 'موظف'
                    : 'آخر',
              ),
            ],
          ),
          if (receiverName.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.person_pin, color: AppColors.primaryGold, size: 20),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'المستلم/المسلم',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    Text(
                      receiverName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoItem(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primaryGold, size: 20),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            Text(
              value,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDescriptionSection(String description) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description_outlined, color: AppColors.primaryGold),
              const SizedBox(width: 8),
              Text(
                'البيان',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepGold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(description, style: const TextStyle(fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildAccountLinesSection(List<dynamic> accountLines) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.list_alt, color: AppColors.primaryGold),
            const SizedBox(width: 8),
            Text(
              'سطور الحسابات',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.deepGold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Table(
          border: TableBorder.all(
            color: AppColors.lightGold,
            borderRadius: BorderRadius.circular(8),
          ),
          columnWidths: const {
            0: FlexColumnWidth(1),
            1: FlexColumnWidth(2),
            2: FlexColumnWidth(1.5),
            3: FlexColumnWidth(1),
          },
          children: [
            // Header
            TableRow(
              decoration: BoxDecoration(
                color: AppColors.lightGold.withValues(alpha: 0.4),
              ),
              children: [
                _buildTableHeader('#'),
                _buildTableHeader('الحساب'),
                _buildTableHeader('المبلغ/الوزن'),
                _buildTableHeader('النوع'),
              ],
            ),
            // Rows
            ...accountLines.asMap().entries.map((entry) {
              final index = entry.key;
              final line = entry.value;
              return TableRow(
                decoration: BoxDecoration(
                  color: index.isEven ? Colors.white : Colors.grey[50],
                ),
                children: [
                  _buildTableCell('${index + 1}'),
                  _buildTableCell(line['account_name'] ?? '---'),
                  _buildTableCell(
                    line['amount_type'] == 'cash'
                        ? _formatCash((line['amount'] as num).toDouble())
                        : '${_formatWeight((line['amount'] as num).toDouble())} ع ${(line['karat'] as num).toInt()}',
                  ),
                  _buildTableCell(
                    line['amount_type'] == 'cash' ? 'نقد' : 'ذهب',
                  ),
                ],
              );
            }).toList(),
          ],
        ),
      ],
    );
  }

  Widget _buildTableHeader(String text) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: AppColors.deepGold,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildTableCell(String text) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(text, textAlign: TextAlign.center),
    );
  }

  Widget _buildTotalsSection(
    double totalCash,
    Map<double, double> totalGoldByKarat,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primaryGold.withValues(alpha: 0.2),
            AppColors.primaryGold.withValues(alpha: 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primaryGold, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calculate, color: AppColors.darkGold),
              const SizedBox(width: 8),
              Text(
                'المجاميع',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepGold,
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          if (totalCash > 0) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.attach_money,
                      color: AppColors.darkGold,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const Text('إجمالي النقد:', style: TextStyle(fontSize: 16)),
                  ],
                ),
                Text(
                  _formatCash(totalCash),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
          if (totalGoldByKarat.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.circle, color: AppColors.primaryGold, size: 20),
                const SizedBox(width: 8),
                const Text('إجمالي الذهب:', style: TextStyle(fontSize: 16)),
              ],
            ),
            const SizedBox(height: 8),
            ...totalGoldByKarat.entries.map(
              (e) => Padding(
                padding: const EdgeInsets.only(right: 32, top: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('عيار ${e.key.toInt()}:'),
                    Text(
                      _formatWeight(e.value),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNotesSection(String notes) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.amber[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.note_outlined, color: Colors.amber[800]),
              const SizedBox(width: 8),
              Text(
                'ملاحظات',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.amber[900],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(notes),
        ],
      ),
    );
  }

  Widget _buildSignaturesSection() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildSignature('المحاسب'),
        _buildSignature('المستلم'),
        _buildSignature('المدير'),
      ],
    );
  }

  Widget _buildSignature(String title) {
    return Column(
      children: [
        Container(
          width: 120,
          height: 60,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.grey[400]!, width: 1),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(title, style: TextStyle(fontSize: 14, color: Colors.grey[700])),
      ],
    );
  }

  Future<void> _printVoucher() async {
    try {
      final pdf = await _generatePdf();
      await Printing.layoutPdf(
        onLayout: (format) async => pdf.save(),
        name: '$_voucherTitle-${widget.voucherData['id'] ?? 'جديد'}.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في الطباعة: $e')));
      }
    }
  }

  Future<void> _shareVoucher() async {
    try {
      final pdf = await _generatePdf();
      await Printing.sharePdf(
        bytes: await pdf.save(),
        filename: '$_voucherTitle-${widget.voucherData['id'] ?? 'جديد'}.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في المشاركة: $e')));
      }
    }
  }

  Future<pw.Document> _generatePdf() async {
    final pdf = pw.Document();
    final date =
        widget.voucherData['date'] ??
        DateFormat('yyyy-MM-dd').format(DateTime.now());
    final description = widget.voucherData['description'] ?? '';
    final notes = widget.voucherData['notes'] ?? '';
    final receiverName = widget.voucherData['receiver_name'] ?? '';
    final partyType = widget.voucherData['party_type'] ?? '';
    final accountLines =
        widget.voucherData['account_lines'] as List<dynamic>? ?? [];

    // حساب المجاميع
    double totalCash = 0;
    Map<double, double> totalGoldByKarat = {};

    for (var line in accountLines) {
      if (line['amount_type'] == 'cash') {
        totalCash += (line['amount'] as num).toDouble();
      } else if (line['amount_type'] == 'gold') {
        final karat = (line['karat'] as num).toDouble();
        final amount = (line['amount'] as num).toDouble();
        totalGoldByKarat[karat] = (totalGoldByKarat[karat] ?? 0) + amount;
      }
    }

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Header
              pw.Container(
                padding: const pw.EdgeInsets.all(16),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(width: 2),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          _voucherTitle,
                          style: pw.TextStyle(
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          'نظام ياسار للذهب',
                          style: const pw.TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'رقم السند',
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                        pw.Text(
                          widget.voucherData['id']?.toString() ?? '---',
                          style: pw.TextStyle(
                            fontSize: 18,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 16),

              // Info
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text('التاريخ: $date'),
                      pw.Text(
                        'الطرف: ${partyType == 'customer'
                            ? 'عميل'
                            : partyType == 'supplier'
                            ? 'مورد'
                            : partyType == 'employee'
                            ? 'موظف'
                            : 'آخر'}',
                      ),
                    ],
                  ),
                  if (receiverName.isNotEmpty) ...[
                    pw.SizedBox(height: 8),
                    pw.Text(
                      'المستلم/المسلم: $receiverName',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                  ],
                ],
              ),
              pw.SizedBox(height: 16),

              // Description
              if (description.isNotEmpty) ...[
                pw.Text(
                  'البيان:',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
                pw.Text(description),
                pw.SizedBox(height: 16),
              ],

              // Account Lines Table
              pw.Table.fromTextArray(
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                headers: ['#', 'الحساب', 'المبلغ/الوزن', 'النوع'],
                data: accountLines.asMap().entries.map((entry) {
                  final index = entry.key;
                  final line = entry.value;
                  return [
                    '${index + 1}',
                    line['account_name'] ?? '---',
                    line['amount_type'] == 'cash'
                        ? _formatCash((line['amount'] as num).toDouble())
                        : '${_formatWeight((line['amount'] as num).toDouble())} ع ${(line['karat'] as num).toInt()}',
                    line['amount_type'] == 'cash' ? 'نقد' : 'ذهب',
                  ];
                }).toList(),
              ),
              pw.SizedBox(height: 16),

              // Totals
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'المجاميع:',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    if (totalCash > 0)
                      pw.Text('إجمالي النقد: ${_formatCash(totalCash)}'),
                    if (totalGoldByKarat.isNotEmpty) ...[
                      pw.Text('إجمالي الذهب:'),
                      ...totalGoldByKarat.entries.map(
                        (e) => pw.Text(
                          '  عيار ${e.key.toInt()}: ${_formatWeight(e.value)}',
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Notes
              if (notes.isNotEmpty) ...[
                pw.SizedBox(height: 16),
                pw.Text(
                  'ملاحظات:',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
                pw.Text(notes),
              ],

              pw.Spacer(),

              // Signatures
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                children: [
                  _buildPdfSignature('المحاسب'),
                  _buildPdfSignature('المستلم'),
                  _buildPdfSignature('المدير'),
                ],
              ),
            ],
          );
        },
      ),
    );

    return pdf;
  }

  pw.Widget _buildPdfSignature(String title) {
    return pw.Column(
      children: [
        pw.Container(
          width: 100,
          height: 40,
          decoration: pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide()),
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Text(title, style: const pw.TextStyle(fontSize: 10)),
      ],
    );
  }
}
