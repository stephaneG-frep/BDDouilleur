import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/firebase/firestore_rules.dart';
import '../../domain/firebase/flutterfire_config.dart';

enum DiagSeverity {
  error('Bloquant'),
  warning('À corriger'),
  info('Information'),
  ok('Conforme');

  const DiagSeverity(this.label);
  final String label;
}

/// Correction automatique proposée (toujours soumise à confirmation).
class DiagnosticFix {
  const DiagnosticFix({required this.label, required this.preview, required this.apply});
  final String label;

  /// Description exacte des fichiers modifiés.
  final String preview;

  /// Applique la correction et renvoie un compte rendu.
  final Future<String> Function() apply;
}

/// Un constat au format Problème — Cause — Solution — Risque — Correction — Vérification.
class DiagnosticFinding {
  const DiagnosticFinding({
    required this.severity,
    required this.problem,
    this.cause = '',
    this.solution = '',
    this.risk = '',
    this.correction = '',
    this.verification = '',
    this.fix,
  });

  final DiagSeverity severity;
  final String problem;
  final String cause;
  final String solution;
  final String risk;
  final String correction;
  final String verification;
  final DiagnosticFix? fix;
}

/// Fournit la configuration google-services.json réelle d'une application
/// Android depuis le projet Firebase connecté (ou `null` si absente).
typedef RemoteConfigProvider = Future<String?> Function(String packageName);

/// Firebase Rescue : diagnostic déterministe (sans IA) d'un projet Flutter
/// local. Chaque constat repose sur le contenu réel des fichiers.
class FlutterFirebaseDiagnostic {
  FlutterFirebaseDiagnostic(this.projectDir, {this.remoteConfig, this.expectedProjectId});

  final String projectDir;

  /// Disponible si un projet Firebase Google est connecté.
  final RemoteConfigProvider? remoteConfig;
  final String? expectedProjectId;

