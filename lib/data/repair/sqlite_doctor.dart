import 'dart:io';

import '../../domain/autopilot/autonomy.dart';
import '../connectors/sqlite/sqlite_connector.dart';
import '../connectors/sqlite/sqlite_sql_builder.dart';
import '../firebase/firebase_diagnostic.dart' show DiagSeverity;

/// Action typée proposée (exécutée par l'agent, AutoPilot ou l'interface,
/// toujours via les outils journalisés).
class PlannedAction {
  const PlannedAction(this.tool, this.args, this.description);
  final String tool;
  final Map<String, Object?> args;
  final String description;

  Map<String, Object?> toJson() => {'tool': tool, 'args': args, 'description': description};
  factory PlannedAction.fromJson(Map<String, Object?> j) => PlannedAction(
        '${j['tool']}',
        ((j['args'] as Map?) ?? const {}).cast<String, Object?>(),
        (j['description'] as String?) ?? '',
      );
}

/// Constat du Réparateur, avec estimation du risque de la correction.
class RepairFinding {
  const RepairFinding({
    required this.severity,
    required this.problem,
    this.cause = '',
    this.solution = '',
    this.risk = ActionRisk.read,
    this.riskDetail = '',
    this.action,
    this.verification = '',
  });

  final DiagSeverity severity;
  final String problem;
  final String cause;
  final String solution;

  /// Niveau de risque de la correction proposée.
  final ActionRisk risk;
  final String riskDetail;
  final PlannedAction? action;
  final String verification;

  Map<String, Object?> toJson() => {
        'gravite': severity.name,
        'probleme': problem,
        if (cause.isNotEmpty) 'cause': cause,
        if (solution.isNotEmpty) 'solution': solution,
        'risque': risk.name,
        if (riskDetail.isNotEmpty) 'detail_risque': riskDetail,
        if (action != null) 'correction': action!.toJson(),
        if (verification.isNotEmpty) 'verification': verification,
      };
}

/// Le Réparateur : diagnostic d'une base SQLite (lecture seule).
class SqliteDoctor {
  SqliteDoctor(this.connector, {required this.connectionId, this.recentQueries = const []});
  final SqliteConnector connector;
  final int connectionId;

  /// Requêtes récentes (journal) à examiner pour les performances.
  final List<String> recentQueries;

  static String q(String id) => SqliteSqlBuilder.quote(id);

  /// Diagnostic de connexion, possible même si la base ne s'ouvre pas.
  static List<RepairFinding> connectionCheck(String path) {
    final out = <RepairFinding>[];
    final f = File(path);
    if (!f.existsSync()) {
      return [
        RepairFinding(
          severity: DiagSeverity.error,
          problem: 'Fichier de base introuvable',
          cause: 'Le fichier $path n\'existe plus (déplacé, supprimé, ou disque non monté).',
          solution: 'Restaurer une sauvegarde (Coffre-fort) ou reconnecter le bon fichier.',
          verification: 'La base s\'ouvre de nouveau.',
        )
      ];
    }
    try {
      final raf = f.openSync();
      final header = raf.readSync(16);
      raf.closeSync();
      if (header.length == 16 && String.fromCharCodes(header.take(15)) != 'SQLite format 3') {
        out.add(const RepairFinding(
          severity: DiagSeverity.error,
          problem: 'Le fichier n\'est pas une base SQLite',
          cause: 'L\'en-tête du fichier ne correspond pas au format SQLite 3 (fichier corrompu ou d\'un autre type).',
          solution: 'Restaurer une sauvegarde vérifiée.',
        ));
      }
    } on FileSystemException catch (e) {
      out.add(RepairFinding(
        severity: DiagSeverity.error,
        problem: 'Fichier illisible',
        cause: 'Accès refusé ou erreur disque : ${e.message}.',
        solution: 'Vérifier les permissions du fichier et de son dossier.',
      ));
    }
    if (File('$path-wal').existsSync() || File('$path-journal').existsSync()) {
      out.add(const RepairFinding(
        severity: DiagSeverity.info,
        problem: 'Journal de transaction présent',
        cause: 'Une transaction est en cours ou une application s\'est arrêtée brutalement. SQLite le rejoue à l\'ouverture.',
        solution: 'Aucune action : ne supprimez jamais ce fichier à la main.',
      ));
    }
    return out;
  }

