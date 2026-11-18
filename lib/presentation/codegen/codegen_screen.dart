import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/codegen/code_integrator.dart';
import '../../data/codegen/flutter_codegen.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/schema_proposal.dart';
import '../../domain/text_diff.dart';
import '../../state/app_state.dart';
import '../firebase/firebase_widgets.dart';

/// Le Connecteur : génération et intégration du code Flutter, avec plan,
/// différences, point de restauration et vérification réelle.
class CodegenScreen extends StatefulWidget {
  const CodegenScreen({super.key, required this.proposal, this.initialFolder, this.backend = CodegenBackend.sqlite});
  final SchemaProposal proposal;
  final String? initialFolder;
  final CodegenBackend backend;

  @override
  State<CodegenScreen> createState() => _CodegenScreenState();
}

class _CodegenScreenState extends State<CodegenScreen> {
  final _form = GlobalKey<FormState>();
  late final _folder = TextEditingController(text: widget.initialFolder ?? '');
  late CodegenBackend _backend = widget.backend;
  CodegenPlan? _plan;
  bool _tools = false;
  bool _addDeps = true;
  bool _busy = false;
  String? _status;
  IntegrationResult? _applied;
  VerificationResult? _verification;
  List<RestorePoint> _restorePoints = const [];

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  CodeIntegrator get _integrator => context.read<AppState>().codeIntegrator;

