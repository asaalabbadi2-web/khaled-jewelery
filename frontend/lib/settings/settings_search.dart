import '../utils/arabic_search.dart';
import 'settings_registry.dart';

// Arabic as people type it -- hamza, ta marbuta, diacritics, Arabic-Indic
// digits -- is the one normalizer the app's search uses (utils/arabic_search.dart).

/// A search hit: the entry, how well it matched, and the word it matched by
/// when not its own name («وُجد بـ…»).
class SettingsHit {
  const SettingsHit(this.entry, this.score, {this.matchedBy});
  final SettingEntry entry;
  final int score;
  final String? matchedBy;
}

int _score(String query, String text) {
  final t = normalizeForSearch(text);
  if (t == query) return 100;
  if (t.startsWith(query)) return 80;
  if (t.contains(query)) return 60;
  return 0;
}

/// The entries a query finds, best first: settings before screens, then by
/// how they matched -- the name itself, then its start, then a synonym, then
/// its description or section. Each entry once; alike entries stay apart.
List<SettingsHit> searchSettings(String raw, {List<SettingEntry> registry = settingsRegistry}) {
  final query = normalizeForSearch(raw);
  if (query.isEmpty) return const [];
  final hits = <SettingsHit>[];
  for (final e in registry) {
    var best = _score(query, e.label);
    String? by;
    for (final word in e.synonyms) {
      final s = _score(query, word);
      final asSynonym = s == 0 ? 0 : s - 30;
      if (asSynonym > best) {
        best = asSynonym;
        by = word;
      }
    }
    for (final text in [e.description, sections[e.section]!.label]) {
      final s = _score(query, text);
      if (s > 0 && 20 > best) {
        best = 20;
        by = null;
      }
    }
    if (best > 0) hits.add(SettingsHit(e, best, matchedBy: by));
  }
  hits.sort((a, b) {
    final kind = a.entry.kind.index.compareTo(b.entry.kind.index);
    if (kind != 0) return kind;
    final score = b.score.compareTo(a.score);
    if (score != 0) return score;
    return a.entry.label.compareTo(b.entry.label);
  });
  return hits;
}
