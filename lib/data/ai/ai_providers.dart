import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../domain/ai/ai_models.dart';

/// Configuration d'un fournisseur. La clé n'est jamais journalisée.
class AiProviderConfig {
  const AiProviderConfig({required this.kind, this.apiKey, String? baseUrl})
      : baseUrl = baseUrl ?? '';
  final AiProviderKind kind;
  final String? apiKey;
  final String baseUrl;

  String get base => (baseUrl.isEmpty ? kind.defaultBaseUrl : baseUrl).replaceAll(RegExp(r'/+$'), '');
}

/// Adaptateur vers l'API d'un fournisseur.
abstract class AiProvider {
  AiProvider(this.config, {http.Client? client, this.retryDelays = const [Duration(seconds: 2), Duration(seconds: 6)]})
      : client = client ?? http.Client();

  final AiProviderConfig config;
  final http.Client client;

  /// Délais entre nouvelles tentatives (surcharge, limite de débit).
  final List<Duration> retryDelays;

  AiProviderKind get kind => config.kind;

  Future<List<AiModelInfo>> listModels();

  Future<AiResponse> chat({
    required String model,
    required String system,
    required List<AiMessage> messages,
    List<AiToolSpec> tools = const [],
  });

  /// Test de connexion réel : la liste des modèles doit être lisible.
  Future<List<AiModelInfo>> testConnection() async {
    final models = await listModels();
    if (models.isEmpty) {
      throw AiException(AiErrorKind.notFound, kind, detail: 'Aucun modèle disponible avec cette configuration.');
    }
    return models;
  }

  Map<String, String> get authHeaders;

  /// Envoie une requête JSON et traduit les erreurs. Réessaie sur surcharge
  /// ou limite de débit (au plus [retryDelays].length fois).
  Future<Map<String, dynamic>> sendJson(String method, String url,
      {Object? body, Map<String, String> extraHeaders = const {}}) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _sendOnce(method, url, body: body, extraHeaders: extraHeaders);
      } on AiException catch (e) {
        final wait = e.retryAfter ?? (attempt < retryDelays.length ? retryDelays[attempt] : null);
        final canRetry = (e.kind == AiErrorKind.overloaded || e.kind == AiErrorKind.rateLimit) &&
            attempt < retryDelays.length &&
            wait != null &&
            wait <= const Duration(seconds: 30);
        if (!canRetry) rethrow;
        await Future<void>.delayed(wait);
      }
    }
  }

  Future<Map<String, dynamic>> _sendOnce(String method, String url,
      {Object? body, Map<String, String> extraHeaders = const {}}) async {
    final req = http.Request(method, Uri.parse(url));
    req.headers.addAll(authHeaders);
    req.headers.addAll(extraHeaders);
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await client.send(req)).timeout(const Duration(minutes: 10));
    } on TimeoutException {
      throw AiException(AiErrorKind.network, kind, detail: 'Délai de réponse dépassé');
    } on SocketException catch (e) {
      throw AiException(AiErrorKind.network, kind, detail: e.message);
    } on http.ClientException catch (e) {
      throw AiException(AiErrorKind.network, kind, detail: e.message);
    }
    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (text.trim().isEmpty) return {};
      final json = jsonDecode(text);
      return json is Map<String, dynamic> ? json : {'value': json};
    }
    throw mapError(res.statusCode, text, res.headers['retry-after']);
  }

  AiException mapError(int status, String body, String? retryAfter) {
    String detail = body.length > 400 ? '${body.substring(0, 400)}…' : body;
    String type = '';
    try {
      final j = jsonDecode(body);
      final err = j is Map ? j['error'] : null;
      if (err is Map) {
        detail = '${err['message'] ?? detail}';
        type = '${err['type'] ?? err['code'] ?? err['status'] ?? ''}';
      } else if (err is String) {
        detail = err;
      } else if (j is Map && j['message'] is String) {
        detail = j['message'] as String;
      }
    } catch (_) {}
    final lower = '$type $detail'.toLowerCase();
    final wait = int.tryParse(retryAfter ?? '');
    final kindOf = switch (status) {
      401 => AiErrorKind.auth,
      402 => AiErrorKind.quota,
      403 => AiErrorKind.permission,
      404 => AiErrorKind.notFound,
      413 => AiErrorKind.contextTooLong,
      429 => lower.contains('quota') || lower.contains('billing') ? AiErrorKind.quota : AiErrorKind.rateLimit,
      529 || 503 => AiErrorKind.overloaded,
      >= 500 => AiErrorKind.server,
      _ => lower.contains('context') && (lower.contains('length') || lower.contains('too long') || lower.contains('window'))
          ? AiErrorKind.contextTooLong
          : lower.contains('api key') || lower.contains('api_key')
              ? AiErrorKind.auth
              : AiErrorKind.badRequest,
    };
    return AiException(kindOf, kind, detail: detail, retryAfter: wait == null ? null : Duration(seconds: wait));
  }

  static Map<String, Object?> decodeArgs(Object? raw) {
    if (raw is Map) return raw.cast<String, Object?>();
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final v = jsonDecode(raw);
        if (v is Map) return v.cast<String, Object?>();
      } catch (_) {}
      return {'_arguments_invalides': raw};
    }
    return {};
  }

  /// Contenu brut réutilisable seulement par le fournisseur qui l'a produit.
  Object? rawFor(AiMessage m) {
    final r = m.raw;
    if (r is Map && r['provider'] == kind.name) return r['content'];
    return null;
  }

  Map<String, Object?> wrapRaw(Object? content) => {'provider': kind.name, 'content': content};
}

