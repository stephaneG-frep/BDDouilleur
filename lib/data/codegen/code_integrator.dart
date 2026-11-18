import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'flutter_codegen.dart';

class CommandResult {
  const CommandResult(this.command, this.exitCode, this.output);
  final String command;
  final int exitCode;
  final String output;
  bool get ok => exitCode == 0;
}

class IntegrationResult {
  IntegrationResult({required this.restoreId, required this.written, required this.commands});
  final String restoreId;
  final List<String> written;
  final List<CommandResult> commands;
  bool get ok => commands.every((c) => c.ok);
}

class VerificationResult {
  VerificationResult(this.steps);
  final List<CommandResult> steps;

  /// `null` : vérification impossible (outils Flutter absents, ex. Android).
  bool? get ok => steps.isEmpty ? null : steps.every((s) => s.ok);
}

class RestorePoint {
  const RestorePoint(this.id, this.created, this.modified, this.date);
  final String id;
  final List<String> created;
  final List<String> modified;
  final DateTime date;
}

/// Exécute une commande FIXE (jamais construite par l'IA).
typedef CommandRunner = Future<CommandResult> Function(String executable, List<String> args, String workingDir);

Future<CommandResult> defaultCommandRunner(String executable, List<String> args, String workingDir) async {
  try {
    final r = await Process.run(executable, args, workingDirectory: workingDir, runInShell: false)
        .timeout(const Duration(minutes: 10));
    final out = '${r.stdout}\n${r.stderr}'.trim();
    return CommandResult('$executable ${args.join(' ')}', r.exitCode, out.length > 20000 ? out.substring(out.length - 20000) : out);
  } on ProcessException catch (e) {
    return CommandResult('$executable ${args.join(' ')}', 127, 'Commande introuvable : ${e.message}');
  }
}

/// Intègre un plan de génération dans un projet Flutter, avec point de
/// restauration, ajout des dépendances et vérification réelle.
class CodeIntegrator {
  CodeIntegrator({CommandRunner? runner}) : run = runner ?? defaultCommandRunner;
  final CommandRunner run;

  static String restoreRoot(String projectDir) => p.join(projectDir, '.bddouilleur', 'restore');

  /// Les outils Flutter sont-ils disponibles (PC de développement) ?
  Future<bool> toolsAvailable(String projectDir) async {
    if (Platform.isAndroid || Platform.isIOS) return false;
    final r = await run('flutter', ['--version'], projectDir);
    return r.ok;
  }

  Future<IntegrationResult> apply(CodegenPlan plan, {required bool addDependencies}) async {
    final dir = plan.projectDir;
    final id = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final backup = Directory(p.join(restoreRoot(dir), id))..createSync(recursive: true);
    final created = <String>[];
    final modified = <String>[];
    for (final f in plan.files) {
      (f.isNew ? created : modified).add(f.path);
    }
    // Sauvegarde AVANT écriture : fichiers modifiés + pubspec (dépendances).
    final toSave = [...modified, if (addDependencies) ...['pubspec.yaml', 'pubspec.lock']];
    final saved = <String>[];
    for (final rel in toSave) {
      final src = File(p.join(dir, rel));
      if (!src.existsSync()) continue;
      final dst = File(p.join(backup.path, 'files', rel))..parent.createSync(recursive: true);
      src.copySync(dst.path);
      saved.add(rel);
    }
    File(p.join(backup.path, 'manifest.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'date': DateTime.now().toIso8601String(),
      'created': created,
      'modified': saved,
    }));

    final written = <String>[];
    for (final f in plan.files) {
      final target = File(p.join(dir, f.path))..parent.createSync(recursive: true);
      final tmp = File('${target.path}.bdd-tmp')..writeAsStringSync(f.content);
      tmp.renameSync(target.path);
      written.add(f.path);
    }
    final commands = <CommandResult>[];
    if (addDependencies) {
      if (plan.missingDependencies.isNotEmpty) {
        commands.add(await run('flutter', ['pub', 'add', ...plan.missingDependencies], dir));
      }
      if (plan.missingDevDependencies.isNotEmpty && commands.every((c) => c.ok)) {
        commands.add(await run('flutter', ['pub', 'add', '--dev', ...plan.missingDevDependencies], dir));
      }
    }
    return IntegrationResult(restoreId: id, written: written, commands: commands);
  }

  /// Vérifie les fichiers générés : analyse statique puis tests générés.
  Future<VerificationResult> verify(CodegenPlan plan) async {
    if (!await toolsAvailable(plan.projectDir)) return VerificationResult(const []);
    final dartFiles = [for (final f in plan.files) if (f.path.endsWith('.dart')) f.path];
    final steps = <CommandResult>[await run('dart', ['analyze', '--fatal-infos', ...dartFiles], plan.projectDir)];
    if (steps.last.ok && plan.testFiles.isNotEmpty) {
      steps.add(await run('flutter', ['test', ...plan.testFiles], plan.projectDir));
    }
    return VerificationResult(steps);
  }

  List<RestorePoint> restorePoints(String projectDir) {
    final root = Directory(restoreRoot(projectDir));
    if (!root.existsSync()) return const [];
    final out = <RestorePoint>[];
    for (final d in root.listSync().whereType<Directory>()) {
      final m = File(p.join(d.path, 'manifest.json'));
      if (!m.existsSync()) continue;
      final j = jsonDecode(m.readAsStringSync()) as Map;
      out.add(RestorePoint(p.basename(d.path), (j['created'] as List).cast<String>(), (j['modified'] as List).cast<String>(),
          DateTime.parse(j['date'] as String)));
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  /// Annule une intégration : fichiers créés supprimés, fichiers modifiés et
  /// pubspec restaurés.
  Future<List<String>> restore(String projectDir, String id) async {
    final point = restorePoints(projectDir).firstWhere((r) => r.id == id,
        orElse: () => throw StateError('Point de restauration introuvable : $id'));
    final base = p.join(restoreRoot(projectDir), id, 'files');
    final report = <String>[];
    for (final rel in point.created) {
      final f = File(p.join(projectDir, rel));
      if (f.existsSync()) {
        f.deleteSync();
        report.add('Supprimé : $rel');
      }
    }
    for (final rel in point.modified) {
      File(p.join(base, rel)).copySync(p.join(projectDir, rel));
      report.add('Restauré : $rel');
    }
    if (point.modified.contains('pubspec.yaml') && await toolsAvailable(projectDir)) {
      final r = await run('flutter', ['pub', 'get'], projectDir);
      report.add(r.ok ? 'Dépendances resynchronisées (flutter pub get).' : 'flutter pub get a échoué : ${r.output}');
    }
    return report;
  }
}
