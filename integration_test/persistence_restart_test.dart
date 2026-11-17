// Vérifie la persistance après fermeture et redémarrage RÉELS de l'application.
//
// Deux lancements distincts (deux processus) partagent le même dossier :
//   flutter test integration_test/persistence_restart_test.dart -d linux \
//     --dart-define=STAGE=write --dart-define=DATA_DIR=/chemin/temporaire
//   flutter test integration_test/persistence_restart_test.dart -d linux \
//     --dart-define=STAGE=read  --dart-define=DATA_DIR=/chemin/temporaire
// Sur Android, omettre DATA_DIR : un sous-dossier « itest » du stockage privé est utilisé.
import 'dart:io';

import 'package:bddouilleur/app.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

const stage = String.fromEnvironment('STAGE');
const dataDir = String.fromEnvironment('DATA_DIR');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String root;

  Future<AppState> launch(WidgetTester tester) async {
    final paths = AppPaths(root);
    final state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase));
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: state, child: const BddouilleurApp()));
    await tester.pump(const Duration(milliseconds: 500));
    return state;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Fait défiler jusqu'à l'élément (petits écrans) puis appuie dessus.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(finder);
  }

  testWidgets('étape « $stage »', (tester) async {
    // Sans DATA_DIR (ex. Android), dossier isolé dans le stockage privé de l'app.
    root = dataDir.isNotEmpty ? dataDir : '${(await getApplicationSupportDirectory()).path}/itest';
    if (stage == 'write') {
      final dir = Directory(root);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      final state = await launch(tester);

      await tapVisible(tester, find.text('Créer mon premier projet'));
      await settle(tester);
      await tester.tap(find.text('Nouveau projet'));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Nom du projet'), 'Labo persistant');
      await tester.tap(find.text('Créer'));
      await settle(tester);

      await tester.tap(find.text('Laboratoire'));
      await settle(tester);
      await tapVisible(tester, find.text('La Fabrique'));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Nom'), 'Inventaire');
      await tapVisible(tester, find.text('Fabriquer la base'));
      await settle(tester);

      await tapVisible(tester, find.text('Créer une table'));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Nom de la table'), 'potions');
      await settle(tester);
      await tester.tap(find.text('Créer la table'));
      await settle(tester);

      await tapVisible(tester, find.text('potions'));
      await settle(tester);
      await tapVisible(tester, find.text('Ajouter le premier'));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, 'nom *'), 'Élixir de jouvence');
      await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
      await settle(tester);
      expect(find.text('Élixir de jouvence'), findsOneWidget);

      state.dispose(); // fermeture : connexions SQLite fermées
    } else if (stage == 'read') {
      expect(File('$root/bddouilleur_app.db').existsSync(), isTrue, reason: 'lancer d\'abord STAGE=write');
      final state = await launch(tester);
      expect(find.textContaining('Labo persistant'), findsWidgets, reason: 'projet actif restauré');

      await tester.tap(find.text('Projets'));
      await settle(tester);
      await tester.tap(find.text('Labo persistant').last);
      await settle(tester);
      await tapVisible(tester, find.text('Inventaire'));
      await settle(tester);
      expect(find.text('potions'), findsOneWidget);
      await tapVisible(tester, find.text('potions'));
      await settle(tester);
      expect(find.text('Élixir de jouvence'), findsOneWidget);
      state.dispose();
    } else {
      fail('STAGE doit valoir write ou read');
    }
  });
}
