import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soumaya/data/models/mushaf_layout.dart';
import 'package:soumaya/data/models/verse_key.dart';

import 'support/mushaf_fixtures.dart';

void main() {
  group('VerseKey', () {
    test('compare selon l\'ordre du Mushaf', () {
      expect(VerseKey.tryParse('1:7')! < VerseKey.tryParse('2:1')!, isTrue);
      expect(VerseKey.tryParse('2:255')! > VerseKey.tryParse('2:254')!, isTrue);
      expect(VerseKey.tryParse('2:1')! == const VerseKey(2, 1), isTrue);
    });

    test('refuse une clé mal formée', () {
      expect(VerseKey.tryParse('1'), isNull);
      expect(VerseKey.tryParse('a:b'), isNull);
      expect(VerseKey.tryParse('1:0'), isNull);
      expect(VerseKey.tryParse('0:1'), isNull);
      expect(VerseKey.tryParse('1:1:1'), isNull);
    });
  });

  group('VerseOrdinalTable', () {
    test('convertit clé et ordinal dans les deux sens', () {
      final table = buildOrdinals();
      expect(table.ordinalOf(const VerseKey(1, 1)), 1);
      expect(table.ordinalOf(const VerseKey(1, 7)), 7);
      expect(table.ordinalOf(const VerseKey(2, 1)), 8);
      expect(table.ordinalOf(const VerseKey(2, 5)), 12);

      expect(table.keyOf(1), const VerseKey(1, 1));
      expect(table.keyOf(8), const VerseKey(2, 1));
      expect(table.keyOf(12), const VerseKey(2, 5));
    });

    test('refuse un verset hors bornes de sa sourate', () {
      final table = buildOrdinals();
      expect(table.ordinalOf(const VerseKey(1, 8)), isNull);
      expect(table.ordinalOf(const VerseKey(3, 1)), isNull);
      expect(table.keyOf(0), isNull);
      expect(table.keyOf(13), isNull);
    });

    test(
      'signale une table incomplète plutôt que de la faire passer pour bonne',
      () {
        // 12 versets sur 6236, 2 sourates sur 114.
        expect(buildOrdinals().isComplete, isFalse);
        expect(buildOrdinals().coveredVerseCount, 12);
      },
    );
  });

  group('MushafIndex', () {
    test('localise un verset sur sa page', () {
      final index = buildIndex();
      expect(index.pageForVerse('1:1'), 1);
      expect(index.pageForVerse('1:3'), 1);
      expect(index.pageForVerse('1:5'), 2);
      expect(index.pageForVerse('2:1'), 3);
      expect(index.pageForVerse('2:5'), 3);
    });

    test('renvoie null pour un verset inconnu', () {
      final index = buildIndex();
      expect(index.pageForVerse('3:1'), isNull);
      expect(index.pageForVerse('n\'importe quoi'), isNull);
    });

    test('couvre une plage à cheval sur deux pages', () {
      final index = buildIndex();
      expect(index.pagesForRange('1:6', '2:2'), <int>[2, 3]);
      expect(index.pagesForRange('1:1', '1:3'), <int>[1]);
    });

    test('refuse une plage inversée', () {
      final index = buildIndex();
      expect(index.pagesForRange('2:1', '1:1'), isEmpty);
    });

    test('signale un index incomplet', () {
      expect(buildIndex().isComplete, isFalse);
    });
  });

  group('MushafSnapshot', () {
    test('lit les métadonnées du mushaf', () {
      final snapshot = buildSnapshot();
      expect(snapshot.id, 1);
      expect(snapshot.name, 'QCF V2');
      expect(snapshot.linesPerPage, 15);
      expect(snapshot.defaultFontName, 'v2');
      expect(snapshot.pages.length, 3);
    });

    test('répartit les mots sur 15 lignes et les trie par position', () {
      final page = buildSnapshot().pages[1]!;
      expect(page.lines.length, 15);
      expect(page.lines[0].words.map((w) => w.text).toList(), <String>[
        'glyphe-1',
        'glyphe-2',
        'glyphe-fin',
      ]);
      expect(page.lines[1].isBlank, isTrue);
      expect(page.lines[0].words.last.isVerseEnd, isTrue);
      expect(page.lines[0].words.first.isRegularWord, isTrue);
    });

    test('survit à un aller-retour par le cache disque', () {
      final original = buildSnapshot();
      final restored = MushafSnapshot.fromCacheJson(
        jsonDecode(jsonEncode(original.toCacheJson())) as Map<String, dynamic>,
      );

      expect(restored.id, original.id);
      expect(restored.defaultFontName, original.defaultFontName);
      expect(restored.pages.length, original.pages.length);

      final originalPage = original.pages[1]!;
      final restoredPage = restored.pages[1]!;
      expect(restoredPage.firstVerseId, originalPage.firstVerseId);
      expect(restoredPage.lastVerseId, originalPage.lastVerseId);
      expect(restoredPage.lines.length, originalPage.lines.length);
      expect(
        restoredPage.lines[0].words.map((w) => w.text).toList(),
        originalPage.lines[0].words.map((w) => w.text).toList(),
      );
      expect(
        restoredPage.lines[0].words.last.charTypeName,
        originalPage.lines[0].words.last.charTypeName,
      );
    });
  });
}
