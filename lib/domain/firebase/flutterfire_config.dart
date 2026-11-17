import 'dart:convert';

/// Contenu utile d'un fichier google-services.json (fourni par Firebase).
class GoogleServicesConfig {
  const GoogleServicesConfig({
    required this.projectId,
    required this.projectNumber,
    required this.storageBucket,
    required this.clients,
  });

  final String projectId;
  final String projectNumber;
  final String? storageBucket;
  final List<GoogleServicesClient> clients;

  GoogleServicesClient? clientFor(String packageName) =>
      clients.where((c) => c.packageName == packageName).firstOrNull;

  static GoogleServicesConfig parse(String json) {
    final Object? root;
    try {
      root = jsonDecode(json);
    } catch (_) {
      throw const FormatException('google-services.json n\'est pas un JSON valide.');
    }
    if (root is! Map || root['project_info'] is! Map) {
      throw const FormatException('google-services.json : section project_info absente.');
    }
    final info = root['project_info'] as Map;
    final clients = <GoogleServicesClient>[];
    for (final c in (root['client'] as List?) ?? const []) {
      final ci = (c as Map)['client_info'] as Map?;
      final pkg = (ci?['android_client_info'] as Map?)?['package_name'] as String?;
      final appId = ci?['mobilesdk_app_id'] as String?;
      final keys = (c['api_key'] as List?) ?? const [];
      final key = keys.isEmpty ? null : (keys.first as Map)['current_key'] as String?;
      if (pkg != null && appId != null) {
        clients.add(GoogleServicesClient(packageName: pkg, appId: appId, apiKey: key));
      }
    }
    return GoogleServicesConfig(
      projectId: '${info['project_id']}',
      projectNumber: '${info['project_number']}',
      storageBucket: info['storage_bucket'] as String?,
      clients: clients,
    );
  }
}

class GoogleServicesClient {
  const GoogleServicesClient({required this.packageName, required this.appId, this.apiKey});
  final String packageName;
  final String appId;
  final String? apiKey;
}

/// Génère lib/firebase_options.dart au format de l'outil officiel
/// `flutterfire configure` (plateforme Android).
abstract final class FlutterFireGenerator {
  static String _q(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

  static String firebaseOptions(GoogleServicesConfig config, String packageName) {
    final client = config.clientFor(packageName);
    if (client == null) {
      throw FormatException('Aucune application Android « $packageName » dans la configuration Firebase.');
    }
    if (client.apiKey == null) throw const FormatException('Clé d\'API absente de la configuration Firebase.');
    return '''// Fichier généré par BDDouilleur au format FlutterFire.
// Source : configuration réelle de l'application Android « $packageName »
// du projet Firebase « ${config.projectId} ».
//
// Ces identifiants sont des identifiants CLIENT (publics par nature) : la
// protection des données repose sur les règles de sécurité et App Check.
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Firebase n\\'est pas configuré pour le Web dans ce projet.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError('Firebase n\\'est configuré que pour Android dans ce projet.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: ${_q(client.apiKey!)},
    appId: ${_q(client.appId)},
    messagingSenderId: ${_q(config.projectNumber)},
    projectId: ${_q(config.projectId)},${config.storageBucket == null ? '' : '\n    storageBucket: ${_q(config.storageBucket!)},'}
  );
}
''';
  }

  /// Extrait projectId d'un firebase_options.dart existant.
  static Set<String> projectIdsIn(String firebaseOptionsSource) => {
        for (final m in RegExp(r'''projectId:\s*['"]([^'"]+)['"]''').allMatches(firebaseOptionsSource)) m.group(1)!,
      };
}
