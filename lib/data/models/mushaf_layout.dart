import 'package:meta/meta.dart';

/// Un mot positionné du Mushaf, tel que renvoyé par le groupe de ressources
/// `mushafs` (`record_type: "mushaf_word"`).
///
/// Le champ [text] ne contient pas des lettres mais un **glyphe** : les polices
/// QCF sont des polices « glyph-based », où chaque mot du Coran est un glyphe
/// unique. C'est ce qui permet un rendu identique à l'imprimé — à condition
/// d'utiliser la police de la page correspondante.
@immutable
class MushafWord {
  const MushafWord({
    required this.wordId,
    required this.text,
    required this.charTypeName,
    required this.lineNumber,
    required this.positionInLine,
    required this.positionInPage,
    this.verseId,
  });

  final int wordId;

  /// Glyphe (et non texte lisible) issu de la police QCF de la page.
  final String text;

  /// `word`, `end` (marqueur de fin de verset), `surah_name`, `bismillah`,
  /// `pause`…
  final String charTypeName;

  final int lineNumber;
  final int positionInLine;
  final int positionInPage;

  /// Ordinal global du verset auquel appartient ce mot.
  final int? verseId;

  bool get isVerseEnd => charTypeName == 'end';
  bool get isSurahName => charTypeName == 'surah_name';
  bool get isBismillah => charTypeName == 'bismillah';

  /// Un mot de texte normal, par opposition aux marqueurs de mise en page.
  bool get isRegularWord => charTypeName == 'word';

  factory MushafWord.fromJson(Map<String, dynamic> json) {
    return MushafWord(
      wordId: (json['word_id'] as num?)?.toInt() ?? (json['id'] as num).toInt(),
      text: json['text'] as String? ?? '',
      charTypeName: json['char_type_name'] as String? ?? 'word',
      lineNumber: (json['line_number'] as num?)?.toInt() ?? 0,
      positionInLine: (json['position_in_line'] as num?)?.toInt() ?? 0,
      positionInPage: (json['position_in_page'] as num?)?.toInt() ?? 0,
      verseId: (json['verse_id'] as num?)?.toInt(),
    );
  }

  @override
  String toString() =>
      'MushafWord(l$lineNumber p$positionInLine, $charTypeName)';
}

/// Une ligne de la page (le Mushaf madani en compte 15).
@immutable
class MushafLine {
  const MushafLine({required this.lineNumber, required this.words});

  final int lineNumber;
  final List<MushafWord> words;

  bool get isBlank => words.isEmpty;

  /// Vrai si la ligne ne porte que l'en-tête d'une sourate.
  bool get isSurahHeader =>
      words.isNotEmpty && words.every((w) => w.isSurahName);

  /// Vrai si la ligne commence par la basmala.
  bool get startsWithBismillah => words.isNotEmpty && words.first.isBismillah;
}

/// La mise en page complète d'une page du Mushaf.
@immutable
class MushafPageLayout {
  const MushafPageLayout({
    required this.pageNumber,
    required this.lines,
    required this.firstVerseId,
    required this.lastVerseId,
    required this.versesCount,
  });

  final int pageNumber;

  /// Les [MushafLine], indexées de 0 à 14 pour les lignes 1 à 15.
  /// Les lignes vides sont conservées : leur hauteur fait partie de la page.
  final List<MushafLine> lines;

  /// Ordinaux globaux (voir `VerseOrdinalTable`) du premier et du dernier
  /// verset de la page.
  final int firstVerseId;
  final int lastVerseId;

  final int versesCount;

  /// Vrai si aucun mot n'a été reçu pour cette page.
  bool get isBlank => lines.every((line) => line.isBlank);

  @override
  String toString() =>
      'MushafPageLayout(p$pageNumber, ${lines.length} lignes, $versesCount versets)';
}

/// Le Mushaf complet : métadonnées, pages et mots positionnés.
///
/// Provient de `GET /resources/snapshots/mushafs/{id}`.
///
/// ⚠️ Un instantané renvoie **toutes** les lignes du Mushaf d'un coup : pour le
/// Mushaf madani, cela représente environ 70 000 mots positionnés. La réponse
/// est volumineuse mais immuable — elle doit être mise en cache sur disque et
/// non retéléchargée. Les fichiers de police, eux, n'y figurent pas.
@immutable
class MushafSnapshot {
  const MushafSnapshot({
    required this.id,
    required this.name,
    required this.pagesCount,
    required this.linesPerPage,
    required this.defaultFontName,
    required this.pages,
  });

  final int id;
  final String name;
  final int pagesCount;

  /// Toujours 15 pour le Mushaf madani.
  final int linesPerPage;

  /// Nom de la famille de polices attendue — `v2` pour le mushaf 1.
  final String defaultFontName;

  /// Pages indexées par numéro de page (1..604).
  final Map<int, MushafPageLayout> pages;

