import '../../domain/models/db_engine.dart';
import '../../domain/models/schema.dart';

/// Capacités qu'un connecteur peut annoncer. Un connecteur ne doit annoncer
/// que ce qu'il sait réellement faire (règle fondamentale de BDDouilleur).
enum ConnectorCapability {
  connect('Connexion'),
  inspect('Inspection du schéma'),
  crud('Lecture / écriture (CRUD)'),
  migration('Migrations'),
  backup('Sauvegarde'),
  restore('Restauration'),
  diagnostic('Diagnostic');

  const ConnectorCapability(this.label);
  final String label;
}

/// Résultat d'une opération qui modifie la base : le SQL réellement exécuté
/// est conservé pour le journal et le module pédagogique.
class OperationOutcome {
  const OperationOutcome({required this.sql, this.affectedRows = 0, this.insertedId});
  final String sql;
  final int affectedRows;
  final int? insertedId;
}

/// Erreur métier lisible en français.
class ConnectorException implements Exception {
  ConnectorException(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() => message;
}

/// Interface commune à tous les connecteurs (SQLite, PostgreSQL, Firestore...).
///
/// Les méthodes sont asynchrones pour permettre des connecteurs réseau.
/// Les moteurs NoSQL n'implémenteront pas forcément les notions de table :
/// ils lèveront [UnsupportedError] et n'annonceront pas la capacité associée.
abstract class DatabaseConnector {
  DbEngine get engine;
  Set<ConnectorCapability> get capabilities;
  bool get isOpen;

  Future<void> open();
  Future<void> close();

  Future<List<String>> listTables();
  Future<TableInfo> describeTable(String table);
  Future<OperationOutcome> createTable(TableDefinition definition);
  Future<OperationOutcome> dropTable(String table);

  Future<RowPage> readRows(String table, {int limit = 50, int offset = 0});
  Future<OperationOutcome> insertRow(String table, Map<String, Object?> values);
  Future<OperationOutcome> updateRow(String table, RowKey key, Map<String, Object?> values);
  Future<OperationOutcome> deleteRow(String table, RowKey key);

  Future<SqlResult> executeSql(String sql);
  Future<IntegrityReport> checkIntegrity();
  Future<OperationOutcome> backupTo(String destinationPath);
}