  Future<void> _computePlan() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _status = 'Calcul du plan…';
      _plan = null;
      _applied = null;
      _verification = null;
    });
    try {
      final dir = _folder.text.trim();
      final plan = FlutterCodeGenerator(widget.proposal, _backend).plan(dir);
      final tools = await _integrator.toolsAvailable(dir);
      setState(() {
        _plan = plan;
        _tools = tools;
        _restorePoints = _integrator.restorePoints(dir);
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<void> _apply() async {
    final plan = _plan!;
    final newCount = plan.files.where((f) => f.isNew).length;
    final modCount = plan.files.length - newCount;
    final deps = [...plan.missingDependencies, ...plan.missingDevDependencies];
    final ok = await confirm(
      context,
      title: 'Intégrer le code ?',
      message: '$newCount fichier(s) créé(s), $modCount modifié(s) dans ${plan.projectDir}.\n'
          '${modCount > 0 ? 'Les versions actuelles sont sauvegardées avant écriture.\n' : ''}'
          '${deps.isEmpty ? '' : _addDeps && _tools ? 'Dépendances ajoutées avec flutter pub add : ${deps.join(', ')}.\n' : 'Dépendances à ajouter vous-même : ${deps.join(', ')}.\n'}'
          'Un point de restauration permet de tout annuler.',
      action: 'Intégrer',
    );
    if (!ok || !mounted) return;
    final state = context.read<AppState>();
    setState(() {
      _busy = true;
      _status = 'Écriture des fichiers…';
    });
    try {
      final applied = await _integrator.apply(plan, addDependencies: _addDeps && _tools);
      state.journal.log(
        projectId: state.activeProject?.id,
        action: JournalAction.codeGenerated,
        summary: 'Code Flutter (${plan.backend.label}) intégré dans ${plan.projectDir} : ${applied.written.length} fichier(s). '
            'Point de restauration ${applied.restoreId}',
        success: applied.ok,
        error: applied.ok ? null : applied.commands.where((c) => !c.ok).map((c) => '${c.command}\n${c.output}').join('\n'),
      );
      setState(() {
        _applied = applied;
        _status = 'Vérification (analyse statique et tests)…';
      });
      final verification = applied.ok ? await _integrator.verify(plan) : VerificationResult(applied.commands);
      state.journal.log(
        projectId: state.activeProject?.id,
        action: JournalAction.codeGenerated,
        summary: verification.ok == null
            ? 'Vérification du code généré impossible ici (outils Flutter absents)'
            : 'Vérification du code généré : ${verification.ok! ? 'analyse et tests réussis' : 'ÉCHEC'}',
        success: verification.ok ?? true,
        error: verification.ok == false ? verification.steps.where((s) => !s.ok).map((s) => s.command).join(', ') : null,
      );
      setState(() {
        _verification = verification;
        _restorePoints = _integrator.restorePoints(plan.projectDir);
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<void> _restore(RestorePoint r) async {
    final ok = await confirm(context,
        title: 'Annuler cette intégration ?',
        message: '${r.created.length} fichier(s) créé(s) seront supprimés et ${r.modified.length} restauré(s) dans leur version d\'origine.',
        action: 'Annuler l\'intégration',
        danger: true);
    if (!ok || !mounted) return;
    final state = context.read<AppState>();
    try {
      final report = await _integrator.restore(_folder.text.trim(), r.id);
      state.journal.log(
          projectId: state.activeProject?.id,
          action: JournalAction.codeRestored,
          summary: 'Intégration ${r.id} annulée dans ${_folder.text.trim()}\n${report.join('\n')}');
      if (!mounted) return;
      showSuccess(context, 'Intégration annulée.');
      setState(() {
        _applied = null;
        _verification = null;
        _plan = null;
        _restorePoints = _integrator.restorePoints(_folder.text.trim());
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Le Connecteur — code Flutter')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const MascotTip(
              message: 'Je génère modèles, dépôts, services et tests pour votre projet Flutter, en respectant son '
                  'organisation. Rien n\'est écrit sans votre accord : vous voyez d\'abord le plan et les différences, '
                  'les fichiers existants sont sauvegardés, et je vérifie le résultat (analyse et tests).',
            ),
            const SizedBox(height: 12),
            Text('${widget.proposal.entities.length} entité(s) : ${widget.proposal.entities.map((e) => e.name).join(', ')}'),
            const SizedBox(height: 12),
            SegmentedButton<CodegenBackend>(
              segments: [for (final b in CodegenBackend.values) ButtonSegment(value: b, label: Text(b.label))],
              selected: {_backend},
              onSelectionChanged: _busy ? null : (s) => setState(() {
                _backend = s.single;
                _plan = null;
              }),
            ),
            const SizedBox(height: 12),
            FolderField(controller: _folder, label: 'Dossier du projet Flutter', validator: validateFlutterProject),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.fact_check_rounded),
              label: const Text('Calculer le plan'),
              onPressed: _busy ? null : _computePlan,
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Row(children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(_status!)
              ]),
            ],
            if (_plan != null) ...[
              const SizedBox(height: 20),
              Text('Plan', style: text.titleLarge),
              for (final n in _plan!.notes) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $n')),
              if (_plan!.missingDependencies.isNotEmpty || _plan!.missingDevDependencies.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Dépendances manquantes : ${[..._plan!.missingDependencies, ..._plan!.missingDevDependencies.map((d) => '$d (dev)')].join(', ')}'),
                if (_tools)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _addDeps,
                    onChanged: (v) => setState(() => _addDeps = v ?? false),
                    title: const Text('Les ajouter avec flutter pub add (pubspec.yaml sauvegardé avant)'),
                  )
                else
                  const Text('Outils Flutter indisponibles ici : ajoutez-les vous-même (flutter pub add …).',
                      style: TextStyle(fontStyle: FontStyle.italic)),
              ],
              const SizedBox(height: 8),
              for (final f in _plan!.files) _FileTile(file: f),
              const SizedBox(height: 12),
              if (_applied == null)
                FilledButton.icon(
                  icon: const Icon(Icons.download_done_rounded),
                  label: Text('Intégrer ${_plan!.files.length} fichier(s)'),
                  onPressed: _busy || _plan!.files.isEmpty ? null : _apply,
                ),
            ],
            if (_applied != null) ...[
              const SizedBox(height: 20),
              Text('Résultat', style: text.titleLarge),
              Text('${_applied!.written.length} fichier(s) écrit(s). Point de restauration : ${_applied!.restoreId}'),
              for (final c in _applied!.commands) _CommandTile(c),
              if (_verification != null) ...[
                const SizedBox(height: 8),
                if (_verification!.ok == null)
                  const MascotTip(
                      message: 'Vérification impossible sur cet appareil (outils Flutter absents). Lancez « flutter analyze » '
                          'et « flutter test » sur votre PC : le code n\'est pas considéré comme vérifié.')
                else ...[
                  StatusChip(
                    label: _verification!.ok! ? 'Analyse et tests réussis' : 'Vérification en échec',
                    color: _verification!.ok! ? BddColors.vert : BddColors.rose,
                    icon: _verification!.ok! ? Icons.verified_rounded : Icons.error_rounded,
                  ),
                  for (final s in _verification!.steps) _CommandTile(s),
                ],
              ],
            ],
            if (_restorePoints.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Points de restauration de ce projet', style: text.titleMedium),
              for (final r in _restorePoints)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history_rounded),
                  title: Text(formatDate(r.date)),
                  subtitle: Text('${r.created.length} créé(s), ${r.modified.length} sauvegardé(s)'),
                  trailing: TextButton(onPressed: _busy ? null : () => _restore(r), child: const Text('Annuler')),
                ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.file});
  final PlannedFile file;

  @override
  Widget build(BuildContext context) {
    final (added, removed) = TextDiff.stats(file.previous ?? '', file.content);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ExpansionTile(
        shape: const Border(),
        leading: Icon(file.isNew ? Icons.note_add_rounded : Icons.edit_document,
            color: file.isNew ? BddColors.vert : BddColors.orange),
        title: Text(file.path, style: AppTheme.mono.copyWith(fontSize: 13)),
        subtitle: Text('${file.purpose} • ${file.isNew ? 'nouveau' : 'modifié'} • +$added −$removed'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [CodeBlock(file.isNew ? file.content : TextDiff.unified(file.previous!, file.content))],
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile(this.c);
  final CommandResult c;

  @override
  Widget build(BuildContext context) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading: Icon(c.ok ? Icons.check_circle_rounded : Icons.cancel_rounded, color: c.ok ? BddColors.vert : BddColors.rose),
        title: Text(c.command, style: AppTheme.mono.copyWith(fontSize: 12)),
        children: [CodeBlock(c.output.isEmpty ? '(aucune sortie)' : c.output)],
      );
}
