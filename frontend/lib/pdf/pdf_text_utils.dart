/// Sanitizes a string for safe rendering in PDF with the Cairo/Arabic font.
///
/// Replaces common Unicode symbols that are not present in the Cairo font
/// (arrows, em-dash, bullet, etc.) with ASCII/Arabic equivalents so they
/// do not appear as empty boxes (tofu) in the output.
String pdfSanitize(String input) {
  if (input.isEmpty) return input;
  return input
      .replaceAll('\u2192', '->') // →
      .replaceAll('\u2190', '<-') // ←
      .replaceAll('\u2194', '<->') // ↔
      .replaceAll('\u21D2', '=>') // ⇒
      .replaceAll('\u21D0', '<=') // ⇐
      .replaceAll('\u2014', ' - ') // —  em-dash
      .replaceAll('\u2013', ' - ') // –  en-dash
      .replaceAll('\u2022', '*') // •  bullet
      .replaceAll('\u25CF', '*') // ● filled circle
      .replaceAll('\u25CB', 'o') // ○ open circle
      .replaceAll('\u2713', '+') // ✓
      .replaceAll('\u2714', '+') // ✔
      .replaceAll('\u2715', 'x') // ✕
      .replaceAll('\u274C', 'x') // ❌
      .replaceAll('\u2705', '+') // ✅
      .replaceAll('\u26A0', '!') // ⚠
      .replaceAll('\u2248', '~') // ≈
      .replaceAll('\u2260', '!=') // ≠
      .replaceAll('\u2264', '<=') // ≤
      .replaceAll('\u2265', '>='); // ≥
}

String pdfShapeArabic(String input) {
  if (input.isEmpty) return input;
  if (!_containsArabicLetters(input)) return input;

  // NOTE: We intentionally do NOT apply BiDi reordering here.
  // Most templates already set `textDirection: pw.TextDirection.rtl`.
  // Applying BiDi here as well can cause double-reversal (garbled Arabic).
  return _shapeArabic(input);
}

