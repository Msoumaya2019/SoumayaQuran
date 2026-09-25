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
  // Polices QCF
  // ---------------------------------------------------------------------------

  /// Base CDN optionnelle pour télécharger les polices QCF page par page.
  ///
  /// Les fichiers de police ne sont **pas** fournis par la Content API (le
  /// groupe `mushafs` ne renvoie qu'un `default_font_name`). Si cette base est
  /// vide et qu'aucun asset local n'est présent, le rendu retombe sur un texte
  /// Uthmani standard au lieu d'afficher une page cassée.
  static const String qcfFontBaseUrl = String.fromEnvironment(
    'SOUMAYA_QCF_FONT_BASE_URL',
    defaultValue: '',
  );

  /// Modèle d'URL des polices, `{page}` remplacé par le numéro sur 3 chiffres.
  static const String qcfFontUrlTemplate = '{base}/qcf2/p{page}.ttf';
}
