import 'dart:convert';
import 'dart:io';

import 'package:bddouilleur/data/ai/agent.dart';
import 'package:bddouilleur/data/ai/ai_providers.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/domain/ai/ai_models.dart';
import 'package:bddouilleur/domain/models/journal_entry.dart';
import 'package:bddouilleur/domain/models/project.dart';
import 'package:bddouilleur/state/agent_tools.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Faux modèle : rejoue une suite de réponses et note ce qu'il reçoit.
class ScriptedProvider extends AiProvider {
  ScriptedProvider(this.script) : super(const AiProviderConfig(kind: AiProviderKind.ollama));
  final List<AiResponse Function(List<AiMessage> messages)> script;
  final List<List<AiMessage>> received = [];

  @override
  Map<String, String> get authHeaders => const {};

  @override
  Future<List<AiModelInfo>> listModels() async => const [AiModelInfo('fake')];

  @override
  Future<AiResponse> chat({required String model, required String system, required List<AiMessage> messages, List<AiToolSpec> tools = const []}) async {
    received.add([...messages]);
    return script[received.length - 1](messages);
  }
}

AiResponse call(String name, Map<String, Object?> args, {String id = 'c1', String text = ''}) => AiResponse(
      message: AiMessage(role: AiRole.assistant, text: text, toolCalls: [AiToolCall(id: id, name: name, arguments: args)]),
      stopReason: AiStopReason.toolUse,
    );

AiResponse say(String text) => AiResponse(message: AiMessage(role: AiRole.assistant, text: text), stopReason: AiStopReason.endTurn);

const proposal = {
  'summary': 'Boutique',
  'entities': [
    {
      'name': 'Category',
      'fields': [
        {'name': 'label', 'type': 'text', 'required': true}
      ]
    },
    {
      'name': 'Product',
      'fields': [
        {'name': 'name', 'type': 'text', 'required': true},
        {'name': 'categoryId', 'type': 'integer', 'references': 'Category', 'required': true},
      ]
    },
  ],
};

