import 'dart:convert';
import 'dart:io';

import 'package:bddouilleur/data/google/google_auth.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Faux serveur OAuth de Google + navigateur simulé : vérifie le parcours
/// RFC 8252 (loopback + PKCE) de bout en bout, sans réseau.
void main() {
  late MemorySecretStore secrets;
  late List<http.Request> requests;
  String? lastChallenge;

  MockClient fakeGoogle({String? tokenError, String scope = 'openid email https://www.googleapis.com/auth/cloud-platform'}) =>
      MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/token') {
          final body = Uri.splitQueryString(req.body);
          if (tokenError != null) return http.Response(jsonEncode({'error': tokenError}), 400);
          if (body['grant_type'] == 'authorization_code') {
            final expected = GoogleAuthService.codeChallenge(body['code_verifier']!);
            if (expected != lastChallenge || body['code'] != 'CODE123') {
              return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
            }
            return http.Response(
                jsonEncode({'access_token': 'AT1', 'refresh_token': 'RT1', 'expires_in': 3600, 'scope': scope}), 200);
          }
          if (body['grant_type'] == 'refresh_token' && body['refresh_token'] == 'RT1') {
            return http.Response(jsonEncode({'access_token': 'AT2', 'expires_in': 3600}), 200);
          }
          return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
        }
        if (req.url.path == '/userinfo') {
          expect(req.headers['Authorization'], 'Bearer AT1');
          return http.Response(jsonEncode({'email': 'testeur@example.com'}), 200);
        }
        if (req.url.path == '/revoke') return http.Response('', 200);
        return http.Response('not found', 404);
      });

  const endpoints = GoogleOAuthEndpoints(
    authorize: 'https://fake.test/auth',
    token: 'https://fake.test/token',
    revoke: 'https://fake.test/revoke',
    userInfo: 'https://fake.test/userinfo',
  );

  /// Navigateur simulé : l'utilisateur « autorise », Google redirige vers le loopback.
  BrowserLauncher browser({String? overrideState, String? error}) => (url) async {
        final q = url.queryParameters;
        expect(q['code_challenge_method'], 'S256');
        expect(q['response_type'], 'code');
        expect(q['scope'], contains('https://www.googleapis.com/auth/cloud-platform'));
        expect(q['redirect_uri'], startsWith('http://127.0.0.1:'));
        lastChallenge = q['code_challenge'];
        final redirect = Uri.parse(q['redirect_uri']!).replace(queryParameters: {
          if (error == null) 'code': 'CODE123',
          'error': ?error,
          'state': overrideState ?? q['state']!,
        });
        // La redirection est suivie de façon asynchrone, comme un vrai navigateur.
        Future(() async {
          final c = HttpClient();
          final r = await (await c.getUrl(redirect)).close();
          await r.drain<void>();
          c.close();
        });
        return true;
      };

  setUp(() {
    secrets = MemorySecretStore();
    requests = [];
    lastChallenge = null;
  });

  Future<GoogleAuthService> service(BrowserLauncher launcher, {String? tokenError, String? scope}) async {
    final s = GoogleAuthService(
        secrets: secrets,
        launcher: launcher,
        client: scope == null ? fakeGoogle(tokenError: tokenError) : fakeGoogle(tokenError: tokenError, scope: scope),
        endpoints: endpoints);
    await s.saveClientConfig(
        const OAuthClientConfig(clientId: '123-abc.apps.googleusercontent.com', clientSecret: 'secret'));
    return s;
  }

  test('format de l\'identifiant client', () {
    expect(OAuthClientConfig.validateClientId('123-abc.apps.googleusercontent.com'), isNull);
    expect(OAuthClientConfig.validateClientId('n importe quoi'), isNotNull);
  });

  test('parcours complet : consentement, PKCE, jetons rangés, rafraîchissement, déconnexion', () async {
    final auth = await service(browser());
    final email = await auth.signIn();
    expect(email, 'testeur@example.com');
    expect(secrets.values[SecretKeys.refreshToken], 'RT1');
    expect(await auth.isSignedIn, isTrue);
    expect(await auth.accessToken(), 'AT1');

    // Nouvelle instance (redémarrage) : rafraîchissement depuis le trousseau.
    final again = GoogleAuthService(secrets: secrets, launcher: browser(), client: fakeGoogle(), endpoints: endpoints);
    await again.load();
    expect(again.email, 'testeur@example.com');
    expect(await again.accessToken(), 'AT2');

    expect(await again.signOut(), isTrue);
    expect(secrets.values.containsKey(SecretKeys.refreshToken), isFalse);
    expect(requests.last.url.path, '/revoke');
    await expectLater(again.accessToken(), throwsA(isA<GoogleAuthException>()));
  });

  test('state falsifié : réponse rejetée, aucun jeton demandé', () async {
    final auth = await service(browser(overrideState: 'pirate'));
    await expectLater(auth.signIn(), throwsA(isA<GoogleAuthException>()));
    expect(requests.where((r) => r.url.path == '/token'), isEmpty);
    expect(secrets.values.containsKey(SecretKeys.refreshToken), isFalse);
  });

  test('refus de l\'utilisateur', () async {
    final auth = await service(browser(error: 'access_denied'));
    await expectLater(
        auth.signIn(), throwsA(isA<GoogleAuthException>().having((e) => e.message, 'message', contains('refusé'))));
  });

  test('client OAuth refusé par Google', () async {
    final auth = await service(browser(), tokenError: 'invalid_client');
    await expectLater(
        auth.signIn(), throwsA(isA<GoogleAuthException>().having((e) => e.message, 'message', contains('client'))));
  });

  test('sans client configuré : message clair', () async {
    final auth = GoogleAuthService(secrets: secrets, launcher: browser(), client: fakeGoogle(), endpoints: endpoints);
    await expectLater(auth.signIn(), throwsA(isA<GoogleAuthException>()));
  });

  test('consentement partiel (case Google Cloud non cochée) : refusé, révoqué, rien de stocké', () async {
    final auth = await service(browser(), scope: 'openid email');
    await expectLater(auth.signIn(),
        throwsA(isA<GoogleAuthException>().having((e) => e.message, 'message', contains('cochez TOUTES les cases'))));
    expect(secrets.values.containsKey(SecretKeys.refreshToken), isFalse);
    expect(requests.last.url.path, '/revoke');
  });

  test('réseau coupé au retour du navigateur : attente du premier plan puis nouvelles tentatives', () async {
    var failures = 2;
    var waited = false;
    final inner = fakeGoogle();
    final flaky = MockClient((req) async {
      if (req.url.path == '/token' && failures > 0) {
        failures--;
        throw const SocketException("Failed host lookup: 'oauth2.googleapis.com'");
      }
      final copy = http.Request(req.method, req.url)
        ..headers.addAll(req.headers)
        ..body = req.body;
      return inner.send(copy).then(http.Response.fromStream);
    });
    final auth = GoogleAuthService(
      secrets: secrets,
      launcher: browser(),
      client: flaky,
      endpoints: endpoints,
      waitForForeground: () async => waited = true,
      networkRetryDelays: const [Duration.zero, Duration.zero, Duration.zero],
    );
    await auth.saveClientConfig(
        const OAuthClientConfig(clientId: '123-abc.apps.googleusercontent.com', clientSecret: 'secret'));
    expect(await auth.signIn(), 'testeur@example.com');
    expect(waited, isTrue);
    expect(failures, 0);
  });

  test('réseau définitivement coupé : message clair en français', () async {
    final auth = GoogleAuthService(
      secrets: secrets,
      launcher: browser(),
      client: MockClient((req) async {
        if (req.url.path == '/token') throw const SocketException('Failed host lookup');
        return http.Response('', 404);
      }),
      endpoints: endpoints,
      networkRetryDelays: const [Duration.zero],
    );
    await auth.saveClientConfig(
        const OAuthClientConfig(clientId: '123-abc.apps.googleusercontent.com', clientSecret: 'secret'));
    await expectLater(
        auth.signIn(), throwsA(isA<GoogleAuthException>().having((e) => e.message, 'message', contains('Réseau injoignable'))));
  });
}
