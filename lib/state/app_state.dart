import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http_pkg;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../data/backup/sqlite_backup_service.dart';
import '../data/connectors/database_connector.dart';
import '../data/connectors/sqlite/sqlite_connector.dart';
import '../data/firebase/firebase_management.dart';
import '../data/firebase/firestore_admin.dart';
import '../data/firebase/firestore_client.dart';
import '../data/firebase/rules_service.dart';
import '../data/google/google_api.dart';
import '../data/google/google_auth.dart';
import '../data/secrets/secret_store.dart';
import '../data/persistence/app_database.dart';
import '../data/persistence/app_paths.dart';
import '../data/persistence/repositories.dart';
import '../domain/firebase/firebase_target.dart';
import '../domain/models/db_engine.dart';
import '../domain/models/journal_entry.dart';
import '../domain/models/project.dart';

/// État global et services de l'application.
///
/// Toute opération qui modifie une base passe par [runLogged] afin d'être
/// journalisée avec le SQL réellement exécuté et son résultat réel.
class AppState extends ChangeNotifier {
  AppState({
    required this.paths,
    required this.appDb,
    SecretStore? secrets,
    http_pkg.Client? httpClient,
    BrowserLauncher? launcher,
  })  : projects = ProjectRepository(appDb),
        connections = ConnectionRepository(appDb),
        journal = JournalRepository(appDb),
        secrets = secrets ?? SystemSecretStore(),
        httpClient = httpClient ?? http_pkg.Client() {
    googleAuth = GoogleAuthService(
      secrets: this.secrets,
      client: this.httpClient,
      launcher: launcher ?? ((url) => launchUrl(url, mode: LaunchMode.externalApplication)),
    );
    _themeMode = switch (appDb.getSetting('theme_mode')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final active = int.tryParse(appDb.getSetting('active_project') ?? '');
    if (active != null && projects.byId(active) != null) _activeProjectId = active;
  }

  static Future<AppState> bootstrap() async {
    final paths = await AppPaths.resolve();
    final state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase));
    await state.loadSecrets();
    return state;
  }

  /// Charge l'état du compte Google depuis le trousseau. Une indisponibilité
  /// du trousseau n'empêche pas l'application de démarrer.
  Future<void> loadSecrets() async {
    try {
      await googleAuth.load();
      secretsError = null;
    } catch (e) {
      secretsError = 'Trousseau système indisponible : $e';
    }
    notifyListeners();
  }

  final AppPaths paths;
  final AppDatabase appDb;
  final ProjectRepository projects;
  final ConnectionRepository connections;
  final JournalRepository journal;
  final SecretStore secrets;
  final http_pkg.Client httpClient;
  late final GoogleAuthService googleAuth;

  /// Message si le stockage sécurisé n'est pas accessible.
  String? secretsError;

  final Map<int, SqliteConnector> _openConnectors = {};

  // ---------------------------------------------------------------- thème
  late ThemeMode _themeMode;
  ThemeMode get themeMode => _themeMode;
  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    appDb.setSetting('theme_mode', mode.name);
    notifyListeners();
  }

  // -------------------------------------------------------------- projets
  int? _activeProjectId;
  Project? get activeProject => _activeProjectId == null ? null : projects.byId(_activeProjectId!);

  void setActiveProject(int? id) {
    _activeProjectId = id;
    appDb.setSetting('active_project', id?.toString());
    notifyListeners();
  }

  Project createProject(String name, String description) {
    final project = projects.create(name, description: description);
    journal.log(projectId: project.id, action: JournalAction.projectCreated, summary: 'Projet « ${project.name} » créé');
    _activeProjectId ??= project.id;
    appDb.setSetting('active_project', _activeProjectId.toString());
    notifyListeners();
    return project;
  }

  Project updateProject(Project project) {
    final updated = projects.update(project);
    journal.log(projectId: updated.id, action: JournalAction.projectUpdated, summary: 'Projet « ${updated.name} » modifié');
    notifyListeners();
    return updated;
  }

  /// Supprime le projet et ses connexions. Les fichiers .db créés par
  /// BDDouilleur dans le dossier du projet sont supprimés seulement si
  /// [deleteFiles] est vrai (confirmation explicite côté UI).
  Future<void> deleteProject(Project project, {required bool deleteFiles}) async {
    for (final c in connections.forProject(project.id!)) {
      await closeConnector(c.id!);
    }
    projects.delete(project.id!);
    if (deleteFiles) {
      final dir = Directory(paths.databasesDir(project.id!));
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    journal.log(
      action: JournalAction.projectDeleted,
      summary: 'Projet « ${project.name} » supprimé${deleteFiles ? ' avec ses fichiers' : ''}',
    );
    if (_activeProjectId == project.id) setActiveProject(null);
    notifyListeners();
  }

  // ----------------------------------------------------------- connexions
  /// Crée réellement un fichier SQLite vide dans le dossier du projet.
  Future<DbConnection> createSqliteDatabase(Project project, String name) async {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('Le nom de la base est obligatoire.');
    final file = paths.newDatabaseFile(project.id!, n);
    final connector = SqliteConnector(file, createIfMissing: true);
    try {
      await connector.open();
      // Écrit l'en-tête SQLite pour que le fichier soit une base valide sur disque.
      await connector.executeSql('PRAGMA user_version = 0; VACUUM;');
    } finally {
      await connector.close();
    }
    if (!File(file).existsSync()) {
      throw ConnectorException('Le fichier de base n\'a pas été créé : $file');
    }
    final conn = connections.create(projectId: project.id!, name: n, engine: DbEngine.sqlite, location: file);
    journal.log(
      projectId: project.id,
      connectionId: conn.id,
      action: JournalAction.databaseCreated,
      summary: 'Base SQLite « $n » créée (${p.basename(file)})',
    );
    projects.touch(project.id!);
    notifyListeners();
    return conn;
  }

  /// Connecte un fichier SQLite existant (vérifié avant enregistrement).
  Future<DbConnection> attachSqliteFile(Project project, String path, {String? name}) async {
    final abs = p.normalize(p.absolute(path.trim()));
    if (connections.locationUsed(project.id!, abs)) {
      throw ConnectorException('Ce fichier est déjà connecté à ce projet.');
    }
    final connector = SqliteConnector(abs);
    try {
      await connector.open();
      await connector.listTables();
    } finally {
      await connector.close();
    }
    final conn = connections.create(
      projectId: project.id!,
      name: (name == null || name.trim().isEmpty) ? p.basenameWithoutExtension(abs) : name.trim(),
      engine: DbEngine.sqlite,
      location: abs,
    );
    journal.log(
      projectId: project.id,
      connectionId: conn.id,
      action: JournalAction.databaseAttached,
      summary: 'Fichier SQLite existant connecté : $abs',
    );
    notifyListeners();
    return conn;
  }

  bool isManagedFile(DbConnection c) => p.isWithin(paths.databasesDir(c.projectId), c.location);

  Future<void> detachConnection(DbConnection c, {required bool deleteFile}) async {
    await closeConnector(c.id!);
    connections.delete(c.id!);
    if (deleteFile && isManagedFile(c)) {
      for (final suffix in ['', '-journal', '-wal', '-shm']) {
        final f = File('${c.location}$suffix');
        if (f.existsSync()) f.deleteSync();
      }
    }
    journal.log(
      projectId: c.projectId,
      action: JournalAction.databaseDetached,
      summary: 'Connexion « ${c.name} » retirée${deleteFile ? ' et fichier supprimé' : ''}',
    );
    notifyListeners();
  }

  Future<SqliteConnector> connectorFor(DbConnection c) async {
    final existing = _openConnectors[c.id];
    if (existing != null && existing.isOpen) return existing;
    if (c.engine != DbEngine.sqlite) {
      throw ConnectorException('Le connecteur ${c.engine.label} n\'est pas encore disponible (phase ${c.engine.plannedPhase}).');
    }
    final connector = SqliteConnector(c.location);
    await connector.open();
    _openConnectors[c.id!] = connector;
    connections.markOpened(c.id!);
    return connector;
  }

  Future<void> closeConnector(int connectionId) async {
    await _openConnectors.remove(connectionId)?.close();
  }

  SqliteBackupService backupsFor(DbConnection c) => SqliteBackupService(paths.backupsDir(c.id!));

  // ------------------------------------------------------------ Google / Firebase
  String? get googleEmail => googleAuth.email;

  Future<String> signInGoogle() async {
    final email = await googleAuth.signIn();
    journal.log(action: JournalAction.googleSignedIn, summary: 'Compte Google connecté (OAuth 2.0, PKCE)');
    notifyListeners();
    return email;
  }

  Future<bool> signOutGoogle() async {
    final revoked = await googleAuth.signOut();
    journal.log(
      action: JournalAction.googleSignedOut,
      summary: revoked ? 'Compte Google déconnecté, autorisation révoquée' : 'Compte Google déconnecté localement',
      success: revoked,
      error: revoked ? null : 'La révocation auprès de Google a échoué ; révoquez l\'accès sur myaccount.google.com.',
    );
    notifyListeners();
    return revoked;
  }

  Future<void> saveOAuthClient(OAuthClientConfig config) async {
    await googleAuth.saveClientConfig(config);
    notifyListeners();
  }

  Future<void> deleteOAuthClient() async {
    await googleAuth.deleteClientConfig();
    notifyListeners();
  }

  /// Client des API Google authentifié par le compte connecté.
  GoogleApiClient googleApi() => GoogleApiClient(
        client: httpClient,
        authHeader: () async => 'Bearer ${await googleAuth.accessToken()}',
      );

  /// Client sans authentification (API publiques avec clé, émulateurs).
  GoogleApiClient anonymousApi([String? authHeader]) =>
      GoogleApiClient(client: httpClient, authHeader: () async => authHeader);

  /// Client adapté à la cible : jeton OAuth (Google) ou « owner » (émulateur).
  GoogleApiClient apiFor(FirebaseTarget t) => t.isEmulator ? anonymousApi('Bearer owner') : googleApi();

  FirestoreClient firestoreFor(DbConnection c) => FirestoreClient(c.firebase, apiFor(c.firebase));

  RulesService rulesFor(DbConnection c, {GoogleApiClient? api}) {
    final t = c.firebase;
    if (!t.isEmulator) return GoogleRulesService(t, api ?? googleApi());
    return EmulatorRulesService(
      t,
      api ?? apiFor(t),
      clientFactory: anonymousApi,
      onDeployed: (source) {
        final fresh = connections.byId(c.id!);
        if (fresh == null) return;
        connections.updateConfig(c.id!, {...fresh.config, 'lastRules': source});
      },
    );
  }

  /// Vérifie que la cible répond réellement, puis l'enregistre dans le projet.
  Future<DbConnection> connectFirebase(Project project, FirebaseTarget target, {String? name}) async {
    final existing = connections
        .forProject(project.id!)
        .where((c) => c.engine == DbEngine.firestore && c.location == target.projectId && c.firebase.mode == target.mode);
    if (existing.isNotEmpty) throw ConnectorException('Ce projet Firebase est déjà connecté à ce projet BDDouilleur.');
    final api = apiFor(target);
    final detail = <String>[];
    try {
      if (target.isEmulator) {
        await FirestoreClient(target, api).listCollectionIds();
        detail.add('Émulateur Firestore joignable sur ${target.firestoreHost}');
      } else {
        final info = await FirebaseManagementService(api).getFirebaseProject(target.projectId);
        if (info == null) {
          throw ConnectorException('Projet Firebase « ${target.projectId} » introuvable ou inaccessible avec ce compte.');
        }
        final dbs = await FirestoreAdminService(api).listDatabases(target.projectId);
        detail.add(dbs.any((d) => d.id == target.databaseId)
            ? 'Base Firestore ${target.databaseId} trouvée'
            : 'Aucune base Firestore ${target.databaseId} pour l\'instant (AutoPilot peut la créer)');
      }
    } on GoogleApiException catch (e) {
      if (target.isEmulator && e.statusCode == 0) {
        throw ConnectorException('Émulateur injoignable sur ${target.firestoreHost}. Lancez-le avec :\n'
            'firebase emulators:start --only firestore,auth --project ${target.projectId}');
      }
      throw ConnectorException(e.toString());
    }
    final json = target.toJson()..remove('projectId');
    final conn = connections.create(
      projectId: project.id!,
      name: (name == null || name.trim().isEmpty)
          ? (target.isEmulator ? '${target.projectId} (émulateur)' : target.projectId)
          : name.trim(),
      engine: DbEngine.firestore,
      location: target.projectId,
      config: json,
    );
    journal.log(
      projectId: project.id,
      connectionId: conn.id,
      action: JournalAction.firebaseConnected,
      summary: '${target.mode.label} « ${target.projectId} » connecté. ${detail.join('. ')}',
    );
    projects.touch(project.id!);
    notifyListeners();
    return conn;
  }

  /// Exécute une opération Firebase et la journalise avec les requêtes REST
  /// réellement envoyées (les lectures seules ne sont pas listées).
  Future<T> runFirebase<T>({
    required GoogleApiClient api,
    required JournalAction action,
    required String summary,
    required Future<T> Function() run,
    DbConnection? connection,
    int? projectId,
  }) async {
    final mark = api.mark;
    String? requests() {
      final writes = api.requestsSince(mark).where((r) => !r.startsWith('GET ')).toList();
      return writes.isEmpty ? null : writes.join('\n');
    }

    try {
      final result = await run();
      journal.log(
        projectId: connection?.projectId ?? projectId,
        connectionId: connection?.id,
        action: action,
        summary: summary,
        sql: requests(),
      );
      notifyListeners();
      return result;
    } catch (e) {
      journal.log(
        projectId: connection?.projectId ?? projectId,
        connectionId: connection?.id,
        action: action,
        summary: summary,
        sql: requests(),
        success: false,
        error: e.toString(),
      );
      notifyListeners();
      rethrow;
    }
  }

  /// Exécute une opération et la journalise avec son résultat réel.
  Future<T> runLogged<T>({
    required DbConnection connection,
    required JournalAction action,
    required String summary,
    required Future<T> Function(SqliteConnector connector) run,
    String? Function(T result)? sqlOf,
  }) async {
    try {
      final connector = await connectorFor(connection);
      final result = await run(connector);
      journal.log(
        projectId: connection.projectId,
        connectionId: connection.id,
        action: action,
        summary: summary,
        sql: sqlOf?.call(result) ?? (result is OperationOutcome ? result.sql : null),
      );
      notifyListeners();
      return result;
    } catch (e) {
      journal.log(
        projectId: connection.projectId,
        connectionId: connection.id,
        action: action,
        summary: summary,
        success: false,
        error: e.toString(),
      );
      notifyListeners();
      rethrow;
    }
  }

  @override
  void dispose() {
    for (final c in _openConnectors.values) {
      c.close();
    }
    googleAuth.cancelPendingSignIn();
    httpClient.close();
    appDb.close();
    super.dispose();
  }
}
