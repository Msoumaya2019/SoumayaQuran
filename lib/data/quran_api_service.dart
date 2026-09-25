import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import 'models/audio_file.dart';
import 'models/mushaf_index.dart';
import 'models/mushaf_layout.dart';
import 'models/recitation.dart';
import 'models/verse_key.dart';
import 'qf_token_provider.dart';
import 'quran_api_exception.dart';

/// Client de la **Quran Foundation Content API v4**.
///
/// Toutes les requêtes portent deux en-têtes : `x-auth-token` (jeton OAuth2 de
/// courte durée, obtenu par [QfTokenSource]) et `x-client-id` (identifiant
/// public de l'application).
class QuranApiService {
  QuranApiService({
    required this.tokenSource,
    http.Client? client,
    String? baseUrl,
    String? clientId,
    MushafCache? cache,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl ?? AppConfig.contentApiBaseUrl,
       _clientId = clientId ?? AppConfig.clientId,
       _cache = cache ?? MushafCache();

  final QfTokenSource tokenSource;
  final http.Client _client;
  final String _baseUrl;

  /// Identifiant public envoyé dans `x-client-id`.
  ///
  /// Il vient des réglages d'exécution quand l'utilisateur les a renseignés,
  /// sinon de la constante compilée. Le `client_secret`, lui, n'entre jamais
  /// ici : il reste sur le proxy.
  final String _clientId;

  final MushafCache _cache;

  /// Champs demandés pour les fichiers audio : sans `fields`, l'API ne renvoie
  /// que `verse_key` et `url`.
  static const String _audioFields = 'verse_key,url,duration,format';

  // ---------------------------------------------------------------------------
  // Récitateurs
  // ---------------------------------------------------------------------------

  /// Catalogue des récitations **verset par verset** — `GET /resources/recitations`.
  ///
  /// ⚠️ Ces identifiants ne sont pas interchangeables avec ceux de
  /// `/resources/chapter_reciters`, qui désignent des récitations par sourate.
  Future<List<Recitation>> fetchRecitations({String language = 'en'}) async {
    final json = await _getJson(
      '/resources/recitations',
      query: <String, String>{'language': language},
    );
    final raw = json['recitations'] as List<dynamic>? ?? const <dynamic>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Recitation.fromJson)
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Audio
  // ---------------------------------------------------------------------------

  /// Fichiers audio d'une page du Mushaf —
  /// `GET /recitations/{recitation_id}/by_page/{page_number}`.
  ///
  /// [pageNumber] va de 1 à 604. `per_page` est fixé au maximum autorisé (50)
  /// et non laissé à sa valeur par défaut de 10 : une page du Mushaf peut
  /// porter davantage de versets, qui seraient alors silencieusement perdus.
  /// La pagination est parcourue jusqu'à épuisement par sécurité.
  Future<List<AudioFile>> fetchPageAudioFiles({
    required int recitationId,
    required int pageNumber,
  }) async {
    if (pageNumber < 1 || pageNumber > AppConfig.mushafPageCount) {
      throw QuranApiException(
        statusCode: 0,
        type: 'invalid_argument',
        message:
            'Numéro de page hors bornes (1..${AppConfig.mushafPageCount}) : '
            '$pageNumber',
      );
    }

    final collected = <AudioFile>[];
    var page = 1;
    // Garde-fou : 604 pages ne peuvent pas légitimement produire des milliers
    // de fichiers pour une seule page.
    const int maxFiles = 400;

    while (true) {
      final json = await _getJson(
        '/recitations/$recitationId/by_page/$pageNumber',
        query: <String, String>{
          'fields': _audioFields,
          'per_page': '${AppConfig.audioFilesPerPage}',
          'page': '$page',
        },
      );

      final raw = json['audio_files'] as List<dynamic>? ?? const <dynamic>[];
      collected.addAll(
        raw.whereType<Map<String, dynamic>>().map(AudioFile.fromJson),
      );

      final pagination = json['pagination'];
      final nextPage = pagination is Map<String, dynamic>
          ? (pagination['next_page'] as num?)?.toInt()
          : null;

      if (nextPage == null ||
          nextPage <= page ||
          collected.length >= maxFiles) {
        break;
      }
      page = nextPage;
    }

    return _normalise(collected);
  }

  /// Fichier audio d'un verset précis — `GET /quran/recitations/{id}` avec
  /// `verse_key`.
  Future<AudioFile?> fetchVerseAudioFile({
    required int recitationId,
    required String verseKey,
  }) async {
    final json = await _getJson(
      '/quran/recitations/$recitationId',
      query: <String, String>{'verse_key': verseKey, 'fields': _audioFields},
    );
    final raw = json['audio_files'] as List<dynamic>? ?? const <dynamic>[];
    final files = raw
        .whereType<Map<String, dynamic>>()
        .map(AudioFile.fromJson)
        .where((file) => file.verseKey == verseKey)
        .toList(growable: false);
    return files.isEmpty ? null : files.first;
  }

  /// Fichiers audio couvrant une plage de versets `from`..`to` (bornes incluses).
  ///
  /// Ne télécharge que les pages réellement concernées, grâce à [index] : une
  /// plage de trois versets ne coûte qu'un appel, pas trois.
  Future<List<AudioFile>> fetchVerseRangeAudioFiles({
    required int recitationId,
    required String fromVerseKey,
    required String toVerseKey,
    required MushafIndex index,
  }) async {
    final from = VerseKey.tryParse(fromVerseKey);
    final to = VerseKey.tryParse(toVerseKey);
    if (from == null || to == null) {
      throw QuranApiException(
        statusCode: 0,
        type: 'invalid_argument',
        message: 'Plage de versets illisible : "$fromVerseKey".."$toVerseKey"',
      );
    }
    if (to < from) {
      throw QuranApiException(
        statusCode: 0,
        type: 'invalid_argument',
        message: 'La fin de plage ($to) précède son début ($from).',
      );
    }

    final pages = index.pagesForRange('$from', '$to');
    if (pages.isEmpty) {
      return const <AudioFile>[];
    }

    final collected = <AudioFile>[];
    for (final page in pages) {
      collected.addAll(
        await fetchPageAudioFiles(recitationId: recitationId, pageNumber: page),
      );
    }

    // On filtre sur la plage demandée : une page peut contenir des versets
    // situés hors de la sélection.
    return _normalise(
      collected
          .where((file) {
            final key = VerseKey.tryParse(file.verseKey);
            return key != null && key >= from && key <= to;
          })
          .toList(growable: false),
    );
  }

  /// Trie par ordre du Mushaf et supprime les doublons de `verse_key`.
  List<AudioFile> _normalise(List<AudioFile> files) {
    final byKey = <String, AudioFile>{};
    for (final file in files) {
      if (file.verseKey.isEmpty || file.url.isEmpty) continue;
      byKey.putIfAbsent(file.verseKey, () => file);
    }
    final result = byKey.values.toList()
      ..sort((a, b) {
        final keyA = VerseKey.tryParse(a.verseKey);
        final keyB = VerseKey.tryParse(b.verseKey);
        if (keyA == null || keyB == null) {
          return a.verseKey.compareTo(b.verseKey);
        }
        return keyA.compareTo(keyB);
      });
    return List<AudioFile>.unmodifiable(result);
  }

  // ---------------------------------------------------------------------------
  // Structure du Mushaf
  // ---------------------------------------------------------------------------

  /// Nombre de versets par sourate — `GET /chapters`.
  ///
  /// Sert à bâtir la table d'ordinaux, donc la localisation des versets.
  Future<Map<int, int>> fetchChapterVerseCounts() async {
    final json = await _getJson('/chapters');
    final raw = json['chapters'] as List<dynamic>? ?? const <dynamic>[];
    final counts = <int, int>{};
    for (final chapter in raw.whereType<Map<String, dynamic>>()) {
      final id = (chapter['id'] as num?)?.toInt();
      final verses = (chapter['verses_count'] as num?)?.toInt();
      if (id != null && verses != null) counts[id] = verses;
    }
    return counts;
  }

  /// Instantané complet du Mushaf —
  /// `GET /resources/snapshots/mushafs/{mushaf_id}`.
  ///
  /// Renvoie la mise en page mot à mot des 604 pages (métadonnées, pages,
  /// mots positionnés). Les fichiers de police n'y figurent pas.
  Future<MushafSnapshot> fetchMushafSnapshot({int? mushafId}) async {
    final id = mushafId ?? AppConfig.mushafId;
    final json = await _getJson('/resources/snapshots/mushafs/$id');
    return MushafSnapshot.fromSnapshotJson(json);
  }

  /// Index verset → page, depuis le cache disque si disponible.
  ///
  /// Le Mushaf imprimé ne change pas : la donnée est donc téléchargée une fois
  /// puis réutilisée indéfiniment. [forceRefresh] court-circuite le cache.
  Future<MushafIndex> loadMushafIndex({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await _cache.read();
      if (cached != null) return cached;
    }

    final results = await Future.wait<Object>(<Future<Object>>[
      fetchMushafSnapshot(),
      fetchChapterVerseCounts(),
    ]);

    final snapshot = results[0] as MushafSnapshot;
    final counts = results[1] as Map<int, int>;

    final index = MushafIndex.fromSnapshot(
      snapshot: snapshot,
      ordinals: VerseOrdinalTable(counts),
    );

    await _cache.write(snapshot: snapshot, verseCounts: counts);
    return index;
  }

  /// Instantané du Mushaf depuis le cache disque uniquement, sans réseau.
  Future<MushafSnapshot?> loadCachedMushafSnapshot() => _cache.readSnapshot();

  // ---------------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------------

  /// Exécute un `GET` authentifié, avec renouvellement de jeton et réessais.
  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? query,
    int maxAttempts = 3,
  }) async {
    var attempt = 0;
    var tokenAlreadyRenewed = false;

    while (true) {
      attempt++;

      final token = await tokenSource.accessToken();
      final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);

      final response = await _client.get(
        uri,
        headers: <String, String>{
          'x-auth-token': token,
          'x-client-id': _clientId,
          'accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map<String, dynamic>) {
          throw QuranApiException(
            statusCode: 200,
            type: 'malformed_response',
            message: 'Réponse inattendue pour $path (objet JSON attendu).',
          );
        }
        return decoded;
      }

      final error = _errorFrom(response, path);

      // Jeton expiré ou scope manquant : on le renouvelle une seule fois.
      if (error.isAuthenticationFailure && !tokenAlreadyRenewed) {
        tokenAlreadyRenewed = true;
        tokenSource.invalidate();
        continue;
      }

      if (error.isTransient && attempt < maxAttempts) {
        await Future<void>.delayed(error.retryAfter ?? _backoff(attempt));
        continue;
      }

      throw error;
    }
  }

  Duration _backoff(int attempt) =>
      Duration(milliseconds: 400 * (1 << (attempt - 1)));

  QuranApiException _errorFrom(http.Response response, String path) {
    var type = 'http_${response.statusCode}';
    var message = 'Échec de $path (${response.statusCode}).';

    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        type = decoded['type'] as String? ?? type;
        message = decoded['message'] as String? ?? message;
      }
    } on FormatException {
      // Corps non JSON : on conserve le message générique.
    }

    Duration? retryAfter;
    final header = response.headers['retry-after'];
    if (header != null) {
      final seconds = int.tryParse(header);
      if (seconds != null) retryAfter = Duration(seconds: seconds);
    }

    return QuranApiException(
      statusCode: response.statusCode,
      type: type,
      message: message,
      retryAfter: retryAfter,
    );
  }

  void dispose() {
    _client.close();
    tokenSource.dispose();
  }
}

