import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Emplacements des fichiers de BDDouilleur.
///
/// Linux : ~/.local/share/fr.bddouilleur.bddouilleur/
/// Android : stockage privé de l'application.
class AppPaths {
  AppPaths(this.root);

  final String root;

  static Future<AppPaths> resolve() async {
    final dir = await getApplicationSupportDirectory();
    return AppPaths(dir.path);
  }

  String get appDatabase => p.join(root, 'bddouilleur_app.db');
  String databasesDir(int projectId) => p.join(root, 'databases', 'projet_$projectId');
  String backupsDir(int connectionId) => p.join(root, 'backups', 'connexion_$connectionId');

  /// Nom de fichier sûr à partir d'un nom saisi librement.
  static String safeFileName(String input) {
    const accents = {
      'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ç': 'c', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'î': 'i', 'ï': 'i', 'í': 'i', 'ô': 'o', 'ö': 'o', 'ó': 'o', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ú': 'u',
      'ÿ': 'y', 'ñ': 'n', 'œ': 'oe', 'æ': 'ae',
    };
    var s = input.trim().toLowerCase();
    accents.forEach((k, v) => s = s.replaceAll(k, v));
    s = s.replaceAll(RegExp(r'[^a-z0-9_-]+'), '_').replaceAll(RegExp(r'_+'), '_');
    s = s.replaceAll(RegExp(r'^_+|_+$'), '');
    return s.isEmpty ? 'base' : s;
  }

  /// Chemin libre pour une nouvelle base dans le dossier du projet.
  String newDatabaseFile(int projectId, String name) {
    final dir = databasesDir(projectId);
    final base = safeFileName(name);
    var candidate = p.join(dir, '$base.db');
    var i = 2;
    while (File(candidate).existsSync()) {
      candidate = p.join(dir, '${base}_$i.db');
      i++;
    }
    return candidate;
  }
}
