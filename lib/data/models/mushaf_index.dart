import 'package:meta/meta.dart';

import 'mushaf_layout.dart';
import 'verse_key.dart';

/// Index de localisation : quel verset se trouve sur quelle page.
///
/// Construit à partir de deux sources seulement :
///  * les ordinaux `first_verse_id` / `last_verse_id` de chaque page, fournis
///    par l'instantané `mushafs` ;
///  * la table d'ordinaux déduite de `verses_count` de `GET /chapters`.
///
/// On évite volontairement de s'appuyer sur `verse_mapping` : ce champ prend
/// deux formes différentes selon l'endpoint (`{"47:1": "47:3"}` côté
/// `/pages/{n}`, `{"1": "1:1"}` côté instantané), ce qui rend son
/// interprétation fragile.
@immutable
class MushafIndex {
  /// Constructeur privé à paramètres positionnels : Dart interdit un paramètre
  /// nommé commençant par un souligné, et les champs restent privés.
  const MushafIndex._(this._ordinals, this._pageStarts, this._pageNumbers);

  final VerseOrdinalTable _ordinals;

  /// Ordinaux du premier verset de chaque page, strictement croissants.
  final List<int> _pageStarts;

  /// Numéro de page associé à chaque entrée de [_pageStarts].
  final List<int> _pageNumbers;

  VerseOrdinalTable get ordinals => _ordinals;

  int get pageCount => _pageNumbers.length;

  /// L'index couvre-t-il bien les 604 pages, de la première à la dernière ?
  ///
  /// Si `false`, les recherches peuvent renvoyer une page voisine erronée en
  /// silence : l'appelant doit alors se rabattre sur une résolution par appel
  /// à `GET /pages/{n}`.
  bool get isComplete =>
      _ordinals.isComplete &&
      _pageNumbers.isNotEmpty &&
      _pageNumbers.first == 1 &&
      _pageNumbers.last == 604;

  /// Construit l'index. Les pages sans `first_verse_id` exploitable sont
  /// ignorées plutôt que de corrompre la monotonie de la recherche binaire.
  factory MushafIndex.fromSnapshot({
    required MushafSnapshot snapshot,
    required VerseOrdinalTable ordinals,
  }) {
    final entries = <({int page, int start})>[];
    for (final page in snapshot.pages.values) {
      if (page.firstVerseId > 0) {
        entries.add((page: page.pageNumber, start: page.firstVerseId));
      }
    }
    entries.sort((a, b) => a.start.compareTo(b.start));

    return MushafIndex._(
      ordinals,
      entries.map((e) => e.start).toList(growable: false),
      entries.map((e) => e.page).toList(growable: false),
    );
  }

  /// Page contenant l'ordinal [ordinal], ou `null` s'il précède le Mushaf.
  int? pageForOrdinal(int ordinal) {
    if (_pageStarts.isEmpty || ordinal < _pageStarts.first) return null;

    // Recherche binaire du dernier point de départ <= ordinal.
    var low = 0;
    var high = _pageStarts.length - 1;
    var found = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (_pageStarts[middle] <= ordinal) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (found < 0) return null;
    return _pageNumbers[found];
  }

  /// Page contenant le verset [verseKey] — par exemple `"2:255"`.
  int? pageForVerse(String verseKey) {
    final key = VerseKey.tryParse(verseKey);
    if (key == null) return null;
    final ordinal = _ordinals.ordinalOf(key);
    if (ordinal == null) return null;
    return pageForOrdinal(ordinal);
  }

  /// Pages couvrant la plage de versets [from]..[to], bornes incluses.
  ///
  /// Renvoie une liste vide si l'une des deux bornes est introuvable — mieux
  /// vaut ne rien lire que lire la mauvaise page.
  List<int> pagesForRange(String from, String to) {
    final start = pageForVerse(from);
    final end = pageForVerse(to);
    if (start == null || end == null || end < start) return const <int>[];
    return List<int>.generate(
      end - start + 1,
      (i) => start + i,
      growable: false,
    );
  }
}