/// Cache disque du Mushaf.
///
/// La mise en page du Mushaf imprimé est immuable : la télécharger une fois et
/// la conserver évite de rejouer une requête volumineuse à chaque lancement.
/// Le dossier est injectable pour permettre les tests sans `path_provider`.
class MushafCache {
  MushafCache({
    this.directory,
    this.schemaVersion = 1,
    this.maxAge = maxAgeParDefaut,
  });

  /// Dossier du cache. `null` = dossier de support de l'application.
  final Directory? directory;
  final int schemaVersion;

  /// Durée maximale de conservation d'un contenu mis en cache.
  ///
  /// Ce n'est pas un réglage de confort : c'est une **condition d'usage**.
  /// Les Developer Terms de la Quran Foundation posent que le contenu ne doit
  /// pas être conservé plus d'une semaine — « Do not cache or store QF Content
  /// for more than 1 week unless QF has expressly permitted longer storage, or
  /// the content is available through the Content Sync APIs. »
  ///
  /// L'application utilise l'instantané ordinaire du Mushaf, pas Content Sync :
  /// c'est donc le délai d'une semaine qui s'applique. Un cache plus vieux est
  /// traité comme absent, ce qui déclenche un retéléchargement — au pire une
  /// requête par semaine et par appareil.
  final Duration maxAge;

