import 'dart:math';

import '../../domain/firebase/firebase_target.dart';
import '../google/google_api.dart';
import 'firebase_management.dart';

class AuthConfigInfo {
  const AuthConfigInfo({
    required this.emailEnabled,
    required this.passwordRequired,
    required this.anonymousEnabled,
    required this.emailEnumerationProtection,
    required this.authorizedDomains,
  });

  final bool emailEnabled;
  final bool passwordRequired;
  final bool anonymousEnabled;
  final bool emailEnumerationProtection;
  final List<String> authorizedDomains;

  factory AuthConfigInfo.fromJson(Map<String, dynamic> j) {
    final signIn = (j['signIn'] as Map?) ?? const {};
    final email = (signIn['email'] as Map?) ?? const {};
    return AuthConfigInfo(
      emailEnabled: email['enabled'] == true,
      passwordRequired: email['passwordRequired'] == true,
      anonymousEnabled: ((signIn['anonymous'] as Map?)?['enabled']) == true,
      emailEnumerationProtection: ((j['emailPrivacyConfig'] as Map?)?['enableImprovedEmailPrivacy']) == true,
      authorizedDomains: ((j['authorizedDomains'] as List?) ?? const []).cast<String>(),
    );
  }
}

/// Configuration de Firebase Authentication (API Identity Toolkit admin v2),
/// sur un vrai projet uniquement.
class AuthAdminService {
  AuthAdminService(this.api, this.projectId);
  final GoogleApiClient api;
  final String projectId;

  String get _config => '${GoogleEndpoints.identityToolkit}/admin/v2/projects/$projectId/config';

  /// `null` si Authentication n'a jamais été initialisé sur le projet (le
  /// bouton « Commencer » de la console Firebase doit alors être utilisé).
  Future<AuthConfigInfo?> getConfig() async {
    try {
      return AuthConfigInfo.fromJson(await api.get(_config));
    } on GoogleApiException catch (e) {
      if (e.isNotFound || e.message.contains('CONFIGURATION_NOT_FOUND')) return null;
      rethrow;
    }
  }

  Future<AuthConfigInfo> enableEmailPassword({required bool enumerationProtection}) async {
    final r = await api.patch(_config, query: {
      'updateMask': 'signIn.email.enabled,signIn.email.passwordRequired,emailPrivacyConfig.enableImprovedEmailPrivacy',
    }, body: {
      'signIn': {
        'email': {'enabled': true, 'passwordRequired': true}
      },
      'emailPrivacyConfig': {'enableImprovedEmailPrivacy': enumerationProtection},
    });
    return AuthConfigInfo.fromJson(r);
  }

  static String consoleUrl(String projectId) =>
      'https://console.firebase.google.com/project/$projectId/authentication/providers';
}

/// Une étape du parcours de test d'authentification.
class AuthTestStep {
  const AuthTestStep(this.label, {required this.ok, this.detail});
  final String label;
  final bool ok;
  final String? detail;
}

/// Parcours de test réels de Firebase Authentication (API REST publique
/// Identity Toolkit v1), sur l'émulateur ou sur un vrai projet.
///
/// Sur un vrai projet, le compte de test est supprimé à la fin du parcours.
class AuthFlowTester {
  AuthFlowTester({required this.target, required this.apiKey, required this.api});
  final FirebaseTarget target;

  /// Clé d'API Web/Android du projet (« fake-api-key » pour l'émulateur).
  final String apiKey;

  /// Client sans en-tête d'autorisation.
  final GoogleApiClient api;

  String get _v1 => '${target.identityToolkitBase()}/v1';
  Map<String, String> get _key => {'key': apiKey};

  static String randomTestEmail() {
    final r = Random.secure();
    final id = List.generate(10, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[r.nextInt(36)]).join();
    return 'bdd-test-$id@bddouilleur.test';
  }

  static String randomPassword() {
    final r = Random.secure();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
    return '${List.generate(16, (_) => chars[r.nextInt(chars.length)]).join()}!9a';
  }

  /// Codes hors bande (vérification, réinitialisation) : l'émulateur les
  /// expose au lieu d'envoyer des e-mails.
  Future<String?> _emulatorOobCode(String email, String requestType) async {
    final r = await api.get('http://${target.authHost}/emulator/v1/projects/${target.projectId}/oobCodes');
    final codes = ((r['oobCodes'] as List?) ?? const [])
        .cast<Map>()
        .where((c) => c['email'] == email && c['requestType'] == requestType)
        .toList();
    return codes.isEmpty ? null : codes.last['oobCode'] as String?;
  }