  File _f(String rel) => File(p.join(projectDir, rel));
  String? _read(String rel) {
    final f = _f(rel);
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  static const firebasePackages = [
    'firebase_core',
    'cloud_firestore',
    'firebase_auth',
    'firebase_storage',
    'firebase_messaging',
    'firebase_analytics',
    'firebase_crashlytics',
    'firebase_database',
    'cloud_functions',
    'firebase_app_check',
    'google_sign_in',
  ];

  /// Dépendances déclarées dans pubspec.yaml (analyse ligne à ligne de la
  /// section dependencies, suffisante pour ce diagnostic).
  static Map<String, String> declaredDependencies(String pubspec) {
    final deps = <String, String>{};
    var inDeps = false;
    for (final raw in pubspec.split('\n')) {
      final line = raw.replaceAll('\r', '');
      if (RegExp(r'^\S').hasMatch(line)) {
        inDeps = line.startsWith('dependencies:');
        continue;
      }
      if (!inDeps) continue;
      final m = RegExp(r'^  ([a-z0-9_]+):\s*(.*)$').firstMatch(line);
      if (m != null) deps[m.group(1)!] = m.group(2)!.trim();
    }
    return deps;
  }

  static String? applicationId(String gradle) =>
      RegExp(r'''applicationId\s*=?\s*["']([^"']+)["']''').firstMatch(gradle)?.group(1);

  static int? minSdk(String gradle) {
    final m = RegExp(r'minSdk(?:Version)?\s*=?\s*(\d+)').firstMatch(gradle);
    return m == null ? null : int.parse(m.group(1)!);
  }

  Future<List<DiagnosticFinding>> run() async {
    final out = <DiagnosticFinding>[];
    final pubspec = _read('pubspec.yaml');
    if (pubspec == null) {
      return [
        const DiagnosticFinding(
          severity: DiagSeverity.error,
          problem: 'Aucun pubspec.yaml dans ce dossier',
          cause: 'Le dossier choisi n\'est pas la racine d\'un projet Flutter.',
          solution: 'Choisissez le dossier qui contient pubspec.yaml.',
        ),
      ];
    }
    final deps = declaredDependencies(pubspec);
    if (!deps.containsKey('flutter')) {
      out.add(const DiagnosticFinding(
        severity: DiagSeverity.warning,
        problem: 'Projet Dart sans dépendance Flutter',
        cause: 'pubspec.yaml ne déclare pas « flutter: sdk: flutter ».',
        solution: 'Ce diagnostic vise les applications Flutter ; les résultats peuvent être incomplets.',
      ));
    }
    final used = firebasePackages.where(deps.containsKey).toList();
    if (used.isEmpty) {
      out.add(const DiagnosticFinding(
        severity: DiagSeverity.info,
        problem: 'Firebase n\'est pas utilisé par ce projet',
        cause: 'Aucun paquet FlutterFire (firebase_core, cloud_firestore, firebase_auth…) dans pubspec.yaml.',
        solution: 'Ajoutez les paquets nécessaires : flutter pub add firebase_core cloud_firestore firebase_auth',
        verification: 'Relancez le diagnostic après l\'ajout.',
      ));
      return out;
    }

    // --- Dépendances
    if (!deps.containsKey('firebase_core') && used.any((d) => d != 'google_sign_in')) {
      out.add(const DiagnosticFinding(
        severity: DiagSeverity.error,
        problem: 'firebase_core manquant',
        cause: 'Des paquets Firebase sont déclarés sans firebase_core, indispensable à l\'initialisation.',
        solution: 'Ajouter firebase_core aux dépendances.',
        risk: 'Aucun.',
        correction: 'flutter pub add firebase_core',
        verification: 'flutter pub get puis relancer le diagnostic.',
      ));
    }
    final loose = [for (final d in used) if (deps[d] == 'any' || deps[d]!.isEmpty) d];
    if (loose.isNotEmpty) {
      out.add(DiagnosticFinding(
        severity: DiagSeverity.warning,
        problem: 'Versions FlutterFire non contraintes : ${loose.join(', ')}',
        cause: 'Une contrainte « any » ou vide laisse pub mélanger des versions de paquets Firebase incompatibles entre elles.',
        solution: 'Fixer des contraintes ^x.y.z issues de la même série de versions FlutterFire.',
        risk: 'Faible : peut nécessiter une mise à jour du code si une version majeure change.',
        correction: 'flutter pub upgrade --major-versions ${loose.join(' ')}',
        verification: 'flutter pub get sans conflit, puis compilation.',
      ));
    }
    final lock = _f('pubspec.lock');
    if (!lock.existsSync()) {
      out.add(const DiagnosticFinding(
        severity: DiagSeverity.warning,
        problem: 'Dépendances non résolues (pubspec.lock absent)',
        cause: 'flutter pub get n\'a jamais été exécuté dans ce projet.',
        solution: 'Résoudre les dépendances.',
        correction: 'flutter pub get',
        verification: 'pubspec.lock est créé sans erreur de résolution.',
      ));
    } else if (lock.lastModifiedSync().isBefore(_f('pubspec.yaml').lastModifiedSync())) {
      out.add(const DiagnosticFinding(
        severity: DiagSeverity.info,
        problem: 'pubspec.lock plus ancien que pubspec.yaml',
        cause: 'Les dépendances ont été modifiées sans être résolues à nouveau.',
        correction: 'flutter pub get',
        verification: 'flutter pub get termine sans erreur.',
      ));
    }

    // --- firebase_options.dart et initialisation
    final options = _read('lib/firebase_options.dart');
    final gradle = _read('android/app/build.gradle.kts') ?? _read('android/app/build.gradle');
    final appId = gradle == null ? null : applicationId(gradle);
    final gsJson = _read('android/app/google-services.json');

    DiagnosticFix? generateFix;
    if (remoteConfig != null && appId != null) {
      generateFix = DiagnosticFix(
        label: 'Générer depuis le projet Firebase connecté',
        preview: 'Écrit (avec sauvegarde .bak si le fichier existe) :\n'
            '• android/app/google-services.json\n• lib/firebase_options.dart\n'
            'à partir de la configuration réelle de l\'application Android « $appId ».',
        apply: () async {
          final json = await remoteConfig!(appId);
          if (json == null) {
            throw StateError('Aucune application Android « $appId » dans le projet Firebase connecté. '
                'Enregistrez-la d\'abord (Firebase AutoPilot → Configuration).');
          }
          final cfg = GoogleServicesConfig.parse(json);
          final written = <String>[];
          for (final (rel, content) in [
            ('android/app/google-services.json', json),
            ('lib/firebase_options.dart', FlutterFireGenerator.firebaseOptions(cfg, appId)),
          ]) {
            written.add(writeWithBackup(p.join(projectDir, rel), content));
          }
          return written.join('\n');
        },
      );
    }

    if (options == null) {
      out.add(DiagnosticFinding(
        severity: DiagSeverity.error,
        problem: 'lib/firebase_options.dart introuvable',
        cause: 'Le projet n\'a pas été configuré avec FlutterFire : Firebase.initializeApp ne connaît pas le projet à utiliser.',
        solution: 'Générer le fichier à partir de la configuration réelle du projet Firebase.',
        risk: 'Aucun pour le code existant (nouveau fichier).',
        correction: generateFix != null
            ? 'Correction automatique disponible.'
            : 'Connectez un projet Firebase Google dans BDDouilleur pour la génération automatique, ou exécutez « flutterfire configure ».',
        verification: 'Le fichier existe et contient le bon projectId ; l\'application démarre sans erreur [core/no-app].',
        fix: generateFix,
      ));
    } else {
      final ids = FlutterFireGenerator.projectIdsIn(options);
      if (expectedProjectId != null && ids.isNotEmpty && !ids.contains(expectedProjectId)) {
        out.add(DiagnosticFinding(
          severity: DiagSeverity.error,
          problem: 'firebase_options.dart pointe vers un autre projet',
          cause: 'Projet dans le fichier : ${ids.join(', ')} ; projet connecté : $expectedProjectId.',
          solution: 'Régénérer la configuration pour le bon projet.',
          risk: 'Le fichier actuel sera remplacé (sauvegarde .bak conservée).',
          correction: generateFix != null ? 'Correction automatique disponible.' : 'flutterfire configure --project=$expectedProjectId',
          verification: 'projectId du fichier = $expectedProjectId.',
          fix: generateFix,
        ));
      } else {
        out.add(DiagnosticFinding(
          severity: DiagSeverity.ok,
          problem: 'firebase_options.dart présent',
          cause: ids.isEmpty ? '' : 'Projet : ${ids.join(', ')}',
        ));
      }
    }

    final main = _read('lib/main.dart');
    if (main == null) {
      out.add(const DiagnosticFinding(severity: DiagSeverity.warning, problem: 'lib/main.dart introuvable'));
    } else if (!main.contains('Firebase.initializeApp')) {
      out.add(const DiagnosticFinding(
        severity: DiagSeverity.error,
        problem: 'Firebase n\'est jamais initialisé',
        cause: 'lib/main.dart n\'appelle pas Firebase.initializeApp : tout appel Firestore ou Auth échouera avec [core/no-app].',
        solution: 'Initialiser Firebase avant runApp.',
        risk: 'Aucun.',
        correction: 'Dans main() :\n  WidgetsFlutterBinding.ensureInitialized();\n'
            '  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);\n  runApp(...);',
        verification: 'L\'application démarre et FirebaseFirestore.instance répond.',
      ));
    } else {
      final initIdx = main.indexOf('Firebase.initializeApp');
      final bindIdx = main.indexOf('ensureInitialized()');
      if (bindIdx < 0 || bindIdx > initIdx) {
        out.add(const DiagnosticFinding(
          severity: DiagSeverity.error,
          problem: 'WidgetsFlutterBinding.ensureInitialized() absent avant l\'initialisation',
          cause: 'Firebase utilise des canaux natifs qui exigent que le binding Flutter soit prêt.',
          solution: 'Appeler WidgetsFlutterBinding.ensureInitialized() en première ligne de main().',
          risk: 'Aucun.',
          correction: 'Ajouter « WidgetsFlutterBinding.ensureInitialized(); » avant Firebase.initializeApp.',
          verification: 'Plus d\'erreur « Binding has not yet been initialized » au démarrage.',
        ));
      }
      if (!RegExp(r'await\s+Firebase\.initializeApp').hasMatch(main)) {
        out.add(const DiagnosticFinding(
          severity: DiagSeverity.warning,
          problem: 'Firebase.initializeApp n\'est pas attendu (await)',
          cause: 'L\'application peut utiliser Firebase avant la fin de l\'initialisation.',
          solution: 'Rendre main() asynchrone et attendre l\'initialisation.',
          correction: 'Future<void> main() async { … await Firebase.initializeApp(…); … }',
          verification: 'Plus d\'erreur [core/no-app] intermittente au démarrage.',
        ));
      }
      if (options != null && !main.contains('DefaultFirebaseOptions.currentPlatform')) {
        out.add(const DiagnosticFinding(
          severity: DiagSeverity.warning,
          problem: 'initializeApp sans DefaultFirebaseOptions',
          cause: 'firebase_options.dart existe mais n\'est pas utilisé : la configuration dépend alors uniquement de google-services.json.',
          solution: 'Passer les options générées.',
          correction: 'await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);',
          verification: 'Démarrage sans erreur sur chaque plateforme ciblée.',
        ));
      }
    }

    // --- Android
    if (gradle == null) {
      out.add(const DiagnosticFinding(
        severity: DiagSeverity.info,
        problem: 'Pas de dossier android/ exploitable',
        cause: 'android/app/build.gradle(.kts) introuvable : la plateforme Android n\'est peut-être pas activée.',
        correction: 'flutter create --platforms=android .',
      ));
    } else {
      if (gsJson == null) {
        out.add(DiagnosticFinding(
          severity: options == null ? DiagSeverity.error : DiagSeverity.warning,
          problem: 'android/app/google-services.json absent',
          cause: 'Le plugin Gradle Google Services et certains services (Crashlytics, Messaging, connexion Google) en ont besoin.',
          solution: 'Télécharger la configuration de l\'application Android depuis Firebase.',
          risk: 'Aucun.',
          correction: generateFix != null ? 'Correction automatique disponible.' : 'flutterfire configure',
          verification: 'Le fichier existe et son package_name = applicationId.',
          fix: generateFix,
        ));
      } else {
        try {
          final cfg = GoogleServicesConfig.parse(gsJson);
          if (appId != null && cfg.clientFor(appId) == null) {
            out.add(DiagnosticFinding(
              severity: DiagSeverity.error,
              problem: 'google-services.json ne correspond pas à l\'application',
              cause: 'applicationId = $appId, mais le fichier ne contient que : ${cfg.clients.map((c) => c.packageName).join(', ')}.',
              solution: 'Enregistrer l\'application $appId dans Firebase et télécharger sa configuration.',
              risk: 'Le fichier sera remplacé (sauvegarde .bak conservée).',
              correction: generateFix != null ? 'Correction automatique disponible.' : 'flutterfire configure',
              verification: 'La compilation ne signale plus « No matching client found for package name ».',
              fix: generateFix,
            ));
          }
          if (expectedProjectId != null && cfg.projectId != expectedProjectId) {
            out.add(DiagnosticFinding(
              severity: DiagSeverity.error,
              problem: 'google-services.json appartient à un autre projet',
              cause: 'Projet dans le fichier : ${cfg.projectId} ; projet connecté : $expectedProjectId.',
              solution: 'Remplacer par la configuration du bon projet.',
              correction: generateFix != null ? 'Correction automatique disponible.' : 'flutterfire configure',
              verification: 'project_id = $expectedProjectId.',
              fix: generateFix,
            ));
          }
        } on FormatException catch (e) {
          out.add(DiagnosticFinding(
            severity: DiagSeverity.error,
            problem: 'google-services.json illisible',
            cause: e.message,
            correction: generateFix != null ? 'Correction automatique disponible.' : 'Télécharger à nouveau le fichier.',
            fix: generateFix,
          ));
        }
        final settings = _read('android/settings.gradle.kts') ?? _read('android/settings.gradle') ?? '';
        final rootGradle = _read('android/build.gradle.kts') ?? _read('android/build.gradle') ?? '';
        final declared = '$settings$rootGradle'.contains('com.google.gms');
        final applied = gradle.contains('com.google.gms.google-services');
        if (!declared || !applied) {
          out.add(const DiagnosticFinding(
            severity: DiagSeverity.warning,
            problem: 'Plugin Gradle Google Services non appliqué',
            cause: 'google-services.json est présent mais n\'est pas lu à la compilation.',
            solution: 'Déclarer le plugin dans android/settings.gradle(.kts) et l\'appliquer dans android/app/build.gradle(.kts).',
            correction: 'settings.gradle.kts : id("com.google.gms.google-services") version "4.4.2" apply false\n'
                'app/build.gradle.kts : id("com.google.gms.google-services")',
            verification: 'La tâche processDebugGoogleServices apparaît lors de flutter build apk.',
          ));
        }
      }

      final sdk = minSdk(gradle);
      if (sdk != null && sdk < 23 && (deps.containsKey('firebase_auth') || deps.containsKey('cloud_firestore'))) {
        out.add(DiagnosticFinding(
          severity: DiagSeverity.error,
          problem: 'minSdk $sdk trop bas pour Firebase',
          cause: 'Les versions actuelles de firebase_auth et cloud_firestore exigent Android 6.0 (API 23) minimum.',
          solution: 'Relever minSdk à 23 dans android/app/build.gradle(.kts).',
          risk: 'Les appareils Android 5.x ne pourront plus installer l\'application.',
          correction: 'minSdk = 23',
          verification: 'flutter build apk termine sans erreur de manifest merger.',
        ));
      }

      final manifestPath = p.join(projectDir, 'android/app/src/main/AndroidManifest.xml');
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      if (manifest != null && !manifest.contains('android.permission.INTERNET')) {
        out.add(DiagnosticFinding(
          severity: DiagSeverity.error,
          problem: 'Permission INTERNET absente du manifeste principal',
          cause: 'Flutter ne l\'ajoute qu\'aux manifestes debug et profile : en version release, aucun appel Firebase ne passe.',
          solution: 'Déclarer la permission dans android/app/src/main/AndroidManifest.xml.',
          risk: 'Aucun (permission normale, accordée automatiquement).',
          correction: 'Correction automatique disponible.',
          verification: 'La permission figure dans le manifeste et l\'APK release se connecte à Firebase.',
          fix: DiagnosticFix(
            label: 'Ajouter la permission INTERNET',
            preview: 'Modifie android/app/src/main/AndroidManifest.xml (sauvegarde .bak) :\n'
                '+ <uses-permission android:name="android.permission.INTERNET"/>',
            apply: () async {
              final updated = addInternetPermission(manifest);
              return writeWithBackup(manifestPath, updated);
            },
          ),
        ));
      }
    }

    // --- Règles Firestore présentes dans le projet
    final rules = _read('firestore.rules');
    if (rules != null) {
      final findings = RulesAnalyzer.analyze(rules);
      for (final f in findings.where((f) => f.severity != RuleSeverity.info)) {
        out.add(DiagnosticFinding(
          severity: f.severity == RuleSeverity.critical ? DiagSeverity.error : DiagSeverity.warning,
          problem: 'firestore.rules : ${f.title}${f.line == null ? '' : ' (ligne ${f.line})'}',
          cause: f.explanation,
          solution: 'Remplacer par des règles fermées par défaut (générateur de règles de BDDouilleur).',
          risk: 'Des écrans de l\'application peuvent recevoir « permission-denied » s\'ils dépendaient de l\'accès ouvert.',
          correction: 'Firebase AutoPilot → projet → Règles → Générateur.',
          verification: 'Tests de règles : accès refusé aux visiteurs et aux autres utilisateurs.',
        ));
      }
    } else if (deps.containsKey('cloud_firestore')) {
      out.add(const DiagnosticFinding(
        severity: DiagSeverity.info,
        problem: 'Pas de firestore.rules dans le projet',
        cause: 'Les règles ne sont pas versionnées avec le code : elles vivent uniquement dans la console.',
        solution: 'Conserver les règles dans le dépôt (firestore.rules) pour les relire et les tester.',
      ));
    }

    if (!out.any((f) => f.severity == DiagSeverity.error || f.severity == DiagSeverity.warning)) {
      out.add(const DiagnosticFinding(
        severity: DiagSeverity.ok,
        problem: 'Aucun problème de configuration détecté',
        cause: 'Les vérifications statiques sont conformes. Si Firebase échoue encore, lancez l\'analyse du projet Firebase distant.',
      ));
    }
    return out;
  }

  static String addInternetPermission(String manifest) {
    const line = '    <uses-permission android:name="android.permission.INTERNET"/>\n';
    final m = RegExp(r'<manifest[^>]*>\s*\n?').firstMatch(manifest);
    if (m == null) throw const FormatException('Balise <manifest> introuvable.');
    return manifest.replaceRange(m.end, m.end, line);
  }

  /// Écrit un fichier en conservant une copie .bak de l'ancien contenu.
  static String writeWithBackup(String path, String content) {
    final f = File(path);
    String report = 'Créé : $path';
    if (f.existsSync()) {
      final bak = '$path.bak';
      f.copySync(bak);
      report = 'Modifié : $path (ancienne version : $bak)';
    }
    f.parent.createSync(recursive: true);
    final tmp = File('$path.bdd-tmp');
    tmp.writeAsStringSync(content);
    tmp.renameSync(path);
    return report;
  }
}
