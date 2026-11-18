import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/schema.dart';
import '../../domain/schema_proposal.dart';
import '../connectors/sqlite/sqlite_sql_builder.dart';

enum CodegenBackend {
  sqlite('SQLite (sqflite)', ['sqflite', 'path'], ['sqflite_common_ffi']),
  firestore('Cloud Firestore', ['cloud_firestore', 'firebase_core'], ['fake_cloud_firestore']);

  const CodegenBackend(this.label, this.dependencies, this.devDependencies);
  final String label;
  final List<String> dependencies;
  final List<String> devDependencies;
}

/// Un fichier du plan : contenu actuel (null si nouveau) et contenu proposé.
class PlannedFile {
  PlannedFile({required this.path, required this.content, this.previous, required this.purpose});

  /// Chemin relatif à la racine du projet Flutter.
  final String path;
  final String content;
  final String? previous;
  final String purpose;

  bool get isNew => previous == null;
  bool get unchanged => previous == content;
}

/// Plan d'intégration affiché AVANT toute écriture.
class CodegenPlan {
  CodegenPlan({
    required this.projectDir,
    required this.packageName,
    required this.backend,
    required this.files,
    required this.missingDependencies,
    required this.missingDevDependencies,
    required this.notes,
  });

  final String projectDir;
  final String packageName;
  final CodegenBackend backend;
  final List<PlannedFile> files;
  final List<String> missingDependencies;
  final List<String> missingDevDependencies;
  final List<String> notes;

  List<String> get testFiles => [for (final f in files) if (f.path.startsWith('test/')) f.path];
}

/// Analyse rapide de l'architecture d'un projet Flutter existant.
class FlutterProjectLayout {
  FlutterProjectLayout({
    required this.packageName,
    required this.modelsDir,
    required this.repositoriesDir,
    required this.servicesDir,
    required this.dependencies,
  });

  final String packageName;
  final String modelsDir;
  final String repositoriesDir;
  final String servicesDir;
  final Set<String> dependencies;

  static FlutterProjectLayout read(String projectDir) {
    final pubspec = File(p.join(projectDir, 'pubspec.yaml'));
    if (!pubspec.existsSync()) throw FileSystemException('pubspec.yaml introuvable : ce n\'est pas un projet Flutter', projectDir);
    final text = pubspec.readAsStringSync();
    final name = RegExp(r'^name:\s*([a-z0-9_]+)', multiLine: true).firstMatch(text)?.group(1);
    if (name == null) throw const FormatException('Nom du paquet introuvable dans pubspec.yaml.');
    final deps = <String>{};
    var inDeps = false;
    for (final line in text.split('\n')) {
      if (RegExp(r'^\S').hasMatch(line)) inDeps = line.startsWith('dependencies:') || line.startsWith('dev_dependencies:');
      final m = RegExp(r'^  ([a-z0-9_]+):').firstMatch(line);
      if (inDeps && m != null) deps.add(m.group(1)!);
    }
    String pick(List<String> candidates, String fallback) =>
        candidates.firstWhere((c) => Directory(p.join(projectDir, c)).existsSync(), orElse: () => fallback);
    return FlutterProjectLayout(
      packageName: name,
      modelsDir: pick(['lib/domain/models', 'lib/models', 'lib/data/models', 'lib/src/models', 'lib/model'], 'lib/models'),
      repositoriesDir: pick(['lib/data/repositories', 'lib/repositories', 'lib/src/repositories', 'lib/data/repository', 'lib/repository'],
          'lib/data/repositories'),
      servicesDir: pick(['lib/services', 'lib/domain/services', 'lib/src/services', 'lib/data/services', 'lib/service'], 'lib/services'),
      dependencies: deps,
    );
  }
}

/// Générateur déterministe de code Flutter (modèles, dépôts, services, tests).
class FlutterCodeGenerator {
  FlutterCodeGenerator(this.proposal, this.backend);
  final SchemaProposal proposal;
  final CodegenBackend backend;

  static String snake(String s) => SchemaProposal.columnName(s);
  static String camel(String s) {
    final parts = s.split('_').where((x) => x.isNotEmpty).toList();
    if (parts.isEmpty) return s;
    return parts.first[0].toLowerCase() + parts.first.substring(1) + parts.skip(1).map((x) => x[0].toUpperCase() + x.substring(1)).join();
  }

