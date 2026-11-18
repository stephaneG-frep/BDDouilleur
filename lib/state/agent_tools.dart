import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/ai/agent.dart';
import '../data/analysis/project_analyzer.dart';
import '../data/codegen/flutter_codegen.dart';
import '../data/connectors/sqlite/sqlite_sql_builder.dart';
import '../domain/ai/ai_models.dart';
import '../domain/firebase/firestore_rules.dart';
import '../domain/models/db_engine.dart';
import '../domain/models/journal_entry.dart';
import '../domain/models/project.dart';
import '../domain/models/schema.dart';
import '../domain/schema_proposal.dart';
import 'app_state.dart';

/// Contexte de travail de l'agent : projet, base par défaut, dossier autorisé.
class AgentContext {
  const AgentContext({required this.state, required this.project, this.folder, this.connectionId});
  final AppState state;
  final Project project;

  /// Seul dossier que l'agent peut lire (choisi par l'utilisateur).
  final String? folder;
  final int? connectionId;
}

/// Outils réels de l'agent. Aucun outil n'exécute de commande système :
/// l'agent n'agit qu'au travers de ces opérations typées et journalisées.
class AgentToolbox {
  AgentToolbox(this.ctx);
  final AgentContext ctx;

  AppState get _state => ctx.state;

  static const _maxFileBytes = 100 * 1024;

  /// Message système (en français) : règles de conduite de l'agent.
  String systemPrompt() {
    final conns = _state.connections.forProject(ctx.project.id!);
    return '''Tu es l'agent IA de BDDouilleur (« Vos bases de données ? Je m'en débrouille ! »), un assistant expert en bases de données (SQLite, Firestore) et en intégration Flutter.
Tu réponds toujours en français, clairement, et tu expliques ce que tu fais et pourquoi.

Règles impératives :
- Tu agis UNIQUEMENT via les outils fournis. Tu n'as accès à aucune commande système.
- Une action n'est réussie que si le résultat de l'outil le confirme. Ne prétends jamais avoir créé, modifié ou supprimé quoi que ce soit sans ce résultat. Si un outil échoue ou est refusé, dis-le.
- Les outils qui modifient des données demandent l'accord de l'utilisateur : explique avant de les appeler ce qu'ils vont faire.
- Pour proposer une architecture de données, appelle propose_schema (l'utilisateur l'appliquera ou générera le code depuis l'interface, avec aperçu et sauvegarde).
- Pour générer du code Flutter, appelle plan_flutter_code : il calcule un plan (fichiers, différences) que l'utilisateur valide dans l'interface. N'écris pas toi-même de code complet dans la réponse.
- Avant toute modification, présente un plan.
- Ne demande jamais de mot de passe ni de clé API.

Contexte :
- Projet BDDouilleur : « ${ctx.project.name} »${ctx.project.description.isEmpty ? '' : ' — ${ctx.project.description}'}
- Bases du projet : ${conns.isEmpty ? 'aucune' : conns.map((c) => '#${c.id} ${c.name} (${c.engine.label})').join(', ')}
- Base par défaut : ${ctx.connectionId == null ? 'aucune' : '#${ctx.connectionId}'}
- Dossier de projet lisible : ${ctx.folder ?? 'aucun (l\'utilisateur peut en choisir un)'}''';
  }

  DbConnection _conn(Map<String, Object?> a) {
    final id = (a['connection_id'] as num?)?.toInt() ?? ctx.connectionId;
    if (id == null) throw StateError('Indique connection_id (voir list_databases).');
    final c = _state.connections.byId(id);
    if (c == null || c.projectId != ctx.project.id) throw StateError('Base #$id introuvable dans ce projet.');
    return c;
  }

  String _resolveInFolder(String rel) {
    final folder = ctx.folder;
    if (folder == null) throw StateError('Aucun dossier de projet n\'a été choisi pour cette conversation.');
    final full = p.normalize(p.join(folder, rel));
    if (!p.isWithin(folder, full) && full != p.normalize(folder)) {
      throw StateError('Accès refusé : le chemin sort du dossier autorisé.');
    }
    if (ProjectAnalyzer.isSecretFile(full)) throw StateError('Accès refusé : fichier de secrets (contenu jamais lu).');
    return full;
  }

  static bool isReadOnlySql(String sql) {
    final statements = SqlScript.split(sql).where((s) => !SqlScript.isBlank(s)).toList();
    if (statements.length != 1) return false;
    final s = statements.single.trim();
    final head = s.split(RegExp(r'\s+')).first.toUpperCase();
    if (!{'SELECT', 'WITH', 'EXPLAIN', 'PRAGMA', 'VALUES'}.contains(head)) return false;
    if (head == 'PRAGMA' && s.contains('=')) return false;
    if (SqlSafety.isWriteLike(s)) return false;
    return true;
  }

