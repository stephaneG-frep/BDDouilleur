import 'dart:io';

import 'package:bddouilleur/data/backup/sqlite_backup_service.dart';
import 'package:bddouilleur/data/connectors/database_connector.dart';
import 'package:bddouilleur/data/connectors/sqlite/sqlite_connector.dart';
import 'package:bddouilleur/data/connectors/sqlite/sqlite_value_codec.dart';
import 'package:bddouilleur/domain/models/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

TableDefinition clients() => TableDefinition(name: 'clients', columns: [
      ColumnDefinition(name: 'id', type: SqlColumnType.integer, primaryKey: true, autoIncrement: true),
      ColumnDefinition(name: 'nom', type: SqlColumnType.text, notNull: true),
      ColumnDefinition(name: 'email', type: SqlColumnType.text, unique: true),
      ColumnDefinition(name: 'solde', type: SqlColumnType.real, defaultValue: '0'),
    ]);

TableDefinition commandes() => TableDefinition(name: 'commandes', columns: [
      ColumnDefinition(name: 'id', type: SqlColumnType.integer, primaryKey: true),
      ColumnDefinition(name: 'client_id', type: SqlColumnType.integer, notNull: true,
          references: const ForeignKeyRef(table: 'clients', column: 'id', onDelete: 'CASCADE')),
      ColumnDefinition(name: 'montant', type: SqlColumnType.numeric),
    ]);