  static String pascal(String s) {
    final c = camel(s);
    return c.isEmpty ? c : c[0].toUpperCase() + c.substring(1);
  }

  bool get _sqlite => backend == CodegenBackend.sqlite;

  String _dartType(FieldProposal f) {
    if (f.references != null) return _sqlite ? 'int' : 'String';
    return switch (f.type) {
      SqlColumnType.integer => 'int',
      SqlColumnType.real || SqlColumnType.numeric => 'double',
      SqlColumnType.boolean => 'bool',
      SqlColumnType.date || SqlColumnType.datetime => 'DateTime',
      SqlColumnType.blob => 'Uint8List',
      SqlColumnType.text => 'String',
    };
  }

  String _fromMap(FieldProposal f, String key) {
    final t = _dartType(f);
    final v = "map['$key']";
    final expr = switch (t) {
      'int' => _sqlite ? '($v as num).toInt()' : '$v as String',
      'double' => '($v as num).toDouble()',
      'bool' => _sqlite ? '($v as int) == 1' : '$v as bool',
      'DateTime' => '_readDate($v)',
      'Uint8List' => _sqlite ? '$v as Uint8List' : '_readBytes($v)',
      _ => '$v as String',
    };
    if (f.references != null && !_sqlite) return f.required ? '$v as String' : '$v as String?';
    return f.required ? expr : '$v == null ? null : $expr';
  }

  String _toMap(FieldProposal f, String name) {
    final t = _dartType(f);
    final n = f.required ? name : '$name?';
    return switch (t) {
      'bool' when _sqlite => f.required ? '$name ? 1 : 0' : '$name == null ? null : ($name! ? 1 : 0)',
      'DateTime' => _sqlite ? '$n.toIso8601String()' : name,
      _ => name,
    };
  }

  String _key(FieldProposal f) => _sqlite ? f.columnName : camel(f.name);

