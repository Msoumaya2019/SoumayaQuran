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
  group('crédits', () {
    setUp(LicenseRegistry.reset);

    test('la mention exigée pour les polices est enregistrée', () async {
      enregistrerCredits();

      final texte = (await _lignesDeCredits()).join('\n');

      // La formule est imposée par les conditions d'usage : on la compare au
      // mot, pour qu'une reformulation bien intentionnée ne passe pas.
      expect(texte, contains(AppConfig.fontCredit));
      expect(texte, contains('Quran fonts provided by Quran Foundation.'));
    });

    test(
      'la mention exigée pour le contenu est enregistrée, elle aussi',
      () async {
        enregistrerCredits();

        final texte = (await _lignesDeCredits()).join('\n');

        // Deux obligations distinctes, deux formules distinctes. N'en tenir
        // qu'une est le défaut le plus probable : les deux phrases commencent
        // par les mêmes mots.
        expect(texte, contains(AppConfig.contentCredit));
        expect(texte, contains('Quran data provided by Quran Foundation.'));
      },
    );

    test('les deux mentions ne se confondent pas', () {
      expect(AppConfig.fontCredit, isNot(AppConfig.contentCredit));
      expect(AppConfig.fontCredit, contains('fonts'));
      expect(AppConfig.contentCredit, contains('data'));
    });

    test(
      'les fichiers ne sont ni revendus, ni redistribués séparément',
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
      // Le témoin : si le registre contenait déjà les mentions, les tests
      // ci-dessus seraient verts même sans `enregistrerCredits()`, et ils ne
      // prouveraient rien.
      final texte = (await _lignesDeCredits()).join('\n');

      expect(texte, isNot(contains(AppConfig.fontCredit)));
      expect(texte, isNot(contains(AppConfig.contentCredit)));
    });
  });
}
