import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/firebase/firebase_autopilot.dart';
import '../../data/firebase/firebase_diagnostic.dart';
import '../../data/firebase/firebase_management.dart';
import '../../domain/firebase/firebase_target.dart';
import '../../domain/models/journal_entry.dart';
import '../../state/app_state.dart';
import 'firebase_connection_screen.dart';
import 'firebase_widgets.dart';

/// Projets Firebase réellement présents sur le compte Google connecté.
class FirebaseProjectsScreen extends StatefulWidget {
  const FirebaseProjectsScreen({super.key});

  @override
  State<FirebaseProjectsScreen> createState() => _FirebaseProjectsScreenState();
}

class _FirebaseProjectsScreenState extends State<FirebaseProjectsScreen> {
  late Future<List<FirebaseProjectInfo>> _future = _load();

  Future<List<FirebaseProjectInfo>> _load() =>
      FirebaseManagementService(context.read<AppState>().googleApi()).listFirebaseProjects();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mes projets Firebase'),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => setState(() { _future = _load(); }),
          ),
        ],
      ),
      body: FutureBuilder<List<FirebaseProjectInfo>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return EmptyState(
              message: 'Lecture impossible :\n${snap.error}',
              action: FilledButton(onPressed: () => setState(() { _future = _load(); }), child: const Text('Réessayer')),
            );
          }
          final list = snap.data!;
          if (list.isEmpty) {
            return const EmptyState(
                message: 'Aucun projet Firebase sur ce compte. Utilisez « Créer un projet complet ».');
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final p in list)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(Icons.local_fire_department_rounded, color: BddColors.orange),
                    title: Text(p.displayName),
                    subtitle: Text('${p.projectId}${p.locationId == null ? '' : ' • ${p.locationId}'}'),
                    trailing: Wrap(spacing: 4, children: [
                      IconButton(
                        tooltip: 'Analyser',
                        icon: const Icon(Icons.troubleshoot_rounded),
                        onPressed: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => ProjectAnalysisScreen(projectId: p.projectId))),
                      ),
                      IconButton(
                        tooltip: 'Connecter au projet actif',
                        icon: const Icon(Icons.add_link_rounded),
                        onPressed: () => _connect(context, p),
                      ),
                    ]),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _connect(BuildContext context, FirebaseProjectInfo p) async {
    final state = context.read<AppState>();
    final project = state.activeProject;
    if (project == null) {
      showError(context, 'Choisissez d\'abord un projet BDDouilleur actif (onglet Projets).');
      return;
    }
    try {
      final conn = await state.connectFirebase(
          project, FirebaseTarget(mode: FirebaseMode.google, projectId: p.projectId),
          name: p.displayName);
      if (!context.mounted) return;
      await Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => FirebaseConnectionScreen(connection: conn)));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

/// Analyse en lecture seule d'un projet Firebase existant.
class ProjectAnalysisScreen extends StatefulWidget {
  const ProjectAnalysisScreen({super.key, required this.projectId, this.databaseId = '(default)', this.journalProjectId});
  final String projectId;
  final String databaseId;
  final int? journalProjectId;

  @override
  State<ProjectAnalysisScreen> createState() => _ProjectAnalysisScreenState();
}

class _ProjectAnalysisScreenState extends State<ProjectAnalysisScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Analyse de ${widget.projectId}')),
      body: ProjectAnalysisView(
          projectId: widget.projectId, databaseId: widget.databaseId, journalProjectId: widget.journalProjectId),
    );
  }
}

class ProjectAnalysisView extends StatefulWidget {
  const ProjectAnalysisView({super.key, required this.projectId, this.databaseId = '(default)', this.journalProjectId});
  final String projectId;
  final String databaseId;
  final int? journalProjectId;

  @override
  State<ProjectAnalysisView> createState() => _ProjectAnalysisViewState();
}

class _ProjectAnalysisViewState extends State<ProjectAnalysisView> {
  late var _future = _run();

  Future<List<DiagnosticFinding>> _run() async {
    final state = context.read<AppState>();
    final findings = await FirebaseProjectAnalyzer(state.googleApi())
        .analyze(widget.projectId, databaseId: widget.databaseId);
    state.journal.log(
      projectId: widget.journalProjectId,
      action: JournalAction.firebaseDiagnostic,
      summary: 'Analyse du projet Firebase « ${widget.projectId} » : '
          '${findings.where((f) => f.severity == DiagSeverity.error).length} bloquant(s), '
          '${findings.where((f) => f.severity == DiagSeverity.warning).length} à corriger',
    );
    return findings;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<DiagnosticFinding>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Interrogation des API Google…'),
          ]));
        }
        if (snap.hasError) return EmptyState(message: '${snap.error}');
        final findings = snap.data!;
        return RefreshIndicator(
          onRefresh: () async => setState(() { _future = _run(); }),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const MascotTip(
                  message: 'Analyse en lecture seule : rien n\'a été modifié. Chaque constat vient d\'une réponse réelle des API Google.'),
              const SizedBox(height: 12),
              FindingsSummary(findings),
              const SizedBox(height: 12),
              for (final f in findings) DiagnosticFindingCard(finding: f, projectId: widget.journalProjectId),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Relancer l\'analyse'),
                onPressed: () => setState(() { _future = _run(); }),
              ),
            ],
          ),
        );
      },
    );
  }
}
