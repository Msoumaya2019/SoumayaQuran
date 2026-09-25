import 'package:meta/meta.dart';

/// Un fichier audio de récitation pour un verset donné.
///
/// Correspond à un élément du tableau `audio_files` renvoyé par
/// `GET /recitations/{recitation_id}/by_page/{page_number}`.
@immutable
class AudioFile {
  const AudioFile({
    required this.verseKey,
    required this.url,
    this.duration,
    this.format,
  });

  /// Clé de verset, au format `sourate:verset` — par exemple `1:1`, `2:255`.
  final String verseKey;

  /// URL absolue et exploitable directement par le lecteur.
  final String url;

  /// Durée en secondes, si demandée via `fields`.
  final int? duration;

  /// `mp3`, `opus`… si demandé via `fields`.
  final String? format;

  /// Hôte du CDN audio officiel, utilisé pour absolutiser les URL relatives.
  static const String cdnHost = 'https://verses.quran.foundation';

  factory AudioFile.fromJson(Map<String, dynamic> json) {
    return AudioFile(
      verseKey: json['verse_key'] as String? ?? '',
      url: absoluteUrl(json['url'] as String? ?? ''),
      duration: (json['duration'] as num?)?.toInt(),
      format: json['format'] as String?,
    );
  }

  /// L'API renvoie selon les cas une URL absolue
  /// (`https://verses.quran.foundation/AbdulBaset/Mujawwad/mp3/001001.mp3`)
  /// ou un simple chemin relatif (`AbdulBaset/Mujawwad/mp3/001001.mp3`).
  /// Les deux formes circulent dans la documentation officielle : on normalise.
  static String absoluteUrl(String raw) {
    if (raw.isEmpty) return raw;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    final path = raw.startsWith('/') ? raw.substring(1) : raw;
    return '$cdnHost/$path';
  }

  /// Numéro de sourate extrait de [verseKey], ou `null` si mal formé.
  int? get chapterNumber {
    final parts = verseKey.split(':');
    if (parts.length != 2) return null;
    return int.tryParse(parts[0]);
  }

  /// Numéro de verset extrait de [verseKey], ou `null` si mal formé.
  int? get verseNumber {
    final parts = verseKey.split(':');
    if (parts.length != 2) return null;
    return int.tryParse(parts[1]);
  }

  @override
  String toString() => 'AudioFile($verseKey -> $url)';
}
