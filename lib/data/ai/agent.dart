import 'dart:convert';

import '../../domain/ai/ai_models.dart';
import 'ai_providers.dart';

/// Outil réel mis à disposition de l'agent.
class AgentTool {
  const AgentTool({
    required this.spec,
    required this.run,
    this.mutating = false,
    required this.describe,
  });

  final AiToolSpec spec;

  /// Exécution réelle. Le résultat (JSON ou texte) est renvoyé au modèle.
  final Future<Object?> Function(Map<String, Object?> args) run;

  /// Une action qui modifie des données exige l'accord explicite de
  /// l'utilisateur avant chaque exécution.
  final bool mutating;

  /// Description en français de ce que l'appel va faire (carte d'approbation).
  final String Function(Map<String, Object?> args) describe;

  String get name => spec.name;
}

/// Décision de l'utilisateur sur une action demandée par le modèle.
typedef ApprovalCallback = Future<bool> Function(AiToolCall call, AgentTool tool);

/// Étape visible dans l'interface pendant le tour de l'agent.
typedef AgentProgress = void Function(AiMessage message);

/// Boucle d'agent : le modèle demande des outils, BDDouilleur les exécute
/// réellement (après accord pour les actions modifiantes) et renvoie les
/// résultats réels. Une réponse textuelle n'est jamais considérée comme une
/// opération réussie : seuls les résultats d'outils font foi.
class Agent {
  Agent({required this.provider, required this.model, required this.tools, required this.system, this.maxSteps = 12});

  final AiProvider provider;
  final String model;
  final List<AgentTool> tools;
  final String system;
  final int maxSteps;

  AgentTool? tool(String name) => tools.where((t) => t.name == name).firstOrNull;

  /// Exécute un tour complet à partir de [history] (qui se termine par le
  /// message de l'utilisateur). Renvoie les nouveaux messages produits.
  Future<List<AiMessage>> runTurn(
    List<AiMessage> history, {
    required ApprovalCallback approve,
    AgentProgress? onMessage,
    void Function(int input, int output)? onUsage,
    bool Function()? cancelled,
  }) async {
    final produced = <AiMessage>[];
    final convo = [...history];
    for (var step = 0; step < maxSteps; step++) {
      if (cancelled?.call() == true) break;
      final res = await provider.chat(
        model: model,
        system: system,
        messages: convo,
        tools: [for (final t in tools) t.spec],
      );
      onUsage?.call(res.inputTokens ?? 0, res.outputTokens ?? 0);
      var reply = res.message;
      if (res.stopReason == AiStopReason.refusal && reply.toolCalls.isEmpty) {
        reply = AiMessage(
          role: AiRole.assistant,
          text: '${reply.text}${reply.text.isEmpty ? '' : '\n\n'}(Le modèle a refusé de traiter cette demande.)',
          raw: reply.raw,
        );
      } else if (res.stopReason == AiStopReason.maxTokens && reply.toolCalls.isEmpty) {
        reply = AiMessage(role: AiRole.assistant, text: '${reply.text}\n\n(Réponse tronquée : limite de longueur atteinte.)', raw: reply.raw);
      }
      reply = reply.withSource('${provider.kind.label} • $model');
      convo.add(reply);
      produced.add(reply);
      onMessage?.call(reply);
      if (reply.toolCalls.isEmpty) return produced;

      final results = <AiToolResult>[];
      for (final call in reply.toolCalls) {
        results.add(await _execute(call, approve, cancelled));
      }
      final toolMsg = AiMessage(role: AiRole.tool, toolResults: results);
      convo.add(toolMsg);
      produced.add(toolMsg);
      onMessage?.call(toolMsg);
    }
    final stop = AiMessage(
      role: AiRole.assistant,
      text: cancelled?.call() == true
          ? '(Tour interrompu à votre demande.)'
          : '(Arrêt de sécurité : $maxSteps étapes d\'outils sans conclusion. Reformulez ou découpez la demande.)',
    );
    produced.add(stop);
    onMessage?.call(stop);
    return produced;
  }

  Future<AiToolResult> _execute(AiToolCall call, ApprovalCallback approve, bool Function()? cancelled) async {
    final t = tool(call.name);
    if (t == null) {
      return AiToolResult(callId: call.id, name: call.name, isError: true, content: 'Outil inconnu : ${call.name}.');
    }
    if (call.arguments.containsKey('_arguments_invalides')) {
      return AiToolResult(callId: call.id, name: call.name, isError: true, content: 'Arguments JSON invalides : réessaie avec un JSON valide.');
    }
    if (cancelled?.call() == true) {
      return AiToolResult(callId: call.id, name: call.name, isError: true, content: 'Interrompu par l\'utilisateur.');
    }
    if (t.mutating && !await approve(call, t)) {
      return AiToolResult(
        callId: call.id,
        name: call.name,
        isError: true,
        content: 'REFUSÉ par l\'utilisateur : cette action n\'a PAS été exécutée. Ne prétends pas qu\'elle a eu lieu.',
      );
    }
    try {
      final out = await t.run(call.arguments);
      return AiToolResult(callId: call.id, name: call.name, content: out is String ? out : jsonEncode(out));
    } catch (e) {
      return AiToolResult(callId: call.id, name: call.name, isError: true, content: 'ÉCHEC : $e');
    }
  }
}
