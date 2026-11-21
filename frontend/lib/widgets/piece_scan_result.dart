import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' show formatGrams;
import '../utils/display_date.dart';

/// A count by scan's result, frozen at its finish (ADR-085 ت2) -- one view for
/// the reader's screen and the computer's log: its place, kind and scope, how
/// it ended (complete, early with its reason, left), who began and ended it
/// and when, its counts by verdict, each piece not found with its weight and
/// verdict and what moved, and the reads that are alerts -- all the server's.
class PieceScanResult extends StatelessWidget {
  const PieceScanResult({super.key, required this.scan, this.trailing});
  final Map<String, dynamic> scan;

  /// What follows it on its screen («جرد جديد» on the reader).
  final Widget? trailing;

  static const verdicts = {
    'found': 'موجودة', 'missing': 'ناقصة', 'unread': 'لم تُقرأ', 'untagged': 'بلا رقاقة معتمدة',
    'moved': 'تحرّكت أثناء الجرد',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final pieces = (scan['expected_pieces'] as List? ?? []).cast<Map<String, dynamic>>();
    final counts = (scan['expected_counts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final reads = (scan['reads'] as List? ?? []).cast<Map<String, dynamic>>();
    final alerts = reads.where((r) => r['verdict'] != 'found' && r['verdict'] != 'other_scope').toList();
    final abandoned = scan['status'] == 'abandoned';
    final notFound = pieces.where((p) => p['verdict'] != 'found').toList();
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('${scan['safe_name']} — ${scan['kind_words']} — ${scan['scope_words']}', style: theme.textTheme.titleSmall),
      Text(
        'بدأه ${scan['started_by'] ?? '—'} ${displayDateTime(scan['started_at'])}'
        '${scan['finished_at'] == null ? '' : ' · ${abandoned ? 'تركه' : 'أنهاه'} ${scan['finished_by'] ?? '—'} ${displayDateTime(scan['finished_at'])}'}',
        key: const Key('scan-result-who'),
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Text(
        scan['status'] == 'open'
            ? 'الجرد مفتوح: موجودة ${scan['found']} من ${scan['expected']} حتى الآن، ويُكمَل من القارئ'
            : abandoned
            ? 'تُرك الجرد: لا حكم فيه'
            : scan['complete'] == true
                ? 'انتهى الجرد ومسحه مكتمل'
                : 'انتهى قبل اكتمال المسح: ${scan['early_reason'] ?? ''}',
        key: const Key('scan-result-state'),
        style: theme.textTheme.titleMedium?.copyWith(
            color: abandoned || scan['complete'] != true ? tones.warning.fg : tones.ready.fg),
      ),
      if (!abandoned && scan['status'] != 'open') ...[
        const SizedBox(height: 12),
        Wrap(spacing: 16, runSpacing: 8, children: [
          for (final e in verdicts.entries)
            if ((counts[e.key] as num? ?? 0) > 0 || e.key == 'found' || e.key == 'missing')
              Text('${e.value}: ${counts[e.key] ?? 0}', key: Key('scan-count-${e.key}'),
                  style: theme.textTheme.titleSmall),
        ]),
        const SizedBox(height: 12),
        for (final p in notFound)
          ListTile(
            key: Key('scan-piece-${p['item_id']}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${p['item_code']} · ${formatGrams((p['weight'] as num? ?? 0).toDouble(), decimals: 2)} جم',
                textDirection: TextDirection.ltr, textAlign: TextAlign.right),
            subtitle: Text([
              '${p['verdict_words']}',
              if (p['moved'] != null) '${p['moved']}',
            ].join(' — ')),
          ),
        if (alerts.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('تنبيهات القراءة (${alerts.length})', style: theme.textTheme.titleSmall),
          for (final r in alerts)
            ListTile(
              key: Key('scan-read-${r['value']}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${r['verdict_words'] ?? r['verdict']}',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
              subtitle: Text([
                '${r['words'] ?? r['value']}',
                if (r['moved'] != null) '${r['moved']}',
                if (r['resolved_by'] != null) 'اعتمدها ${r['resolved_by']}',
              ].join(' — ')),
            ),
        ],
      ],
      if (trailing != null) ...[const SizedBox(height: 24), trailing!],
    ]);
  }
}
