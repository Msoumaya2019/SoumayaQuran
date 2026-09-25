import 'package:flutter_test/flutter_test.dart';
import 'package:soumaya/data/models/recitation.dart';
import 'package:soumaya/data/reciter_catalog.dart';

/// Catalogue réduit, reprenant les entrées réellement documentées par la
/// Content API : identifiant 7 pour Al-Afasy, 8 et 9 pour Minshawi selon le
/// style. Yasser Al-Dossari en est volontairement absent — c'est le cas réel.
List<Recitation> _catalogue() => const <Recitation>[
  Recitation(id: 1, reciterName: 'AbdulBaset AbdulSamad', style: 'Mujawwad'),
  Recitation(id: 2, reciterName: 'AbdulBaset AbdulSamad', style: 'Murattal'),
  Recitation(id: 3, reciterName: 'Abdur-Rahman as-Sudais'),
  Recitation(id: 7, reciterName: 'Mishari Rashid al-`Afasy', style: 'Murattal'),
  Recitation(
    id: 8,
    reciterName: 'Mohamed Siddiq al-Minshawi',
    style: 'Mujawwad',
  ),
  Recitation(
    id: 9,
    reciterName: 'Mohamed Siddiq al-Minshawi',
    style: 'Murattal',
  ),
  Recitation(id: 10, reciterName: 'Sa`ud ash-Shuraym'),
];

ReciterResolution _resolve(String displayName) => ReciterCatalog.resolve(
  available: _catalogue(),
  preference: ReciterPreference(displayName: displayName),
);

void main() {
  group('résolution des récitateurs', () {
    test('Al-Afasy est résolu malgré l\'orthographe différente', () {
      // « Mishary » demandé, « Mishari » renvoyé par l'API.
      final resolution = _resolve('Mishary Rashid Al-Afasy');
      expect(resolution.isResolved, isTrue);
      expect(resolution.recitation!.id, 7);
      expect(
        resolution.score,
        greaterThanOrEqualTo(ReciterCatalog.minimumScore),
      );
    });

    test('Minshawi est résolu et le style Murattal est préféré', () {
      final resolution = _resolve('Mohamed Siddiq Al-Minshawi');
      expect(resolution.isResolved, isTrue);
      // 8 = Mujawwad, 9 = Murattal : les deux portent le même nom.
      expect(resolution.recitation!.id, 9);
      expect(resolution.recitation!.style, 'Murattal');
    });

    test('Yasser Al-Dossari est signalé comme introuvable', () {
      final resolution = _resolve('Yasser Al-Dossari');
      expect(resolution.isResolved, isFalse);
      expect(resolution.recitation, isNull);
      expect(resolution.score, lessThan(ReciterCatalog.minimumScore));
    });

    test('un nom sans rapport ne correspond à personne', () {
      final resolution = _resolve('Récitateur Imaginaire');
      expect(resolution.isResolved, isFalse);
      expect(resolution.score, lessThan(ReciterCatalog.minimumScore));
    });

    test('resolveAll conserve l\'ordre demandé, y compris les absents', () {
      final resolutions = ReciterCatalog.resolveAll(available: _catalogue());
      expect(resolutions.length, 3);
      expect(resolutions[0].preference.displayName, 'Mishary Rashid Al-Afasy');
      expect(resolutions[0].isResolved, isTrue);
      expect(resolutions[1].isResolved, isTrue);
      expect(resolutions[2].isResolved, isFalse);
    });

    test('resolveAll sur un catalogue vide ne résout rien', () {
      final resolutions = ReciterCatalog.resolveAll(
        available: const <Recitation>[],
      );
      expect(resolutions.every((r) => !r.isResolved), isTrue);
    });
  });

  group('scoreCandidate', () {
    test('donne 1 pour une correspondance exacte', () {
      final score = ReciterCatalog.scoreCandidate(
        wanted: const <String>['Mishari Rashid al-Afasy'],
        candidate: const Recitation(
          id: 7,
          reciterName: 'Mishari Rashid al-`Afasy',
        ),
      );
      expect(score, 1.0);
    });

    test('tolère une lettre d\'écart sur un mot long', () {
      final score = ReciterCatalog.scoreCandidate(
        wanted: const <String>['Mishary Rashid Al-Afasy'],
        candidate: const Recitation(
          id: 7,
          reciterName: 'Mishari Rashid al-Afasy',
        ),
      );
      expect(score, 1.0);
    });

    test('ne confond pas deux récitateurs différents', () {
      final score = ReciterCatalog.scoreCandidate(
        wanted: const <String>['Mohamed Siddiq Al-Minshawi'],
        candidate: const Recitation(
          id: 3,
          reciterName: 'Abdur-Rahman as-Sudais',
        ),
      );
      expect(score, lessThan(ReciterCatalog.minimumScore));
    });
  });
}
