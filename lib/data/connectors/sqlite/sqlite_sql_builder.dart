import '../../../domain/models/schema.dart';

/// Génère du SQL SQLite sûr : identifiants validés et échappés, valeurs
/// toujours liées par paramètres (jamais concaténées).
class SqliteSqlBuilder {
  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static final _number = RegExp(r'^-?\d+(\.\d+)?$');
  static const _sqlKeywordsDefaults = {'CURRENT_TIMESTAMP', 'CURRENT_DATE', 'CURRENT_TIME', 'NULL'};
  static const onDeleteActions = ['NO ACTION', 'CASCADE', 'SET NULL', 'RESTRICT'];

  /// Mots réservés SQLite les plus susceptibles d'être choisis par erreur.
  static const _reserved = {
    'ABORT', 'ADD', 'ALL', 'ALTER', 'AND', 'AS', 'ASC', 'BETWEEN', 'BY', 'CASE', 'CHECK', 'COLUMN',
    'COMMIT', 'CONSTRAINT', 'CREATE', 'CROSS', 'DEFAULT', 'DELETE', 'DESC', 'DISTINCT', 'DROP', 'ELSE',
    'END', 'EXISTS', 'FOREIGN', 'FROM', 'GROUP', 'HAVING', 'IN', 'INDEX', 'INNER', 'INSERT', 'INTO', 'IS',
    'JOIN', 'KEY', 'LEFT', 'LIKE', 'LIMIT', 'NOT', 'NULL', 'OFFSET', 'ON', 'OR', 'ORDER', 'PRIMARY',
    'REFERENCES', 'SELECT', 'SET', 'TABLE', 'THEN', 'TO', 'TRANSACTION', 'UNION', 'UNIQUE', 'UPDATE',
    'USING', 'VALUES', 'WHEN', 'WHERE', 'WITH',
  };

  /// Échappe un identifiant (fonctionne aussi pour les noms existants atypiques).
  static String quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';

  static String quoteLiteral(String value) => "'${value.replaceAll("'", "''")}'";

  /// Valide un nom de table ou de colonne à créer. Retourne null si valide.
  static String? validateIdentifier(String name, {String kind = 'nom'}) {
    final n = name.trim();
    if (n.isEmpty) return 'Le $kind est obligatoire.';
    if (n.length > 64) return 'Le $kind ne doit pas dépasser 64 caractères.';
    if (!_identifier.hasMatch(n)) {
      return 'Le $kind « $n » doit commencer par une lettre ou « _ » et ne contenir que '
          'des lettres sans accent, chiffres et « _ ».';
    }
    if (n.toLowerCase().startsWith('sqlite_')) return 'Le préfixe « sqlite_ » est réservé par SQLite.';
    if (_reserved.contains(n.toUpperCase())) return '« $n » est un mot réservé SQL.';
    return null;
  }

  /// Vérifie une définition de table complète. Liste vide = valide.
  static List<String> validateTable(TableDefinition def) {
    final errors = <String>[];
    final tableError = validateIdentifier(def.name, kind: 'nom de table');
    if (tableError != null) errors.add(tableError);
    if (def.columns.isEmpty) errors.add('Une table doit contenir au moins une colonne.');

    final seen = <String>{};
    for (final c in def.columns) {
      final err = validateIdentifier(c.name, kind: 'nom de colonne');
      if (err != null) errors.add(err);
      if (!seen.add(c.name.trim().toLowerCase())) errors.add('La colonne « ${c.name} » est en double.');
      if (c.autoIncrement && !(c.primaryKey && c.type == SqlColumnType.integer)) {
        errors.add('« ${c.name} » : l\'auto-incrément exige une clé primaire de type INTEGER.');
      }
      if (c.references != null) {
        final refErr = validateIdentifier(c.references!.table, kind: 'nom de table référencée');
        if (refErr != null) errors.add(refErr);
        if (!onDeleteActions.contains(c.references!.onDelete)) errors.add('Action ON DELETE invalide.');
      }
      final d = c.defaultValue?.trim();
      if (d != null && d.isNotEmpty && c.type == SqlColumnType.integer && !_isKeyword(d) && int.tryParse(d) == null) {
        errors.add('« ${c.name} » : la valeur par défaut doit être un entier.');
      }
      if (d != null && d.isNotEmpty && c.type == SqlColumnType.boolean && !_isKeyword(d) && d != '0' && d != '1') {
        errors.add('« ${c.name} » : la valeur par défaut d\'un booléen est 0 ou 1.');
      }
    }
    final pkCount = def.columns.where((c) => c.primaryKey).length;
    if (pkCount > 1 && def.columns.any((c) => c.autoIncrement)) {
      errors.add('L\'auto-incrément est impossible avec une clé primaire composée.');
    }
    return errors;
  }

  static bool _isKeyword(String v) => _sqlKeywordsDefaults.contains(v.toUpperCase());

  static String _defaultLiteral(ColumnDefinition c) {
    final d = c.defaultValue!.trim();
    if (_isKeyword(d)) return d.toUpperCase();
    final numericType = {SqlColumnType.integer, SqlColumnType.real, SqlColumnType.numeric, SqlColumnType.boolean}
        .contains(c.type);
    if (numericType && _number.hasMatch(d)) return d;
    return quoteLiteral(d);
  }

