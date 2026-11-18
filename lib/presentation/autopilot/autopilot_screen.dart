import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/markdown_lite.dart';
import '../../core/widgets/mascot.dart';
import '../../data/ai/autopilot_repository.dart';
import '../../domain/ai/ai_models.dart';
import '../../domain/autopilot/autonomy.dart';
import '../../domain/autopilot/autopilot_plan.dart';
import '../../domain/models/project.dart';
import '../../state/agent_tools.dart';
import '../../state/app_state.dart';
import '../../state/autopilot_engine.dart';
import '../agent/ai_providers_screen.dart';

Color riskColor(ActionRisk r) => switch (r) {
      ActionRisk.read => BddColors.turquoise,
      ActionRisk.routine => BddColors.vert,
      ActionRisk.schema => BddColors.violet,
      ActionRisk.destructive => BddColors.rose,
      ActionRisk.sensitive => BddColors.rose,
    };

/// Module AutoPilot : historique des exécutions du projet actif.
class AutopilotScreen extends StatelessWidget {
  const AutopilotScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final project = state.activeProject;
    final runs = project == null ? <AutopilotRun>[] : state.autopilotRuns.forProject(project.id!);
    return Scaffold(
      appBar: AppBar(title: const Text('AutoPilot')),
      floatingActionButton: project == null
          ? null
          : FloatingActionButton.extended(
              heroTag: 'newrun',
              icon: const Icon(Icons.rocket_launch_rounded),
              label: const Text('Nouvel objectif'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AutopilotRunScreen())),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          GradientCard(
            colors: const [BddColors.violet, BddColors.orange],
            child: Row(children: [
              const Mascot(size: 72, animate: false),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Donnez un objectif : je prépare un plan d\'actions typées, vous l\'approuvez, puis je l\'exécute en contrôlant '
                  'chaque étape. Sauvegarde avant toute modification, tests à la fin, rapport détaillé et retour arrière possible. '
                  'Les actions destructives ou sensibles vous sont toujours soumises.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          if (project == null) const MascotTip(message: 'Choisissez d\'abord un projet actif (onglet Projets).'),
          if (project != null && runs.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Aucune exécution pour ce projet.')),
          for (final r in runs)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(_statusIcon(r.status), color: _statusColor(r.status)),
                title: Text(r.goal, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('${r.status.label} • ${r.plan.steps.length} étape(s) • ${formatDate(r.createdAt)}'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AutopilotRunScreen(runId: r.id))),
              ),
            ),
        ],
      ),
    );
  }
}

IconData _statusIcon(RunStatus s) => switch (s) {
      RunStatus.planned => Icons.pending_actions_rounded,
      RunStatus.running => Icons.play_circle_rounded,
      RunStatus.succeeded => Icons.verified_rounded,
      RunStatus.failed => Icons.error_rounded,
      RunStatus.cancelled => Icons.stop_circle_rounded,
      RunStatus.rolledBack => Icons.undo_rounded,
    };

Color _statusColor(RunStatus s) => switch (s) {
      RunStatus.succeeded => BddColors.vert,
      RunStatus.failed => BddColors.rose,
      RunStatus.rolledBack || RunStatus.cancelled => BddColors.orange,
      _ => BddColors.turquoise,
    };

enum _Phase { form, planning, review, executing, done }

/// Création, approbation, exécution et rapport d'une exécution AutoPilot.
class AutopilotRunScreen extends StatefulWidget {
  const AutopilotRunScreen({super.key, this.runId});
  final int? runId;

  @override
  State<AutopilotRunScreen> createState() => _AutopilotRunScreenState();
}

class _AutopilotRunScreenState extends State<AutopilotRunScreen> {
  final _goal = TextEditingController();
  _Phase _phase = _Phase.form;
  AiProviderKind? _provider;
  List<AiProviderKind> _available = [];
  final Set<int> _scope = {};
  final List<String> _thoughts = [];
  AutopilotRun? _run;
  String? _error;
  bool _cancel = false;