  static Map<String, Object?> _obj(Map<String, Object?> props, {List<String> required = const []}) =>
      {'type': 'object', 'properties': props, 'required': required};

  static const _connId = {'type': 'integer', 'description': 'Identifiant de la base (voir list_databases). Facultatif si une base par défaut est définie.'};

  static final _schemaParam = {
    'type': 'object',
    'description': 'Proposition de schéma.',
    'properties': {
      'summary': {'type': 'string', 'description': 'Résumé en français.'},
      'entities': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': 'Nom de l\'entité en PascalCase anglais ou français sans accent (ex. Product).'},
            'description': {'type': 'string'},
            'fields': {
              'type': 'array',
              'description': 'Champs, sans « id » (ajouté automatiquement).',
              'items': {
                'type': 'object',
                'properties': {
                  'name': {'type': 'string', 'description': 'camelCase, lettres ASCII.'},
                  'type': {
                    'type': 'string',
                    'enum': ['integer', 'real', 'text', 'numeric', 'boolean', 'date', 'datetime', 'blob'],
                  },
                  'required': {'type': 'boolean'},
                  'unique': {'type': 'boolean'},
                  'references': {'type': 'string', 'description': 'Nom de l\'entité référencée (clé étrangère).'},
                },
                'required': ['name', 'type'],
              },
            },
          },
          'required': ['name', 'fields'],
        },
      },
    },
    'required': ['entities'],
  };

  void _logTool(String summary, {bool success = true, String? error, String? detail, int? connectionId}) => _state.journal.log(
        projectId: ctx.project.id,
        connectionId: connectionId,
        action: JournalAction.agentToolExecuted,
        summary: 'Agent IA : $summary',
        sql: detail,
        success: success,
        error: error,
      );

  List<AgentTool> tools() => [
        AgentTool(
          spec: AiToolSpec(name: 'list_databases', description: 'Liste les bases de données du projet BDDouilleur.', parameters: _obj({})),
          describe: (_) => 'Lister les bases du projet',
          run: (_) async => [
            for (final c in _state.connections.forProject(ctx.project.id!))
              {'id': c.id, 'name': c.name, 'engine': c.engine.name, 'location': c.engine == DbEngine.firestore ? c.firebase.description : p.basename(c.location)}
          ],
        ),
        AgentTool(
          spec: AiToolSpec(
            name: 'describe_database',
            description: 'Décrit une base : tables, colonnes, types, clés et nombre de lignes (SQLite) ou collections (Firestore).',
            parameters: _obj({'connection_id': _connId}),
          ),
          describe: (a) => 'Décrire la base #${a['connection_id'] ?? ctx.connectionId}',
          run: (a) async {
            final c = _conn(a);
            if (c.engine == DbEngine.firestore) {
              return {'engine': 'firestore', 'collections': await _state.firestoreFor(c).listCollectionIds()};
            }
            final db = await _state.connectorFor(c);
            final tables = <Object?>[];
            for (final t in await db.listTables()) {
              final info = await db.describeTable(t);
              tables.add({
                'table': t,
                'rows': info.rowCount,
                'columns': [
                  for (final col in info.columns)
                    '${col.name} ${col.declaredType}${col.isPrimaryKey ? ' PK' : ''}${col.notNull ? ' NOT NULL' : ''}'
                ],
                'foreignKeys': [for (final fk in info.foreignKeys) '${fk.from} -> ${fk.table}(${fk.to ?? 'rowid'})'],
              });
            }
            return {'engine': 'sqlite', 'tables': tables};
          },
        ),
        AgentTool(
          spec: AiToolSpec(
            name: 'query_sqlite',
            description: 'Exécute UNE requête en LECTURE SEULE (SELECT, WITH, EXPLAIN, PRAGMA de lecture) sur une base SQLite. 100 lignes maximum.',
            parameters: _obj({'connection_id': _connId, 'sql': {'type': 'string'}}, required: ['sql']),
          ),
          describe: (a) => 'Lire : ${a['sql']}',
          run: (a) async {
            final c = _conn(a);
            final sql = '${a['sql'] ?? ''}';
            if (c.engine != DbEngine.sqlite) throw StateError('query_sqlite ne s\'applique qu\'aux bases SQLite.');
            if (!isReadOnlySql(sql)) {
              throw StateError('Requête refusée : seule une requête de lecture unique est permise ici (utilise execute_sql pour modifier).');
            }
            final r = await (await _state.connectorFor(c)).executeSql(sql);
            return {
              'columns': r.columns,
              'rows': r.rows.take(100).toList(),
              if (r.rows.length > 100) 'truncated': '${r.rows.length} lignes au total, 100 affichées',
            };
          },
        ),
        AgentTool(
          spec: AiToolSpec(
            name: 'list_firestore_documents',
            description: 'Lit les documents d\'une collection Firestore (20 maximum).',
            parameters: _obj({'connection_id': _connId, 'collection': {'type': 'string'}}, required: ['collection']),
          ),
          describe: (a) => 'Lire la collection ${a['collection']}',
          run: (a) async {
            final c = _conn(a);
            if (c.engine != DbEngine.firestore) throw StateError('Cette base n\'est pas Firestore.');
            final page = await _state.firestoreFor(c).listDocuments('${a['collection']}', pageSize: 20);
            return [for (final d in page.documents) {'path': d.path, 'data': d.data}];
          },
        ),
        AgentTool(
          spec: AiToolSpec(
            name: 'analyze_project',
            description: 'Analyse le dossier de projet autorisé : technologie, dépendances, modèles, services, stockage, authentification, appels API. Renvoie aussi une proposition de schéma déduite des modèles.',
            parameters: _obj({}),
          ),
          describe: (_) => 'Analyser le dossier ${ctx.folder}',
          run: (_) async {
            final folder = ctx.folder;
            if (folder == null) throw StateError('Aucun dossier de projet choisi pour cette conversation.');
            final analysis = await ProjectAnalyzer(folder).run();
            final proposal = ProjectAnalyzer.proposeSchema(analysis);
            _logTool('analyse du projet $folder');
            return {'analysis': analysis.toText(), 'deducedSchema': proposal.toJson()};
          },
        ),
        AgentTool(
          spec: AiToolSpec(
            name: 'list_project_files',
            description: 'Liste les fichiers d\'un sous-dossier du projet autorisé (200 maximum).',
            parameters: _obj({'subdir': {'type': 'string', 'description': 'Chemin relatif, ex. lib/models. Vide : racine.'}}),
          ),
          describe: (a) => 'Lister ${a['subdir'] ?? '.'}',
          run: (a) async {
            final dir = Directory(_resolveInFolder('${a['subdir'] ?? ''}'));
            if (!dir.existsSync()) throw StateError('Dossier introuvable.');
            final out = <String>[];
            for (final e in dir.listSync(recursive: true, followLinks: false)) {
              final rel = p.relative(e.path, from: ctx.folder);
              if (rel.split(p.separator).any((s) => s.startsWith('.') || s == 'build' || s == 'node_modules')) continue;
              if (e is File) out.add(rel);
              if (out.length >= 200) break;
            }
            return out;
          },
        ),
        AgentTool(
          spec: AiToolSpec(
            name: 'read_project_file',
            description: 'Lit un fichier texte du projet autorisé (100 Ko maximum). Les fichiers de secrets (.env, clés) sont refusés.',
            parameters: _obj({'path': {'type': 'string', 'description': 'Chemin relatif au dossier du projet.'}}, required: ['path']),
          ),
          describe: (a) => 'Lire ${a['path']}',
          run: (a) async {
            final f = File(_resolveInFolder('${a['path']}'));
            if (!f.existsSync()) throw StateError('Fichier introuvable.');
            if (f.lengthSync() > _maxFileBytes) throw StateError('Fichier trop volumineux (${f.lengthSync()} octets).');
            return f.readAsStringSync();
          },
        ),
        AgentTool(
          spec: AiToolSpec(
            name: 'analyze_firestore_rules',
            description: 'Analyse des règles de sécurité Firestore et signale les ouvertures dangereuses.',
            parameters: _obj({'source': {'type': 'string'}}, required: ['source']),
          ),
          describe: (_) => 'Analyser des règles Firestore',
          run: (a) async => [
            for (final f in RulesAnalyzer.analyze('${a['source']}'))
              {'gravite': f.severity.name, 'chemin': f.matchPath, 'titre': f.title, 'explication': f.explanation, 'ligne': f.line}
          ],
        ),
        AgentTool(
          spec: AiToolSpec(
            name: 'propose_schema',
            description: 'Présente à l\'utilisateur une architecture de données (entités, champs, relations). Rien n\'est créé : l\'utilisateur pourra l\'appliquer à une base ou générer le code.',
            parameters: _schemaParam,
          ),
          describe: (_) => 'Proposer un schéma',
          run: (a) async {
            final proposal = SchemaProposal.fromJson(a);
            final problems = proposal.validate();
            if (problems.isNotEmpty) throw StateError('Schéma invalide : ${problems.join(' ; ')}');
            return {'affiche': true, 'resume': proposal.describe(), 'proposal': proposal.toJson()};
          },
        ),
        AgentTool(
          spec: AiToolSpec(
            name: 'plan_flutter_code',
            description: 'Calcule (sans rien écrire) le plan de génération du code Flutter (modèles, dépôts, services, tests) pour un schéma, dans le dossier de projet autorisé. L\'utilisateur voit les différences et décide d\'appliquer.',
            parameters: _obj({
              'backend': {'type': 'string', 'enum': ['sqlite', 'firestore']},
              'proposal': _schemaParam,
            }, required: ['backend', 'proposal']),
          ),
          describe: (a) => 'Planifier le code Flutter (${a['backend']})',
          run: (a) async {
            final folder = ctx.folder;
            if (folder == null) throw StateError('Aucun dossier de projet Flutter choisi pour cette conversation.');
            final proposal = SchemaProposal.fromJson(((a['proposal'] as Map?) ?? const {}).cast());
            final backend = a['backend'] == 'firestore' ? CodegenBackend.firestore : CodegenBackend.sqlite;
            final plan = FlutterCodeGenerator(proposal, backend).plan(folder);
            return {
              'affiche': true,
              'backend': backend.name,
              'proposal': proposal.toJson(),
              'fichiers': [for (final f in plan.files) '${f.isNew ? 'nouveau' : 'modifié'} : ${f.path}'],
              'dependances_a_ajouter': [...plan.missingDependencies, ...plan.missingDevDependencies.map((d) => '$d (dev)')],
              'note': 'Rien n\'est écrit tant que l\'utilisateur n\'a pas validé le plan dans l\'interface.',
            };
          },
        ),
        AgentTool(
          mutating: true,
          spec: AiToolSpec(
            name: 'create_tables',
            description: 'Crée dans une base SQLite les tables d\'un schéma (clé « id » automatique, clés étrangères). Demande l\'accord de l\'utilisateur.',
            parameters: _obj({'connection_id': _connId, 'proposal': _schemaParam}, required: ['proposal']),
          ),
          describe: (a) {
            final prop = SchemaProposal.fromJson(((a['proposal'] as Map?) ?? const {}).cast());
            return 'Créer ${prop.entities.length} table(s) dans la base #${a['connection_id'] ?? ctx.connectionId} : '
                '${prop.entities.map((e) => e.tableName).join(', ')}';
          },
          run: (a) async {
            final c = _conn(a);
            if (c.engine != DbEngine.sqlite) throw StateError('create_tables ne s\'applique qu\'aux bases SQLite.');
            final tables = SchemaProposal.fromJson(((a['proposal'] as Map?) ?? const {}).cast()).toTableDefinitions();
            return await applyTables(_state, c, tables);
          },
        ),
        AgentTool(
          mutating: true,
          spec: AiToolSpec(
            name: 'insert_row',
            description: 'Ajoute un enregistrement dans une table SQLite. Demande l\'accord de l\'utilisateur.',
            parameters: _obj({
              'connection_id': _connId,
              'table': {'type': 'string'},
              'values': {'type': 'object', 'description': 'Colonne → valeur.'},
            }, required: ['table', 'values']),
          ),
          describe: (a) => 'Ajouter dans « ${a['table']} » : ${a['values']}',
          run: (a) async {
            final c = _conn(a);
            final values = ((a['values'] as Map?) ?? const {}).cast<String, Object?>();
            final out = await _state.runLogged(
              connection: c,
              action: JournalAction.rowInserted,
              summary: 'Agent IA : enregistrement ajouté dans « ${a['table']} »',
              run: (db) => db.insertRow('${a['table']}', values),
            );
            return {'ok': true, 'id': out.insertedId, 'sql': out.sql};
          },
        ),
        AgentTool(
          mutating: true,
          spec: AiToolSpec(
            name: 'execute_sql',
            description: 'Exécute du SQL qui modifie une base SQLite. Un point de restauration est créé avant toute instruction destructive. Demande l\'accord de l\'utilisateur.',
            parameters: _obj({'connection_id': _connId, 'sql': {'type': 'string'}}, required: ['sql']),
          ),
          describe: (a) => '${SqlSafety.isDestructive('${a['sql']}') ? 'SQL DESTRUCTIF (sauvegarde automatique avant) : ' : 'Exécuter : '}${a['sql']}',
          run: (a) async {
            final c = _conn(a);
            final sql = '${a['sql'] ?? ''}';
            if (c.engine != DbEngine.sqlite) throw StateError('execute_sql ne s\'applique qu\'aux bases SQLite.');
            String? backupName;
            if (SqlSafety.isDestructive(sql)) {
              final (backup, backupSql) = await _state.backupsFor(c).create(await _state.connectorFor(c), label: 'avant_agent');
              backupName = backup.name;
              _state.journal.log(
                projectId: c.projectId,
                connectionId: c.id,
                action: JournalAction.backupCreated,
                summary: 'Point de restauration avant SQL de l\'agent : ${backup.name}',
                sql: backupSql,
              );
            }
            final r = await _state.runLogged(
              connection: c,
              action: JournalAction.sqlExecuted,
              summary: 'Agent IA : SQL exécuté',
              run: (db) => db.executeSql(sql),
              sqlOf: (_) => sql,
            );
            return {'ok': true, 'lignes_modifiees': r.affectedRows, 'sauvegarde': ?backupName};
          },
        ),
        AgentTool(
          mutating: true,
          spec: AiToolSpec(
            name: 'write_firestore_document',
            description: 'Crée un document Firestore (types spéciaux : {"\$timestamp": "ISO"}, {"\$ref": "col/id"}, {"\$geo": [lat, lng]}). Demande l\'accord de l\'utilisateur.',
            parameters: _obj({
              'connection_id': _connId,
              'collection': {'type': 'string'},
              'document_id': {'type': 'string', 'description': 'Facultatif : identifiant généré sinon.'},
              'data': {'type': 'object'},
            }, required: ['collection', 'data']),
          ),
          describe: (a) => 'Créer un document dans « ${a['collection']} »${a['document_id'] == null ? '' : ' (id ${a['document_id']})'} : ${a['data']}',
          run: (a) async {
            final c = _conn(a);
            if (c.engine != DbEngine.firestore) throw StateError('Cette base n\'est pas Firestore.');
            final client = _state.firestoreFor(c);
            final doc = await _state.runFirebase(
              api: client.api,
              connection: c,
              action: JournalAction.firestoreDocumentWritten,
              summary: 'Agent IA : document créé dans « ${a['collection']} »',
              run: () => client.createDocument('${a['collection']}', ((a['data'] as Map?) ?? const {}).cast(),
                  documentId: (a['document_id'] as String?)?.trim().isEmpty ?? true ? null : a['document_id'] as String),
            );
            return {'ok': true, 'path': doc.path};
          },
        ),
      ];

  /// Crée des tables (dans l'ordre) en journalisant chaque création.
  static Future<Map<String, Object?>> applyTables(AppState state, DbConnection c, List<TableDefinition> tables) async {
    final db = await state.connectorFor(c);
    final existing = (await db.listTables()).map((t) => t.toLowerCase()).toSet();
    final created = <String>[];
    final skipped = <String>[];
    for (final t in tables) {
      if (existing.contains(t.name.toLowerCase())) {
        skipped.add(t.name);
        continue;
      }
      await state.runLogged(
        connection: c,
        action: JournalAction.tableCreated,
        summary: 'Table « ${t.name} » créée (schéma proposé)',
        run: (conn) => conn.createTable(t),
      );
      created.add(t.name);
    }
    return {'ok': true, 'creees': created, if (skipped.isNotEmpty) 'deja_existantes_non_modifiees': skipped};
  }

  /// Nom lisible d'un appel d'outil pour l'interface.
  static String label(AiToolCall c) => switch (c.name) {
        'list_databases' => 'Liste des bases',
        'describe_database' => 'Description de la base',
        'query_sqlite' => 'Requête de lecture',
        'list_firestore_documents' => 'Lecture de documents',
        'analyze_project' => 'Analyse du projet',
        'list_project_files' => 'Liste des fichiers',
        'read_project_file' => 'Lecture de fichier',
        'analyze_firestore_rules' => 'Analyse de règles',
        'propose_schema' => 'Proposition de schéma',
        'plan_flutter_code' => 'Plan de code Flutter',
        'create_tables' => 'Création de tables',
        'insert_row' => 'Ajout d\'enregistrement',
        'execute_sql' => 'Exécution SQL',
        'write_firestore_document' => 'Écriture Firestore',
        _ => c.name,
      };
}
