import 'dart:convert';
import 'dart:io';

import '../data/ai/agent.dart';
import '../data/ai/ai_providers.dart';
import '../data/ai/autopilot_repository.dart';
import '../data/backup/sqlite_backup_service.dart';
import '../domain/ai/ai_models.dart';
import '../domain/autopilot/autonomy.dart';
import '../domain/autopilot/autopilot_plan.dart';
import '../domain/models/db_engine.dart';
import '../domain/models/journal_entry.dart';
import '../domain/models/project.dart';
import '../domain/schema_proposal.dart';
import 'agent_tools.dart';
import 'app_state.dart';

/// Moteur AutoPilot : l'IA comprend l'objectif et prépare un plan d'actions
/// typées ; BDDouilleur le valide, l'exécute lui-même (jamais le modèle),
/// contrôle chaque résultat, corrige ce qui est récupérable, teste, rend
/// compte, et sait tout annuler.
class AutopilotEngine {
  AutopilotEngine({
    required this.state,
    required this.project,
    required this.provider,
    required this.model,
    required this.scope,
    this.folder,
    this.maxCorrections = 2,
  }) : box = AgentToolbox(AgentContext(
          state: state,
          project: project,
          folder: folder,
          connectionId: scope.length == 1 ? scope.first : null,
          mode: AutonomyMode.autopilot,
          scopeConnectionIds: scope,
        ));

  final AppState state;
  final Project project;
  final AiProvider provider;
  final String model;

  /// Bases du périmètre approuvé.
  final Set<int> scope;
  final String? folder;
  final int maxCorrections;
  final AgentToolbox box;

  /// Outils d'affichage : réservés à la conversation, pas aux plans.
  static const _uiOnly = {'propose_schema', 'plan_flutter_code'};

  late final Map<String, AgentTool> _tools = {for (final t in box.tools()) t.name: t};

  List<AgentTool> get _readTools => [for (final t in _tools.values) if (!t.mutating && !_uiOnly.contains(t.name)) t];

  Iterable<String> get allowedSteps => _tools.keys.where((n) => !_uiOnly.contains(n));

  String _scopeText() => [
        for (final id in scope)
          () {
            final c = state.connections.byId(id);
            return c == null ? '#$id' : '#$id ${c.name} (${c.engine.label})';
          }()
      ].join(', ');

  // ================================================================ PLAN

  /// Contrôle une étape proposée ; renvoie les problèmes (vide si valide).
  List<String> _checkStep(PlanStep s) {
    final t = _tools[s.tool];
    if (t == null || _uiOnly.contains(s.tool)) return ['Étape « ${s.title} » : outil « ${s.tool} » non autorisé.'];
    final problems = [for (final p in t.validate?.call(s.args) ?? const <String>[]) 'Étape « ${s.title} » : $p'];
    if (!box.inScope(t, s.args)) problems.add('Étape « ${s.title} » : base hors du périmètre approuvé (${_scopeText()}).');
    if (problems.isNotEmpty) {
      // Le modèle reçoit le format exact attendu pour pouvoir se corriger.
      problems.add('Arguments attendus pour « ${s.tool} » (schéma JSON) : ${jsonEncode(t.spec.parameters)}');
    }
    return problems;
  }

  void _classify(PlanStep s) {
    final t = _tools[s.tool]!;
    s.risk = t.risk(s.args);
    s.needsConfirmation = t.mutating && ActionPolicy.requiresConfirmation(AutonomyMode.autopilot, s.risk, inScope: box.inScope(t, s.args));
  }

  static PlanStep _stepFrom(Map<String, Object?> j) {
    final args = Map<String, Object?>.of(((j['args'] as Map?) ?? const {}).cast<String, Object?>());
    // Tolérance : connection_id placé au niveau de l'étape au lieu des arguments.
    if (!args.containsKey('connection_id') && j['connection_id'] != null) args['connection_id'] = j['connection_id'];
    return PlanStep(
      title: '${j['title'] ?? j['tool'] ?? 'Étape'}',
      tool: '${j['tool'] ?? ''}',
      args: args,
      verification: '${j['verification'] ?? ''}',
    );
  }