  /// Construit le Mushaf à partir de l'enveloppe d'instantané de la Content API.
  ///
  /// Les enregistrements `mushaf`, `mushaf_page` et `mushaf_word` arrivent
  /// mêlés dans un tableau unique ; on les trie ici.
  factory MushafSnapshot.fromSnapshotJson(Map<String, dynamic> json) {
    final records = (json['records'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);

    var id = 0;
    var name = '';
    var pagesCount = 0;
    var linesPerPage = 0;
    var defaultFontName = '';

    // page -> ligne -> mots
    final wordsByPage = <int, Map<int, List<MushafWord>>>{};
    // page -> métadonnées de page
    final pageMeta = <int, _PageMeta>{};

    for (final record in records) {
      switch (record['record_type']) {
        case 'mushaf':
          id = (record['id'] as num?)?.toInt() ?? 0;
          name = record['name'] as String? ?? '';
          pagesCount = (record['pages_count'] as num?)?.toInt() ?? 0;
          linesPerPage = (record['lines_per_page'] as num?)?.toInt() ?? 0;
          defaultFontName = record['default_font_name'] as String? ?? '';

        case 'mushaf_page':
          final pageNumber = (record['page_number'] as num?)?.toInt();
          if (pageNumber == null) break;
          pageMeta[pageNumber] = _PageMeta(
            firstVerseId: (record['first_verse_id'] as num?)?.toInt() ?? 0,
            lastVerseId: (record['last_verse_id'] as num?)?.toInt() ?? 0,
            versesCount: (record['verses_count'] as num?)?.toInt() ?? 0,
          );

        case 'mushaf_word':
          final pageNumber = (record['page_number'] as num?)?.toInt();
          if (pageNumber == null) break;
          final word = MushafWord.fromJson(record);
          final lines = wordsByPage.putIfAbsent(pageNumber, () => {});
          lines.putIfAbsent(word.lineNumber, () => []).add(word);
      }
    }

    final effectiveLinesPerPage = linesPerPage > 0 ? linesPerPage : 15;
    final pages = <int, MushafPageLayout>{};

    for (final entry in pageMeta.entries) {
      final pageNumber = entry.key;
      final wordsByLine =
          wordsByPage[pageNumber] ?? const <int, List<MushafWord>>{};
      final lines = <MushafLine>[];

      for (
        var lineNumber = 1;
        lineNumber <= effectiveLinesPerPage;
        lineNumber++
      ) {
        final words = List<MushafWord>.of(
          wordsByLine[lineNumber] ?? const <MushafWord>[],
        )..sort((a, b) => a.positionInLine.compareTo(b.positionInLine));
        lines.add(MushafLine(lineNumber: lineNumber, words: words));
      }

      pages[pageNumber] = MushafPageLayout(
        pageNumber: pageNumber,
        lines: lines,
        firstVerseId: entry.value.firstVerseId,
        lastVerseId: entry.value.lastVerseId,
        versesCount: entry.value.versesCount,
      );
    }

    return MushafSnapshot(
      id: id,
      name: name,
      pagesCount: pagesCount > 0 ? pagesCount : pages.length,
      linesPerPage: effectiveLinesPerPage,
      defaultFontName: defaultFontName,
      pages: pages,
    );
  }

  /// Sérialisation minimale, pour le cache disque.
  Map<String, dynamic> toCacheJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'pages_count': pagesCount,
    'lines_per_page': linesPerPage,
    'default_font_name': defaultFontName,
    'pages': pages.values
        .map(
          (page) => <String, dynamic>{
            'page_number': page.pageNumber,
            'first_verse_id': page.firstVerseId,
            'last_verse_id': page.lastVerseId,
            'verses_count': page.versesCount,
            'lines': page.lines
                .map(
                  (line) => line.words
                      .map(
                        (word) => <String, dynamic>{
                          'word_id': word.wordId,
                          'text': word.text,
                          'char_type_name': word.charTypeName,
                          'line_number': word.lineNumber,
                          'position_in_line': word.positionInLine,
                          'position_in_page': word.positionInPage,
                          'verse_id': word.verseId,
                        },
                      )
                      .toList(growable: false),
                )
                .toList(growable: false),
          },
        )
        .toList(growable: false),
  };

  /// Reconstruit un Mushaf depuis [toCacheJson].
  factory MushafSnapshot.fromCacheJson(Map<String, dynamic> json) {
    final rawPages = (json['pages'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>();
    final linesPerPage = (json['lines_per_page'] as num?)?.toInt() ?? 15;
    final pages = <int, MushafPageLayout>{};

    for (final rawPage in rawPages) {
      final pageNumber = (rawPage['page_number'] as num).toInt();
      final rawLines = (rawPage['lines'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<List<dynamic>>()
          .toList(growable: false);
      final lines = <MushafLine>[];

      for (var index = 0; index < linesPerPage; index++) {
        // Le type est annoté explicitement : sans cela le ternaire s'élargit en
        // `dynamic` et l'appel suivant devient un appel dynamique non vérifié.
        final List<dynamic> rawWords = index < rawLines.length
            ? (rawLines[index] as List<dynamic>? ?? const <dynamic>[])
            : const <dynamic>[];
        final words = rawWords
            .whereType<Map<String, dynamic>>()
            .map(MushafWord.fromJson)
            .toList(growable: false);
        lines.add(MushafLine(lineNumber: index + 1, words: words));
      }

      pages[pageNumber] = MushafPageLayout(
        pageNumber: pageNumber,
        lines: lines,
        firstVerseId: (rawPage['first_verse_id'] as num?)?.toInt() ?? 0,
        lastVerseId: (rawPage['last_verse_id'] as num?)?.toInt() ?? 0,
        versesCount: (rawPage['verses_count'] as num?)?.toInt() ?? 0,
      );
    }

    return MushafSnapshot(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      pagesCount: (json['pages_count'] as num?)?.toInt() ?? pages.length,
      linesPerPage: linesPerPage,
      defaultFontName: json['default_font_name'] as String? ?? '',
      pages: pages,
    );
  }
}

@immutable
class _PageMeta {
  const _PageMeta({
    required this.firstVerseId,
    required this.lastVerseId,
    required this.versesCount,
  });

  final int firstVerseId;
  final int lastVerseId;
  final int versesCount;
}
