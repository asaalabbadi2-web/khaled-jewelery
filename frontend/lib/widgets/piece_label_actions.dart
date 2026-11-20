import 'dart:math';

import 'package:flutter/material.dart';

import '../api_service.dart';
import 'app_feedback.dart';
import 'confirm_financial_action.dart';

/// A piece's label, one way everywhere (ADR-097 law 5): the coding station
/// and «القطع» ask through this -- the first print, «تسجيل فقط», a run of a
/// waiting or failed job, an unknown end settled, a reprint with its reason
/// -- and each job runs on the server's one engine. The piece is saved
/// before; a printer that fails stops no one.
class PieceLabelActions {
  PieceLabelActions({required this.api, required this.onLabel, required this.onBusy, this.afterEach});

  final ApiService api;

  /// The piece's label as it now stands.
  final void Function(int pieceId, Map<String, dynamic> label) onLabel;
  final void Function(int pieceId, bool busy) onBusy;

  /// After each request: the printer and the labels waiting read again.
  final VoidCallback? afterEach;

  static const failedWords =
      'تم تسجيل القطعة بنجاح، لكن تعذّرت طباعة البطاقة. أُضيفت إلى قائمة انتظار الطباعة.';

  /// What stops the printer itself: the next label would fail as well.
  static const printerStops = {'paper_out', 'ribbon_out', 'head_open', 'paused', 'unreachable'};

  /// One attempt, one key -- 0x7fffffff: on the web a shift is 32-bit.
  static String newKey() =>
      '${Random.secure().nextInt(0x7fffffff)}-${Random.secure().nextInt(0x7fffffff)}';

  /// A job as a piece carries it: its state and its last attempt's.
  static Map<String, dynamic> labelOf(Map<String, dynamic> job) {
    final last = job['last_attempt'] as Map<String, dynamic>?;
    return {
      'job_id': job['id'], 'kind': job['kind'], 'status': job['status'],
      'attempt_id': last?['id'], 'generation': last?['generation'],
      'printed': last?['printed'], 'written': last?['written'], 'verified': last?['verified'],
      'error_code': last?['error_code'], 'message': last?['message'],
    };
  }

  Future<Map<String, dynamic>?> _ask(BuildContext context, int pieceId, Future<Map<String, dynamic>> Function() call,
      {required bool quiet, bool sayFailure = true}) async {
    onBusy(pieceId, true);
    try {
      final label = labelOf((await call())['job'] as Map<String, dynamic>);
      onLabel(pieceId, label);
      if (!quiet && sayFailure && label['status'] != 'completed' && label['status'] != 'pending' &&
          context.mounted) {
        AppFeedback.warning(context, failedWords);
      }
      return label;
    } catch (e) {
      if (!quiet && context.mounted) AppFeedback.warning(context, failedWords);
      return null;
    } finally {
      onBusy(pieceId, false);
      afterEach?.call();
    }
  }

  /// A new job: printed now, or waiting (`run` false, «تسجيل فقط»).
  Future<Map<String, dynamic>?> print(BuildContext context, Map<String, dynamic> piece,
          {String kind = 'first', String? reason, bool run = true, bool quiet = false}) =>
      _ask(
        context,
        piece['id'] as int,
        () => api.printPieceLabel(piece['id'] as int, {
          'request_key': newKey(),
          'kind': kind,
          if (reason != null) 'reason': reason,
          'run': run,
        }),
        quiet: quiet,
        sayFailure: run,
      );

  /// A waiting or failed job run again: a new attempt, a new generation.
  Future<Map<String, dynamic>?> retry(BuildContext context, int pieceId, int jobId, {bool quiet = false}) =>
      _ask(context, pieceId, () => api.runPrintJob(jobId), quiet: quiet);

  /// An attempt whose end is not known: the label read by the reader, or
  /// none came out (ADR-097 law 10).
  Future<void> resolve(BuildContext context, int pieceId, String code, int attemptId) async {
    final answer = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ResolveLabelDialog(code: code),
    );
    if (answer == null || !context.mounted) return;
    onBusy(pieceId, true);
    try {
      final saved = await api.resolvePrintAttempt(attemptId, answer);
      onLabel(pieceId, labelOf(saved['job'] as Map<String, dynamic>));
    } catch (e) {
      if (context.mounted) AppFeedback.error(context, e);
    } finally {
      onBusy(pieceId, false);
      afterEach?.call();
    }
  }

  /// A new label for a piece whose label is adopted: its reason asked; the
  /// old tag stopped once the new one is read back (ADR-097 law 4).
  Future<void> reprint(BuildContext context, Map<String, dynamic> piece) async {
    final reason = await confirmFinancialAction(
      context,
      title: 'إعادة طباعة بطاقة ${piece['item_code']}؟',
      effect: 'تُطبع بطاقة جديدة برقاقة جديدة، وتُلغى القديمة حين تُعتمد الجديدة. رقم القطعة لا يتغيّر.',
      confirmLabel: 'إعادة الطباعة',
      reasonLabel: 'سبب إعادة الطباعة',
      destructive: false,
    );
    if (reason == null || reason.trim().isEmpty || !context.mounted) return;
    await print(context, piece, kind: 'reprint', reason: reason.trim());
  }

  /// The next step of a piece's label by its state -- printed, run, tried
  /// again; null for one printed or to be settled by hand. For «اطبع المحدد».
  Future<Map<String, dynamic>?> advance(BuildContext context, Map<String, dynamic> piece) {
    final label = piece['label'] as Map<String, dynamic>?;
    switch (label?['status'] as String?) {
      case null:
        // a tag adopted before ADR-097 (generation 0): printed, not printed again
        return piece['tag'] != null ? Future.value(null) : print(context, piece, quiet: true);
      case 'pending':
      case 'printing':
      case 'verifying':
      case 'failed':
        return retry(context, piece['id'] as int, label!['job_id'] as int, quiet: true);
      default:
        return Future.value(null);
    }
  }
}

