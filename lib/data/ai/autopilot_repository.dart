import 'dart:convert';

import '../../domain/ai/ai_models.dart';
import '../../domain/autopilot/autopilot_plan.dart';
import '../persistence/app_database.dart';

class AutopilotRun {
  AutopilotRun({
    required this.id,
    required this.projectId,
    required this.goal,
    required this.provider,
    required this.model,
    required this.scope,
    required this.plan,
    required this.status,
    required this.checks,
    required this.rollback,
    this.report,
    required this.createdAt,
  });

  final int id;
  final int projectId;
  final String goal;
  final AiProviderKind provider;
  final String model;
  final List<int> scope;
  AutopilotPlan plan;
  RunStatus status;
  List<RunCheck> checks;
  RollbackInfo rollback;
  String? report;
  final DateTime createdAt;

  factory AutopilotRun.fromRow(Map<String, Object?> r) => AutopilotRun(
        id: r['id'] as int,
        projectId: r['project_id'] as int,
        goal: r['goal'] as String,
        provider: AiProviderKind.fromName(r['provider'] as String) ?? AiProviderKind.anthropic,
        model: r['model'] as String,
        scope: (jsonDecode(r['scope'] as String) as List).cast<int>(),
        plan: AutopilotPlan.fromJson((jsonDecode(r['plan'] as String) as Map).cast()),
        status: RunStatus.fromName(r['status'] as String),
        checks: [for (final c in jsonDecode(r['checks'] as String) as List) RunCheck.fromJson((c as Map).cast())],
        rollback: RollbackInfo.fromJson((jsonDecode(r['rollback'] as String) as Map).cast()),
        report: r['report'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );
}

/// Exécutions AutoPilot (plan, état, contrôles, retour arrière, rapport).
class AutopilotRepository {
  AutopilotRepository(this._app);
  final AppDatabase _app;

  List<AutopilotRun> forProject(int projectId) => _app.db
      .select('SELECT * FROM autopilot_runs WHERE project_id = ? ORDER BY updated_at DESC, id DESC', [projectId])
      .map(AutopilotRun.fromRow)
      .toList();

  AutopilotRun? byId(int id) {
    final r = _app.db.select('SELECT * FROM autopilot_runs WHERE id = ?', [id]);
    return r.isEmpty ? null : AutopilotRun.fromRow(r.first);
  }

  AutopilotRun create({
    required int projectId,
    required AiProviderKind provider,
    required String model,
    required List<int> scope,
    required AutopilotPlan plan,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _app.db.execute(
      'INSERT INTO autopilot_runs(project_id, goal, provider, model, scope, plan, status, created_at, updated_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [projectId, plan.goal, provider.name, model, jsonEncode(scope), jsonEncode(plan.toJson()), RunStatus.planned.name, now, now],
    );
    return byId(_app.db.lastInsertRowId)!;
  }

  void save(AutopilotRun run) => _app.db.execute(
        'UPDATE autopilot_runs SET plan = ?, status = ?, checks = ?, rollback = ?, report = ?, updated_at = ? WHERE id = ?',
        [
          jsonEncode(run.plan.toJson()),
          run.status.name,
          jsonEncode([for (final c in run.checks) c.toJson()]),
          jsonEncode(run.rollback.toJson()),
          run.report,
          DateTime.now().millisecondsSinceEpoch,
          run.id,
        ],
      );

  void delete(int id) => _app.db.execute('DELETE FROM autopilot_runs WHERE id = ?', [id]);
}
