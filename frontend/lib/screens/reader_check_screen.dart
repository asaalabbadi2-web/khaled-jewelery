import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' show formatAmount;

/// «فحص القارئ» (ADR-085 ت0; the owner, 21 Nov 2026): how a handheld reader
/// writes in the browser, seen before the count by scan is built on it. The
/// reader types each tag it reads as a keyboard would, into this page's
/// field; the page says each read as it came -- when, new or repeated --
/// what the reader puts between two reads, and what each value is to the
/// server. A setup page: nothing is written.
///
/// A value is a tag's (24 characters, «4B4A» first, ADR-097 §2) or a label's
/// printed code («KJ-», the DataMatrix): found wherever it is in what was
/// typed, so a reader that puts nothing between two reads is read too.
///
/// A press of the reader reads every tag near it, again at each press (the
/// owner, 21 Nov 2026): the reads are grouped by press -- those arriving
/// within [pressGap] of the one before are one press -- each press said with
/// its reads and the new among them. The reader's button itself reaches the
/// page as F12 (seen on the reader, 21 Nov): its presses are counted apart,
/// to see that it does.
class ReaderCheckScreen extends StatefulWidget {
  const ReaderCheckScreen({super.key, this.api, this.elapsed});
  final ApiService? api;

  /// Milliseconds from the first read or press -- a stopwatch unless given
  /// (a test's own time).
  final int Function()? elapsed;

  @override
  State<ReaderCheckScreen> createState() => _ReaderCheckScreenState();
}

/// One read: its value, when from the first read, and its press.
typedef ReaderRead = ({String value, int ms, int press});

/// Reads closer than this to the one before are one press of the reader.
const pressGap = 500;