  static final _stepSchema = {
    'type': 'object',
    'properties': {
      'title': {'type': 'string', 'description': 'Ce que fait l\'étape, en français.'},
      'tool': {'type': 'string', 'description': 'Nom exact de l\'outil à exécuter.'},
      'args': {'type': 'object', 'description': 'Arguments de l\'outil, conformes à son schéma.'},
      'verification': {'type': 'string', 'description': 'Ce qui prouvera que l\'étape a réussi.'},
    },
    'required': ['title', 'tool', 'args'],
  };

  String _toolCatalog() => [
        for (final n in allowedSteps)
          '- $n${_tools[n]!.mutating ? ' (modifie)' : ' (lecture)'} : ${_tools[n]!.spec.description}'
      ].join('\n');

  /// Étapes 1 à 4 : objectif, contexte, plan, prérequis (validation à blanc).
  Future<AutopilotPlan> plan(String goal, {void Function(AiMessage)? onMessage}) async {
    AutopilotPlan? planned;
    final submit = AgentTool(
      spec: AiToolSpec(
        name: 'submit_plan',
        description: 'Soumet le plan d\'exécution. Chaque étape est un appel d\'outil typé. BDDouilleur le valide '
            'sans rien exécuter et renvoie les problèmes à corriger.',
        parameters: {
          'type': 'object',
          'properties': {
            'summary': {'type': 'string', 'description': 'Résumé du plan en français.'},
            'steps': {'type': 'array', 'items': _stepSchema},
          },
          'required': ['summary', 'steps'],
        },
      ),
      describe: (_) => 'Soumettre le plan',
      run: (a) async {
        final steps = [for (final s in (a['steps'] as List?) ?? const []) _stepFrom((s as Map).cast())];
        if (steps.isEmpty) throw StateError('Plan vide.');
        if (steps.length > 25) throw StateError('Plan trop long (25 étapes maximum) : découpe l\'objectif.');
        final problems = [for (final s in steps) ..._checkStep(s)];
        if (problems.isNotEmpty) throw StateError('Plan refusé, corrige puis soumets de nouveau :\n${problems.join('\n')}');
        for (final s in steps) {
          _classify(s);
        }
        planned = AutopilotPlan(goal: goal, summary: '${a['summary'] ?? ''}', steps: steps);
        return 'Plan accepté (${steps.length} étapes). Il sera présenté à l\'utilisateur pour approbation : '
            'n\'exécute rien. Termine par une phrase de conclusion.';
      },
    );
    final system = '''Tu es le planificateur AutoPilot de BDDouilleur. Réponds en français.
Objectif : préparer un plan d'actions typées que BDDouilleur exécutera lui-même après approbation de l'utilisateur.
Démarche : 1) comprends l'objectif ; 2) analyse le contexte avec les outils de lecture (structure réelle des bases) ;
3) appelle submit_plan avec des étapes ordonnées ; 4) si le plan est refusé, corrige et soumets de nouveau.
Règles :
- Tu n'exécutes rien toi-même : aucune modification pendant la planification.
- N'utilise que ces outils dans les étapes, avec des arguments conformes à leur schéma :
${_toolCatalog()}
- Périmètre approuvé (bases autorisées) : ${_scopeText()}. N'en sors pas ; précise connection_id à chaque étape.
- Préfère les opérations non destructives. Les suppressions, migrations destructives, écritures en production
  seront de toute façon soumises à confirmation explicite.
- Ajoute à la fin des étapes de contrôle en lecture si utile (describe_database, query_sqlite, diagnose_database).
Projet : « ${project.name} »${project.description.isEmpty ? '' : ' — ${project.description}'}''';
    final agent = Agent(provider: provider, model: model, tools: [..._readTools, submit], system: system, maxSteps: 10);
    final produced = await agent.runTurn([AiMessage.user(goal)], approve: (_, _) async => false, onMessage: onMessage);
    // Relances si le modèle s'arrête sans avoir soumis de plan accepté.
    for (var nudge = 0; planned == null && nudge < 2; nudge++) {
      final ask = AiMessage.user('Tu n\'as pas encore soumis de plan accepté. Appelle MAINTENANT l\'outil submit_plan '
          'avec un résumé et la liste des étapes (tool + args conformes à leur schéma), en utilisant ce que tu as découvert. '
          'N\'écris pas le plan en texte : appelle l\'outil.');
      final more = await agent.runTurn([AiMessage.user(goal), ...produced, ask],
          approve: (_, _) async => false, onMessage: onMessage);
      produced
        ..add(ask)
        ..addAll(more);
    }
    final p = planned;
    if (p == null) {
      final last = produced.where((m) => m.role == AiRole.assistant && m.text.trim().isNotEmpty).lastOrNull?.text;
      throw StateError('Le modèle n\'a pas produit de plan valide.${last == null ? '' : '\nDernière réponse : $last'}');
    }
    final analysis = produced.where((m) => m.role == AiRole.assistant).map((m) => m.text.trim()).where((t) => t.isNotEmpty).join('\n\n');
    return AutopilotPlan(goal: p.goal, summary: p.summary, steps: p.steps, analysis: analysis);
  }

