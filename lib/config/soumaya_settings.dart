import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';

/// Réglages modifiables **à l'exécution**, par opposition aux constantes de
/// compilation d'[AppConfig].
///
/// ## Pourquoi ce fichier existe
///
/// `AppConfig.proxyBaseUrl` est une constante de compilation
/// (`String.fromEnvironment`). Cela a une conséquence qu'on ne voit qu'après
/// avoir distribué un binaire : **un IPA ou un APK compilé sans proxy ne pourra
/// jamais fonctionner**, quel que soit le compte créé ensuite. Or celui qui
/// installe l'application — un parent, en pratique — ne recompilera pas.
///
/// Ces deux valeurs sont donc déplacées à l'exécution. Les constantes de
/// compilation restent : elles servent de **valeur par défaut** quand rien n'a
/// été saisi. C'est ce qui permet à une compilation de CI faite avec la variable
/// de dépôt de fonctionner sans passage par l'écran de configuration.
///
/// ## Ce qui est stocké, et ce qui ne l'est pas
///
/// L'URL du proxy et l'identifiant client. **Ni l'un ni l'autre n'est un
/// secret** : le `client_id` est transmis en clair dans l'en-tête `x-client-id`
/// à chaque requête, et l'URL d'un service n'est pas un secret non plus. Le
/// `client_secret` reste sur le proxy, où il n'est jamais lu par l'application.
///
/// Les écrire dans les préférences de l'appareil n'ajoute donc aucune surface :
/// ce sont des valeurs que n'importe qui peut lire en observant une requête.
/// C'est précisément ce qui rend légitime de les rendre modifiables.
@immutable
class SoumayaSettings {
  const SoumayaSettings({required this.proxyBaseUrl, required this.clientId});

  /// URL de base du proxy de jetons, sans barre oblique finale.
  final String proxyBaseUrl;

  /// Identifiant client Quran Foundation (`x-client-id`).
  final String clientId;

  /// Réglages par défaut : ceux compilés dans le binaire.
  static const SoumayaSettings defaults = SoumayaSettings(
    proxyBaseUrl: AppConfig.proxyBaseUrl,
    clientId: AppConfig.clientId,
  );

  /// Vrai si l'application peut tenter de joindre le proxy.
  bool get isConfigured =>
      validerProxyBaseUrl(proxyBaseUrl) == null &&
      validerClientId(clientId) == null;

  SoumayaSettings copyWith({String? proxyBaseUrl, String? clientId}) =>
      SoumayaSettings(
        proxyBaseUrl: proxyBaseUrl ?? this.proxyBaseUrl,
        clientId: clientId ?? this.clientId,
      );

  @override
  bool operator ==(Object other) =>
      other is SoumayaSettings &&
      other.proxyBaseUrl == proxyBaseUrl &&
      other.clientId == clientId;

  @override
  int get hashCode => Object.hash(proxyBaseUrl, clientId);

  @override
  String toString() =>
      'SoumayaSettings(proxyBaseUrl: $proxyBaseUrl, clientId: $clientId)';
}

// -----------------------------------------------------------------------------
// Validation
// -----------------------------------------------------------------------------

/// Schémas refusés parce qu'ils ne désignent pas une ressource joignable par
/// HTTP.
const Set<String> _schemasHttp = <String>{'http', 'https'};

/// Préfixes d'adresses IPv4 privées, de boucle locale et de lien local.
///
/// Ce sont les seules pour lesquelles un `http://` en clair est toléré : le
/// trafic ne quitte pas le réseau de l'utilisateur.
const List<String> _prefixesPrives = <String>[
  '127.',
  '10.',
  '192.168.',
  '169.254.',
  '0.',
];

/// Hôtes littéraux toujours considérés comme locaux.
const Set<String> _hotesLocaux = <String>{
  'localhost',
  '127.0.0.1',
  '::1',
  '[::1]',
};

/// Vrai si [hote] désigne la machine elle-même ou le réseau local.
///
/// Le contrôle est **textuel**, volontairement : résoudre un nom par DNS pour
/// décider s'il est local demanderait un accès réseau à la validation, et
/// rendrait le verdict dépendant d'une réponse qu'on ne maîtrise pas. Un nom
/// public écrit en `http://` est donc refusé même s'il pointe vers une adresse
/// privée — c'est le prix, assumé, d'une règle vérifiable hors ligne.
@visibleForTesting
bool hoteLocal(String hote) {
  final minuscule = hote.toLowerCase();
  if (_hotesLocaux.contains(minuscule)) return true;
  if (minuscule.endsWith('.local')) return true;
  if (_prefixesPrives.any(minuscule.startsWith)) return true;

  // 172.16.0.0/12 — la seule plage privée qui ne se reconnaît pas à un préfixe
  // fixe. On lit donc l'octet du milieu.
  if (minuscule.startsWith('172.')) {
    final octets = minuscule.split('.');
    if (octets.length >= 2) {
      final deuxieme = int.tryParse(octets[1]);
      if (deuxieme != null && deuxieme >= 16 && deuxieme <= 31) return true;
    }
  }
  return false;
}

