// Captures d'écran rendues par le moteur Flutter, avec les vraies polices.
// Usage : flutter test tool/screenshots.dart  (sortie : build/screenshots/)
import 'dart:convert';

import 'package:bddouilleur/data/codegen/code_integrator.dart';
import 'package:bddouilleur/domain/ai/ai_models.dart';
import 'package:bddouilleur/domain/autopilot/autonomy.dart';
import 'package:bddouilleur/domain/autopilot/autopilot_plan.dart';
import 'package:bddouilleur/presentation/autopilot/autopilot_screen.dart';
import 'package:bddouilleur/presentation/repair/repair_screen.dart';
import 'package:bddouilleur/state/autopilot_engine.dart';
import 'package:bddouilleur/domain/schema_proposal.dart';
import 'package:bddouilleur/presentation/agent/agent_screen.dart';
import 'package:bddouilleur/presentation/agent/ai_providers_screen.dart';
import 'package:bddouilleur/presentation/agent/chat_screen.dart';
import 'package:bddouilleur/presentation/codegen/codegen_screen.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/domain/firebase/firebase_target.dart';
import 'package:bddouilleur/domain/models/db_engine.dart';
import 'package:bddouilleur/presentation/firebase/firebase_hub_screen.dart';
import 'package:bddouilleur/presentation/firebase/rules_view.dart';
import 'package:bddouilleur/app.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/domain/models/journal_entry.dart';
import 'package:bddouilleur/domain/models/schema.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<void> loadFonts() async {
  final cache = '${Platform.environment['HOME']}/snap/flutter/common/flutter/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final f in ['Roboto-Regular', 'Roboto-Medium', 'Roboto-Bold', 'Roboto-Italic', 'Roboto-Black']) {
    roboto.addFont(Future.value(File('$cache/$f.ttf').readAsBytesSync().buffer.asByteData()));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(File('$cache/MaterialIcons-Regular.otf').readAsBytesSync().buffer.asByteData()));
  await icons.load();
  final mono = FontLoader('monospace')
    ..addFont(Future.value(File('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf').readAsBytesSync().buffer.asByteData()));
  await mono.load();
}

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/screenshots').createSync(recursive: true);
    File('build/screenshots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('captures', (tester) async {
    await tester.runAsync(loadFonts);
    final tmp = Directory.systemTemp.createTempSync('bdd_shots_');
    final paths = AppPaths(tmp.path);
    final state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
    final project = state.createProject('Boutique en ligne', 'Application Flutter de vente');
    final conn = await state.createSqliteDatabase(project, 'Catalogue');
    await state.runLogged(
      connection: conn,
      action: JournalAction.tableCreated,
      summary: 'Table « produits » créée',
      run: (c) => c.createTable(TableDefinition(name: 'produits', columns: [
        ColumnDefinition(name: 'id', type: SqlColumnType.integer, primaryKey: true, autoIncrement: true),
        ColumnDefinition(name: 'libelle', type: SqlColumnType.text, notNull: true),
        ColumnDefinition(name: 'prix', type: SqlColumnType.real, defaultValue: '0'),
        ColumnDefinition(name: 'en_stock', type: SqlColumnType.boolean, defaultValue: '1'),
      ])),
    );
    for (final (n, p) in [('Chapeau de savant', 24.9), ('Lunettes de labo', 12.5), ('Clé à molette', 8.0)]) {
      await state.runLogged(
          connection: conn,
          action: JournalAction.rowInserted,
          summary: 'Ajout « $n »',
          run: (c) => c.insertRow('produits', {'libelle': n, 'prix': p}));
    }

    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    Future<void> pump(Size size, ThemeMode mode) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      state.setThemeMode(mode);
      await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: ChangeNotifierProvider<AppState>.value(value: state, child: const BddouilleurApp()),
      ));
      await tester.pumpAndSettle();
    }

    await pump(const Size(1280, 860), ThemeMode.dark);
    await shot(tester, '01_accueil_sombre');
    await pump(const Size(1280, 860), ThemeMode.light);
    await shot(tester, '02_accueil_clair');
    await pump(const Size(400, 860), ThemeMode.dark);
    await shot(tester, '03_accueil_telephone');

    await pump(const Size(1280, 860), ThemeMode.dark);
    await tester.tap(find.text('Projets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Boutique en ligne').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Catalogue'));
    await tester.pumpAndSettle();
    await shot(tester, '04_base_tables');
    await tester.tap(find.text('produits'));
    await tester.pumpAndSettle();
    await shot(tester, '05_table_donnees');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nouvelle table'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Nom de la table'), 'clients');
    await tester.pumpAndSettle();
    await shot(tester, '06_nouvelle_table');

    // --- Firebase AutoPilot (sans réseau : écrans et générateur de règles).
    final fb = state.connections.create(
      projectId: project.id!,
      name: 'demo-boutique (émulateur)',
      engine: DbEngine.firestore,
      location: 'demo-boutique',
      config: const FirebaseTarget(mode: FirebaseMode.emulator, projectId: 'demo-boutique').toJson()..remove('projectId'),
    );
    Future<void> open(Widget screen, Size size) async {
      await pump(size, ThemeMode.dark);
      tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute(builder: (_) => screen));
      await tester.pumpAndSettle();
    }

    await open(const FirebaseHubScreen(), const Size(1280, 1100));
    await shot(tester, '07_firebase_autopilot');
    await open(RulesEditorScreen(connection: fb), const Size(1280, 1300));
    await shot(tester, '08_regles_generateur');
    await open(const FirebaseHubScreen(), const Size(400, 860));
    await shot(tester, '09_firebase_telephone');

    // --- Phase 3 : agent IA, Détective, Connecteur (données de démonstration, sans réseau).
    state.ai.setModel(AiProviderKind.anthropic, 'claude-opus-5-5');
    state.ai.defaultProvider = AiProviderKind.anthropic;
    final conv = state.aiConversations.create(
        projectId: project.id!, title: 'Base pour la boutique', provider: AiProviderKind.anthropic, model: 'claude-opus-5-5');
    const demo = SchemaProposal(summary: 'Une boutique : catégories, produits et commandes.', entities: [
      EntityProposal(name: 'Category', fields: [FieldProposal(name: 'label', type: SqlColumnType.text, required: true)]),
      EntityProposal(name: 'Product', fields: [
        FieldProposal(name: 'name', type: SqlColumnType.text, required: true),
        FieldProposal(name: 'price', type: SqlColumnType.real, required: true),
        FieldProposal(name: 'categoryId', type: SqlColumnType.integer, references: 'Category', required: true),
      ]),
    ]);
    for (final m in [
      AiMessage.user('Crée-moi une base pour gérer les produits de ma boutique'),
      const AiMessage(role: AiRole.assistant, text: 'Je regarde d\'abord ce que contient la base Catalogue.', toolCalls: [
        AiToolCall(id: '1', name: 'describe_database', arguments: {'connection_id': 1}),
      ]),
      const AiMessage(role: AiRole.tool, toolResults: [
        AiToolResult(callId: '1', name: 'describe_database', content: '{"engine":"sqlite","tables":[{"table":"produits","rows":3}]}'),
      ]),
      AiMessage(role: AiRole.assistant, text: 'Voici une architecture plus complète, avec des catégories.', toolCalls: [
        AiToolCall(id: '2', name: 'propose_schema', arguments: demo.toJson()),
      ]),
      AiMessage(role: AiRole.tool, toolResults: [
        AiToolResult(callId: '2', name: 'propose_schema', content: jsonEncode({'affiche': true, 'proposal': demo.toJson()})),
      ]),
      const AiMessage(role: AiRole.assistant, text: 'Vous pouvez créer ces tables dans « Catalogue » ou générer le code Flutter.'),
    ]) {
      state.aiConversations.addMessage(conv.id, m);
    }
    await open(const AgentScreen(), const Size(1280, 860));
    await shot(tester, '10_agent_conversations');
    await open(ChatScreen(conversationId: conv.id), const Size(1280, 1400));
    await shot(tester, '11_agent_conversation');
    await open(const AiProvidersScreen(), const Size(1280, 900));
    await shot(tester, '12_fournisseurs_ia');
    final flutterDir = Directory('${tmp.path}/appli')..createSync();
    File('${flutterDir.path}/pubspec.yaml').writeAsStringSync('name: boutique\ndependencies:\n  flutter:\n    sdk: flutter\n');
    Directory('${flutterDir.path}/lib/models').createSync(recursive: true);
    // Outils Flutter simulés : Process.run ne s'exécute pas sous l'horloge de test.
    state.codeIntegrator = CodeIntegrator(runner: (exe, args, dir) async => CommandResult('$exe ${args.join(' ')}', 0, 'ok'));
    await open(CodegenScreen(proposal: demo, initialFolder: flutterDir.path), const Size(1280, 1500));
    await tester.tap(find.text('Calculer le plan'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
    await shot(tester, '13_connecteur_plan');
    await open(ChatScreen(conversationId: conv.id), const Size(400, 860));
    await shot(tester, '14_agent_telephone');

    // --- Phase 4 : AutoPilot (exécution de démonstration), Réparateur.
    final apPlan = AutopilotPlan(goal: 'Ajouter des catégories aux produits et indexer la recherche', summary: 'Créer la table categories, '
        'ajouter un index sur produits.libelle, puis vérifier la base.', steps: [
      PlanStep(title: 'Créer la table categories', tool: 'create_tables', args: {'connection_id': conn.id}, risk: ActionRisk.schema,
          status: StepStatus.succeeded, verified: 'Tables présentes : categories', autoApproved: true),
      PlanStep(title: 'Index sur produits.libelle', tool: 'create_index', args: {'connection_id': conn.id, 'table': 'produits', 'columns': ['libelle']},
          risk: ActionRisk.schema, status: StepStatus.succeeded, verified: 'Index « idx_produits_libelle » présent.', autoApproved: true),
      PlanStep(title: 'Supprimer les produits de test', tool: 'execute_sql', args: {'connection_id': conn.id, 'sql': "DELETE FROM produits WHERE libelle LIKE 'test%'"},
          risk: ActionRisk.destructive, needsConfirmation: true, status: StepStatus.succeeded, verified: 'SQL exécuté : 0 ligne(s) modifiée(s).'),
      PlanStep(title: 'Diagnostic final', tool: 'diagnose_database', args: {'connection_id': conn.id}, status: StepStatus.succeeded, verified: 'Lecture effectuée.'),
    ]);
    final apRun = state.autopilotRuns.create(projectId: project.id!, provider: AiProviderKind.anthropic, model: 'claude-opus-5-5', scope: [conn.id!], plan: apPlan)
      ..status = RunStatus.succeeded
      ..checks = [const RunCheck('Prérequis', true, 'Bases accessibles, plan valide.'), const RunCheck('Points de restauration', true, '1 sauvegarde vérifiée créée.'), const RunCheck('Intégrité et clés étrangères de « Catalogue »', true)]
      ..rollback = RollbackInfo(sqliteBackups: {conn.id!: '/tmp/x.db'});
    apRun.report = AutopilotEngine.buildReport(apRun, const Duration(seconds: 14));
    state.autopilotRuns.save(apRun);
    await open(AutopilotRunScreen(runId: apRun.id), const Size(1280, 1700));
    await shot(tester, '15_autopilot_rapport');
    await tester.runAsync(() async => (await state.connectorFor(conn)).executeSql(
        'CREATE TABLE commandes(id INTEGER PRIMARY KEY, produit_id INTEGER REFERENCES produits(id), quantite INTEGER);'));
    await open(RepairScreen(connection: conn), const Size(1280, 1300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await shot(tester, '16_reparateur');

    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    tester.view.reset();
    state.dispose();
    tmp.deleteSync(recursive: true);
  });
}
