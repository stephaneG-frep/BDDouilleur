import 'dart:convert';
import 'dart:io';

import 'package:bddouilleur/data/security/security_auditor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('bdd_gardien_'));
  tearDown(() => dir.deleteSync(recursive: true));

  void write(String rel, String content) {
    final f = File(p.join(dir.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  // Fausses valeurs assemblées à l'exécution (aucune chaîne ressemblant à une clé dans le dépôt).
  final fakeAws = 'AK${'IA'}${'Z' * 16}';
  final fakeAnthropic = 'sk-${'ant'}-${'a1b2c3d4' * 4}';
  String b64(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final fakeServiceRole = '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64({'role': 'service' '_role', 'iss': 'supabase'})}.${'s' * 20}';

  test('audit : chaque catégorie détectée, secrets masqués, correction .gitignore', () async {
    write('pubspec.yaml', 'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n  supabase_flutter: ^2.0.0\n');
    write('lib/config.dart', "const aws = '$fakeAws';\nconst claude = '$fakeAnthropic';\nconst supa = '$fakeServiceRole';\n"
        "const db = 'postgres://admin:Sup3rS3cret@db.example.org:5432/prod';\nconst api = 'http://api.boutique.fr/v1';\n");
    write('lib/repo.dart', "Future<void> f(String nom) async {\n  await db.rawQuery('SELECT * FROM clients WHERE nom = \$nom');\n}\n");
    write('server/app.py', 'cursor.execute(f"SELECT * FROM users WHERE id = {user_id}")\nconn = connect("host=x sslmode=disable")\n');
    write('android/app/src/main/AndroidManifest.xml',
        '<manifest><uses-permission android:name="android.permission.READ_SMS"/><application android:usesCleartextTraffic="true"/></manifest>');
    write('firestore.rules', "rules_version = '2';\nservice cloud.firestore { match /databases/{database}/documents { match /{document=**} { allow read, write: if true; } } }");
    write('supabase/migrations/001.sql', 'create table profils (id uuid primary key);\ncreate table notes (id int);\n'
        'alter table notes enable row level security;\ncreate policy p on notes for select using (true);\n');
    write('keys/compte.json', jsonEncode({'type': 'service_account', 'private_key': '-----BEGIN ' 'PRIVATE KEY-----\\nabc'}));
    write('.env', 'API_KEY=valeur-tres-secrete');
    write('.gitignore', 'build/\n');
    write('lib/firebase_options.dart', "projectId: 'mon-appli-prod',");
    write('test/api_test.dart', "// utilise mon-appli-prod\nconst password = 'motdepassedetest';");

    final f = await SecurityAuditor(dir.path).run();
    String all() => f.map((x) => '${x.severity.name} ${x.category.name} ${x.title} ${x.explanation} ${x.location}').join('\n');

    expect(f.first.severity, SecuritySeverity.critical, reason: 'tri par gravité');
    expect(all(), contains('Clé d\'accès AWS en clair'));
    expect(all(), contains('Clé API Anthropic en clair'));
    expect(all(), contains('« service_role »'));
    expect(all(), contains('Chaîne de connexion avec mot de passe'));
    expect(all(), contains('Clé de compte de service Google'));
    expect(f.where((x) => x.category == SecurityCategory.injection).map((x) => x.location), containsAll(['lib/repo.dart:2', 'server/app.py:1']));
    expect(all(), contains('Connexion non chiffrée (http://)'));
    expect(all(), contains('Chiffrement de la connexion à la base désactivé'));
    expect(all(), contains('Trafic HTTP en clair autorisé'));
    expect(all(), contains('Permission sensible : READ_SMS'));
    expect(all(), contains('Règles Firestore : Écriture ouverte à tous'));
    expect(all(), contains('Table Supabase « profils » sans RLS'));
    expect(all(), isNot(contains('« notes » sans RLS')));
    expect(all(), contains('Politique RLS ouverte à tous'));
    expect(all(), contains('Un seul environnement Firebase (« mon-appli-prod »)'));
    expect(f.firstWhere((x) => x.category == SecurityCategory.environments).severity, SecuritySeverity.medium);

    // Les secrets ne sont jamais restitués en clair.
    for (final secret in [fakeAws, fakeAnthropic, fakeServiceRole, 'Sup3rS3cret', 'valeur-tres-secrete']) {
      expect(all(), isNot(contains(secret)), reason: 'secret masqué');
    }

    final gitignore = f.firstWhere((x) => x.title == 'Fichier de secrets non exclu de git');
    await gitignore.fix!.apply();
    expect(File(p.join(dir.path, '.gitignore')).readAsStringSync(), contains('.env*'));
    expect(File(p.join(dir.path, '.gitignore.bak')).existsSync(), isTrue);
    final again = await SecurityAuditor(dir.path).run();
    expect(again.any((x) => x.title == 'Fichier de secrets non exclu de git'), isFalse);
  });

  test('projet propre : aucune alerte élevée', () async {
    write('pubspec.yaml', 'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n');
    write('lib/repo.dart', "Future<void> f(db, String nom) => db.rawQuery('SELECT * FROM clients WHERE nom = ?', [nom]);\n"
        "const local = 'http://127.0.0.1:8080';\nconst api = 'https://api.boutique.fr';\n");
    final f = await SecurityAuditor(dir.path).run();
    expect(f.where((x) => x.severity.index <= SecuritySeverity.medium.index), isEmpty, reason: f.map((x) => x.title).join(', '));
  });

  test('masquage', () {
    expect(SecurityAuditor.mask('abc'), '••••');
    expect(SecurityAuditor.mask('abcdefghijkl'), 'abcd…kl (12 caractères)');
  });
}