/// Valide une URL de proxy. Rend `null` si elle est acceptable, sinon la raison
/// du refus, rédigée pour être montrée telle quelle.
String? validerProxyBaseUrl(String valeur) {
  final texte = valeur.trim();
  if (texte.isEmpty) {
    return 'Renseignez l\'adresse du proxy de jetons.';
  }
  if (texte.contains(RegExp(r'\s'))) {
    // Un blanc casserait aussi la ligne de commande de compilation ; ici il
    // trahit surtout une adresse recopiée de travers.
    return 'L\'adresse ne doit contenir aucun espace.';
  }

  final uri = Uri.tryParse(texte);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'Adresse incomplète : attendu par exemple https://proxy.exemple.fr';
  }
  if (!_schemasHttp.contains(uri.scheme)) {
    return 'Schéma « ${uri.scheme} » non pris en charge : attendu http ou https.';
  }

  // Le proxy délivre des jetons d'accès. En clair sur un réseau public, ces
  // jetons sont lisibles par quiconque est sur le chemin. On tolère le clair
  // uniquement là où le trafic ne sort pas du réseau local — ce qui couvre le
  // cas d'un essai, et refuse le cas dangereux.
  if (uri.scheme == 'http' && !hoteLocal(uri.host)) {
    return 'En http://, seules les adresses locales sont acceptées. '
        'Utilisez https:// pour un hôte distant.';
  }

  return null;
}

/// Valide l'identifiant client. Rend `null` si acceptable.
String? validerClientId(String valeur) {
  final texte = valeur.trim();
  if (texte.isEmpty) {
    return 'Renseignez l\'identifiant client (Client ID) de la console '
        'développeur.';
  }
  if (texte.contains(RegExp(r'\s'))) {
    return 'L\'identifiant ne doit contenir aucun espace.';
  }
  return null;
}

/// Normalise une URL : espaces retirés, barres obliques finales supprimées.
///
/// Sans cela, `https://proxy.fr/` et `https://proxy.fr` produiraient
/// `https://proxy.fr//qf/token`, que certains serveurs refusent — et le message
/// ne nommerait pas la cause.
String normaliserProxyBaseUrl(String valeur) {
  var texte = valeur.trim();
  while (texte.endsWith('/')) {
    texte = texte.substring(0, texte.length - 1);
  }
  return texte;
}

// -----------------------------------------------------------------------------
// Persistance
// -----------------------------------------------------------------------------

/// Lit et écrit les réglages dans les préférences de l'appareil.
class SoumayaSettingsStore {
  const SoumayaSettingsStore();

  static const String cleProxy = 'soumaya.proxy_base_url';
  static const String cleClient = 'soumaya.client_id';

  /// Charge les réglages, en retombant sur les valeurs compilées.
  ///
  /// Une préférence absente et une préférence vide sont traitées pareil : dans
  /// les deux cas, la valeur compilée s'applique.
  Future<SoumayaSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final proxy = prefs.getString(cleProxy) ?? '';
    final client = prefs.getString(cleClient) ?? '';

    return SoumayaSettings(
      proxyBaseUrl: proxy.isEmpty
          ? SoumayaSettings.defaults.proxyBaseUrl
          : proxy,
      clientId: client.isEmpty ? SoumayaSettings.defaults.clientId : client,
    );
  }

  /// Écrit les réglages. Lève [ArgumentError] si une valeur est refusée — on ne
  /// persiste jamais une configuration qu'on vient de déclarer invalide.
  Future<void> save(SoumayaSettings reglages) async {
    final erreurProxy = validerProxyBaseUrl(reglages.proxyBaseUrl);
    if (erreurProxy != null) {
      throw ArgumentError.value(
        reglages.proxyBaseUrl,
        'proxyBaseUrl',
        erreurProxy,
      );
    }
    final erreurClient = validerClientId(reglages.clientId);
    if (erreurClient != null) {
      throw ArgumentError.value(reglages.clientId, 'clientId', erreurClient);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      cleProxy,
      normaliserProxyBaseUrl(reglages.proxyBaseUrl),
    );
    await prefs.setString(cleClient, reglages.clientId.trim());
  }

  /// Efface les réglages : les valeurs compilées reprennent la main.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(cleProxy);
    await prefs.remove(cleClient);
  }
}
