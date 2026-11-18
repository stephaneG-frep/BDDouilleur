import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../../domain/models/db_engine.dart';
import '../../../domain/models/schema.dart';
import '../database_connector.dart';
import 'sqlite_sql_builder.dart';

/// Connecteur SQLite réel (bibliothèque SQLite embarquée via package:sqlite3).
class SqliteConnector implements DatabaseConnector {
  SqliteConnector(this.path, {this.createIfMissing = false});

  /// Chemin absolu du fichier, ou `:memory:` pour les tests.
  final String path;
  final bool createIfMissing;
  Database? _db;

  static const _rowIdAlias = '__bdd_rowid__';

  @override
  DbEngine get engine => DbEngine.sqlite;

  @override
  Set<ConnectorCapability> get capabilities => const {
        ConnectorCapability.connect,
        ConnectorCapability.inspect,
        ConnectorCapability.crud,
        ConnectorCapability.backup,
        ConnectorCapability.restore,
        ConnectorCapability.diagnostic,
      };

  @override
  bool get isOpen => _db != null;

  Database get _conn {
    final db = _db;
    if (db == null) throw ConnectorException('La base n\'est pas ouverte.');
    return db;
  }

  /// Version de la bibliothèque SQLite réellement chargée.
  static String get libraryVersion => sqlite3.version.libVersion;

