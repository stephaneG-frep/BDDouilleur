import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../domain/models/db_engine.dart';
import '../firebase/firebase_hub_screen.dart';
import '../../state/app_state.dart';
import '../database/database_screen.dart';
import '../projects/projects_screen.dart';

/// La Fabrique : création d'une base de données.
class FabriqueScreen extends StatefulWidget {
  const FabriqueScreen({super.key, this.projectId});
  final int? projectId;

  @override
  State<FabriqueScreen> createState() => _FabriqueScreenState();
}

class _FabriqueScreenState extends State<FabriqueScreen> {
  final _name = TextEditingController();
  final _path = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  DbEngine _engine = DbEngine.sqlite;
  int? _projectId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _projectId = widget.projectId ?? context.read<AppState>().activeProject?.id;
  }

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    final state = context.read<AppState>();
    final project = state.projects.byId(_projectId!);
    if (project == null) return;
    setState(() => _busy = true);
    try {
      final conn = await state.createSqliteDatabase(project, _name.text);
      if (!mounted) return;
      showSuccess(context, 'Base « ${conn.name} » créée : ${conn.location}');
      await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => DatabaseScreen(connection: conn)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _attach() async {
    final state = context.read<AppState>();
    final project = state.projects.byId(_projectId!);
    if (project == null || _path.text.trim().isEmpty) {
      showError(context, 'Indiquez le chemin complet du fichier SQLite.');
      return;
    }
    setState(() => _busy = true);
    try {
      final conn = await state.attachSqliteFile(project, _path.text);
      if (!mounted) return;
      showSuccess(context, 'Base existante connectée.');
      await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => DatabaseScreen(connection: conn)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projects = state.projects.all();
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('La Fabrique')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const MascotTip(
                title: 'Fabriquons une base !',
                message: 'Choisissez un projet, un moteur et un nom. Je crée réellement le fichier de base de '
                    'données, puis vous pourrez y ajouter des tables et des enregistrements.',
              ),
              const SizedBox(height: 20),
              if (projects.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Text('Une base appartient toujours à un projet. Commencez par en créer un.'),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () async {
                            final p = await showProjectDialog(context);
                            if (p != null) setState(() => _projectId = p.id);
                          },
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Créer un projet'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('1. Projet', style: text.titleMedium),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int>(
                        initialValue: projects.any((p) => p.id == _projectId) ? _projectId : null,
                        decoration: const InputDecoration(labelText: 'Projet'),
                        items: [for (final p in projects) DropdownMenuItem(value: p.id, child: Text(p.name))],
                        onChanged: (v) => setState(() => _projectId = v),
                        validator: (v) => v == null ? 'Choisissez un projet.' : null,
                      ),
                      const SizedBox(height: 20),
                      Text('2. Moteur de base de données', style: text.titleMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final e in DbEngine.values)
                            Tooltip(
                              message: e.implemented ? e.description : '${e.description}\nDisponible en phase ${e.plannedPhase}.',
                              child: ChoiceChip(
                                label: Text(e.implemented ? e.label : '${e.label} · phase ${e.plannedPhase}'),
                                avatar: Icon(e.implemented ? Icons.check_circle_rounded : Icons.schedule_rounded, size: 18),
                                selected: _engine == e,
                                onSelected: e.implemented ? (_) => setState(() => _engine = e) : null,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(_engine.description, style: text.bodySmall),
                      const SizedBox(height: 20),
                      if (_engine == DbEngine.firestore) ...[
                        const MascotTip(
                          message: 'Une base Firestore vit dans un projet Firebase : je la crée avec Firebase AutoPilot '
                              '(sur votre compte Google) ou je me connecte à l\'émulateur local pour tester sans risque.',
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _projectId == null
                              ? null
                              : () {
                                  context.read<AppState>().setActiveProject(_projectId);
                                  Navigator.push(context, MaterialPageRoute(builder: (_) => const FirebaseHubScreen()));
                                },
                          icon: const Icon(Icons.local_fire_department_rounded),
                          label: const Text('Ouvrir Firebase AutoPilot'),
                        ),
                      ] else ...[
                      Text('3. Nom de la base', style: text.titleMedium),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: 'Nom', hintText: 'Ex. Catalogue produits'),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Le nom est obligatoire.' : null,
                        onFieldSubmitted: (_) => _create(),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _busy ? null : _create,
                        icon: _busy
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.precision_manufacturing_rounded),
                        label: const Text('Fabriquer la base'),
                      ),
                      ],
                      const SizedBox(height: 32),
                      const Divider(),
                      const SizedBox(height: 12),
                      Text('Ou connecter un fichier SQLite existant', style: text.titleMedium),
                      const SizedBox(height: 4),
                      Text('Le fichier est vérifié avant d\'être ajouté au projet. Il n\'est ni copié ni déplacé.',
                          style: text.bodySmall),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _path,
                        decoration: const InputDecoration(
                          labelText: 'Chemin complet du fichier',
                          hintText: '/home/moi/projet/donnees.db',
                          prefixIcon: Icon(Icons.insert_drive_file_outlined),
                        ),
                        style: AppTheme.mono,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _attach,
                        icon: const Icon(Icons.link_rounded),
                        label: const Text('Connecter ce fichier'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
