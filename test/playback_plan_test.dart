import 'package:flutter_test/flutter_test.dart';
import 'package:soumaya/audio/playback_plan.dart';

/// Déroule le curseur jusqu'à épuisement et renvoie la suite des versets joués.
///
/// [maxSteps] borne les politiques infinies, qui ne s'arrêtent jamais d'elles-mêmes.
List<String> _playAll(PlaybackCursor cursor, {int maxSteps = 200}) {
  final played = <String>[cursor.current];
  var steps = 0;
  while (cursor.advance()) {
    played.add(cursor.current);
    steps++;
    if (steps >= maxSteps) break;
  }
  return played;
}

PlaybackCursor _cursor(
  List<String> verses,
  RepeatMode mode,
  RepeatScope scope,
) => PlaybackCursor(
  verses: verses,
  policy: RepeatPolicy(mode: mode, scope: scope),
);

void main() {
  const threeVerses = <String>['1:1', '1:2', '1:3'];

  group('répétition du verset (perVerse)', () {
    test('1x joue chaque verset une fois, dans l\'ordre', () {
      final played = _playAll(
        _cursor(threeVerses, RepeatMode.once, RepeatScope.perVerse),
      );
      expect(played, <String>['1:1', '1:2', '1:3']);
    });

    test('3x répète chaque verset trois fois avant de passer au suivant', () {
      final played = _playAll(
        _cursor(threeVerses, RepeatMode.thrice, RepeatScope.perVerse),
      );
      expect(played, <String>[
        '1:1',
        '1:1',
        '1:1',
        '1:2',
        '1:2',
        '1:2',
        '1:3',
        '1:3',
        '1:3',
      ]);
    });

    test('5x produit bien 5 lectures de chaque verset', () {
      final played = _playAll(
        _cursor(threeVerses, RepeatMode.five, RepeatScope.perVerse),
      );
      expect(played.length, 15);
      expect(played.take(5).toSet(), <String>{'1:1'});
      expect(played.skip(5).take(5).toSet(), <String>{'1:2'});
    });

    test('∞ ne quitte jamais le verset courant', () {
      final played = _playAll(
        _cursor(threeVerses, RepeatMode.infinite, RepeatScope.perVerse),
        maxSteps: 12,
      );
      expect(played.length, 13); // premier + 12 avances
      expect(played.toSet(), <String>{'1:1'});
    });
  });

  group('répétition de la plage (wholeRange)', () {
    test('1x équivaut à une seule passe', () {
      final played = _playAll(
        _cursor(threeVerses, RepeatMode.once, RepeatScope.wholeRange),
      );
      expect(played, <String>['1:1', '1:2', '1:3']);
    });

    test('2x rejoue la plage entière depuis le début', () {
      final played = _playAll(
        _cursor(threeVerses, RepeatMode.twice, RepeatScope.wholeRange),
      );
      expect(played, <String>['1:1', '1:2', '1:3', '1:1', '1:2', '1:3']);
    });

    test('∞ reboucle sans fin sur la plage', () {
      final played = _playAll(
        _cursor(threeVerses, RepeatMode.infinite, RepeatScope.wholeRange),
        maxSteps: 6,
      );
      expect(played, <String>['1:1', '1:2', '1:3', '1:1', '1:2', '1:3', '1:1']);
    });

    test('un seul verset en plage 3x le joue trois fois', () {
      final played = _playAll(
        _cursor(<String>['2:255'], RepeatMode.thrice, RepeatScope.wholeRange),
      );
      expect(played, <String>['2:255', '2:255', '2:255']);
    });
  });

  group('retour en arrière', () {
    test('recule d\'un verset puis s\'arrête au début', () {
      final cursor = _cursor(
        threeVerses,
        RepeatMode.once,
        RepeatScope.perVerse,
      );
      expect(cursor.current, '1:1');
      expect(cursor.advance(), isTrue);
      expect(cursor.current, '1:2');
      expect(cursor.advance(), isTrue);
      expect(cursor.current, '1:3');

      expect(cursor.retreat(), isTrue);
      expect(cursor.current, '1:2');
      expect(cursor.retreat(), isTrue);
      expect(cursor.current, '1:1');
      expect(cursor.retreat(), isFalse);
      expect(cursor.current, '1:1');
    });

    test('en répétition de verset, recule d\'abord dans les répétitions', () {
      final cursor = _cursor(
        threeVerses,
        RepeatMode.thrice,
        RepeatScope.perVerse,
      );
      expect(cursor.advance(), isTrue);
      expect(cursor.advance(), isTrue);
      expect(cursor.repeatOfCurrent, 3);
      expect(cursor.current, '1:1');

      expect(cursor.retreat(), isTrue);
      expect(cursor.repeatOfCurrent, 2);
      expect(cursor.current, '1:1');
    });

    test('en répétition de plage, recule vers la dernière passe', () {
      final cursor = _cursor(
        threeVerses,
        RepeatMode.twice,
        RepeatScope.wholeRange,
      );
      // Une passe complète.
      expect(cursor.advance(), isTrue);
      expect(cursor.advance(), isTrue);
      expect(cursor.advance(), isTrue); // début de la passe 2
      expect(cursor.rangePass, 2);
      expect(cursor.current, '1:1');

      expect(cursor.retreat(), isTrue);
      expect(cursor.rangePass, 1);
      expect(cursor.current, '1:3');
    });
  });

  group('position et libellés', () {
    test('jumpTo replace au verset demandé et remet les compteurs à zéro', () {
      final cursor = _cursor(
        threeVerses,
        RepeatMode.thrice,
        RepeatScope.perVerse,
      );
      cursor.advance();
      cursor.advance();
      expect(cursor.repeatOfCurrent, 3);

      expect(cursor.jumpTo('1:3'), isTrue);
      expect(cursor.current, '1:3');
      expect(cursor.repeatOfCurrent, 1);
      expect(cursor.rangePass, 1);
    });

    test('jumpTo refuse un verset absent de la file', () {
      final cursor = _cursor(
        threeVerses,
        RepeatMode.once,
        RepeatScope.perVerse,
      );
      expect(cursor.jumpTo('2:255'), isFalse);
      expect(cursor.current, '1:1');
    });

    test('progressLabel décrit l\'avancement en répétition de verset', () {
      final cursor = _cursor(
        threeVerses,
        RepeatMode.five,
        RepeatScope.perVerse,
      );
      expect(cursor.progressLabel, 'verset 1/3 \u00b7 1/5');
      cursor.advance();
      expect(cursor.progressLabel, 'verset 1/3 \u00b7 2/5');
    });

    test('progressLabel décrit l\'avancement en répétition de plage', () {
      final cursor = _cursor(
        threeVerses,
        RepeatMode.twice,
        RepeatScope.wholeRange,
      );
      expect(cursor.progressLabel, 'plage 1/2 \u00b7 verset 1/3');
    });

    test('hasNext est faux sur le dernier verset d\'une politique finie', () {
      final cursor = _cursor(
        <String>['1:1'],
        RepeatMode.once,
        RepeatScope.perVerse,
      );
      expect(cursor.hasNext, isFalse);
    });
  });

  group('garde-fous', () {
    test('une file vide est refusée', () {
      expect(
        () => PlaybackCursor(
          verses: const <String>[],
          policy: const RepeatPolicy(),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('les libellés de RepeatMode sont ceux attendus par l\'interface', () {
      expect(RepeatMode.once.label, '1x');
      expect(RepeatMode.twice.label, '2x');
      expect(RepeatMode.thrice.label, '3x');
      expect(RepeatMode.five.label, '5x');
      expect(RepeatMode.infinite.label, '\u221e');
      expect(RepeatMode.fromLabel('3x'), RepeatMode.thrice);
      expect(RepeatMode.fromLabel('7x'), isNull);
    });

    test('isActive est faux seulement pour 1x', () {
      expect(const RepeatPolicy().isActive, isFalse);
      expect(const RepeatPolicy(mode: RepeatMode.twice).isActive, isTrue);
    });
  });
}