void main() {
  late Directory tmp;
  late SqliteConnector db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bddouilleur_test_');
    db = SqliteConnector(p.join(tmp.path, 'test.db'), createIfMissing: true);
    await db.open();
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('annonce uniquement ses capacités réelles', () {
    expect(db.capabilities, isNot(contains(ConnectorCapability.migration)));
    expect(db.capabilities, contains(ConnectorCapability.crud));
  });

  test('refuse d\'ouvrir un fichier absent sans createIfMissing', () async {
    expect(() => SqliteConnector(p.join(tmp.path, 'absent.db')).open(), throwsA(isA<ConnectorException>()));
  });

  test('refuse un fichier qui n\'est pas une base SQLite', () async {
    final f = File(p.join(tmp.path, 'faux.db'))..writeAsStringSync('ceci n\'est pas une base de données, vraiment pas');
    expect(() => SqliteConnector(f.path).open(), throwsA(isA<ConnectorException>()));
  });

  test('crée une table et l\'inspecte', () async {
    await db.createTable(clients());
    expect(await db.listTables(), ['clients']);
    final info = await db.describeTable('clients');
    expect(info.columns.map((c) => c.name), ['id', 'nom', 'email', 'solde']);
    expect(info.primaryKeyColumns.single.name, 'id');
    expect(info.columns[1].notNull, isTrue);
    expect(info.indexes.any((i) => i.unique && i.columns.contains('email')), isTrue);
    expect(info.rowCount, 0);
  });

  test('CRUD complet avec valeurs liées', () async {
    await db.createTable(clients());
    final ins = await db.insertRow('clients', {'nom': "O'Brien", 'email': 'ob@exemple.fr'});
    expect(ins.insertedId, 1);
    await db.insertRow('clients', {'nom': 'Zoé', 'email': 'zoe@exemple.fr', 'solde': 12.5});

    var page = await db.readRows('clients');
    expect(page.total, 2);
    expect(page.rows.first['nom'], "O'Brien");
    expect(page.rows.first['solde'], 0); // valeur par défaut

    await db.updateRow('clients', page.keys.first, {'solde': 99.9});
    page = await db.readRows('clients');
    expect(page.rows.first['solde'], 99.9);

    await db.deleteRow('clients', page.keys.last);
    page = await db.readRows('clients');
    expect(page.total, 1);

    expect(() => db.deleteRow('clients', const RowKey({'rowid': 999})), throwsA(isA<ConnectorException>()));
  });

  test('contraintes appliquées et erreurs en français', () async {
    await db.createTable(clients());
    await db.createTable(commandes());
    await db.insertRow('clients', {'nom': 'A', 'email': 'a@a.fr'});
    await expectLater(db.insertRow('clients', {'nom': 'B', 'email': 'a@a.fr'}),
        throwsA(predicate((e) => e.toString().contains('UNIQUE'))));
    await expectLater(db.insertRow('clients', {'email': 'c@c.fr'}),
        throwsA(predicate((e) => e.toString().contains('obligatoire'))));
    await expectLater(db.insertRow('commandes', {'client_id': 42}),
        throwsA(predicate((e) => e.toString().contains('clé étrangère'))));

    await db.insertRow('commandes', {'client_id': 1, 'montant': 10});
    final page = await db.readRows('clients');
    await db.deleteRow('clients', page.keys.first);
    expect((await db.readRows('commandes')).total, 0, reason: 'ON DELETE CASCADE');
  });

  test('pagination', () async {
    await db.createTable(clients());
    for (var i = 0; i < 30; i++) {
      await db.insertRow('clients', {'nom': 'c$i'});
    }
    final p2 = await db.readRows('clients', limit: 10, offset: 10);
    expect(p2.rows.length, 10);
    expect(p2.rows.first['nom'], 'c10');
    expect(p2.total, 30);
  });

  test('table WITHOUT ROWID identifiée par sa clé primaire', () async {
    await db.executeSql('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID; INSERT INTO kv VALUES (\'a\', \'1\');');
    final page = await db.readRows('kv');
    expect(page.keys.first.values, {'k': 'a'});
    await db.updateRow('kv', page.keys.first, {'v': '2'});
    expect((await db.readRows('kv')).rows.first['v'], '2');
  });

  test('executeSql : requêtes et modifications', () async {
    await db.createTable(clients());
    final w = await db.executeSql("INSERT INTO clients(nom) VALUES ('a'); INSERT INTO clients(nom) VALUES ('b');");
    expect(w.isQuery, isFalse);
    expect(w.affectedRows, 2);
    final r = await db.executeSql('SELECT nom FROM clients ORDER BY nom');
    expect(r.isQuery, isTrue);
    expect(r.rows, [['a'], ['b']]);
    expect(() => db.executeSql('SELEC 1'), throwsA(isA<ConnectorException>()));
  });

  test('executeSql : script avec trigger et points-virgules dans les chaînes', () async {
    await db.executeSql('''
      CREATE TABLE log (msg TEXT);
      CREATE TABLE t (v TEXT);
      -- commentaire ; avec point-virgule
      CREATE TRIGGER t_ins AFTER INSERT ON t BEGIN
        INSERT INTO log VALUES ('ajout; ' || new.v);
      END;
      INSERT INTO t VALUES ('a;b');
    ''');
    final r = await db.executeSql('SELECT msg FROM log');
    expect(r.rows, [['ajout; a;b']]);
    expect(() => db.executeSql('  -- rien\n ;'), throwsA(isA<ConnectorException>()));
  });

  test('intégrité, sauvegarde et restauration', () async {
    await db.createTable(clients());
    await db.insertRow('clients', {'nom': 'avant'});
    expect((await db.checkIntegrity()).ok, isTrue);

    final service = SqliteBackupService(p.join(tmp.path, 'backups'));
    final (backup, sql) = await service.create(db);
    expect(sql, startsWith('VACUUM INTO'));
    expect(SqliteBackupService.verify(backup.path), isEmpty);

    await db.insertRow('clients', {'nom': 'après'});
    expect((await db.readRows('clients')).total, 2);

    final safety = await service.restore(db, backup);
    expect(File(safety.path).existsSync(), isTrue);
    final page = await db.readRows('clients');
    expect(page.total, 1);
    expect(page.rows.single['nom'], 'avant');
    expect(service.list().length, 2);
  });

  test('restauration refusée si la sauvegarde est corrompue', () async {
    final bad = File(p.join(tmp.path, 'backups', 'bad.db'))
      ..createSync(recursive: true)
      ..writeAsStringSync('corrompu' * 100);
    final service = SqliteBackupService(p.join(tmp.path, 'backups'));
    final b = service.list().single;
    expect(b.path, bad.path);
    await expectLater(service.restore(db, b), throwsA(isA<ConnectorException>()));
    expect(db.isOpen, isTrue);
  });

  group('SqliteValueCodec', () {
    const intCol = ColumnInfo(name: 'n', declaredType: 'INTEGER', notNull: true, defaultValue: null, primaryKeyIndex: 0);
    const realCol = ColumnInfo(name: 'r', declaredType: 'REAL', notNull: false, defaultValue: null, primaryKeyIndex: 0);
    const boolCol = ColumnInfo(name: 'b', declaredType: 'BOOLEAN', notNull: false, defaultValue: null, primaryKeyIndex: 0);

    test('convertit selon l\'affinité', () {
      expect(SqliteValueCodec.parse('42', intCol), 42);
      expect(SqliteValueCodec.parse('3,5', realCol), 3.5);
      expect(SqliteValueCodec.parse('', realCol), isNull);
      expect(SqliteValueCodec.parse('oui', boolCol), 1);
      expect(SqliteValueCodec.parse(null, intCol), isNull);
      expect(() => SqliteValueCodec.parse('abc', intCol), throwsFormatException);
      expect(() => SqliteValueCodec.parse('', intCol), throwsFormatException);
    });
  });
}
