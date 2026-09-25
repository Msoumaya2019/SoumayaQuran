import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soumaya/config/app_config.dart';
import 'package:soumaya/config/credits.dart';

/// Rassemble le texte de tous les crédits enregistrés.
///
/// `LicenseRegistry.licenses` se ferme une fois tous les collecteurs épuisés :
/// `toList()` se termine donc. Le risque serait l'inverse — un collecteur qui ne
/// se ferme jamais — et il n'y en a pas ici.
Future<List<String>> _lignesDeCredits() async {
  final lignes = <String>[];
  await for (final entree in LicenseRegistry.licenses) {
    for (final paragraphe in entree.paragraphs) {
      lignes.add(paragraphe.text);
    }
  }
  return lignes;
}

void main() {
  group('crédit des polices', () {
    setUp(LicenseRegistry.reset);

    test('la mention exigée par la licence est enregistrée', () async {
      enregistrerCredits();

      final lignes = await _lignesDeCredits();
      final texte = lignes.join('\n');

      // La formule est imposée par les conditions d'usage : on la compare au
      // mot, pour qu'une reformulation bien intentionnée ne passe pas.
      expect(texte, contains(AppConfig.fontCredit));
      expect(texte, contains('Quran Foundation'));
    });

    test(
      'les polices sont présentées comme intégrées, jamais redistribuées',
      () async {
        enregistrerCredits();

        final texte = (await _lignesDeCredits()).join('\n');

        // Ces mots reprennent la limite posée par la licence : les fichiers ne
        // peuvent être proposés « separately », « as an asset package » ou en
        // « standalone download ». Le crédit doit dire la même chose que ce que
        // l'application fait.
        expect(texte, contains('partie intégrante'));
        expect(texte, contains('redistribuées séparément'));
      },
    );

    test('sans appel, rien n\'est enregistré', () async {
      // Le témoin : si le registre contenait déjà la mention, les deux tests
      // ci-dessus seraient verts même sans `enregistrerCredits()`, et ils ne
      // prouveraient rien.
      final texte = (await _lignesDeCredits()).join('\n');

      expect(texte, isNot(contains(AppConfig.fontCredit)));
    });
  });
}
