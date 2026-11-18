import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/schema.dart';
import '../../domain/schema_proposal.dart';

class DetectedField {
  const DetectedField(this.name, this.type, {this.nullable = false});
  final String name;

  /// Type tel qu'écrit dans le code source.
  final String type;
  final bool nullable;
}

class DetectedModel {
  const DetectedModel(this.name, this.file, this.fields);
  final String name;
  final String file;
  final List<DetectedField> fields;
}

class ProjectAnalysis {
  ProjectAnalysis(this.root);
  final String root;
  String technology = 'Inconnue';
  final List<String> frameworks = [];
  int fileCount = 0;
  int sourceFileCount = 0;
  final Map<String, String> storage = {};
  final Map<String, String> auth = {};
  final List<String> otherDependencies = [];
  final List<DetectedModel> models = [];
  final List<String> services = [];
  final Map<String, int> apiHosts = {};
  final List<String> configs = [];
  final List<String> findings = [];
  bool truncated = false;

  /// Résumé texte, utilisé par l'écran et donné tel quel à l'agent IA.
  String toText() {
    final b = StringBuffer()
      ..writeln('Projet : $root')
      ..writeln('Technologie : $technology${frameworks.isEmpty ? '' : ' (${frameworks.join(', ')})'}')
      ..writeln('Fichiers : $fileCount, dont $sourceFileCount fichiers source${truncated ? ' (analyse limitée)' : ''}')
      ..writeln('Stockage : ${storage.isEmpty ? 'aucun détecté' : storage.entries.map((e) => '${e.key} (${e.value})').join(', ')}')
      ..writeln('Authentification : ${auth.isEmpty ? 'aucune détectée' : auth.entries.map((e) => '${e.key} (${e.value})').join(', ')}');
    if (models.isNotEmpty) {
      b.writeln('Modèles de données (${models.length}) :');
      for (final m in models) {
        b.writeln('- ${m.name} [${m.file}] : ${m.fields.map((f) => '${f.name}: ${f.type}${f.nullable ? '?' : ''}').join(', ')}');
      }
    }
    if (services.isNotEmpty) b.writeln('Services / dépôts : ${services.join(', ')}');
    if (apiHosts.isNotEmpty) b.writeln('Appels API vers : ${apiHosts.entries.map((e) => '${e.key} (${e.value}×)').join(', ')}');
    if (configs.isNotEmpty) b.writeln('Configurations : ${configs.join(', ')}');
    for (final f in findings) {
      b.writeln('Constat : $f');
    }
    return b.toString().trim();
  }

  Map<String, Object?> toJson() => {
        'root': root,
        'technology': technology,
        'frameworks': frameworks,
        'storage': storage,
        'auth': auth,
        'models': [
          for (final m in models)
            {
              'name': m.name,
              'file': m.file,
              'fields': [for (final f in m.fields) '${f.name}: ${f.type}${f.nullable ? '?' : ''}']
            }
        ],
        'services': services,
        'apiHosts': apiHosts,
        'configs': configs,
        'findings': findings,
      };
}

/// Analyse déterministe d'un dossier de projet (aucune IA, aucune écriture).
/// Les valeurs des fichiers de secrets (.env, clés) ne sont jamais lues.
class ProjectAnalyzer {
  ProjectAnalyzer(this.root, {this.maxFiles = 4000, this.maxFileBytes = 300 * 1024});
  final String root;
  final int maxFiles;
  final int maxFileBytes;

  static const _skipDirs = {
    '.git', 'build', 'node_modules', '.dart_tool', '.idea', '.vscode', '.gradle', 'Pods', 'venv', '.venv', 'env',
    '__pycache__', 'dist', '.next', '.nuxt', 'coverage', 'target', '.angular', 'vendor', '.fvm', 'ephemeral',
  };
  static const _sourceExt = {'.dart', '.ts', '.tsx', '.js', '.jsx', '.vue', '.py', '.java', '.kt', '.go', '.php', '.rb', '.swift'};

  /// Fichiers dont le contenu n'est jamais lu (secrets potentiels).
  static bool isSecretFile(String path) {
    final name = p.basename(path).toLowerCase();
    return name == '.env' ||
        name.startsWith('.env.') ||
        name.endsWith('.jks') ||
        name.endsWith('.keystore') ||
        name.endsWith('.pem') ||
        name.endsWith('.p12') ||
        name == 'key.properties' ||
        name == 'credentials.json' ||
        name.contains('service-account') ||
        name.contains('serviceaccount');
  }

