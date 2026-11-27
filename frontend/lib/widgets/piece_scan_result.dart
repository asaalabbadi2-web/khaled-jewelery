import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' show formatGrams;
import '../utils/display_date.dart';
import '../utils/bidi.dart';

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

  static IconData _pieceIcon(String verdict) => switch (verdict) {
        'missing' => Icons.report_outlined,
        'unread' => Icons.visibility_off_outlined,
        'untagged' => Icons.label_off_outlined,
        'moved' => Icons.swap_horiz,
        _ => Icons.help_outline,
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
      Text(isolateLatin('${scan['safe_name']} — ${scan['kind_words']} — ${scan['scope_words']}'),
          style: theme.textTheme.titleSmall),
      Text(
        isolateLatin('بدأه ${scan['started_by_name'] ?? scan['started_by'] ?? '—'} ${displayDateTime(scan['started_at'])}'
            '${scan['finished_at'] == null ? '' : ' · ${abandoned ? 'تركه' : 'أنهاه'} ${scan['finished_by_name'] ?? scan['finished_by'] ?? '—'} ${displayDateTime(scan['finished_at'])}'}'),
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
        // its figures as the scanning screen's tiles (the owner, 22 Nov 2026), the missing in the warning
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: ScanFigure(figureKey: 'scan-count-found', name: verdicts['found']!,
              value: '${counts['found'] ?? 0}', tone: tones.ready)),
          const SizedBox(width: 12),
          Expanded(child: ScanFigure(figureKey: 'scan-count-missing', name: verdicts['missing']!,
              value: '${counts['missing'] ?? 0}', tone: (counts['missing'] as num? ?? 0) > 0 ? tones.warning : null)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 16, runSpacing: 8, children: [
          for (final e in verdicts.entries)
            if (e.key != 'found' && e.key != 'missing' && (counts[e.key] as num? ?? 0) > 0)
              Text('${e.value}: ${counts[e.key]}', key: Key('scan-count-${e.key}'), style: theme.textTheme.titleSmall),
        ]),
        if (notFound.isNotEmpty) ...[
          const SizedBox(height: 16),
          // what a count is for: the missing first, then the rest not found
          Text(
            'الناقصة (${notFound.where((p) => p['verdict'] == 'missing').length})',
            key: const Key('scan-missing-title'),
            style: theme.textTheme.titleSmall?.copyWith(color: tones.warning.fg, fontWeight: FontWeight.w800),
          ),
          for (final p in [
            ...notFound.where((p) => p['verdict'] == 'missing'),
            ...notFound.where((p) => p['verdict'] != 'missing'),
          ])
            ListTile(
              key: Key('scan-piece-${p['item_id']}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(_pieceIcon('${p['verdict']}'),
                  color: p['verdict'] == 'missing' ? tones.warning.fg : theme.colorScheme.onSurfaceVariant),
              // the missing said by what it is, to be looked for (the owner, 27 Nov 2026)
              title: Text('${ltrIsolate('${p['item_code']}')} · '
                  '${p['piece_name'] == null ? '' : '${p['piece_name']} · '}'
                  '${ltrIsolate(formatGrams((p['weight'] as num? ?? 0).toDouble(), decimals: 2))} جم'),
              subtitle: Text(isolateLatin([
                '${p['verdict_words']}',
                if (p['moved'] != null) '${p['moved']}',
              ].join(' — '))),
            ),
        ],
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
              subtitle: Text(isolateLatin([
                '${r['words'] ?? r['value']}',
                if (r['moved'] != null) '${r['moved']}',
                if (r['resolved_by'] != null) 'اعتمدها ${r['resolved_by_name'] ?? r['resolved_by']}',
              ].join(' — '))),
            ),
        ],
      ],
      if (trailing != null) ...[const SizedBox(height: 24), trailing!],
    ]);
  }
}

/// A count's figure -- its name and its number in a tile, coloured by its
/// tone: the scanning screen's and the result's alike (one tile).
class ScanFigure extends StatelessWidget {
  const ScanFigure({super.key, required this.figureKey, required this.name, required this.value, this.tone});
  final String figureKey;
  final String name;
  final String value;
  final SemanticTone? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone?.container ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: theme.textTheme.bodySmall?.copyWith(color: tone?.onContainer)),
        Text(isolateLatin(value), key: Key(figureKey),
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: tone?.onContainer)),
      ]),
    );
  }
}

