import '../../domain/firebase/firebase_target.dart';
import '../../domain/firebase/firestore_rules.dart';
import '../../domain/firebase/flutterfire_config.dart';
import '../google/google_api.dart';
import 'auth_service.dart';
import 'firebase_diagnostic.dart';
import 'firebase_management.dart';
import 'firestore_admin.dart';
import 'rules_service.dart';

/// Ce que l'utilisateur demande à Firebase AutoPilot.
class FirebaseCreationPlan {
  const FirebaseCreationPlan({
    required this.projectId,
    required this.displayName,
    this.packageName,
    this.firestoreLocation,
    this.enableEmailAuth = true,
  });

  final String projectId;
  final String displayName;
  final String? packageName;
  final String? firestoreLocation;
  final bool enableEmailAuth;

  /// Liste lisible des actions possibles (affichée avant confirmation).
  List<String> describe() => [
        'Créer le projet Google Cloud « $projectId » s\'il n\'existe pas encore (sinon le réutiliser).',
        'Ajouter Firebase au projet s\'il ne l\'a pas déjà.',
        'Activer les API Cloud Firestore, Firebase Rules et Identity Toolkit si nécessaire.',
        if (firestoreLocation != null)
          'Créer la base Firestore (default) en région $firestoreLocation si elle n\'existe pas. La région ne pourra plus être changée.',
        if (packageName != null) 'Enregistrer l\'application Android « $packageName » et récupérer sa configuration.',
        if (enableEmailAuth) 'Activer la connexion e-mail / mot de passe, avec protection contre l\'énumération des comptes.',
        'Vérifier que chaque ressource existe réellement.',
      ];
}

enum StepStatus { pending, running, done, skipped, warning, failed }

class AutoPilotStep {
  AutoPilotStep(this.title);
  final String title;
  StepStatus status = StepStatus.pending;
  String? detail;
}

/// Résultat d'une exécution d'AutoPilot.
class AutoPilotResult {
  AutoPilotResult(this.steps);
  final List<AutoPilotStep> steps;
  String? googleServicesJson;
  FirebaseProjectInfo? project;
  bool get success => steps.every((s) => s.status != StepStatus.failed);
}

/// Orchestration réelle de la création d'un projet Firebase complet.
/// Chaque étape vérifie l'existant avant d'agir : rien n'est recréé.
class FirebaseAutoPilot {
  FirebaseAutoPilot(this.api, {this.onLog});
  final GoogleApiClient api;

  /// Appelé après chaque action modifiante réussie ou échouée (journal).
  final void Function(String summary, String? request, {bool success, String? error})? onLog;

  late final _mgmt = FirebaseManagementService(api);
  late final _admin = FirestoreAdminService(api);

  static const requiredPermissions = [
    'resourcemanager.projects.get',
    'serviceusage.services.enable',
    'firebase.projects.update',
  ];

