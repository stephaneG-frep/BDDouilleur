import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../domain/models/project.dart';
import 'firebase_admin_views.dart';
import 'firebase_projects_screen.dart';
import 'firestore_data_view.dart';
import 'rules_view.dart';

/// Espace de travail d'une connexion Firebase (émulateur ou vrai projet).
class FirebaseConnectionScreen extends StatelessWidget {
  const FirebaseConnectionScreen({super.key, required this.connection});
  final DbConnection connection;

  @override
  Widget build(BuildContext context) {
    final t = connection.firebase;
    final tabs = <(Tab, Widget)>[
      (const Tab(icon: Icon(Icons.folder_copy_rounded), text: 'Données'), FirestoreDataView(connection: connection)),
      (const Tab(icon: Icon(Icons.policy_rounded), text: 'Règles'), RulesView(connection: connection)),
      (const Tab(icon: Icon(Icons.sort_rounded), text: 'Index'), IndexesView(connection: connection)),
      (const Tab(icon: Icon(Icons.person_rounded), text: 'Authentication'), AuthView(connection: connection)),
      if (!t.isEmulator) ...[
        (const Tab(icon: Icon(Icons.settings_rounded), text: 'Configuration'), ConfigView(connection: connection)),
        (
          const Tab(icon: Icon(Icons.troubleshoot_rounded), text: 'Analyse'),
          ProjectAnalysisView(projectId: t.projectId, databaseId: t.databaseId, journalProjectId: connection.projectId)
        ),
      ],
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(connection.name),
            Text(t.description, style: Theme.of(context).textTheme.bodySmall),
          ]),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: StatusChip(
                label: t.mode.label,
                color: t.isEmulator ? BddColors.turquoise : BddColors.orange,
                icon: t.isEmulator ? Icons.science_rounded : Icons.cloud_rounded,
              ),
            ),
          ],
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final t in tabs) t.$1]),
        ),
        body: TabBarView(children: [for (final t in tabs) t.$2]),
      ),
    );
  }
}
