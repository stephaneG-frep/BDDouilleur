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
import '../../data/codegen/flutter_codegen.dart';
import '../../domain/schema_proposal.dart';
import '../agent/agent_screen.dart';
import '../codegen/codegen_screen.dart';
import '../detective/project_analysis_screen.dart';
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
      final choice = await _choose(context, 'Que voulez-vous analyser ?', [
        (Icons.folder_open_rounded, 'Un dossier de projet', 'Flutter, React, Angular, Vue, Python, Node…'),
        (Icons.storage_rounded, 'Une base de données', 'Tables, colonnes, clés, index'),
      ]);
      if (!context.mounted) return;
      if (choice == 0) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProjectAnalysisScreen()));
      } else if (choice == 1) {
        final c = await pickConnection(context, purpose: 'inspecter');
        if (c != null && context.mounted) await openConnection(context, c);
      }
    case ModuleId.schematiseur:
      final choice = await _choose(context, 'Comment concevoir le schéma ?', [
        (Icons.table_chart_rounded, 'Avec le formulaire', 'Créer des tables dans une base SQLite'),
        (Icons.record_voice_over_rounded, 'Depuis une description en français', 'L\'agent IA propose un schéma'),
      ]);
      if (!context.mounted) return;
      if (choice == 0) {
        final c = await pickConnection(context, purpose: 'y concevoir des tables', sqliteOnly: true);
        if (c != null && context.mounted) {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => DatabaseScreen(connection: c)));
        }
      } else if (choice == 1) {
        await startConversation(context,
            prompt: 'Je veux une base de données pour : … (décrivez votre application). '
                'Propose un schéma avec propose_schema et explique chaque relation.');
      }
    case ModuleId.connecteur:
      final c = await pickConnection(context, purpose: 'générer son code Flutter', sqliteOnly: true);
      if (c == null || !context.mounted) return;
      try {
        final state = context.read<AppState>();
        final db = await state.connectorFor(c);
        final entities = [for (final t in await db.listTables()) FlutterCodeGenerator.entityFromTable(await db.describeTable(t))];
        if (!context.mounted) return;
        if (entities.isEmpty) {
          showError(context, 'La base « ${c.name} » ne contient aucune table.');
          return;
        }
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => CodegenScreen(
                    proposal: SchemaProposal(entities: entities, summary: 'Tables de la base « ${c.name} »'))));
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    case ModuleId.reparateur:
      final c = await pickConnection(context, purpose: 'diagnostiquer', sqliteOnly: true);
      if (c != null && context.mounted) {
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => DatabaseScreen(connection: c, initialTab: DatabaseTab.health)));
      }
    case ModuleId.firebase:
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const FirebaseHubScreen()));
    case ModuleId.gardien || ModuleId.autopilot:
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

Future<int?> _choose(BuildContext context, String title, List<(IconData, String, String)> options) =>
    showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final (i, o) in options.indexed)
            ListTile(leading: Icon(o.$1), title: Text(o.$2), subtitle: Text(o.$3), onTap: () => Navigator.pop(ctx, i)),
        ]),
      ),
    );