  // ============================================================ EXÉCUTION

  Set<int> _touched(AutopilotPlan plan, {bool writesOnly = false}) => {
        for (final s in plan.steps)
          if (!writesOnly || _tools[s.tool]?.mutating == true) ?_tools[s.tool]?.connectionOf?.call(s.args),
      };

  /// Étapes 4 à 9 : prérequis, sauvegardes, exécution contrôlée, corrections,
  /// tests et rapport.
  Future<void> execute(
    AutopilotRun run, {
    required Future<bool> Function(PlanStep step) confirm,
    void Function()? onUpdate,
    bool Function()? cancelled,
  }) async {
    final watch = Stopwatch()..start();
    run.status = RunStatus.running;
    run.checks = [];
    _save(run, onUpdate);

    // --- Prérequis : bases accessibles et dans le périmètre.
    final prereq = <String>[];
    for (final id in _touched(run.plan)) {
      final c = state.connections.byId(id);
      if (c == null || c.projectId != project.id) {
        prereq.add('Base #$id introuvable dans le projet.');
        continue;
      }
      try {
        if (c.engine == DbEngine.sqlite) {
          await (await state.connectorFor(c)).listTables();
        } else if (c.engine == DbEngine.firestore) {
          await state.firestoreFor(c).listCollectionIds();
        }
      } catch (e) {
        prereq.add('« ${c.name} » inaccessible : $e');
      }
    }
    for (final s in run.plan.steps) {
      prereq.addAll(_checkStep(s));
    }
    run.checks.add(RunCheck('Prérequis', prereq.isEmpty, prereq.isEmpty ? 'Bases accessibles, plan valide.' : prereq.join('\n')));
    if (prereq.isNotEmpty) return _finish(run, RunStatus.failed, watch, onUpdate);

    // --- Points de restauration avant toute modification.
    for (final id in _touched(run.plan, writesOnly: true)) {
      final c = state.connections.byId(id)!;
      if (c.engine != DbEngine.sqlite || run.rollback.sqliteBackups.containsKey(id)) continue;
      try {
        final (backup, sql) = await state.backupsFor(c).create(await state.connectorFor(c), label: 'avant_autopilot');
        run.rollback.sqliteBackups[id] = backup.path;
        state.journal.log(
          projectId: project.id,
          connectionId: id,
          action: JournalAction.backupCreated,
          summary: 'Point de restauration avant AutoPilot : ${backup.name}',
          sql: sql,
        );
      } catch (e) {
        run.checks.add(RunCheck('Point de restauration de « ${c.name} »', false, '$e'));
        return _finish(run, RunStatus.failed, watch, onUpdate);
      }
    }
    if (run.rollback.sqliteBackups.isNotEmpty) {
      run.checks.add(RunCheck('Points de restauration', true, '${run.rollback.sqliteBackups.length} sauvegarde(s) vérifiée(s) créée(s).'));
    }
    _save(run, onUpdate);

    // --- Exécution contrôlée, étape par étape.
    var budget = maxCorrections;
    var stopped = false;
    for (final step in run.plan.steps) {
      if (stopped || cancelled?.call() == true) {
        step.status = StepStatus.skipped;
        continue;
      }
      var ok = await _runStep(run, step, confirm, onUpdate);
      if (!ok && step.status == StepStatus.failed && budget > 0 && cancelled?.call() != true) {
        budget--;
        final fix = await _askFix(run, step);
        if (fix != null) {
          step.corrections = [...step.corrections, 'Échec : ${step.error}\nCorrection : ${fix.title}'];
          step
            ..tool = fix.tool
            ..args = fix.args
            ..verification = fix.verification.isEmpty ? step.verification : fix.verification
            ..error = null;
          ok = await _runStep(run, step, confirm, onUpdate);
          if (ok) step.status = StepStatus.corrected;
        }
      }
      _save(run, onUpdate);
      if (!ok) stopped = true;
    }
    if (cancelled?.call() == true && run.plan.steps.any((s) => s.status == StepStatus.skipped)) {
      await _finalChecks(run);
      return _finish(run, RunStatus.cancelled, watch, onUpdate);
    }

    // --- Tests finaux.
    await _finalChecks(run);
    final allOk = run.plan.steps.every((s) => s.status == StepStatus.succeeded || s.status == StepStatus.corrected) &&
        run.checks.every((c) => c.ok);
    _finish(run, allOk ? RunStatus.succeeded : RunStatus.failed, watch, onUpdate);
  }

