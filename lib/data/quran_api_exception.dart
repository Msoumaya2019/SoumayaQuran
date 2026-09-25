import 'package:meta/meta.dart';

/// Erreur normalisée de la Content API v4.
///
/// L'API renvoie toujours la même enveloppe d'erreur :
/// `{"message": "...", "type": "<enum>", "success": false}`
/// avec `type` parmi `invalid_request`, `unauthorized`, `forbidden`,
/// `not_found`, `unprocessable_entity`, `rate_limit_exceeded`,
/// `internal_server_error`, `bad_gateway`, `service_unavailable`,
/// `gateway_timeout`, `insufficient_scope`, `invalid_token`.
@immutable
class QuranApiException implements Exception {
  const QuranApiException({
    required this.statusCode,
    required this.type,
    required this.message,
    this.retryAfter,
  });

  final int statusCode;
  final String type;
  final String message;

  /// Délai indiqué par l'en-tête `Retry-After`, lorsqu'il est présent (429).
  final Duration? retryAfter;

  /// Le jeton est absent, expiré, ou ne porte pas le scope `content`.
  bool get isAuthenticationFailure => statusCode == 401 || statusCode == 403;

  bool get isRateLimited => statusCode == 429;

  /// Erreurs transitoires : un nouvel essai a du sens.
  bool get isTransient =>
      statusCode == 429 ||
      statusCode == 500 ||
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 504;

  @override
  String toString() => 'QuranApiException($statusCode $type) : $message';
}
