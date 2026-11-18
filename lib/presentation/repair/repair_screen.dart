import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/firebase/firebase_diagnostic.dart' show DiagSeverity;
import '../../data/repair/sqlite_doctor.dart';
import '../../domain/autopilot/autonomy.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../state/agent_tools.dart';
import '../../state/app_state.dart';
import '../autopilot/autopilot_screen.dart' show riskColor;
import '../firebase/firebase_widgets.dart' show severityColor, severityIcon;

/// Le Réparateur : diagnostic d'une base SQLite et corrections avec
/// estimation du risque (point de restauration avant toute modification).
class RepairScreen extends StatefulWidget {
  const RepairScreen({super.key, required this.connection});
  final DbConnection connection;

  @override
  State<RepairScreen> createState() => _RepairScreenState();
}

class _RepairScreenState extends State<RepairScreen> {
  List<RepairFinding>? _findings;
  List<RepairFinding>? _queryFindings;
  List<Object?>? _queryPlan;
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final _resultsKey = GlobalKey();
  bool _busy = false;
  String? _error;

  AppState get _state => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run({bool manual = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final pre = SqliteDoctor.connectionCheck(widget.connection.location);
    try {
      if (pre.any((f) => f.severity == DiagSeverity.error)) {
        setState(() => _findings = pre);
        return;
      }
      final doctor = await AgentToolbox.doctorFor(_state, widget.connection);
      final findings = [...pre, ...await doctor.run()];
      _state.journal.log(
        projectId: widget.connection.projectId,
        connectionId: widget.connection.id,
        action: JournalAction.integrityChecked,
        summary: 'Le Réparateur : ${findings.where((f) => f.severity == DiagSeverity.error).length} problème(s) bloquant(s), '
            '${findings.where((f) => f.severity == DiagSeverity.warning).length} à corriger',
      );
      setState(() => _findings = findings);
      if (manual && mounted) {
        final problems = findings.where((f) => f.severity == DiagSeverity.error || f.severity == DiagSeverity.warning).length;
        showSuccess(context, problems == 0
            ? 'Diagnostic relancé : aucun problème détecté.'
            : 'Diagnostic relancé : $problems problème(s) à traiter sur ${findings.length} constat(s).');
      }
    } catch (e) {
      setState(() {
        _findings = pre;
        _error = '$e';
      });
      if (manual && mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _analyzeQuery() async {
    final sql = _query.text.trim();
    FocusScope.of(context).unfocus();
    if (sql.isEmpty) {
      showError(context, 'Saisissez d\'abord une requête SQL à analyser (ex. SELECT * FROM clients WHERE ville = \'Paris\').');
      return;
    }
    try {
      final db = await _state.connectorFor(widget.connection);
      final findings = await SqliteDoctor(db, connectionId: widget.connection.id!).analyzeQuery(sql);
      List<Object?>? plan;
      try {
        plan = [for (final r in await db.select('EXPLAIN QUERY PLAN ${sql.replaceAll(RegExp(r';\s*$'), '')}')) r['detail']];
      } catch (_) {}
      setState(() {
        _queryFindings = findings;
        _queryPlan = plan;
      });
      if (!mounted) return;
      showSuccess(
          context,
          findings.isEmpty
              ? 'Plan calculé : aucun problème de performance pour cette requête.'
              : '${findings.length} constat(s) pour cette requête : voir ci-dessous.');
      // Fait défiler jusqu'au résultat (souvent sous le clavier sur téléphone).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _resultsKey.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300));
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _apply(RepairFinding f) async {
    final action = f.action!;
    final destructive = f.risk.index >= ActionRisk.destructive.index;
    final ok = await confirm(context,
        title: action.description,
        message: 'Risque : ${f.risk.label}. ${f.riskDetail}\n\n'
            '${destructive ? 'Un point de restauration de la base est créé avant l\'opération.\n\n' : ''}'
            'Opération exacte :\n${const JsonEncoder.withIndent('  ').convert(action.args)}',
        action: 'Appliquer',
        danger: destructive);
    if (!ok || !mounted) return;
    final project = _state.projects.byId(widget.connection.projectId)!;
    final box = AgentToolbox(AgentContext(state: _state, project: project, connectionId: widget.connection.id));
    final tool = box.tools().firstWhere((t) => t.name == action.tool);
    try {
      final problems = tool.validate?.call(action.args) ?? const [];
      if (problems.isNotEmpty) throw StateError(problems.join(' '));
      await tool.run(action.args);
      _state.journal.log(
        projectId: widget.connection.projectId,
        connectionId: widget.connection.id,
        action: JournalAction.repairApplied,
        summary: 'Le Réparateur : ${action.description} (risque ${f.risk.label.toLowerCase()})',
      );
      if (mounted) showSuccess(context, 'Correction appliquée. Nouveau diagnostic pour vérification…');
      await _run();
    } catch (e) {
      _state.journal.log(
        projectId: widget.connection.projectId,
        connectionId: widget.connection.id,
        action: JournalAction.repairApplied,
        summary: 'Le Réparateur : ${action.description}',
        success: false,
        error: '$e',
      );
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final findings = _findings;
    return Scaffold(
      appBar: AppBar(
        title: Text('Le Réparateur — ${widget.connection.name}'),
        actions: [IconButton(tooltip: 'Relancer le diagnostic', icon: const Icon(Icons.refresh_rounded), onPressed: _busy ? null : () => _run(manual: true))],
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        children: [
          const MascotTip(
            message: 'Diagnostic en lecture seule : intégrité, contraintes violées, migrations incomplètes, index absents, '
                'requêtes lentes ou incorrectes, configuration. Chaque correction indique son risque ; une sauvegarde est faite '
                'avant toute modification des données.',
          ),
          const SizedBox(height: 12),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: const TextStyle(color: BddColors.rose)),
          if (findings != null) ...[
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in DiagSeverity.values)
                if (findings.any((f) => f.severity == s))
                  StatusChip(
                    label: '${findings.where((f) => f.severity == s).length} ${s.label.toLowerCase()}',
                    color: severityColor(s),
                    icon: severityIcon(s),
                  ),
            ]),
            const SizedBox(height: 12),
            for (final f in findings) _FindingCard(finding: f, onApply: f.action == null || _busy ? null : () => _apply(f)),
          ],
          const SizedBox(height: 20),
          Text('Analyser une requête', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _query,
            minLines: 2,
            maxLines: 6,
            style: AppTheme.mono,
            decoration: const InputDecoration(hintText: 'SELECT * FROM clients WHERE ville = \'Paris\''),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(icon: const Icon(Icons.query_stats_rounded), label: const Text('Plan d\'exécution'), onPressed: _analyzeQuery),
          SizedBox(key: _resultsKey, height: 1),
          if (_queryPlan != null) ...[
            const SizedBox(height: 8),
            Text('Plan d\'exécution', style: Theme.of(context).textTheme.titleSmall),
            CodeBlock(_queryPlan!.isEmpty ? '(aucune étape)' : _queryPlan!.join('\n')),
          ],
          if (_queryFindings != null && _queryFindings!.isEmpty)
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('Aucun problème de performance détecté pour cette requête.')),
          for (final f in _queryFindings ?? const <RepairFinding>[]) _FindingCard(finding: f, onApply: f.action == null ? null : () => _apply(f)),
          const SizedBox(height: 300),
        ],
      ),
    );
  }
}

class _FindingCard extends StatelessWidget {
  const _FindingCard({required this.finding, this.onApply});
  final RepairFinding finding;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    final f = finding;
    final color = severityColor(f.severity);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        initiallyExpanded: f.severity == DiagSeverity.error,
        leading: Icon(severityIcon(f.severity), color: color),
        title: Text(f.problem),
        subtitle: Text(f.severity.label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (f.cause.isNotEmpty) ...[const Text('Cause', style: TextStyle(fontWeight: FontWeight.w600)), SelectableText(f.cause)],
          if (f.solution.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text('Solution', style: TextStyle(fontWeight: FontWeight.w600)),
            Text(f.solution)
          ],
          if (f.action != null || f.risk != ActionRisk.read) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              StatusChip(label: 'Risque : ${f.risk.label}', color: riskColor(f.risk), icon: Icons.speed_rounded),
              if (f.riskDetail.isNotEmpty) Text(f.riskDetail, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ],
          if (f.verification.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Vérification : ${f.verification}', style: Theme.of(context).textTheme.bodySmall),
          ],
          if (f.action != null) ...[
            const SizedBox(height: 10),
            FilledButton.icon(icon: const Icon(Icons.build_rounded), label: Text(f.action!.description), onPressed: onApply),
          ],
        ],
      ),
    );
  }
}