  String model(EntityProposal e) {
    final cls = pascal(e.name);
    final fields = e.fields;
    final hasBlob = fields.any((f) => _dartType(f) == 'Uint8List');
    final hasDate = fields.any((f) => _dartType(f) == 'DateTime');
    final idType = _sqlite ? 'int' : 'String';
    final b = StringBuffer()
      ..writeln('// Généré par BDDouilleur. ${e.description.isEmpty ? '' : e.description}'.trimRight())
      ..writeln(hasBlob ? "import 'dart:typed_data';\n" : '')
      ..writeln('/// Entité « $cls »${_sqlite ? ' (table ${e.tableName})' : ' (collection ${_collection(e)})'}.')
      ..writeln('class $cls {')
      ..writeln('  const $cls({')
      ..writeln('    this.id,');
    for (final f in fields) {
      b.writeln('    ${f.required ? 'required ' : ''}this.${camel(f.name)},');
    }
    b
      ..writeln('  });')
      ..writeln()
      ..writeln('  /// Identifiant attribué par la base (nul avant l\'enregistrement).')
      ..writeln('  final $idType? id;');
    for (final f in fields) {
      b.writeln('  final ${_dartType(f)}${f.required ? '' : '?'} ${camel(f.name)};');
    }
    b
      ..writeln()
      ..writeln('  factory $cls.fromMap(Map<String, Object?> map${_sqlite ? '' : ', {String? id}'}) => $cls(')
      ..writeln(_sqlite ? "        id: map['id'] == null ? null : (map['id'] as num).toInt()," : '        id: id,');
    for (final f in fields) {
      b.writeln('        ${camel(f.name)}: ${_fromMap(f, _key(f))},');
    }
    b
      ..writeln('      );')
      ..writeln()
      ..writeln('  Map<String, Object?> toMap() => {')
      ..writeln(_sqlite ? "        if (id != null) 'id': id," : '');
    for (final f in fields) {
      b.writeln("        '${_key(f)}': ${_toMap(f, camel(f.name))},");
    }
    b
      ..writeln('      };')
      ..writeln()
      ..writeln('  $cls copyWith({')
      ..writeln('    $idType? id,');
    for (final f in fields) {
      b.writeln('    ${_dartType(f)}? ${camel(f.name)},');
    }
    b
      ..writeln('  }) =>')
      ..writeln('      $cls(')
      ..writeln('        id: id ?? this.id,');
    for (final f in fields) {
      final n = camel(f.name);
      b.writeln('        $n: $n ?? this.$n,');
    }
    b
      ..writeln('      );')
      ..writeln()
      ..writeln('  @override')
      ..writeln('  bool operator ==(Object other) =>')
      ..writeln('      other is $cls && other.id == id${fields.where((f) => _dartType(f) != 'Uint8List').map((f) => ' && other.${camel(f.name)} == ${camel(f.name)}').join()};')
      ..writeln()
      ..writeln('  @override')
      ..writeln('  int get hashCode => Object.hashAll([id${fields.where((f) => _dartType(f) != 'Uint8List').map((f) => ', ${camel(f.name)}').join()}]);')
      ..writeln()
      ..writeln('  @override')
      ..writeln("  String toString() => '$cls(id: \$id${fields.take(3).map((f) => ', ${camel(f.name)}: \$${camel(f.name)}').join()})';");
    if (hasBlob && !_sqlite) {
      b
        ..writeln()
        ..writeln('  /// Accepte un Blob Firestore, des octets ou une liste d\'entiers.\n'
            '  static Uint8List _readBytes(Object? v) {\n'
            '    if (v is Uint8List) return v;\n'
            '    if (v is List) return Uint8List.fromList(v.cast<int>());\n'
            '    return (v as dynamic).bytes as Uint8List;\n'
            '  }');
    }
    if (hasDate) {
      b
        ..writeln()
        ..writeln(_sqlite
            ? '  static DateTime _readDate(Object? v) => DateTime.parse(v as String);'
            : '  /// Accepte un Timestamp Firestore, une date ou un texte ISO 8601.\n'
                '  static DateTime _readDate(Object? v) {\n'
                '    if (v is DateTime) return v;\n'
                '    if (v is String) return DateTime.parse(v);\n'
                '    return (v as dynamic).toDate() as DateTime;\n'
                '  }');
    }
    b.writeln('}');
    return '${b.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim()}\n';
  }

  String _collection(EntityProposal e) => SchemaProposal.tableName(e.name).replaceAll('_', '');

  String exception() => '''// Généré par BDDouilleur.
/// Erreur d'accès aux données, avec un message compréhensible.
class RepositoryException implements Exception {
  RepositoryException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '\$message (\$cause)';
}
''';

  String databaseFile(String packageName) {
    final tables = proposal.toTableDefinitions();
    final sql = [for (final t in tables) SqliteSqlBuilder.createTable(t)];
    return '''// Généré par BDDouilleur : ouverture de la base SQLite de l'application.
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();

  static const fileName = 'app.db';
  static const version = 1;

  /// Instructions de création, dans l'ordre des dépendances entre tables.
  static const createStatements = <String>[
${sql.map((s) => "    r'''${s.replaceAll("'''", r"\'\'\'")}''',").join('\n')}
  ];

  /// Ouvre (et crée au besoin) la base. [factory] permet les tests (ffi).
  static Future<Database> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), fileName);
    return f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          for (final s in createStatements) {
            await db.execute(s);
          }
        },
      ),
    );
  }
}
''';
  }

