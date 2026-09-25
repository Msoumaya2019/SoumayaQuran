import 'package:meta/meta.dart';

/// Multiplicateur de répétition proposé dans la capsule audio.
enum RepeatMode {
  once,
  twice,
  thrice,
  five,
  infinite;

  /// Nombre de passes, ou `null` pour une répétition sans fin.
  int? get passes => switch (this) {
    RepeatMode.once => 1,
    RepeatMode.twice => 2,
    RepeatMode.thrice => 3,
    RepeatMode.five => 5,
    RepeatMode.infinite => null,
  };

  /// Libellé affiché sur le bouton.
  String get label => switch (this) {
    RepeatMode.once => '1x',
    RepeatMode.twice => '2x',
    RepeatMode.thrice => '3x',
    RepeatMode.five => '5x',
    RepeatMode.infinite => '\u221e',
  };

  static RepeatMode? fromLabel(String label) {
    for (final mode in RepeatMode.values) {
      if (mode.label == label) return mode;
    }
    return null;
  }
}

/// Ce que le multiplicateur répète réellement.
///
/// Les deux lectures sont légitimes en mémorisation, et elles ne donnent pas le
/// même résultat : répéter trois fois chaque verset n'est pas la même chose que
/// rejouer trois fois la plage entière.
enum RepeatScope {
  /// Chaque verset est répété avant de passer au suivant.
  perVerse,

  /// La plage est rejouée depuis son début.
  wholeRange,
}

extension RepeatScopeX on RepeatScope {
  String get label => switch (this) {
    RepeatScope.perVerse => 'Verset',
    RepeatScope.wholeRange => 'Plage',
  };
}

/// Politique de répétition complète : multiplicateur et portée.
@immutable
class RepeatPolicy {
  const RepeatPolicy({
    this.mode = RepeatMode.once,
    this.scope = RepeatScope.perVerse,
  });

  final RepeatMode mode;
  final RepeatScope scope;

  bool get isInfinite => mode.passes == null;

  /// Vrai si la répétition est active — sert à mettre le bouton en évidence.
  bool get isActive => mode != RepeatMode.once;

  RepeatPolicy copyWith({RepeatMode? mode, RepeatScope? scope}) =>
      RepeatPolicy(mode: mode ?? this.mode, scope: scope ?? this.scope);

  @override
  bool operator ==(Object other) =>
      other is RepeatPolicy && other.mode == mode && other.scope == scope;

  @override
  int get hashCode => Object.hash(mode, scope);

  @override
  String toString() => '${mode.label} ${scope.label}';
}

/// Curseur de lecture : où l'on en est dans la file, et combien de fois le
/// verset courant a déjà été joué.
///
/// Classe volontairement dépourvue de toute dépendance audio : la logique de
/// répétition se teste alors sans appareil, sans plugin et sans attente.
class PlaybackCursor {
  PlaybackCursor({required List<String> verses, required this.policy})
    : verses = List<String>.unmodifiable(verses) {
    if (verses.isEmpty) {
      throw ArgumentError.value(
        verses,
        'verses',
        'La file de lecture ne peut pas être vide.',
      );
    }
  }

  /// Clés de verset de la file, dans l'ordre du Mushaf.
  final List<String> verses;

  /// Politique de répétition courante. La modifier ne perd pas la position.
  RepeatPolicy policy;

  int _verseIndex = 0;

  /// Nombre de fois que le verset courant a été joué, en comptant la lecture en
  /// cours. Vaut 1 dès la première écoute.
  int _repeatOfCurrent = 1;

  /// Nombre de passes complètes effectuées sur la plage.
  int _rangePass = 1;

  String get current => verses[_verseIndex];

  int get verseIndex => _verseIndex;
  int get repeatOfCurrent => _repeatOfCurrent;
  int get rangePass => _rangePass;

  /// Vrai s'il reste une étape après celle en cours.
  bool get hasNext {
    final passes = policy.mode.passes;
    if (policy.scope == RepeatScope.perVerse) {
      if (passes == null) return true; // boucle sans fin sur le verset
      if (_repeatOfCurrent < passes) return true;
      return _verseIndex + 1 < verses.length;
    }
    if (_verseIndex + 1 < verses.length) return true;
    return passes == null || _rangePass < passes;
  }

  /// Vrai s'il existe une étape avant celle en cours.
  bool get hasPrevious {
    if (policy.scope == RepeatScope.perVerse) {
      return _repeatOfCurrent > 1 || _verseIndex > 0;
    }
    return _verseIndex > 0 || _rangePass > 1;
  }

  /// Avance d'une étape. Renvoie `false` si la lecture est terminée.
  bool advance() {
    final passes = policy.mode.passes;

    if (policy.scope == RepeatScope.perVerse) {
      if (passes == null) {
        // Répétition sans fin : le verset courant ne cède jamais la place.
        _repeatOfCurrent++;
        return true;
      }
      if (_repeatOfCurrent < passes) {
        _repeatOfCurrent++;
        return true;
      }
      if (_verseIndex + 1 >= verses.length) return false;
      _verseIndex++;
      _repeatOfCurrent = 1;
      return true;
    }

    // Répétition de la plage entière.
    if (_verseIndex + 1 < verses.length) {
      _verseIndex++;
      return true;
    }
    if (passes == null || _rangePass < passes) {
      _verseIndex = 0;
      _rangePass++;
      _repeatOfCurrent = 1;
      return true;
    }
    return false;
  }

  /// Recule d'une étape. Renvoie `false` si l'on est déjà au tout début.
  bool retreat() {
    final passes = policy.mode.passes;

    if (policy.scope == RepeatScope.perVerse) {
      if (_repeatOfCurrent > 1) {
        _repeatOfCurrent--;
        return true;
      }
      if (_verseIndex == 0) return false;
      _verseIndex--;
      _repeatOfCurrent = passes ?? 1;
      return true;
    }

    if (_verseIndex > 0) {
      _verseIndex--;
      return true;
    }
    if (_rangePass > 1) {
      _rangePass--;
      _verseIndex = verses.length - 1;
      return true;
    }
    return false;
  }

  /// Positionne la lecture sur [verseKey] et remet les compteurs à zéro.
  ///
  /// Renvoie `false` si le verset n'appartient pas à la file.
  bool jumpTo(String verseKey) {
    final index = verses.indexOf(verseKey);
    if (index < 0) return false;
    _verseIndex = index;
    _repeatOfCurrent = 1;
    _rangePass = 1;
    return true;
  }

  /// Réinitialise au premier verset, première passe.
  void reset() {
    _verseIndex = 0;
    _repeatOfCurrent = 1;
    _rangePass = 1;
  }

  /// Description courte de l'avancement, pour la capsule audio — par exemple
  /// `2/5` en répétition de verset, `plage 1/3` en répétition de plage.
  String get progressLabel {
    final passes = policy.mode.passes;
    if (passes == null) return '${verses.length} versets \u00b7 boucle';

    if (policy.scope == RepeatScope.perVerse) {
      return 'verset ${_verseIndex + 1}/${verses.length} \u00b7 $_repeatOfCurrent/$passes';
    }
    return 'plage $_rangePass/$passes \u00b7 verset ${_verseIndex + 1}/${verses.length}';
  }

  @override
  String toString() =>
      'PlaybackCursor($current, $policy, verset ${_verseIndex + 1}/${verses.length})';
}
