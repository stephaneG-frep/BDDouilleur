import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/mascot.dart';
import '../../domain/modules.dart';
import '../../state/app_state.dart';
import '../modules/module_router.dart';
import '../shell.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onOpenProjects});

  final VoidCallback onOpenProjects;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1200 ? 4 : width >= 840 ? 3 : width >= 520 ? 2 : 1;

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(child: _Hero(compact: width < 520)),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              sliver: SliverToBoxAdapter(child: _ActiveProjectCard(state: state, onOpenProjects: onOpenProjects)),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: Text('Les ateliers du laboratoire', style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  mainAxisExtent: 140,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _ModuleCard(module: modules[i]),
                  childCount: modules.length,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final title = Column(
      crossAxisAlignment: compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ShaderMask(
          shaderCallback: (r) => const LinearGradient(colors: [BddColors.violet, BddColors.turquoise]).createShader(r),
          child: Text('BDDouilleur',
              style: text.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5)),
        ),
        const SizedBox(height: 4),
        Text('Vos bases de données ? Je m\'en débrouille !',
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: text.titleMedium?.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurface.withValues(alpha: 0.85))),
        const SizedBox(height: 10),
        Text('Le laboratoire du savant fou des bases de données.',
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );

    return GradientCard(
      colors: const [BddColors.violet, BddColors.turquoise],
      padding: const EdgeInsets.all(20),
      child: compact
          ? Stack(children: [
              Column(children: [const Mascot(size: 150), const SizedBox(height: 8), title]),
              const Positioned(top: -8, right: -8, child: ThemeMenuButton()),
            ])
          : Row(
              children: [
                const Mascot(size: 170),
                const SizedBox(width: 20),
                Expanded(child: title),
              ],
            ),
    );
  }
}

class _ActiveProjectCard extends StatelessWidget {
  const _ActiveProjectCard({required this.state, required this.onOpenProjects});
  final AppState state;
  final VoidCallback onOpenProjects;

  @override
  Widget build(BuildContext context) {
    final project = state.activeProject;
    final all = state.projects.all();
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.folder_special_rounded, color: scheme.primary, size: 32),
            if (project == null)
              Text(all.isEmpty ? 'Aucun projet pour l\'instant.' : 'Aucun projet actif.',
                  style: Theme.of(context).textTheme.titleMedium)
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Projet actif', style: Theme.of(context).textTheme.labelMedium),
                  Text(project.name, style: Theme.of(context).textTheme.titleMedium),
                  Text('${state.connections.forProject(project.id!).length} base(s) de données',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            if (all.isNotEmpty)
              DropdownMenu<int>(
                key: ValueKey(project?.id),
                initialSelection: project?.id,
                label: const Text('Changer de projet'),
                width: 260,
                onSelected: (id) => state.setActiveProject(id),
                dropdownMenuEntries: [for (final p in all) DropdownMenuEntry(value: p.id!, label: p.name)],
              ),
            FilledButton.tonalIcon(
              onPressed: onOpenProjects,
              icon: Icon(all.isEmpty ? Icons.add_rounded : Icons.folder_open_rounded),
              label: Text(all.isEmpty ? 'Créer mon premier projet' : 'Gérer les projets'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({required this.module});
  final ModuleInfo module;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = switch (module.status) {
      ModuleStatus.available => BddColors.vert,
      ModuleStatus.partial => BddColors.orange,
      ModuleStatus.planned => scheme.outline,
    };
    return GradientCard(
      colors: module.colors,
      onTap: () => openModule(context, module),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: module.colors),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(module.icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(module.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Expanded(child: Text(module.tagline, maxLines: 2, overflow: TextOverflow.ellipsis)),
                const SizedBox(height: 6),
                StatusChip(
                  label: module.status == ModuleStatus.planned
                      ? 'Prévu — phase ${module.phase}'
                      : module.status.label,
                  color: statusColor,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
