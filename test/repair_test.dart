import 'dart:io';

import 'package:bddouilleur/data/connectors/sqlite/sqlite_connector.dart';
import 'package:bddouilleur/data/firebase/firebase_diagnostic.dart' show DiagSeverity;
import 'package:bddouilleur/data/repair/sqlite_doctor.dart';
import 'package:bddouilleur/domain/autopilot/autonomy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bdd_repair_');
    path = '${dir.path}/abimee.db';
    final db = sqlite3.open(path);
    db.execute('''
      PRAGMA foreign_keys = OFF;
      CREATE TABLE clients(id INTEGER PRIMARY KEY, nom TEXT NOT NULL, ville TEXT);
      CREATE TABLE factures(id INTEGER PRIMARY KEY, client_id INTEGER REFERENCES clients(id), montant INTEGER);
      CREATE TABLE lignes(id INTEGER PRIMARY KEY, produit_id INTEGER REFERENCES produits_supprimes(id));
      CREATE VIEW v_cassee AS SELECT * FROM ancienne_table;
      INSERT INTO clients(id, nom, ville) VALUES (1, 'Ada', 'Paris'), (2, 'Grace', 'Lyon');
      INSERT INTO factures(client_id, montant) VALUES (1, 100), (2, 50), (99, 10), (98, 20);
    ''');
    db.close();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('diagnostic : constats réels avec corrections typées et risques', () async {
    final c = SqliteConnector(path);
    await c.open();
    final doctor = SqliteDoctor(c, connectionId: 7, recentQueries: [
      "SELECT * FROM clients WHERE ville = 'Paris'",
      'SELECT * FROM table_inconnue',
    ]);
    final f = await doctor.run();
    String titles() => f.map((x) => x.problem).join('\n');

    final orphans = f.firstWhere((x) => x.problem.contains('référencent un « clients » inexistant'));
    expect(orphans.problem, startsWith('2 ligne(s) de « factures »'));
    expect(orphans.risk, ActionRisk.destructive);
    expect(orphans.action!.tool, 'execute_sql');
    expect(orphans.action!.args['sql'], startsWith('DELETE FROM "factures" WHERE rowid IN ('));

    expect(titles(), contains('« lignes.produit_id » référence la table absente « produits_supprimes »'));
    final index = f.firstWhere((x) => x.problem.contains('Clé étrangère « factures.client_id » sans index'));
    expect(index.risk, ActionRisk.schema);
    expect(index.action!.tool, 'create_index');
    expect(index.action!.args['columns'], ['client_id']);
    expect(titles(), contains('Vue « v_cassee » invalide'));
    final scan = f.firstWhere((x) => x.problem.contains('Parcours complet de « clients »'));
    expect(scan.action!.args['columns'], ['ville']);
    expect(titles(), contains('Requête incorrecte'));
    expect(f.where((x) => x.severity == DiagSeverity.error).length, greaterThanOrEqualTo(4));

    // Application des corrections, puis vérification : les constats disparaissent.
    await c.executeSql(orphans.action!.args['sql'] as String);
    await c.executeSql('CREATE INDEX idx_f ON factures(client_id); CREATE INDEX idx_v ON clients(ville); DROP VIEW v_cassee;');
    final after = await SqliteDoctor(c, connectionId: 7, recentQueries: ["SELECT * FROM clients WHERE ville = 'Paris'"]).run();
    final t2 = after.map((x) => x.problem).join('\n');
    expect(t2, isNot(contains('inexistant')));
    expect(t2, isNot(contains('sans index')));
    expect(t2, isNot(contains('Parcours complet')));
    expect(t2, isNot(contains('v_cassee')));
    expect(t2, contains('produits_supprimes'), reason: 'la migration incomplète reste signalée');
    await c.close();
  });

  test('base saine : aucun problème ; fragmentation et statistiques détectées', () async {
    final clean = '${dir.path}/saine.db';
    final db = sqlite3.open(clean);
    db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, x TEXT);');
    db.execute('BEGIN');
    final ins = db.prepare('INSERT INTO t(x) VALUES (?)');
    for (var i = 0; i < 3000; i++) {
      ins.execute(['valeur assez longue pour remplir des pages $i' * 3]);
    }
    ins.close();
    db.execute('COMMIT');
    db.close();
    final c = SqliteConnector(clean);
    await c.open();
    final f1 = await SqliteDoctor(c, connectionId: 1).run();
    expect(f1.map((x) => x.problem), contains('Statistiques de l\'optimiseur absentes'));
    await c.executeSql('DELETE FROM t WHERE id > 100;');
    final f2 = await SqliteDoctor(c, connectionId: 1).run();
    final vacuum = f2.firstWhere((x) => x.problem.contains('espace inutilisé'));
    expect(vacuum.action!.args['sql'], 'VACUUM;');
    expect(vacuum.risk, ActionRisk.destructive);
    await c.executeSql('VACUUM; ANALYZE;');
    final f3 = await SqliteDoctor(c, connectionId: 1).run();
    expect(f3.single.severity, DiagSeverity.ok);
    await c.close();
  });

  test('connexion : fichier absent ou qui n\'est pas une base', () {
    expect(SqliteDoctor.connectionCheck('${dir.path}/absent.db').single.problem, 'Fichier de base introuvable');
    File('${dir.path}/faux.db').writeAsStringSync('ceci n\'est pas une base SQLite du tout');
    expect(SqliteDoctor.connectionCheck('${dir.path}/faux.db').single.problem, contains('n\'est pas une base SQLite'));
  });
}
