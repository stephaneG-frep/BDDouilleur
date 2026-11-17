import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/firebase/firebase_autopilot.dart';
import '../../data/firebase/firebase_management.dart';
import '../../data/firebase/firestore_admin.dart';
import '../../domain/firebase/firebase_target.dart';
import '../../domain/models/db_engine.dart';
import '../../domain/models/journal_entry.dart';
import '../../state/app_state.dart';
import 'firebase_admin_views.dart';
import 'firebase_connection_screen.dart';

/// « Crée-moi un projet Firebase complet pour mon application Flutter. »
class AutoPilotWizardScreen extends StatefulWidget {
  const AutoPilotWizardScreen({super.key});

  @override
  State<AutoPilotWizardScreen> createState() => _AutoPilotWizardScreenState();
}

class _AutoPilotWizardScreenState extends State<AutoPilotWizardScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _id = TextEditingController();
  final _package = TextEditingController();
  bool _idEdited = false;
  String? _location = 'eur3';
  bool _email = true;
  AutoPilotResult? _result;
  bool _running = false;

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    _package.dispose();
    super.dispose();
  }

  static String suggestId(String name) {
    var s = name
        .toLowerCase()
        .replaceAll(RegExp('[àâä]'), 'a')
        .replaceAll(RegExp('[éèêë]'), 'e')
        .replaceAll(RegExp('[îï]'), 'i')
        .replaceAll(RegExp('[ôö]'), 'o')
        .replaceAll(RegExp('[ùûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp('^-+|-+\$'), '');
    if (s.isEmpty || !RegExp('^[a-z]').hasMatch(s)) s = 'app-$s';
    if (s.length > 30) s = s.substring(0, 30).replaceAll(RegExp(r'-+$'), '');
    while (s.length < 6) {
      s = '$s-app';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Projet Firebase complet')),
      body: _result == null && !_running ? _formView(context) : _progressView(context),
    );
  }

  Widget _formView(BuildContext context) {
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const MascotTip(
            message: '« Crée-moi un projet Firebase complet pour mon application Flutter. » '
                'Je passe par les API officielles, je vérifie l\'existant avant chaque étape et je ne recrée jamais '
                'ce qui existe déjà. Tout reste sur le plan Spark, gratuit : aucune facturation n\'est activée.',
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nom affiché du projet'),
            validator: (v) => (v ?? '').trim().length < 4 ? '4 caractères minimum.' : null,
            onChanged: (v) {
              if (!_idEdited) _id.text = suggestId(v);
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _id,
            decoration: const InputDecoration(
              labelText: 'Identifiant du projet',
              helperText: 'Unique dans tout Google Cloud et définitif. Un projet existant de votre compte sera réutilisé.',
              helperMaxLines: 2,
            ),
            onChanged: (_) => _idEdited = true,
            validator: (v) => FirebaseManagementService.validateProjectId(v ?? ''),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _package,
            decoration: const InputDecoration(
              labelText: 'Nom de paquet Android (facultatif)',
              hintText: 'fr.monentreprise.monapp',
              helperText: 'L\'applicationId de android/app/build.gradle. Permet de générer les fichiers FlutterFire.',
              helperMaxLines: 2,
            ),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? null : FirebaseManagementService.validatePackageName(v!),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: _location,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Région de Cloud Firestore', helperText: 'Définitive une fois la base créée.'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Ne pas créer de base Firestore')),
              for (final e in firestoreLocations.entries)
                DropdownMenuItem(value: e.key, child: Text('${e.value} (${e.key})', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _location = v),
          ),
          SwitchListTile(
            value: _email,
            onChanged: (v) => setState(() => _email = v),
            title: const Text('Authentication par e-mail / mot de passe'),
            subtitle: const Text('Avec protection contre l\'énumération des comptes.'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.rocket_launch_rounded),
            label: const Text('Préparer le lancement'),
            onPressed: () => _start(context),
          ),
        ],
      ),
    );
  }

  Widget _progressView(BuildContext context) {
    final r = _result;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (r != null)
          for (final s in r.steps)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: _statusIcon(s.status),
                title: Text(s.title),
                subtitle: s.detail == null ? null : SelectableText(s.detail!),
              ),
            ),
        if (_running) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
        if (!_running && r != null) ...[
          const SizedBox(height: 8),
          MascotTip(
            title: r.success ? 'Projet prêt' : 'Arrêt sur une étape',
            message: r.success
                ? 'Chaque ressource a été vérifiée chez Google. Le projet est connecté à votre projet BDDouilleur actif.'
                : 'Je me suis arrêté à l\'étape en échec, sans rien tenter d\'autre. Corrigez la cause indiquée puis '
                    'relancez : les étapes déjà réalisées seront simplement vérifiées.',
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (r.googleServicesJson != null)
              FilledButton.icon(
                icon: const Icon(Icons.file_download_rounded),
                label: const Text('Écrire les fichiers FlutterFire'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => FlutterFireExportDialog(
                    googleServicesJson: r.googleServicesJson!,
                    packageName: _package.text.trim(),
                    journalProjectId: context.read<AppState>().activeProject?.id,
                  ),
                ),
              ),
            if (r.success)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Ouvrir le projet'),
                onPressed: () => openFirebaseConnection(context, context.read<AppState>(), _id.text.trim()),
              ),
            OutlinedButton(
              onPressed: () => setState(() => _result = null),
              child: Text(r.success ? 'Nouveau projet' : 'Modifier et relancer'),
            ),
          ]),
        ],
      ],
    );
  }

  Widget _statusIcon(StepStatus s) => switch (s) {
        StepStatus.pending => const Icon(Icons.radio_button_unchecked),
        StepStatus.running => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        StepStatus.done => const Icon(Icons.check_circle_rounded, color: BddColors.vert),
        StepStatus.skipped => const Icon(Icons.task_alt_rounded, color: BddColors.turquoise),
        StepStatus.warning => const Icon(Icons.warning_amber_rounded, color: BddColors.orange),
        StepStatus.failed => const Icon(Icons.cancel_rounded, color: BddColors.rose),
      };

  Future<void> _start(BuildContext context) async {
    if (!_form.currentState!.validate()) return;
    final plan = FirebaseCreationPlan(
      projectId: _id.text.trim(),
      displayName: _name.text.trim(),
      packageName: _package.text.trim().isEmpty ? null : _package.text.trim(),
      firestoreLocation: _location,
      enableEmailAuth: _email,
    );
    final ok = await confirm(
      context,
      title: 'Lancer Firebase AutoPilot ?',
      message: 'Actions sur votre compte Google :\n\n${plan.describe().map((l) => '• $l').join('\n')}\n\n'
          'Aucune facturation n\'est activée. Chaque action est journalisée.',
      action: 'Lancer',
    );
    if (!ok || !context.mounted) return;
    final state = context.read<AppState>();
    final api = state.googleApi();
    final project = state.activeProject;
    setState(() => _running = true);
    final result = await FirebaseAutoPilot(api, onLog: (summary, request, {success = true, error}) {
      state.journal.log(
        projectId: project?.id,
        action: JournalAction.firebaseAutopilot,
        summary: summary,
        sql: request == null || request.startsWith('GET ') ? null : request,
        success: success,
        error: error,
      );
    }).run(plan, onProgress: (r) {
      if (mounted) setState(() => _result = r);
    });
    if (result.success && project != null) {
      final already = state.connections
          .forProject(project.id!)
          .any((c) => c.engine == DbEngine.firestore && c.location == plan.projectId && !c.firebase.isEmulator);
      if (!already) {
        try {
          await state.connectFirebase(project, FirebaseTarget(mode: FirebaseMode.google, projectId: plan.projectId),
              name: plan.displayName);
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      }
    }
    state.journal.log(
      projectId: project?.id,
      action: JournalAction.firebaseAutopilot,
      summary: 'AutoPilot « ${plan.projectId} » : ${result.success ? 'terminé, ressources vérifiées' : 'arrêté sur une étape en échec'}',
      success: result.success,
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
    });
  }
}

/// Ouvre l'espace de travail d'une connexion Firebase existante.
void openFirebaseConnection(BuildContext context, AppState state, String projectId) {
  final project = state.activeProject;
  if (project == null) return;
  final c = state.connections
      .forProject(project.id!)
      .where((c) => c.engine == DbEngine.firestore && c.location == projectId)
      .firstOrNull;
  if (c != null) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => FirebaseConnectionScreen(connection: c)));
  }
}