/// Returns a visually ordered Arabic string intended to be rendered with
/// `textDirection: pw.TextDirection.ltr`.
///
/// Why: `package:pdf` uses an internal BiDi implementation that can throw
/// `RangeError` for some shaped Arabic presentation-form code points.
/// Rendering as LTR with visual ordering avoids that crash.
///
/// This function keeps non-Arabic runs (numbers/Latin) in their original order
/// while reversing Arabic runs.
String pdfVisualArabic(String input) {
  if (input.isEmpty) return input;
  if (!_containsArabicLetters(input)) return input;

  // Protect currency abbreviation from being split/reordered by punctuation.
  // This fixes cases like (ر.س) where the dot/parentheses can cause
  // "mirrored" output after visual reordering.
  final protected = _protectCurrencyTokens(input);

  final shaped = _shapeArabic(protected.text);
  final shapedRunes = shaped.runes.toList(growable: false);
  if (shapedRunes.isEmpty) return shaped;

  bool isStrongRtl(int r) {
    // Marks stay with Arabic runs.
    if (_isArabicMark(r)) return true;
    // Presentation Forms blocks used by our shaper.
    if (r >= 0xFE70 && r <= 0xFEFF) return true;
    // Fallback for any Arabic letters that might remain.
    return _isArabicLetter(r);
  }

  bool isStrongLtr(int r) {
    // ASCII digits
    if (r >= 0x0030 && r <= 0x0039) return true;
    // Arabic-Indic digits
    if (r >= 0x0660 && r <= 0x0669) return true;
    // Extended Arabic-Indic digits
    if (r >= 0x06F0 && r <= 0x06F9) return true;
    // Basic Latin letters
    if ((r >= 0x0041 && r <= 0x005A) || (r >= 0x0061 && r <= 0x007A)) {
      return true;
    }
    return false;
  }

  // Compute RTL flags with context-aware handling of neutrals.
  // We render with LTR direction, so we must keep neutral punctuation and
  // brackets attached to the correct side, otherwise strings like
  // "ذهب (وزن)" can become "ذهب) وزن(".
  final rtlFlags = List<bool>.filled(shapedRunes.length, false);
  final strong = List<int>.filled(shapedRunes.length, 0);
  // strong: -1 = strong RTL, +1 = strong LTR, 0 = neutral
  for (var i = 0; i < shapedRunes.length; i++) {
    final r = shapedRunes[i];
    if (isStrongRtl(r)) {
      strong[i] = -1;
      rtlFlags[i] = true;
    } else if (isStrongLtr(r)) {
      strong[i] = 1;
    }
  }

  // Paired brackets take one direction, from what they hold (the bidi
  // algorithm's N0): Arabic or a number inside -- the text's own direction;
  // only Latin inside -- the Latin before them, when there is. A closing
  // bracket after «...-00566» was read alone and leapt to the far end of
  // «دفعات فاتورة SELL-2026-546 (RV-2026-00566)» (PRINT-4). Resolved first,
  // they count as strong for the neutrals around them.
  {
    const closerOf = {0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D, 0x00AB: 0x00BB};
    final open = <int>[];
    for (var i = 0; i < shapedRunes.length; i++) {
      final r = shapedRunes[i];
      if (closerOf.containsKey(r)) {
        open.add(i);
        continue;
      }
      if (open.isEmpty || closerOf[shapedRunes[open.last]] != r) continue;
      final o = open.removeLast();
      var holdsRtl = false, holdsLatin = false;
      for (var j = o + 1; j < i; j++) {
        final rr = shapedRunes[j];
        if (isStrongRtl(rr) || (rr >= 0x30 && rr <= 0x39) || (rr >= 0x660 && rr <= 0x669) || (rr >= 0x6F0 && rr <= 0x6F9)) {
          holdsRtl = true;
        } else if (isStrongLtr(rr)) {
          holdsLatin = true;
        }
      }
      var dir = -1;
      if (!holdsRtl && holdsLatin) {
        // Only Latin inside: as the Latin before the pair, if any.
        for (var j = o - 1; j >= 0; j--) {
          if (strong[j] != 0) {
            final digit = shapedRunes[j] >= 0x30 && shapedRunes[j] <= 0x39;
            dir = (strong[j] == 1 && !digit) ? 1 : -1;
            break;
          }
        }
      }
      for (final k in [o, i]) {
        strong[k] = dir;
        rtlFlags[k] = dir == -1;
      }
    }
  }

  bool isNeutralThatShouldStickToRtl(int r) {
    // Whitespace (keep with RTL so word spacing doesn't disappear/split)
    if (r == 0x20 /* space */) return true;
    if (r == 0x00A0 /* NBSP */) return true;
    if (r == 0x09 /* \t */) return true;
    if (r == 0x0A /* \n */) return true;
    if (r == 0x0D /* \r */) return true;

    // Parentheses / brackets that should visually wrap RTL text.
    if (r == 0x28 /* ( */ || r == 0x29 /* ) */) return true;
    // Ornate parentheses used in some Arabic text.
    if (r == 0xFD3E /* ﴾ */ || r == 0xFD3F /* ﴿ */) return true;
    if (r == 0x5B /* [ */ || r == 0x5D /* ] */) return true;
    if (r == 0x7B /* { */ || r == 0x7D /* } */) return true;
    // Angle quotes and guillemets (common in Arabic docs).
    if (r == 0x00AB /* « */ || r == 0x00BB /* » */) return true;

    // Common punctuation in Arabic UI labels.
    if (r == 0x060C /* ، */) return true;
    if (r == 0x061B /* ؛ */) return true;
    if (r == 0x061F /* ؟ */) return true;
    if (r == 0x003A /* : */) return true;
    if (r == 0x002F /* / */) return true;
    if (r == 0x002D /* - */) return true;
    if (r == 0x2013 /* – */ || r == 0x2014 /* — */) return true;
    if (r == 0x002E /* . */) return true;

    // Our private-use placeholders (used to protect tokens like ر.س).
    if (r >= 0xE000 && r <= 0xF8FF) return true;

    return false;
  }

  int nearestStrongDir(int from, int step) {
    for (var i = from; i >= 0 && i < strong.length; i += step) {
      final s = strong[i];
      if (s != 0) return s;
    }
    return 0;
  }

  // Assign direction to neutrals by looking for nearest strong characters
  // on both sides (skipping over other neutrals). This handles cases where
  // a neutral is separated by spaces from the strong RTL text.
  for (var i = 0; i < shapedRunes.length; i++) {
    if (strong[i] != 0) continue;
    final r = shapedRunes[i];
    if (!isNeutralThatShouldStickToRtl(r)) continue;

    bool isBracketLike(int rr) {
      return rr == 0x28 /* ( */ ||
          rr == 0x29 /* ) */ ||
          rr == 0xFD3E /* ﴾ */ ||
          rr == 0xFD3F /* ﴿ */ ||
          rr == 0x5B /* [ */ ||
          rr == 0x5D /* ] */ ||
          rr == 0x7B /* { */ ||
          rr == 0x7D /* } */ ||
          rr == 0x00AB /* « */ ||
          rr == 0x00BB /* » */;
    }

    bool isAnyDigit(int rr) {
      // ASCII digits
      if (rr >= 0x0030 && rr <= 0x0039) return true;
      // Arabic-Indic digits
      if (rr >= 0x0660 && rr <= 0x0669) return true;
      // Extended Arabic-Indic digits
      if (rr >= 0x06F0 && rr <= 0x06F9) return true;
      return false;
    }

    int nearestStrongDirSkippingDigits(int from, int step) {
      for (var j = from; j >= 0 && j < strong.length; j += step) {
        final s = strong[j];
        if (s == 0) continue;
        if (s == 1 && isAnyDigit(shapedRunes[j])) {
          // Digits inside Arabic context should not flip surrounding brackets.
          continue;
        }
        return s;
      }
      return 0;
    }

    final left = nearestStrongDir(i - 1, -1);
    final right = nearestStrongDir(i + 1, 1);

    // Brackets should cling to the direction of the text they wrap.
    // Specifically, for Arabic phrases that include digits inside parentheses
    // (e.g. "(عيار 21)"), the closing bracket can appear after digits and be
    // mistakenly treated as LTR. We fix that by deciding bracket direction
    // while skipping digits when searching for nearby strong characters.
    if (isBracketLike(r)) {
      final leftNoDigits = nearestStrongDirSkippingDigits(i - 1, -1);
      final rightNoDigits = nearestStrongDirSkippingDigits(i + 1, 1);
      if (leftNoDigits == -1 || rightNoDigits == -1) {
        rtlFlags[i] = true;
        continue;
      }
    }

    // The text is Arabic, so its direction is right to left: a neutral
    // takes it unless both its sides are left to right (the Unicode bidi
    // algorithm's N1/N2). Between an Arabic word and a number it took the
    // number's side and stood beyond it -- «بنجرة ذهب 21» printed «21»
    // touching «ذهب», «تاريخ الطباعة: 2026-10-28» printed «: 2026-10-28
    // تاريخ الطباعة» (PRINT-4). Between two numbers or Latin words -- a
    // date's dashes, «PAYMENT - PV» -- it stays with them.
    final shouldBeRtl = !(left == 1 && right == 1);

    if (shouldBeRtl) rtlFlags[i] = true;
  }

  final runs = <({bool rtl, List<int> runes})>[];
  for (var i = 0; i < shapedRunes.length; i++) {
    final r = shapedRunes[i];
    final rtl = rtlFlags[i];
    if (runs.isEmpty || runs.last.rtl != rtl) {
      runs.add((rtl: rtl, runes: <int>[r]));
    } else {
      runs.last.runes.add(r);
    }
  }

  final out = <int>[];
  for (final run in runs.reversed) {
    if (run.rtl) {
      // Reverse RTL run for visual order, but keep Arabic marks (tashkeel)
      // attached to their base letter. Reversing marks independently can
      // visually corrupt glyphs.
      final clusters = <List<int>>[];
      for (final r in run.runes) {
        if (_isArabicMark(r) && clusters.isNotEmpty) {
          clusters.last.add(r);
        } else {
          clusters.add(<int>[r]);
        }
      }

      for (final cluster in clusters.reversed) {
        for (final r in cluster) {
          out.add(_mirrorBracketForRtl(r));
        }
      }
    } else {
      out.addAll(run.runes);
    }
  }

  final visual = String.fromCharCodes(out);
  return protected.restore(visual);
}