AiProvider createProvider(AiProviderConfig config, {http.Client? client, List<Duration>? retryDelays}) {
  final delays = retryDelays ?? const [Duration(seconds: 2), Duration(seconds: 6)];
  return switch (config.kind) {
    AiProviderKind.anthropic => AnthropicProvider(config, client: client, retryDelays: delays),
    AiProviderKind.openai || AiProviderKind.mistral => OpenAiCompatibleProvider(config, client: client, retryDelays: delays),
    AiProviderKind.gemini => GeminiProvider(config, client: client, retryDelays: delays),
    AiProviderKind.ollama => OllamaProvider(config, client: client, retryDelays: delays),
  };
}

// ============================================================ Anthropic

/// API Messages d'Anthropic (REST direct : pas de SDK officiel pour Dart).
class AnthropicProvider extends AiProvider {
  AnthropicProvider(super.config, {super.client, super.retryDelays});

  static const apiVersion = '2026-10-21';

  /// Modèles acceptant le repli serveur automatique en cas de refus.
  static const fallbackModels = {'claude-fable-5-2', 'claude-fable-5-1', 'claude-opus-5-5', 'claude-opus-5', 'claude-sonnet-5-5'};

  @override
  Map<String, String> get authHeaders => {'x-api-key': config.apiKey ?? '', 'anthropic-version': apiVersion};

  @override
  Future<List<AiModelInfo>> listModels() async {
    final r = await sendJson('GET', '${config.base}/v1/models?limit=100');
    return [
      for (final m in (r['data'] as List?) ?? const [])
        AiModelInfo((m as Map)['id'] as String, m['display_name'] as String?),
    ];
  }

  List<Map<String, Object?>> buildMessages(List<AiMessage> messages) {
    final out = <Map<String, Object?>>[];
    void add(String role, List<Object?> blocks) {
      if (blocks.isEmpty) return;
      if (out.isNotEmpty && out.last['role'] == role) {
        (out.last['content'] as List).addAll(blocks);
      } else {
        out.add({'role': role, 'content': [...blocks]});
      }
    }

    for (final m in messages) {
      switch (m.role) {
        case AiRole.user:
          add('user', [if (m.text.trim().isNotEmpty) {'type': 'text', 'text': m.text}]);
        case AiRole.assistant:
          final raw = rawFor(m);
          if (raw is List) {
            add('assistant', [...raw]);
          } else {
            add('assistant', [
              if (m.text.trim().isNotEmpty) {'type': 'text', 'text': m.text},
              for (final c in m.toolCalls) {'type': 'tool_use', 'id': c.id, 'name': c.name, 'input': c.arguments},
            ]);
          }
        case AiRole.tool:
          add('user', [
            for (final r in m.toolResults)
              {'type': 'tool_result', 'tool_use_id': r.callId, 'content': r.content, if (r.isError) 'is_error': true},
          ]);
      }
    }
    return out;
  }

