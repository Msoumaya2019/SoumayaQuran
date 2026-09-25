import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';

/// État de résolution de la police d'une page.
enum MushafFontStatus {
  /// Police chargée, la page peut être rendue fidèlement.
  ready,

  /// Aucune police disponible : la page ne peut pas être rendue en glyphes.
  missing,
}

/// Résultat de la résolution de la police d'une page.
@immutable
class MushafFontResult {
  const MushafFontResult({required this.status, this.family});

  final MushafFontStatus status;

  /// Nom de famille à passer à `TextStyle.fontFamily`, si disponible.
  final String? family;

  bool get isReady => status == MushafFontStatus.ready && family != null;
}

/// Fournit la police QCF de chaque page du Mushaf.
///
/// Les polices QCF sont des polices **glyph-based** : chaque mot du Coran y est
/// un glyphe unique, et l'ensemble est dessiné page par page. Il faut donc
/// 604 fichiers de police — un par page — et non une seule police couvrant
/// tout le texte. Les fichiers ne sont pas fournis par la Content API : le
/// groupe `mushafs` ne renvoie que le nom de famille attendu (`v2`).
///
/// Trois sources sont essayées, dans cet ordre :
///  1. un asset local `assets/mushaf/qcf2/pXXX.ttf` (hors ligne, immédiat) ;
///  2. un téléchargement depuis [AppConfig.qcfFontBaseUrl], mis en cache ;
///  3. rien — on renvoie alors un état `missing`, que l'interface doit
///     présenter clairement plutôt que d'afficher des carrés vides.
///
/// ⚠️ Les conditions de redistribution de ces polices doivent être vérifiées
/// auprès de leur éditeur avant de les embarquer dans une application publiée.
class MushafFontProvider {
  MushafFontProvider({
    http.Client? client,
    this.cacheDirectory,
    String? baseUrl,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl ?? AppConfig.qcfFontBaseUrl;

  final http.Client _client;

  /// Dossier de cache des polices téléchargées. `null` = dossier système.
  final Directory? cacheDirectory;

  final String _baseUrl;

  final Set<int> _loadedPages = <int>{};
  final Map<int, Future<MushafFontResult>> _inFlight =
      <int, Future<MushafFontResult>>{};
  final Set<int> _unavailablePages = <int>{};

  /// Nom de famille utilisé par Flutter pour la page [pageNumber].
  static String familyNameForPage(int pageNumber) =>
      'QCF2_P${pageNumber.toString().padLeft(3, '0')}';

  /// Chemin de l'asset local attendu pour la page [pageNumber].
  static String assetPathForPage(int pageNumber) =>
      'assets/mushaf/qcf2/p${pageNumber.toString().padLeft(3, '0')}.ttf';

  /// Résout la police de [pageNumber], en la chargeant si nécessaire.
  ///
  /// Les appels concurrents pour une même page partagent le même chargement.
  Future<MushafFontResult> resolve(int pageNumber) {
    if (_loadedPages.contains(pageNumber)) {
      return Future<MushafFontResult>.value(
        MushafFontResult(
          status: MushafFontStatus.ready,
          family: familyNameForPage(pageNumber),
        ),
      );
    }
    if (_unavailablePages.contains(pageNumber)) {
      return Future<MushafFontResult>.value(
        const MushafFontResult(status: MushafFontStatus.missing),
      );
    }

    final pending = _inFlight[pageNumber];
    if (pending != null) return pending;

    final future = _load(pageNumber).whenComplete(() {
      _inFlight.remove(pageNumber);
    });
    _inFlight[pageNumber] = future;
    return future;
  }

  Future<MushafFontResult> _load(int pageNumber) async {
    final family = familyNameForPage(pageNumber);
    final bytes = await _obtainBytes(pageNumber);

    if (bytes == null) {
      _unavailablePages.add(pageNumber);
      return const MushafFontResult(status: MushafFontStatus.missing);
    }

    try {
      final loader = FontLoader(family)..addFont(Future<ByteData>.value(bytes));
      await loader.load();
      _loadedPages.add(pageNumber);
      return MushafFontResult(status: MushafFontStatus.ready, family: family);
    } on Object catch (error) {
      debugPrint('[Soumaya/fonts] police p$pageNumber illisible : $error');
      _unavailablePages.add(pageNumber);
      return const MushafFontResult(status: MushafFontStatus.missing);
    }
  }

  /// Cherche les octets de la police : asset, puis cache disque, puis réseau.
  Future<ByteData?> _obtainBytes(int pageNumber) async {
    // 1. Asset embarqué.
    try {
      return await rootBundle.load(assetPathForPage(pageNumber));
    } on Object {
      // Absent du bundle : on continue.
    }

    final cacheFile = await _cacheFileFor(pageNumber);

    // 2. Cache disque.
    if (cacheFile != null && await cacheFile.exists()) {
      try {
        return _toByteData(await cacheFile.readAsBytes());
      } on FileSystemException {
        // Cache illisible : on retélécharge.
      }
    }

    // 3. Réseau.
    if (_baseUrl.isEmpty) return null;

    final uri = Uri.parse(
      AppConfig.qcfFontUrlTemplate
          .replaceFirst('{base}', _baseUrl)
          .replaceFirst('{page}', pageNumber.toString().padLeft(3, '0')),
    );

    try {
      final response = await _client.get(uri);
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        debugPrint(
          '[Soumaya/fonts] p$pageNumber : HTTP ${response.statusCode} sur $uri',
        );
        return null;
      }

      if (cacheFile != null) {
        try {
          await cacheFile.parent.create(recursive: true);
          await cacheFile.writeAsBytes(response.bodyBytes);
        } on FileSystemException {
          // Échec de cache non bloquant.
        }
      }

      return _toByteData(response.bodyBytes);
    } on Object catch (error) {
      debugPrint(
        '[Soumaya/fonts] p$pageNumber : téléchargement échoué ($error)',
      );
      return null;
    }
  }

  Future<File?> _cacheFileFor(int pageNumber) async {
    var directory = cacheDirectory;
    if (directory == null) {
      try {
        directory = await getApplicationSupportDirectory();
      } on Object {
        return null;
      }
    }
    final name = 'p${pageNumber.toString().padLeft(3, '0')}.ttf';
    return File(
      '${directory.path}${Platform.pathSeparator}qcf2'
      '${Platform.pathSeparator}$name',
    );
  }

  static ByteData _toByteData(Uint8List bytes) => ByteData.sublistView(bytes);

  void dispose() => _client.close();
}
