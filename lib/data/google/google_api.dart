import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Erreur renvoyée par une API Google, traduite en français.
class GoogleApiException implements Exception {
  GoogleApiException({
    required this.statusCode,
    required this.status,
    required this.message,
    this.reason,
    this.activationUrl,
    this.request,
  });

  final int statusCode;

  /// Statut canonique Google (PERMISSION_DENIED, NOT_FOUND…).
  final String status;
  final String message;
  final String? reason;

  /// Lien de la console pour activer une API désactivée.
  final String? activationUrl;
  final String? request;

  bool get isNotFound => statusCode == 404 || status == 'NOT_FOUND';
  bool get isAlreadyExists => statusCode == 409 || status == 'ALREADY_EXISTS';
  bool get isPermissionDenied => statusCode == 403 || status == 'PERMISSION_DENIED';
  bool get isScopeInsufficient =>
      reason == 'ACCESS_TOKEN_SCOPE_INSUFFICIENT' || message.contains('insufficient authentication scopes');
  bool get isServiceDisabled => reason == 'SERVICE_DISABLED';
  bool get isBillingRequired =>
      reason == 'BILLING_DISABLED' || message.toLowerCase().contains('billing');

  /// Explication en français destinée à l'utilisateur.
  String get explanation {
    if (isScopeInsufficient) {
      return 'Autorisation Google incomplète : l\'accès « Google Cloud » n\'a pas été coché lors de la connexion. '
          'Déconnectez-vous, reconnectez-vous et cochez TOUTES les cases sur l\'écran de Google.';
    }
    if (isServiceDisabled) {
      return 'Une API Google nécessaire est désactivée sur ce projet.'
          '${activationUrl == null ? '' : ' Activez-la ici : $activationUrl'}';
    }
    if (isBillingRequired) {
      return 'Cette opération exige un compte de facturation (plan Blaze) sur le projet. '
          'BDDouilleur ne l\'active jamais à votre place.';
    }
    return switch (status) {
      'PERMISSION_DENIED' => 'Permission refusée : votre compte n\'a pas les droits nécessaires sur ce projet.',
      'NOT_FOUND' => 'Ressource introuvable.',
      'ALREADY_EXISTS' => 'Cette ressource existe déjà.',
      'RESOURCE_EXHAUSTED' => 'Quota atteint. Réessayez plus tard ou vérifiez les quotas dans la console.',
      'UNAUTHENTICATED' => 'Session Google expirée ou révoquée. Reconnectez votre compte.',
      'FAILED_PRECONDITION' => 'Prérequis non rempli.',
      'INVALID_ARGUMENT' => 'Paramètre refusé par Google.',
      _ => 'Erreur de l\'API Google (HTTP $statusCode).',
    };
  }

  @override
  String toString() => '$explanation\nDétail Google : $message';

  static GoogleApiException fromResponse(http.Response res, String request) {
    String status = 'UNKNOWN';
    String message = res.body.length > 300 ? '${res.body.substring(0, 300)}…' : res.body;
    String? reason;
    String? activation;
    try {
      final json = jsonDecode(res.body);
      final err = json is Map ? json['error'] : null;
      if (err is Map) {
        status = (err['status'] as String?) ?? status;
        message = (err['message'] as String?) ?? message;
        for (final d in (err['details'] as List?) ?? const []) {
          if (d is! Map) continue;
          reason ??= d['reason'] as String?;
          final meta = d['metadata'];
          if (meta is Map && meta['activationUrl'] is String) activation = meta['activationUrl'] as String;
          for (final link in (d['links'] as List?) ?? const []) {
            if (link is Map && activation == null && '${link['url']}'.contains('apis/api')) {
              activation = link['url'] as String?;
            }
          }
        }
      } else if (err is String) {
        status = err;
      }
    } catch (_) {}
    if (status == 'UNKNOWN') {
      status = switch (res.statusCode) {
        401 => 'UNAUTHENTICATED',
        403 => 'PERMISSION_DENIED',
        404 => 'NOT_FOUND',
        409 => 'ALREADY_EXISTS',
        429 => 'RESOURCE_EXHAUSTED',
        _ => 'UNKNOWN',
      };
    }
    return GoogleApiException(
      statusCode: res.statusCode,
      status: status,
      message: message,
      reason: reason,
      activationUrl: activation,
      request: request,
    );
  }
}

