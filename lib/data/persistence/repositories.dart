import 'dart:convert';

import '../../domain/models/db_engine.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import 'app_database.dart';

class ProjectRepository {
  ProjectRepository(this._app);
  final AppDatabase _app;

  List<Project> all() => _app.db
      .select('SELECT * FROM projects ORDER BY updated_at DESC, id DESC')
      .map((r) => Project.fromRow(r))
      .toList();

  Project? byId(int id) {
    final r = _app.db.select('SELECT * FROM projects WHERE id = ?', [id]);
    return r.isEmpty ? null : Project.fromRow(r.first);
  }

  Project create(String name, {String description = ''}) {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('Le nom du projet est obligatoire.');
    final now = DateTime.now().millisecondsSinceEpoch;
    _app.db.execute(
      'INSERT INTO projects(name, description, created_at, updated_at) VALUES(?, ?, ?, ?)',
      [n, description.trim(), now, now],
    );
    return byId(_app.db.lastInsertRowId)!;
  }

  Project update(Project p) {
    if (p.name.trim().isEmpty) throw ArgumentError('Le nom du projet est obligatoire.');
    _app.db.execute(
      'UPDATE projects SET name = ?, description = ?, updated_at = ? WHERE id = ?',
      [p.name.trim(), p.description.trim(), DateTime.now().millisecondsSinceEpoch, p.id],
    );
    return byId(p.id!)!;
  }

  void touch(int id) =>
      _app.db.execute('UPDATE projects SET updated_at = ? WHERE id = ?', [DateTime.now().millisecondsSinceEpoch, id]);

  /// Supprime le projet et ses connexions enregistrées. Les fichiers de base
  /// de données ne sont PAS supprimés par cette méthode.
  void delete(int id) => _app.db.execute('DELETE FROM projects WHERE id = ?', [id]);
}

class ConnectionRepository {
  ConnectionRepository(this._app);
  final AppDatabase _app;

  List<DbConnection> forProject(int projectId) => _app.db
      .select('SELECT * FROM connections WHERE project_id = ? ORDER BY name COLLATE NOCASE', [projectId])
      .map((r) => DbConnection.fromRow(r))
      .toList();

  List<DbConnection> all() =>
      _app.db.select('SELECT * FROM connections ORDER BY name COLLATE NOCASE').map((r) => DbConnection.fromRow(r)).toList();

  DbConnection? byId(int id) {
    final r = _app.db.select('SELECT * FROM connections WHERE id = ?', [id]);
    return r.isEmpty ? null : DbConnection.fromRow(r.first);
  }

  bool locationUsed(int projectId, String location) => _app.db
      .select('SELECT 1 FROM connections WHERE project_id = ? AND location = ?', [projectId, location])
      .isNotEmpty;

  DbConnection create({
    required int projectId,
    required String name,
    required DbEngine engine,
    required String location,
    Map<String, Object?> config = const {},
  }) {
    _app.db.execute(
      'INSERT INTO connections(project_id, name, engine, location, created_at, config) VALUES(?, ?, ?, ?, ?, ?)',
      [projectId, name.trim(), engine.name, location, DateTime.now().millisecondsSinceEpoch, jsonEncode(config)],
    );
    return byId(_app.db.lastInsertRowId)!;
  }

  void updateConfig(int id, Map<String, Object?> config) =>
      _app.db.execute('UPDATE connections SET config = ? WHERE id = ?', [jsonEncode(config), id]);

  void markOpened(int id) => _app.db
      .execute('UPDATE connections SET last_opened_at = ? WHERE id = ?', [DateTime.now().millisecondsSinceEpoch, id]);

  void delete(int id) => _app.db.execute('DELETE FROM connections WHERE id = ?', [id]);
}

class JournalRepository {
  JournalRepository(this._app);
  final AppDatabase _app;

  void log({
    int? projectId,
    int? connectionId,
    required JournalAction action,
    required String summary,
    String? sql,
    bool success = true,
    String? error,
  }) {
    _app.db.execute(
      'INSERT INTO journal(project_id, connection_id, action, summary, sql, success, error, timestamp) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?)',
      [projectId, connectionId, action.name, summary, sql, success ? 1 : 0, error, DateTime.now().millisecondsSinceEpoch],
    );
  }

  List<JournalEntry> recent({int? projectId, int? connectionId, int limit = 200, bool withSqlOnly = false}) {
    final where = <String>[];
    final args = <Object?>[];
    if (projectId != null) {
      where.add('project_id = ?');
      args.add(projectId);
    }
    if (connectionId != null) {
      where.add('connection_id = ?');
      args.add(connectionId);
    }
    if (withSqlOnly) where.add("sql IS NOT NULL AND sql <> ''");
    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    return _app.db
        .select('SELECT * FROM journal $clause ORDER BY timestamp DESC, id DESC LIMIT ?', [...args, limit])
        .map((r) => JournalEntry.fromRow(r))
        .toList();
  }
}
