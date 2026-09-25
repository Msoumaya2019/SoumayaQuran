import 'package:meta/meta.dart';

/// Une clé de verset `sourate:verset` — par exemple `1:1`, `2:255`.
///
/// L'ordre du Mushaf est exactement l'ordre lexicographique des couples
/// (sourate, verset) : `1:7` précède `2:1`, qui précède `2:286`. Comparer deux
/// clés ne demande donc aucun décalage cumulé.
@immutable
class VerseKey implements Comparable<VerseKey> {
  const VerseKey(this.chapter, this.verse);

  final int chapter;
  final int verse;

  static VerseKey? tryParse(String raw) {
    final parts = raw.split(':');
    if (parts.length != 2) return null;
    final chapter = int.tryParse(parts[0]);
    final verse = int.tryParse(parts[1]);
    if (chapter == null || verse == null) return null;
    if (chapter < 1 || verse < 1) return null;
    return VerseKey(chapter, verse);
  }

  @override
  int compareTo(VerseKey other) {
    final byChapter = chapter.compareTo(other.chapter);
    return byChapter != 0 ? byChapter : verse.compareTo(other.verse);
  }

  bool operator <(VerseKey other) => compareTo(other) < 0;
  bool operator >(VerseKey other) => compareTo(other) > 0;
  bool operator <=(VerseKey other) => compareTo(other) <= 0;
  bool operator >=(VerseKey other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is VerseKey && other.chapter == chapter && other.verse == verse;

  @override
  int get hashCode => Object.hash(chapter, verse);

  @override
  String toString() => '$chapter:$verse';
}

/// Table de correspondance entre clé de verset et *ordinal* global.
///
/// L'API expose, pour chaque page du Mushaf, `first_verse_id` et
/// `last_verse_id`. Ces valeurs ne sont pas des identifiants de verset mais des
/// **ordinaux** : le verset `1:1` vaut 1, `1:2` vaut 2, …, `2:1` vaut 8, et
/// ainsi de suite jusqu'à 6236.
///
/// Cette classe reconstruit la correspondance à partir du nombre de versets par
/// sourate (`verses_count` de `GET /chapters`), ce qui permet ensuite de
/// localiser n'importe quel verset sans télécharger les 604 pages.
@immutable
class VerseOrdinalTable {
  /// [verseCountsByChapter] associe le numéro de sourate (1..114) à son nombre
  /// de versets. Une entrée manquante rend la table incomplète.
  const VerseOrdinalTable(this.verseCountsByChapter);

  final Map<int, int> verseCountsByChapter;

  static const int expectedChapterCount = 114;
  static const int expectedVerseCount = 6236;

  /// Nombre total de versets couverts par la table.
  int get coveredVerseCount =>
      verseCountsByChapter.values.fold(0, (sum, count) => sum + count);

  /// La table couvre-t-elle l'intégralité du Mushaf ?
  ///
  /// Un index bâti sur une table incomplète produirait des pages fausses en
  /// silence : on préfère l'exposer et laisser l'appelant décider.
  bool get isComplete =>
      verseCountsByChapter.length == expectedChapterCount &&
      coveredVerseCount == expectedVerseCount;

  /// Ordinal du premier verset de [chapter] (1 pour la sourate 1).
  int? firstOrdinalOfChapter(int chapter) {
    if (chapter < 1) return null;
    var ordinal = 1;
    for (var c = 1; c < chapter; c++) {
      final count = verseCountsByChapter[c];
      if (count == null) return null;
      ordinal += count;
    }
    return verseCountsByChapter.containsKey(chapter) ? ordinal : null;
  }

  /// Ordinal global de [key], ou `null` si la table ne le couvre pas.
  int? ordinalOf(VerseKey key) {
    final first = firstOrdinalOfChapter(key.chapter);
    if (first == null) return null;
    final count = verseCountsByChapter[key.chapter]!;
    if (key.verse < 1 || key.verse > count) return null;
    return first + key.verse - 1;
  }

  /// Clé de verset correspondant à [ordinal], ou `null` hors bornes.
  VerseKey? keyOf(int ordinal) {
    if (ordinal < 1) return null;
    var remaining = ordinal;
    for (var chapter = 1; chapter <= expectedChapterCount; chapter++) {
      final count = verseCountsByChapter[chapter];
      if (count == null) return null;
      if (remaining <= count) return VerseKey(chapter, remaining);
      remaining -= count;
    }
    return null;
  }
}
