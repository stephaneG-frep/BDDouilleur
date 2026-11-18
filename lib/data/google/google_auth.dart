import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../secrets/secret_store.dart';

/// Identifiants du client OAuth « Application de bureau » créé par
/// l'utilisateur dans SA console Google Cloud. Rien n'est intégré à l'APK.
class OAuthClientConfig {
  const OAuthClientConfig({required this.clientId, required this.clientSecret});
  final String clientId;

  /// Pour un client « bureau », Google exige ce champ lors de l'échange du
  /// code, mais il n'est pas considéré comme confidentiel (RFC 8252). Il est
  /// tout de même rangé dans le stockage sécurisé.
  final String clientSecret;

  static String? validateClientId(String v) {
    final s = v.trim();
    if (s.isEmpty) return 'Identifiant client obligatoire.';
    if (!RegExp(r'^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$').hasMatch(s)) {
      return 'Format attendu : 1234567890-abc….apps.googleusercontent.com';
    }
    return null;
  }
}

class GoogleAuthException implements Exception {
  GoogleAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Points d'accès OAuth (modifiables pour les tests).
class GoogleOAuthEndpoints {
  const GoogleOAuthEndpoints({
    this.authorize = 'https://accounts.google.com/o/oauth2/v2/auth',
    this.token = 'https://oauth2.googleapis.com/token',
    this.revoke = 'https://oauth2.googleapis.com/revoke',
    this.userInfo = 'https://openidconnect.googleapis.com/v1/userinfo',
  });
  final String authorize;
  final String token;
  final String revoke;
  final String userInfo;
}

/// Ouvre une URL dans le navigateur du système.
typedef BrowserLauncher = Future<bool> Function(Uri url);

/// Authentification Google OAuth 2.0 pour application native (RFC 8252) :
/// navigateur du système + redirection loopback 127.0.0.1 + PKCE (S256).
///
/// - Le mot de passe Google n'est jamais vu par BDDouilleur.
/// - Le jeton de rafraîchissement est rangé dans le [SecretStore].
/// - Aucun jeton n'est écrit dans les journaux.
class GoogleAuthService {
  GoogleAuthService({
    required this.secrets,
    required this.launcher,
    http.Client? client,
    this.endpoints = const GoogleOAuthEndpoints(),
    this.loginTimeout = const Duration(minutes: 5),
    this.waitForForeground,
    this.networkRetryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
      Duration(seconds: 5),
      Duration(seconds: 8),
    ],
  }) : _http = client ?? http.Client();

  /// Attend que l'application soit revenue au premier plan. Certains
  /// téléphones (Honor, Huawei, Xiaomi…) coupent le réseau des applications
  /// en arrière-plan : l'échange du code doit donc attendre le retour.
  final Future<void> Function()? waitForForeground;

  /// Nouvelles tentatives en cas d'erreur réseau (réseau pas encore rétabli).
  final List<Duration> networkRetryDelays;

  final SecretStore secrets;
  final BrowserLauncher launcher;
  final GoogleOAuthEndpoints endpoints;
  final Duration loginTimeout;

  static const networkErrorMessage =
      'Réseau injoignable pour BDDouilleur (serveurs Google introuvables). Vérifiez la connexion Internet. '
      'Sur certains téléphones (Honor, Huawei…), le gestionnaire d\'énergie coupe le réseau des applications '
      'en arrière-plan : autorisez BDDouilleur à fonctionner en arrière-plan, puis réessayez.';

