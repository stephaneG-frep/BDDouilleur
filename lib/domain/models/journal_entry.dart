/// Types d'actions journalisées. Le moteur d'actions typées (futur AutoPilot)
/// s'appuiera sur ce même vocabulaire.
enum JournalAction {
  projectCreated('Projet créé'),
  projectUpdated('Projet modifié'),
  projectDeleted('Projet supprimé'),
  databaseCreated('Base créée'),
  databaseAttached('Base existante connectée'),
  databaseDetached('Connexion retirée'),
  tableCreated('Table créée'),
  tableDropped('Table supprimée'),
  rowInserted('Enregistrement ajouté'),
  rowUpdated('Enregistrement modifié'),
  rowDeleted('Enregistrement supprimé'),
  sqlExecuted('SQL exécuté'),
  integrityChecked('Intégrité vérifiée'),
  backupCreated('Sauvegarde créée'),
  backupRestored('Sauvegarde restaurée'),
  googleSignedIn('Compte Google connecté'),
  googleSignedOut('Compte Google déconnecté'),
  firebaseConnected('Projet Firebase connecté'),
  firebaseAutopilot('Firebase AutoPilot'),
  firestoreDocumentWritten('Document Firestore écrit'),
  firestoreDocumentDeleted('Document Firestore supprimé'),
  firestoreIndexCreated('Index Firestore créé'),
  firestoreIndexDeleted('Index Firestore supprimé'),
  rulesDeployed('Règles de sécurité déployées'),
  rulesTested('Règles de sécurité testées'),
  authConfigured('Authentication configuré'),
  authTested('Parcours Authentication testé'),
  firebaseConfigWritten('Configuration FlutterFire écrite'),
  firebaseDiagnostic('Diagnostic Firebase'),
  diagnosticFixApplied('Correction appliquée');

  const JournalAction(this.label);
  final String label;

  static JournalAction fromName(String name) =>
      JournalAction.values.firstWhere((e) => e.name == name, orElse: () => JournalAction.sqlExecuted);
}

class JournalEntry {
  const JournalEntry({
    this.id,
    this.projectId,
    this.connectionId,
    required this.action,
    required this.summary,
    this.sql,
    required this.success,
    this.error,
    required this.timestamp,
  });

  final int? id;
  final int? projectId;
  final int? connectionId;
  final JournalAction action;
  final String summary;

  /// SQL réellement exécuté (sans valeurs sensibles : les valeurs sont liées
  /// par paramètres et ne figurent pas dans ce texte), ou requête REST
  /// envoyée (méthode + URL, jamais de jeton ni de clé).
  final String? sql;
  final bool success;
  final String? error;
  final DateTime timestamp;

  factory JournalEntry.fromRow(Map<String, Object?> row) => JournalEntry(
        id: row['id'] as int,
        projectId: row['project_id'] as int?,
        connectionId: row['connection_id'] as int?,
        action: JournalAction.fromName(row['action'] as String),
        summary: row['summary'] as String,
        sql: row['sql'] as String?,
        success: (row['success'] as int) == 1,
        error: row['error'] as String?,
        timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      );
}
