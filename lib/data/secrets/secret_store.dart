import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stockage des secrets (jetons OAuth, identifiants client), séparé de la base
/// interne. Les secrets ne sont jamais écrits dans le journal ni dans la base
/// SQLite de l'application.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Trousseau du système : libsecret (GNOME Keyring) sous Linux,
/// Android Keystore sous Android.
class SystemSecretStore implements SecretStore {
  SystemSecretStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  static const _prefix = 'bddouilleur.';

  @override
  Future<String?> read(String key) => _storage.read(key: '$_prefix$key');

  @override
  Future<void> write(String key, String value) => _storage.write(key: '$_prefix$key', value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: '$_prefix$key');
}

/// Stockage en mémoire, pour les tests uniquement.
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Clés utilisées dans le stockage sécurisé.
abstract final class SecretKeys {
  static const oauthClientId = 'google.oauth.client_id';
  static const oauthClientSecret = 'google.oauth.client_secret';
  static const refreshToken = 'google.oauth.refresh_token';
  static const accountEmail = 'google.account.email';
}