  Future<AutoPilotResult> run(FirebaseCreationPlan plan, {void Function(AutoPilotResult)? onProgress}) async {
    final s = <String, AutoPilotStep>{
      'gcp': AutoPilotStep('Projet Google Cloud'),
      'perm': AutoPilotStep('Permissions sur le projet'),
      'firebase': AutoPilotStep('Ajout de Firebase'),
      'apis': AutoPilotStep('Activation des API'),
      if (plan.firestoreLocation != null) 'firestore': AutoPilotStep('Base Cloud Firestore'),
      if (plan.packageName != null) 'android': AutoPilotStep('Application Android'),
      if (plan.packageName != null) 'config': AutoPilotStep('Configuration FlutterFire'),
      if (plan.enableEmailAuth) 'auth': AutoPilotStep('Authentication e-mail / mot de passe'),
      'verify': AutoPilotStep('Vérification finale'),
    };
    final result = AutoPilotResult(s.values.toList());
    final id = plan.projectId;

    void update(String key, StepStatus status, [String? detail]) {
      s[key]!
        ..status = status
        ..detail = detail;
      onProgress?.call(result);
    }

    Future<bool> guard(String key, Future<void> Function() body) async {
      update(key, StepStatus.running);
      try {
        await body();
        if (s[key]!.status == StepStatus.running) update(key, StepStatus.done, s[key]!.detail);
        return true;
      } on GoogleApiException catch (e) {
        update(key, StepStatus.failed, e.toString());
        onLog?.call('AutoPilot — ${s[key]!.title} : échec', e.request, success: false, error: e.toString());
        return false;
      } catch (e) {
        update(key, StepStatus.failed, '$e');
        onLog?.call('AutoPilot — ${s[key]!.title} : échec', null, success: false, error: '$e');
        return false;
      }
    }

    // Dernière requête modifiante (les GET de suivi d'opération sont ignorés).
    void logged(String summary) =>
        onLog?.call(summary, api.requestLog.reversed.where((r) => !r.startsWith('GET ')).firstOrNull);

    if (!await guard('gcp', () async {
      final state = await _mgmt.gcpProjectState(id);
      if (state == null) {
        try {
          await _mgmt.createGcpProject(id, plan.displayName);
        } on GoogleApiException catch (e) {
          if (e.isAlreadyExists) {
            throw GoogleApiException(
              statusCode: e.statusCode,
              status: e.status,
              message: 'L\'identifiant « $id » est déjà pris par un autre compte Google. Choisissez-en un autre.',
            );
          }
          rethrow;
        }
        logged('Projet Google Cloud « $id » créé');
        s['gcp']!.detail = 'Projet créé.';
      } else if (state != 'ACTIVE') {
        throw StateError('Le projet existe mais son état est $state (supprimé ou en cours de suppression).');
      } else {
        update('gcp', StepStatus.skipped, 'Le projet existe déjà : il est réutilisé, pas recréé.');
      }
    })) {
      return result;
    }

    if (!await guard('perm', () async {
      final granted = await _mgmt.testPermissions(id, requiredPermissions);
      final missing = requiredPermissions.where((p) => !granted.contains(p)).toList();
      if (missing.isNotEmpty) {
        throw StateError('Permissions manquantes : ${missing.join(', ')}. '
            'Demandez le rôle Propriétaire (ou Éditeur + Administrateur Firebase) sur ce projet.');
      }
      s['perm']!.detail = 'Toutes les permissions nécessaires sont accordées.';
    })) {
      return result;
    }

    if (!await guard('firebase', () async {
      final existing = await _mgmt.getFirebaseProject(id);
      if (existing != null) {
        result.project = existing;
        update('firebase', StepStatus.skipped, 'Firebase est déjà actif sur ce projet.');
      } else {
        result.project = await _mgmt.addFirebase(id);
        logged('Firebase ajouté au projet « $id »');
        s['firebase']!.detail = 'Firebase ajouté (plan Spark, gratuit).';
      }
    })) {
      return result;
    }

    if (!await guard('apis', () async {
      final enabled = await _mgmt.enabledServices(id);
      final toEnable = FirebaseService.values.where((x) => !enabled.contains(x.id)).toList();
      for (final svc in toEnable) {
        await _mgmt.enableService(id, svc.id);
        logged('API ${svc.label} activée sur « $id »');
      }
      if (toEnable.isEmpty) {
        update('apis', StepStatus.skipped, 'Les API nécessaires sont déjà actives.');
      } else {
        s['apis']!.detail = 'Activées : ${toEnable.map((x) => x.label).join(', ')}.';
      }
    })) {
      return result;
    }

    if (plan.firestoreLocation != null) {
      if (!await guard('firestore', () async {
        final dbs = await _admin.listDatabases(id);
        final existing = dbs.where((d) => d.id == '(default)').firstOrNull;
        if (existing != null) {
          update(
              'firestore',
              existing.isNative ? StepStatus.skipped : StepStatus.warning,
              existing.isNative
                  ? 'La base existe déjà (région ${existing.locationId}).'
                  : 'La base existe en mode ${existing.type}, pas en mode natif.');
        } else {
          final db = await _admin.createDatabase(id, plan.firestoreLocation!);
          logged('Base Firestore (default) créée en ${db.locationId}');
          s['firestore']!.detail = 'Base créée en ${db.locationId}. Règles par défaut de Google : tout est refusé.';
        }
      })) {
        return result;
      }
    }

    if (plan.packageName != null) {
      AndroidAppInfo? app;
      if (!await guard('android', () async {
        final apps = await _mgmt.listAndroidApps(id);
        app = apps.where((a) => a.packageName == plan.packageName).firstOrNull;
        if (app != null) {
          update('android', StepStatus.skipped, 'Déjà enregistrée (${app!.appId}).');
        } else {
          app = await _mgmt.createAndroidApp(id, plan.packageName!, plan.displayName);
          logged('Application Android « ${plan.packageName} » enregistrée');
          s['android']!.detail = 'Enregistrée : ${app!.appId}';
        }
      })) {
        return result;
      }
      if (!await guard('config', () async {
        final json = await _mgmt.androidConfigFile(id, app!.appId);
        final cfg = GoogleServicesConfig.parse(json);
        FlutterFireGenerator.firebaseOptions(cfg, plan.packageName!); // vérifie qu'elle est exploitable
        result.googleServicesJson = json;
        s['config']!.detail = 'google-services.json récupéré ; firebase_options.dart peut être généré.';
      })) {
        return result;
      }
    }

    if (plan.enableEmailAuth) {
      await guard('auth', () async {
        final auth = AuthAdminService(api, id);
        final cfg = await auth.getConfig();
        if (cfg == null) {
          update('auth', StepStatus.warning,
              'Authentication n\'est pas encore initialisé : ouvrez ${AuthAdminService.consoleUrl(id)}, '
              'cliquez sur « Commencer », puis relancez AutoPilot (les étapes déjà faites seront ignorées).');
          return;
        }
        if (cfg.emailEnabled && cfg.emailEnumerationProtection) {
          update('auth', StepStatus.skipped, 'Déjà activé, protection contre l\'énumération active.');
          return;
        }
        final after = await auth.enableEmailPassword(enumerationProtection: true);
        logged('Authentication e-mail / mot de passe activée sur « $id »');
        if (!after.emailEnabled) throw StateError('Google n\'a pas confirmé l\'activation.');
        s['auth']!.detail = 'Activé, protection contre l\'énumération des comptes active.';
      });
    }

    await guard('verify', () async {
      final problems = <String>[];
      final project = await _mgmt.getFirebaseProject(id);
      if (project == null) problems.add('projet Firebase introuvable');
      result.project = project ?? result.project;
      if (plan.firestoreLocation != null) {
        final dbs = await _admin.listDatabases(id);
        if (!dbs.any((d) => d.id == '(default)')) problems.add('base Firestore introuvable');
      }
      if (plan.packageName != null) {
        final apps = await _mgmt.listAndroidApps(id);
        if (!apps.any((a) => a.packageName == plan.packageName)) problems.add('application Android introuvable');
      }
      if (problems.isNotEmpty) throw StateError('Vérification échouée : ${problems.join(', ')}.');
      s['verify']!.detail = 'Toutes les ressources demandées existent réellement chez Google.';
    });
    return result;
  }
}