  AppState get _state => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    if (widget.runId != null) {
      _run = _state.autopilotRuns.byId(widget.runId!);
      _phase = switch (_run?.status) {
        RunStatus.planned => _Phase.review,
        null => _Phase.form,
        _ => _Phase.done,
      };
    }
    _loadProviders();
  }

  @override
  void dispose() {
    _goal.dispose();
    super.dispose();
  }

  Future<void> _loadProviders() async {
    final list = <AiProviderKind>[];
    for (final k in AiProviderKind.values) {
      if (_state.ai.model(k) != null && await _state.ai.hasKey(k)) list.add(k);
    }
    if (!mounted) return;
    setState(() {
      _available = list;
      _provider = list.contains(_state.ai.defaultProvider) ? _state.ai.defaultProvider : list.firstOrNull;
    });
  }

  Future<AutopilotEngine> _engine(AiProviderKind kind, Set<int> scope) async => AutopilotEngine(
        state: _state,
        project: _state.projects.byId(_state.activeProject!.id!)!,
        provider: await _state.providerFor(kind),
        model: _state.ai.model(kind)!,
        scope: scope,
      );

  Future<void> _plan() async {
    final project = _state.activeProject;
    if (project == null || _provider == null) return;
    if (_goal.text.trim().length < 5) return setState(() => _error = 'Décrivez l\'objectif.');
    if (_scope.isEmpty) return setState(() => _error = 'Choisissez au moins une base dans le périmètre.');
    setState(() {
      _phase = _Phase.planning;
      _error = null;
      _thoughts.clear();
    });
    try {
      final engine = await _engine(_provider!, _scope);
      final plan = await engine.plan(_goal.text.trim(), onMessage: (m) {
        if (m.role == AiRole.assistant) {
          if (mounted) {
            setState(() {
              if (m.text.trim().isNotEmpty) _thoughts.add(m.text.trim());
              for (final c in m.toolCalls) {
                _thoughts.add('→ ${c.name == 'submit_plan' ? 'Soumission du plan' : AgentToolbox.label(c)}');
              }
            });
          }
        } else if (m.role == AiRole.tool) {
          for (final r in m.toolResults.where((r) => r.isError)) {
            if (mounted) setState(() => _thoughts.add('✗ ${r.content.split('\n').take(4).join(' ')}'));
          }
        }
      });
      final run = _state.autopilotRuns.create(
          projectId: project.id!, provider: _provider!, model: _state.ai.model(_provider!)!, scope: _scope.toList(), plan: plan);
      setState(() {
        _run = run;
        _phase = _Phase.review;
      });
    } catch (e) {
      setState(() {
        _phase = _Phase.form;
        _error = '$e';
      });
    }
  }

  Future<bool> _confirmStep(PlanStep s) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.gpp_maybe_rounded, color: riskColor(s.risk), size: 36),
        title: Text('Confirmer : ${s.title}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              StatusChip(label: 'Action ${s.risk.label.toLowerCase()}', color: riskColor(s.risk), icon: Icons.speed_rounded),
              const SizedBox(height: 8),
              Text(s.risk.help),
              const SizedBox(height: 8),
              CodeBlock(const JsonEncoder.withIndent('  ').convert(s.args)),
              const SizedBox(height: 8),
              const Text('Un point de restauration a été créé avant l\'exécution. Si vous refusez, AutoPilot s\'arrête ici.'),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Refuser')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Autoriser')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _execute() async {
    final run = _run!;
    final ok = await confirm(context,
        title: 'Approuver et exécuter ?',
        message: '${run.plan.steps.length} étape(s) sur : ${run.scope.map((id) => _state.connections.byId(id)?.name ?? '#$id').join(', ')}.\n'
            '${run.plan.steps.where((s) => s.needsConfirmation).length} étape(s) vous seront soumises pendant l\'exécution.\n'
            'Un point de restauration est créé avant toute modification.',
        action: 'Exécuter');
    if (!ok || !mounted) return;
    setState(() {
      _phase = _Phase.executing;
      _cancel = false;
    });
    try {
      final engine = await _engine(run.provider, run.scope.toSet());
      await engine.execute(run, confirm: _confirmStep, cancelled: () => _cancel, onUpdate: () {
        if (mounted) setState(() {});
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => _phase = _Phase.done);
  }

  Future<void> _rollback() async {
    final run = _run!;
    final ok = await confirm(context,
        title: 'Annuler toute l\'exécution ?',
        message: 'Les bases SQLite concernées reviendront exactement à leur état d\'avant l\'exécution '
            '(les modifications faites depuis, par vous ou par l\'agent, seront aussi annulées ; l\'état actuel est sauvegardé).'
            '${run.rollback.firestoreCreated.isEmpty ? '' : '\n${run.rollback.firestoreCreated.length} document(s) Firestore créé(s) seront supprimés.'}',
        action: 'Retour arrière',
        danger: true);
    if (!ok || !mounted) return;
    try {
      final report = await AutopilotEngine.rollback(_state, run);
      if (mounted) {
        showSuccess(context, report.join(' '));
        setState(() {});
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = _state.activeProject;
    return PopScope(
      canPop: _phase != _Phase.executing && _phase != _Phase.planning,
      child: Scaffold(
        appBar: AppBar(title: Text(_run?.goal ?? 'Nouvel objectif AutoPilot', overflow: TextOverflow.ellipsis)),
        body: switch (_phase) {
          _Phase.form => _form(project),
          _Phase.planning => _planning(),
          _ => _runView(),
        },
      ),
    );
  }

  Widget _form(Project? project) {
    final conns = project == null ? <DbConnection>[] : _state.connections.forProject(project.id!);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_available.isEmpty)
          MascotTip(
            title: 'Aucun fournisseur d\'IA configuré',
            message: 'AutoPilot a besoin d\'un modèle pour planifier.',
          ),
        if (_available.isEmpty)
          FilledButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiProvidersScreen()))
                  .then((_) => _loadProviders()),
              child: const Text('Configurer un fournisseur')),
        TextField(
          controller: _goal,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Objectif',
            hintText: 'Ex. : Crée une table de rendez-vous liée aux clients, ajoute les index utiles et vérifie la base.',
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<AiProviderKind>(
          initialValue: _provider,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Modèle planificateur'),
          items: [for (final k in _available) DropdownMenuItem(value: k, child: Text('${k.label} — ${_state.ai.model(k)}'))],
          onChanged: (v) => setState(() => _provider = v),
        ),
        const SizedBox(height: 16),
        Text('Périmètre approuvé', style: Theme.of(context).textTheme.titleMedium),
        const Text('AutoPilot ne pourra agir que sur ces bases.'),
        for (final c in conns)
          CheckboxListTile(
            value: _scope.contains(c.id),
            onChanged: (v) => setState(() => v == true ? _scope.add(c.id!) : _scope.remove(c.id)),
            title: Text(c.name),
            subtitle: Text(c.engine.label),
            secondary: const Icon(Icons.storage_rounded),
          ),
        if (conns.isEmpty) const Text('Ce projet n\'a pas encore de base : créez-en une avec La Fabrique.'),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: BddColors.rose))),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.psychology_rounded),
          label: const Text('Préparer le plan'),
          onPressed: _available.isEmpty || conns.isEmpty ? null : _plan,
        ),
      ],
    );
  }

  Widget _planning() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Row(children: [
            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Expanded(child: Text('Analyse du contexte et préparation du plan… Rien n\'est modifié pendant cette étape.')),
          ]),
          const SizedBox(height: 16),
          for (final t in _thoughts) Padding(padding: const EdgeInsets.only(bottom: 8), child: MarkdownLite(t)),
        ],
      );

  Widget _runView() {
    final run = _run!;
    final text = Theme.of(context).textTheme;
    final executing = _phase == _Phase.executing;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          StatusChip(label: run.status.label, color: _statusColor(run.status), icon: _statusIcon(run.status)),
          StatusChip(label: '${run.provider.label} • ${run.model}', color: BddColors.violet),
          StatusChip(label: 'Risque max : ${run.plan.maxRisk.label}', color: riskColor(run.plan.maxRisk)),
        ]),
        const SizedBox(height: 12),
        Text('Plan', style: text.titleLarge),
        if (run.plan.summary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(run.plan.summary)),
        if (run.plan.analysis.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Analyse du planificateur'),
            children: [MarkdownLite(run.plan.analysis)],
          ),
        const SizedBox(height: 8),
        for (final (i, s) in run.plan.steps.indexed) _StepTile(index: i, step: s),
        const SizedBox(height: 12),
        if (_phase == _Phase.review) ...[
          const MascotTip(
              message: 'Vérifiez le plan. En l\'approuvant, vous autorisez les étapes non sensibles du périmètre ; '
                  'les étapes marquées « confirmation » vous seront soumises une par une.'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(icon: const Icon(Icons.play_arrow_rounded), label: const Text('Approuver et exécuter'), onPressed: _execute),
            OutlinedButton(
              onPressed: () {
                _state.autopilotRuns.delete(run.id);
                _state.refresh();
                Navigator.pop(context);
              },
              child: const Text('Abandonner ce plan'),
            ),
          ]),
        ],
        if (executing)
          Row(children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            const Expanded(child: Text('Exécution contrôlée en cours…')),
            TextButton(onPressed: () => setState(() => _cancel = true), child: const Text('Arrêter après l\'étape en cours')),
          ]),
        if (_phase == _Phase.done && run.report != null) ...[
          const Divider(height: 32),
          Text('Rapport', style: text.titleLarge),
          const SizedBox(height: 8),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: MarkdownLite(run.report!))),
          for (final c in run.checks.where((c) => !c.ok))
            Padding(padding: const EdgeInsets.only(top: 8), child: CodeBlock('${c.label}\n${c.detail}')),
          const SizedBox(height: 12),
          if (!run.rollback.isEmpty && run.status != RunStatus.rolledBack)
            OutlinedButton.icon(
              icon: const Icon(Icons.undo_rounded),
              label: const Text('Annuler toute l\'exécution (retour arrière)'),
              style: OutlinedButton.styleFrom(foregroundColor: BddColors.rose),
              onPressed: _rollback,
            ),
        ],
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.index, required this.step});
  final int index;
  final PlanStep step;

  @override
  Widget build(BuildContext context) {
    final s = step;
    final (icon, color) = switch (s.status) {
      StepStatus.pending => (Icons.radio_button_unchecked, Theme.of(context).colorScheme.outline),
      StepStatus.awaitingConfirmation => (Icons.front_hand_rounded, BddColors.orange),
      StepStatus.running => (Icons.hourglass_top_rounded, BddColors.turquoise),
      StepStatus.succeeded => (Icons.check_circle_rounded, BddColors.vert),
      StepStatus.corrected => (Icons.healing_rounded, BddColors.vert),
      StepStatus.failed => (Icons.cancel_rounded, BddColors.rose),
      StepStatus.refused => (Icons.block_rounded, BddColors.orange),
      StepStatus.skipped => (Icons.remove_circle_outline_rounded, Theme.of(context).colorScheme.outline),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ExpansionTile(
        shape: const Border(),
        leading: Icon(icon, color: color),
        title: Text('${index + 1}. ${s.title}'),
        subtitle: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusChip(label: s.risk.label, color: riskColor(s.risk)),
          if (s.needsConfirmation) const StatusChip(label: 'confirmation', color: BddColors.orange, icon: Icons.front_hand_rounded),
          Text(s.status.label, style: TextStyle(color: color, fontSize: 12)),
        ]),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Outil : ${AgentToolbox.label(AiToolCall(id: '', name: s.tool, arguments: const {}))}'),
          CodeBlock(const JsonEncoder.withIndent('  ').convert(s.args)),
          if (s.verification.isNotEmpty) Text('Contrôle prévu : ${s.verification}'),
          if (s.verified != null) Text('Contrôle réel : ${s.verified}', style: const TextStyle(color: BddColors.vert)),
          if (s.error != null) Text('Erreur : ${s.error}', style: const TextStyle(color: BddColors.rose)),
          for (final c in s.corrections) Text(c, style: const TextStyle(fontStyle: FontStyle.italic)),
          if (s.durationMs != null) Text('${s.durationMs} ms', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
