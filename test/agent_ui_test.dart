import 'dart:io';

import 'package:bddouilleur/app.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/domain/ai/ai_models.dart';
import 'package:bddouilleur/domain/models/project.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'agent_test.dart' show ScriptedProvider, call, say, proposal;

void main() {
  late Directory tmp;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bdd_agent_ui_');
    final paths = AppPaths(tmp.path);
    state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
  });

  tearDown(() {
    state.dispose();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('conversation : proposition affichée, accord demandé, tables réellement créées', (tester) async {
    final project = state.createProject('Boutique', '');
    late final DbConnection conn;
    await tester.runAsync(() async => conn = await state.createSqliteDatabase(project, 'Catalogue'));
    final provider = ScriptedProvider([
      (_) => call('propose_schema', proposal, text: 'Voici ma proposition.'),
      (_) => call('create_tables', {'proposal': proposal, 'connection_id': conn.id}, id: 'c2', text: 'Je crée les tables.'),
      (m) => say(m.last.toolResults.single.isError ? 'Rien n\'a été créé.' : 'Tables créées : categories et products.'),
    ]);
    state.providerFactory = (_) => provider;
    state.ai.setModel(AiProviderKind.ollama, 'fake');
    state.ai.defaultProvider = AiProviderKind.ollama;

    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: state, child: const BddouilleurApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Agent IA'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Nouvelle conversation'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Commencer'));
    for (var i = 0; i < 20 && find.byTooltip('Envoyer').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'Crée-moi une base pour une boutique');
    await tester.tap(find.byTooltip('Envoyer'));
    for (var i = 0; i < 20 && find.text('L\'agent demande une action').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.text('L\'agent demande une action'), findsOneWidget);
    expect(find.textContaining('categories, products'), findsWidgets);
    await tester.tap(find.text('Autoriser'));
    for (var i = 0; i < 40 && find.textContaining('Tables créées').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('Tables créées : categories et products.'), findsOneWidget);
    expect(find.text('Architecture de données proposée'), findsOneWidget);
    expect(find.text('Proposition de schéma'), findsOneWidget);
    expect(find.text('Création de tables'), findsOneWidget);

    late List<String> tables;
    await tester.runAsync(() async => tables = await (await state.connectorFor(conn)).listTables());
    expect(tables, containsAll(['categories', 'products']));
    final saved = state.aiConversations.messages(state.aiConversations.forProject(project.id!).single.id);
    expect(saved.where((m) => m.role == AiRole.tool), hasLength(2));
    expect(state.aiConversations.forProject(project.id!).single.title, 'Crée-moi une base pour une boutique');
  });
}