void main() {
  late Directory tmp;
  late AppState state;
  late Project project;
  late DbConnection conn;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bdd_agent_');
    final paths = AppPaths(tmp.path);
    state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
    project = state.createProject('Boutique', '');
    conn = await state.createSqliteDatabase(project, 'Catalogue');
  });

  tearDown(() {
    state.dispose();
    tmp.deleteSync(recursive: true);
  });

  Agent agentWith(ScriptedProvider provider, {String? folder}) {
    final box = AgentToolbox(AgentContext(state: state, project: project, connectionId: conn.id, folder: folder));
    return Agent(provider: provider, model: 'fake', tools: box.tools(), system: box.systemPrompt());
  }

  Future<List<String>> tables() async => (await state.connectorFor(conn)).listTables();

  test('action modifiante refusée : rien n\'est créé, le modèle en est informé', () async {
    final provider = ScriptedProvider([
      (_) => call('create_tables', {'proposal': proposal}),
      (_) => say('D\'accord, je n\'ai rien créé.'),
    ]);
    final asked = <String>[];
    final out = await agentWith(provider).runTurn([AiMessage.user('Crée les tables')], approve: (c, t) async {
      asked.add(t.describe(c.arguments));
      return false;
    });
    expect(asked.single, contains('categories, products'));
    expect(await tables(), isEmpty);
    final result = out.firstWhere((m) => m.role == AiRole.tool).toolResults.single;
    expect(result.isError, isTrue);
    expect(result.content, contains('REFUSÉ'));
    expect(provider.received.last.last.toolResults.single.content, contains('PAS été exécutée'));
  });

  test('action approuvée : tables réellement créées et journalisées', () async {
    final provider = ScriptedProvider([
      (_) => call('create_tables', {'proposal': proposal}),
      (m) {
        final r = jsonDecode(m.last.toolResults.single.content) as Map;
        return say('Créées : ${r['creees']}');
      },
    ]);
    final out = await agentWith(provider).runTurn([AiMessage.user('Crée les tables')], approve: (_, _) async => true);
    expect(await tables(), containsAll(['categories', 'products']));
    final fks = (await (await state.connectorFor(conn)).describeTable('products')).foreignKeys;
    expect(fks.single.table, 'categories');
    expect(out.last.text, 'Créées : [categories, products]');
    expect(state.journal.recent().where((e) => e.action == JournalAction.tableCreated).length, 2);
  });

  test('outils en lecture : exécutés sans demander, écriture refusée par query_sqlite', () async {
    final provider = ScriptedProvider([
      (_) => AiResponse(
            message: const AiMessage(role: AiRole.assistant, toolCalls: [
              AiToolCall(id: 'a', name: 'describe_database', arguments: {}),
              AiToolCall(id: 'b', name: 'query_sqlite', arguments: {'sql': 'DELETE FROM x'}),
              AiToolCall(id: 'c', name: 'query_sqlite', arguments: {'sql': 'SELECT 1 AS un'}),
              AiToolCall(id: 'd', name: 'outil_imaginaire', arguments: {}),
            ]),
            stopReason: AiStopReason.toolUse,
          ),
      (_) => say('Fini.'),
    ]);
    var asked = 0;
    final out = await agentWith(provider).runTurn([AiMessage.user('Regarde')], approve: (_, _) async {
      asked++;
      return true;
    });
    expect(asked, 0);
    final results = out.firstWhere((m) => m.role == AiRole.tool).toolResults;
    expect(results[0].isError, isFalse);
    expect(results[1].isError, isTrue);
    expect(results[1].content, contains('lecture'));
    expect(jsonDecode(results[2].content)['rows'], [
      [1]
    ]);
    expect(results[3].content, contains('Outil inconnu'));
    expect(AgentToolbox.isReadOnlySql('SELECT 1; DROP TABLE x'), isFalse);
    expect(AgentToolbox.isReadOnlySql('PRAGMA user_version = 3'), isFalse);
    expect(AgentToolbox.isReadOnlySql('WITH t AS (SELECT 1) INSERT INTO x SELECT * FROM t'), isFalse);
    expect(AgentToolbox.isReadOnlySql('PRAGMA table_info("x")'), isTrue);
  });

  test('SQL destructif approuvé : point de restauration créé avant', () async {
    await (await state.connectorFor(conn)).executeSql('CREATE TABLE t(a); INSERT INTO t VALUES (1);');
    final provider = ScriptedProvider([
      (_) => call('execute_sql', {'sql': 'DELETE FROM t'}),
      (_) => say('Supprimé.'),
    ]);
    String? described;
    await agentWith(provider).runTurn([AiMessage.user('Vide t')], approve: (c, t) async {
      described = t.describe(c.arguments);
      return true;
    });
    expect(described, startsWith('SQL DESTRUCTIF'));
    expect(state.backupsFor(conn).list(), hasLength(1));
    expect((await (await state.connectorFor(conn)).executeSql('SELECT COUNT(*) FROM t')).rows.single.single, 0);
  });

  test('dossier autorisé : sortie interdite, secrets jamais lus', () async {
    final folder = Directory('${tmp.path}/projet')..createSync();
    File('${folder.path}/lib.dart').writeAsStringSync('class A {}');
    File('${folder.path}/.env').writeAsStringSync('API_KEY=secret');
    File('${tmp.path}/dehors.txt').writeAsStringSync('privé');
    final provider = ScriptedProvider([
      (_) => AiResponse(
            message: const AiMessage(role: AiRole.assistant, toolCalls: [
              AiToolCall(id: '1', name: 'read_project_file', arguments: {'path': 'lib.dart'}),
              AiToolCall(id: '2', name: 'read_project_file', arguments: {'path': '../dehors.txt'}),
              AiToolCall(id: '3', name: 'read_project_file', arguments: {'path': '.env'}),
            ]),
            stopReason: AiStopReason.toolUse,
          ),
      (_) => say('ok'),
    ]);
    final out = await agentWith(provider, folder: folder.path).runTurn([AiMessage.user('Lis')], approve: (_, _) async => true);
    final r = out.firstWhere((m) => m.role == AiRole.tool).toolResults;
    expect(r[0].content, 'class A {}');
    expect(r[1].content, contains('sort du dossier'));
    expect(r[2].content, contains('secrets'));
    expect(r.map((x) => x.content).join(), isNot(contains('secret\n')));
    expect(r.map((x) => x.content).join(), isNot(contains('privé')));
  });

  test('boucle infinie : arrêt de sécurité', () async {
    final provider = ScriptedProvider(List.filled(20, (_) => call('list_databases', {})));
    final agent = agentWith(provider);
    final out = await Agent(provider: provider, model: 'fake', tools: agent.tools, system: 's', maxSteps: 3)
        .runTurn([AiMessage.user('x')], approve: (_, _) async => true);
    expect(provider.received.length, 3);
    expect(out.last.text, contains('Arrêt de sécurité'));
  });

  test('historique des conversations persistant, sans clé', () async {
    await state.ai.setApiKey(AiProviderKind.anthropic, 'sk-ant-SECRET');
    final c = state.aiConversations.create(projectId: project.id!, title: 'Essai', provider: AiProviderKind.anthropic, model: 'claude-opus-5-5');
    state.aiConversations.addMessage(c.id, AiMessage.user('Bonjour'), inputTokens: 3);
    state.aiConversations.addMessage(c.id, const AiMessage(role: AiRole.assistant, text: 'Salut'), outputTokens: 2);
    expect(state.aiConversations.messages(c.id).map((m) => m.text), ['Bonjour', 'Salut']);
    expect(state.aiConversations.usage(c.id), (3, 2));
    final dump = state.appDb.db.select('SELECT group_concat(content) AS c FROM ai_messages').first['c'];
    final settings = state.appDb.db.select('SELECT group_concat(value) AS v FROM settings').first['v'];
    expect('$dump$settings', isNot(contains('SECRET')));
    expect(await state.ai.apiKey(AiProviderKind.anthropic), 'sk-ant-SECRET');
  });
}
