import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../domain/models/db_engine.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../domain/schema_proposal.dart';
import '../../state/agent_tools.dart';
import '../../state/app_state.dart';
import 'codegen_screen.dart';

/// Affiche une architecture de données proposée et permet de l'appliquer.
class SchemaProposalCard extends StatelessWidget {
  const SchemaProposalCard({super.key, required this.proposal, this.folder});
  final SchemaProposal proposal;

  /// Dossier de projet Flutter proposé par défaut pour la génération.
  final String? folder;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final problems = proposal.validate();
    return Card(
      color: BddColors.violet.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.schema_rounded, color: BddColors.violet),
            const SizedBox(width: 8),
            Expanded(child: Text('Architecture de données proposée', style: text.titleMedium)),
          ]),
          if (proposal.summary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(proposal.summary)),
          const SizedBox(height: 8),
          for (final e in proposal.entities)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${e.name}  (table ${e.tableName})', style: const TextStyle(fontWeight: FontWeight.w700)),
                if (e.description.isNotEmpty) Text(e.description, style: text.bodySmall),
                Text(
                  ['id (clé primaire)', for (final f in e.fields) f.references == null ? '${f.name} : ${f.type.sql}${f.required ? ' requis' : ''}' : '${f.name} : clé → ${f.references}${f.required ? ' (requis)' : ''}']
                      .join(' • '),
                  style: AppTheme.mono.copyWith(fontSize: 12),
                ),
              ]),
            ),
          if (problems.isNotEmpty)
            Text('Proposition invalide : ${problems.join(' ; ')}', style: const TextStyle(color: BddColors.rose))
          else
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                icon: const Icon(Icons.table_chart_rounded),
                label: const Text('Créer dans une base SQLite'),
                onPressed: () => applyToSqlite(context, proposal),
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.code_rounded),
                label: const Text('Générer le code Flutter'),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => CodegenScreen(proposal: proposal, initialFolder: folder))),
              ),
            ]),
        ]),
      ),
    );
  }

  /// Choix d'une base SQLite du projet actif, confirmation, création réelle.
  static Future<void> applyToSqlite(BuildContext context, SchemaProposal proposal) async {
    final state = context.read<AppState>();
    final project = state.activeProject;
    final conns = project == null
        ? <DbConnection>[]
        : state.connections.forProject(project.id!).where((c) => c.engine == DbEngine.sqlite).toList();
    if (conns.isEmpty) {
      showError(context, 'Aucune base SQLite dans le projet actif : créez-en une avec La Fabrique.');
      return;
    }
    final tables = proposal.toTableDefinitions();
    final target = await showDialog<DbConnection>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Dans quelle base créer les tables ?'),
        children: [
          for (final c in conns) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, c), child: Text(c.name)),
        ],
      ),
    );
    if (target == null || !context.mounted) return;
    final ok = await confirm(context,
        title: 'Créer ${tables.length} table(s) ?',
        message: 'Dans « ${target.name} » : ${tables.map((t) => t.name).join(', ')}.\n'
            'Les tables qui existent déjà ne sont pas modifiées.',
        action: 'Créer');
    if (!ok || !context.mounted) return;
    try {
      final r = await AgentToolbox.applyTables(state, target, tables);
      state.journal.log(
        projectId: target.projectId,
        connectionId: target.id,
        action: JournalAction.schemaApplied,
        summary: 'Schéma appliqué à « ${target.name} » : ${(r['creees'] as List).length} table(s) créée(s)',
      );
      if (context.mounted) {
        final skipped = r['deja_existantes_non_modifiees'] as List?;
        showSuccess(context, 'Créées : ${(r['creees'] as List).join(', ')}${skipped == null ? '' : ' • déjà présentes : ${skipped.join(', ')}'}');
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}