  @override
  Future<void> open() async {
    if (_db != null) return;
    if (path != ':memory:') {
      final file = File(path);
      if (!file.existsSync()) {
        if (!createIfMissing) throw ConnectorException('Fichier introuvable : $path');
        file.parent.createSync(recursive: true);
      }
    }
    try {
      final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);
      // Vérifie qu'il s'agit bien d'une base SQLite (lève une erreur sinon).
      db.select('SELECT count(*) FROM sqlite_schema');
      db.execute('PRAGMA foreign_keys = ON;');
      _db = db;
    } on SqliteException catch (e) {
      throw ConnectorException('Impossible d\'ouvrir la base SQLite : ${e.message}', cause: e);
    }
  }

  @override
  Future<void> close() async {
    _db?.close();
    _db = null;
  }

  T _guard<T>(T Function() action) {
    try {
      return action();
    } on SqliteException catch (e) {
      throw ConnectorException(_frenchError(e), cause: e);
    }
  }

  static String _frenchError(SqliteException e) {
    final msg = e.message;
    if (msg.contains('UNIQUE constraint failed')) return 'Valeur déjà existante (contrainte UNIQUE) : $msg';
    if (msg.contains('NOT NULL constraint failed')) return 'Champ obligatoire manquant (NOT NULL) : $msg';
    if (msg.contains('FOREIGN KEY constraint failed')) {
      return 'Référence invalide (clé étrangère) : la valeur liée n\'existe pas ou est encore utilisée.';
    }
    if (msg.contains('CHECK constraint failed')) return 'Valeur refusée par une contrainte CHECK : $msg';
    if (msg.contains('already exists')) return 'Cet élément existe déjà : $msg';
    if (msg.contains('no such table')) return 'Table introuvable : $msg';
    if (msg.contains('syntax error')) return 'Erreur de syntaxe SQL : $msg';
    if (msg.contains('datatype mismatch')) return 'Type de donnée incompatible : $msg';
    return 'Erreur SQLite : $msg';
  }

  @override
  Future<List<String>> listTables() async => _guard(() => _conn
      .select("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .map((r) => r['name'] as String)
      .toList());

  @override
  Future<TableInfo> describeTable(String table) async => _guard(() {
        final db = _conn;
        final q = SqliteSqlBuilder.quote(table);
        final master = db.select("SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", [table]);
        if (master.isEmpty) throw ConnectorException('Table introuvable : $table');

        final columns = db
            .select('PRAGMA table_info($q)')
            .map((r) => ColumnInfo(
                  name: r['name'] as String,
                  declaredType: (r['type'] as String?) ?? '',
                  notNull: (r['notnull'] as int) == 1,
                  defaultValue: r['dflt_value']?.toString(),
                  primaryKeyIndex: r['pk'] as int,
                ))
            .toList();

        final fks = db
            .select('PRAGMA foreign_key_list($q)')
            .map((r) => ForeignKeyInfo(
                  from: r['from'] as String,
                  table: r['table'] as String,
                  to: r['to'] as String?,
                  onDelete: r['on_delete'] as String,
                ))
            .toList();

        final indexes = <IndexInfo>[];
        for (final r in db.select('PRAGMA index_list($q)')) {
          final name = r['name'] as String;
          final cols = db
              .select('PRAGMA index_info(${SqliteSqlBuilder.quote(name)})')
              .map((c) => (c['name'] as String?) ?? '(expression)')
              .toList();
          indexes.add(IndexInfo(name: name, unique: (r['unique'] as int) == 1, columns: cols, origin: r['origin'] as String));
        }

        final list = db.select('PRAGMA table_list($q)');
        final withoutRowId = list.isNotEmpty && (list.first['wr'] as int) == 1;
        final count = db.select('SELECT count(*) AS c FROM $q').first['c'] as int;

        return TableInfo(
          name: table,
          columns: columns,
          foreignKeys: fks,
          indexes: indexes,
          rowCount: count,
          createSql: master.first['sql'] as String?,
          withoutRowId: withoutRowId,
        );
      });

  @override
  Future<OperationOutcome> createTable(TableDefinition definition) async {
    final String sql;
    try {
      sql = SqliteSqlBuilder.createTable(definition);
    } on ArgumentError catch (e) {
      throw ConnectorException(e.message.toString());
    }
    return _guard(() {
      _conn.execute(sql);
      return OperationOutcome(sql: sql);
    });
  }

  @override
  Future<OperationOutcome> dropTable(String table) async => _guard(() {
        final sql = 'DROP TABLE ${SqliteSqlBuilder.quote(table)};';
        _conn.execute(sql);
        return OperationOutcome(sql: sql);
      });

  /// Utilise rowid quand il existe, sinon la clé primaire (tables WITHOUT ROWID).
  bool _usesRowId(TableInfo info) =>
      !info.withoutRowId && !info.columns.any((c) => const {'rowid', '_rowid_', 'oid'}.contains(c.name.toLowerCase()));

  @override
  Future<RowPage> readRows(String table, {int limit = 50, int offset = 0}) async {
    final info = await describeTable(table);
    return _guard(() {
      final q = SqliteSqlBuilder.quote(table);
      final useRowId = _usesRowId(info);
      final pk = info.primaryKeyColumns;
      if (!useRowId && pk.isEmpty) {
        throw ConnectorException('Impossible d\'identifier les lignes de « $table » (ni rowid ni clé primaire).');
      }
      final select = useRowId ? 'SELECT rowid AS "$_rowIdAlias", * FROM $q' : 'SELECT * FROM $q';
      final order = useRowId ? 'rowid' : pk.map((c) => SqliteSqlBuilder.quote(c.name)).join(', ');
      final result = _conn.select('$select ORDER BY $order LIMIT ? OFFSET ?', [limit, offset]);

      final rows = <Map<String, Object?>>[];
      final keys = <RowKey>[];
      for (final r in result) {
        final row = <String, Object?>{for (final c in info.columns) c.name: r[c.name]};
        rows.add(row);
        keys.add(useRowId ? RowKey({'rowid': r[_rowIdAlias]}) : RowKey({for (final c in pk) c.name: r[c.name]}));
      }
      return RowPage(columns: info.columns.map((c) => c.name).toList(), rows: rows, keys: keys, total: info.rowCount);
    });
  }

  @override
  Future<OperationOutcome> insertRow(String table, Map<String, Object?> values) async => _guard(() {
        final sql = SqliteSqlBuilder.insert(table, values.keys.toList());
        _conn.execute(sql, values.values.toList());
        return OperationOutcome(sql: sql, affectedRows: _conn.updatedRows, insertedId: _conn.lastInsertRowId);
      });

  @override
  Future<OperationOutcome> updateRow(String table, RowKey key, Map<String, Object?> values) async {
    if (values.isEmpty) return const OperationOutcome(sql: '-- aucune modification');
    return _guard(() {
      final sql = SqliteSqlBuilder.update(table, values.keys.toList(), key);
      _conn.execute(sql, [...values.values, ...key.values.values]);
      final n = _conn.updatedRows;
      if (n == 0) throw ConnectorException('Aucun enregistrement modifié : la ligne n\'existe plus.');
      return OperationOutcome(sql: sql, affectedRows: n);
    });
  }

  @override
  Future<OperationOutcome> deleteRow(String table, RowKey key) async => _guard(() {
        final sql = SqliteSqlBuilder.delete(table, key);
        _conn.execute(sql, key.values.values.toList());
        final n = _conn.updatedRows;
        if (n == 0) throw ConnectorException('Aucun enregistrement supprimé : la ligne n\'existe plus.');
        return OperationOutcome(sql: sql, affectedRows: n);
      });

  @override
  Future<SqlResult> executeSql(String sql) async => _guard(() {
        final db = _conn;
        final pieces = SqlScript.split(sql);
        if (pieces.isEmpty) throw ConnectorException('Aucune instruction SQL à exécuter.');
        var columns = <String>[];
        var rows = <List<Object?>>[];
        var affected = 0;
        var isQuery = false;
        var pending = '';
        // Chaque instruction est préparée puis exécutée avant la suivante, pour
        // qu'un script « CREATE TABLE ...; INSERT ... » fonctionne.
        for (var i = 0; i < pieces.length; i++) {
          pending += pieces[i];
          if (SqlScript.isBlank(pending)) {
            pending = '';
            continue;
          }
          final PreparedStatement stmt;
          try {
            stmt = db.prepare(pending, checkNoTail: true);
          } on SqliteException catch (e) {
            // Corps de trigger (BEGIN ... ; ... END) : on continue d'accumuler.
            if (e.message.contains('incomplete input') && i < pieces.length - 1) continue;
            rethrow;
          }
          pending = '';
          try {
            final before = _totalChanges(db);
            final rs = stmt.select();
            if (rs.columnNames.isNotEmpty) {
              isQuery = true;
              columns = rs.columnNames;
              rows = rs.rows.map((r) => List<Object?>.from(r)).toList();
            } else {
              affected += _totalChanges(db) - before;
            }
          } finally {
            stmt.close();
          }
        }
        return SqlResult(columns: columns, rows: rows, affectedRows: affected, isQuery: isQuery);
      });

  static int _totalChanges(Database db) => db.select('SELECT total_changes() AS t').first['t'] as int;

  /// Lecture brute (diagnostics) : lignes sous forme de dictionnaires.
  Future<List<Map<String, Object?>>> select(String sql, [List<Object?> args = const []]) async =>
      _guard(() => [for (final r in _conn.select(sql, args)) Map<String, Object?>.of(r)]);

  /// Vrai si l'instruction se compile (sans l'exécuter) ; sinon le message d'erreur.
  Future<String?> compileError(String sql) async {
    try {
      _conn.prepare(sql).close();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  @override
  Future<IntegrityReport> checkIntegrity() async => _guard(() {
        final messages = _conn.select('PRAGMA integrity_check').map((r) => r.values.first.toString()).toList();
        final fk = _conn
            .select('PRAGMA foreign_key_check')
            .map((r) => 'Table « ${r['table']} », ligne ${r['rowid']} → « ${r['parent']} » absente')
            .toList();
        final ok = messages.length == 1 && messages.first == 'ok' && fk.isEmpty;
        return IntegrityReport(ok: ok, messages: messages, foreignKeyViolations: fk);
      });

  @override
  Future<OperationOutcome> backupTo(String destinationPath) async {
    if (File(destinationPath).existsSync()) {
      throw ConnectorException('Le fichier de destination existe déjà : $destinationPath');
    }
    Directory(File(destinationPath).parent.path).createSync(recursive: true);
    return _guard(() {
      // VACUUM INTO produit une copie cohérente et compacte de la base.
      final sql = 'VACUUM INTO ${SqliteSqlBuilder.quoteLiteral(destinationPath)};';
      _conn.execute(sql);
      return OperationOutcome(sql: sql);
    });
  }
}
