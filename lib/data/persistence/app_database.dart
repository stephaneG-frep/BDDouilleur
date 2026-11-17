import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Base interne de BDDouilleur (projets, connexions, journal).
///
/// Ne contient aucun secret : mots de passe et clés seront conservés dans un
/// stockage sécurisé séparé (phase 2+).
class AppDatabase {
  AppDatabase._(this.db, this.path);

  final Database db;
  final String path;

  static const schemaVersion = 2;

  static AppDatabase open(String path) {
    if (path != ':memory:') File(path).parent.createSync(recursive: true);
    final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);
    db.execute('PRAGMA foreign_keys = ON;');
    final app = AppDatabase._(db, path);
    app._migrate();
    return app;
  }

  void _migrate() {
    final current = db.userVersion;
    if (current > schemaVersion) {
      throw StateError('Base interne créée par une version plus récente de BDDouilleur.');
    }
    if (current < 1) {
      db.execute('BEGIN');
      try {
        db.execute('''
          CREATE TABLE projects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          );
          CREATE TABLE connections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            engine TEXT NOT NULL,
            location TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            last_opened_at INTEGER
          );
          CREATE INDEX idx_connections_project ON connections(project_id);
          CREATE TABLE journal (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            connection_id INTEGER REFERENCES connections(id) ON DELETE SET NULL,
            action TEXT NOT NULL,
            summary TEXT NOT NULL,
            sql TEXT,
            success INTEGER NOT NULL CHECK (success IN (0, 1)),
            error TEXT,
            timestamp INTEGER NOT NULL
          );
          CREATE INDEX idx_journal_project ON journal(project_id, timestamp);
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          );
        ''');
        db.userVersion = 1;
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (db.userVersion < 2) {
      // v2 : configuration non sensible par connexion (Firebase).
      db.execute('BEGIN');
      try {
        db.execute("ALTER TABLE connections ADD COLUMN config TEXT NOT NULL DEFAULT '{}';");
        db.userVersion = 2;
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  String? getSetting(String key) {
    final r = db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void setSetting(String key, String? value) {
    if (value == null) {
      db.execute('DELETE FROM settings WHERE key = ?', [key]);
    } else {
      db.execute('INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [key, value]);
    }
  }

  void close() => db.close();
}
