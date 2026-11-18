import 'dart:io';

import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/domain/ai/ai_models.dart';
import 'package:bddouilleur/domain/autopilot/autopilot_plan.dart';
import 'package:bddouilleur/domain/models/project.dart';
import 'package:bddouilleur/presentation/autopilot/autopilot_screen.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'agent_test.dart' show ScriptedProvider, call, say;

void main() {
  late Directory tmp;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bdd_ap_ui_');
    final paths = AppPaths(tmp.path);
    state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
  });

  tearDown(() {
    state.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> waitFor(WidgetTester tester, Finder f) async {
    for (var i = 0; i < 60 && f.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(f, findsWidgets);
  }

  testWidgets('objectif → plan → approbation → confirmation destructive → rapport → retour arrière', (tester) async {
    final project = state.createProject('CRM', '');
    late DbConnection conn;
    await tester.runAsync(() async {
      conn = await state.createSqliteDatabase(project, 'Clients');
      await (await state.connectorFor(conn)).executeSql("CREATE TABLE tests(a); INSERT INTO tests VALUES ('x');");
    });
    state.providerFactory = (_) => ScriptedProvider([
          (_) => call('submit_plan', {
                'summary': 'Créer la table clients et vider la table de tests',
                'steps': [
                  {
                    'title': 'Créer la table clients',
                    'tool': 'create_tables',
                    'args': {
                      'connection_id': conn.id,
                      'proposal': {
                        'entities': [
                          {
                            'name': 'Client',
                            'fields': [
                              {'name': 'nom', 'type': 'text', 'required': true}
                            ]
                          }
                        ]
                      }
                    },
                  },
                  {'title': 'Vider la table de tests', 'tool': 'execute_sql', 'args': {'connection_id': conn.id, 'sql': 'DELETE FROM tests'}},
                ],
              }),
          (_) => say('Plan soumis.'),
        ]);
    state.ai.setModel(AiProviderKind.ollama, 'fake');
    state.ai.defaultProvider = AiProviderKind.ollama;

    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: AutopilotRunScreen()),
    ));
    await waitFor(tester, find.text('Préparer le plan'));
    await tester.enterText(find.byType(TextField).first, 'Prépare la base clients et nettoie les tests');
    await tester.tap(find.text('Clients'));
    await tester.pump();
    await tester.tap(find.text('Préparer le plan'));
    await waitFor(tester, find.text('Approuver et exécuter'));
    expect(find.text('Structure'), findsOneWidget);
    expect(find.text('Destructive'), findsOneWidget);
    expect(find.text('confirmation'), findsOneWidget);
    expect(await tester.runAsync(() async => (await state.connectorFor(conn)).listTables()), ['tests'], reason: 'rien exécuté avant approbation');

    await tester.tap(find.text('Approuver et exécuter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exécuter'));
    await waitFor(tester, find.text('Confirmer : Vider la table de tests'));
    await tester.tap(find.text('Autoriser'));
    await waitFor(tester, find.text('Rapport'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Résultat : Terminé'), findsOneWidget);
    final run = state.autopilotRuns.forProject(project.id!).single;
    expect(run.status, RunStatus.succeeded);
    late List<String> tables;
    late Object? count;
    await tester.runAsync(() async {
      final db = await state.connectorFor(conn);
      tables = await db.listTables();
      count = (await db.select('SELECT COUNT(*) AS n FROM tests')).single['n'];
    });
    expect(tables, containsAll(['clients', 'tests']));
    expect(count, 0);

    await tester.tap(find.text('Annuler toute l\'exécution (retour arrière)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Retour arrière'));
    await waitFor(tester, find.textContaining('Annulé (retour arrière)'));
    await tester.runAsync(() async {
      final db = await state.connectorFor(conn);
      tables = await db.listTables();
      count = (await db.select('SELECT COUNT(*) AS n FROM tests')).single['n'];
    });
    expect(tables, ['tests']);
    expect(count, 1);
  });
}
