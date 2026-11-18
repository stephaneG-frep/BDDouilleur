import 'dart:convert';
import 'dart:io';

import 'package:bddouilleur/data/firebase/firebase_diagnostic.dart';
import 'package:bddouilleur/data/firebase/firestore_value_codec.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/domain/firebase/firebase_target.dart';
import 'package:bddouilleur/domain/firebase/firestore_rules.dart';
import 'package:bddouilleur/domain/firebase/flutterfire_config.dart';
import 'package:bddouilleur/domain/sql_explainer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const _root = 'projects/demo/databases/(default)';

String _googleServices({String pkg = 'fr.labo.app', String project = 'mon-labo'}) => jsonEncode({
      'project_info': {'project_number': '42', 'project_id': project, 'storage_bucket': '$project.appspot.com'},
      'client': [
        {
          'client_info': {
            'mobilesdk_app_id': '1:42:android:abc',
            'android_client_info': {'package_name': pkg}
          },
          'api_key': [
            {'current_key': "AIza'FAKE\$"}
          ]
        }
      ]
    });

void main() {
  group('Codec des valeurs Firestore', () {
    test('aller-retour sans perte de tous les types', () {
      final data = <String, Object?>{
        's': 'texte',
        'i': 42,
        'd': 1.5,
        'dEntier': {r'$double': 2.0},
        'b': false,
        'n': null,
        't': {r'$timestamp': '2026-11-17T10:00:00.000Z'},
        'r': {r'$ref': 'labos/central'},
        'g': {r'$geo': [48.85, 2.35]},
        'o': {r'$bytes': base64Encode([1, 2, 3])},
        'a': [1, 'deux', {'x': true}],
        'm': {'imbrique': {'niveau': 2}},
      };
      final encoded = FirestoreValueCodec.encodeFields(data, databaseRoot: _root);
      expect(encoded['i'], {'integerValue': '42'});
      expect(encoded['r'], {'referenceValue': '$_root/documents/labos/central'});
      final decoded = FirestoreValueCodec.decodeFields(jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>);
      expect(decoded['t'], {r'$timestamp': '2026-11-17T10:00:00.000Z'});
      decoded['t'] = data['t'];
      expect(decoded, data);
    });

    test('erreurs explicites', () {
      expect(() => FirestoreValueCodec.encodeFields({'__nom__': 1}, databaseRoot: _root), throwsFormatException);
      expect(() => FirestoreValueCodec.encodeValue([[1]], databaseRoot: _root), throwsFormatException);
      expect(() => FirestoreValueCodec.encodeValue({r'$timestamp': 'hier'}, databaseRoot: _root), throwsFormatException);
      expect(() => FirestoreValueCodec.encodeValue({r'$geo': [100, 0]}, databaseRoot: _root), throwsFormatException);
      expect(() => FirestoreValueCodec.encodeValue({r'$ref': 'collection'}, databaseRoot: _root), throwsFormatException);
      expect(() => FirestoreValueCodec.parseJsonObject('[1]'), throwsFormatException);
      expect(() => FirestoreValueCodec.parseJsonObject('{nope'), throwsFormatException);
    });
  });

  group('Règles Firestore', () {
    final design = [
      const CollectionRule('users', CollectionAccess.ownerDocument),
      const CollectionRule('notes', CollectionAccess.ownerField, ownerField: 'auteur'),
      const CollectionRule('catalogue', CollectionAccess.publicRead),
    ];

    test('générateur : fermé par défaut, aucune ouverture critique', () {
      final src = RulesGenerator.generate(design, requireVerifiedEmail: true, now: DateTime(2026, 11, 17));
      expect(src, startsWith("rules_version = '2';"));
      expect(src, contains('match /users/{uid}/{document=**}'));
      expect(src, contains('request.resource.data.auteur == resource.data.auteur'));
      expect(src, contains('email_verified == true'));
      expect(src, isNot(contains('allow write: if true')));
      final findings = RulesAnalyzer.analyze(src);
      expect(RulesAnalyzer.hasCritical(findings), isFalse);
      // seule la lecture publique de « catalogue » est signalée (information)
      expect(findings.map((f) => f.severity), [RuleSeverity.info]);
      expect(findings.single.matchPath, '/catalogue/{docId}');
    });

    test('générateur : noms invalides et doublons refusés', () {
      expect(() => RulesGenerator.generate([const CollectionRule('a b', CollectionAccess.locked)]), throwsFormatException);
      expect(
          () => RulesGenerator.generate(
              [const CollectionRule('x', CollectionAccess.locked), const CollectionRule('x', CollectionAccess.publicRead)]),
          throwsFormatException);
    });

    test('analyseur : mode test, écriture ouverte, tout utilisateur connecté', () {
      const testMode = '''rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if request.time < timestamp.date(2026, 12, 1);
    }
  }
}''';
      final f1 = RulesAnalyzer.analyze(testMode);
      expect(f1.single.title, contains('mode test'));
      expect(f1.single.line, 5);

      const authOnly = '''service cloud.firestore {
  match /databases/{database}/documents {
    // commentaire : allow write: if true;
    match /{document=**} { allow read, write: if request.auth != null; }
    match /public/{id} { allow write; }
  }
}''';
      final f2 = RulesAnalyzer.analyze(authOnly);
      expect(f2.where((f) => f.severity == RuleSeverity.critical).map((f) => f.title),
          containsAll(['Écriture accordée à tout utilisateur connecté', 'Écriture ouverte à tous']));
      expect(f2.any((f) => f.title.contains('rules_version')), isTrue);
      expect(f2.any((f) => f.line == 3), isFalse, reason: 'les commentaires sont ignorés');
    });

    test('cas de test générés cohérents', () {
      final cases = RulesGenerator.testsFor(design);
      expect(cases.where((c) => c.expectAllow), isNotEmpty);
      expect(cases.where((c) => !c.expectAllow).length, greaterThan(cases.where((c) => c.expectAllow).length));
      expect(cases.last.path, startsWith('bdd_collection_non_declaree/'));
    });
  });

  group('FlutterFire', () {
    test('firebase_options.dart généré depuis google-services.json, chaînes échappées', () {
      final cfg = GoogleServicesConfig.parse(_googleServices());
      final src = FlutterFireGenerator.firebaseOptions(cfg, 'fr.labo.app');
      expect(src, contains(r"apiKey: 'AIza\'FAKE\$',"));
      expect(src, contains("appId: '1:42:android:abc',"));
      expect(src, contains("messagingSenderId: '42',"));
      expect(src, contains("storageBucket: 'mon-labo.appspot.com',"));
      expect(FlutterFireGenerator.projectIdsIn(src), {'mon-labo'});
      expect(() => FlutterFireGenerator.firebaseOptions(cfg, 'autre.app'), throwsFormatException);
    });
  });

  group('Firebase Rescue (projet Flutter réel sur disque)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('bdd_rescue_'));
    tearDown(() => dir.deleteSync(recursive: true));

    void write(String rel, String content) {
      final f = File(p.join(dir.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    test('détecte les problèmes réels, corrige INTERNET et vérifie', () async {
      write('pubspec.yaml', 'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n  cloud_firestore: any\n  firebase_auth: ^5.0.0\n');
      write('lib/main.dart', 'void main() { Firebase.initializeApp(); runApp(App()); }');
      write('android/app/build.gradle.kts', 'android { defaultConfig { applicationId = "fr.labo.app"\n minSdk = 21 } }');
      write('android/app/src/main/AndroidManifest.xml',
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n    <application/>\n</manifest>\n');
      write('android/app/google-services.json', _googleServices(pkg: 'fr.autre.app'));
      write('firestore.rules',
          "rules_version = '2';\nservice cloud.firestore { match /databases/{database}/documents { match /{document=**} { allow read, write: if true; } } }");

      final findings = await FlutterFirebaseDiagnostic(dir.path, expectedProjectId: 'mon-labo').run();
      String titles() => findings.map((f) => f.problem).join('\n');
      expect(titles(), contains('firebase_core manquant'));
      expect(titles(), contains('Versions FlutterFire non contraintes : cloud_firestore'));
      expect(titles(), contains('lib/firebase_options.dart introuvable'));
      expect(titles(), contains('WidgetsFlutterBinding.ensureInitialized() absent'));
      expect(titles(), contains('n\'est pas attendu'));
      expect(titles(), contains('ne correspond pas à l\'application'));
      expect(titles(), contains('Plugin Gradle Google Services non appliqué'));
      expect(titles(), contains('minSdk 21 trop bas'));
      expect(titles(), contains('Permission INTERNET absente'));
      expect(titles(), contains('firestore.rules : Écriture ouverte à tous'));

      final internet = findings.firstWhere((f) => f.problem.contains('INTERNET'));
      final report = await internet.fix!.apply();
      expect(report, contains('.bak'));
      final manifest = File(p.join(dir.path, 'android/app/src/main/AndroidManifest.xml')).readAsStringSync();
      expect(manifest, contains('<uses-permission android:name="android.permission.INTERNET"/>'));
      expect(File(p.join(dir.path, 'android/app/src/main/AndroidManifest.xml.bak')).existsSync(), isTrue);

      // Vérification : le problème a disparu.
      final after = await FlutterFirebaseDiagnostic(dir.path).run();
      expect(after.any((f) => f.problem.contains('INTERNET')), isFalse);
    });

    test('génère les fichiers FlutterFire depuis le projet connecté', () async {
      write('pubspec.yaml', 'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n  firebase_core: ^4.0.0\n');
      write('lib/main.dart', 'Future<void> main() async {\n  WidgetsFlutterBinding.ensureInitialized();\n'
          '  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);\n}');
      write('android/app/build.gradle', 'android { defaultConfig { applicationId "fr.labo.app" } }');
      final diag = FlutterFirebaseDiagnostic(dir.path,
          expectedProjectId: 'mon-labo', remoteConfig: (pkg) async => pkg == 'fr.labo.app' ? _googleServices() : null);
      final findings = await diag.run();
      final missing = findings.firstWhere((f) => f.problem.contains('firebase_options.dart introuvable'));
      await missing.fix!.apply();
      expect(File(p.join(dir.path, 'lib/firebase_options.dart')).readAsStringSync(), contains("projectId: 'mon-labo'"));
      expect(File(p.join(dir.path, 'android/app/google-services.json')).existsSync(), isTrue);
      final after = await diag.run();
      expect(after.any((f) => f.severity == DiagSeverity.error), isFalse, reason: after.map((f) => f.problem).join('\n'));
    });

    test('dossier sans pubspec.yaml', () async {
      final f = await FlutterFirebaseDiagnostic(dir.path).run();
      expect(f.single.severity, DiagSeverity.error);
    });
  });

  test('migration de la base interne v1 → v4 sans perte', () {
    final dir = Directory.systemTemp.createTempSync('bdd_mig_');
    final path = p.join(dir.path, 'app.db');
    // Base au format v1 (phase 1).
    final v1 = sqlite3.open(path);
    v1.execute('''
      CREATE TABLE projects (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE connections (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE, name TEXT NOT NULL, engine TEXT NOT NULL, location TEXT NOT NULL, created_at INTEGER NOT NULL, last_opened_at INTEGER);
      CREATE TABLE journal (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id INTEGER, connection_id INTEGER, action TEXT NOT NULL, summary TEXT NOT NULL, sql TEXT, success INTEGER NOT NULL, error TEXT, timestamp INTEGER NOT NULL);
      CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO projects VALUES (1, 'Ancien', '', 0, 0);
      INSERT INTO connections VALUES (1, 1, 'base', 'sqlite', '/x.db', 0, NULL);
      PRAGMA user_version = 1;
    ''');
    v1.close();
    final app = AppDatabase.open(path);
    expect(app.db.userVersion, 4);
    expect(app.db.select("SELECT name FROM sqlite_master WHERE name = 'autopilot_runs'"), hasLength(1));
    expect(app.db.select("SELECT name FROM sqlite_master WHERE name = 'ai_conversations'"), hasLength(1));
    final row = app.db.select('SELECT name, config FROM connections').single;
    expect(row['name'], 'base');
    expect(row['config'], '{}');
    app.close();
    dir.deleteSync(recursive: true);
  });

  test('cible Firebase : validation et sérialisation sans secret', () {
    expect(FirebaseTarget.validateEmulatorProjectId('demo-labo'), isNull);
    expect(FirebaseTarget.validateEmulatorProjectId('vrai-projet'), isNotNull);
    expect(FirebaseTarget.validateHost('192.168.1.10:8080'), isNull);
    expect(FirebaseTarget.validateHost('localhost'), isNotNull);
    const t = FirebaseTarget(mode: FirebaseMode.emulator, projectId: 'demo-labo', firestoreHost: '10.0.0.2:8080');
    final back = FirebaseTarget.fromJson(t.toJson());
    expect(back.documentsRoot, 'http://10.0.0.2:8080/v1/projects/demo-labo/databases/(default)/documents');
    const g = FirebaseTarget(mode: FirebaseMode.google, projectId: 'mon-labo');
    expect(g.toJson().containsKey('firestoreHost'), isFalse);
    expect(g.firestoreBase, 'https://firestore.googleapis.com/v1');
  });

  test('Le Professeur explique les requêtes REST journalisées', () {
    final lines = SqlExplainer.explain(
        'POST http://127.0.0.1:8080/v1/projects/demo/databases/(default)/documents/potions?documentId=elixir');
    expect(lines.first, contains('émulateur'));
    expect(lines.last, contains('« potions »'));
    expect(lines.last, contains('collection vide'));
    final multi = SqlExplainer.explain('POST https://firebaserules.googleapis.com/v1/projects/p/rulesets\n'
        'PATCH https://firebaserules.googleapis.com/v1/projects/p/releases/cloud.firestore');
    expect(multi.first, contains('2 requêtes'));
    expect(multi.last, contains('Publication'));
  });
}
