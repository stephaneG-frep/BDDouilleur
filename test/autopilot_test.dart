import 'dart:io';

import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/domain/ai/ai_models.dart';
import 'package:bddouilleur/domain/autopilot/autonomy.dart';
import 'package:bddouilleur/domain/autopilot/autopilot_plan.dart';
import 'package:bddouilleur/domain/models/journal_entry.dart';
import 'package:bddouilleur/domain/models/project.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:bddouilleur/state/autopilot_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_test.dart' show ScriptedProvider, call, say;

const schema = {
  'summary': 'Clients',
  'entities': [
    {
      'name': 'Client',
      'fields': [
        {'name': 'nom', 'type': 'text', 'required': true},
        {'name': 'email', 'type': 'text'},
      ]
    }
  ],
};

void main() {
  late Directory tmp;
  late AppState state;
  late Project project;
  late DbConnection conn;
  late DbConnection other;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bdd_autopilot_');
    final paths = AppPaths(tmp.path);
    state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
    project = state.createProject('CRM', '');
    conn = await state.createSqliteDatabase(project, 'Clients');
    other = await state.createSqliteDatabase(project, 'Hors périmètre');
  });

  tearDown(() {
    state.dispose();
    tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> step(String title, String tool, Map<String, Object?> args) => {'title': title, 'tool': tool, 'args': args, 'verification': 'ok'};

  AutopilotEngine engine(ScriptedProvider p) =>
      AutopilotEngine(state: state, project: project, provider: p, model: 'fake', scope: {conn.id!});

  Future<List<String>> tables(DbConnection c) async => (await state.connectorFor(c)).listTables();

  test('politique des modes', () {
    expect(ActionPolicy.requiresConfirmation(AutonomyMode.manual, ActionRisk.routine), isTrue);
    expect(ActionPolicy.requiresConfirmation(AutonomyMode.assisted, ActionRisk.routine), isFalse);
    expect(ActionPolicy.requiresConfirmation(AutonomyMode.assisted, ActionRisk.schema), isTrue);
    expect(ActionPolicy.requiresConfirmation(AutonomyMode.autopilot, ActionRisk.schema), isFalse);
    for (final m in AutonomyMode.values) {
      expect(ActionPolicy.requiresConfirmation(m, ActionRisk.destructive), isTrue);
      expect(ActionPolicy.requiresConfirmation(m, ActionRisk.sensitive), isTrue);
      expect(ActionPolicy.requiresConfirmation(m, ActionRisk.read), isFalse);
    }
    expect(ActionPolicy.requiresConfirmation(AutonomyMode.autopilot, ActionRisk.routine, inScope: false), isTrue);
  });

  test('plan refusé (hors périmètre) puis corrigé, risques classés', () async {
    final p = ScriptedProvider([
      (_) => call('describe_database', {'connection_id': conn.id}),
      (_) => call('submit_plan', {
            'summary': 'Mauvais plan',
            'steps': [step('Créer ailleurs', 'create_tables', {'connection_id': other.id, 'proposal': schema})],
          }, id: 'p1'),
      (m) {
        expect(m.last.toolResults.single.content, contains('hors du périmètre'));
        expect(m.last.toolResults.single.content, contains('Arguments attendus pour « create_tables »'));
        return call('submit_plan', {
          'summary': 'Créer la table clients, ajouter un client, nettoyer',
          'steps': [
            step('Créer la table', 'create_tables', {'connection_id': conn.id, 'proposal': schema}),
            step('Ajouter Ada', 'insert_row', {'connection_id': conn.id, 'table': 'clients', 'values': {'nom': 'Ada'}}),
            step('Supprimer les tests', 'execute_sql', {'connection_id': conn.id, 'sql': "DELETE FROM clients WHERE nom = 'test'"}),
            step('Vérifier', 'describe_database', {'connection_id': conn.id}),
          ],
        }, id: 'p2');
      },
      (_) => say('Plan prêt.'),
    ]);
    final plan = await engine(p).plan('Prépare une base clients');
    expect(plan.steps.map((s) => s.risk), [ActionRisk.schema, ActionRisk.routine, ActionRisk.destructive, ActionRisk.read]);
    expect(plan.steps.map((s) => s.needsConfirmation), [false, false, true, false]);
    expect(plan.summary, contains('clients'));
    expect(await tables(conn), isEmpty, reason: 'rien n\'est exécuté pendant la planification');
  });

  test('exécution : automatique, confirmation, contrôles, rapport, retour arrière', () async {
    final e = engine(ScriptedProvider([]));
    final plan = AutopilotPlan(goal: 'Base clients', summary: 's', steps: [
      PlanStep(title: 'Créer la table', tool: 'create_tables', args: {'connection_id': conn.id, 'proposal': schema}),
      PlanStep(title: 'Ajouter Ada', tool: 'insert_row', args: {'connection_id': conn.id, 'table': 'clients', 'values': {'nom': 'Ada'}}),
      PlanStep(title: 'Ajouter test', tool: 'insert_row', args: {'connection_id': conn.id, 'table': 'clients', 'values': {'nom': 'test'}}),
      PlanStep(title: 'Nettoyer', tool: 'execute_sql', args: {'connection_id': conn.id, 'sql': "DELETE FROM clients WHERE nom = 'test'"}),
      PlanStep(title: 'Index email', tool: 'create_index', args: {'connection_id': conn.id, 'table': 'clients', 'columns': ['email']}),
    ]);
    final run = state.autopilotRuns.create(projectId: project.id!, provider: AiProviderKind.ollama, model: 'fake', scope: [conn.id!], plan: plan);
    final confirmed = <String>[];
    await e.execute(run, confirm: (s) async {
      confirmed.add(s.title);
      return true;
    });
    expect(confirmed, ['Nettoyer'], reason: 'seule l\'étape destructive est soumise en mode AutoPilot');
    expect(run.status, RunStatus.succeeded, reason: run.report);
    expect(run.plan.steps.every((s) => s.status == StepStatus.succeeded), isTrue);
    expect(run.plan.steps.first.autoApproved, isTrue);
    expect(run.plan.steps.first.verified, contains('clients'));
    expect(run.plan.steps.last.verified, contains('idx_clients_email'));
    final db = await state.connectorFor(conn);
    expect((await db.select('SELECT nom FROM clients')).map((r) => r['nom']), ['Ada']);
    expect(run.checks.map((c) => c.label), containsAll(['Prérequis', 'Points de restauration', 'Intégrité et clés étrangères de « Clients »']));
    expect(run.checks.every((c) => c.ok), isTrue);
    expect(run.report, contains('## Résultat : Terminé'));
    expect(run.report, contains('(confirmée par vous)'));
    expect(state.journal.recent().any((j) => j.action == JournalAction.autopilotRun && j.success), isTrue);

    // Persistance puis retour arrière : la base revient à l'état d'avant.
    final reloaded = state.autopilotRuns.byId(run.id)!;
    expect(reloaded.rollback.sqliteBackups.keys, [conn.id]);
    final report = await AutopilotEngine.rollback(state, reloaded);
    expect(report.single, contains('restaurée'));
    expect(await tables(conn), isEmpty);
    expect(state.autopilotRuns.byId(run.id)!.status, RunStatus.rolledBack);
  });

  test('erreur récupérable corrigée ; correction plus risquée refusée', () async {
    final p = ScriptedProvider([
      // 1re correction : plus risquée (DROP) → refusée, puis correction valide.
      (_) => call('submit_fix', step('Tout effacer', 'execute_sql', {'connection_id': conn.id, 'sql': 'DROP TABLE clients'})),
      (m) {
        expect(m.last.toolResults.single.content, contains('plus risquée'));
        return call('submit_fix', step('Ajouter dans la bonne table', 'insert_row',
            {'connection_id': conn.id, 'table': 'clients', 'values': {'nom': 'Grace'}}), id: 'f2');
      },
      (_) => say('Corrigé.'),
    ]);
    await (await state.connectorFor(conn)).executeSql('CREATE TABLE clients(nom TEXT NOT NULL);');
    final plan = AutopilotPlan(goal: 'Ajouter Grace', summary: 's', steps: [
      PlanStep(title: 'Ajouter Grace', tool: 'insert_row', args: {'connection_id': conn.id, 'table': 'client', 'values': {'nom': 'Grace'}}),
    ]);
    final run = state.autopilotRuns.create(projectId: project.id!, provider: AiProviderKind.ollama, model: 'fake', scope: [conn.id!], plan: plan);
    await engine(p).execute(run, confirm: (_) async => true);
    expect(run.plan.steps.single.status, StepStatus.corrected, reason: run.report);
    expect(run.plan.steps.single.corrections.single, contains('Échec'));
    expect(run.status, RunStatus.succeeded);
    expect((await (await state.connectorFor(conn)).select('SELECT nom FROM clients')).single['nom'], 'Grace');
    expect(await tables(conn), contains('clients'), reason: 'le DROP n\'a jamais été exécuté');
  });

  test('étape destructive refusée : arrêt, étapes suivantes non exécutées', () async {
    await (await state.connectorFor(conn)).executeSql("CREATE TABLE t(a); INSERT INTO t VALUES (1);");
    final plan = AutopilotPlan(goal: 'g', summary: 's', steps: [
      PlanStep(title: 'Vider', tool: 'execute_sql', args: {'connection_id': conn.id, 'sql': 'DELETE FROM t'}),
      PlanStep(title: 'Après', tool: 'create_index', args: {'connection_id': conn.id, 'table': 't', 'columns': ['a']}),
    ]);
    final run = state.autopilotRuns.create(projectId: project.id!, provider: AiProviderKind.ollama, model: 'fake', scope: [conn.id!], plan: plan);
    await engine(ScriptedProvider([])).execute(run, confirm: (_) async => false);
    expect(run.plan.steps.map((s) => s.status), [StepStatus.refused, StepStatus.skipped]);
    expect(run.status, RunStatus.failed);
    expect((await (await state.connectorFor(conn)).select('SELECT COUNT(*) AS n FROM t')).single['n'], 1);
  });

  test('prérequis : étape hors périmètre bloquée avant toute modification', () async {
    final plan = AutopilotPlan(goal: 'g', summary: 's', steps: [
      PlanStep(title: 'Ailleurs', tool: 'create_tables', args: {'connection_id': other.id, 'proposal': schema}),
    ]);
    final run = state.autopilotRuns.create(projectId: project.id!, provider: AiProviderKind.ollama, model: 'fake', scope: [conn.id!], plan: plan);
    await engine(ScriptedProvider([])).execute(run, confirm: (_) async => true);
    expect(run.status, RunStatus.failed);
    expect(run.checks.first.ok, isFalse);
    expect(await tables(other), isEmpty);
    expect(run.rollback.isEmpty, isTrue);
  });

  test('planificateur qui oublie submit_plan : relancé puis plan obtenu', () async {
    final p = ScriptedProvider([
      (_) => call('describe_database', {'connection_id': conn.id}),
      (_) => say('Je propose de créer une table clients.'),
      (m) {
        expect(m.last.text, contains('submit_plan'));
        return call('submit_plan', {
          'summary': 'Créer clients',
          'steps': [step('Créer', 'create_tables', {'connection_id': conn.id, 'proposal': schema})],
        }, id: 'p9');
      },
      (_) => say('Fait.'),
    ]);
    final plan = await engine(p).plan('Crée une table clients');
    expect(plan.steps.single.tool, 'create_tables');
  });
}