  String sqliteRepository(EntityProposal e, String pkg, FlutterProjectLayout l) {
    final cls = pascal(e.name);
    final table = e.tableName;
    final modelImport = "package:$pkg/${l.modelsDir.substring(4)}/${snake(e.name)}.dart";
    return '''// Généré par BDDouilleur.
import 'package:sqflite/sqflite.dart';

import '$modelImport';
import 'repository_exception.dart';

/// Accès à la table « $table ».
class ${cls}Repository {
  ${cls}Repository(this._db);
  final Database _db;

  static const table = '$table';

  Future<List<$cls>> getAll({int? limit, int? offset}) => _guard('lecture', () async {
        final rows = await _db.query(table, orderBy: 'id', limit: limit, offset: offset);
        return rows.map($cls.fromMap).toList();
      });

  Future<$cls?> getById(int id) => _guard('lecture', () async {
        final rows = await _db.query(table, where: 'id = ?', whereArgs: [id], limit: 1);
        return rows.isEmpty ? null : $cls.fromMap(rows.first);
      });

  /// Insère et renvoie l'entité avec son identifiant.
  Future<$cls> insert($cls value) => _guard('ajout', () async {
        final id = await _db.insert(table, value.toMap()..remove('id'));
        return value.copyWith(id: id);
      });

  Future<void> update($cls value) => _guard('modification', () async {
        if (value.id == null) throw RepositoryException('Impossible de modifier un élément sans identifiant.');
        final n = await _db.update(table, value.toMap()..remove('id'), where: 'id = ?', whereArgs: [value.id]);
        if (n == 0) throw RepositoryException('Élément \${value.id} introuvable dans $table.');
      });

  Future<void> delete(int id) => _guard('suppression', () async {
        final n = await _db.delete(table, where: 'id = ?', whereArgs: [id]);
        if (n == 0) throw RepositoryException('Élément \$id introuvable dans $table.');
      });

  Future<int> count() => _guard('comptage', () async {
        final r = await _db.rawQuery('SELECT COUNT(*) AS n FROM $table');
        return (r.first['n'] as num).toInt();
      });

  Future<T> _guard<T>(String action, Future<T> Function() body) async {
    try {
      return await body();
    } on RepositoryException {
      rethrow;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) throw RepositoryException('Échec de \$action : valeur déjà utilisée.', e);
      if (e.toString().contains('FOREIGN KEY')) throw RepositoryException('Échec de \$action : élément lié introuvable ou encore utilisé.', e);
      throw RepositoryException('Échec de \$action dans $table.', e);
    }
  }
}
''';
  }

  String firestoreRepository(EntityProposal e, String pkg, FlutterProjectLayout l) {
    final cls = pascal(e.name);
    final col = _collection(e);
    final modelImport = "package:$pkg/${l.modelsDir.substring(4)}/${snake(e.name)}.dart";
    final dates = e.fields.where((f) => _dartType(f) == 'DateTime').map((f) => camel(f.name)).toList();
    final blobs = e.fields.where((f) => _dartType(f) == 'Uint8List').map((f) => camel(f.name)).toList();
    return '''// Généré par BDDouilleur.
import 'package:cloud_firestore/cloud_firestore.dart';

import '$modelImport';
import 'repository_exception.dart';

/// Accès à la collection « $col ». Les règles de sécurité Firestore
/// s'appliquent à ces requêtes : testez-les avec BDDouilleur.
class ${cls}Repository {
  ${cls}Repository([FirebaseFirestore? firestore]) : _db = firestore ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  static const collection = '$col';

  CollectionReference<Map<String, dynamic>> get _col => _db.collection(collection);

  $cls _fromDoc(DocumentSnapshot<Map<String, dynamic>> d) => $cls.fromMap(d.data()!, id: d.id);

  Map<String, Object?> _toData($cls v) => {
        ...v.toMap(),${dates.map((d) => "\n        if (v.$d != null) '$d': Timestamp.fromDate(v.$d!),").join()}${blobs.map((d) => "\n        if (v.$d != null) '$d': Blob(v.$d!),").join()}
      };

  Stream<List<$cls>> watchAll() => _col.snapshots().map((s) => s.docs.map(_fromDoc).toList());

  Future<List<$cls>> getAll({int limit = 100}) => _guard('lecture', () async {
        final s = await _col.limit(limit).get();
        return s.docs.map(_fromDoc).toList();
      });

  Future<$cls?> getById(String id) => _guard('lecture', () async {
        final d = await _col.doc(id).get();
        return d.exists ? _fromDoc(d) : null;
      });

  /// Crée le document (identifiant généré) et renvoie l'entité complétée.
  Future<$cls> add($cls value) => _guard('ajout', () async {
        final ref = await _col.add(_toData(value));
        return value.copyWith(id: ref.id);
      });

  Future<void> update($cls value) => _guard('modification', () async {
        if (value.id == null) throw RepositoryException('Impossible de modifier un document sans identifiant.');
        await _col.doc(value.id).update(_toData(value));
      });

  Future<void> delete(String id) => _guard('suppression', () => _col.doc(id).delete());

  Future<T> _guard<T>(String action, Future<T> Function() body) async {
    try {
      return await body();
    } on RepositoryException {
      rethrow;
    } on FirebaseException catch (e) {
      final message = switch (e.code) {
        'permission-denied' => 'Échec de \$action : accès refusé par les règles de sécurité.',
        'not-found' => 'Échec de \$action : document introuvable.',
        'unavailable' => 'Échec de \$action : service indisponible (réseau ?).',
        _ => 'Échec de \$action dans $col.',
      };
      throw RepositoryException(message, e);
    }
  }
}
''';
  }