  static const _storageDeps = {
    'sqflite': 'SQLite (sqflite)', 'drift': 'SQLite (Drift)', 'floor': 'SQLite (Floor)', 'sqlite3': 'SQLite',
    'hive': 'Hive', 'hive_flutter': 'Hive', 'isar': 'Isar', 'objectbox': 'ObjectBox', 'shared_preferences': 'Préférences clé-valeur',
    'cloud_firestore': 'Firestore', 'firebase_database': 'Firebase Realtime Database', 'firebase_storage': 'Firebase Storage',
    'supabase_flutter': 'Supabase', '@supabase/supabase-js': 'Supabase', 'firebase': 'Firebase (JS)',
    'mongoose': 'MongoDB (Mongoose)', 'mongodb': 'MongoDB', 'prisma': 'Prisma', '@prisma/client': 'Prisma',
    'sequelize': 'Sequelize (SQL)', 'typeorm': 'TypeORM (SQL)', 'pg': 'PostgreSQL', 'mysql2': 'MySQL', 'better-sqlite3': 'SQLite',
    'redis': 'Redis', 'ioredis': 'Redis', 'sqlalchemy': 'SQLAlchemy', 'psycopg2': 'PostgreSQL', 'psycopg2-binary': 'PostgreSQL',
    'psycopg': 'PostgreSQL', 'pymongo': 'MongoDB', 'django': 'ORM Django', 'peewee': 'Peewee', 'tortoise-orm': 'Tortoise ORM',
  };
  static const _authDeps = {
    'firebase_auth': 'Firebase Authentication', 'google_sign_in': 'Connexion Google', 'sign_in_with_apple': 'Connexion Apple',
    'local_auth': 'Biométrie', 'flutter_appauth': 'OAuth', 'passport': 'Passport', 'next-auth': 'NextAuth',
    'jsonwebtoken': 'JWT', '@auth0/auth0-react': 'Auth0', 'firebase-admin': 'Firebase Admin', 'flask-login': 'Flask-Login',
    'djangorestframework-simplejwt': 'JWT (Django)', 'python-jose': 'JWT', 'pyjwt': 'JWT', 'bcrypt': 'Hachage de mots de passe',
  };

  Future<ProjectAnalysis> run() async {
    final dir = Directory(root);
    if (!dir.existsSync()) throw FileSystemException('Dossier introuvable', root);
    final a = ProjectAnalysis(root);
    final files = <File>[];
    _walk(dir, files, a);
    a.fileCount = files.length;

    final deps = <String>{};
    _detectTechnology(a, deps);
    for (final d in deps) {
      final key = d.toLowerCase();
      if (_storageDeps.containsKey(key)) {
        a.storage[d] = _storageDeps[key]!;
      } else if (_authDeps.containsKey(key)) {
        a.auth[d] = _authDeps[key]!;
      } else {
        a.otherDependencies.add(d);
      }
    }

    final urlRe = RegExp(r'''https?://([A-Za-z0-9.\-]+)''');
    final apiCallRe = RegExp(r'(http\.(get|post|put|patch|delete)|dio\.|Dio\(|fetch\(|axios[.(]|requests\.(get|post|put|delete)|HttpClient)');
    for (final f in files) {
      final rel = p.relative(f.path, from: root);
      final name = p.basename(rel).toLowerCase();
      if (isSecretFile(rel)) {
        a.configs.add('$rel (secret : contenu non lu)');
        continue;
      }
      if (name == 'firebase_options.dart' || name == 'google-services.json' || name == 'firebase.json' ||
          name == 'firestore.rules' || name == 'docker-compose.yml' || name == 'docker-compose.yaml' ||
          name == 'schema.prisma' || name == 'alembic.ini' || name.endsWith('.sql')) {
        a.configs.add(rel);
      }
      final ext = p.extension(name);
      if (!_sourceExt.contains(ext) && name != 'schema.prisma') continue;
      a.sourceFileCount++;
      if (RegExp(r'(service|repositor|repo|dao|api|store|provider|datasource|data_source)').hasMatch(name) &&
          !name.contains('test')) {
        a.services.add(rel);
      }
      if (f.lengthSync() > maxFileBytes) continue;
      final String text;
      try {
        text = f.readAsStringSync();
      } catch (_) {
        continue;
      }
      if (rel.contains('test')) continue;
      if (apiCallRe.hasMatch(text)) {
        for (final m in urlRe.allMatches(text)) {
          final host = m.group(1)!;
          if (host.contains('schemas.android') || host.contains('w3.org') || host == 'localhost') continue;
          a.apiHosts[host] = (a.apiHosts[host] ?? 0) + 1;
        }
      }
      switch (ext) {
        case '.dart':
          a.models.addAll(_dartModels(text, rel));
        case '.ts' || '.tsx':
          a.models.addAll(_tsModels(text, rel));
        case '.py':
          a.models.addAll(_pythonModels(text, rel));
      }
      if (name == 'schema.prisma') a.models.addAll(_prismaModels(text, rel));
    }
    _conclude(a);
    return a;
  }

