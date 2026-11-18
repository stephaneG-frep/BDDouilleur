import 'dart:io';

import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/domain/models/project.dart';
import 'package:bddouilleur/presentation/repair/repair_screen.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('Réparateur : chaque bouton donne un retour visible (téléphone)', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('bdd_rep_ui_');
    final paths = AppPaths(tmp.path);
    final state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
    final project = state.createProject('P', '');
    late DbConnection conn;
    await tester.runAsync(() async {
      conn = await state.createSqliteDatabase(project, 'Base');
      await (await state.connectorFor(conn)).executeSql("CREATE TABLE clients(id INTEGER PRIMARY KEY, ville TEXT); INSERT INTO clients(ville) VALUES ('Paris');");
    });
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: state, child: MaterialApp(home: RepairScreen(connection: conn))));
    await tester.pumpAndSettle();
    expect(find.text('Aucun problème détecté'), findsOneWidget);

    await tester.tap(find.byTooltip('Relancer le diagnostic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Diagnostic relancé'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first)).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Plan d\'exécution'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Plan d\'exécution'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saisissez d\'abord une requête'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first)).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), "SELECT * FROM clients WHERE ville = 'Paris'");
    await tester.tap(find.text('Plan d\'exécution'));
    await tester.pumpAndSettle();
    expect(find.textContaining('constat(s) pour cette requête'), findsOneWidget);
    expect(find.textContaining('Parcours complet de « clients »'), findsOneWidget);
    expect(find.textContaining('SCAN clients'), findsOneWidget);
    state.dispose();
    tmp.deleteSync(recursive: true);
  });
}
