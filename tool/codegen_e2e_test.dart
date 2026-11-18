// Vérification de bout en bout du générateur : crée un vrai projet Flutter,
// y intègre le code généré (SQLite puis Firestore), installe les dépendances,
// puis exécute dart analyze et flutter test sur le code produit.
//   flutter test tool/codegen_e2e_test.dart   (réseau requis pour pub add)
import 'dart:io';

import 'package:bddouilleur/data/codegen/code_integrator.dart';
import 'package:bddouilleur/data/codegen/flutter_codegen.dart';
import 'package:bddouilleur/domain/models/schema.dart';
import 'package:bddouilleur/domain/schema_proposal.dart';
import 'package:flutter_test/flutter_test.dart';

const proposal = SchemaProposal(summary: 'Boutique', entities: [
  EntityProposal(name: 'Category', fields: [
    FieldProposal(name: 'label', type: SqlColumnType.text, required: true, unique: true),
  ]),
  EntityProposal(name: 'Product', fields: [
    FieldProposal(name: 'name', type: SqlColumnType.text, required: true),
    FieldProposal(name: 'price', type: SqlColumnType.real, required: true),
    FieldProposal(name: 'inStock', type: SqlColumnType.boolean, required: true),
    FieldProposal(name: 'createdAt', type: SqlColumnType.datetime),
    FieldProposal(name: 'photo', type: SqlColumnType.blob),
    FieldProposal(name: 'categoryId', type: SqlColumnType.integer, required: true, references: 'Category'),
  ]),
]);

void main() {
  for (final backend in CodegenBackend.values) {
    test('génération ${backend.name} : intégration, analyse et tests réels', () async {
      final dir = Directory.systemTemp.createTempSync('bdd_codegen_${backend.name}_');
      final create = await Process.run('flutter', ['create', '--project-name', 'boutique', '--platforms', 'linux', dir.path]);
      expect(create.exitCode, 0, reason: '${create.stderr}');
      // Architecture existante à respecter.
      Directory('${dir.path}/lib/models').createSync();

      final plan = FlutterCodeGenerator(proposal, backend).plan(dir.path);
      expect(plan.files.any((f) => f.path == 'lib/models/product.dart'), isTrue, reason: 'dossier existant respecté');
      final integrator = CodeIntegrator();
      final applied = await integrator.apply(plan, addDependencies: true);
      for (final c in applied.commands) {
        expect(c.ok, isTrue, reason: '${c.command}\n${c.output}');
      }
      final verification = await integrator.verify(plan);
      for (final s in verification.steps) {
        expect(s.ok, isTrue, reason: '${s.command}\n${s.output}');
      }
      expect(verification.steps.length, 2);
      // ignore: avoid_print
      print('${backend.name} : ${plan.files.length} fichiers, ${verification.steps.last.output.split('\n').last}');

      // Restauration : retour à l'état initial.
      final report = await integrator.restore(dir.path, applied.restoreId);
      expect(File('${dir.path}/lib/models/product.dart').existsSync(), isFalse);
      expect(File('${dir.path}/pubspec.yaml').readAsStringSync(), isNot(contains(backend.dependencies.first)));
      expect(report, isNotEmpty);
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 15)));
  }
}
