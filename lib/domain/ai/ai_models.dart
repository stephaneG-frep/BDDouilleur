/// Modèle commun aux fournisseurs d'IA (format neutre, converti par chaque
/// adaptateur vers l'API du fournisseur).
library;

enum AiProviderKind {
  anthropic('Anthropic Claude', true, 'https://api.anthropic.com', 'claude-opus-5-5',
      'https://console.anthropic.com/settings/keys'),
  openai('OpenAI', true, 'https://api.openai.com', '', 'https://platform.openai.com/api-keys'),
  gemini('Google Gemini', true, 'https://generativelanguage.googleapis.com', '', 'https://aistudio.google.com/apikey'),
  mistral('Mistral', true, 'https://api.mistral.ai', '', 'https://console.mistral.ai/api-keys'),
  ollama('Ollama (local)', false, 'http://127.0.0.1:11434', '', 'https://ollama.com/download');

  const AiProviderKind(this.label, this.needsKey, this.defaultBaseUrl, this.suggestedModel, this.keyHelpUrl);
  final String label;
  final bool needsKey;
  final String defaultBaseUrl;

  /// Modèle proposé par défaut ('' : premier modèle renvoyé par le fournisseur).
  final String suggestedModel;
  final String keyHelpUrl;

  static AiProviderKind? fromName(String? n) => AiProviderKind.values.where((k) => k.name == n).firstOrNull;
}

enum AiRole { user, assistant, tool }

class AiToolCall {
  const AiToolCall({required this.id, required this.name, required this.arguments});
  final String id;
  final String name;
  final Map<String, Object?> arguments;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'arguments': arguments};
  factory AiToolCall.fromJson(Map<String, Object?> j) => AiToolCall(
        id: j['id'] as String,
        name: j['name'] as String,
        arguments: ((j['arguments'] as Map?) ?? const {}).cast<String, Object?>(),
      );
}

class AiToolResult {
  const AiToolResult({required this.callId, required this.name, required this.content, this.isError = false});
  final String callId;
  final String name;

  /// Résultat RÉEL de l'exécution (texte ou JSON sérialisé).
  final String content;
  final bool isError;

  Map<String, Object?> toJson() => {'callId': callId, 'name': name, 'content': content, 'isError': isError};
  factory AiToolResult.fromJson(Map<String, Object?> j) => AiToolResult(
        callId: j['callId'] as String,
        name: j['name'] as String,
        content: j['content'] as String,
        isError: j['isError'] == true,
      );
}

class AiMessage {
  const AiMessage({
    required this.role,
    this.text = '',
    this.toolCalls = const [],
    this.toolResults = const [],
    this.raw,
    this.source,
  });

  final AiRole role;
  final String text;
  final List<AiToolCall> toolCalls;
  final List<AiToolResult> toolResults;

  /// Contenu brut renvoyé par le fournisseur (ex. blocs « thinking »
  /// d'Anthropic), réutilisé tel quel au tour suivant avec le même fournisseur.
  final Object? raw;

  /// Fournisseur et modèle qui ont produit ce message (affichage).
  final String? source;

  AiMessage withSource(String s) =>
      AiMessage(role: role, text: text, toolCalls: toolCalls, toolResults: toolResults, raw: raw, source: s);

  factory AiMessage.user(String text) => AiMessage(role: AiRole.user, text: text);

  Map<String, Object?> toJson() => {
        'role': role.name,
        'text': text,
        if (toolCalls.isNotEmpty) 'toolCalls': [for (final c in toolCalls) c.toJson()],
        if (toolResults.isNotEmpty) 'toolResults': [for (final r in toolResults) r.toJson()],
        'raw': ?raw,
        'source': ?source,
      };

  factory AiMessage.fromJson(Map<String, Object?> j) => AiMessage(
        role: AiRole.values.byName(j['role'] as String),
        text: (j['text'] as String?) ?? '',
        toolCalls: [for (final c in (j['toolCalls'] as List?) ?? const []) AiToolCall.fromJson((c as Map).cast())],
        toolResults: [
          for (final r in (j['toolResults'] as List?) ?? const []) AiToolResult.fromJson((r as Map).cast())
        ],
        raw: j['raw'],
        source: j['source'] as String?,
      );
}

/// Déclaration d'un outil proposé au modèle (schéma JSON des paramètres).
class AiToolSpec {
  const AiToolSpec({required this.name, required this.description, required this.parameters});
  final String name;
  final String description;
  final Map<String, Object?> parameters;
}

enum AiStopReason { endTurn, toolUse, maxTokens, refusal, other }

class AiResponse {
  const AiResponse({required this.message, required this.stopReason, this.inputTokens, this.outputTokens});
  final AiMessage message;
  final AiStopReason stopReason;
  final int? inputTokens;
  final int? outputTokens;
}

class AiModelInfo {
  const AiModelInfo(this.id, [this.displayName]);
  final String id;
  final String? displayName;
  String get label => displayName == null || displayName == id ? id : '$displayName ($id)';
}

enum AiErrorKind { auth, permission, rateLimit, quota, overloaded, contextTooLong, badRequest, notFound, network, server }

class AiException implements Exception {
  AiException(this.kind, this.provider, {this.detail, this.retryAfter});
  final AiErrorKind kind;
  final AiProviderKind provider;
  final String? detail;
  final Duration? retryAfter;

  bool get retryable =>
      kind == AiErrorKind.rateLimit || kind == AiErrorKind.overloaded || kind == AiErrorKind.server || kind == AiErrorKind.network;

  String get message => switch (kind) {
        AiErrorKind.auth => 'Clé API refusée par ${provider.label}. Vérifiez-la dans les réglages des fournisseurs.',
        AiErrorKind.permission => '${provider.label} refuse l\'accès à ce modèle ou à cette fonction pour votre compte.',
        AiErrorKind.rateLimit =>
          'Limite de requêtes atteinte chez ${provider.label}${retryAfter == null ? '' : ' : réessayez dans ${retryAfter!.inSeconds} s'}.',
        AiErrorKind.quota => 'Crédit ou quota épuisé chez ${provider.label}. Vérifiez la facturation de votre compte.',
        AiErrorKind.overloaded => '${provider.label} est momentanément surchargé. Réessayez dans un instant.',
        AiErrorKind.contextTooLong => 'La conversation est trop longue pour ce modèle. Commencez une nouvelle conversation.',
        AiErrorKind.badRequest => 'Requête refusée par ${provider.label}.',
        AiErrorKind.notFound => 'Modèle ou adresse introuvable chez ${provider.label}.',
        AiErrorKind.network => provider == AiProviderKind.ollama
            ? 'Ollama ne répond pas. Lancez-le (ollama serve) ou vérifiez l\'adresse.'
            : 'Réseau injoignable vers ${provider.label}.',
        AiErrorKind.server => 'Erreur interne chez ${provider.label}. Réessayez plus tard.',
      };

  @override
  String toString() => detail == null ? message : '$message\nDétail : $detail';
}
