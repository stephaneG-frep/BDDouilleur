/// Où se trouve le projet Firebase d'une connexion.
enum FirebaseMode {
  /// Suite d'émulateurs locale (environnement de test, aucune facturation).
  emulator('Émulateur local'),

  /// Vrai projet Google, via le compte connecté en OAuth.
  google('Projet Google');

  const FirebaseMode(this.label);
  final String label;
}

/// Configuration non sensible d'une connexion Firebase (stockée dans la base
/// interne, colonne `config`). Aucun jeton ni clé n'y figure.
class FirebaseTarget {
  const FirebaseTarget({
    required this.mode,
    required this.projectId,
    this.databaseId = '(default)',
    this.firestoreHost = '127.0.0.1:8080',
    this.authHost = '127.0.0.1:9099',
    this.lastRules,
  });

  final FirebaseMode mode;
  final String projectId;
  final String databaseId;

  /// Hôtes de l'émulateur (mode émulateur uniquement).
  final String firestoreHost;
  final String authHost;

  /// Dernières règles déployées sur l'émulateur par BDDouilleur (l'émulateur
  /// n'expose pas de lecture des règles en cours).
  final String? lastRules;

  bool get isEmulator => mode == FirebaseMode.emulator;

  String get databaseRoot => 'projects/$projectId/databases/$databaseId';

  String get firestoreBase =>
      isEmulator ? 'http://$firestoreHost/v1' : 'https://firestore.googleapis.com/v1';

  String get documentsRoot => '$firestoreBase/$databaseRoot/documents';

  /// Racine des API Identity Toolkit / Secure Token (émulateur ou Google).
  String identityToolkitBase() => isEmulator
      ? 'http://$authHost/identitytoolkit.googleapis.com'
      : 'https://identitytoolkit.googleapis.com';

  String secureTokenBase() =>
      isEmulator ? 'http://$authHost/securetoken.googleapis.com' : 'https://securetoken.googleapis.com';

  /// Les projets d'émulateur sans vrai projet doivent commencer par « demo- »
  /// pour qu'aucun appel ne parte vers Google.
  static String? validateEmulatorProjectId(String v) {
    final s = v.trim();
    if (!RegExp(r'^demo-[a-z0-9-]{1,25}$').hasMatch(s)) {
      return 'Identifiant de démonstration attendu : demo-… (minuscules, chiffres, tirets).';
    }
    return null;
  }

  static String? validateHost(String v) {
    final s = v.trim();
    final m = RegExp(r'^([A-Za-z0-9.\-]+):(\d{2,5})$').firstMatch(s);
    if (m == null) return 'Format attendu : hôte:port (ex. 127.0.0.1:8080)';
    final port = int.parse(m.group(2)!);
    if (port < 1 || port > 65535) return 'Port invalide.';
    return null;
  }

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'projectId': projectId,
        'databaseId': databaseId,
        if (isEmulator) 'firestoreHost': firestoreHost,
        if (isEmulator) 'authHost': authHost,
        'lastRules': ?lastRules,
      };

  factory FirebaseTarget.fromJson(Map<String, Object?> j) => FirebaseTarget(
        mode: j['mode'] == 'google' ? FirebaseMode.google : FirebaseMode.emulator,
        projectId: j['projectId'] as String,
        databaseId: (j['databaseId'] as String?) ?? '(default)',
        firestoreHost: (j['firestoreHost'] as String?) ?? '127.0.0.1:8080',
        authHost: (j['authHost'] as String?) ?? '127.0.0.1:9099',
        lastRules: j['lastRules'] as String?,
      );

  FirebaseTarget copyWith({String? lastRules}) => FirebaseTarget(
        mode: mode,
        projectId: projectId,
        databaseId: databaseId,
        firestoreHost: firestoreHost,
        authHost: authHost,
        lastRules: lastRules ?? this.lastRules,
      );

  String get description => isEmulator
      ? 'Émulateur $firestoreHost • $projectId'
      : '$projectId • base $databaseId';
}