  Future<void> _finalChecks(AutopilotRun run) async {
    for (final id in _touched(run.plan, writesOnly: true)) {
      final c = state.connections.byId(id);
      if (c == null || c.engine != DbEngine.sqlite) continue;
      try {
        final r = await (await state.connectorFor(c)).checkIntegrity();
        run.checks.add(RunCheck(
          'Intégrité et clés étrangères de « ${c.name} »',
          r.ok,
          r.ok ? 'integrity_check : ok ; foreign_key_check : aucune violation.' : [...r.messages, ...r.foreignKeyViolations].take(10).join('\n'),
        ));
      } catch (e) {
        run.checks.add(RunCheck('Intégrité de « ${c.name} »', false, '$e'));
      }
    }
  }

  void _save(AutopilotRun run, void Function()? onUpdate) {
    state.autopilotRuns.save(run);
    onUpdate?.call();
  }

  void _finish(AutopilotRun run, RunStatus status, Stopwatch watch, void Function()? onUpdate) {
    run.status = status;
    run.report = buildReport(run, watch.elapsed);
    _save(run, onUpdate);
    state.journal.log(
      projectId: project.id,
      action: JournalAction.autopilotRun,
      summary: 'AutoPilot « ${run.goal} » : ${status.label} '
          '(${run.plan.steps.where((s) => s.status == StepStatus.succeeded || s.status == StepStatus.corrected).length}/${run.plan.steps.length} étapes)',
      success: status == RunStatus.succeeded,
      error: status == RunStatus.succeeded ? null : run.plan.steps.where((s) => s.error != null).map((s) => '${s.title} : ${s.error}').join('\n'),
    );
  }

  Future<bool> _runStep(AutopilotRun run, PlanStep step, Future<bool> Function(PlanStep) confirm, void Function()? onUpdate) async {
    final tool = _tools[step.tool];
    if (tool == null) {
      step
        ..status = StepStatus.failed
        ..error = 'Outil inconnu.';
      return false;
    }
    _classify(step);
    if (step.needsConfirmation) {
      step.status = StepStatus.awaitingConfirmation;
      _save(run, onUpdate);
      if (!await confirm(step)) {
        step.status = StepStatus.refused;
        return false;
      }
    }
    step
      ..status = StepStatus.running
      ..autoApproved = tool.mutating && !step.needsConfirmation;
    _save(run, onUpdate);
    final watch = Stopwatch()..start();
    try {
      final out = await tool.run(step.args);
      final text = out is String ? out : jsonEncode(out);
      step.result = text.length > 3000 ? '${text.substring(0, 3000)}…' : text;
      if (step.tool == 'write_firestore_document' && out is Map && out['path'] is String) {
        run.rollback.firestoreCreated.add((tool.connectionOf!(step.args)!, out['path'] as String));
      }
      step.verified = await _verify(step, out);
      step.status = StepStatus.succeeded;
      return true;
    } catch (e) {
      step
        ..status = StepStatus.failed
        ..error = '$e';
      return false;
    } finally {
      step.durationMs = watch.elapsedMilliseconds;
    }
  }

