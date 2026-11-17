import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/mascot.dart';
import '../../domain/models/db_engine.dart';
import '../../domain/models/project.dart';
import '../../domain/modules.dart';
import '../../state/app_state.dart';
import '../backup/backup_screen.dart';
import '../database/database_screen.dart';
import '../fabrique/fabrique_screen.dart';
import '../firebase/firebase_connection_screen.dart';
import '../firebase/firebase_hub_screen.dart';
import '../professeur/professeur_screen.dart';

/// Ouvre l'écran correspondant à un module. Les modules non encore
/// développés affichent une fiche honnête, sans bouton fictif.
Future<void> openModule(BuildContext context, ModuleInfo module) async {
  switch (module.id) {
    case ModuleId.fabrique:
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const FabriqueScreen()));
    case ModuleId.professeur:
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfesseurScreen()));
    case ModuleId.coffreFort:
      final c = await pickConnection(context, purpose: 'sauvegarder ou restaurer', sqliteOnly: true);
      if (c != null && context.mounted) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => BackupScreen(connection: c)));
      }
    case ModuleId.detective:
      final c = await pickConnection(context, purpose: 'inspecter');
      if (c != null && context.mounted) await openConnection(context, c);
    case ModuleId.schematiseur:
      final c = await pickConnection(context, purpose: 'y concevoir des tables', sqliteOnly: true);
      if (c != null && context.mounted) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => DatabaseScreen(connection: c)));
      }
    case ModuleId.reparateur:
      final c = await pickConnection(context, purpose: 'diagnostiquer', sqliteOnly: true);
      if (c != null && context.mounted) {
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => DatabaseScreen(connection: c, initialTab: DatabaseTab.health)));
      }
    case ModuleId.firebase:
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const FirebaseHubScreen()));
    case ModuleId.connecteur || ModuleId.gardien || ModuleId.autopilot:
      await Navigator.push(context, MaterialPageRoute(builder: (_) => ModuleInfoScreen(module: module)));
  }
}

/// Choix d'une base de données du projet actif (ou de tous les projets).
/// Ouvre l'écran adapté au moteur de la connexion.
Future<void> openConnection(BuildContext context, DbConnection c) => Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            c.engine == DbEngine.firestore ? FirebaseConnectionScreen(connection: c) : DatabaseScreen(connection: c),
      ),
    );

Future<DbConnection?> pickConnection(BuildContext context, {required String purpose, bool sqliteOnly = false}) async {
  final state = context.read<AppState>();
  final active = state.activeProject;
  final list = (active == null ? state.connections.all() : state.connections.forProject(active.id!))
      .where((c) => !sqliteOnly || c.engine == DbEngine.sqlite)
      .toList();
  if (list.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(sqliteOnly ? 'Aucune base SQLite' : 'Aucune base de données'),
        content: MascotTip(
          message: active == null
              ? 'Créez d\'abord un projet puis une base avec La Fabrique.'
              : 'Le projet « ${active.name} » n\'a pas encore de base${sqliteOnly ? ' SQLite (ce module ne traite pas encore Firestore)' : ''}. '
                  'Passez par La Fabrique pour en créer une.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const FabriqueScreen()));
            },
            child: const Text('Ouvrir La Fabrique'),
          ),
        ],
      ),
    );
    return null;
  }
  if (list.length == 1) return list.single;
  return showModalBottomSheet<DbConnection>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Quelle base voulez-vous $purpose ?', style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final c in list)
            ListTile(
              leading: Icon(c.engine == DbEngine.firestore ? Icons.local_fire_department_rounded : Icons.storage_rounded),
              title: Text(c.name),
              subtitle: Text(c.engine.label),
              onTap: () => Navigator.pop(ctx, c),
            ),
        ],
      ),
    ),
  );
}

/// Fiche d'un module dont le développement est planifié.
class ModuleInfoScreen extends StatelessWidget {
  const ModuleInfoScreen({super.key, required this.module});
  final ModuleInfo module;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(module.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GradientCard(
            colors: module.colors,
            child: Row(
              children: [
                const Mascot(size: 96, animate: false),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(module.name, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                      Text(module.tagline),
                      const SizedBox(height: 8),
                      StatusChip(label: 'Prévu — phase ${module.phase}', color: BddColors.orange, icon: Icons.schedule),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const MascotTip(
            title: 'Pas encore dans cette version',
            message: 'Ce module n\'est pas encore opérationnel. Plutôt que de vous montrer de faux boutons, '
                'je vous indique précisément ce qui arrivera et quand.',
          ),
          const SizedBox(height: 16),
          Text('Fonctionnalités prévues', style: text.titleMedium),
          const SizedBox(height: 8),
          for (final f in module.comingLater)
            ListTile(leading: const Icon(Icons.radio_button_unchecked), title: Text(f), dense: true),
        ],
      ),
    );
  }
}
