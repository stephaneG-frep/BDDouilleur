import 'dart:convert';

import '../google/google_api.dart';

/// Points d'accès des API officielles Google Cloud et Firebase.
abstract final class GoogleEndpoints {
  static const resourceManager = 'https://cloudresourcemanager.googleapis.com';
  static const firebase = 'https://firebase.googleapis.com';
  static const serviceUsage = 'https://serviceusage.googleapis.com';
  static const billing = 'https://cloudbilling.googleapis.com';
  static const firestore = 'https://firestore.googleapis.com';
  static const rules = 'https://firebaserules.googleapis.com';
  static const identityToolkit = 'https://identitytoolkit.googleapis.com';
  static const secureToken = 'https://securetoken.googleapis.com';
}

/// Services Google nécessaires à BDDouilleur sur un projet Firebase.
enum FirebaseService {
  firestore('firestore.googleapis.com', 'Cloud Firestore'),
  rules('firebaserules.googleapis.com', 'Firebase Rules'),
  auth('identitytoolkit.googleapis.com', 'Firebase Authentication');

  const FirebaseService(this.id, this.label);
  final String id;
  final String label;
}

class FirebaseProjectInfo {
  const FirebaseProjectInfo({
    required this.projectId,
    required this.displayName,
    this.projectNumber,
    this.storageBucket,
    this.locationId,
    this.state,
  });

  final String projectId;
  final String displayName;
  final String? projectNumber;
  final String? storageBucket;
  final String? locationId;
  final String? state;

  factory FirebaseProjectInfo.fromJson(Map<String, dynamic> j) {
    final res = (j['resources'] as Map?) ?? const {};
    return FirebaseProjectInfo(
      projectId: j['projectId'] as String,
      displayName: (j['displayName'] as String?) ?? j['projectId'] as String,
      projectNumber: j['projectNumber'] as String?,
      storageBucket: res['storageBucket'] as String?,
      locationId: res['locationId'] as String?,
      state: j['state'] as String?,
    );
  }
}

class GcpProjectInfo {
  const GcpProjectInfo({required this.projectId, required this.displayName});
  final String projectId;
  final String displayName;
}

class AndroidAppInfo {
  const AndroidAppInfo({required this.name, required this.appId, required this.packageName, this.displayName});
  final String name;
  final String appId;
  final String packageName;
  final String? displayName;

  factory AndroidAppInfo.fromJson(Map<String, dynamic> j) => AndroidAppInfo(
        name: j['name'] as String,
        appId: j['appId'] as String,
        packageName: j['packageName'] as String,
        displayName: j['displayName'] as String?,
      );
}

/// Gestion des projets via les API Cloud Resource Manager, Firebase
/// Management, Service Usage et Cloud Billing. Toutes les réponses sont
/// celles des serveurs Google : rien n'est supposé.
class FirebaseManagementService {
  FirebaseManagementService(this.api);
  final GoogleApiClient api;

  static const _rm = GoogleEndpoints.resourceManager;
  static const _fb = '${GoogleEndpoints.firebase}/v1beta1';
  static const _su = GoogleEndpoints.serviceUsage;

  /// Règle des identifiants de projet Google Cloud.
  static String? validateProjectId(String v) {
    final s = v.trim();
    if (!RegExp(r'^[a-z][a-z0-9-]{4,28}[a-z0-9]$').hasMatch(s)) {
      return '6 à 30 caractères : minuscules, chiffres et tirets, commence par une lettre, ne finit pas par un tiret.';
    }
    if (s.contains('google') || s.contains('null') || s.contains('undefined') || s.contains('ssl')) {
      return 'Google refuse les identifiants contenant « google », « null », « undefined » ou « ssl ».';
    }
    return null;
  }

