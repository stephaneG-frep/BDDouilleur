import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../connectors/database_connector.dart';
import '../connectors/sqlite/sqlite_connector.dart';

class BackupFile {
  const BackupFile({required this.path, required this.size, required this.modified});
  final String path;
  final int size;
  final DateTime modified;
  String get name => p.basename(path);
}

/// Sauvegarde et restauration de bases SQLite (Le Coffre-fort).
///
/// Une sauvegarde SQLite est une copie complète et cohérente du fichier
/// (VACUUM INTO), vérifiée par PRAGMA integrity_check après création.
class SqliteBackupService {
  SqliteBackupService(this.backupsRoot);

  /// Dossier dédié aux sauvegardes de cette connexion.
  final String backupsRoot;

  static String _stamp(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}${two(d.second)}'
        '_${d.millisecond.toString().padLeft(3, '0')}';
  }

  List<BackupFile> list() {
    final dir = Directory(backupsRoot);
    if (!dir.existsSync()) return [];
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.db')).map((f) {
      final s = f.statSync();
      return BackupFile(path: f.path, size: s.size, modified: s.modified);
    }).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  }

  /// Vérifie qu'un fichier est une base SQLite intègre.
  static List<String> verify(String path) {
    if (!File(path).existsSync()) return ['Fichier introuvable.'];
    Database? db;
    try {
      db = sqlite3.open(path, mode: OpenMode.readOnly);
      final rows = db.select('PRAGMA integrity_check').map((r) => r.values.first.toString()).toList();
      return (rows.length == 1 && rows.first == 'ok') ? const [] : rows;
    } on SqliteException catch (e) {
      return ['Fichier illisible : ${e.message}'];
    } finally {
      db?.close();
    }
  }

  /// Crée une sauvegarde à partir d'un connecteur ouvert, puis la vérifie.
  Future<(BackupFile, String)> create(SqliteConnector connector, {String label = 'manuelle'}) async {
    final base = p.basenameWithoutExtension(connector.path);
    final dest = p.join(backupsRoot, '${base}_${label}_${_stamp(DateTime.now())}.db');
    final outcome = await connector.backupTo(dest);
    final problems = verify(dest);
    if (problems.isNotEmpty) {
      File(dest).deleteSync();
      throw ConnectorException('La sauvegarde produite est corrompue : ${problems.join(', ')}');
    }
    final s = File(dest).statSync();
    return (BackupFile(path: dest, size: s.size, modified: s.modified), outcome.sql);
  }

  /// Restaure [backup] à la place de la base de [connector].
  ///
  /// 1. Vérifie l'intégrité de la sauvegarde.
  /// 2. Crée un point de restauration de l'état actuel.
  /// 3. Ferme la connexion, remplace le fichier, rouvre et revérifie.
  /// Retourne le point de restauration créé.
  Future<BackupFile> restore(SqliteConnector connector, BackupFile backup) async {
    final problems = verify(backup.path);
    if (problems.isNotEmpty) {
      throw ConnectorException('Sauvegarde refusée, intégrité non valide : ${problems.join(', ')}');
    }
    final (safety, _) = await create(connector, label: 'avant_restauration');
    await connector.close();
    final target = connector.path;
    for (final suffix in ['-journal', '-wal', '-shm']) {
      final f = File('$target$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    final tmp = '$target.restauration_tmp';
    File(backup.path).copySync(tmp);
    File(tmp).renameSync(target);
    await connector.open();
    final report = await connector.checkIntegrity();
    if (!report.ok) {
      throw ConnectorException('La base restaurée ne passe pas la vérification. Point de restauration : ${safety.name}');
    }
    return safety;
  }
}
