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

/// Fournit les polices du Mushaf : une par page, plus la police Unicode.
///
/// Les polices QCF sont **glyph-based** : chaque mot du Coran y est un glyphe
/// unique, et le jeu est dessiné **page par page**. Il faut donc 604 fichiers,
/// un par page — ce n'est pas une police couvrant tout le texte. La Content API
/// ne les sert pas, mais la Quran Foundation les **distribue** bien, sur un CDN
/// documenté (voir [AppConfig.quranFontBaseUrl]) :
///
/// > « Don't load all 604 QCF fonts upfront. Load only fonts for visible pages. »
///
/// Mesuré : les 604 pages répondent 200, de 163 044 à 884 644 octets, pour
/// 198,2 Mio au total — d'où le chargement à la demande et le cache disque.
///
/// Trois sources sont essayées, dans cet ordre :
///  1. un asset local `assets/mushaf/qcf2/p{page}.ttf` (hors ligne, immédiat) ;
///  2. le cache disque des téléchargements précédents ;
///  3. le CDN.
///
/// Si les trois échouent, on renvoie un état `missing` que l'interface présente
/// clairement, plutôt que des carrés vides dont personne ne peut deviner la
/// cause.
///
/// ## Ce que dit la licence, et ce qu'elle interdit
///
/// La fondation autorise la mise en cache et l'embarquement **à deux
/// conditions** : détenir un compte actif dans la console développeur, et
/// créditer la fondation quelque part de raisonnablement accessible —
/// « Quran fonts provided by Quran Foundation. »
///
/// Et une limite qui compte pour ce dépôt : les fichiers « may be distributed
/// only as an integrated part of your application » et « may not be offered
/// separately through your own API, asset package, standalone download, or
/// similar offering ». **Un dépôt Git public qui contient les TTF est
/// exactement un « asset package »** — les fichiers sont donc ignorés par git
/// (voir `.gitignore`), et le chargement à la demande depuis le CDN est le
/// chemin normal.
class MushafFontProvider {
  MushafFontProvider({
    http.Client? client,
    this.cacheDirectory,
    String? baseUrl,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl ?? AppConfig.quranFontBaseUrl;

  final http.Client _client;

  /// Dossier de cache des polices téléchargées. `null` = dossier système.
  final Directory? cacheDirectory;

  final String _baseUrl;

  final Set<int> _loadedPages = <int>{};
  final Map<int, Future<MushafFontResult>> _inFlight =
      <int, Future<MushafFontResult>>{};
  final Set<int> _unavailablePages = <int>{};

  bool _unicodeLoaded = false;
  bool _unicodeFailed = false;
  Future<String?>? _unicodeInFlight;

  /// Nom de famille utilisé par Flutter pour la page [pageNumber].
  ///
  /// On reprend la convention du CDN (`p1-v2`) plutôt que d'en inventer une :
  /// elle se recoupe avec la documentation, et un écart gratuit entre les deux
  /// se paie en confusion.
  static String familyNameForPage(int pageNumber) =>
      'p$pageNumber-${AppConfig.qcfFontVersion}';

  /// Chemin de l'asset local attendu pour la page [pageNumber].
  ///
  /// Le nom suit celui du CDN, **sans remplissage à trois chiffres** : les
  /// fichiers téléchargés depuis la source officielle se déposent donc tels
  /// quels, sans renommage.
  static String assetPathForPage(int pageNumber) =>
      'assets/mushaf/qcf2/p$pageNumber.ttf';

  /// Chemin de l'asset local de la police Unicode, si elle est embarquée.
  static String get unicodeAssetPath =>
      'assets/mushaf/uthmanic/UthmanicHafs1Ver18.ttf';

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

  /// Résout la police Unicode des marqueurs de fin de verset.
  ///
  /// Rend `null` si elle est introuvable — auquel cas le rendu retombe sur la
  /// police QCF de la page, ce qui est dégradé mais lisible.
  Future<String?> resolveUnicodeFamily() {
    if (_unicodeLoaded) {
      return Future<String?>.value(AppConfig.unicodeFontFamily);
    }
    if (_unicodeFailed) return Future<String?>.value(null);

    final pending = _unicodeInFlight;
    if (pending != null) return pending;

    final future = _loadUnicode().whenComplete(() {
      _unicodeInFlight = null;
    });
    _unicodeInFlight = future;
    return future;
  }

  Future<MushafFontResult> _load(int pageNumber) async {
    final family = familyNameForPage(pageNumber);
    final bytes = await _obtainBytes(
      assetPath: assetPathForPage(pageNumber),
      cacheName: 'p$pageNumber.ttf',
      remoteUri: _remoteUri(
        AppConfig.qcfFontUrlTemplate
            .replaceFirst('{base}', _baseUrl)
            .replaceFirst('{version}', AppConfig.qcfFontVersion)
            .replaceFirst('{page}', '$pageNumber'),
      ),
    );

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

  Future<String?> _loadUnicode() async {
    final family = AppConfig.unicodeFontFamily;
    final bytes = await _obtainBytes(
      assetPath: unicodeAssetPath,
      cacheName: 'UthmanicHafs1Ver18.ttf',
      remoteUri: _remoteUri(
        AppConfig.unicodeFontUrlTemplate.replaceFirst('{base}', _baseUrl),
      ),
    );

    if (bytes == null) {
      _unicodeFailed = true;
      debugPrint(
        '[Soumaya/fonts] police Unicode absente : les marqueurs de fin de '
        'verset seront rendus avec la police de la page.',
      );
      return null;
    }

    try {
      final loader = FontLoader(family)..addFont(Future<ByteData>.value(bytes));
      await loader.load();
      _unicodeLoaded = true;
      return family;
    } on Object catch (error) {
      debugPrint('[Soumaya/fonts] police Unicode illisible : $error');
      _unicodeFailed = true;
      return null;
    }
  }

  Uri? _remoteUri(String url) {
    if (_baseUrl.isEmpty) return null;
    final uri = Uri.tryParse(url);
    return uri != null && uri.hasScheme ? uri : null;
  }

  /// Cherche les octets : asset, puis cache disque, puis réseau.
  Future<ByteData?> _obtainBytes({
    required String assetPath,
    required String cacheName,
    required Uri? remoteUri,
  }) async {
    // 1. Asset embarqué.
    try {
      return await rootBundle.load(assetPath);
    } on Object {
      // Absent du bundle : on continue.
    }

    final cacheFile = await _cacheFileFor(cacheName);

    // 2. Cache disque.
    if (cacheFile != null && await cacheFile.exists()) {
      try {
        return _toByteData(await cacheFile.readAsBytes());
      } on FileSystemException {
        // Cache illisible : on retélécharge.
      }
    }

    // 3. Réseau.
    if (remoteUri == null) return null;

    try {
      final response = await _client.get(remoteUri);
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        debugPrint(
          '[Soumaya/fonts] HTTP ${response.statusCode} sur $remoteUri',
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
        '[Soumaya/fonts] téléchargement échoué sur $remoteUri ($error)',
      );
      return null;
    }
  }

  Future<File?> _cacheFileFor(String name) async {
    var directory = cacheDirectory;
    if (directory == null) {
      try {
        directory = await getApplicationSupportDirectory();
      } on Object {
        return null;
      }
    }
    return File(
      '${directory.path}${Platform.pathSeparator}fonts'
      '${Platform.pathSeparator}$name',
    );
  }

  static ByteData _toByteData(Uint8List bytes) => ByteData.sublistView(bytes);

  void dispose() => _client.close();
}