int _mirrorBracketForRtl(int r) {
  return switch (r) {
    0x28 => 0x29, // ( -> )
    0x29 => 0x28, // ) -> (
    0xFD3E => 0xFD3F, // ﴾ -> ﴿
    0xFD3F => 0xFD3E, // ﴿ -> ﴾
    0x5B => 0x5D, // [ -> ]
    0x5D => 0x5B, // ] -> [
    0x7B => 0x7D, // { -> }
    0x7D => 0x7B, // } -> {
    0x00AB => 0x00BB, // « -> »
    0x00BB => 0x00AB, // » -> «
    _ => r,
  };
}

class _ProtectedText {
  final String text;
  final Map<int, String> _placeholderToToken;

  const _ProtectedText(this.text, this._placeholderToToken);

  String restore(String s) {
    if (_placeholderToToken.isEmpty) return s;
    final out = StringBuffer();
    for (final r in s.runes) {
      final token = _placeholderToToken[r];
      if (token != null) {
        out.write(token);
      } else {
        out.writeCharCode(r);
      }
    }
    return out.toString();
  }
}

_ProtectedText _protectCurrencyTokens(String input) {
  // We store the currency token in VISUAL (reversed) order so that when
  // `pdfVisualArabic` places it at the START of the visual LTR output string
  // (because the surrounding RTL run is reversed), an Arabic reader reading
  // right-to-left sees the characters in the correct logical order.
  //
  // Why reversed:
  //   `pdfVisualArabic` reverses the whole RTL run → the token (a single
  //   cluster placeholder) ends up at the leftmost position.  The reader
  //   reads RIGHT→LEFT, so the leftmost char is seen LAST.  If we stored
  //   "ر.س" (Ra, dot, Seen) the reader would see: Seen·dot·Ra = "س.ر" ✗
  //   If we store reversed "ﺱ.ﺮ" (Seen, dot, Ra) the reader sees:
  //   Ra·dot·Seen = "ر.س" ✓
  //
  // U+FEB1 = ﺱ  (Seen isolated form)   — leftmost in visual LTR string
  // U+FEAD = ﺭ  (Ra   isolated form)   — rightmost in visual LTR string
  // (Ra in ر.س / ريال is always first letter → no preceding connector → isolated form)
  const normalizedPlain = '\uFEB1.\uFEAD'; // visual reversed "ر.س"
  // For the parenthesized form: brackets are also stored reversed so the RTL
  // reader sees opening "(" on the right and closing ")" on the left.
  const normalizedParen = ')\uFEB1.\uFEAD('; // visual reversed "(ر.س)"

  // "ريال" — visual reversed presentation forms:
  // Logical:  ر(FEAD) ي(FEF3) ا(FE8E) ل(FEDD)   — Ra is first letter → isolated (FEAD)
  // Reversed: ل(FEDD) ا(FE8E) ي(FEF3) ر(FEAD)
  const shapedRiyalReversed = '\uFEDD\uFE8E\uFEF3\uFEAD';
  const normalizedRiyal = shapedRiyalReversed;
  const normalizedRiyalParen = ')$shapedRiyalReversed(';

  // ﷼ (U+FDFC) Arabic Rial Sign — single code point, stored as-is.
  // Protected so the placeholder mechanism keeps it in visual position order.
  const normalizedRialSign = '\uFDFC';

  // Match (ر.س), ر.س, (ريال), ريال, (﷼), or ﷼.
  final re = RegExp('\\(\\s*ر\\s*\\.\\s*س\\s*\\)|\\(\\s*ريال\\s*\\)|\\(\\s*\uFDFC\\s*\\)|ر\\s*\\.\\s*س|ريال|\uFDFC');

  final matches = re.allMatches(input).toList(growable: false);
  if (matches.isEmpty) return _ProtectedText(input, const {});

  // Use Private Use Area placeholders (unlikely to appear in user text).
  var nextPlaceholder = 0xE000;
  final placeholderToToken = <int, String>{};

  final buf = StringBuffer();
  var last = 0;
  for (final m in matches) {
    buf.write(input.substring(last, m.start));

    final raw = m.group(0) ?? '';
    final isParen = raw.trimLeft().startsWith('(');
    final isRiyal = raw.contains('ريال');
    final isRialSign = raw.contains('\uFDFC');
    final placeholder = nextPlaceholder++;
    if (isRialSign) {
      placeholderToToken[placeholder] = normalizedRialSign;
    } else if (isRiyal) {
      placeholderToToken[placeholder] = isParen ? normalizedRiyalParen : normalizedRiyal;
    } else {
      placeholderToToken[placeholder] = isParen ? normalizedParen : normalizedPlain;
    }
    buf.writeCharCode(placeholder);

    last = m.end;
  }
  buf.write(input.substring(last));
  return _ProtectedText(buf.toString(), placeholderToToken);
}

