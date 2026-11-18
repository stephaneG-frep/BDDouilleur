import 'dart:convert';

import 'package:bddouilleur/data/ai/ai_providers.dart';
import 'package:bddouilleur/domain/ai/ai_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const tool = AiToolSpec(name: 'list_databases', description: 'Liste', parameters: {
  'type': 'object',
  'properties': {},
  'required': [],
  'additionalProperties': false,
});

final history = [
  AiMessage.user('Quelles bases ?'),
  const AiMessage(role: AiRole.assistant, text: 'Je regarde.', toolCalls: [
    AiToolCall(id: 'call_1', name: 'list_databases', arguments: {}),
  ]),
  const AiMessage(role: AiRole.tool, toolResults: [
    AiToolResult(callId: 'call_1', name: 'list_databases', content: '[{"id":1}]'),
  ]),
];

void main() {
  late List<http.Request> sent;
  setUp(() => sent = []);

  MockClient mock(Object Function(http.Request) respond, {int status = 200, Map<String, String> headers = const {}}) =>
      MockClient((req) async {
        sent.add(req);
        final body = respond(req);
        return http.Response(body is String ? body : jsonEncode(body), status, headers: headers);
      });

  group('Anthropic', () {
    test('en-têtes, outils, résultats d\'outils et repli serveur', () async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.anthropic, apiKey: 'sk-ant-SECRET'),
          client: mock((_) => {
                'content': [
                  {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
                  {'type': 'text', 'text': 'Je liste.'},
                  {'type': 'tool_use', 'id': 'toolu_2', 'name': 'list_databases', 'input': {}}
                ],
                'stop_reason': 'tool_use',
                'usage': {'input_tokens': 10, 'output_tokens': 5},
              }));
      final r = await p.chat(model: 'claude-opus-5-5', system: 'Système', messages: history, tools: [tool]);
      final req = sent.single;
      expect(req.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(req.headers['x-api-key'], 'sk-ant-SECRET');
      expect(req.headers['anthropic-version'], '2026-10-21');
      expect(req.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
      final body = jsonDecode(req.body) as Map;
      expect(body['fallbacks'], 'default');
      expect(body['system'], 'Système');
      expect(body.containsKey('temperature'), isFalse);
      expect((body['tools'] as List).single['input_schema'], isNotNull);
      final msgs = body['messages'] as List;
      expect(msgs.map((m) => m['role']), ['user', 'assistant', 'user']);
      expect((msgs[1]['content'] as List).last, {'type': 'tool_use', 'id': 'call_1', 'name': 'list_databases', 'input': {}});
      expect((msgs[2]['content'] as List).single['type'], 'tool_result');

      expect(r.stopReason, AiStopReason.toolUse);
      expect(r.message.text, 'Je liste.');
      expect(r.message.toolCalls.single.id, 'toolu_2');
      expect(r.inputTokens, 10);

      // Le contenu brut (dont le bloc thinking) est renvoyé tel quel au tour suivant.
      sent.clear();
      await p.chat(model: 'claude-opus-5-5', system: 'S', messages: [AiMessage.user('a'), r.message]);
      final replay = (jsonDecode(sent.single.body)['messages'] as List)[1]['content'] as List;
      expect(replay.first['type'], 'thinking');
      expect(replay.first['signature'], 'sig');
    });

    test('pas de repli serveur pour un modèle qui ne le gère pas', () async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.anthropic, apiKey: 'k'),
          client: mock((_) => {'content': [], 'stop_reason': 'end_turn'}));
      await p.chat(model: 'claude-haiku-4-5', system: 'S', messages: [AiMessage.user('a')]);
      expect(sent.single.headers.containsKey('anthropic-beta'), isFalse);
      expect((jsonDecode(sent.single.body) as Map).containsKey('fallbacks'), isFalse);
    });

    test('refus et liste des modèles', () async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.anthropic, apiKey: 'k'),
          client: mock((req) => req.url.path == '/v1/models'
              ? {
                  'data': [
                    {'id': 'claude-opus-5-5', 'display_name': 'Claude Opus 5.5'}
                  ]
                }
              : {'content': [], 'stop_reason': 'refusal'}));
      expect((await p.listModels()).single.label, 'Claude Opus 5.5 (claude-opus-5-5)');
      expect((await p.chat(model: 'm', system: 'S', messages: [AiMessage.user('a')])).stopReason, AiStopReason.refusal);
    });
  });

  group('OpenAI / Mistral', () {
    test('format chat completions avec appels d\'outils', () async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.openai, apiKey: 'sk-SECRET'),
          client: mock((_) => {
                'choices': [
                  {
                    'message': {
                      'content': null,
                      'tool_calls': [
                        {
                          'id': 'c9',
                          'type': 'function',
                          'function': {'name': 'list_databases', 'arguments': '{"x": 1}'}
                        }
                      ]
                    },
                    'finish_reason': 'tool_calls'
                  }
                ],
                'usage': {'prompt_tokens': 3, 'completion_tokens': 4},
              }));
      final r = await p.chat(model: 'gpt-x', system: 'S', messages: history, tools: [tool]);
      final body = jsonDecode(sent.single.body) as Map;
      expect(sent.single.headers['authorization'], 'Bearer sk-SECRET');
      final msgs = body['messages'] as List;
      expect(msgs.first, {'role': 'system', 'content': 'S'});
      expect(msgs[2]['tool_calls'][0]['function']['arguments'], '{}');
      expect(msgs[3], {'role': 'tool', 'tool_call_id': 'call_1', 'content': '[{"id":1}]'});
      expect(r.message.toolCalls.single.arguments, {'x': 1});
      expect(r.stopReason, AiStopReason.toolUse);
    });

    test('Mistral ajoute le nom de l\'outil et filtre les modèles sans outils', () async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.mistral, apiKey: 'k'),
          client: mock((req) => req.url.path == '/v1/models'
              ? {
                  'data': [
                    {'id': 'mistral-large-latest', 'capabilities': {'function_calling': true, 'completion_chat': true}},
                    {'id': 'mistral-embed', 'capabilities': {'function_calling': false}},
                  ]
                }
              : {
                  'choices': [
                    {'message': {'content': 'ok'}, 'finish_reason': 'stop'}
                  ]
                }));
      expect((await p.listModels()).map((m) => m.id), ['mistral-large-latest']);
      await p.chat(model: 'mistral-large-latest', system: 'S', messages: history);
      expect((jsonDecode(sent.last.body)['messages'] as List)[3]['name'], 'list_databases');
    });

    test('OpenAI : seuls les modèles de conversation sont proposés', () async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.openai, apiKey: 'k'),
          client: mock((_) => {
                'data': [
                  {'id': 'gpt-5'},
                  {'id': 'text-embedding-3-small'},
                  {'id': 'gpt-4o-audio-preview'},
                  {'id': 'o4-mini'},
                  {'id': 'dall-e-3'},
                ]
              }));
      expect((await p.listModels()).map((m) => m.id), ['o4-mini', 'gpt-5']);
    });
  });

  group('Gemini', () {
    test('clé dans l\'en-tête (jamais dans l\'URL), fonctions et réponses', () async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.gemini, apiKey: 'AIzaSECRET'),
          client: mock((_) => {
                'candidates': [
                  {
                    'content': {
                      'role': 'model',
                      'parts': [
                        {
                          'functionCall': {'name': 'list_databases', 'args': {}},
                          'thoughtSignature': 'abc'
                        }
                      ]
                    },
                    'finishReason': 'STOP'
                  }
                ],
                'usageMetadata': {'promptTokenCount': 7, 'candidatesTokenCount': 2},
              }));
      final r = await p.chat(model: 'gemini-x', system: 'S', messages: history, tools: [tool]);
      final req = sent.single;
      expect(req.url.toString(), isNot(contains('AIzaSECRET')));
      expect(req.headers['x-goog-api-key'], 'AIzaSECRET');
      final body = jsonDecode(req.body) as Map;
      final decl = (body['tools'] as List).single['functionDeclarations'][0] as Map;
      expect((decl['parameters'] as Map).containsKey('additionalProperties'), isFalse);
      final contents = body['contents'] as List;
      expect(contents[2]['parts'][0]['functionResponse']['name'], 'list_databases');
      expect(r.stopReason, AiStopReason.toolUse);
      // La signature de pensée est conservée pour le tour suivant.
      sent.clear();
      await p.chat(model: 'gemini-x', system: 'S', messages: [AiMessage.user('a'), r.message]);
      expect((jsonDecode(sent.single.body)['contents'] as List)[1]['parts'][0]['thoughtSignature'], 'abc');
    });
  });

  group('Ollama', () {
    test('API locale /api/chat sans clé', () async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.ollama),
          client: mock((req) => req.url.path == '/api/tags'
              ? {
                  'models': [
                    {'name': 'qwen3:1.7b'}
                  ]
                }
              : {
                  'message': {
                    'content': '',
                    'tool_calls': [
                      {
                        'function': {'name': 'list_databases', 'arguments': {}}
                      }
                    ]
                  },
                  'done_reason': 'stop',
                }));
      expect((await p.testConnection()).single.id, 'qwen3:1.7b');
      final r = await p.chat(model: 'qwen3:1.7b', system: 'S', messages: history, tools: [tool]);
      expect(sent.last.url.toString(), 'http://127.0.0.1:11434/api/chat');
      expect(sent.last.headers.containsKey('authorization'), isFalse);
      expect((jsonDecode(sent.last.body)['messages'] as List)[3]['tool_name'], 'list_databases');
      expect(r.message.toolCalls.single.name, 'list_databases');
    });
  });

  group('Erreurs', () {
    Future<AiException> errorFor(int status, Object body, {Map<String, String> headers = const {}}) async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.anthropic, apiKey: 'k'),
          client: mock((_) => body, status: status, headers: headers), retryDelays: const []);
      try {
        await p.chat(model: 'm', system: 'S', messages: [AiMessage.user('a')]);
      } on AiException catch (e) {
        return e;
      }
      fail('aucune erreur');
    }

    test('traduction en français', () async {
      expect((await errorFor(401, {'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}})).kind, AiErrorKind.auth);
      expect((await errorFor(429, {'error': {'type': 'rate_limit_error'}}, headers: {'retry-after': '12'})).retryAfter,
          const Duration(seconds: 12));
      expect((await errorFor(529, {'error': {'type': 'overloaded_error'}})).kind, AiErrorKind.overloaded);
      expect((await errorFor(402, {'error': {'type': 'billing_error'}})).kind, AiErrorKind.quota);
      expect((await errorFor(400, {'error': {'message': 'prompt is too long: context window exceeded'}})).kind,
          AiErrorKind.contextTooLong);
      final e = await errorFor(401, {'error': {'message': 'bad'}});
      expect(e.message, contains('Clé API refusée'));
      expect(e.toString(), isNot(contains('k\n')));
    });

    test('nouvelle tentative automatique sur surcharge', () async {
      var calls = 0;
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.anthropic, apiKey: 'k'),
          client: MockClient((_) async {
            calls++;
            return calls == 1
                ? http.Response('{"error":{"type":"overloaded_error"}}', 529)
                : http.Response('{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}', 200);
          }),
          retryDelays: const [Duration.zero]);
      final r = await p.chat(model: 'm', system: 'S', messages: [AiMessage.user('a')]);
      expect(r.message.text, 'ok');
      expect(calls, 2);
    });

    test('Ollama injoignable : message explicite', () async {
      final p = createProvider(const AiProviderConfig(kind: AiProviderKind.ollama),
          client: MockClient((_) async => throw http.ClientException('Connection refused')));
      await expectLater(p.listModels(),
          throwsA(isA<AiException>().having((e) => e.message, 'message', contains('ollama serve'))));
    });
  });
}
