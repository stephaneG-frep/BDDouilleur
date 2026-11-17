/// Types de colonnes proposés pour SQLite (affinités SQLite + types usuels
/// convertis vers l'affinité appropriée).
enum SqlColumnType {
  integer('INTEGER', 'Nombre entier (ex. 42)'),
  real('REAL', 'Nombre à virgule (ex. 3.14)'),
  text('TEXT', 'Texte libre'),
  numeric('NUMERIC', 'Valeur numérique exacte (prix, montants)'),
  boolean('BOOLEAN', 'Vrai/faux stocké en 0 ou 1'),
  date('DATE', 'Date au format AAAA-MM-JJ (texte)'),
  datetime('DATETIME', 'Date et heure ISO 8601 (texte)'),
  blob('BLOB', 'Données binaires brutes');

  const SqlColumnType(this.sql, this.help);
  final String sql;
  final String help;
}

class ForeignKeyRef {
  const ForeignKeyRef({required this.table, required this.column, this.onDelete = 'NO ACTION'});
  final String table;
  final String column;

  /// NO ACTION, CASCADE, SET NULL, RESTRICT.
  final String onDelete;
}

/// Définition d'une colonne à créer.
class ColumnDefinition {
  ColumnDefinition({
    required this.name,
    this.type = SqlColumnType.text,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.notNull = false,
    this.unique = false,
    this.defaultValue,
    this.references,
  });

  String name;
  SqlColumnType type;
  bool primaryKey;
  bool autoIncrement;
  bool notNull;
  bool unique;
  String? defaultValue;
  ForeignKeyRef? references;
}

class TableDefinition {
  TableDefinition({required this.name, required this.columns});
  final String name;
  final List<ColumnDefinition> columns;
}

/// Description d'une colonne existante (lue via PRAGMA table_info).
class ColumnInfo {
  const ColumnInfo({
    required this.name,
    required this.declaredType,
    required this.notNull,
    required this.defaultValue,
    required this.primaryKeyIndex,
  });

  final String name;
  final String declaredType;
  final bool notNull;
  final String? defaultValue;

  /// 0 si la colonne ne fait pas partie de la clé primaire, sinon sa position (1..n).
  final int primaryKeyIndex;
  bool get isPrimaryKey => primaryKeyIndex > 0;

  /// Affinité SQLite déterminée selon les règles officielles (section 3.1 de
  /// la documentation « Datatypes In SQLite »).
  String get affinity {
    final t = declaredType.toUpperCase();
    if (t.contains('INT')) return 'INTEGER';
    if (t.contains('CHAR') || t.contains('CLOB') || t.contains('TEXT')) return 'TEXT';
    if (t.isEmpty || t.contains('BLOB')) return 'BLOB';
    if (t.contains('REAL') || t.contains('FLOA') || t.contains('DOUB')) return 'REAL';
    return 'NUMERIC';
  }
}

class ForeignKeyInfo {
  const ForeignKeyInfo({required this.from, required this.table, required this.to, required this.onDelete});
  final String from;
  final String table;
  final String? to;
  final String onDelete;
}

class IndexInfo {
  const IndexInfo({required this.name, required this.unique, required this.columns, required this.origin});
  final String name;
  final bool unique;
  final List<String> columns;

  /// c = CREATE INDEX, u = contrainte UNIQUE, pk = clé primaire.
  final String origin;
}

class TableInfo {
  const TableInfo({
    required this.name,
    required this.columns,
    required this.foreignKeys,
    required this.indexes,
    required this.rowCount,
    required this.createSql,
    required this.withoutRowId,
  });

  final String name;
  final List<ColumnInfo> columns;
  final List<ForeignKeyInfo> foreignKeys;
  final List<IndexInfo> indexes;
  final int rowCount;
  final String? createSql;
  final bool withoutRowId;

  List<ColumnInfo> get primaryKeyColumns =>
      (columns.where((c) => c.isPrimaryKey).toList()..sort((a, b) => a.primaryKeyIndex.compareTo(b.primaryKeyIndex)));
}

/// Identifie un enregistrement de façon fiable pour UPDATE/DELETE.
class RowKey {
  const RowKey(this.values);

  /// Colonne -> valeur. Utilise la clé primaire, ou `rowid` à défaut.
  final Map<String, Object?> values;
}

class RowPage {
  const RowPage({required this.columns, required this.rows, required this.keys, required this.total});
  final List<String> columns;
  final List<Map<String, Object?>> rows;
  final List<RowKey> keys;
  final int total;
}

class SqlResult {
  const SqlResult({required this.columns, required this.rows, required this.affectedRows, required this.isQuery});
  final List<String> columns;
  final List<List<Object?>> rows;
  final int affectedRows;
  final bool isQuery;
}

class IntegrityReport {
  const IntegrityReport({required this.ok, required this.messages, required this.foreignKeyViolations});
  final bool ok;
  final List<String> messages;
  final List<String> foreignKeyViolations;
}
