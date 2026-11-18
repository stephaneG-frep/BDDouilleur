// Essai RÉEL d'AutoPilot avec Ollama en local (aucun coût).
//   flutter test test_live/autopilot_live_test.dart --dart-define=OLLAMA_MODEL=qwen3:1.7b
import 'dart:io';

import 'package:bddouilleur/data/ai/ai_providers.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/domain/ai/ai_models.dart';
import 'package:bddouilleur/domain/autopilot/autopilot_plan.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:bddouilleur/state/autopilot_engine.dart';
import 'package:flutter_test/flutter_test.dart';

const model = String.fromEnvironment('OLLAMA_MODEL', defaultValue: 'qwen3:1.7b');

void main() {
  test('AutoPilot réel : plan, exécution contrôlée, rapport, retour arrière', () async {
    final tmp = Directory.systemTemp.createTempSync('bdd_ap_live_');
    final paths = AppPaths(tmp.path);
    final state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
    final project = state.createProject('Cabinet', 'Prise de rendez-vous');
    final conn = await state.createSqliteDatabase(project, 'Cabinet');
    await (await state.connectorFor(conn)).executeSql(
        "CREATE TABLE clients(id INTEGER PRIMARY KEY AUTOINCREMENT, nom TEXT NOT NULL); INSERT INTO clients(nom) VALUES ('Ada');");

    final engine = AutopilotEngine(
      state: state,
      project: project,
      provider: createProvider(const AiProviderConfig(kind: AiProviderKind.ollama)),
      model: model,
      scope: {conn.id!},
    );
    final plan = await engine.plan(
      'Dans la base #${conn.id}, crée une table de rendez-vous avec une date et un motif, liée à la table clients existante '
      '(champ clientId qui référence l\'entité Client), puis ajoute un index sur la date.',
      onMessage: (m) {
        // ignore: avoid_print
        print('[${m.role.name}] ${m.text.trim()}${m.toolCalls.map((c) => '\n  → ${c.name} ${c.arguments}').join()}'
            '${m.toolResults.map((r) => '\n  ← ${r.isError ? 'ERREUR ' : ''}${r.content.length > 300 ? r.content.substring(0, 300) : r.content}').join()}');
      },
    );
    // ignore: avoid_print
    print('PLAN : ${plan.steps.map((s) => '${s.title} [${s.tool}, ${s.risk.label}${s.needsConfirmation ? ', confirmation' : ''}]').join(' | ')}');
    final run = state.autopilotRuns.create(projectId: project.id!, provider: AiProviderKind.ollama, model: model, scope: [conn.id!], plan: plan);
    await engine.execute(run, confirm: (s) async {
      // ignore: avoid_print
      print('  ? confirmation demandée : ${s.title}');
      return true;
    });
    // ignore: avoid_print
    print(run.report);
    final tables = await (await state.connectorFor(conn)).listTables();
    // ignore: avoid_print
    print('Tables réelles : $tables');
    expect(run.status, RunStatus.succeeded);
    expect(run.checks.every((c) => c.ok), isTrue);
    await AutopilotEngine.rollback(state, run);
    expect(await (await state.connectorFor(conn)).listTables(), ['clients']);
    state.dispose();
    tmp.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 25)));
}
