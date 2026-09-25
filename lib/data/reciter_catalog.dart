import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'models/recitation.dart';

/// Un récitateur souhaité par le produit, indépendamment des identifiants
/// numériques de l'API.
@immutable
class ReciterPreference {
  const ReciterPreference({
    required this.displayName,
    this.aliases = const <String>[],
    this.preferredStyle = 'Murattal',
  });

  final String displayName;

  /// Orthographes alternatives rencontrées dans les catalogues.
  final List<String> aliases;

  /// Style à privilégier quand le catalogue contient plusieurs entrées pour le
  /// même récitateur — Minshawi y figure deux fois, en Murattal et en Mujawwad.
  final String preferredStyle;
}

/// Résultat de la résolution d'un récitateur dans le catalogue de l'API.
@immutable
class ReciterResolution {
  const ReciterResolution({
    required this.preference,
    required this.recitation,
    required this.score,
  });

  final ReciterPreference preference;

  /// `null` si aucun récitateur du catalogue ne correspond.
  final Recitation? recitation;

  final double score;

  bool get isResolved => recitation != null;

  @override
  String toString() => isResolved
      ? '${preference.displayName} -> ${recitation!.id} (${recitation!.style ?? "-"})'
      : '${preference.displayName} -> introuvable';
}

/// Résout les récitateurs demandés à partir du catalogue renvoyé par l'API.
///
/// Les identifiants numériques ne sont **pas** écrits en dur. La raison est
/// concrète : le catalogue officiel documenté ne contient pas d'entrée pour
/// Yasser Al-Dossari. Coder un identifiant deviné produirait un lecteur qui
/// échoue silencieusement ou lit le mauvais récitateur ; on résout donc par le
/// nom, et on signale explicitement les absences.
class ReciterCatalog {
  const ReciterCatalog._();

  /// Les trois récitateurs demandés, dans l'ordre d'affichage.
  static const List<ReciterPreference> defaults = <ReciterPreference>[
    ReciterPreference(
      displayName: 'Mishary Rashid Al-Afasy',
      aliases: <String>['Mishari Rashid al-Afasy', 'Mishary Alafasy'],
    ),
    ReciterPreference(
      displayName: 'Mohamed Siddiq Al-Minshawi',
      aliases: <String>['Mohamed Siddiq al-Minshawi', 'Minshawi'],
    ),
    ReciterPreference(
      displayName: 'Yasser Al-Dossari',
      aliases: <String>['Yasser Al-Dosari', 'Yasser Al Dosary'],
    ),
  ];

  /// Seuil au-dessous duquel une correspondance est jugée trop faible.
  static const double minimumScore = 0.7;

  /// Résout chaque préférence dans [available].
  ///
  /// La liste renvoyée suit l'ordre de [preferences], y compris pour les
  /// récitateurs introuvables — l'appelant peut ainsi les afficher comme
  /// indisponibles au lieu de les faire disparaître sans explication.
  static List<ReciterResolution> resolveAll({
    required List<Recitation> available,
    List<ReciterPreference> preferences = defaults,
  }) {
    return preferences
        .map(
          (preference) => resolve(available: available, preference: preference),
        )
        .toList(growable: false);
  }

  /// Résout une préférence unique.
  static ReciterResolution resolve({
    required List<Recitation> available,
    required ReciterPreference preference,
  }) {
    Recitation? best;
    var bestScore = 0.0;

    for (final candidate in available) {
      final score = scoreCandidate(
        wanted: <String>[preference.displayName, ...preference.aliases],
        candidate: candidate,
      );
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      } else if (score == bestScore &&
          best != null &&
          _styleBonus(candidate, preference) > _styleBonus(best, preference)) {
        // À score égal, on privilégie le style demandé (Murattal par défaut).
        best = candidate;
      }
    }

    if (best == null || bestScore < minimumScore) {
      return ReciterResolution(
        preference: preference,
        recitation: null,
        score: bestScore,
      );
    }

    return ReciterResolution(
      preference: preference,
      recitation: best,
      score: bestScore,
    );
  }

  /// Meilleur score obtenu par [candidate] face à l'ensemble des orthographes
  /// de [wanted].
  @visibleForTesting
  static double scoreCandidate({
    required List<String> wanted,
    required Recitation candidate,
  }) {
    final candidateTokens = _tokens(candidate.reciterName);
    if (candidateTokens.isEmpty) return 0;

    var best = 0.0;
    for (final name in wanted) {
      final score = _tokenScore(_tokens(name), candidateTokens);
      best = math.max(best, score);
    }
    return best;
  }

  static int _styleBonus(Recitation recitation, ReciterPreference preference) {
    final style = recitation.style;
    if (style == null) return 0;
    return style.toLowerCase() == preference.preferredStyle.toLowerCase()
        ? 1
        : 0;
  }

  /// Proportion des mots attendus retrouvés dans le candidat.
  static double _tokenScore(List<String> wanted, List<String> candidate) {
    if (wanted.isEmpty) return 0;
    var matched = 0;
    for (final token in wanted) {
      if (candidate.any((other) => _isClose(token, other))) matched++;
    }
    return matched / wanted.length;
  }

  /// Deux mots sont « proches » s'ils diffèrent d'au plus une ou deux lettres,
  /// selon leur longueur. C'est ce qui rapproche `mishary` de `mishari` et
  /// `dossari` de `dosari`, sans confondre deux récitateurs distincts.
  static bool _isClose(String a, String b) {
    if (a == b) return true;
    final longest = math.max(a.length, b.length);
    if (longest < 5) return false;
    final tolerance = longest >= 8 ? 2 : 1;
    if ((a.length - b.length).abs() > tolerance) return false;
    return _levenshtein(a, b, tolerance) <= tolerance;
  }

  /// Distance d'édition, abandonnée dès qu'elle dépasse [limit].
  static int _levenshtein(String a, String b, int limit) {
    if ((a.length - b.length).abs() > limit) return limit + 1;

    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);

    for (var i = 1; i <= a.length; i++) {
      current[0] = i;
      var rowMinimum = current[0];
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        current[j] = math.min(
          math.min(current[j - 1] + 1, previous[j] + 1),
          previous[j - 1] + cost,
        );
        rowMinimum = math.min(rowMinimum, current[j]);
      }
      if (rowMinimum > limit) return limit + 1;
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[b.length];
  }

  /// Découpe un nom en mots normalisés : minuscules, sans ponctuation ni
  /// diacritique.
  static List<String> _tokens(String name) {
    final normalised = _stripDiacritics(
      name.toLowerCase(),
    ).replaceAll(RegExp(r'[^a-z]+'), ' ').trim();
    if (normalised.isEmpty) return const <String>[];
    return normalised
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
  }

  /// Retire les signes diacritiques latins (par exemple `` dans `al-`Afasy`).
  static String _stripDiacritics(String input) {
    const replacements = <String, String>{
      'à': 'a',
      'á': 'a',
      'â': 'a',
      'ã': 'a',
      'ä': 'a',
      'å': 'a',
      'è': 'e',
      'é': 'e',
      'ê': 'e',
      'ë': 'e',
      'ì': 'i',
      'í': 'i',
      'î': 'i',
      'ï': 'i',
      'ò': 'o',
      'ó': 'o',
      'ô': 'o',
      'õ': 'o',
      'ö': 'o',
      'ù': 'u',
      'ú': 'u',
      'û': 'u',
      'ü': 'u',
      'ç': 'c',
      'ñ': 'n',
      '’': ' ',
      "'": ' ',
    };
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(replacements[char] ?? char);
    }
    return buffer.toString();
  }
}