  static const Duration maxAgeParDefaut = Duration(days: 7);

  static const String _fileName = 'mushaf_layout.json';

  Future<File?> _resolveFile() async {
    var resolved = directory;
    if (resolved == null) {
      try {
        resolved = await getApplicationSupportDirectory();
      } on MissingPluginException {
        // Hors contexte Flutter (test unitaire) : pas de cache disque.
        return null;
      } on Object {
        return null;
      }
    }
    return File('${resolved.path}${Platform.pathSeparator}$_fileName');
  }

  /// Vrai si l'entrée datée de [savedAt] dépasse [maxAge].
  ///
  /// `saved_at` prime sur la date du fichier : celle-ci peut changer pour une
  /// raison étrangère au contenu — une copie, une restauration de sauvegarde —
  /// et une sauvegarde restaurée rajeunirait un contenu ancien. En l'absence
  /// du champ (cache écrit par une version antérieure), la date du fichier fait
  /// foi : mieux vaut retélécharger que conserver au-delà du délai autorisé.
  bool _estPerime(String? savedAt, DateTime modification) {
    final ecrit = savedAt == null ? null : DateTime.tryParse(savedAt);
    final reference = ecrit?.toUtc() ?? modification.toUtc();
    return DateTime.now().toUtc().difference(reference) > maxAge;
  }

