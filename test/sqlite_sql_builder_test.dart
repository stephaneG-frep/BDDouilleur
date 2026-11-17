import 'package:bddouilleur/data/connectors/sqlite/sqlite_sql_builder.dart';
import 'package:bddouilleur/domain/models/schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('validateIdentifier', () {
    test('accepte les noms simples', () {
      expect(SqliteSqlBuilder.validateIdentifier('clients'), isNull);
      expect(SqliteSqlBuilder.validateIdentifier('_date_creation2'), isNull);
    });

    test('refuse vides, accents, espaces, mots réservés et préfixe sqlite_', () {
      expect(SqliteSqlBuilder.validateIdentifier(''), isNotNull);
      expect(SqliteSqlBuilder.validateIdentifier('prénom'), isNotNull);
      expect(SqliteSqlBuilder.validateIdentifier('mon nom'), isNotNull);
      expect(SqliteSqlBuilder.validateIdentifier('1abc'), isNotNull);
      expect(SqliteSqlBuilder.validateIdentifier('select'), isNotNull);
      expect(SqliteSqlBuilder.validateIdentifier('sqlite_x'), isNotNull);
      expect(SqliteSqlBuilder.validateIdentifier('a"; DROP TABLE x; --'), isNotNull);
    });
  });

  test('quote échappe les guillemets', () {
    expect(SqliteSqlBuilder.quote('a"b'), '"a""b"');
    expect(SqliteSqlBuilder.quoteLiteral("l'école"), "'l''école'");
  });

  test('createTable génère le SQL attendu', () {
    final sql = SqliteSqlBuilder.createTable(TableDefinition(name: 'commandes', columns: [
      ColumnDefinition(name: 'id', type: SqlColumnType.integer, primaryKey: true, autoIncrement: true),
      ColumnDefinition(name: 'client_id', type: SqlColumnType.integer, notNull: true,
          references: const ForeignKeyRef(table: 'clients', column: 'id', onDelete: 'CASCADE')),
      ColumnDefinition(name: 'statut', type: SqlColumnType.text, defaultValue: "en attente d'envoi"),
      ColumnDefinition(name: 'payee', type: SqlColumnType.boolean, defaultValue: '0'),
      ColumnDefinition(name: 'cree_le', type: SqlColumnType.datetime, defaultValue: 'current_timestamp'),
    ]));
    expect(sql, contains('"id" INTEGER PRIMARY KEY AUTOINCREMENT'));
    expect(sql, contains('"client_id" INTEGER NOT NULL REFERENCES "clients"("id") ON DELETE CASCADE'));
    expect(sql, contains("DEFAULT 'en attente d''envoi'"));
    expect(sql, contains('"payee" BOOLEAN DEFAULT 0 CHECK ("payee" IN (0, 1))'));
    expect(sql, contains('DEFAULT CURRENT_TIMESTAMP'));
  });

  test('clé primaire composée en contrainte de table', () {
    final sql = SqliteSqlBuilder.createTable(TableDefinition(name: 'lignes', columns: [
      ColumnDefinition(name: 'commande_id', type: SqlColumnType.integer, primaryKey: true),
      ColumnDefinition(name: 'produit_id', type: SqlColumnType.integer, primaryKey: true),
    ]));
    expect(sql, contains('PRIMARY KEY ("commande_id", "produit_id")'));
  });

  test('validateTable détecte les erreurs', () {
    final errors = SqliteSqlBuilder.validateTable(TableDefinition(name: 't', columns: [
      ColumnDefinition(name: 'a', type: SqlColumnType.text, autoIncrement: true),
      ColumnDefinition(name: 'A'),
      ColumnDefinition(name: 'n', type: SqlColumnType.integer, defaultValue: 'abc'),
    ]));
    expect(errors.length, 3);
    expect(() => SqliteSqlBuilder.createTable(TableDefinition(name: 'x', columns: [])), throwsArgumentError);
  });

  group('SqlSafety', () {
    test('détecte les instructions destructives', () {
      expect(SqlSafety.isDestructive('DROP TABLE a'), isTrue);
      expect(SqlSafety.isDestructive('delete from a where id=1'), isTrue);
      expect(SqlSafety.isDestructive('SELECT * FROM a'), isFalse);
      expect(SqlSafety.isDestructive('INSERT INTO a VALUES (1)'), isFalse);
    });

    test('ignore les mots-clés dans les chaînes et commentaires', () {
      expect(SqlSafety.isDestructive("SELECT 'DROP TABLE x' AS t -- delete"), isFalse);
      expect(SqlSafety.isDestructive("INSERT INTO notes VALUES ('update prévue') /* DROP */"), isFalse);
    });
  });
}
