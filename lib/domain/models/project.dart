import 'dart:convert';

import '../firebase/firebase_target.dart';
import 'db_engine.dart';

/// Un projet regroupe des connexions de bases de données et leur historique.
class Project {
  const Project({
    this.id,
    required this.name,
    this.description = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final String name;
  final String description;
  final DateTime createdAt;
  final DateTime updatedAt;

  Project copyWith({String? name, String? description, DateTime? updatedAt}) => Project(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  factory Project.fromRow(Map<String, Object?> row) => Project(
        id: row['id'] as int,
        name: row['name'] as String,
        description: (row['description'] as String?) ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      );
}

/// Connexion vers une base de données (configuration non sensible uniquement).
///
/// Les secrets (mots de passe, clés) ne sont jamais stockés ici.
class DbConnection {
  const DbConnection({
    this.id,
    required this.projectId,
    required this.name,
    required this.engine,
    required this.location,
    required this.createdAt,
    this.lastOpenedAt,
    this.config = const {},
  });

  final int? id;
  final int projectId;
  final String name;
  final DbEngine engine;

  /// Pour SQLite : chemin absolu du fichier de base.
  /// Pour Firestore : identifiant du projet Firebase.
  final String location;

  /// Configuration non sensible propre au moteur (JSON). Jamais de secret.
  final Map<String, Object?> config;

  /// Cible Firebase (connexions Firestore uniquement).
  FirebaseTarget get firebase => FirebaseTarget.fromJson({'projectId': location, ...config});
  final DateTime createdAt;
  final DateTime? lastOpenedAt;

  factory DbConnection.fromRow(Map<String, Object?> row) => DbConnection(
        id: row['id'] as int,
        projectId: row['project_id'] as int,
        name: row['name'] as String,
        engine: DbEngine.fromName(row['engine'] as String),
        location: row['location'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        lastOpenedAt: row['last_opened_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['last_opened_at'] as int),
        config: _decodeConfig(row['config'] as String?),
      );

  static Map<String, Object?> _decodeConfig(String? s) {
    if (s == null || s.isEmpty) return const {};
    try {
      return (jsonDecode(s) as Map).cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }
}