/// Analyse d'un projet Firebase existant (lecture seule).
class FirebaseProjectAnalyzer {
  FirebaseProjectAnalyzer(this.api);
  final GoogleApiClient api;

  Future<List<DiagnosticFinding>> analyze(String projectId, {String databaseId = '(default)'}) async {
    final out = <DiagnosticFinding>[];
    final mgmt = FirebaseManagementService(api);
    final admin = FirestoreAdminService(api);

    Future<T?> attempt<T>(String what, Future<T> Function() body) async {
      try {
        return await body();
      } on GoogleApiException catch (e) {
        out.add(DiagnosticFinding(
          severity: DiagSeverity.error,
          problem: 'Impossible de lire : $what',
          cause: e.explanation,
          solution: e.isServiceDisabled
              ? 'Activer l\'API indiquée (dans le projet de votre client OAuth et/ou dans ce projet).'
              : e.isPermissionDenied
                  ? 'Utiliser un compte ayant le rôle Propriétaire ou Éditeur sur ce projet.'
                  : 'Réessayer ; vérifier la connexion réseau.',
          risk: 'Aucun (lecture seule).',
          verification: 'Relancer l\'analyse.',
          correction: e.activationUrl ?? '',
        ));
        return null;
      }
    }

    final project = await attempt('projet Firebase', () => mgmt.getFirebaseProject(projectId));
    if (project == null) {
      if (out.isEmpty) {
        out.add(DiagnosticFinding(
          severity: DiagSeverity.error,
          problem: 'Projet Firebase « $projectId » introuvable',
          cause: 'Le projet n\'existe pas, Firebase n\'y est pas ajouté, ou votre compte n\'y a pas accès.',
          solution: 'Vérifier l\'identifiant, ou utiliser AutoPilot pour ajouter Firebase.',
        ));
      }
      return out;
    }
    out.add(DiagnosticFinding(
        severity: DiagSeverity.ok,
        problem: 'Projet Firebase « ${project.displayName} » accessible',
        cause: 'Numéro ${project.projectNumber ?? '?'}'));

    final billing = await mgmt.billingEnabled(projectId);
    out.add(DiagnosticFinding(
      severity: DiagSeverity.info,
      problem: billing == null
          ? 'Facturation : information non disponible'
          : billing
              ? 'Facturation active (plan Blaze)'
              : 'Pas de facturation (plan Spark, gratuit)',
      cause: billing == false
          ? 'Firestore et Authentication fonctionnent dans les quotas gratuits. Storage exige le plan Blaze.'
          : '',
    ));

    final enabled = await attempt('services activés', () => mgmt.enabledServices(projectId));
    if (enabled != null) {
      for (final svc in FirebaseService.values) {
        if (!enabled.contains(svc.id)) {
          out.add(DiagnosticFinding(
            severity: DiagSeverity.warning,
            problem: 'API ${svc.label} désactivée',
            cause: 'Le service ${svc.id} n\'est pas activé sur le projet.',
            solution: 'L\'activer (AutoPilot le fait automatiquement).',
            risk: 'Aucun coût sur le plan Spark.',
            verification: 'Le service apparaît comme activé.',
          ));
        }
      }
    }

    final dbs = await attempt('bases Firestore', () => admin.listDatabases(projectId));
    final db = dbs?.where((d) => d.id == databaseId).firstOrNull;
    if (dbs != null && db == null) {
      out.add(DiagnosticFinding(
        severity: DiagSeverity.error,
        problem: 'Aucune base Firestore « $databaseId »',
        cause: 'Firestore n\'a pas encore été créé sur ce projet : toute lecture ou écriture échouera (NOT_FOUND).',
        solution: 'Créer la base en choisissant sa région (définitive).',
        correction: 'Firebase AutoPilot → Créer un projet complet (avec le même identifiant : rien d\'existant n\'est recréé).',
        verification: 'La base apparaît dans la liste.',
      ));
    } else if (db != null) {
      out.add(DiagnosticFinding(
          severity: db.isNative ? DiagSeverity.ok : DiagSeverity.warning,
          problem: 'Base Firestore « $databaseId » (${db.locationId})',
          cause: db.isNative ? 'Mode natif.' : 'Mode ${db.type} : les SDK Firestore mobiles exigent le mode natif.'));

      final rules = await attempt('règles de sécurité', () => GoogleRulesService(
              FirebaseTarget(mode: FirebaseMode.google, projectId: projectId, databaseId: databaseId), api)
          .currentRules());
      if (rules == null && !out.any((f) => f.problem.contains('règles de sécurité'))) {
        out.add(const DiagnosticFinding(
          severity: DiagSeverity.warning,
          problem: 'Aucune règle de sécurité publiée',
          cause: 'Aucune publication cloud.firestore n\'a été trouvée.',
          solution: 'Générer et déployer des règles fermées par défaut.',
        ));
      } else if (rules != null) {
        final findings = RulesAnalyzer.analyze(rules);
        if (findings.every((f) => f.severity == RuleSeverity.info)) {
          out.add(const DiagnosticFinding(severity: DiagSeverity.ok, problem: 'Règles de sécurité sans ouverture dangereuse'));
        }
        for (final f in findings) {
          out.add(DiagnosticFinding(
            severity: switch (f.severity) {
              RuleSeverity.critical => DiagSeverity.error,
              RuleSeverity.warning => DiagSeverity.warning,
              RuleSeverity.info => DiagSeverity.info,
            },
            problem: 'Règles : ${f.title}${f.line == null ? '' : ' (ligne ${f.line})'}',
            cause: f.explanation,
            solution: f.severity == RuleSeverity.info ? '' : 'Remplacer par des règles générées et testées.',
            risk: f.severity == RuleSeverity.info
                ? ''
                : 'Des écrans qui dépendaient de l\'accès ouvert recevront « permission-denied ».',
            correction: f.severity == RuleSeverity.info ? '' : 'Onglet Règles → Générateur → Tester → Déployer.',
            verification: f.severity == RuleSeverity.info ? '' : 'Les tests de règles passent ; nouvelle analyse sans alerte.',
          ));
        }
      }

      final indexes = await attempt('index composites', () => admin.listIndexes(projectId, databaseId: databaseId));
      if (indexes != null) {
        final broken = indexes.where((i) => i.state == 'NEEDS_REPAIR').toList();
        out.add(DiagnosticFinding(
          severity: broken.isEmpty ? DiagSeverity.info : DiagSeverity.error,
          problem: '${indexes.length} index composite(s)${broken.isEmpty ? '' : ', dont ${broken.length} à réparer'}',
          cause: broken.isEmpty
              ? 'Une requête qui combine filtres et tris sur plusieurs champs exige un index composite ; '
                  'l\'erreur FAILED_PRECONDITION de Firestore donne alors le lien de création.'
              : 'Index : ${broken.map((i) => i.collectionGroup).join(', ')}',
        ));
      }
    }

    final auth = await attempt('configuration Authentication', () => AuthAdminService(api, projectId).getConfig());
    if (auth == null && !out.any((f) => f.problem.contains('Authentication'))) {
      out.add(DiagnosticFinding(
        severity: DiagSeverity.warning,
        problem: 'Authentication non initialisé',
        cause: 'Le service n\'a jamais été démarré sur ce projet.',
        solution: 'Ouvrir la console et cliquer sur « Commencer ».',
        correction: AuthAdminService.consoleUrl(projectId),
        verification: 'Relancer l\'analyse : la configuration devient lisible.',
      ));
    } else if (auth != null) {
      out.add(DiagnosticFinding(
        severity: auth.emailEnabled ? DiagSeverity.ok : DiagSeverity.info,
        problem: 'Connexion e-mail / mot de passe ${auth.emailEnabled ? 'activée' : 'désactivée'}',
        cause: 'Domaines autorisés : ${auth.authorizedDomains.join(', ')}',
      ));
      if (auth.emailEnabled && !auth.emailEnumerationProtection) {
        out.add(const DiagnosticFinding(
          severity: DiagSeverity.warning,
          problem: 'Protection contre l\'énumération des e-mails désactivée',
          cause: 'Un attaquant peut tester si une adresse possède un compte.',
          solution: 'Activer la protection (onglet Authentication).',
          risk: 'fetchSignInMethodsForEmail ne renvoie plus d\'information exploitable.',
          verification: 'L\'option apparaît active dans la configuration.',
        ));
      }
      if (auth.anonymousEnabled) {
        out.add(const DiagnosticFinding(
          severity: DiagSeverity.info,
          problem: 'Connexion anonyme activée',
          cause: 'Des règles fondées uniquement sur « request.auth != null » laissent alors passer n\'importe qui.',
        ));
      }
    }

    final apps = await attempt('applications Android', () => mgmt.listAndroidApps(projectId));
    if (apps != null) {
      out.add(DiagnosticFinding(
        severity: apps.isEmpty ? DiagSeverity.warning : DiagSeverity.ok,
        problem: apps.isEmpty ? 'Aucune application Android enregistrée' : '${apps.length} application(s) Android',
        cause: apps.map((a) => a.packageName).join(', '),
        solution: apps.isEmpty ? 'Enregistrer l\'application (onglet Configuration).' : '',
      ));
    }
    return out;
  }
}