  Future<List<RepairFinding>> run() async {
    final out = <RepairFinding>[];
    final integrity = await connector.checkIntegrity();
    if (integrity.messages.length != 1 || integrity.messages.first != 'ok') {
      out.add(RepairFinding(
        severity: DiagSeverity.error,
        problem: 'Base endommagée (integrity_check)',
        cause: integrity.messages.take(5).join(' ; '),
        solution: 'Restaurer la dernière sauvegarde vérifiée du Coffre-fort, puis rejouer les modifications récentes.',
        risk: ActionRisk.destructive,
        riskDetail: 'La restauration remplace le fichier actuel (une copie de sécurité est faite avant).',
        verification: 'integrity_check renvoie « ok ».',
      ));
    }

    final tables = await connector.listTables();
    final tableSet = tables.map((t) => t.toLowerCase()).toSet();
    var totalRows = 0;

    // --- Contraintes violées (clés étrangères orphelines), par table et parent.
    final orphans = await connector.select('PRAGMA foreign_key_check');
    final groups = <(String, String), List<int>>{};
    for (final r in orphans) {
      groups.putIfAbsent(('${r['table']}', '${r['parent']}'), () => []).add((r['rowid'] as num?)?.toInt() ?? -1);
    }
    for (final MapEntry(key: (table, parent), value: rowids) in groups.entries) {
      final ids = rowids.where((i) => i >= 0).take(500).toList();
      out.add(RepairFinding(
        severity: DiagSeverity.error,
        problem: '${rowids.length} ligne(s) de « $table » référencent un « $parent » inexistant',
        cause: 'Des lignes ont été insérées ou des parents supprimés alors que les clés étrangères étaient désactivées.',
        solution: 'Supprimer les lignes orphelines, ou recréer les lignes parentes manquantes.',
        risk: ActionRisk.destructive,
        riskDetail: 'Suppression de ${rowids.length} ligne(s) : point de restauration créé avant.',
        action: ids.isEmpty
            ? null
            : PlannedAction('execute_sql', {
                'connection_id': connectionId,
                'sql': 'DELETE FROM ${q(table)} WHERE rowid IN (${ids.join(', ')});',
              }, 'Supprimer les ${ids.length} ligne(s) orpheline(s) de « $table »'),
        verification: 'PRAGMA foreign_key_check ne renvoie plus rien pour « $table ».',
      ));
    }

    for (final t in tables) {
      final info = await connector.describeTable(t);
      totalRows += info.rowCount;
      // --- Migration incomplète : clé étrangère vers une table absente.
      for (final fk in info.foreignKeys) {
        if (!tableSet.contains(fk.table.toLowerCase())) {
          out.add(RepairFinding(
            severity: DiagSeverity.error,
            problem: '« $t.${fk.from} » référence la table absente « ${fk.table} »',
            cause: 'Une migration n\'a pas été appliquée entièrement, ou la table a été renommée ou supprimée.',
            solution: 'Recréer la table « ${fk.table} » ou corriger la clé étrangère (reconstruction de « $t »).',
            risk: ActionRisk.schema,
            riskDetail: 'Toute insertion dans « $t » échoue tant que la référence est invalide.',
            verification: 'Une insertion de test dans « $t » réussit.',
          ));
          continue;
        }
        // --- Index absent sur une clé étrangère.
        final indexed = info.indexes.any((i) => i.columns.isNotEmpty && i.columns.first.toLowerCase() == fk.from.toLowerCase()) ||
            info.columns.any((c) => c.isPrimaryKey && c.name.toLowerCase() == fk.from.toLowerCase());
        if (!indexed) {
          final name = 'idx_${t}_${fk.from}'.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
          out.add(RepairFinding(
            severity: info.rowCount > 1000 ? DiagSeverity.warning : DiagSeverity.info,
            problem: 'Clé étrangère « $t.${fk.from} » sans index',
            cause: 'Chaque jointure vers « ${fk.table} » et chaque suppression dans « ${fk.table} » parcourt toute la table « $t » (${info.rowCount} ligne(s)).',
            solution: 'Créer un index sur « ${fk.from} ».',
            risk: ActionRisk.schema,
            riskDetail: 'Aucune donnée modifiée ; léger surcoût à l\'écriture.',
            action: PlannedAction('create_index', {
              'connection_id': connectionId,
              'table': t,
              'columns': [fk.from],
              'name': name,
            }, 'Créer l\'index $name'),
            verification: 'EXPLAIN QUERY PLAN d\'une jointure utilise l\'index.',
          ));
        }
      }
    }

    // --- Vues cassées (migration ayant supprimé ou renommé une table).
    for (final v in await connector.select("SELECT name FROM sqlite_master WHERE type = 'view'")) {
      final name = '${v['name']}';
      final err = await connector.compileError('SELECT * FROM ${q(name)} LIMIT 0');
      if (err != null) {
        out.add(RepairFinding(
          severity: DiagSeverity.error,
          problem: 'Vue « $name » invalide',
          cause: 'Elle référence une table ou une colonne qui n\'existe plus : ${err.split('\n').first}',
          solution: 'Recréer la vue avec la bonne définition, ou la supprimer.',
          risk: ActionRisk.destructive,
          verification: 'SELECT * FROM « $name » fonctionne.',
        ));
      }
    }

    // --- Configuration et maintenance.
    final pages = ((await connector.select('PRAGMA page_count')).first.values.first as num).toInt();
    final free = ((await connector.select('PRAGMA freelist_count')).first.values.first as num).toInt();
    if (pages > 100 && free / pages > 0.25) {
      out.add(RepairFinding(
        severity: DiagSeverity.warning,
        problem: '${(free * 100 / pages).round()} % de la base est de l\'espace inutilisé',
        cause: 'Beaucoup de données ont été supprimées : le fichier ne rétrécit pas tout seul.',
        solution: 'Compacter la base (VACUUM).',
        risk: ActionRisk.destructive,
        riskDetail: 'VACUUM réécrit tout le fichier : sans danger en temps normal, mais un point de restauration est créé avant.',
        action: PlannedAction('execute_sql', {'connection_id': connectionId, 'sql': 'VACUUM;'}, 'Compacter la base'),
        verification: 'PRAGMA freelist_count proche de 0.',
      ));
    }
    final hasStats = (await connector.select("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_stat1'")).isNotEmpty;
    if (!hasStats && totalRows > 1000) {
      out.add(RepairFinding(
        severity: DiagSeverity.info,
        problem: 'Statistiques de l\'optimiseur absentes',
        cause: 'Sans ANALYZE, SQLite choisit ses index sans connaître la répartition des données.',
        solution: 'Exécuter ANALYZE.',
        risk: ActionRisk.schema,
        riskDetail: 'Ajoute la table interne sqlite_stat1 ; aucune donnée modifiée.',
        action: PlannedAction('analyze_statistics', {'connection_id': connectionId}, 'Calculer les statistiques (ANALYZE)'),
        verification: 'La table sqlite_stat1 existe.',
      ));
    }

    // --- Requêtes récentes : plans d'exécution.
    final seen = <String>{};
    for (final sql in recentQueries) {
      final key = sql.trim().toLowerCase();
      if (!seen.add(key)) continue;
      out.addAll(await analyzeQuery(sql));
    }

    if (!out.any((f) => f.severity == DiagSeverity.error || f.severity == DiagSeverity.warning)) {
      out.add(RepairFinding(
        severity: DiagSeverity.ok,
        problem: 'Aucun problème détecté',
        cause: 'Intégrité, contraintes, références, vues et configuration sont conformes (${tables.length} table(s), $totalRows ligne(s)).',
      ));
    }
    return out;
  }

