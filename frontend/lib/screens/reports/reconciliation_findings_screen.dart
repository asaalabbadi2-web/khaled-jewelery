import 'package:flutter/material.dart';

import '../../api_service.dart';

/// «نتائج الفحص الليلي» — what the nightly checks and the schedulers found
/// (ADR-030, SCHED-004). Read-only: nothing here changes the books or a
/// finding. Grouped by kind, the standing risk first; what each kind means
/// comes from the server (`kinds`), never from this screen.
class ReconciliationFindingsScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const ReconciliationFindingsScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<ReconciliationFindingsScreen> createState() => _ReconciliationFindingsScreenState();
}

class _ReconciliationFindingsScreenState extends State<ReconciliationFindingsScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.getReconciliationFindings();
  }

  Future<void> _reload() async {
    setState(() => _future = widget.api.getReconciliationFindings());
    await _future;
  }

  static double _metric(Map<String, dynamic> f) {
    final m = f['metric'];
    return m is num ? m.toDouble() : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isAr ? 'نتائج الفحص الليلي' : 'Nightly check findings'),
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
          ],
        ),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    isAr ? 'تعذّر تحميل النتائج:\n${snap.error}' : 'Could not load findings:\n${snap.error}',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final data = snap.data ?? const {};
            final findings = (data['findings'] as List? ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            final kinds = Map<String, dynamic>.from(data['kinds'] as Map? ?? const {});
            if (findings.isEmpty) {
              return Center(
                child: Text(isAr ? 'لا توجد نتائج مفتوحة — الدفاتر سليمة في كل ما يُفحص.' : 'No open findings.'),
              );
            }

            final groups = <String, List<Map<String, dynamic>>>{};
            for (final f in findings) {
              groups.putIfAbsent(f['kind']?.toString() ?? '', () => []).add(f);
            }
            int rank(String k) => ((kinds[k] as Map?)?['rank'] as num?)?.toInt() ?? 999;
            final order = groups.keys.toList()..sort((a, b) => rank(a).compareTo(rank(b)));

            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      isAr
                          ? '${findings.length} نتيجة مفتوحة. للقراءة فقط: الإصلاح قرار محاسبي يُتخذ في جرد إصلاح البيانات.'
                          : '${findings.length} open findings. Read-only.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  for (final kind in order) _group(context, kind, kinds[kind] as Map?, groups[kind]!),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _group(BuildContext context, String kind, Map? info, List<Map<String, dynamic>> rows) {
    final theme = Theme.of(context);
    final title = (info?['title_ar'] ?? kind).toString();
    final explanation = (info?['explanation_ar'] ?? '').toString();
    rows.sort((a, b) => _metric(b).abs().compareTo(_metric(a).abs()));
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$title (${rows.length})', style: theme.textTheme.titleMedium),
            if (explanation.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(explanation, style: theme.textTheme.bodySmall),
            ],
            const Divider(),
            for (final f in rows) _row(context, f),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> f) {
    final theme = Theme.of(context);
    final detail = Map<String, dynamic>.from(f['detail'] as Map? ?? const {});
    final facts = <String>[
      for (final key in const ['entry_number', 'reference', 'invoice_status', 'missing', 'payment_method', 'due_day', 'payments'])
        if (detail[key] != null) '${detail[key]}',
    ];
    final since = (f['created_at'] ?? '').toString();
    final checks = (f['check_count'] as num?)?.toInt() ?? 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((f['subject_label'] ?? f['subject_key'] ?? '').toString(),
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                if (facts.isNotEmpty) Text(facts.join(' · '), style: theme.textTheme.bodySmall),
                Text(
                  'منذ ${since.length >= 10 ? since.substring(0, 10) : since} · فُحص $checks مرة',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(_metric(f).toStringAsFixed(2), style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