  /// CREATE TABLE complet. Lève [ArgumentError] si la définition est invalide.
  static String createTable(TableDefinition def) {
    final errors = validateTable(def);
    if (errors.isNotEmpty) throw ArgumentError(errors.join('\n'));

    final pkColumns = def.columns.where((c) => c.primaryKey).toList();
    final inlinePk = pkColumns.length == 1;
    final lines = <String>[];

    for (final c in def.columns) {
      final parts = <String>[quote(c.name.trim()), c.type.sql];
      if (inlinePk && c.primaryKey) {
        parts.add('PRIMARY KEY');
        if (c.autoIncrement) parts.add('AUTOINCREMENT');
      }
      if (c.notNull && !(inlinePk && c.primaryKey && c.type == SqlColumnType.integer)) parts.add('NOT NULL');
      if (c.unique && !c.primaryKey) parts.add('UNIQUE');
      if (c.defaultValue != null && c.defaultValue!.trim().isNotEmpty) parts.add('DEFAULT ${_defaultLiteral(c)}');
      if (c.type == SqlColumnType.boolean) parts.add('CHECK (${quote(c.name.trim())} IN (0, 1))');
      if (c.references != null) {
        final r = c.references!;
        parts.add('REFERENCES ${quote(r.table)}(${quote(r.column)})');
        if (r.onDelete != 'NO ACTION') parts.add('ON DELETE ${r.onDelete}');
      }
      lines.add('  ${parts.join(' ')}');
    }
    if (pkColumns.length > 1) {
      lines.add('  PRIMARY KEY (${pkColumns.map((c) => quote(c.name.trim())).join(', ')})');
    }
    return 'CREATE TABLE ${quote(def.name.trim())} (\n${lines.join(',\n')}\n);';
  }

  static String insert(String table, List<String> columns) {
    if (columns.isEmpty) return 'INSERT INTO ${quote(table)} DEFAULT VALUES;';
    final cols = columns.map(quote).join(', ');
    final params = List.filled(columns.length, '?').join(', ');
    return 'INSERT INTO ${quote(table)} ($cols) VALUES ($params);';
  }

  static String _where(RowKey key) => key.values.keys.map((k) => '${k == 'rowid' ? 'rowid' : quote(k)} IS ?').join(' AND ');

  static String update(String table, List<String> columns, RowKey key) {
    final sets = columns.map((c) => '${quote(c)} = ?').join(', ');
    return 'UPDATE ${quote(table)} SET $sets WHERE ${_where(key)};';
  }

  static String delete(String table, RowKey key) => 'DELETE FROM ${quote(table)} WHERE ${_where(key)};';
}

/// Classification simple des requêtes saisies par l'utilisateur pour exiger
/// une confirmation avant les opérations destructives.
class SqlSafety {
  static final _destructive = RegExp(
    r'\b(DROP|DELETE|TRUNCATE|ALTER|REPLACE|UPDATE|VACUUM|DETACH|REINDEX)\b',
    caseSensitive: false,
  );

  /// Retire les commentaires et les chaînes pour éviter les faux positifs.
  static String _strip(String sql) => sql
      .replaceAll(RegExp(r'--[^\n]*'), ' ')
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r"'(?:[^']|'')*'"), "''");

  static bool isDestructive(String sql) => _destructive.hasMatch(_strip(sql));

  static List<String> destructiveKeywords(String sql) =>
      _destructive.allMatches(_strip(sql)).map((m) => m.group(1)!.toUpperCase()).toSet().toList();
}

/// Découpage d'un script SQL en instructions, aux « ; » situés hors chaînes,
/// identifiants entre guillemets et commentaires. Chaque morceau conserve son
/// « ; » final.
class SqlScript {
  static List<String> split(String sql) {
    final out = <String>[];
    final buf = StringBuffer();
    var i = 0;
    while (i < sql.length) {
      final ch = sql[i];
      final next = i + 1 < sql.length ? sql[i + 1] : '';
      if (ch == '-' && next == '-') {
        final end = sql.indexOf('\n', i);
        final stop = end == -1 ? sql.length : end;
        buf.write(sql.substring(i, stop));
        i = stop;
        continue;
      }
      if (ch == '/' && next == '*') {
        final end = sql.indexOf('*/', i + 2);
        final stop = end == -1 ? sql.length : end + 2;
        buf.write(sql.substring(i, stop));
        i = stop;
        continue;
      }
      if (ch == "'" || ch == '"' || ch == '`' || ch == '[') {
        final close = ch == '[' ? ']' : ch;
        var j = i + 1;
        while (j < sql.length) {
          if (sql[j] == close) {
            if (close != ']' && j + 1 < sql.length && sql[j + 1] == close) {
              j += 2; // guillemet doublé = échappement
              continue;
            }
            break;
          }
          j++;
        }
        final stop = j < sql.length ? j + 1 : sql.length;
        buf.write(sql.substring(i, stop));
        i = stop;
        continue;
      }
      buf.write(ch);
      i++;
      if (ch == ';') {
        out.add(buf.toString());
        buf.clear();
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out.where((s) => !isBlank(s)).isEmpty ? const [] : out;
  }

  /// Vrai si le texte ne contient que des espaces, commentaires et « ; ».
  static bool isBlank(String sql) => sql
      .replaceAll(RegExp(r'--[^\n]*'), '')
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(';', '')
      .trim()
      .isEmpty;
}