  Future<List<AuthTestStep>> run() async {
    final steps = <AuthTestStep>[];
    final email = randomTestEmail();
    var password = randomPassword();
    String? idToken;
    String? refreshToken;

    Future<bool> step(String label, Future<String?> Function() body) async {
      try {
        final detail = await body();
        steps.add(AuthTestStep(label, ok: true, detail: detail));
        return true;
      } catch (e) {
        steps.add(AuthTestStep(label, ok: false, detail: e is GoogleApiException ? e.message : '$e'));
        return false;
      }
    }

    try {
      if (!await step('Inscription e-mail / mot de passe ($email)', () async {
        final r = await api.post('$_v1/accounts:signUp',
            query: _key, body: {'email': email, 'password': password, 'returnSecureToken': true});
        idToken = r['idToken'] as String?;
        refreshToken = r['refreshToken'] as String?;
        return 'Compte créé, uid ${r['localId']}';
      })) {
        return steps;
      }

      await step('Refus d\'un mauvais mot de passe', () async {
        try {
          await api.post('$_v1/accounts:signInWithPassword',
              query: _key, body: {'email': email, 'password': 'mauvais-$password', 'returnSecureToken': true});
        } on GoogleApiException catch (e) {
          return 'Refusé comme attendu (${e.message.split(' ').first})';
        }
        throw StateError('Connexion acceptée avec un mauvais mot de passe !');
      });

      await step('Connexion avec le bon mot de passe', () async {
        final r = await api.post('$_v1/accounts:signInWithPassword',
            query: _key, body: {'email': email, 'password': password, 'returnSecureToken': true});
        idToken = r['idToken'] as String?;
        refreshToken = r['refreshToken'] as String?;
        return 'Session ouverte';
      });

      await step('Renouvellement de session (jeton de rafraîchissement)', () async {
        final r = await api.post('${target.secureTokenBase()}/v1/token',
            query: _key, body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken});
        final newToken = (r['id_token'] ?? r['idToken']) as String?;
        if (newToken == null) throw StateError('Aucun nouveau jeton reçu');
        idToken = newToken;
        return 'Nouveau jeton d\'identité obtenu';
      });

      await step('Envoi de l\'e-mail de vérification', () async {
        await api.post('$_v1/accounts:sendOobCode', query: _key, body: {'requestType': 'VERIFY_EMAIL', 'idToken': idToken});
        return target.isEmulator
            ? 'Demande acceptée (l\'émulateur conserve le lien au lieu d\'envoyer un e-mail)'
            : 'Demande acceptée par Firebase (adresse fictive : aucun e-mail ne sera reçu)';
      });

      if (target.isEmulator) {
        await step('Validation de l\'adresse avec le code reçu', () async {
          final code = await _emulatorOobCode(email, 'VERIFY_EMAIL');
          if (code == null) throw StateError('Aucun code de vérification trouvé');
          await api.post('$_v1/accounts:update', query: _key, body: {'oobCode': code});
          final r = await api.post('$_v1/accounts:lookup', query: _key, body: {'idToken': idToken});
          final verified = ((r['users'] as List).first as Map)['emailVerified'] == true;
          if (!verified) throw StateError('L\'adresse n\'est pas marquée comme vérifiée');
          return 'emailVerified = true';
        });
      }

      await step('Demande de réinitialisation du mot de passe', () async {
        await api.post('$_v1/accounts:sendOobCode', query: _key, body: {'requestType': 'PASSWORD_RESET', 'email': email});
        return 'Demande acceptée';
      });

      if (target.isEmulator) {
        await step('Réinitialisation avec le code reçu, puis connexion', () async {
          final code = await _emulatorOobCode(email, 'PASSWORD_RESET');
          if (code == null) throw StateError('Aucun code de réinitialisation trouvé');
          final newPassword = randomPassword();
          await api.post('$_v1/accounts:resetPassword', query: _key, body: {'oobCode': code, 'newPassword': newPassword});
          password = newPassword;
          final r = await api.post('$_v1/accounts:signInWithPassword',
              query: _key, body: {'email': email, 'password': newPassword, 'returnSecureToken': true});
          idToken = r['idToken'] as String?;
          return 'Connexion réussie avec le nouveau mot de passe';
        });
      }
    } finally {
      if (idToken != null) {
        await step('Suppression du compte de test', () async {
          await api.post('$_v1/accounts:delete', query: _key, body: {'idToken': idToken});
          return 'Compte supprimé';
        });
      }
    }
    return steps;
  }
}
