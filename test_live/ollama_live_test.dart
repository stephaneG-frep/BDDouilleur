// Test RÉEL de l'agent avec Ollama en local (aucun coût).
//   ollama serve & ; ollama pull qwen3:1.7b
//   flutter test test_live/ollama_live_test.dart --dart-define=OLLAMA_MODEL=qwen3:1.7b
import 'dart:io';

import 'package:bddouilleur/data/ai/agent.dart';
import 'package:bddouilleur/data/ai/ai_providers.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/domain/ai/ai_models.dart';
import 'package:bddouilleur/state/agent_tools.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

const model = String.fromEnvironment('OLLAMA_MODEL', defaultValue: 'qwen3:1.7b');

void main() {
  test('agent réel (Ollama) : lecture, puis création de table après accord', () async {
    final tmp = Directory.systemTemp.createTempSync('bdd_live_');
    final paths = AppPaths(tmp.path);
    final state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
    final project = state.createProject('Boutique', 'Vente de matériel de laboratoire');
    final conn = await state.createSqliteDatabase(project, 'Catalogue');

    final provider = createProvider(const AiProviderConfig(kind: AiProviderKind.ollama));
    final models = await provider.testConnection();
    expect(models.map((m) => m.id), contains(model));

    final box = AgentToolbox(AgentContext(state: state, project: project, connectionId: conn.id));
    final agent = Agent(provider: provider, model: model, tools: box.tools(), system: box.systemPrompt());

    void show(AiMessage m) {
      // ignore: avoid_print
      print('[${m.role.name}] ${m.text.trim()}'
          '${m.toolCalls.map((c) => '\n  → ${c.name} ${c.arguments}').join()}'
          '${m.toolResults.map((r) => '\n  ← ${r.name} ${r.isError ? 'ERREUR ' : ''}${r.content.length > 160 ? '${r.content.substring(0, 160)}…' : r.content}').join()}');
    }

    // 1. Lecture seule.
    final history = <AiMessage>[AiMessage.user('Quelles bases de données contient ce projet ? Utilise l\'outil adapté.')];
    final t1 = await agent.runTurn(history, approve: (_, _) async => false, onMessage: show);
    history.addAll(t1);
    final calls1 = t1.expand((m) => m.toolCalls).map((c) => c.name).toList();
    expect(calls1, anyOf(contains('list_databases'), contains('describe_database')));
    expect(t1.expand((m) => m.toolResults).every((r) => !r.isError), isTrue);

    // 2. Modification : l'accord est demandé, puis la table est réellement créée.
    var asked = 0;
    history.add(AiMessage.user('Crée dans la base Catalogue une table pour des produits avec un nom (texte, requis) '
        'et un prix (réel). Utilise create_tables.'));
    final t2 = await agent.runTurn(history, approve: (c, t) async {
      asked++;
      // ignore: avoid_print
      print('  ? accord demandé : ${t.describe(c.arguments)}');
      return true;
    }, onMessage: show);
    final tables = await (await state.connectorFor(conn)).listTables();
    // ignore: avoid_print
    print('Tables réelles : $tables • accords demandés : $asked');
    expect(asked, greaterThanOrEqualTo(1));
    expect(tables, isNotEmpty);
    expect(t2.last.role, AiRole.assistant);
    state.dispose();
    tmp.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