/// A piece's label: its state and the one thing to do -- in the station's
/// last piece and its list, and in «القطع».
class PieceLabelCell extends StatelessWidget {
  const PieceLabelCell(
      {super.key, required this.piece, required this.busy, required this.actions, this.compact = false});

  final Map<String, dynamic> piece;
  final bool busy;
  final PieceLabelActions actions;

  /// A table's cell: a short word and an icon, the action's words its tooltip.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final id = piece['id'] as int;
    final label = piece['label'] as Map<String, dynamic>?;
    if (busy) {
      return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    }
    Widget action(String key, String state, String text, IconData icon, VoidCallback onPressed) {
      final button = compact
          ? IconButton(key: Key('$key-$id'), tooltip: text, onPressed: onPressed, icon: Icon(icon))
          : TextButton.icon(key: Key('$key-$id'), onPressed: onPressed, icon: Icon(icon), label: Text(text));
      return Row(mainAxisSize: MainAxisSize.min, children: [
        if (state.isNotEmpty) Text(state, key: Key('label-state-$id')),
        button,
      ]);
    }
    switch (label?['status'] as String?) {
      case 'completed':
        return action('label-reprint', 'مطبوعة · الجيل ${label!['generation']}', 'إعادة الطباعة',
            Icons.print_outlined, () => actions.reprint(context, piece));
      case 'failed':
        return action('label-retry', compact ? 'فاشلة' : '', 'إعادة المحاولة', Icons.refresh,
            () => actions.retry(context, id, label!['job_id'] as int));
      case 'needs_attention':
        return action('label-resolve', compact ? 'مجهولة' : '', 'حسم المحاولة', Icons.help_outline,
            () => actions.resolve(context, id, '${piece['item_code']}', label!['attempt_id'] as int));
      case 'pending':
      case 'printing':
      case 'verifying':
        return action('label-run', compact ? 'منتظرة' : '', 'اطبع الآن', Icons.print,
            () => actions.retry(context, id, label!['job_id'] as int));
      default:
        if (piece['tag'] != null) {
          // a tag adopted before ADR-097 (generation 0): printed -- reprinted with a reason
          return action('label-reprint', 'رقاقة معتمدة', 'إعادة الطباعة', Icons.print_outlined,
              () => actions.reprint(context, piece));
        }
        return action('label-print', compact ? 'بلا بطاقة' : '', 'اطبع البطاقة', Icons.print,
            () => actions.print(context, piece));
    }
  }
}

/// An attempt whose end is not known (ADR-097 law 10): the label that came
/// out read by the handheld reader -- it types the tag's value into the field
/// -- or no label came out. Returns the request's body.
class ResolveLabelDialog extends StatefulWidget {
  const ResolveLabelDialog({super.key, required this.code});
  final String code;

  @override
  State<ResolveLabelDialog> createState() => _ResolveLabelDialogState();
}

class _ResolveLabelDialogState extends State<ResolveLabelDialog> {
  final _read = TextEditingController();

  @override
  void dispose() {
    _read.dispose();
    super.dispose();
  }

  void _adopt() {
    final value = _read.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop({'read_value': value});
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text('بطاقة ${widget.code}: هل خرج ملصق؟'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('انقطع الاتصال بالطابعة ولا يُعرف هل كُتبت الرقاقة. '
                'إن خرج ملصق فاقرأه بالقارئ هنا، وإلا اضغط «لم يخرج ملصق».'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('resolve-read'),
              controller: _read,
              autofocus: true,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'رمز الرقاقة من القارئ'),
              onSubmitted: (_) => _adopt(),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('resolve-no-label'),
            onPressed: () => Navigator.of(context).pop({'no_label': true}),
            child: const Text('لم يخرج ملصق'),
          ),
          FilledButton(key: const Key('resolve-adopt'), onPressed: _adopt, child: const Text('اعتمد القراءة')),
        ],
      ),
    );
  }
}
