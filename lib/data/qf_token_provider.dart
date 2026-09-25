import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../config/app_config.dart';
import 'quran_api_exception.dart';

/// Fournit un jeton d'accès Content API.
abstract class QfTokenSource {
  /// Renvoie un jeton valide, en le renouvelant si nécessaire.
  Future<String> accessToken();

  /// Force le renouvellement au prochain appel (utilisé après un 401/403).
  void invalidate();

  /// Libère les ressources réseau.
  void dispose() {}
}

/// Base commune : cache du jeton et protection contre les appels concurrents.
///
/// Sans cette protection, l'ouverture d'une page déclenche plusieurs requêtes
/// simultanées qui demanderaient chacune un jeton — autant d'appels inutiles au
/// point d'échange OAuth2, et un risque de limitation de débit.
abstract class _CachingTokenSource implements QfTokenSource {
  _CachingTokenSource({required this.client});

  final http.Client client;

  String? _token;
  DateTime? _expiresAt;
  Future<String>? _inFlight;

  /// Marge de sécurité avant expiration (les jetons vivent 3600 s).
  static const Duration _safetyMargin = Duration(seconds: 90);

  /// Récupère un jeton auprès de la source concrète.
  @protected
  Future<({String token, Duration lifetime})> fetchToken();

  @override
  void invalidate() {
    _token = null;
    _expiresAt = null;
  }

  @override
  Future<String> accessToken() {
    final token = _token;
    final expiresAt = _expiresAt;
    if (token != null &&
        expiresAt != null &&
        DateTime.now().isBefore(expiresAt.subtract(_safetyMargin))) {
      return Future<String>.value(token);
    }

    // Un seul appel en vol à la fois.
    return _inFlight ??= _refresh().whenComplete(() {
      _inFlight = null;
    });
  }

  Future<String> _refresh() async {
    final result = await fetchToken();
    _token = result.token;
    _expiresAt = DateTime.now().add(result.lifetime);
    return result.token;
  }

  @override
  void dispose() => client.close();
}

/// Source **recommandée** : un proxy applicatif détient le `client_secret` et
/// délivre des jetons courts à l'application.
///
/// C'est la seule architecture acceptable en production. Un `client_secret`
/// compilé dans un APK ou un IPA est extractible en quelques minutes : il
/// donnerait à quiconque le contrôle du quota de l'application.
class ProxyTokenSource extends _CachingTokenSource {
  ProxyTokenSource({required super.client, String? proxyBaseUrl})
    : _proxyBaseUrl = proxyBaseUrl ?? AppConfig.proxyBaseUrl;

  final String _proxyBaseUrl;

  /// Chemin attendu sur le proxy : `GET {proxyBaseUrl}/qf/token`.
  ///
  /// Réponse attendue : `{"access_token": "...", "expires_in": 3600}`.
  @override
  Future<({String token, Duration lifetime})> fetchToken() async {
    if (_proxyBaseUrl.isEmpty) {
      throw const QuranApiException(
        statusCode: 0,
        type: 'configuration_missing',
        message:
            'Aucun proxy configuré. Compilez avec '
            '--dart-define=SOUMAYA_PROXY_BASE_URL=https://votre-proxy',
      );
    }

    final uri = Uri.parse('$_proxyBaseUrl/qf/token');
    final response = await client.get(
      uri,
      headers: const <String, String>{'accept': 'application/json'},
    );

    if (response.statusCode != 200) {
      throw QuranApiException(
        statusCode: response.statusCode,
        type: 'proxy_token_failed',
        message: 'Le proxy a refusé la demande de jeton : ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const QuranApiException(
        statusCode: 200,
        type: 'proxy_response_malformed',
        message: 'Réponse de jeton illisible.',
      );
    }

    final token = decoded['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw const QuranApiException(
        statusCode: 200,
        type: 'proxy_response_malformed',
        message: 'Le proxy n\'a pas renvoyé de access_token.',
      );
    }

    final expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 3600;
    return (token: token, lifetime: Duration(seconds: expiresIn));
  }
}

/// Source de développement : échange `client_credentials` directement depuis
/// l'application.
///
/// ⚠️ **Inutilisable en production.** Elle exige d'embarquer le
/// `client_secret` dans le binaire. Le constructeur refuse de s'instancier en
/// mode release tant que `SOUMAYA_ALLOW_EMBEDDED_CREDENTIALS` n'a pas été
/// explicitement activé, afin qu'aucune compilation de production ne parte
/// avec un secret à l'intérieur par simple inadvertance.
class ClientCredentialsTokenSource extends _CachingTokenSource {
  ClientCredentialsTokenSource({
    required super.client,
    required this.clientId,
    required this.clientSecret,
    String? tokenEndpoint,
  }) : _tokenEndpoint = tokenEndpoint ?? AppConfig.tokenEndpoint {
    const allowEmbedded = bool.fromEnvironment(
      'SOUMAYA_ALLOW_EMBEDDED_CREDENTIALS',
    );
    if (!allowEmbedded && !_isDebugBuild) {
      throw StateError(
        'Refus de compiler un client_secret dans un binaire de production. '
        'Utilisez ProxyTokenSource, ou passez explicitement '
        '--dart-define=SOUMAYA_ALLOW_EMBEDDED_CREDENTIALS=true si vous '
        'acceptez que ce secret soit extractible de l\'application.',
      );
    }
  }

  final String clientId;
  final String clientSecret;
  final String _tokenEndpoint;

  static const bool _isDebugBuild =
      bool.fromEnvironment('dart.vm.product') == false;

  /// Échange `client_credentials` contre un jeton portant le scope `content`.
  ///
  /// Le Content API n'accepte que ce grant : le flux Authorization Code + PKCE
  /// est réservé aux User APIs.
  @override
  Future<({String token, Duration lifetime})> fetchToken() async {
    final credentials = base64Encode(utf8.encode('$clientId:$clientSecret'));

    final response = await client.post(
      Uri.parse(_tokenEndpoint),
      headers: <String, String>{
        'authorization': 'Basic $credentials',
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
      },
      body: 'grant_type=client_credentials&scope=content',
    );

    if (response.statusCode != 200) {
      throw QuranApiException(
        statusCode: response.statusCode,
        type: 'invalid_client',
        message: 'Échange de jeton refusé : ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const QuranApiException(
        statusCode: 200,
        type: 'token_response_malformed',
        message: 'Réponse de jeton illisible.',
      );
    }

    final token = decoded['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw const QuranApiException(
        statusCode: 200,
        type: 'token_response_malformed',
        message: 'Aucun access_token dans la réponse.',
      );
    }

    final expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 3600;
    return (token: token, lifetime: Duration(seconds: expiresIn));
  }
}