  @override
  Future<AiResponse> chat({
    required String model,
    required String system,
    required List<AiMessage> messages,
    List<AiToolSpec> tools = const [],
  }) async {
    final fallback = fallbackModels.contains(model);
    final body = <String, Object?>{
      'model': model,
      'max_tokens': 16000,
      'system': system,
      'messages': buildMessages(messages),
      if (tools.isNotEmpty)
        'tools': [
          for (final t in tools) {'name': t.name, 'description': t.description, 'input_schema': t.parameters}
        ],
      if (fallback) 'fallbacks': 'default',
    };
    final r = await sendJson('POST', '${config.base}/v1/messages',
        body: body, extraHeaders: fallback ? const {'anthropic-beta': 'server-side-fallback-2026-07-01'} : const {});
    final content = (r['content'] as List?) ?? const [];
    final text = StringBuffer();
    final calls = <AiToolCall>[];
    for (final b in content) {
      final block = b as Map;
      if (block['type'] == 'text') text.write(block['text']);
      if (block['type'] == 'tool_use') {
        calls.add(AiToolCall(
            id: block['id'] as String, name: block['name'] as String, arguments: AiProvider.decodeArgs(block['input'])));
      }
    }
    final usage = (r['usage'] as Map?) ?? const {};
    return AiResponse(
      message: AiMessage(role: AiRole.assistant, text: text.toString(), toolCalls: calls, raw: wrapRaw(content)),
      stopReason: switch (r['stop_reason']) {
        'end_turn' || 'stop_sequence' => AiStopReason.endTurn,
        'tool_use' => AiStopReason.toolUse,
        'max_tokens' => AiStopReason.maxTokens,
        'refusal' => AiStopReason.refusal,
        _ => calls.isNotEmpty ? AiStopReason.toolUse : AiStopReason.other,
      },
      inputTokens: (usage['input_tokens'] as num?)?.toInt(),
      outputTokens: (usage['output_tokens'] as num?)?.toInt(),
    );
  }
}

// ===================================================== OpenAI / Mistral

/// API « chat completions » d'OpenAI, également utilisée par Mistral.
class OpenAiCompatibleProvider extends AiProvider {
  OpenAiCompatibleProvider(super.config, {super.client, super.retryDelays});

  bool get _mistral => kind == AiProviderKind.mistral;

  @override
  Map<String, String> get authHeaders => {'authorization': 'Bearer ${config.apiKey ?? ''}'};

  static final _openAiChat = RegExp(r'^(gpt-|o\d|chatgpt-)');
  static final _excluded = RegExp(r'audio|realtime|transcribe|tts|image|embed|search|moderation|whisper|dall-e|ocr|codestral-embed');

  @override
  Future<List<AiModelInfo>> listModels() async {
    final r = await sendJson('GET', '${config.base}/v1/models');
    final out = <AiModelInfo>[];
    for (final m in (r['data'] as List?) ?? const []) {
      final id = (m as Map)['id'] as String;
      if (_excluded.hasMatch(id)) continue;
      if (_mistral) {
        final caps = m['capabilities'];
        if (caps is Map && caps['function_calling'] == false) continue;
        if (caps is Map && caps['completion_chat'] == false) continue;
      } else if (!_openAiChat.hasMatch(id)) {
        continue;
      }
      out.add(AiModelInfo(id, m['name'] as String?));
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  List<Map<String, Object?>> buildMessages(String system, List<AiMessage> messages) => [
        {'role': 'system', 'content': system},
        for (final m in messages)
          ...switch (m.role) {
            AiRole.user => [
                {'role': 'user', 'content': m.text}
              ],
            AiRole.assistant => [
                {
                  'role': 'assistant',
                  'content': m.text.isEmpty ? null : m.text,
                  if (m.toolCalls.isNotEmpty)
                    'tool_calls': [
                      for (final c in m.toolCalls)
                        {
                          'id': c.id,
                          'type': 'function',
                          'function': {'name': c.name, 'arguments': jsonEncode(c.arguments)}
                        }
                    ],
                }
              ],
            AiRole.tool => [
                for (final r in m.toolResults)
                  {'role': 'tool', 'tool_call_id': r.callId, 'content': r.content, if (_mistral) 'name': r.name}
              ],
          },
      ];

  @override
  Future<AiResponse> chat({
    required String model,
    required String system,
    required List<AiMessage> messages,
    List<AiToolSpec> tools = const [],
  }) async {
    final r = await sendJson('POST', '${config.base}/v1/chat/completions', body: {
      'model': model,
      'messages': buildMessages(system, messages),
      if (tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'type': 'function',
              'function': {'name': t.name, 'description': t.description, 'parameters': t.parameters}
            }
        ],
    });
    final choice = (((r['choices'] as List?) ?? const []).firstOrNull as Map?) ?? const {};
    final msg = (choice['message'] as Map?) ?? const {};
    final calls = [
      for (final c in (msg['tool_calls'] as List?) ?? const [])
        AiToolCall(
          id: (c as Map)['id'] as String,
          name: (c['function'] as Map)['name'] as String,
          arguments: AiProvider.decodeArgs((c['function'] as Map)['arguments']),
        ),
    ];
    final usage = (r['usage'] as Map?) ?? const {};
    return AiResponse(
      message: AiMessage(role: AiRole.assistant, text: (msg['content'] as String?) ?? '', toolCalls: calls),
      stopReason: switch (choice['finish_reason']) {
        'stop' => calls.isNotEmpty ? AiStopReason.toolUse : AiStopReason.endTurn,
        'tool_calls' => AiStopReason.toolUse,
        'length' || 'model_length' => AiStopReason.maxTokens,
        'content_filter' => AiStopReason.refusal,
        _ => calls.isNotEmpty ? AiStopReason.toolUse : AiStopReason.other,
      },
      inputTokens: (usage['prompt_tokens'] as num?)?.toInt(),
      outputTokens: (usage['completion_tokens'] as num?)?.toInt(),
    );
  }
}

// ============================================================== Gemini

class GeminiProvider extends AiProvider {
  GeminiProvider(super.config, {super.client, super.retryDelays});

