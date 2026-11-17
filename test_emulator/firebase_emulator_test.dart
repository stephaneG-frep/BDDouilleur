// Tests contre la VRAIE suite d'émulateurs Firebase (Firestore + Auth).
// Lancement : tool/run_emulator_tests.sh  (démarre les émulateurs, exécute, arrête).
@Tags(['emulator'])
library;

import 'package:bddouilleur/data/firebase/auth_service.dart';
import 'package:bddouilleur/data/firebase/firestore_client.dart';
import 'package:bddouilleur/data/firebase/rules_service.dart';
import 'package:bddouilleur/data/google/google_api.dart';
import 'package:bddouilleur/domain/firebase/firebase_target.dart';
import 'package:bddouilleur/domain/firebase/firestore_rules.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  const projectId = 'demo-bddouilleur';
  const target = FirebaseTarget(mode: FirebaseMode.emulator, projectId: projectId);
  final httpClient = http.Client();
  GoogleApiClient api([String? auth]) => GoogleApiClient(client: httpClient, authHeader: () async => auth);
  final owner = FirestoreClient(target, api('Bearer owner'));

  setUpAll(() async {
    await httpClient.delete(Uri.parse('http://127.0.0.1:8080/emulator/v1/projects/$projectId/databases/(default)/documents'));
  });
  tearDownAll(httpClient.close);

  test('CRUD Firestore réel avec types variés et sous-collections', () async {
    final created = await owner.createDocument('potions', {
      'nom': 'Élixir',
      'stock': 12,
      'prix': {r'$double': 4.0},
      'note': 4.5,
      'actif': true,
      'vide': null,
      'creeLe': {r'$timestamp': '2026-11-17T10:00:00.000Z'},
      'lieu': {r'$geo': [48.85, 2.35]},
      'tags': ['bleu', 1],
      'meta': {'niveau': 3},
      'labo': {r'$ref': 'labos/central'},
    }, documentId: 'elixir');
    expect(created.path, 'potions/elixir');
    final read = await owner.getDocument('potions/elixir');
    expect(read!.data['nom'], 'Élixir');
    expect(read.data['stock'], 12);
    expect(read.data['prix'], {r'$double': 4.0});
    expect(read.data['creeLe'], {r'$timestamp': '2026-11-17T10:00:00Z'});
    expect(read.data['lieu'], {r'$geo': [48.85, 2.35]});
    expect(read.data['labo'], {r'$ref': 'labos/central'});
    expect(read.data['meta'], {'niveau': 3});

    // création refusée si le document existe déjà
    await expectLater(owner.createDocument('potions', {'x': 1}, documentId: 'elixir'),
        throwsA(isA<GoogleApiException>().having((e) => e.isAlreadyExists, 'existe', true)));

    await owner.replaceDocument('potions/elixir', {'nom': 'Élixir 2'});
    expect((await owner.getDocument('potions/elixir'))!.data, {'nom': 'Élixir 2'});
    // remplacement refusé si absent
    await expectLater(owner.replaceDocument('potions/absent', {'x': 1}), throwsA(isA<GoogleApiException>()));

    final auto = await owner.createDocument('potions', {'nom': 'Auto'});
    expect(auto.id.length, greaterThan(10));
    await owner.setDocument('potions/elixir/ingredients/sel', {'g': 2});
    expect(await owner.listCollectionIds(), contains('potions'));
    expect(await owner.listCollectionIds(documentPath: 'potions/elixir'), ['ingredients']);

    final page = await owner.listDocuments('potions', pageSize: 1);
    expect(page.documents, hasLength(1));
    expect(page.nextPageToken, isNotNull);

    await owner.deleteDocument('potions/elixir');
    expect(await owner.getDocument('potions/elixir'), isNull);
  });

  test('Règles générées : déploiement et tests réels sur l\'émulateur', () async {
    final design = [
      const CollectionRule('users', CollectionAccess.ownerDocument),
      const CollectionRule('notes', CollectionAccess.ownerField),
      const CollectionRule('catalogue', CollectionAccess.publicRead),
      const CollectionRule('annonces', CollectionAccess.signedInRead),
      const CollectionRule('admin', CollectionAccess.locked),
    ];
    final source = RulesGenerator.generate(design);
    expect(RulesAnalyzer.hasCritical(RulesAnalyzer.analyze(source)), isFalse);

    // Donnée existante qui doit survivre aux tests.
    await owner.setDocument('users/alice', {'nom': 'Vraie Alice'});

    final rules = EmulatorRulesService(target, api('Bearer owner'), clientFactory: api);
    final results = await rules.runTests(source, RulesGenerator.testsFor(design));
    for (final r in results) {
      expect(r.passed, isTrue, reason: '${r.testCase.label} : observé ${r.allowed}, ${r.error ?? r.details}');
    }
    expect((await owner.getDocument('users/alice'))!.data, {'nom': 'Vraie Alice'}, reason: 'donnée restaurée');
    expect(await owner.getDocument('notes/bdd_test_doc'), isNull, reason: 'document de test nettoyé');

    // Des règles ouvertes font échouer les tests attendus.
    const open = "rules_version = '2';\nservice cloud.firestore { match /databases/{database}/documents {\n"
        '  match /{document=**} { allow read, write: if true; } } }';
    expect(RulesAnalyzer.hasCritical(RulesAnalyzer.analyze(open)), isTrue);
    final bad = await rules.runTests(open, RulesGenerator.testsFor(design));
    expect(bad.where((r) => !r.passed), isNotEmpty);

    // Règles invalides : erreur de compilation.
    await expectLater(rules.deploy('service cloud.firestore { match /x { allow read: if ; } }'),
        throwsA(isA<RulesCompileException>()));
  });

  test('Parcours Authentication complet sur l\'émulateur', () async {
    final tester = AuthFlowTester(target: target, apiKey: 'fake-api-key', api: api());
    final steps = await tester.run();
    for (final s in steps) {
      expect(s.ok, isTrue, reason: '${s.label} : ${s.detail}');
    }
    expect(steps.map((s) => s.label), contains('Suppression du compte de test'));
    expect(steps.length, 9);
  });
}
