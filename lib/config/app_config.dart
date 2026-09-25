/// Configuration centrale de Soumaya.
///
/// Règle de sécurité absolue : **aucun secret ne doit être compilé dans
/// l'application**. Le `client_secret` OAuth2 de la Quran Foundation reste sur
/// le proxy applicatif ; l'application ne reçoit que des jetons d'accès de
/// courte durée. Voir le README, section « Authentification ».
class AppConfig {
  const AppConfig._();

  // ---------------------------------------------------------------------------
  // Proxy applicatif (recommandé, et de fait obligatoire en production)
  // ---------------------------------------------------------------------------

  /// URL de base du proxy qui détient les identifiants Quran Foundation.
  ///
  /// Fournie à la compilation :
  /// `flutter build apk --dart-define=SOUMAYA_PROXY_BASE_URL=https://...`
  static const String proxyBaseUrl = String.fromEnvironment(
    'SOUMAYA_PROXY_BASE_URL',
    defaultValue: '',
  );

  /// Identifiant client Quran Foundation.
  ///
  /// Le `client_id` n'est **pas** un secret : il est transmis en clair dans
  /// l'en-tête `x-client-id` à chaque requête. Il peut donc être compilé dans
  /// l'application. Seul le `client_secret` doit rester sur le proxy.
  static const String clientId = String.fromEnvironment(
    'SOUMAYA_QF_CLIENT_ID',
    defaultValue: '',
  );

  /// Serveur Content API v4.
  ///
  /// En pré-live, le jeu de données ne contient **que** Al-Fatihah (sourate 1)
  /// et Al-Baqarah (sourate 2) — inutilisable pour parcourir les 604 pages.
  static const String contentApiProduction =
      'https://apis.quran.foundation/content/api/v4';
  static const String contentApiPrelive =
      'https://apis-prelive.quran.foundation/content/api/v4';

  /// Point d'échange OAuth2.
  static const String tokenEndpointProduction =
      'https://oauth2.quran.foundation/oauth2/token';
  static const String tokenEndpointPrelive =
      'https://prelive-oauth2.quran.foundation/oauth2/token';

  /// Bascule vers l'environnement de pré-live (tests uniquement).
  static const bool usePrelive = bool.fromEnvironment('SOUMAYA_USE_PRELIVE');

  static String get contentApiBaseUrl =>
      usePrelive ? contentApiPrelive : contentApiProduction;

  static String get tokenEndpoint =>
      usePrelive ? tokenEndpointPrelive : tokenEndpointProduction;

  // ---------------------------------------------------------------------------
  // Mushaf
  // ---------------------------------------------------------------------------

  /// Nombre de pages du Mushaf madani (Mushaf de Médine).
  static const int mushafPageCount = 604;

  /// Le Mushaf madani est imprimé sur une grille de 15 lignes par page.
  /// Cette valeur est confirmée par le champ `lines_per_page` du groupe de
  /// ressources `mushafs`.
  static const int mushafLinesPerPage = 15;

  /// Identifiant du mushaf « QCF V2 » (1423H) côté Content API.
  ///
  /// Le groupe `mushafs` renvoie `default_font_name: "v2"` pour cet
  /// identifiant ; c'est la police à utiliser pour le rendu glyphe par glyphe.
  static const int mushafId = 1;

  /// Nombre maximal de fichiers audio renvoyés par appel.
  ///
  /// L'API plafonne `per_page` à 50 et vaut **10 par défaut** : ne jamais
  /// omettre ce paramètre, une page du Mushaf peut porter plus de 10 versets.
  static const int audioFilesPerPage = 50;

  /// Teinte papier naturel du Mushaf.
  static const int mushafPaperColor = 0xFFFDFBF7;

  // ---------------------------------------------------------------------------
  // Polices
  // ---------------------------------------------------------------------------

