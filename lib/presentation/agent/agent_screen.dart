import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/mascot.dart';
import '../../domain/ai/ai_models.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../state/app_state.dart';
import '../firebase/firebase_widgets.dart';
import 'ai_providers_screen.dart';
import 'chat_screen.dart';

/// Agent IA : conversations du projet actif.
class AgentScreen extends StatelessWidget {
  const AgentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final project = state.activeProject;
    final convs = project == null ? const [] : state.aiConversations.forProject(project.id!);
    final provider = state.ai.defaultProvider;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent IA'),
        actions: [
          IconButton(
            tooltip: 'Fournisseurs d\'IA',
            icon: const Icon(Icons.settings_suggest_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiProvidersScreen())),
          ),
        ],
      ),
      floatingActionButton: project == null || provider == null
          ? null
          : FloatingActionButton.extended(
              heroTag: 'newconv',
              icon: const Icon(Icons.add_comment_rounded),
              label: const Text('Nouvelle conversation'),
              onPressed: () => startConversation(context),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          GradientCard(
            colors: const [BddColors.violet, BddColors.orange],
            child: Row(children: [
              const Mascot(size: 72, animate: false),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Je travaille avec de vrais outils : je lis vos bases et vos projets, je propose des schémas et du code, '
                  'et je vous demande votre accord avant toute modification. Tout est journalisé.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          if (provider == null)
            MascotTip(
              title: 'Aucun fournisseur configuré',
              message: 'Ajoutez une clé (Anthropic, OpenAI, Gemini, Mistral) ou connectez Ollama en local.',
            ),
          if (provider == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.icon(
                icon: const Icon(Icons.key_rounded),
                label: const Text('Configurer un fournisseur'),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiProvidersScreen())),
              ),
            ),
          if (project == null)
            const MascotTip(message: 'Choisissez un projet actif (onglet Projets) : les conversations sont rangées par projet.'),
          if (project != null && provider != null && convs.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('Aucune conversation pour ce projet.')),
          if (project != null) ...[
            if (convs.isNotEmpty) Text('Conversations du projet « ${project.name} »', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final c in convs)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const Icon(Icons.forum_rounded),
                  title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${c.provider.label} • ${c.model} • ${formatDate(c.updatedAt)}'),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(conversationId: c.id))),
                  trailing: IconButton(
                    tooltip: 'Supprimer',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () async {
                      final ok = await confirm(context,
                          title: 'Supprimer la conversation ?',
                          message: 'L\'historique de « ${c.title} » sera effacé. Les actions déjà réalisées restent dans le journal.',
                          danger: true,
                          action: 'Supprimer');
                      if (!ok) return;
                      state.aiConversations.delete(c.id);
                      state.refresh();
                    },
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Crée une conversation (fournisseur, dossier lisible, base par défaut) et l'ouvre.
Future<void> startConversation(BuildContext context, {String? folder, int? connectionId, String? prompt}) async {
  final state = context.read<AppState>();
  final project = state.activeProject;
  if (project == null) {
    showError(context, 'Choisissez d\'abord un projet actif.');
    return;
  }
  final available = <AiProviderKind>[];
  for (final k in AiProviderKind.values) {
    if (state.ai.model(k) != null && await state.ai.hasKey(k)) available.add(k);
  }
  if (!context.mounted) return;
  if (available.isEmpty) {
    showError(context, 'Configurez d\'abord un fournisseur d\'IA (clé et modèle).');
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const AiProvidersScreen()));
    return;
  }
  final result = await showDialog<_NewConv>(
    context: context,
    builder: (_) => _NewConversationDialog(
      project: project,
      providers: available,
      initialProvider: available.contains(state.ai.defaultProvider) ? state.ai.defaultProvider! : available.first,
      folder: folder,
      connectionId: connectionId,
    ),
  );
  if (result == null || !context.mounted) return;
  final conv = state.aiConversations.create(
    projectId: project.id!,
    title: 'Nouvelle conversation',
    provider: result.provider,
    model: state.ai.model(result.provider)!,
    folder: result.folder,
    connectionId: result.connectionId,
  );
  state.journal.log(
    projectId: project.id,
    action: JournalAction.agentConversation,
    summary: 'Conversation ouverte avec ${result.provider.label} (${conv.model})',
  );
  state.refresh();
  await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(conversationId: conv.id, initialPrompt: prompt)));
}

class _NewConv {
  const _NewConv(this.provider, this.folder, this.connectionId);
  final AiProviderKind provider;
  final String? folder;
  final int? connectionId;
}

class _NewConversationDialog extends StatefulWidget {
  const _NewConversationDialog({
    required this.project,
    required this.providers,
    required this.initialProvider,
    this.folder,
    this.connectionId,
  });
  final Project project;
  final List<AiProviderKind> providers;
  final AiProviderKind initialProvider;
  final String? folder;
  final int? connectionId;

  @override
  State<_NewConversationDialog> createState() => _NewConversationDialogState();
}

class _NewConversationDialogState extends State<_NewConversationDialog> {
  final _form = GlobalKey<FormState>();
  late AiProviderKind _provider = widget.initialProvider;
  late final _folder = TextEditingController(text: widget.folder ?? '');
  late int? _conn = widget.connectionId;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final conns = state.connections.forProject(widget.project.id!);
    return AlertDialog(
      title: const Text('Nouvelle conversation'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<AiProviderKind>(
                initialValue: _provider,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Fournisseur'),
                items: [
                  for (final k in widget.providers) DropdownMenuItem(value: k, child: Text('${k.label} — ${state.ai.model(k)}'))
                ],
                onChanged: (v) => setState(() => _provider = v!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: conns.any((c) => c.id == _conn) ? _conn : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Base de données par défaut (facultatif)'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Aucune')),
                  for (final c in conns) DropdownMenuItem(value: c.id, child: Text('${c.name} (${c.engine.label})')),
                ],
                onChanged: (v) => setState(() => _conn = v),
              ),
              const SizedBox(height: 12),
              FolderField(
                controller: _folder,
                label: 'Dossier de projet lisible par l\'agent (facultatif)',
                helper: 'L\'agent ne pourra lire que ce dossier (jamais les fichiers .env ni les clés).',
                validator: (v) {
                  final s = (v ?? '').trim();
                  if (s.isEmpty) return null;
                  return validateFlutterProject(s) == 'Dossier introuvable.' ? 'Dossier introuvable.' : null;
                },
              ),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, _NewConv(_provider, _folder.text.trim().isEmpty ? null : _folder.text.trim(), _conn));
          },
          child: const Text('Commencer'),
        ),
      ],
    );
  }
}