  /// Clé dans un en-tête (jamais dans l'URL, donc jamais dans un journal).
  @override
  Map<String, String> get authHeaders => {'x-goog-api-key': config.apiKey ?? ''};

  @override
  Future<List<AiModelInfo>> listModels() async {
    final r = await sendJson('GET', '${config.base}/v1beta/models?pageSize=1000');
    final out = <AiModelInfo>[];
    for (final m in (r['models'] as List?) ?? const []) {
      final methods = ((m as Map)['supportedGenerationMethods'] as List?) ?? const [];
      final id = (m['name'] as String).replaceFirst('models/', '');
      if (!methods.contains('generateContent') || id.contains('embedding') || id.contains('image')) continue;
      out.add(AiModelInfo(id, m['displayName'] as String?));
    }
    return out;
  }

  /// Gemini n'accepte qu'un sous-ensemble d'OpenAPI : pas de additionalProperties.
  static Object? cleanSchema(Object? s) {
    if (s is Map) {
      return {
        for (final e in s.entries)
          if (e.key != 'additionalProperties' && e.key != r'$schema') e.key as String: cleanSchema(e.value)
      };
    }
    if (s is List) return [for (final x in s) cleanSchema(x)];
    return s;
  }

  List<Map<String, Object?>> buildContents(List<AiMessage> messages) {
    final out = <Map<String, Object?>>[];
    for (final m in messages) {
      switch (m.role) {
        case AiRole.user:
          out.add({
            'role': 'user',
            'parts': [
              {'text': m.text}
            ]
          });
        case AiRole.assistant:
          final raw = rawFor(m);
          out.add({
            'role': 'model',
            'parts': raw is List
                ? raw
                : [
                    if (m.text.isNotEmpty) {'text': m.text},
                    for (final c in m.toolCalls)
                      {
                        'functionCall': {'name': c.name, 'args': c.arguments}
                      },
                  ],
          });
        case AiRole.tool:
          out.add({
            'role': 'user',
            'parts': [
              for (final r in m.toolResults)
                {
                  'functionResponse': {
                    'name': r.name,
                    'response': {r.isError ? 'error' : 'result': r.content}
                  }
                }
            ],
          });
      }
    }
    return out;
  }