  /// Renvoie l'index mis en cache, ou `null` si absent, illisible ou périmé.
  Future<MushafIndex?> read() async {
    final snapshot = await readSnapshot();
    if (snapshot == null) return null;

    final file = await _resolveFile();
    if (file == null) return null;

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      if ((decoded['schema_version'] as num?)?.toInt() != schemaVersion) {
        return null;
      }
      final rawCounts = decoded['verse_counts'];
      if (rawCounts is! Map<String, dynamic>) return null;

      final counts = <int, int>{};
      for (final entry in rawCounts.entries) {
        final chapter = int.tryParse(entry.key);
        final count = (entry.value as num?)?.toInt();
        if (chapter != null && count != null) counts[chapter] = count;
      }

      return MushafIndex.fromSnapshot(
        snapshot: snapshot,
        ordinals: VerseOrdinalTable(counts),
      );
    } on Object {
      // Cache corrompu : on le traite comme absent, il sera réécrit.
      return null;
    }
  }

  /// Lit uniquement l'instantané du Mushaf depuis le disque.
  ///
  /// C'est ici que le délai est appliqué : [read] passe par cette méthode, donc
  /// les deux chemins de lecture sont couverts par un seul contrôle.
  Future<MushafSnapshot?> readSnapshot() async {
    final file = await _resolveFile();
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      if ((decoded['schema_version'] as num?)?.toInt() != schemaVersion) {
        return null;
      }
      if (_estPerime(
        decoded['saved_at'] as String?,
        await file.lastModified(),
      )) {
        return null;
      }
      final rawSnapshot = decoded['snapshot'];
      if (rawSnapshot is! Map<String, dynamic>) return null;
      return MushafSnapshot.fromCacheJson(rawSnapshot);
    } on Object {
      return null;
    }
  }

  Future<void> write({
    required MushafSnapshot snapshot,
    required Map<int, int> verseCounts,
  }) async {
    final file = await _resolveFile();
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'schema_version': schemaVersion,
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'verse_counts': verseCounts.map(
            (chapter, count) => MapEntry('$chapter', count),
          ),
          'snapshot': snapshot.toCacheJson(),
        }),
      );
    } on FileSystemException {
      // Un cache non écrit n'est pas une erreur fatale : la donnée sera
      // simplement retéléchargée.
    }
  }

  Future<void> clear() async {
    final file = await _resolveFile();
    if (file != null && await file.exists()) {
      await file.delete();
    }
  }
}
