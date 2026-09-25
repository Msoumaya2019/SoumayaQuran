import 'package:flutter/foundation.dart';

import '../audio/audio_controller.dart';
import '../audio/playback_plan.dart';
import '../config/app_config.dart';
import '../data/models/mushaf_index.dart';
import '../data/models/mushaf_layout.dart';
import '../data/quran_api_exception.dart';
import '../data/quran_api_service.dart';
import '../data/reciter_catalog.dart';
import '../ui/mushaf_font_provider.dart';

/// État de démarrage de la session.
enum SessionStatus { idle, loading, ready, failed }

/// Assemble les briques de Soumaya : catalogue des récitateurs, index du
/// Mushaf, chargement de l'audio d'une page, et lecteur.
///
/// C'est le seul endroit où l'on décide *quand* une requête part. L'interface
/// ne fait que lire cet état.
class SoumayaSession extends ChangeNotifier {
  SoumayaSession(this._api, this._handler, {MushafFontProvider? fontProvider})
    : fontProvider = fontProvider ?? MushafFontProvider() {
    audio = AudioController(_handler);
  }

  final QuranApiService _api;
  final SoumayaAudioHandler _handler;

  final MushafFontProvider fontProvider;

  late final AudioController audio;

  SessionStatus _status = SessionStatus.idle;
  String? _errorMessage;
  bool _configurationManquante = false;
  MushafSnapshot? _snapshot;
  MushafIndex? _index;
  List<ReciterResolution> _reciters = const <ReciterResolution>[];
  ReciterResolution? _selectedReciter;
  int _currentPage = 1;
  int? _loadingPage;

  SessionStatus get status => _status;
  String? get errorMessage => _errorMessage;

  /// Vrai quand l'échec vient d'une configuration absente, et non du réseau.
  ///
  /// La distinction commande ce que l'interface propose : « Réessayer » ne
  /// réparera jamais une adresse de proxy vide, alors qu'un écran de
  /// configuration, oui. Sans ce drapeau, l'écran d'échec proposait le seul
  /// bouton qui ne pouvait pas marcher.
  bool get configurationManquante => _configurationManquante;

  MushafSnapshot? get snapshot => _snapshot;
  MushafIndex? get index => _index;
  List<ReciterResolution> get reciters => _reciters;
  ReciterResolution? get selectedReciter => _selectedReciter;
  int get currentPage => _currentPage;
  bool get isLoadingPage => _loadingPage != null;

  /// Libellé du récitateur actif, pour la capsule.
  String get reciterLabel => _selectedReciter?.recitation?.displayName ?? '';

  /// Vrai si au moins un récitateur a pu être résolu.
  bool get hasUsableReciter => _selectedReciter?.isResolved ?? false;

  /// Met en place le catalogue, l'index du Mushaf et la première page.
  Future<void> initialize() async {
    _status = SessionStatus.loading;
    _errorMessage = null;
    _configurationManquante = false;
    notifyListeners();

    try {
      final recitations = await _api.fetchRecitations();
      _reciters = ReciterCatalog.resolveAll(available: recitations);
      _selectedReciter = _reciters.where((r) => r.isResolved).firstOrNull;

      _index = await _api.loadMushafIndex();
      _snapshot = await _api.loadCachedMushafSnapshot();

      if (_selectedReciter == null) {
        // Cas réel : le catalogue officiel ne contient pas d'entrée pour
        // Yasser Al-Dossari. On le dit au lieu d'afficher un lecteur muet.
        _status = SessionStatus.failed;
        _errorMessage =
            'Aucun des récitateurs demandés n\'est disponible dans le '
            'catalogue Content API. Vérifiez les identifiants de récitation.';
        notifyListeners();
        return;
      }

      _status = SessionStatus.ready;
      notifyListeners();

      await openPage(1, autoPlay: false);
    } on Object catch (error) {
      _status = SessionStatus.failed;
      _errorMessage = error.toString();
      _configurationManquante =
          error is QuranApiException && error.type == 'configuration_missing';
      notifyListeners();
    }
  }

  /// Charge la page [pageNumber] et met sa sélection audio en file.
  ///
  /// [autoPlay] à `false` prépare la file sans démarrer : c'est le
  /// comportement attendu quand on feuillette le Mushaf sans écouter.
  Future<void> openPage(int pageNumber, {bool autoPlay = true}) async {
    if (pageNumber < 1 || pageNumber > AppConfig.mushafPageCount) return;

    _currentPage = pageNumber;
    notifyListeners();

    final recitation = _selectedReciter?.recitation;
    if (recitation == null) return;

    _loadingPage = pageNumber;
    notifyListeners();

    try {
      final files = await _api.fetchPageAudioFiles(
        recitationId: recitation.id,
        pageNumber: pageNumber,
      );

      // Une page changée pendant le chargement rend le résultat caduc.
      if (_loadingPage != pageNumber) return;
      if (files.isEmpty) return;

      await _handler.loadSelection(
        files: files,
        reciterLabel: reciterLabel,
        pageLabel: 'Page $pageNumber',
        policy: audio.policy,
        autoPlay: autoPlay,
      );
    } on Object catch (error) {
      _errorMessage = error.toString();
    } finally {
      if (_loadingPage == pageNumber) _loadingPage = null;
      notifyListeners();
    }
  }

  /// Change de récitateur et recharge la page courante.
  Future<void> selectReciter(ReciterResolution resolution) async {
    if (!resolution.isResolved) return;
    _selectedReciter = resolution;
    notifyListeners();
    await openPage(_currentPage, autoPlay: audio.isPlaying);
  }

  /// Applique une plage de versets à la sélection courante.
  Future<void> applyRange({String? from, String? to}) async {
    await _handler.setVerseRange(from: from, to: to, autoPlay: audio.isPlaying);
    notifyListeners();
  }

  /// Clés des versets de la page [pageNumber], dans l'ordre du Mushaf.
  ///
  /// Déduites des ordinaux de la page et de la table de correspondance : aucune
  /// requête n'est nécessaire, et le résultat reste juste même après avoir
  /// restreint la lecture à une plage de versets.
  List<String> verseKeysOfPage(int pageNumber) {
    final page = _snapshot?.pages[pageNumber];
    final ordinals = _index?.ordinals;
    if (page == null || ordinals == null) return const <String>[];
    if (page.firstVerseId <= 0 || page.lastVerseId < page.firstVerseId) {
      return const <String>[];
    }

    final keys = <String>[];
    for (
      var ordinal = page.firstVerseId;
      ordinal <= page.lastVerseId;
      ordinal++
    ) {
      final key = ordinals.keyOf(ordinal);
      if (key == null) break;
      keys.add('$key');
    }
    return List<String>.unmodifiable(keys);
  }

  /// Recharge le Mushaf depuis le réseau, en ignorant le cache disque.
  Future<void> refreshMushaf() async {
    _index = await _api.loadMushafIndex(forceRefresh: true);
    _snapshot = await _api.loadCachedMushafSnapshot();
    notifyListeners();
  }

  void updatePolicy(RepeatPolicy policy) {
    audio.setPolicy(policy);
    notifyListeners();
  }

  @override
  void dispose() {
    audio.dispose();
    fontProvider.dispose();
    _api.dispose();
    super.dispose();
  }
}

/// Petit utilitaire : `firstOrNull` sans dépendre de `collection`.
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
