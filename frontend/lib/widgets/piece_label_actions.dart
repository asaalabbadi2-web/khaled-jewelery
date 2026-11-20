import 'dart:math';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
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

  /// Another label printing (ADR-097 ط6): asked again by itself this often,
  /// this many times -- the server never holds a worker long for the printer.
  static Duration busyPause = const Duration(milliseconds: 1500);
  static const busyTries = 20;

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
      var answer = await call();
      // Another label printing: its turn asked again by itself, nothing written meanwhile.
      for (var i = 0; i < busyTries && (answer['printer'] as Map?)?['busy'] == true; i++) {
        await Future<void>.delayed(busyPause);
        answer = await api.runPrintJob((answer['job'] as Map)['id'] as int);
      }
      final label = labelOf(answer['job'] as Map<String, dynamic>);
      // The printer asked first and not ready: no attempt, no generation --
      // the job waits, and the printer's own words say why (ADR-097, ط6).
      final printer = answer['printer'] as Map<String, dynamic>?;
      if (printer != null && printer['ready'] == false) {
        label['printer_ready'] = false;
        label['printer_message'] = printer['message'];
      }
      onLabel(pieceId, label);
      if (!quiet && context.mounted) {
        if (label['printer_ready'] == false) {
          AppFeedback.warning(context, 'تعذّرت طباعة البطاقة: ${printer!['message']}. القطعة محفوظة وبطاقتها في قائمة الانتظار.');
        } else if (sayFailure && label['status'] != 'completed' && label['status'] != 'pending') {
          AppFeedback.warning(context, failedWords);
        }
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

/// A label's state as the staff see it (ADR-097 ر2): the server's job
/// statuses read -- none added -- each with its colour, its icon and its
/// word, never a colour alone. Printing and verifying are one exchange of
/// two seconds with the printer: one state, «تُطبع الآن».
enum LabelLook {
  waiting('منتظرة', Icons.schedule),
  printing('تُطبع الآن', Icons.print),
  done('مكتملة', Icons.verified_outlined),
  failed('فاشلة', Icons.error_outline),
  unknown('مجهولة', Icons.help_outline),
  /// a piece no label was asked for (before ADR-097)
  none('بلا بطاقة', Icons.label_off_outlined);

  const LabelLook(this.word, this.icon);
  final String word;
  final IconData icon;

  static LabelLook of(Map<String, dynamic> piece) {
    final label = piece['label'] as Map<String, dynamic>?;
    return switch (label?['status'] as String?) {
      'pending' => waiting,
      'printing' || 'verifying' => printing,
      'completed' => done,
      'failed' => failed,
      'needs_attention' => unknown,
      // a tag adopted before ADR-097 (generation 0) is a label done
      _ => piece['tag'] != null ? done : none,
    };
  }

  /// Its word with what tells one label from another: the generation printed.
  static String wordOf(Map<String, dynamic> piece) {
    final look = of(piece);
    final label = piece['label'] as Map<String, dynamic>?;
    if (look == done) {
      return label == null ? 'رقاقة معتمدة' : '${look.word} · الجيل ${label['generation']}';
    }
    return look.word;
  }

  SemanticTone? tone(AppSemanticColors tones) => switch (this) {
        done => tones.ready,
        failed => tones.blocked,
        unknown => tones.warning,
        printing => tones.info,
        waiting || none => null,
      };
}

/// A label's state: its colour, its icon, its word (ADR-097 ر2).
class LabelBadge extends StatelessWidget {
  const LabelBadge({super.key, required this.piece, this.large = false});
  final Map<String, dynamic> piece;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final look = LabelLook.of(piece);
    final tone = look.tone(AppSemanticColors.of(context));
    final bg = tone?.container ?? theme.colorScheme.surfaceContainerHighest;
    final fg = tone?.onContainer ?? theme.colorScheme.onSurfaceVariant;
    final style = (large ? theme.textTheme.titleSmall : theme.textTheme.labelMedium)
        ?.copyWith(color: fg, fontWeight: FontWeight.w700);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 12 : 8, vertical: large ? 6 : 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(large ? 10 : 8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(look.icon, size: large ? 20 : 16, color: fg),
        const SizedBox(width: 4),
        Flexible(child: Text(LabelLook.wordOf(piece), key: Key('label-state-${piece['id']}'), style: style)),
      ]),
    );
  }
}