  /// Requête avec nouvelles tentatives sur erreur réseau uniquement.
  Future<http.Response> _withRetry(Future<http.Response> Function() send) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await send();
      } on SocketException {
        if (attempt >= networkRetryDelays.length) throw GoogleAuthException(networkErrorMessage);
      } on http.ClientException {
        if (attempt >= networkRetryDelays.length) throw GoogleAuthException(networkErrorMessage);
      }
      await Future<void>.delayed(networkRetryDelays[attempt]);
    }
  }
  final http.Client _http;

  static const scopes = [
    'openid',
    'email',
    'https://www.googleapis.com/auth/cloud-platform',
    'https://www.googleapis.com/auth/firebase',
  ];

  /// Accès indispensable : sans lui, aucune API Cloud/Firebase ne répond.
  static const requiredScope = 'https://www.googleapis.com/auth/cloud-platform';

  static const scopeInsufficientMessage =
      'Autorisation incomplète : l\'accès « Google Cloud » (voir, modifier, configurer et supprimer vos données '
      'Google Cloud) n\'a pas été accordé. Sur l\'écran de consentement de Google, cochez TOUTES les cases, '
      'puis reconnectez-vous.';

  /// Vérifie les accès réellement accordés (consentement granulaire de Google).
  static void checkGrantedScopes(Map<String, dynamic> tokens) {
    final scope = tokens['scope'];
    if (scope is! String) return; // Google omet parfois le champ lors d'un rafraîchissement.
    if (!scope.split(' ').contains(requiredScope)) throw GoogleAuthException(scopeInsufficientMessage);
  }

  String? _accessToken;
  DateTime? _accessExpiry;
  String? _email;
  HttpServer? _pendingServer;

  String? get email => _email;

  /// Charge l'état depuis le stockage sécurisé (au démarrage).
  Future<void> load() async {
    _email = await secrets.read(SecretKeys.accountEmail);
    if (await secrets.read(SecretKeys.refreshToken) == null) _email = null;
  }

  Future<bool> get isSignedIn async => await secrets.read(SecretKeys.refreshToken) != null;

  Future<OAuthClientConfig?> clientConfig() async {
    final id = await secrets.read(SecretKeys.oauthClientId);
    final secret = await secrets.read(SecretKeys.oauthClientSecret);
    if (id == null || secret == null) return null;
    return OAuthClientConfig(clientId: id, clientSecret: secret);
  }

  Future<void> saveClientConfig(OAuthClientConfig c) async {
    await secrets.write(SecretKeys.oauthClientId, c.clientId.trim());
    await secrets.write(SecretKeys.oauthClientSecret, c.clientSecret.trim());
  }

  Future<void> deleteClientConfig() async {
    await signOut();
    await secrets.delete(SecretKeys.oauthClientId);
    await secrets.delete(SecretKeys.oauthClientSecret);
  }

  static String _randomUrlSafe(int bytes) {
    final r = Random.secure();
    return base64UrlEncode(List<int>.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  static String codeChallenge(String verifier) =>
      base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

  /// Annule une connexion en attente (l'utilisateur a fermé le navigateur).
  Future<void> cancelPendingSignIn() async {
    await _pendingServer?.close(force: true);
    _pendingServer = null;
  }

  /// Lance le parcours de consentement. Renvoie l'adresse e-mail du compte.
  Future<String> signIn() async {
    final config = await clientConfig();
    if (config == null) {
      throw GoogleAuthException('Configurez d\'abord votre identifiant client OAuth (type « Application de bureau »).');
    }
    await cancelPendingSignIn();
    final verifier = _randomUrlSafe(48);
    final state = _randomUrlSafe(24);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _pendingServer = server;
    final redirect = 'http://127.0.0.1:${server.port}';
    final url = Uri.parse(endpoints.authorize).replace(queryParameters: {
      'client_id': config.clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': scopes.join(' '),
      'code_challenge': codeChallenge(verifier),
      'code_challenge_method': 'S256',
      'state': state,
      'access_type': 'offline',
      'prompt': 'consent',
    });

    try {
      if (!await launcher(url)) {
        throw GoogleAuthException('Impossible d\'ouvrir le navigateur du système.');
      }
      final code = await _waitForCode(server, state).timeout(loginTimeout, onTimeout: () {
        throw GoogleAuthException('Délai dépassé : aucune autorisation reçue du navigateur.');
      });
      // Le code arrive souvent alors que le navigateur est encore au premier plan.
      await waitForForeground?.call();
      final tokens = await _postToken({
        'grant_type': 'authorization_code',
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'client_id': config.clientId,
        'client_secret': config.clientSecret,
      });
      final refresh = tokens['refresh_token'] as String?;
      try {
        checkGrantedScopes(tokens);
      } on GoogleAuthException {
        // Autorisation partielle inutilisable : on la révoque au lieu de la garder.
        if (refresh != null) {
          try {
            await _http.post(Uri.parse(endpoints.revoke), body: {'token': refresh});
          } catch (_) {}
        }
        rethrow;
      }
      if (refresh == null) {
        throw GoogleAuthException('Google n\'a pas fourni de jeton de rafraîchissement.');
      }
      _applyAccess(tokens);
      await secrets.write(SecretKeys.refreshToken, refresh);
      final email = await _fetchEmail();
      _email = email;
      await secrets.write(SecretKeys.accountEmail, email);
      return email;
    } finally {
      await server.close(force: true);
      if (identical(_pendingServer, server)) _pendingServer = null;
    }
  }

  Future<String> _waitForCode(HttpServer server, String expectedState) async {
    await for (final req in server) {
      final q = req.uri.queryParameters;
      if (req.uri.path != '/' || (!q.containsKey('code') && !q.containsKey('error'))) {
        req.response.statusCode = 404;
        await req.response.close();
        continue;
      }
      final error = q['error'];
      final ok = error == null && q['state'] == expectedState && q['code'] != null;
      req.response.headers.contentType = ContentType.html;
      req.response.write(_page(ok
          ? 'Autorisation reçue. Vous pouvez fermer cet onglet et revenir dans BDDouilleur.'
          : 'Autorisation refusée ou invalide. Revenez dans BDDouilleur.'));
      await req.response.close();
      if (error != null) {
        throw GoogleAuthException(error == 'access_denied'
            ? 'Vous avez refusé l\'autorisation dans le navigateur.'
            : 'Google a renvoyé l\'erreur « $error ».');
      }
      if (q['state'] != expectedState) {
        throw GoogleAuthException('Réponse d\'autorisation rejetée : paramètre « state » incorrect.');
      }
      return q['code']!;
    }
    throw GoogleAuthException('Connexion annulée.');
  }

  static String _page(String msg) => '<!doctype html><html lang="fr"><meta charset="utf-8">'
      '<title>BDDouilleur</title><body style="font-family:sans-serif;background:#10172A;color:#fff;'
      'display:flex;align-items:center;justify-content:center;height:100vh;margin:0">'
      '<div style="max-width:420px;text-align:center"><h1 style="color:#20D6C7">BDDouilleur</h1>'
      '<p>${const HtmlEscape().convert(msg)}</p></div></body></html>';

  Future<Map<String, dynamic>> _postToken(Map<String, String> body) async {
    final res = await _withRetry(() => _http.post(Uri.parse(endpoints.token), body: body));
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw GoogleAuthException('Réponse inattendue du serveur de jetons (HTTP ${res.statusCode}).');
    }
    if (res.statusCode != 200) {
      final err = json['error'];
      if (err == 'invalid_grant') {
        throw GoogleAuthException('Autorisation expirée ou révoquée. Reconnectez votre compte Google.');
      }
      if (err == 'invalid_client') {
        throw GoogleAuthException('Identifiant ou secret client OAuth refusé par Google. Vérifiez la configuration.');
      }
      throw GoogleAuthException('Échec de l\'obtention du jeton : ${json['error_description'] ?? err ?? res.statusCode}.');
    }
    return json;
  }

  void _applyAccess(Map<String, dynamic> tokens) {
    _accessToken = tokens['access_token'] as String?;
    final expires = (tokens['expires_in'] as num?)?.toInt() ?? 3600;
    _accessExpiry = DateTime.now().add(Duration(seconds: expires - 60));
  }

  Future<String> _fetchEmail() async {
    final res = await _withRetry(
        () => _http.get(Uri.parse(endpoints.userInfo), headers: {'Authorization': 'Bearer $_accessToken'}));
    if (res.statusCode != 200) throw GoogleAuthException('Impossible de lire le profil du compte (HTTP ${res.statusCode}).');
    final email = (jsonDecode(res.body) as Map<String, dynamic>)['email'] as String?;
    if (email == null) throw GoogleAuthException('Le profil Google ne contient pas d\'adresse e-mail.');
    return email;
  }

  /// Jeton d'accès valide (rafraîchi si nécessaire).
  Future<String> accessToken() async {
    if (_accessToken != null && _accessExpiry != null && DateTime.now().isBefore(_accessExpiry!)) {
      return _accessToken!;
    }
    final refresh = await secrets.read(SecretKeys.refreshToken);
    final config = await clientConfig();
    if (refresh == null || config == null) {
      throw GoogleAuthException('Aucun compte Google connecté.');
    }
    final tokens = await _postToken({
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
      'client_id': config.clientId,
      'client_secret': config.clientSecret,
    });
    checkGrantedScopes(tokens);
    _applyAccess(tokens);
    return _accessToken!;
  }

  /// Déconnecte et révoque l'autorisation auprès de Google.
  /// Renvoie `false` si la révocation distante a échoué (le jeton local est
  /// effacé dans tous les cas).
  Future<bool> signOut() async {
    final refresh = await secrets.read(SecretKeys.refreshToken);
    var revoked = true;
    if (refresh != null) {
      try {
        final res = await _http.post(Uri.parse(endpoints.revoke), body: {'token': refresh});
        revoked = res.statusCode == 200;
      } catch (_) {
        revoked = false;
      }
    }
    await secrets.delete(SecretKeys.refreshToken);
    await secrets.delete(SecretKeys.accountEmail);
    _accessToken = null;
    _accessExpiry = null;
    _email = null;
    return revoked;
  }
}
