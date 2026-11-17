/// Moteurs de bases de données ciblés par BDDouilleur.
///
/// [implemented] indique si un connecteur réel existe dans cette version.
/// Aucun moteur non implémenté n'est présenté comme utilisable dans l'UI.
enum DbEngine {
  sqlite('SQLite', 'Base relationnelle embarquée dans un simple fichier.', true, 1),
  postgresql('PostgreSQL', 'Serveur relationnel robuste et complet.', false, 5),
  firestore('Firebase Firestore', 'Base NoSQL orientée documents de Google.', true, 2),
  mysql('MySQL', 'Serveur relationnel très répandu.', false, 5),
  mariadb('MariaDB', 'Fork communautaire de MySQL.', false, 5),
  supabase('Supabase', 'PostgreSQL hébergé avec API et RLS.', false, 5),
  mongodb('MongoDB', 'Base NoSQL orientée documents.', false, 5),
  hive('Hive', 'Stockage clé-valeur local pour Flutter.', false, 5),
  isar('Isar', 'Base NoSQL locale pour Flutter.', false, 5);

  const DbEngine(this.label, this.description, this.implemented, this.plannedPhase);

  final String label;
  final String description;
  final bool implemented;

  /// Phase du plan de développement où le connecteur est prévu.
  final int plannedPhase;

  static DbEngine fromName(String name) =>
      DbEngine.values.firstWhere((e) => e.name == name, orElse: () => DbEngine.sqlite);
}
