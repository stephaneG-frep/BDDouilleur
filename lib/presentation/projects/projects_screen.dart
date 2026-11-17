import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../domain/models/db_engine.dart';
import '../../domain/models/project.dart';
import '../../state/app_state.dart';
import '../backup/backup_screen.dart';
import '../modules/module_router.dart';
import '../fabrique/fabrique_screen.dart';

class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projects = state.projects.all();
    final activeId = state.activeProject?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Projets')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showProjectDialog(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nouveau projet'),
      ),
      body: projects.isEmpty
          ? EmptyState(
              message: 'Aucun projet. Un projet regroupe les bases de données d\'une application.',
              action: FilledButton.icon(
                onPressed: () => showProjectDialog(context),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Créer un projet'),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: projects.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final p = projects[i];
                final count = state.connections.forProject(p.id!).length;
                final active = p.id == activeId;
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: CircleAvatar(
                      backgroundColor: (active ? BddColors.violet : BddColors.turquoise).withValues(alpha: 0.2),
                      child: Icon(active ? Icons.star_rounded : Icons.folder_rounded,
                          color: active ? BddColors.violet : BddColors.turquoise),
                    ),
                    title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([
                      if (p.description.isNotEmpty) p.description,
                      '$count base(s) • modifié le ${formatDate(p.updatedAt)}',
                    ].join('\n')),
                    isThreeLine: p.description.isNotEmpty,
                    trailing: active ? const StatusChip(label: 'Actif', color: BddColors.violet) : null,
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => ProjectDetailScreen(projectId: p.id!))),
                  ),
                );
              },
            ),
    );
  }
}

/// Création (project == null) ou modification d'un projet.
Future<Project?> showProjectDialog(BuildContext context, {Project? project}) {
  final name = TextEditingController(text: project?.name);
  final description = TextEditingController(text: project?.description);
  final formKey = GlobalKey<FormState>();
  return showDialog<Project>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(project == null ? 'Nouveau projet' : 'Modifier le projet'),
      content: Form(
        key: formKey,
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nom du projet', hintText: 'Ex. Boutique en ligne'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Le nom est obligatoire.' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: description,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Description (facultatif)'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            if (!formKey.currentState!.validate()) return;
            final state = ctx.read<AppState>();
            try {
              final result = project == null
                  ? state.createProject(name.text, description.text)
                  : state.updateProject(project.copyWith(name: name.text, description: description.text));
              Navigator.pop(ctx, result);
            } catch (e) {
              showError(ctx, e);
            }
          },
          child: Text(project == null ? 'Créer' : 'Enregistrer'),
        ),
      ],
    ),
  );
}

class ProjectDetailScreen extends StatelessWidget {
  const ProjectDetailScreen({super.key, required this.projectId});
  final int projectId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final project = state.projects.byId(projectId);
    if (project == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(message: 'Ce projet n\'existe plus.'));
    }
    final conns = state.connections.forProject(projectId);
    final isActive = state.activeProject?.id == projectId;

    return Scaffold(
      appBar: AppBar(
        title: Text(project.name),
        actions: [
          IconButton(
            tooltip: 'Modifier',
            icon: const Icon(Icons.edit_rounded),
            onPressed: () => showProjectDialog(context, project: project),
          ),
          IconButton(
            tooltip: 'Supprimer le projet',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => _delete(context, project),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (project.description.isNotEmpty) ...[Text(project.description), const SizedBox(height: 8)],
                  Text('Créé le ${formatDate(project.createdAt)}', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (!isActive)
                        FilledButton.tonalIcon(
                          onPressed: () => state.setActiveProject(projectId),
                          icon: const Icon(Icons.star_outline_rounded),
                          label: const Text('Définir comme projet actif'),
                        )
                      else
                        const StatusChip(label: 'Projet actif', color: BddColors.violet, icon: Icons.star_rounded),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text('Bases de données', style: Theme.of(context).textTheme.titleLarge)),
              FilledButton.icon(
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => FabriqueScreen(projectId: projectId))),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Ajouter'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (conns.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: MascotTip(message: 'Ce projet n\'a pas encore de base. Cliquez sur « Ajouter » pour en fabriquer une.'),
            ),
          for (final c in conns)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: ListTile(
                  leading: c.engine == DbEngine.firestore
                      ? const Icon(Icons.local_fire_department_rounded, color: BddColors.orange)
                      : const Icon(Icons.storage_rounded, color: BddColors.turquoise),
                  title: Text(c.name),
                  subtitle: Text(
                      c.engine == DbEngine.firestore
                          ? '${c.engine.label} • ${c.firebase.description}'
                          : '${c.engine.label} • ${c.location}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  onTap: () => openConnection(context, c),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'backup') {
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => BackupScreen(connection: c)));
                      } else if (v == 'detach' && context.mounted) {
                        await _detach(context, c);
                      }
                    },
                    itemBuilder: (_) => [
                      if (c.engine == DbEngine.sqlite)
                        const PopupMenuItem(value: 'backup', child: Text('Coffre-fort (sauvegardes)')),
                      PopupMenuItem(
                          value: 'detach',
                          child: Text(c.engine == DbEngine.firestore
                              ? 'Retirer du projet (le projet Firebase n\'est pas touché)…'
                              : 'Retirer du projet…')),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _detach(BuildContext context, DbConnection c) async {
    final state = context.read<AppState>();
    final managed = state.isManagedFile(c);
    var deleteFile = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Retirer « ${c.name} » ?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('La connexion sera retirée du projet.'),
              if (managed)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: deleteFile,
                  onChanged: (v) => setState(() => deleteFile = v ?? false),
                  title: const Text('Supprimer aussi le fichier de la base (irréversible)'),
                )
              else
                const Text('\nLe fichier, créé hors de BDDouilleur, ne sera pas supprimé.'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Retirer')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    if (deleteFile &&
        !await confirmByTyping(context,
            title: 'Suppression définitive',
            message: 'Le fichier et toutes ses données seront effacés. Les sauvegardes du Coffre-fort sont conservées.',
            expected: c.name)) {
      return;
    }
    try {
      await state.detachConnection(c, deleteFile: deleteFile);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _delete(BuildContext context, Project project) async {
    final state = context.read<AppState>();
    var deleteFiles = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Supprimer « ${project.name} » ?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Le projet et ses connexions seront supprimés de BDDouilleur.'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: deleteFiles,
                onChanged: (v) => setState(() => deleteFiles = v ?? false),
                title: const Text('Supprimer aussi les fichiers de bases créés par BDDouilleur'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Supprimer'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    if (!await confirmByTyping(context,
        title: 'Confirmation', message: 'Cette suppression est définitive.', expected: project.name)) {
      return;
    }
    await state.deleteProject(project, deleteFiles: deleteFiles);
    if (context.mounted) Navigator.pop(context);
  }
}