  /// Base du CDN de polices de la Quran Foundation.
  ///
  /// Les fichiers ne sont pas servis par la **Content API** — le groupe
  /// `mushafs` ne renvoie qu'un `default_font_name` — mais ils sont bien
  /// distribués par la fondation, sur un CDN documenté :
  /// <https://api-docs.quran.foundation/docs/tutorials/fonts/font-rendering/>
  ///
  /// Mesuré : les 604 pages répondent 200, de 163 044 à 884 644 octets, pour
  /// **198,2 Mio** au total. Les embarquer dans le paquet est donc exclu ; ils
  /// se chargent page par page, à la demande.
  ///
  /// `SOUMAYA_QCF_FONT_BASE_URL` permet de pointer vers un miroir auto-hébergé.
  ///
  /// ⚠️ Une valeur **vide** ne retombe pas sur le défaut toute seule : un
  /// `--dart-define` défini mais vide l'emporte sur `defaultValue` (mesuré).
  /// D'où [_rawFontBaseUrl] et [quranFontBaseUrl] plus bas.
  static const String _rawFontBaseUrl = String.fromEnvironment(
    'SOUMAYA_QCF_FONT_BASE_URL',
  );

  static const String _defaultFontBaseUrl =
      'https://verses.quran.foundation/fonts/quran/hafs';

  /// Base effectivement utilisée : une valeur vide ou absente retombe sur le CDN
  /// officiel, jamais sur une chaîne vide qui empêcherait tout chargement.
  static String get quranFontBaseUrl =>
      _rawFontBaseUrl.isEmpty ? _defaultFontBaseUrl : _rawFontBaseUrl;

  /// Version du jeu de polices QCF — celle que désigne `default_font_name: "v2"`.
  ///
  /// `v1` et `v2` sont servis en `ttf` ; `v4` (Tajweed) ne l'est **pas** —
  /// mesuré, `v4/ttf/p1.ttf` répond 404, cette version n'existant qu'en
  /// `colrv1` et `ot-svg`.
  static const String qcfFontVersion = 'v2';

  /// Modèle d'URL d'une police de page.
  ///
  /// Le numéro de page n'est **pas** rempli à trois chiffres : le CDN ne sert
  /// que `p1.ttf`, et `p001.ttf` comme `p01.ttf` répondent 404 — mesuré. Une
  /// convention « jolie » de ce côté-ci produit donc un échec silencieux.
  static const String qcfFontUrlTemplate = '{base}/{version}/ttf/p{page}.ttf';

  /// Police **Unicode** utilisée pour les marqueurs de fin de verset.
  ///
  /// La documentation est explicite : les glyphes de numéro de verset se
  /// rendent mieux avec la police Unicode qu'avec une police QCF, et il faut
  /// l'employer pour tout `char_type_name == 'end'`. C'est un fichier unique
  /// (242 368 octets), pas un jeu de 604.
  static const String unicodeFontUrlTemplate =
      '{base}/uthmanic_hafs/UthmanicHafs1Ver18.ttf';

  /// Nom de famille sous lequel la police Unicode est enregistrée.
  ///
  /// Il est choisi par l'application : `FontLoader` enregistre une police sous
  /// le nom qu'on lui donne, et `TextStyle.fontFamily` doit simplement
  /// concorder. La convention `p{page}-{version}` du CDN, elle, ne concerne que
  /// le web, où la famille vient de la feuille de style.
  static const String unicodeFontFamily = 'UthmanicHafs';

  /// Mention exigée par les conditions d'usage des polices.
  ///
  /// La fondation en pose deux : détenir un compte **Developer Console actif**,
  /// et créditer la fondation. La formule est imposée dans les termes mêmes —
  /// la reprendre au mot évite d'avoir à discuter d'une paraphrase.
  ///
  /// Elle est enregistrée dans le registre de licences de Flutter par
  /// `enregistrerCredits()` (voir `lib/config/credits.dart`).
  static const String fontCredit = 'Quran fonts provided by Quran Foundation.';

  /// Mention exigée pour le **contenu**, distincte de celle des polices.
  ///
  /// Les Developer Terms demandent, pour les applications connectées, de
  /// l'afficher « wherever Quranic content is surfaced ». Elle ne remplace pas
  /// [fontCredit] : l'une couvre les fichiers de police, l'autre le texte, la
  /// mise en page et les récitations.
  static const String contentCredit =
      'Quran data provided by Quran Foundation.';
}
