import 'autonomy.dart';

enum StepStatus {
  pending('À faire'),
  awaitingConfirmation('Confirmation demandée'),
  running('En cours'),
  succeeded('Réussie et vérifiée'),
  corrected('Corrigée puis réussie'),
  failed('Échec'),
  refused('Refusée par vous'),
  skipped('Non exécutée');

  const StepStatus(this.label);
  final String label;
}

enum RunStatus {
  planned('Plan prêt'),
  running('En cours'),
  succeeded('Terminé'),
  failed('Arrêté sur un échec'),
  cancelled('Interrompu'),
  rolledBack('Annulé (retour arrière)');

  const RunStatus(this.label);
  final String label;

  static RunStatus fromName(String? n) => RunStatus.values.where((s) => s.name == n).firstOrNull ?? RunStatus.planned;
}

/// Une étape du plan : une action typée (outil + arguments) et son contrôle.
class PlanStep {
  PlanStep({
    required this.title,
    required this.tool,
    required this.args,
    this.verification = '',
    this.risk = ActionRisk.read,
    this.needsConfirmation = false,
    this.status = StepStatus.pending,
    this.result,
    this.error,
    this.verified,
    this.autoApproved = false,
    this.corrections = const [],
    this.durationMs,
  });

  String title;
  String tool;
  Map<String, Object?> args;

  /// Ce qui sera contrôlé après l'exécution (énoncé par le planificateur).
  String verification;
  ActionRisk risk;
  bool needsConfirmation;
  StepStatus status;
  String? result;
  String? error;

  /// Résultat du contrôle réel effectué par BDDouilleur après l'exécution.
  String? verified;
  bool autoApproved;
  List<String> corrections;
  int? durationMs;

  Map<String, Object?> toJson() => {
        'title': title,
        'tool': tool,
        'args': args,
        'verification': verification,
        'risk': risk.name,
        'needsConfirmation': needsConfirmation,
        'status': status.name,
        'result': ?result,
        'error': ?error,
        'verified': ?verified,
        if (autoApproved) 'autoApproved': true,
        if (corrections.isNotEmpty) 'corrections': corrections,
        'durationMs': ?durationMs,
      };

  factory PlanStep.fromJson(Map<String, Object?> j) => PlanStep(
        title: '${j['title'] ?? ''}',
        tool: '${j['tool'] ?? ''}',
        args: ((j['args'] as Map?) ?? const {}).cast<String, Object?>(),
        verification: (j['verification'] as String?) ?? '',
        risk: ActionRisk.values.where((r) => r.name == j['risk']).firstOrNull ?? ActionRisk.read,
        needsConfirmation: j['needsConfirmation'] == true,
        status: StepStatus.values.where((s) => s.name == j['status']).firstOrNull ?? StepStatus.pending,
        result: j['result'] as String?,
        error: j['error'] as String?,
        verified: j['verified'] as String?,
        autoApproved: j['autoApproved'] == true,
        corrections: ((j['corrections'] as List?) ?? const []).cast<String>(),
        durationMs: (j['durationMs'] as num?)?.toInt(),
      );
}

class AutopilotPlan {
  AutopilotPlan({required this.goal, required this.summary, required this.steps, this.analysis = ''});
  final String goal;
  final String summary;

  /// Ce que le planificateur a compris du contexte.
  final String analysis;
  final List<PlanStep> steps;

  ActionRisk get maxRisk => steps.fold(ActionRisk.read, (m, s) => s.risk > m ? s.risk : m);

  Map<String, Object?> toJson() => {
        'goal': goal,
        'summary': summary,
        'analysis': analysis,
        'steps': [for (final s in steps) s.toJson()],
      };

  factory AutopilotPlan.fromJson(Map<String, Object?> j) => AutopilotPlan(
        goal: '${j['goal'] ?? ''}',
        summary: '${j['summary'] ?? ''}',
        analysis: '${j['analysis'] ?? ''}',
        steps: [for (final s in (j['steps'] as List?) ?? const []) PlanStep.fromJson((s as Map).cast())],
      );
}

/// Résultat d'un contrôle final (tests).
class RunCheck {
  const RunCheck(this.label, this.ok, [this.detail = '']);
  final String label;
  final bool ok;
  final String detail;

  Map<String, Object?> toJson() => {'label': label, 'ok': ok, 'detail': detail};
  factory RunCheck.fromJson(Map<String, Object?> j) => RunCheck('${j['label']}', j['ok'] == true, '${j['detail'] ?? ''}');
}

/// Ce qui permet le retour arrière d'une exécution.
class RollbackInfo {
  RollbackInfo({Map<int, String>? sqliteBackups, List<(int, String)>? firestoreCreated})
      : sqliteBackups = sqliteBackups ?? {},
        firestoreCreated = firestoreCreated ?? [];

  /// Base SQLite → sauvegarde prise avant la première modification.
  final Map<int, String> sqliteBackups;

  /// Documents Firestore créés (base, chemin), à supprimer en cas d'annulation.
  final List<(int, String)> firestoreCreated;

  bool get isEmpty => sqliteBackups.isEmpty && firestoreCreated.isEmpty;

  Map<String, Object?> toJson() => {
        'sqlite': {for (final e in sqliteBackups.entries) '${e.key}': e.value},
        'firestore': [for (final (c, path) in firestoreCreated) {'connection': c, 'path': path}],
      };

  factory RollbackInfo.fromJson(Map<String, Object?>? j) => RollbackInfo(
        sqliteBackups: {for (final e in ((j?['sqlite'] as Map?) ?? const {}).entries) int.parse('${e.key}'): '${e.value}'},
        firestoreCreated: [
          for (final f in (j?['firestore'] as List?) ?? const []) ((f as Map)['connection'] as int, f['path'] as String)
        ],
      );
}
