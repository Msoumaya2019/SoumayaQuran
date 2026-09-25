import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soumaya/data/quran_api_service.dart';

import 'support/mushaf_fixtures.dart';

/// Le délai de conservation du cache n'est pas un réglage de confort : les
/// Developer Terms de la Quran Foundation interdisent de conserver le contenu
/// plus d'une semaine hors Content Sync. Ces tests tiennent cette limite.
///
/// Ils l'éprouvent par la **date**, pas par une constante recopiée : si le
/// contrôle disparaissait, les cas « périmé » redeviendraient verts pour la
/// mauvaise raison et le témoin « frais » resterait vert — d'où la présence des
/// deux, qui ne peuvent pas passer ensemble sans le contrôle.
Future<Directory> _dossier() =>
    Directory.systemTemp.createTemp('soumaya-cache-');

/// Le fichier de cache, trouvé par énumération plutôt que par son nom : un
/// renommage interne ne doit pas faire échouer ces tests pour une raison qui
/// n'a rien à voir avec le délai.
Future<File> _fichier(Directory dossier) async =>
    dossier.listSync().whereType<File>().single;

Future<void> _redater(Directory dossier, DateTime date) async {
  final fichier = await _fichier(dossier);
  final decoded =
      jsonDecode(await fichier.readAsString()) as Map<String, dynamic>;
  decoded['saved_at'] = date.toUtc().toIso8601String();
  await fichier.writeAsString(jsonEncode(decoded));
}

Future<void> _ecrire(MushafCache cache) => cache.write(
  snapshot: buildSnapshot(),
  verseCounts: const <int, int>{1: 7, 2: 5},
);

void main() {
  late Directory dossier;

  setUp(() async {
    dossier = await _dossier();
  });

  tearDown(() {
    if (dossier.existsSync()) dossier.deleteSync(recursive: true);
  });

  test('un cache frais se relit', () async {
    // Le témoin. Sans lui, un contrôle qui refuserait TOUT cache passerait
    // pour concluant, et l'application retéléchargerait à chaque démarrage.
    final cache = MushafCache(directory: dossier);
    await _ecrire(cache);

    expect(await cache.readSnapshot(), isNotNull);
    expect(await cache.read(), isNotNull);
  });

  test('un cache de plus d\'une semaine est traité comme absent', () async {
    final cache = MushafCache(directory: dossier);
    await _ecrire(cache);
    await _redater(dossier, DateTime.now().subtract(const Duration(days: 8)));

    expect(await cache.readSnapshot(), isNull);
    expect(
      await cache.read(),
      isNull,
      reason: 'les deux chemins de lecture doivent appliquer le délai',
    );
  });

  test('un cache de moins d\'une semaine reste valable', () async {
    // La borne. La règle dit « more than 1 week » : six jours doivent passer.
    final cache = MushafCache(directory: dossier);
    await _ecrire(cache);
    await _redater(dossier, DateTime.now().subtract(const Duration(days: 6)));

    expect(await cache.readSnapshot(), isNotNull);
  });

  test('sans date enregistrée, la date du fichier fait foi', () async {
    // Un cache écrit par une version antérieure n'a pas de `saved_at` : mieux
    // vaut retélécharger que conserver au-delà du délai autorisé.
    final cache = MushafCache(directory: dossier);
    await _ecrire(cache);

    final fichier = await _fichier(dossier);
    final decoded =
        jsonDecode(await fichier.readAsString()) as Map<String, dynamic>;
    decoded.remove('saved_at');
    await fichier.writeAsString(jsonEncode(decoded));
    await fichier.setLastModified(
      DateTime.now().subtract(const Duration(days: 8)),
    );

    expect(await cache.readSnapshot(), isNull);
  });

  test('le délai est celui de l\'instance, pas une constante en dur', () async {
    // Preuve que le contrôle lit bien `maxAge` : avec un délai plus long, la
    // même entrée redevient valable.
    final cache = MushafCache(
      directory: dossier,
      maxAge: const Duration(days: 30),
    );
    await _ecrire(cache);
    await _redater(dossier, DateTime.now().subtract(const Duration(days: 8)));

    expect(await cache.readSnapshot(), isNotNull);
  });
}
