import 'package:meta/meta.dart';

/// Une récitation *verset par verset* telle que renvoyée par
/// `GET /resources/recitations`.
@immutable
class Recitation {
  const Recitation({
    required this.id,
    required this.reciterName,
    this.style,
    this.translatedName,
  });

  /// Identifiant à utiliser dans `/recitations/{id}/by_page/{n}`.
  ///
  /// ⚠️ Ces identifiants ne sont **pas** interchangeables avec ceux de
  /// `/resources/chapter_reciters`, qui désignent des récitations par sourate.
  final int id;

  final String reciterName;

  /// `Murattal`, `Mujawwad`, `Muallim`… ou `null`.
  final String? style;

  final String? translatedName;

  factory Recitation.fromJson(Map<String, dynamic> json) {
    final translated = json['translated_name'];
    return Recitation(
      id: (json['id'] as num).toInt(),
      reciterName: json['reciter_name'] as String? ?? '',
      style: json['style'] as String?,
      translatedName: translated is Map<String, dynamic>
          ? translated['name'] as String?
          : null,
    );
  }

  /// Libellé affiché dans le sélecteur de récitateur.
  ///
  /// Le style est indispensable : Minshawi apparaît deux fois dans le
  /// catalogue (Murattal et Mujawwad), avec deux identifiants distincts.
  String get displayName {
    final s = style;
    if (s == null || s.isEmpty) return reciterName;
    return '$reciterName ($s)';
  }

  @override
  String toString() => 'Recitation($id, $reciterName, ${style ?? "-"})';
}