  /// Contrôle réel du résultat (lève une exception si l'effet est absent).
  Future<String> _verify(PlanStep step, Object? out) async {
    final tool = _tools[step.tool]!;
    final id = tool.connectionOf?.call(step.args);
    final c = id == null ? null : state.connections.byId(id);
    switch (step.tool) {
      case 'create_tables':
        final expected = SchemaProposal.fromJson(((step.args['proposal'] as Map?) ?? const {}).cast()).entities.map((e) => e.tableName.toLowerCase());
        final actual = (await (await state.connectorFor(c!)).listTables()).map((t) => t.toLowerCase()).toSet();
        final missing = expected.where((t) => !actual.contains(t)).toList();
        if (missing.isNotEmpty) throw StateError('Contrôle : table(s) absente(s) après création : ${missing.join(', ')}');
        return 'Tables présentes : ${expected.join(', ')}';
      case 'insert_row':
        final rowid = out is Map ? out['id'] : null;
        if (rowid == null) return 'Ajout confirmé par SQLite.';
        final rows = await (await state.connectorFor(c!)).select('SELECT 1 FROM "${'${step.args['table']}'.replaceAll('"', '""')}" WHERE rowid = ?', [rowid]);
        if (rows.isEmpty) throw StateError('Contrôle : la ligne $rowid est introuvable après l\'ajout.');
        return 'Ligne $rowid présente dans « ${step.args['table']} ».';
      case 'create_index':
        final name = out is Map ? '${out['index']}' : '';
        final rows = await (await state.connectorFor(c!)).select("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?", [name]);
        if (rows.isEmpty) throw StateError('Contrôle : index « $name » absent.');
        return 'Index « $name » présent.';
      case 'analyze_statistics':
        final rows = await (await state.connectorFor(c!)).select("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_stat1'");
        if (rows.isEmpty) throw StateError('Contrôle : statistiques absentes.');
        return 'Statistiques présentes (sqlite_stat1).';
      case 'write_firestore_document':
        final path = out is Map ? '${out['path']}' : '';
        if (await state.firestoreFor(c!).getDocument(path) == null) throw StateError('Contrôle : document $path introuvable.');
        return 'Document $path présent.';
      case 'execute_sql':
        return 'SQL exécuté${out is Map && out['lignes_modifiees'] != null ? ' : ${out['lignes_modifiees']} ligne(s) modifiée(s)' : ''}.';
      default:
        return 'Lecture effectuée.';
    }
  }

  /// Étape 7 : correction d'une erreur récupérable, proposée par le modèle,
  /// revalidée, et jamais plus risquée que l'étape d'origine.
  Future<PlanStep?> _askFix(AutopilotRun run, PlanStep failed) async {
    PlanStep? fix;
    final submit = AgentTool(
      spec: AiToolSpec(
        name: 'submit_fix',
        description: 'Propose une étape de remplacement pour l\'étape en échec.',
        parameters: _stepSchema,
      ),
      describe: (_) => 'Proposer une correction',
      run: (a) async {
        final s = _stepFrom(a);
        final problems = _checkStep(s);
        if (problems.isNotEmpty) throw StateError(problems.join('\n'));
        _classify(s);
        if (s.risk > failed.risk) {
          throw StateError('Correction refusée : elle est plus risquée (${s.risk.label}) que l\'étape approuvée (${failed.risk.label}).');
        }
        fix = s;
        return 'Correction acceptée.';
      },
    );
    final agent = Agent(
      provider: provider,
      model: model,
      tools: [..._readTools, submit],
      maxSteps: 6,
      system: 'Tu es le correcteur AutoPilot de BDDouilleur. Réponds en français. Une étape approuvée a échoué. '
          'Examine la cause avec les outils de lecture puis appelle submit_fix avec une étape corrigée qui atteint le même but, '
          'sans risque supérieur. Si l\'erreur n\'est pas récupérable, explique pourquoi sans appeler submit_fix.\n'
          'Outils autorisés dans l\'étape :\n${_toolCatalog()}\nPérimètre : ${_scopeText()}.',
    );
    try {
      await agent.runTurn([
        AiMessage.user('Objectif global : ${run.goal}\nÉtape en échec : ${jsonEncode(failed.toJson())}\nErreur : ${failed.error}')
      ], approve: (_, _) async => false);
    } catch (_) {
      return null;
    }
    return fix;
  }

  // ======================================================== RETOUR ARRIÈRE

  /// Annule une exécution : bases SQLite restaurées à l'état d'avant
  /// l'exécution, documents Firestore créés supprimés.
  static Future<List<String>> rollback(AppState state, AutopilotRun run) async {
    final report = <String>[];
    for (final MapEntry(key: id, value: path) in run.rollback.sqliteBackups.entries) {
      final c = state.connections.byId(id);
      final f = File(path);
      if (c == null || !f.existsSync()) {
        report.add('Base #$id : sauvegarde introuvable, non restaurée.');
        continue;
      }
      final stat = f.statSync();
      final safety = await state.runLogged<BackupFile>(
        connection: c,
        action: JournalAction.backupRestored,
        summary: 'Retour arrière AutoPilot : « ${c.name} » restaurée',
        run: (conn) => state.backupsFor(c).restore(conn, BackupFile(path: path, size: stat.size, modified: stat.modified)),
        sqlOf: (s) => '-- Restauration de ${f.uri.pathSegments.last}\n-- Copie de sécurité de l\'état annulé : ${s.name}',
      );
      report.add('« ${c.name} » restaurée (état annulé conservé dans ${safety.name}).');
    }
    for (final (id, path) in run.rollback.firestoreCreated.reversed) {
      final c = state.connections.byId(id);
      if (c == null) continue;
      final client = state.firestoreFor(c);
      await state.runFirebase(
        api: client.api,
        connection: c,
        action: JournalAction.firestoreDocumentDeleted,
        summary: 'Retour arrière AutoPilot : document $path supprimé',
        run: () => client.deleteDocument(path),
      );
      report.add('Document $path supprimé.');
    }
    run.status = RunStatus.rolledBack;
    run.report = '${run.report ?? ''}\n\n## Retour arrière\n${report.map((r) => '- $r').join('\n')}';
    state.autopilotRuns.save(run);
    state.journal.log(
      projectId: run.projectId,
      action: JournalAction.autopilotRun,
      summary: 'AutoPilot « ${run.goal} » annulé : ${report.length} opération(s) de retour arrière',
    );
    return report;
  }

  // ================================================================ RAPPORT

  static String buildReport(AutopilotRun run, [Duration? elapsed]) {
    final b = StringBuffer()
      ..writeln('## Objectif')
      ..writeln(run.goal)
      ..writeln()
      ..writeln('## Résultat : ${run.status.label}')
      ..writeln('${run.plan.steps.where((s) => s.status == StepStatus.succeeded || s.status == StepStatus.corrected).length} étape(s) réussie(s) sur ${run.plan.steps.length}'
          '${elapsed == null ? '' : ', en ${elapsed.inSeconds} s'}. Fournisseur : ${run.provider.label} (${run.model}).')
      ..writeln()
      ..writeln('## Étapes');
    for (final (i, s) in run.plan.steps.indexed) {
      b.writeln('${i + 1}. **${s.title}** — ${s.status.label}'
          '${s.autoApproved ? ' (automatique, ${s.risk.label.toLowerCase()})' : s.needsConfirmation ? ' (confirmée par vous)' : ''}');
      if (s.verified != null) b.writeln('   - Contrôle : ${s.verified}');
      if (s.error != null) b.writeln('   - Erreur : ${s.error!.split('\n').first}');
      for (final c in s.corrections) {
        b.writeln('   - ${c.replaceAll('\n', ' — ')}');
      }
    }
    b
      ..writeln()
      ..writeln('## Contrôles');
    for (final c in run.checks) {
      b.writeln('- ${c.ok ? 'OK' : 'ÉCHEC'} : ${c.label}${c.detail.isEmpty ? '' : ' : ${c.detail.split('\n').first}'}');
    }
    b
      ..writeln()
      ..writeln('## Retour arrière')
      ..writeln(run.rollback.isEmpty
          ? 'Aucune modification à annuler.'
          : 'Possible : ${run.rollback.sqliteBackups.length} base(s) SQLite restaurable(s) à l\'état d\'avant l\'exécution'
              '${run.rollback.firestoreCreated.isEmpty ? '' : ', ${run.rollback.firestoreCreated.length} document(s) Firestore à supprimer'}.');
    return b.toString().trim();
  }
}