  String service(EntityProposal e, String pkg, FlutterProjectLayout l) {
    final cls = pascal(e.name);
    final repoImport = "package:$pkg/${l.repositoriesDir.substring(4)}/${snake(e.name)}_repository.dart";
    final exImport = "package:$pkg/${l.repositoriesDir.substring(4)}/repository_exception.dart";
    final modelImport = "package:$pkg/${l.modelsDir.substring(4)}/${snake(e.name)}.dart";
    final checks = <String>[
      for (final f in e.fields)
        if (f.required && _dartType(f) == 'String')
          "    if (value.${camel(f.name)}.trim().isEmpty) errors.add('${camel(f.name)} est obligatoire.');",
    ];
    final idType = _sqlite ? 'int' : 'String';
    final create = _sqlite ? 'insert' : 'add';
    return '''// Généré par BDDouilleur.
import '$modelImport';
import '$repoImport';
import '$exImport';

/// Règles métier autour de « $cls » : validation avant écriture.
class ${cls}Service {
  ${cls}Service(this.repository);
  final ${cls}Repository repository;

  /// Liste des problèmes de validation (vide si la valeur est correcte).
  List<String> validate($cls value) {
    final errors = <String>[];
${checks.isEmpty ? '    // Aucun champ texte obligatoire.' : checks.join('\n')}
    return errors;
  }

  Future<$cls> create($cls value) async {
    final errors = validate(value);
    if (errors.isNotEmpty) throw RepositoryException(errors.join(' '));
    return repository.$create(value);
  }

  Future<void> save($cls value) async {
    final errors = validate(value);
    if (errors.isNotEmpty) throw RepositoryException(errors.join(' '));
    await repository.update(value);
  }

  Future<List<$cls>> list() => repository.getAll();

  Future<$cls?> find($idType id) => repository.getById(id);

  Future<void> remove($idType id) => repository.delete(id);
}
''';
  }

  /// Valeur d'exemple pour les tests.
  String _sample(FieldProposal f, String Function(String entity) refId, int seed) {
    if (f.references != null) return refId(f.references!);
    return switch (_dartType(f)) {
      'int' => '${seed + 1}',
      'double' => '${seed + 1}.5',
      'bool' => 'true',
      'DateTime' => 'DateTime.utc(2026, 1, ${seed + 1})',
      'Uint8List' => 'Uint8List.fromList([1, 2, 3])',
      _ => "'${camel(f.name)} $seed'",
    };
  }

  String modelTest(EntityProposal e, String pkg, FlutterProjectLayout l) {
    final cls = pascal(e.name);
    final modelImport = "package:$pkg/${l.modelsDir.substring(4)}/${snake(e.name)}.dart";
    final hasBlob = e.fields.any((f) => _dartType(f) == 'Uint8List');
    final args = e.fields.map((f) => '${camel(f.name)}: ${_sample(f, (_) => _sqlite ? '1' : "'ref1'", 0)}').join(', ');
    final firstText = e.fields.where((f) => _dartType(f) == 'String' && f.references == null).firstOrNull;
    return '''// Généré par BDDouilleur.
${hasBlob ? "import 'dart:typed_data';\n\n" : ''}import 'package:flutter_test/flutter_test.dart';
import '$modelImport';

void main() {
  test('$cls : aller-retour toMap / fromMap', () {
    const id = ${_sqlite ? '7' : "'abc'"};
    final value = $cls(id: id, $args);
    final back = $cls.fromMap(value.toMap()${_sqlite ? '' : ', id: id'});
${hasBlob ? '    expect(back.id, value.id);' : '    expect(back, value);'}
  });

  test('$cls : copyWith ne modifie que les champs donnés', () {
    final value = $cls($args);
    final copy = value.copyWith(id: ${_sqlite ? '3' : "'x'"});
    expect(copy.id, ${_sqlite ? '3' : "'x'"});
${firstText == null ? '' : '    expect(copy.${camel(firstText.name)}, value.${camel(firstText.name)});\n'}  });
}
''';
  }