/// A piece's label: its state and the one thing to do -- in the station's
/// current piece and its log, and in «القطع». A label done offers its
/// reprint in a small menu: a new label is not the next thing to do (ر2).
class PieceLabelCell extends StatelessWidget {
  const PieceLabelCell(
      {super.key,
      required this.piece,
      required this.busy,
      required this.actions,
      this.compact = false,
      this.showState = true});

  final Map<String, dynamic> piece;
  final bool busy;
  final PieceLabelActions actions;

  /// A table's cell: a short word and an icon, the action's words its tooltip.
  final bool compact;

  /// False where its state is said already, larger (the station's current piece).
  final bool showState;

  @override
  Widget build(BuildContext context) {
    final id = piece['id'] as int;
    final label = piece['label'] as Map<String, dynamic>?;
    if (busy) {
      return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    }
    final look = LabelLook.of(piece);
    Widget action(String key, String text, IconData icon, VoidCallback onPressed) {
      if (compact) {
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Text(LabelLook.wordOf(piece), key: Key('label-state-$id')),
          IconButton(key: Key('$key-$id'), tooltip: text, onPressed: onPressed, icon: Icon(icon)),
        ]);
      }
      // a Wrap: on a phone the button goes under its state, never past the edge
      return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
        if (showState) LabelBadge(piece: piece),
        if (look == LabelLook.done)
          PopupMenuButton<void>(
            key: Key('label-menu-$id'),
            tooltip: 'خيارات البطاقة',
            icon: const Icon(Icons.more_vert),
            itemBuilder: (_) => [
              PopupMenuItem<void>(
                key: Key('$key-$id'),
                onTap: onPressed,
                child: ListTile(leading: Icon(icon), title: Text(text), contentPadding: EdgeInsets.zero),
              ),
            ],
          )
        else
          TextButton.icon(key: Key('$key-$id'), onPressed: onPressed, icon: Icon(icon), label: Text(text)),
      ]);
    }
    return switch (look) {
      LabelLook.done => action('label-reprint', 'إعادة الطباعة', Icons.print_outlined,
          () => actions.reprint(context, piece)),
      LabelLook.failed => action('label-retry', 'إعادة المحاولة', Icons.refresh,
          () => actions.retry(context, id, label!['job_id'] as int)),
      LabelLook.unknown => action('label-resolve', 'حسم المحاولة', Icons.help_outline,
          () => actions.resolve(context, id, '${piece['item_code']}', label!['attempt_id'] as int)),
      LabelLook.waiting || LabelLook.printing => action('label-run', 'اطبع الآن', Icons.print,
          () => actions.retry(context, id, label!['job_id'] as int)),
      LabelLook.none => action('label-print', 'اطبع البطاقة', Icons.print, () => actions.print(context, piece)),
    };
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
            // The reader types on its own screen, not this one (ط6): its code
            // read there and written here -- or no label came out.
            const Text('انقطع الاتصال بالطابعة ولا يُعرف هل كُتبت الرقاقة.', key: Key('resolve-why')),
            const SizedBox(height: 8),
            const Text(
              'إن خرج ملصق: اقرأه بالقارئ في تطبيق الملاحظات على القارئ — فالقارئ يكتب في شاشته هو — '
              'ثم اكتب الرمز هنا (24 خانة تبدأ بـ 4B4A). وإلا اضغط «لم يخرج ملصق» وأتلف أي ملصق خرج.',
              key: Key('resolve-how'),
            ),
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