  static String? validatePackageName(String v) {
    final s = v.trim();
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$').hasMatch(s)) {
      return 'Nom de paquet Android attendu, par exemple fr.monentreprise.monapp';
    }
    return null;
  }

  Future<List<FirebaseProjectInfo>> listFirebaseProjects() async {
    final out = <FirebaseProjectInfo>[];
    String? token;
    do {
      final r = await api.get('$_fb/projects', query: {'pageSize': '100', 'pageToken': ?token});
      for (final p in (r['results'] as List?) ?? const []) {
        out.add(FirebaseProjectInfo.fromJson(p as Map<String, dynamic>));
      }
      token = r['nextPageToken'] as String?;
    } while (token != null && token.isNotEmpty);
    return out;
  }

  /// Projets Google Cloud auxquels Firebase peut être ajouté.
  Future<List<GcpProjectInfo>> listAvailableProjects() async {
    final r = await api.get('$_fb/availableProjects', query: {'pageSize': '100'});
    return [
      for (final p in (r['projectInfo'] as List?) ?? const [])
        GcpProjectInfo(
          projectId: (p['project'] as String).replaceFirst('projects/', ''),
          displayName: (p['displayName'] as String?) ?? (p['project'] as String),
        ),
    ];
  }

  /// Projet Firebase, ou `null` s'il n'existe pas (ou si Firebase n'y est
  /// pas encore ajouté).
  Future<FirebaseProjectInfo?> getFirebaseProject(String projectId) async {
    try {
      return FirebaseProjectInfo.fromJson(await api.get('$_fb/projects/$projectId'));
    } on GoogleApiException catch (e) {
      if (e.isNotFound) return null;
      // Firebase répond 403 pour un projet existant sans Firebase ou inaccessible.
      if (e.isPermissionDenied && !e.isServiceDisabled) return null;
      rethrow;
    }
  }

  /// État du projet Google Cloud : `null` s'il est introuvable ou inaccessible.
  Future<String?> gcpProjectState(String projectId) async {
    try {
      final r = await api.get('$_rm/v1/projects/$projectId');
      return r['lifecycleState'] as String? ?? 'ACTIVE';
    } on GoogleApiException catch (e) {
      if (e.isNotFound || (e.isPermissionDenied && !e.isServiceDisabled)) return null;
      rethrow;
    }
  }

  /// Vérifie les permissions IAM du compte connecté sur le projet.
  /// Renvoie celles qui sont accordées.
  Future<Set<String>> testPermissions(String projectId, List<String> permissions) async {
    final r = await api.post('$_rm/v1/projects/$projectId:testIamPermissions', body: {'permissions': permissions});
    return {for (final p in (r['permissions'] as List?) ?? const []) p as String};
  }

  /// Crée un projet Google Cloud (sans organisation parente).
  Future<void> createGcpProject(String projectId, String displayName) async {
    final op = await api.post('$_rm/v3/projects', body: {'projectId': projectId, 'displayName': displayName});
    await api.waitOperation('$_rm/v3', op);
  }

  Future<FirebaseProjectInfo> addFirebase(String projectId) async {
    final op = await api.post('$_fb/projects/$projectId:addFirebase', body: {});
    await api.waitOperation(_fb, op);
    final p = await getFirebaseProject(projectId);
    if (p == null) {
      throw GoogleApiException(statusCode: 0, status: 'UNKNOWN', message: 'Firebase introuvable après ajout');
    }
    return p;
  }

  Future<List<AndroidAppInfo>> listAndroidApps(String projectId) async {
    final r = await api.get('$_fb/projects/$projectId/androidApps', query: {'pageSize': '100'});
    return [for (final a in (r['apps'] as List?) ?? const []) AndroidAppInfo.fromJson(a as Map<String, dynamic>)];
  }

  Future<AndroidAppInfo> createAndroidApp(String projectId, String packageName, String displayName) async {
    final op = await api.post('$_fb/projects/$projectId/androidApps',
        body: {'packageName': packageName, 'displayName': displayName});
    final res = await api.waitOperation(_fb, op);
    return AndroidAppInfo.fromJson(res);
  }

  /// Contenu réel de google-services.json fourni par Firebase.
  Future<String> androidConfigFile(String projectId, String appId) async {
    final r = await api.get('$_fb/projects/$projectId/androidApps/$appId/config');
    return utf8.decode(base64Decode(r['configFileContents'] as String));
  }

  Future<Set<String>> enabledServices(String projectId) async {
    final out = <String>{};
    String? token;
    do {
      final r = await api.get('$_su/v1/projects/$projectId/services',
          query: {'filter': 'state:ENABLED', 'pageSize': '200', 'pageToken': ?token});
      for (final s in (r['services'] as List?) ?? const []) {
        out.add(((s['config'] as Map?)?['name'] as String?) ?? (s['name'] as String).split('/').last);
      }
      token = r['nextPageToken'] as String?;
    } while (token != null && token.isNotEmpty);
    return out;
  }

  Future<void> enableService(String projectId, String service) async {
    final op = await api.post('$_su/v1/projects/$projectId/services/$service:enable', body: {});
    await api.waitOperation('$_su/v1', op);
  }

  /// `true`/`false` selon Cloud Billing, `null` si l'information n'est pas lisible.
  Future<bool?> billingEnabled(String projectId) async {
    try {
      final r = await api.get('${GoogleEndpoints.billing}/v1/projects/$projectId/billingInfo');
      return r['billingEnabled'] == true;
    } on GoogleApiException {
      return null;
    }
  }
}
