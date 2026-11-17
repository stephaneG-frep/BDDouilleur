import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/common.dart';
import '../../data/firebase/firebase_diagnostic.dart';
import '../../data/firebase/firebase_management.dart';
import '../../domain/models/db_engine.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../state/app_state.dart';
import 'firebase_widgets.dart';

/// Firebase Rescue : « Pourquoi Firebase ne fonctionne pas dans mon application ? »
class RescueScreen extends StatefulWidget {
  const RescueScreen({super.key});

  @override
  State<RescueScreen> createState() => _RescueScreenState();
}

class _RescueScreenState extends State<RescueScreen> {
  final _form = GlobalKey<FormState>();
  final _dir = TextEditingController();
  DbConnection? _remote;
  List<DiagnosticFinding>? _findings;
  bool _running = false;

  @override
  void dispose() {
    _dir.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final project = state.activeProject;
    final googleConns = project == null
        ? <DbConnection>[]
        : state.connections
            .forProject(project.id!)
            .where((c) => c.engine == DbEngine.firestore && !c.firebase.isEmulator)
            .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Firebase Rescue')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const MascotTip(
              title: 'Pourquoi Firebase ne fonctionne pas dans mon application ?',
              message: 'Je lis les fichiers de votre projet Flutter (pubspec, main.dart, configuration Android, '
                  'firebase_options, règles) et je classe chaque constat : Problème, Cause, Solution, Risque, '
                  'Correction, Vérification. Je ne modifie rien sans votre accord, et je garde une copie .bak.',
            ),
            const SizedBox(height: 16),
            FolderField(
              controller: _dir,
              label: 'Dossier du projet Flutter',
              helper: 'Racine contenant pubspec.yaml.',
              validator: validateFlutterProject,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<DbConnection?>(
              initialValue: _remote,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Projet Firebase attendu (facultatif)',
                helperText: 'Permet de vérifier la correspondance et de générer les fichiers manquants.',
                helperMaxLines: 2,
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('Aucun')),
                for (final c in googleConns) DropdownMenuItem(value: c, child: Text('${c.name} (${c.location})')),
              ],
              onChanged: (v) => setState(() => _remote = v),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: _running
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.troubleshoot_rounded),
              label: const Text('Diagnostiquer'),
              onPressed: _running ? null : _run,
            ),
            if (_findings != null) ...[
              const SizedBox(height: 16),
              FindingsSummary(_findings!),
              const SizedBox(height: 12),
              for (final f in _findings!)
                DiagnosticFindingCard(finding: f, projectId: project?.id, onFixed: _run),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _run() async {
    if (!_form.currentState!.validate()) return;
    final state = context.read<AppState>();
    final remote = _remote;
    setState(() => _running = true);
    try {
      final diag = FlutterFirebaseDiagnostic(
        _dir.text.trim(),
        expectedProjectId: remote?.location,
        remoteConfig: remote == null
            ? null
            : (pkg) async {
                final mgmt = FirebaseManagementService(state.googleApi());
                final app = (await mgmt.listAndroidApps(remote.location)).where((a) => a.packageName == pkg).firstOrNull;
                return app == null ? null : mgmt.androidConfigFile(remote.location, app.appId);
              },
      );
      final findings = await diag.run();
      state.journal.log(
        projectId: state.activeProject?.id,
        action: JournalAction.firebaseDiagnostic,
        summary: 'Firebase Rescue sur ${_dir.text.trim()} : '
            '${findings.where((f) => f.severity == DiagSeverity.error).length} bloquant(s), '
            '${findings.where((f) => f.severity == DiagSeverity.warning).length} à corriger',
      );
      if (mounted) setState(() => _findings = findings);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}