class _ReaderCheckScreenState extends State<ReaderCheckScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  final _field = TextEditingController();
  final _focus = FocusNode();

  /// Time from the first read -- a stopwatch, not the clock: only the gaps
  /// between reads are asked.
  final _since = Stopwatch();

  int get _now {
    if (!_since.isRunning) _since.start();
    return widget.elapsed?.call() ?? _since.elapsedMilliseconds;
  }
  final List<ReaderRead> _reads = [];
  final List<String> _between = [];
  int _taken = 0;
  int _press = 0;

  /// The reader's button (F12) pressed: a key held repeats every ~50 ms, so a
  /// press is one more than [pressGap] after the last.
  int _buttonPresses = 0;
  int? _lastButton;

  /// What the server says of each value, asked once a value.
  final Map<String, ({bool counted, String words})?> _said = {};

  static final _value = RegExp(r'4B4A[0-9A-F]{20}|KJ-\d{6,}');

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  bool _key(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.f12 || event is KeyUpEvent) return false;
    final now = _now;
    final last = _lastButton;
    _lastButton = now;
    if (last == null || now - last > pressGap) setState(() => _buttonPresses++);
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _typed(String text) {
    final upper = text.toUpperCase();
    final found = _value.allMatches(upper).toList();
    if (found.length <= _taken) return;
    final now = _now;
    setState(() {
      if (_reads.isEmpty || now - _reads.last.ms > pressGap) _press++;
      for (var i = _taken; i < found.length; i++) {
        final value = found[i].group(0)!;
        if (i > 0) _between.add(upper.substring(found[i - 1].end, found[i].start));
        _reads.add((value: value, ms: now, press: _press));
        if (!_said.containsKey(value)) {
          _said[value] = null;
          _ask(value);
        }
      }
      _taken = found.length;
    });
  }

  Future<void> _ask(String value) async {
    ({bool counted, String words}) said;
    try {
      final body = value.startsWith('KJ-') ? await _api.lookupPiece(value) : await _api.pieceByTag(value);
      final piece = body['piece'] as Map<String, dynamic>;
      final where = (body['location'] as Map?)?['name'];
      said = (
        counted: true,
        words: '${piece['item_code']}${where == null ? '' : ' — $where'}'
            '${value.startsWith('KJ-') ? ' — الرمز المطبوع' : ' — رقاقة معتمدة'}',
      );
    } on ApiException catch (e) {
      said = (counted: false, words: e.message);
    } catch (_) {
      said = (counted: false, words: 'تعذّر سؤال الخادم');
    }
    if (mounted) setState(() => _said[value] = said);
  }

  void _clear() {
    setState(() {
      _field.clear();
      _reads.clear();
      _between.clear();
      _said.clear();
      _taken = 0;
      _press = 0;
      _buttonPresses = 0;
      _lastButton = null;
      _since
        ..stop()
        ..reset();
    });
    _focus.requestFocus();
  }

  /// What the reader puts between two reads, the most of them.
  String get _separator {
    if (_between.isEmpty) return '—';
    String name(String gap) => gap.contains('\n')
        ? 'Enter'
        : gap.contains('\t')
            ? 'Tab'
            : gap.trim().isEmpty && gap.isNotEmpty
                ? 'مسافة'
                : gap.isEmpty
                    ? 'بلا فاصل'
                    : 'أحرف أخرى';
    final counts = <String, int>{};
    for (final gap in _between) {
      counts.update(name(gap), (n) => n + 1, ifAbsent: () => 1);
    }
    final most = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return most.key;
  }

  String _seconds(int ms) => formatAmount(ms / 1000, decimals: 1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final unique = <String, int>{};
    for (final r in _reads) {
      unique.update(r.value, (n) => n + 1, ifAbsent: () => 1);
    }
    var longest = 0;
    for (var i = 1; i < _reads.length; i++) {
      final gap = _reads[i].ms - _reads[i - 1].ms;
      if (gap > longest) longest = gap;
    }
    final span = _reads.isEmpty ? 0 : _reads.last.ms - _reads.first.ms;
    // each press: its reads, and the values no press before it had read
    final presses = <({int press, int reads, int fresh})>[];
    final seen = <String>{};
    for (var p = 1; p <= _press; p++) {
      final these = _reads.where((r) => r.press == p).toList();
      final values = these.map((r) => r.value).toSet();
      presses.add((press: p, reads: values.length, fresh: values.difference(seen).length));
      seen.addAll(values);
    }
    int pressesOf(String value) => _reads.where((r) => r.value == value).map((r) => r.press).toSet().length;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('فحص القارئ'),
          actions: [
            TextButton.icon(
              key: const Key('reader-clear'),
              // the bar's own ink: a text button's is the bar's colour, unseen on it
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).appBarTheme.foregroundColor),
              onPressed: _clear,
              icon: const Icon(Icons.restart_alt),
              label: const Text('من جديد'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'اضغط في الحقل، ثم وجّه القارئ إلى البطاقات واضغط زرّه. '
              'الصفحة تعدّ ما يكتبه القارئ، ولا تكتب شيئًا في النظام.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('reader-field'),
              controller: _field,
              focusNode: _focus,
              autofocus: true,
              maxLines: 4,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'ما يكتبه القارئ', border: OutlineInputBorder()),
              onChanged: _typed,
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(spacing: 24, runSpacing: 8, children: [
                  _figure(context, 'reader-presses', 'الضغطات', '$_press'),
                  _figure(context, 'reader-button', 'ضغطات الزرّ (F12)', '$_buttonPresses'),
                  _figure(context, 'reader-reads', 'القراءات', '${_reads.length}'),
                  _figure(context, 'reader-unique', 'رقاقات مختلفة', '${unique.length}'),
                  _figure(context, 'reader-repeats', 'مكرّرة', '${_reads.length - unique.length}'),
                  _figure(context, 'reader-separator', 'الفاصل', _separator),
                  _figure(context, 'reader-span', 'من الأولى إلى الأخيرة', '${_seconds(span)} ث'),
                  _figure(context, 'reader-longest', 'أطول فاصل', '${_seconds(longest)} ث'),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            for (final p in presses.reversed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  'الضغطة ${p.press}: ${p.reads} رقاقة · جديدة ${p.fresh}',
                  key: Key('reader-press-${p.press}'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            const SizedBox(height: 8),
            for (final e in unique.entries.toList().reversed)
              Card(
                key: Key('reader-value-${e.key}'),
                child: ListTile(
                  leading: Icon(
                    _said[e.key] == null
                        ? Icons.hourglass_empty
                        : (_said[e.key]!.counted ? Icons.check_circle : Icons.error_outline),
                    color: _said[e.key] == null
                        ? theme.colorScheme.outline
                        : (_said[e.key]!.counted ? tones.ready.fg : tones.warning.fg),
                  ),
                  title: Text(e.key, textDirection: TextDirection.ltr, textAlign: TextAlign.right),
                  subtitle: Text('في ${pressesOf(e.key)} من $_press ضغطة · ${_said[e.key]?.words ?? 'يُسأل الخادم…'}'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _figure(BuildContext context, String key, String name, String value) {
    final theme = Theme.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(name, style: theme.textTheme.bodySmall),
      Text(value, key: Key(key), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
    ]);
  }
}
