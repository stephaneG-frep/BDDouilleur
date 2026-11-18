import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/markdown_lite.dart';
import '../../core/widgets/mascot.dart';
import '../../data/ai/agent.dart';
import '../../data/ai/ai_repository.dart';
import '../../data/codegen/flutter_codegen.dart';
import '../../domain/ai/ai_models.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/schema_proposal.dart';
import '../../state/agent_tools.dart';
import '../../state/app_state.dart';
import '../codegen/codegen_screen.dart';
import '../codegen/schema_proposal_card.dart';

/// Conversation avec l'agent IA d'un projet.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversationId, this.initialPrompt});
  final int conversationId;

  /// Message proposé à l'ouverture (ex. depuis Le Détective).
  final String? initialPrompt;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final _input = TextEditingController(text: widget.initialPrompt ?? '');
  final _scroll = ScrollController();
  List<AiMessage> _messages = [];
  AiConversation? _conv;
  bool _running = false;
  bool _cancel = false;
  String? _error;

  AppState get _state => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _conv = _state.aiConversations.byId(widget.conversationId);
      _messages = _state.aiConversations.messages(widget.conversationId);
    });
    _scrollDown();
  }

  void _scrollDown() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });

  /// Résultat associé à un appel d'outil (dans le message d'outils suivant).
  AiToolResult? _resultFor(String callId) {
    for (final m in _messages) {
      for (final r in m.toolResults) {
        if (r.callId == callId) return r;
      }
    }
    return null;
  }

  Future<void> _send({bool retry = false}) async {
    final conv = _conv;
    if (conv == null || _running) return;
    final text = _input.text.trim();
    if (!retry && text.isEmpty) return;
    final project = _state.projects.byId(conv.projectId);
    if (project == null) return;
    setState(() {
      _running = true;
      _cancel = false;
      _error = null;
    });
    try {
      // Appels d'outils restés sans résultat (interruption) : signalés au modèle.
      final last = _messages.isEmpty ? null : _messages.last;
      if (last != null && last.role == AiRole.assistant && last.toolCalls.isNotEmpty) {
        final fix = AiMessage(role: AiRole.tool, toolResults: [
          for (final c in last.toolCalls)
            AiToolResult(callId: c.id, name: c.name, isError: true, content: 'Interrompu : action non exécutée.')
        ]);
        _state.aiConversations.addMessage(conv.id, fix);
        _messages.add(fix);
      }
      if (!retry) {
        final user = AiMessage.user(text);
        _state.aiConversations.addMessage(conv.id, user);
        setState(() {
          _messages.add(user);
          _input.clear();
        });
        _scrollDown();
        if (_messages.where((m) => m.role == AiRole.user).length == 1 && conv.title == 'Nouvelle conversation') {
          _state.aiConversations.rename(conv.id, text.length > 60 ? '${text.substring(0, 60)}…' : text);
        }
      }
      final provider = await _state.providerFor(conv.provider);
      final box = AgentToolbox(AgentContext(state: _state, project: project, folder: conv.folder, connectionId: conv.connectionId));
      final agent = Agent(provider: provider, model: conv.model, tools: box.tools(), system: box.systemPrompt());
      int? pendingIn, pendingOut;
      await agent.runTurn(
        [..._messages],
        approve: _approve,
        cancelled: () => _cancel,
        onUsage: (i, o) {
          pendingIn = i;
          pendingOut = o;
        },
        onMessage: (m) {
          _state.aiConversations.addMessage(conv.id, m, inputTokens: pendingIn, outputTokens: pendingOut);
          pendingIn = pendingOut = null;
          if (m.role == AiRole.tool) {
            for (final r in m.toolResults) {
              _state.journal.log(
                projectId: project.id,
                connectionId: conv.connectionId,
                action: JournalAction.agentToolExecuted,
                summary: 'Agent IA (${conv.provider.label}) : ${AgentToolbox.label(AiToolCall(id: r.callId, name: r.name, arguments: const {}))}',
                success: !r.isError,
                error: r.isError ? r.content : null,
              );
            }
          }
          if (mounted) setState(() => _messages.add(m));
          _scrollDown();
        },
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() => _running = false);
        _conv = _state.aiConversations.byId(widget.conversationId);
      }
    }
  }

  Future<bool> _approve(AiToolCall call, AgentTool tool) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.gpp_maybe_rounded, color: BddColors.orange, size: 36),
        title: const Text('L\'agent demande une action'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(AgentToolbox.label(call), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(tool.describe(call.arguments)),
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Paramètres exacts'),
                children: [CodeBlock(const JsonEncoder.withIndent('  ').convert(call.arguments))],
              ),
              const Text('Rien ne sera fait si vous refusez. L\'opération est journalisée.'),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Refuser')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Autoriser')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _changeModel() async {
    final conv = _conv!;
    final choices = <(AiProviderKind, String)>[];
    for (final k in AiProviderKind.values) {
      final m = _state.ai.model(k);
      if (m != null && await _state.ai.hasKey(k)) choices.add((k, m));
    }
    if (!mounted) return;
    final pick = await showDialog<(AiProviderKind, String)>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Modèle de la conversation'),
        children: [
          for (final c in choices)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, c), child: Text('${c.$1.label} — ${c.$2}')),
          if (choices.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Configurez d\'abord un fournisseur.')),
        ],
      ),
    );
    if (pick == null) return;
    _state.aiConversations.setModel(conv.id, pick.$1, pick.$2);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final conv = _conv;
    if (conv == null) return const Scaffold(body: Center(child: Text('Conversation introuvable.')));
    final (tin, tout) = _state.aiConversations.usage(conv.id);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(conv.title, overflow: TextOverflow.ellipsis),
          Text('${conv.provider.label} • ${conv.model}${tin + tout == 0 ? '' : ' • $tin / $tout jetons'}',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [IconButton(tooltip: 'Changer de modèle', icon: const Icon(Icons.tune_rounded), onPressed: _running ? null : _changeModel)],
      ),
      body: Column(children: [
        if (conv.folder != null || conv.connectionId != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Text(
              [
                if (conv.folder != null) 'Dossier lisible : ${conv.folder}',
                if (conv.connectionId != null) 'Base : ${_state.connections.byId(conv.connectionId!)?.name ?? '#${conv.connectionId}'}',
              ].join(' • '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Expanded(
          child: _messages.isEmpty
              ? const EmptyState(
                  message: 'Posez votre question. Exemples :\n« Analyse mon projet et propose une base de données »\n'
                      '« Crée une base pour gérer des clients et des factures »\n« Pourquoi cette requête est-elle lente ? »')
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  children: [for (final m in _messages) ..._buildMessage(m)],
                ),
        ),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            actions: [
              TextButton(onPressed: () => setState(() => _error = null), child: const Text('Fermer')),
              TextButton(onPressed: () => _send(retry: true), child: const Text('Réessayer')),
            ],
          ),
        if (_running)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              const Expanded(child: Text('L\'agent travaille…')),
              TextButton(onPressed: () => setState(() => _cancel = true), child: const Text('Arrêter')),
            ]),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 6,
                  enabled: !_running,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(hintText: 'Votre message…'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Envoyer',
                icon: const Icon(Icons.send_rounded),
                onPressed: _running ? null : () => _send(),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  List<Widget> _buildMessage(AiMessage m) {
    final scheme = Theme.of(context).colorScheme;
    switch (m.role) {
      case AiRole.tool:
        return const [];
      case AiRole.user:
        return [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.only(bottom: 10, left: 48),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(16)),
              child: SelectableText(m.text),
            ),
          ),
        ];
      case AiRole.assistant:
        return [
          if (m.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10, right: 32),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Mascot(size: 34, animate: false),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (m.source != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 2),
                        child: Text(m.source!, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.secondary)),
                      ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(16)),
                      child: MarkdownLite(m.text.trim()),
                    ),
                  ]),
                ),
              ]),
            ),
          for (final c in m.toolCalls) _toolCard(c),
        ];
    }
  }

  Widget _toolCard(AiToolCall c) {
    final r = _resultFor(c.id);
    final refused = r != null && r.isError && r.content.startsWith('REFUSÉ');
    final (icon, color, status) = r == null
        ? (Icons.hourglass_top_rounded, BddColors.orange, 'en cours')
        : refused
            ? (Icons.block_rounded, BddColors.orange, 'refusé par vous')
            : r.isError
                ? (Icons.error_rounded, BddColors.rose, 'échec')
                : (Icons.check_circle_rounded, BddColors.vert, 'exécuté');
    Map<String, Object?>? payload;
    if (r != null && !r.isError) {
      try {
        final j = jsonDecode(r.content);
        if (j is Map) payload = j.cast<String, Object?>();
      } catch (_) {}
    }
    final conv = _conv!;
    return Padding(
      padding: const EdgeInsets.only(left: 42, bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Card(
          margin: EdgeInsets.zero,
          child: ExpansionTile(
            shape: const Border(),
            dense: true,
            leading: Icon(icon, color: color),
            title: Text(AgentToolbox.label(c)),
            subtitle: Text(status, style: TextStyle(color: color)),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Paramètres'),
              CodeBlock(const JsonEncoder.withIndent('  ').convert(c.arguments)),
              if (r != null) ...[
                const SizedBox(height: 6),
                const Text('Résultat réel'),
                CodeBlock(r.content.length > 4000 ? '${r.content.substring(0, 4000)}…' : r.content),
              ],
            ],
          ),
        ),
        if (payload != null && c.name == 'propose_schema' && payload['proposal'] is Map)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SchemaProposalCard(
                proposal: SchemaProposal.fromJson((payload['proposal'] as Map).cast()), folder: conv.folder),
          ),
        if (payload != null && c.name == 'plan_flutter_code' && payload['proposal'] is Map)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FilledButton.icon(
              icon: const Icon(Icons.difference_rounded),
              label: const Text('Voir le plan, les différences et intégrer'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CodegenScreen(
                    proposal: SchemaProposal.fromJson((payload!['proposal'] as Map).cast()),
                    initialFolder: conv.folder,
                    backend: payload['backend'] == 'firestore' ? CodegenBackend.firestore : CodegenBackend.sqlite,
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