bool _containsArabicLetters(String text) {
  for (final rune in text.runes) {
    if (_isArabicLetter(rune)) return true;
  }
  return false;
}

bool _isArabicLetter(int rune) {
  // Basic Arabic + Arabic supplement letters that commonly appear.
  return (rune >= 0x0600 && rune <= 0x06FF) ||
      (rune >= 0x0750 && rune <= 0x077F) ||
      (rune >= 0x08A0 && rune <= 0x08FF);
}

bool _isArabicMark(int rune) {
  // Arabic diacritics (tashkeel) and related marks.
  return (rune >= 0x0610 && rune <= 0x061A) ||
      (rune >= 0x064B && rune <= 0x065F) ||
      (rune >= 0x0670 && rune <= 0x0670) ||
      (rune >= 0x06D6 && rune <= 0x06ED);
}

bool _isJoinCausing(int rune) {
  // Tatweel
  return rune == 0x0640;
}

String _shapeArabic(String input) {
  final runes = input.runes.toList(growable: false);
  final out = <int>[];

  int? previousRelevantIndex(int from) {
    for (var i = from; i >= 0; i--) {
      final r = runes[i];
      if (_isArabicMark(r)) continue;
      return i;
    }
    return null;
  }

  int? nextRelevantIndex(int from) {
    for (var i = from; i < runes.length; i++) {
      final r = runes[i];
      if (_isArabicMark(r)) continue;
      return i;
    }
    return null;
  }

  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];

    // Keep marks as-is; they should follow the shaped base letter.
    if (_isArabicMark(r)) {
      out.add(r);
      continue;
    }

    // Lam-Alef ligatures.
    if (r == 0x0644 /* ل */) {
      final ni = nextRelevantIndex(i + 1);
      if (ni != null) {
        final next = runes[ni];
        final ligature = _lamAlefLigature(next);
        if (ligature != null) {
          final pi = previousRelevantIndex(i - 1);
          final prev = pi == null ? null : runes[pi];
          final connectPrev = prev != null && _canConnectToNext(prev) && _canConnectToPrev(r);

          out.add(connectPrev ? ligature.finalForm : ligature.isolatedForm);
          // Skip the alef character we consumed.
          if (ni == i + 1) {
            i = ni;
          } else {
            // If there were marks between lam and alef, keep them.
            for (var k = i + 1; k < ni; k++) {
              out.add(runes[k]);
            }
            i = ni;
          }
          continue;
        }
      }
    }

    final forms = _arabicForms[r];
    if (forms == null) {
      out.add(r);
      continue;
    }

    final pi = previousRelevantIndex(i - 1);
    final ni = nextRelevantIndex(i + 1);
    final prev = pi == null ? null : runes[pi];
    final next = ni == null ? null : runes[ni];

    final connectPrev = prev != null && _canConnectToNext(prev) && _canConnectToPrev(r);
    final connectNext = next != null && _canConnectToPrev(next) && _canConnectToNext(r);

    final shaped = switch ((connectPrev, connectNext)) {
      (true, true) => forms.medial ?? forms.finalForm,
      (true, false) => forms.finalForm,
      (false, true) => forms.initial ?? forms.isolated,
      (false, false) => forms.isolated,
    };

    // If this letter is fully isolated, prefer keeping the base codepoint
    // only for yeh (ي). Some renderers/fonts display isolated yeh
    // presentation forms oddly.
    if (!connectPrev && !connectNext && r == 0x064A /* ي */) {
      out.add(r);
    } else {
      out.add(shaped);
    }
  }

  return String.fromCharCodes(out);
}