  /// Plan d'exécution d'une requête : repère les parcours complets de table
  /// filtrés sur une colonne non indexée, et les requêtes incorrectes.
  Future<List<RepairFinding>> analyzeQuery(String sql) async {
    final s = sql.trim().replaceAll(RegExp(r';\s*$'), '');
    if (s.isEmpty) return const [];
    final head = s.split(RegExp(r'\s+')).first.toUpperCase();
    if (head != 'SELECT' && head != 'WITH' && head != 'UPDATE' && head != 'DELETE') return const [];
    final err = await connector.compileError(s);
    if (err != null) {
      return [
        RepairFinding(
          severity: DiagSeverity.error,
          problem: 'Requête incorrecte',
          cause: '${err.split('\n').first}\nRequête : $s',
          solution: 'Corriger la syntaxe ou les noms de tables et colonnes.',
          verification: 'La requête se compile.',
        )
      ];
    }
    final List<Map<String, Object?>> plan;
    try {
      plan = await connector.select('EXPLAIN QUERY PLAN $s');
    } catch (_) {
      return const [];
    }
    final out = <RepairFinding>[];
    for (final row in plan) {
      final detail = '${row['detail']}';
      final m = RegExp(r'^SCAN (?:TABLE )?(\S+)(?: AS \S+)?$').firstMatch(detail.trim());
      if (m == null) continue;
      final table = m.group(1)!;
      final where = RegExp(r'\bWHERE\b([\s\S]*?)(?:\bGROUP\b|\bORDER\b|\bLIMIT\b|$)', caseSensitive: false).firstMatch(s)?.group(1) ?? '';
      final cols = <String>{
        for (final c in RegExp(r'"?([A-Za-z_][A-Za-z0-9_]*)"?\s*(?:=|>|<|>=|<=|\bIN\b|\bLIKE\b|\bIS\b)', caseSensitive: false).allMatches(where))
          c.group(1)!,
      }..removeWhere((c) => {'AND', 'OR', 'NOT', 'NULL'}.contains(c.toUpperCase()));
      List<String> columns;
      try {
        columns = (await connector.describeTable(table)).columns.map((c) => c.name).toList();
      } catch (_) {
        continue;
      }
      final indexable = cols.where((c) => columns.any((x) => x.toLowerCase() == c.toLowerCase())).toList();
      if (indexable.isEmpty) continue;
      final name = 'idx_${table}_${indexable.join('_')}'.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
      out.add(RepairFinding(
        severity: DiagSeverity.warning,
        problem: 'Parcours complet de « $table » pour filtrer sur ${indexable.join(', ')}',
        cause: 'Plan d\'exécution : « $detail ». Requête : $s',
        solution: 'Créer un index sur ${indexable.join(', ')}.',
        risk: ActionRisk.schema,
        riskDetail: 'Aucune donnée modifiée ; léger surcoût à l\'écriture.',
        action: PlannedAction('create_index', {
          'connection_id': connectionId,
          'table': table,
          'columns': indexable,
          'name': name,
        }, 'Créer l\'index $name'),
        verification: 'EXPLAIN QUERY PLAN affiche « USING INDEX $name ».',
      ));
    }
    return out;
  }
}