  /// Test d'intégration du dépôt sur une vraie base (SQLite en mémoire via
  /// sqflite_common_ffi, ou faux Firestore).
  String repositoryTest(EntityProposal e, String pkg, FlutterProjectLayout l) {
    final cls = pascal(e.name);
    final repoDir = l.repositoriesDir.substring(4);
    final ordered = _sqlite ? proposal.toTableDefinitions().map((t) => t.name).toList() : <String>[];
    // Entités dont dépend celle-ci (à créer d'abord pour respecter les clés étrangères).
    final parents = <EntityProposal>[];
    void collect(EntityProposal x) {
      for (final f in x.fields) {
        if (f.references == null || f.references!.toLowerCase() == x.name.toLowerCase()) continue;
        final parent = proposal.entities.firstWhere((p) => p.name.toLowerCase() == f.references!.toLowerCase());
        if (!parents.contains(parent)) {
          collect(parent);
          parents.add(parent);
        }
      }
    }

    collect(e);
    if (_sqlite) parents.sort((a, b) => ordered.indexOf(a.tableName).compareTo(ordered.indexOf(b.tableName)));
    final imports = {
      for (final x in [...parents, e]) ...{
        "import 'package:$pkg/${l.modelsDir.substring(4)}/${snake(x.name)}.dart';",
        "import 'package:$pkg/$repoDir/${snake(x.name)}_repository.dart';",
      },
    };
    String varOf(EntityProposal x) => '${camel(x.name)}Saved';
    String refId(String entity) {
      final parent = parents.firstWhere((p) => p.name.toLowerCase() == entity.toLowerCase());
      return '${varOf(parent)}.id!';
    }

    final hasBlob = [...parents, e].any((x) => x.fields.any((f) => _dartType(f) == 'Uint8List'));
    final setup = StringBuffer();
    for (final (i, x) in parents.indexed) {
      final args = x.fields.map((f) => '${camel(f.name)}: ${_sample(f, refId, i)}').join(', ');
      setup.writeln(_sqlite
          ? '    final ${varOf(x)} = await ${pascal(x.name)}Repository(db).insert(${pascal(x.name)}($args));'
          : '    final ${varOf(x)} = await ${pascal(x.name)}Repository(db).add(${pascal(x.name)}($args));');
    }
    final args = e.fields.map((f) => '${camel(f.name)}: ${_sample(f, refId, 9)}').join(', ');
    if (_sqlite) {
      return '''// Généré par BDDouilleur : test d'intégration sur une vraie base SQLite en mémoire.
${hasBlob ? "import 'dart:typed_data';\n\n" : ''}import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:$pkg/$repoDir/app_database.dart';
${imports.join('\n')}

void main() {
  sqfliteFfiInit();
  late Database db;

  setUp(() async => db = await AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath));
  tearDown(() => db.close());

  test('${cls}Repository : ajout, lecture, modification, suppression', () async {
${setup.toString().trimRight()}
    final repo = ${cls}Repository(db);
    final saved = await repo.insert($cls($args));
    expect(saved.id, isNotNull);
    expect(await repo.getById(saved.id!), isNotNull);
    expect(await repo.count(), 1);
    await repo.update(saved);
    await repo.delete(saved.id!);
    expect(await repo.getById(saved.id!), isNull);
  });
}
''';
    }
    return '''// Généré par BDDouilleur : test d'intégration sur un Firestore simulé.
${hasBlob ? "import 'dart:typed_data';\n\n" : ''}import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
${imports.join('\n')}

void main() {
  test('${cls}Repository : ajout, lecture, modification, suppression', () async {
    final db = FakeFirebaseFirestore();
${setup.toString().trimRight()}
    final repo = ${cls}Repository(db);
    final saved = await repo.add($cls($args));
    expect(saved.id, isNotNull);
    expect(await repo.getById(saved.id!), isNotNull);
    await repo.update(saved);
    await repo.delete(saved.id!);
    expect(await repo.getById(saved.id!), isNull);
  });
}
''';
  }

