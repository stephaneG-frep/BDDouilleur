// Parcours utilisateur réel de Firebase AutoPilot contre la VRAIE suite
// d'émulateurs Firebase (Firestore + Auth), via l'interface de l'application.
//
//   tool/run_emulator_tests.sh            (tests Dart)
//   cd tool/firebase_emulator && firebase emulators:exec --only firestore,auth \
//     --project demo-bddouilleur "cd ../.. && flutter test integration_test/firebase_emulator_ui_test.dart -d linux"
import 'dart:io';

import 'package:bddouilleur/app.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/presentation/firebase/firebase_admin_views.dart';
import 'package:bddouilleur/presentation/firebase/rules_view.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(WidgetTester tester, Finder finder, {int seconds = 20}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) {
        // Laisse finir les transitions de page avant d'interagir.
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        return;
      }
    }
    fail('Introuvable après ${seconds}s : $finder');
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('émulateur : connexion, document, règles testées et déployées, parcours Auth', (tester) async {
    await http.delete(Uri.parse(
        'http://127.0.0.1:8080/emulator/v1/projects/demo-bddouilleur/databases/(default)/documents'));
    final root = Directory.systemTemp.createTempSync('bdd_fb_ui_').path;
    final paths = AppPaths(root);
    final state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
    state.createProject('Labo Firebase', '');
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: state, child: const BddouilleurApp()));
    await tester.pump(const Duration(milliseconds: 500));

    // Module Firebase AutoPilot depuis le tableau de bord.
    await tester.scrollUntilVisible(find.text('Firebase AutoPilot'), 250, scrollable: find.byType(Scrollable).first);
    await tapVisible(tester, find.text('Firebase AutoPilot'));
    await waitFor(tester, find.text('Connecter un émulateur'));
    expect(find.text('Configurer le client OAuth'), findsOneWidget);
    await tapVisible(tester, find.text('Connecter un émulateur'));
    await waitFor(tester, find.text('Vérifier et connecter'));
    await tester.tap(find.text('Vérifier et connecter'));
    await waitFor(tester, find.text('Nouveau document'));

    // Création d'un document (la collection naît avec lui).
    await tester.tap(find.text('Nouveau document'));
    await waitFor(tester, find.text('Créer'));
    await tester.enterText(find.widgetWithText(TextField, 'Collection'), 'potions');
    await tester.enterText(find.widgetWithText(TextField, 'Identifiant du document (facultatif)'), 'elixir');
    await tester.enterText(find.widgetWithText(TextField, 'Contenu (JSON)'),
        '{"nom": "Élixir de jouvence", "stock": 12, "creeLe": {"\$timestamp": "2026-11-17T10:00:00Z"}}');
    await tester.tap(find.text('Créer'));
    await waitFor(tester, find.text('Élixir de jouvence'));
    expect(find.text('entier'), findsOneWidget);
    expect(find.text('date'), findsOneWidget);
    await tester.tap(find.byType(BackButton).last);
    await waitFor(tester, find.text('potions'));

    // Vérification indépendante : le document existe réellement dans l'émulateur.
    final raw = await http.get(
        Uri.parse('http://127.0.0.1:8080/v1/projects/demo-bddouilleur/databases/(default)/documents/potions/elixir'),
        headers: {'Authorization': 'Bearer owner'});
    expect(raw.statusCode, 200);
    expect(raw.body, contains('Élixir de jouvence'));

    // Règles : générateur, tests réels, déploiement.
    await tester.tap(find.text('Règles'));
    await waitFor(tester, find.text('Générateur et tests de règles'));
    await tester.tap(find.text('Générateur et tests de règles'));
    await waitFor(tester, find.text('1. Collections et accès'));
    final editorList =
        find.descendant(of: find.byType(RulesEditorScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Lancer 7 tests'), 300, scrollable: editorList);
    await tapVisible(tester, find.text('Lancer 7 tests'));
    // Attend la fin réelle des tests (entrée de journal), puis fait défiler jusqu'au résultat.
    final end = DateTime.now().add(const Duration(seconds: 40));
    while (!state.journal.recent().any((e) => e.summary.startsWith('Règles testées')) && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tester.scrollUntilVisible(find.textContaining('tests conformes'), 200, scrollable: editorList);
    expect(find.textContaining('7 / 7 tests conformes'), findsOneWidget);
    await tapVisible(tester, find.text('Déployer'));
    await waitFor(tester, find.text('Déployer').last);
    await tester.tap(find.widgetWithText(FilledButton, 'Déployer').last);
    await waitFor(tester, find.text('Règles actives'));
    await waitFor(tester, find.textContaining('match /users/{uid}'));

    // Authentication : parcours complet.
    await tester.tap(find.text('Authentication'));
    await waitFor(tester, find.text('Lancer le parcours de test'));
    await tester.tap(find.text('Lancer le parcours de test'));
    await waitFor(tester, find.textContaining('Inscription e-mail'), seconds: 30);
    expect(find.byIcon(Icons.cancel_rounded), findsNothing);
    await tester.scrollUntilVisible(find.text('Suppression du compte de test'), 200,
        scrollable: find.descendant(of: find.byType(AuthView), matching: find.byType(Scrollable)).first);
    expect(find.byIcon(Icons.cancel_rounded), findsNothing);

    // Journal : opérations réelles enregistrées avec leurs requêtes.
    final entries = state.journal.recent();
    expect(entries.any((e) => e.summary.contains('Document créé dans « potions »') && e.sql!.contains('POST http://127.0.0.1:8080')),
        isTrue);
    expect(entries.any((e) => e.summary.startsWith('Règles déployées sur l\'émulateur (7/7')), isTrue);
    expect(entries.any((e) => e.summary.contains('9/9 étapes réussies')), isTrue);
    state.dispose();
    Directory(root).deleteSync(recursive: true);
  });
}