  @override
  Future<AiResponse> chat({
    required String model,
    required String system,
    required List<AiMessage> messages,
    List<AiToolSpec> tools = const [],
  }) async {
    final r = await sendJson('POST', '${config.base}/v1beta/models/${Uri.encodeComponent(model)}:generateContent', body: {
      'systemInstruction': {
        'parts': [
          {'text': system}
        ]
      },
      'contents': buildContents(messages),
      if (tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final t in tools) {'name': t.name, 'description': t.description, 'parameters': cleanSchema(t.parameters)}
            ]
          }
        ],
    });
    final cands = (r['candidates'] as List?) ?? const [];
    if (cands.isEmpty) {
      final block = (r['promptFeedback'] as Map?)?['blockReason'];
      return AiResponse(
        message: const AiMessage(role: AiRole.assistant),
        stopReason: block != null ? AiStopReason.refusal : AiStopReason.other,
      );
    }
    final cand = cands.first as Map;
    final parts = ((cand['content'] as Map?)?['parts'] as List?) ?? const [];
    final text = StringBuffer();
    final calls = <AiToolCall>[];
    for (final (i, p) in parts.indexed) {
      final part = p as Map;
      if (part['text'] is String && part['thought'] != true) text.write(part['text']);
      final fc = part['functionCall'];
      if (fc is Map) {
        calls.add(AiToolCall(
            id: (fc['id'] as String?) ?? 'gemini-$i', name: fc['name'] as String, arguments: AiProvider.decodeArgs(fc['args'])));
      }
    }
    final usage = (r['usageMetadata'] as Map?) ?? const {};
    return AiResponse(
      message: AiMessage(role: AiRole.assistant, text: text.toString(), toolCalls: calls, raw: wrapRaw(parts)),
      stopReason: calls.isNotEmpty
          ? AiStopReason.toolUse
          : switch (cand['finishReason']) {
              'STOP' => AiStopReason.endTurn,
              'MAX_TOKENS' => AiStopReason.maxTokens,
              'SAFETY' || 'PROHIBITED_CONTENT' || 'BLOCKLIST' || 'RECITATION' => AiStopReason.refusal,
              _ => AiStopReason.other,
            },
      inputTokens: (usage['promptTokenCount'] as num?)?.toInt(),
      outputTokens: (usage['candidatesTokenCount'] as num?)?.toInt(),
    );
  }
}

// ============================================================== Ollama

class OllamaProvider extends AiProvider {
  OllamaProvider(super.config, {super.client, super.retryDelays});

  @override
  Map<String, String> get authHeaders => const {};

  @override
  Future<List<AiModelInfo>> listModels() async {
    final r = await sendJson('GET', '${config.base}/api/tags');
    return [for (final m in (r['models'] as List?) ?? const []) AiModelInfo((m as Map)['name'] as String)];
  }

  @override
  Future<AiResponse> chat({
    required String model,
    required String system,
    required List<AiMessage> messages,
    List<AiToolSpec> tools = const [],
  }) async {
    final r = await sendJson('POST', '${config.base}/api/chat', body: {
      'model': model,
      'stream': false,
      'messages': [
        {'role': 'system', 'content': system},
        for (final m in messages)
          ...switch (m.role) {
            AiRole.user => [
                {'role': 'user', 'content': m.text}
              ],
            AiRole.assistant => [
                {
                  'role': 'assistant',
                  'content': m.text,
                  if (m.toolCalls.isNotEmpty)
                    'tool_calls': [
                      for (final c in m.toolCalls)
                        {
                          'function': {'name': c.name, 'arguments': c.arguments}
                        }
                    ],
                }
              ],
            AiRole.tool => [
                for (final t in m.toolResults) {'role': 'tool', 'content': t.content, 'tool_name': t.name}
              ],
          },
      ],
      if (tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'type': 'function',
              'function': {'name': t.name, 'description': t.description, 'parameters': t.parameters}
            }
        ],
    });
    final msg = (r['message'] as Map?) ?? const {};
    final calls = [
      for (final (i, c) in ((msg['tool_calls'] as List?) ?? const []).indexed)
        AiToolCall(
          id: 'ollama-$i-${DateTime.now().microsecondsSinceEpoch}',
          name: ((c as Map)['function'] as Map)['name'] as String,
          arguments: AiProvider.decodeArgs((c['function'] as Map)['arguments']),
        ),
    ];
    return AiResponse(
      message: AiMessage(role: AiRole.assistant, text: (msg['content'] as String?) ?? '', toolCalls: calls),
      stopReason: calls.isNotEmpty
          ? AiStopReason.toolUse
          : (r['done_reason'] == 'length' ? AiStopReason.maxTokens : AiStopReason.endTurn),
      inputTokens: (r['prompt_eval_count'] as num?)?.toInt(),
      outputTokens: (r['eval_count'] as num?)?.toInt(),
    );
  }
}