/// Fournit l'en-tête d'autorisation (jeton OAuth, ou « owner » pour l'émulateur).
typedef AuthHeaderProvider = Future<String?> Function();

/// Client JSON minimal pour les API REST Google.
class GoogleApiClient {
  GoogleApiClient({required this.authHeader, http.Client? client, this.pollInterval = const Duration(seconds: 2)})
      : _http = client ?? http.Client();

  final AuthHeaderProvider authHeader;
  final Duration pollInterval;
  final http.Client _http;

  /// Dernières requêtes envoyées (méthode + URL sans paramètre secret),
  /// utilisées pour le journal.
  final List<String> requestLog = [];
  int _sent = 0;

  /// Repère à passer à [requestsSince].
  int get mark => _sent;

  /// Requêtes envoyées depuis [mark] (les plus anciennes peuvent manquer
  /// au-delà de 50).
  List<String> requestsSince(int mark) {
    final n = (_sent - mark).clamp(0, requestLog.length);
    return requestLog.sublist(requestLog.length - n);
  }

  Future<Map<String, dynamic>> get(String url, {Map<String, String>? query}) => send('GET', url, query: query);
  Future<Map<String, dynamic>> post(String url, {Object? body, Map<String, String>? query}) =>
      send('POST', url, body: body, query: query);
  Future<Map<String, dynamic>> patch(String url, {Object? body, Map<String, String>? query}) =>
      send('PATCH', url, body: body, query: query);
  Future<Map<String, dynamic>> put(String url, {Object? body, Map<String, String>? query}) =>
      send('PUT', url, body: body, query: query);
  Future<Map<String, dynamic>> delete(String url, {Map<String, String>? query}) => send('DELETE', url, query: query);

  Future<Map<String, dynamic>> send(String method, String url, {Object? body, Map<String, String>? query}) async {
    var uri = Uri.parse(url);
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    final safeQuery = Map.of(uri.queryParameters)..remove('key');
    final logged = '$method ${uri.origin}${uri.path}'
        '${safeQuery.isEmpty ? '' : '?${Uri(queryParameters: safeQuery).query}'}';
    requestLog.add(logged);
    _sent++;
    if (requestLog.length > 50) requestLog.removeAt(0);

    final req = http.Request(method, uri);
    final auth = await authHeader();
    if (auth != null) req.headers['Authorization'] = auth;
    if (body != null) {
      req.headers['Content-Type'] = 'application/json; charset=utf-8';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req)).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw GoogleApiException(statusCode: 0, status: 'DEADLINE_EXCEEDED', message: 'Délai dépassé', request: logged);
    } catch (e) {
      throw GoogleApiException(
          statusCode: 0, status: 'UNAVAILABLE', message: 'Serveur injoignable ($e)', request: logged);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) throw GoogleApiException.fromResponse(res, logged);
    if (res.body.trim().isEmpty) return {};
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    return json is Map<String, dynamic> ? json : {'value': json};
  }

  /// Attend la fin d'une opération longue (google.longrunning.Operation).
  Future<Map<String, dynamic>> waitOperation(
    String baseUrl,
    Map<String, dynamic> operation, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    var op = operation;
    final deadline = DateTime.now().add(timeout);
    while (op['done'] != true) {
      final name = op['name'] as String?;
      if (name == null) return op;
      if (DateTime.now().isAfter(deadline)) {
        throw GoogleApiException(
            statusCode: 0, status: 'DEADLINE_EXCEEDED', message: 'Opération $name toujours en cours après ${timeout.inMinutes} min');
      }
      await Future<void>.delayed(pollInterval);
      op = await get('$baseUrl/$name');
    }
    final error = op['error'];
    if (error is Map) {
      throw GoogleApiException(
        statusCode: (error['code'] as num?)?.toInt() ?? 0,
        status: _statusFromCode((error['code'] as num?)?.toInt()),
        message: (error['message'] as String?) ?? 'Opération échouée',
      );
    }
    return (op['response'] as Map<String, dynamic>?) ?? op;
  }

  static String _statusFromCode(int? code) => switch (code) {
        3 => 'INVALID_ARGUMENT',
        5 => 'NOT_FOUND',
        6 => 'ALREADY_EXISTS',
        7 => 'PERMISSION_DENIED',
        8 => 'RESOURCE_EXHAUSTED',
        9 => 'FAILED_PRECONDITION',
        16 => 'UNAUTHENTICATED',
        _ => 'UNKNOWN',
      };

  void close() => _http.close();
}
