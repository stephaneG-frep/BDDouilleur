import 'dart:io';

import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/domain/models/journal_entry.dart';
import 'package:bddouilleur/domain/models/schema.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AppState openState(String root) {
  final paths = AppPaths(root);
  return AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase));
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('bddouilleur_persist_'));
  tearDown(() async => tmp.delete(recursive: true));

  test('projets, bases, tables et données persistent après fermeture et réouverture', () async {
    var state = openState(tmp.path);
    final project = state.createProject('Boutique', 'Ma boutique en ligne');
    state.setThemeMode(ThemeMode.dark);
    final conn = await state.createSqliteDatabase(project, 'Catalogue Été');
    expect(File(conn.location).existsSync(), isTrue);
    expect(File(conn.location).lengthSync(), greaterThan(0), reason: 'en-tête SQLite écrit');
    expect(conn.location, endsWith('catalogue_ete.db'));

    await state.runLogged(
      connection: conn,
      action: JournalAction.tableCreated,
      summary: 'Table produits',
      run: (c) => c.createTable(TableDefinition(name: 'produits', columns: [
        ColumnDefinition(name: 'id', type: SqlColumnType.integer, primaryKey: true, autoIncrement: true),
        ColumnDefinition(name: 'libelle', type: SqlColumnType.text, notNull: true),
        ColumnDefinition(name: 'prix', type: SqlColumnType.real),
      ])),
    );
    await state.runLogged(
      connection: conn,
      action: JournalAction.rowInserted,
      summary: 'Ajout',
      run: (c) => c.insertRow('produits', {'libelle': 'Chapeau', 'prix': 19.9}),
    );
    // Échec journalisé comme tel.
    await expectLater(
      state.runLogged(
        connection: conn,
        action: JournalAction.rowInserted,
        summary: 'Ajout invalide',
        run: (c) => c.insertRow('produits', {'prix': 1}),
      ),
      throwsA(anything),
    );
    state.dispose(); // fermeture de l'application

    state = openState(tmp.path); // redémarrage
    expect(state.themeMode, ThemeMode.dark);
    expect(state.activeProject?.name, 'Boutique');
    final reopened = state.connections.forProject(project.id!).single;
    expect(reopened.name, 'Catalogue Été');
    final connector = await state.connectorFor(reopened);
    expect(await connector.listTables(), ['produits']);
    final rows = await connector.readRows('produits');
    expect(rows.rows.single['libelle'], 'Chapeau');
    expect(rows.rows.single['prix'], 19.9);

    final entries = state.journal.recent(projectId: project.id);
    expect(entries.where((e) => e.action == JournalAction.tableCreated).single.sql, contains('CREATE TABLE "produits"'));
    expect(entries.where((e) => !e.success).single.error, contains('obligatoire'));
    state.dispose();
  });

  test('attacher un fichier existant puis supprimer un projet avec ses fichiers', () async {
    final state = openState(tmp.path);
    final project = state.createProject('P', '');
    final conn = await state.createSqliteDatabase(project, 'Base');
    final other = state.createProject('Q', '');
    final attached = await state.attachSqliteFile(other, conn.location);
    expect(state.isManagedFile(attached), isFalse);
    await expectLater(state.attachSqliteFile(other, conn.location), throwsA(anything));

    await state.deleteProject(project, deleteFiles: true);
    expect(File(conn.location).existsSync(), isFalse);
    expect(state.projects.byId(project.id!), isNull);
    expect(state.connections.forProject(project.id!), isEmpty);
    state.dispose();
  });

  test('noms de fichiers sûrs', () {
    expect(AppPaths.safeFileName('Mes Clients 2026 !'), 'mes_clients_2026');
    expect(AppPaths.safeFileName('../../etc/passwd'), 'etc_passwd');
    expect(AppPaths.safeFileName('***'), 'base');
  });
}
