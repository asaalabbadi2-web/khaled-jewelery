import 'package:flutter/material.dart';

import '../../api_service.dart';

class CustomerGoldBalancesReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const CustomerGoldBalancesReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<CustomerGoldBalancesReportScreen> createState() =>
      _CustomerGoldBalancesReportScreenState();
}

class _CustomerGoldBalancesReportScreenState
    extends State<CustomerGoldBalancesReportScreen> {
  static const _gold = Color(0xFFFFD700);

  final TextEditingController _search = TextEditingController();
  bool _loading = false;
  bool _onlyNonZero = true;
  bool _ensureAccounts = false;

  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  double _num(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  Map<String, double> _balancesOf(Map<String, dynamic> row) {
    final balances = row['balances'];
    if (balances is Map) {
      return {
        '18k': _num(balances['18k']),
        '21k': _num(balances['21k']),
        '22k': _num(balances['22k']),
        '24k': _num(balances['24k']),
      };
    }
    return const {'18k': 0, '21k': 0, '22k': 0, '24k': 0};
  }

  bool _isNonZero(Map<String, double> b) {
    return b.values.any((v) => v.abs() > 0.0005);
  }

  double _equiv21k(Map<String, double> b) {
    // Main karat equivalent (assume 21 as default).
    // Convert each karat weight into 21k-equivalent: w * (k/21).
    return (b['18k'] ?? 0) * (18.0 / 21.0) +
        (b['21k'] ?? 0) +
        (b['22k'] ?? 0) * (22.0 / 21.0) +
        (b['24k'] ?? 0) * (24.0 / 21.0);
  }

  String _fmtG(double v) => v.toStringAsFixed(3);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await widget.api.getCustomersGoldBalances(
        ensureAccounts: _ensureAccounts,
      );
      if (!mounted) return;
      setState(() => _rows = data);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.isArabic
              ? 'فشل تحميل أرصدة ذهب العملاء: $e'
              : 'Failed to load customer gold balances: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _search.text.trim().toLowerCase();
    final filtered = _rows.where((row) {
      final code = (row['customer_code'] ?? '').toString().toLowerCase();
      final name = (row['customer_name'] ?? '').toString().toLowerCase();
      final matches = q.isEmpty || code.contains(q) || name.contains(q);
      if (!matches) return false;
      if (!_onlyNonZero) return true;
      return _isNonZero(_balancesOf(row));
    }).toList();

    filtered.sort((a, b) {
      final ea = _equiv21k(_balancesOf(a)).abs();
      final eb = _equiv21k(_balancesOf(b)).abs();
      return eb.compareTo(ea);
    });

    return filtered;
  }

  Map<String, double> get _totals {
    double t18 = 0, t21 = 0, t22 = 0, t24 = 0;
    for (final row in _filtered) {
      final b = _balancesOf(row);
      t18 += b['18k'] ?? 0;
      t21 += b['21k'] ?? 0;
      t22 += b['22k'] ?? 0;
      t24 += b['24k'] ?? 0;
    }
    return {'18k': t18, '21k': t21, '22k': t22, '24k': t24};
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isAr ? 'أرصدة ذهب العملاء' : 'Customer Gold Balances'),
          actions: [
            IconButton(
              tooltip: isAr ? 'تحديث' : 'Refresh',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: _buildTopControls(context),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildSummary(context),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _filtered.isEmpty
                          ? _buildEmpty(context)
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 8, 16, 24),
                              itemCount: _filtered.length,
                              itemBuilder: (context, index) {
                                return _buildRowCard(context, _filtered[index]);
                              },
                            ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildTopControls(BuildContext context) {
    final isAr = widget.isArabic;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: isAr
                ? 'بحث بالاسم أو الكود...'
                : 'Search by name or code...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilterChip(
              selected: _onlyNonZero,
              onSelected: (v) => setState(() => _onlyNonZero = v),
              label: Text(
                isAr ? 'غير الصفري فقط' : 'Non‑zero only',
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
              selectedColor: _gold.withValues(alpha: 0.25),
              checkmarkColor: _gold,
            ),
            FilterChip(
              selected: _ensureAccounts,
              onSelected: (v) async {
                setState(() => _ensureAccounts = v);
                await _load();
              },
              label: Text(
                isAr ? 'إصلاح الربط تلقائياً' : 'Auto-fix linking',
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
              selectedColor: _gold.withValues(alpha: 0.25),
              checkmarkColor: _gold,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSummary(BuildContext context) {
    final isAr = widget.isArabic;
    final totals = _totals;
    final equiv = _equiv21k(totals);

    final nonZeroCount = _filtered.length;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                context,
                title: isAr ? 'عدد العملاء' : 'Customers',
                value: nonZeroCount.toString(),
                icon: Icons.group_outlined,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _summaryCard(
                context,
                title: isAr ? 'مكافئ 21' : '21k equiv',
                value: '${_fmtG(equiv)} g',
                icon: Icons.scale,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _summaryCard(
                context,
                title: isAr ? '18k' : '18k',
                value: '${_fmtG(totals['18k'] ?? 0)} g',
                icon: Icons.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _summaryCard(
                context,
                title: isAr ? '21k' : '21k',
                value: '${_fmtG(totals['21k'] ?? 0)} g',
                icon: Icons.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _summaryCard(
                context,
                title: isAr ? '22k' : '22k',
                value: '${_fmtG(totals['22k'] ?? 0)} g',
                icon: Icons.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _summaryCard(
                context,
                title: isAr ? '24k' : '24k',
                value: '${_fmtG(totals['24k'] ?? 0)} g',
                icon: Icons.circle,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryCard(
    BuildContext context, {
    required String title,
    required String value,
    required IconData icon,
  }) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _gold, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFamily: 'Cairo',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontFamily: 'Cairo',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRowCard(BuildContext context, Map<String, dynamic> row) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);

    final code = (row['customer_code'] ?? '').toString();
    final name = (row['customer_name'] ?? '').toString();
    final b = _balancesOf(row);
    final eq = _equiv21k(b);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment:
              isAr ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.person_outline, color: _gold),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        isAr ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontFamily: 'Cairo',
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isAr ? 'الكود: $code' : 'Code: $code',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFamily: 'Cairo',
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${_fmtG(eq)} g',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    fontFamily: 'Cairo',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _pill(context, '18k', b['18k'] ?? 0),
                _pill(context, '21k', b['21k'] ?? 0),
                _pill(context, '22k', b['22k'] ?? 0),
                _pill(context, '24k', b['24k'] ?? 0),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, String label, double value) {
    final theme = Theme.of(context);
    final v = _fmtG(value);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _gold.withValues(alpha: 0.22)),
      ),
      child: Text(
        '$label: $v g',
        style: theme.textTheme.labelLarge?.copyWith(
          fontFamily: 'Cairo',
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final isAr = widget.isArabic;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 72, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              isAr ? 'لا توجد بيانات مطابقة' : 'No matching data',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              isAr
                  ? 'جرّب تغيير البحث أو إلغاء خيار غير الصفري فقط.'
                  : 'Try adjusting the search or disabling non‑zero only.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}