  void _walk(Directory dir, List<File> out, ProjectAnalysis a) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final e in entries) {
      if (out.length >= maxFiles) {
        a.truncated = true;
        return;
      }
      final name = p.basename(e.path);
      if (e is Directory) {
        if (_skipDirs.contains(name) || (name.startsWith('.') && name != '.github')) continue;
        _walk(e, out, a);
      } else if (e is File) {
        out.add(e);
      }
    }
  }

  String? _read(String rel) {
    final f = File(p.join(root, rel));
    if (!f.existsSync() || f.lengthSync() > maxFileBytes) return null;
    try {
      return f.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  void _detectTechnology(ProjectAnalysis a, Set<String> deps) {
    final pubspec = _read('pubspec.yaml');
    final pkg = _read('package.json');
    final req = _read('requirements.txt');
    final pyproject = _read('pyproject.toml');
    if (pubspec != null) {
      var inDeps = false;
      for (final line in pubspec.split('\n')) {
        if (RegExp(r'^\S').hasMatch(line)) inDeps = line.startsWith('dependencies:') || line.startsWith('dev_dependencies:');
        final m = RegExp(r'^  ([a-z0-9_]+):').firstMatch(line);
        if (inDeps && m != null) deps.add(m.group(1)!);
      }
      a.technology = deps.contains('flutter') ? 'Flutter' : 'Dart';
      deps.remove('flutter');
    }
    if (pkg != null) {
      try {
        final j = jsonDecode(pkg) as Map;
        for (final k in ['dependencies', 'devDependencies']) {
          deps.addAll(((j[k] as Map?) ?? const {}).keys.cast<String>());
        }
      } catch (_) {
        a.findings.add('package.json illisible.');
      }
      if (a.technology == 'Inconnue') a.technology = 'Node.js';
      for (final (dep, label) in [
        ('react', 'React'), ('next', 'Next.js'), ('@angular/core', 'Angular'), ('vue', 'Vue.js'), ('nuxt', 'Nuxt'),
        ('express', 'Express'), ('@nestjs/core', 'NestJS'), ('svelte', 'Svelte'), ('react-native', 'React Native'),
      ]) {
        if (deps.contains(dep)) a.frameworks.add(label);
      }
    }
    if (req != null || pyproject != null) {
      for (final line in (req ?? '').split('\n')) {
        final l = line.trim();
        if (l.isEmpty || l.startsWith('#') || l.startsWith('-')) continue;
        final m = RegExp(r'^([A-Za-z0-9_\-.]+)').firstMatch(l);
        if (m != null) deps.add(m.group(1)!.toLowerCase());
      }
      // pyproject.toml : chaînes de dépendances du type "django>=5".
      for (final m in RegExp(r'''["']([A-Za-z0-9_\-.]+)\s*(?:[<>=~!\[;]|["'])''').allMatches(pyproject ?? '')) {
        deps.add(m.group(1)!.toLowerCase());
      }
      if (a.technology == 'Inconnue') a.technology = 'Python';
      for (final (dep, label) in [('django', 'Django'), ('flask', 'Flask'), ('fastapi', 'FastAPI')]) {
        if (deps.contains(dep)) a.frameworks.add(label);
      }
    }
    if (a.technology == 'Inconnue') {
      if (_read('go.mod') != null) a.technology = 'Go';
      if (_read('pom.xml') != null || _read('build.gradle') != null || _read('build.gradle.kts') != null) a.technology = 'Java / Kotlin';
      if (_read('composer.json') != null) a.technology = 'PHP';
    }
  }

  static const _notModels = {'StatelessWidget', 'StatefulWidget', 'State', 'ChangeNotifier', 'CustomPainter', 'Bloc', 'Cubit'};

  List<DetectedModel> _dartModels(String text, String rel) {
    final out = <DetectedModel>[];
    final classRe = RegExp(r'^(?:@\w+(?:\([^)]*\))?\s*)*(?:abstract\s+|final\s+|sealed\s+)?class\s+([A-Z]\w*)([^{]*)\{', multiLine: true);
    for (final m in classRe.allMatches(text)) {
      final name = m.group(1)!;
      final header = m.group(2)!;
      if (_notModels.any((w) => header.contains(w)) || name.startsWith('_') || name.endsWith('Screen') ||
          name.endsWith('Page') || name.endsWith('Widget') || name.endsWith('State') || name.endsWith('Service') ||
          name.endsWith('Repository') || name.endsWith('Exception')) {
        continue;
      }
      final body = _block(text, m.end - 1);
      final fields = <DetectedField>[];
      for (final f in RegExp(r'^\s{2}(?:final|late final|late)?\s*([A-Z][\w<>, ?]*|int|double|num|bool|String|DateTime)(\?)?\s+(\w+)\s*;',
              multiLine: true)
          .allMatches(body)) {
        fields.add(DetectedField(f.group(3)!, f.group(1)!.trim(), nullable: f.group(2) != null));
      }
      if (fields.length >= 2) out.add(DetectedModel(name, rel, fields));
    }
    return out;
  }

  List<DetectedModel> _tsModels(String text, String rel) {
    final out = <DetectedModel>[];
    for (final m in RegExp(r'(?:export\s+)?(?:interface|type|class)\s+([A-Z]\w*)\s*(?:=\s*)?\{').allMatches(text)) {
      final body = _block(text, m.end - 1);
      final fields = [
        for (final f in RegExp(r'^\s*(?:readonly\s+)?(\w+)(\?)?\s*:\s*([^;,\n]+)', multiLine: true).allMatches(body))
          if (!f.group(3)!.contains('=>')) DetectedField(f.group(1)!, f.group(3)!.trim(), nullable: f.group(2) != null),
      ];
      if (fields.length >= 2 && !m.group(1)!.endsWith('Props') && !m.group(1)!.endsWith('State')) {
        out.add(DetectedModel(m.group(1)!, rel, fields));
      }
    }
    return out;
  }

  List<DetectedModel> _pythonModels(String text, String rel) {
    final out = <DetectedModel>[];
    final classRe = RegExp(r'^class\s+([A-Z]\w*)\((?:models\.Model|BaseModel|Base|db\.Model|SQLModel)[^)]*\):\s*$', multiLine: true);
    for (final m in classRe.allMatches(text)) {
      final rest = text.substring(m.end);
      final end = RegExp(r'^\S', multiLine: true).firstMatch(rest)?.start ?? rest.length;
      final body = rest.substring(0, end);
      final fields = <DetectedField>[];
      for (final f in RegExp(r'^\s{4}(\w+)\s*=\s*(?:models|db|sa)\.(\w+)', multiLine: true).allMatches(body)) {
        fields.add(DetectedField(f.group(1)!, f.group(2)!, nullable: body.contains('${f.group(1)} = ') && body.contains('null=True')));
      }
      for (final f in RegExp(r'^\s{4}(\w+)\s*:\s*([\w\[\]., |]+?)(?:\s*=.*)?$', multiLine: true).allMatches(body)) {
        if (fields.any((x) => x.name == f.group(1))) continue;
        fields.add(DetectedField(f.group(1)!, f.group(2)!.trim(), nullable: f.group(2)!.contains('None') || f.group(2)!.contains('Optional')));
      }
      if (fields.length >= 2) out.add(DetectedModel(m.group(1)!, rel, fields));
    }
    return out;
  }

  List<DetectedModel> _prismaModels(String text, String rel) => [
        for (final m in RegExp(r'^model\s+(\w+)\s*\{', multiLine: true).allMatches(text))
          DetectedModel(m.group(1)!, rel, [
            for (final f in RegExp(r'^\s+(\w+)\s+(\w+)(\?)?', multiLine: true).allMatches(_block(text, m.end - 1)))
              DetectedField(f.group(1)!, f.group(2)!, nullable: f.group(3) != null),
          ]),
      ];

  /// Contenu entre l'accolade ouvrante à [open] et sa fermante.
  static String _block(String text, int open) {
    var depth = 0;
    for (var i = open; i < text.length; i++) {
      final c = text[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return text.substring(open + 1, i);
      }
    }
    return text.substring(open + 1);
  }

  void _conclude(ProjectAnalysis a) {
    if (a.models.isNotEmpty && a.storage.isEmpty) {
      a.findings.add('${a.models.length} modèle(s) de données mais aucun stockage persistant : les données sont perdues à la fermeture de l\'application.');
    }
    if (a.storage.keys.any((k) => k == 'shared_preferences') && a.models.length > 2) {
      a.findings.add('Des préférences clé-valeur sont utilisées alors que l\'application manipule plusieurs entités : une vraie base serait plus adaptée.');
    }
    if (a.storage.values.any((v) => v.contains('Firestore')) && !a.configs.any((c) => c.endsWith('firestore.rules'))) {
      a.findings.add('Firestore est utilisé mais aucune règle de sécurité n\'est versionnée (firestore.rules).');
    }
    if (a.auth.isEmpty && a.models.any((m) => RegExp(r'user|utilisateur|account|compte', caseSensitive: false).hasMatch(m.name))) {
      a.findings.add('Des utilisateurs sont modélisés mais aucune authentification n\'est détectée.');
    }
    if (a.configs.any((c) => c.contains('secret'))) {
      a.findings.add('Des fichiers de secrets sont présents : vérifiez qu\'ils sont exclus du dépôt (.gitignore).');
    }
  }

  // ---------------------------------------------------------------- schéma

  static SqlColumnType sqlTypeFor(String type) {
    final t = type.toLowerCase().replaceAll('?', '');
    if (RegExp(r'^(int|integer|bigint|smallint|integerfield|bigintegerfield|positiveintegerfield|autofield)$').hasMatch(t)) {
      return SqlColumnType.integer;
    }
    if (RegExp(r'^(double|float|num|number|floatfield|decimal|decimalfield)$').hasMatch(t)) return SqlColumnType.real;
    if (RegExp(r'^(bool|boolean|booleanfield)$').hasMatch(t)) return SqlColumnType.boolean;
    if (RegExp(r'datetime|timestamp|date$|datefield|datetimefield').hasMatch(t)) return SqlColumnType.datetime;
    if (RegExp(r'uint8list|bytes|blob|binaryfield').hasMatch(t)) return SqlColumnType.blob;
    return SqlColumnType.text;
  }

  /// Proposition d'architecture déduite des modèles détectés : une entité par
  /// modèle, relations déduites des champs « xxxId » et des types de modèles.
  static SchemaProposal proposeSchema(ProjectAnalysis a) {
    final names = {for (final m in a.models) m.name.toLowerCase(): m.name};
    final entities = <EntityProposal>[];
    final seen = <String>{};
    for (final m in a.models) {
      if (!seen.add(m.name.toLowerCase())) continue;
      final fields = <FieldProposal>[];
      for (final f in m.fields) {
        final col = SchemaProposal.columnName(f.name);
        if (col == 'id' || col == 'uid' && m.fields.any((x) => x.name == 'id')) continue;
        final idRef = RegExp(r'^(\w+?)_?[Ii]d$').firstMatch(f.name);
        final refName = idRef == null ? null : names[idRef.group(1)!.toLowerCase()];
        final typeRef = names[f.type.replaceAll('?', '').toLowerCase()];
        if (RegExp(r'^(List|Set|Iterable)<').hasMatch(f.type) || f.type.endsWith('[]')) continue; // côté « plusieurs »
        if (typeRef != null && typeRef != m.name) {
          fields.add(FieldProposal(name: '${f.name}Id', type: SqlColumnType.integer, required: !f.nullable, references: typeRef));
        } else if (refName != null && refName != m.name) {
          fields.add(FieldProposal(name: f.name, type: SqlColumnType.integer, required: !f.nullable, references: refName));
        } else {
          fields.add(FieldProposal(name: f.name, type: sqlTypeFor(f.type), required: !f.nullable));
        }
      }
      if (fields.isNotEmpty) entities.add(EntityProposal(name: m.name, fields: fields, source: m.file));
    }
    final rel = entities.expand((e) => e.fields.where((f) => f.references != null)).length;
    return SchemaProposal(
      entities: entities,
      summary: entities.isEmpty
          ? 'Aucun modèle de données exploitable n\'a été trouvé.'
          : 'Cette application manipule ${entities.map((e) => e.name).join(', ')}. '
              'Je propose ${entities.length} entité(s)${rel == 0 ? '' : ' et $rel relation(s)'}.',
    );
  }
}