bool _canConnectToPrev(int rune) {
  if (_isArabicMark(rune)) return false;
  if (_isJoinCausing(rune)) return true;
  return _arabicForms.containsKey(rune);
}

bool _canConnectToNext(int rune) {
  if (_isArabicMark(rune)) return false;
  if (_isJoinCausing(rune)) return true;
  return !_nonJoinToNext.contains(rune) && _arabicForms.containsKey(rune);
}

class _ArabicForms {
  final int isolated;
  final int finalForm;
  final int? initial;
  final int? medial;

  const _ArabicForms({
    required this.isolated,
    required this.finalForm,
    this.initial,
    this.medial,
  });
}

class _LamAlefLigature {
  final int isolatedForm;
  final int finalForm;

  const _LamAlefLigature(this.isolatedForm, this.finalForm);
}

_LamAlefLigature? _lamAlefLigature(int alefRune) {
  // https://unicode.org/charts/PDF/UFE70.pdf (Arabic Presentation Forms-B)
  return switch (alefRune) {
    0x0627 => const _LamAlefLigature(0xFEFB, 0xFEFC), // لا
    0x0622 => const _LamAlefLigature(0xFEF5, 0xFEF6), // لآ
    0x0623 => const _LamAlefLigature(0xFEF7, 0xFEF8), // لأ
    0x0625 => const _LamAlefLigature(0xFEF9, 0xFEFA), // لإ
    _ => null,
  };
}