  /// Construit le plan sans rien écrire.
  CodegenPlan plan(String projectDir) {
    final problems = proposal.validate();
    if (problems.isNotEmpty) throw FormatException(problems.join('\n'));
    final l = FlutterProjectLayout.read(projectDir);
    final pkg = l.packageName;
    final files = <PlannedFile>[];
    void add(String rel, String content, String purpose) {
      final f = File(p.join(projectDir, rel));
      files.add(PlannedFile(path: rel, content: content, previous: f.existsSync() ? f.readAsStringSync() : null, purpose: purpose));
    }

    add('${l.repositoriesDir}/repository_exception.dart', exception(), 'Erreur d\'accès aux données');
    if (_sqlite) add('${l.repositoriesDir}/app_database.dart', databaseFile(pkg), 'Ouverture et création de la base');
    for (final e in proposal.entities) {
      final s = snake(e.name);
      add('${l.modelsDir}/$s.dart', model(e), 'Modèle ${pascal(e.name)}');
      add('${l.repositoriesDir}/${s}_repository.dart',
          _sqlite ? sqliteRepository(e, pkg, l) : firestoreRepository(e, pkg, l), 'Dépôt ${pascal(e.name)}');
      add('${l.servicesDir}/${s}_service.dart', service(e, pkg, l), 'Service ${pascal(e.name)}');
      add('test/models/${s}_test.dart', modelTest(e, pkg, l), 'Test unitaire du modèle');
      add('test/repositories/${s}_repository_test.dart', repositoryTest(e, pkg, l), 'Test d\'intégration du dépôt');
    }
    final missing = [for (final d in backend.dependencies) if (!l.dependencies.contains(d)) d];
    final missingDev = [for (final d in backend.devDependencies) if (!l.dependencies.contains(d)) d];
    return CodegenPlan(
      projectDir: projectDir,
      packageName: pkg,
      backend: backend,
      files: files.where((f) => !f.unchanged).toList(),
      missingDependencies: missing,
      missingDevDependencies: missingDev,
      notes: [
        'Architecture respectée : modèles dans ${l.modelsDir}, dépôts dans ${l.repositoriesDir}, services dans ${l.servicesDir}.',
        if (!_sqlite) 'Firebase doit être initialisé dans main() (Firebase Rescue vérifie ce point).',
        if (files.any((f) => !f.isNew && !f.unchanged)) 'Des fichiers existants seront modifiés : leur version actuelle est sauvegardée.',
      ],
    );
  }

  /// Entité déduite d'une table SQLite existante (pour générer son code).
  static String entityNameForTable(String table) => pascal(table.endsWith('ies')
      ? '${table.substring(0, table.length - 3)}y'
      : table.endsWith('s')
          ? table.substring(0, table.length - 1)
          : table);

  static EntityProposal entityFromTable(TableInfo t) {
    final fks = {for (final fk in t.foreignKeys) fk.from: entityNameForTable(fk.table)};
    return EntityProposal(name: entityNameForTable(t.name), table: t.name, source: 'table ${t.name}', fields: [
      for (final c in t.columns)
        if (!(c.isPrimaryKey && c.name.toLowerCase() == 'id'))
          FieldProposal(
            name: camel(c.name),
            column: c.name,
            required: c.notNull,
            references: fks[c.name],
            type: switch (c.declaredType.toUpperCase()) {
              final d when d.contains('BOOL') => SqlColumnType.boolean,
              final d when d.contains('DATETIME') || d.contains('TIMESTAMP') => SqlColumnType.datetime,
              final d when d.contains('DATE') => SqlColumnType.date,
              _ => switch (c.affinity) {
                  'INTEGER' => SqlColumnType.integer,
                  'REAL' => SqlColumnType.real,
                  'NUMERIC' => SqlColumnType.numeric,
                  'BLOB' => SqlColumnType.blob,
                  _ => SqlColumnType.text,
                },
            },
          ),
    ]);
  }
}