// Arabic letters that do NOT connect to the next letter.
const Set<int> _nonJoinToNext = {
  0x0621, // ء
  0x0622, // آ
  0x0623, // أ
  0x0624, // ؤ
  0x0625, // إ
  0x0627, // ا
  0x0629, // ة
  0x062F, // د
  0x0630, // ذ
  0x0631, // ر
  0x0632, // ز
  0x0648, // و
  0x0649, // ى (alef maksura)
};

// Mapping from base Arabic codepoint -> presentation forms.
// This is a pragmatic subset covering common Arabic used in the app.
const Map<int, _ArabicForms> _arabicForms = {
  0x0622: _ArabicForms(isolated: 0xFE81, finalForm: 0xFE82),
  0x0623: _ArabicForms(isolated: 0xFE83, finalForm: 0xFE84),
  0x0624: _ArabicForms(isolated: 0xFE85, finalForm: 0xFE86),
  0x0625: _ArabicForms(isolated: 0xFE87, finalForm: 0xFE88),
  0x0626: _ArabicForms(isolated: 0xFE89, finalForm: 0xFE8A, initial: 0xFE8B, medial: 0xFE8C),
  0x0627: _ArabicForms(isolated: 0xFE8D, finalForm: 0xFE8E),
  0x0628: _ArabicForms(isolated: 0xFE8F, finalForm: 0xFE90, initial: 0xFE91, medial: 0xFE92),
  0x0629: _ArabicForms(isolated: 0xFE93, finalForm: 0xFE94),
  0x062A: _ArabicForms(isolated: 0xFE95, finalForm: 0xFE96, initial: 0xFE97, medial: 0xFE98),
  0x062B: _ArabicForms(isolated: 0xFE99, finalForm: 0xFE9A, initial: 0xFE9B, medial: 0xFE9C),
  0x062C: _ArabicForms(isolated: 0xFE9D, finalForm: 0xFE9E, initial: 0xFE9F, medial: 0xFEA0),
  0x062D: _ArabicForms(isolated: 0xFEA1, finalForm: 0xFEA2, initial: 0xFEA3, medial: 0xFEA4),
  0x062E: _ArabicForms(isolated: 0xFEA5, finalForm: 0xFEA6, initial: 0xFEA7, medial: 0xFEA8),
  0x062F: _ArabicForms(isolated: 0xFEA9, finalForm: 0xFEAA),
  0x0630: _ArabicForms(isolated: 0xFEAB, finalForm: 0xFEAC),
  0x0631: _ArabicForms(isolated: 0xFEAD, finalForm: 0xFEAE),
  0x0632: _ArabicForms(isolated: 0xFEAF, finalForm: 0xFEB0),
  0x0633: _ArabicForms(isolated: 0xFEB1, finalForm: 0xFEB2, initial: 0xFEB3, medial: 0xFEB4),
  0x0634: _ArabicForms(isolated: 0xFEB5, finalForm: 0xFEB6, initial: 0xFEB7, medial: 0xFEB8),
  0x0635: _ArabicForms(isolated: 0xFEB9, finalForm: 0xFEBA, initial: 0xFEBB, medial: 0xFEBC),
  0x0636: _ArabicForms(isolated: 0xFEBD, finalForm: 0xFEBE, initial: 0xFEBF, medial: 0xFEC0),
  0x0637: _ArabicForms(isolated: 0xFEC1, finalForm: 0xFEC2, initial: 0xFEC3, medial: 0xFEC4),
  0x0638: _ArabicForms(isolated: 0xFEC5, finalForm: 0xFEC6, initial: 0xFEC7, medial: 0xFEC8),
  0x0639: _ArabicForms(isolated: 0xFEC9, finalForm: 0xFECA, initial: 0xFECB, medial: 0xFECC),
  0x063A: _ArabicForms(isolated: 0xFECD, finalForm: 0xFECE, initial: 0xFECF, medial: 0xFED0),
  0x0641: _ArabicForms(isolated: 0xFED1, finalForm: 0xFED2, initial: 0xFED3, medial: 0xFED4),
  0x0642: _ArabicForms(isolated: 0xFED5, finalForm: 0xFED6, initial: 0xFED7, medial: 0xFED8),
  0x0643: _ArabicForms(isolated: 0xFED9, finalForm: 0xFEDA, initial: 0xFEDB, medial: 0xFEDC),
  0x0644: _ArabicForms(isolated: 0xFEDD, finalForm: 0xFEDE, initial: 0xFEDF, medial: 0xFEE0),
  0x0645: _ArabicForms(isolated: 0xFEE1, finalForm: 0xFEE2, initial: 0xFEE3, medial: 0xFEE4),
  0x0646: _ArabicForms(isolated: 0xFEE5, finalForm: 0xFEE6, initial: 0xFEE7, medial: 0xFEE8),
  0x0647: _ArabicForms(isolated: 0xFEE9, finalForm: 0xFEEA, initial: 0xFEEB, medial: 0xFEEC),
  0x0648: _ArabicForms(isolated: 0xFEED, finalForm: 0xFEEE),
  0x0649: _ArabicForms(isolated: 0xFEEF, finalForm: 0xFEF0),
  0x064A: _ArabicForms(isolated: 0xFEF1, finalForm: 0xFEF2, initial: 0xFEF3, medial: 0xFEF4),
};
