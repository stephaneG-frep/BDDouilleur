import 'dart:io';

import 'package:bddouilleur/app.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  late Directory tmp;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bddouilleur_ui_');
    final paths = AppPaths(tmp.path);
    state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase));
  });

  tearDown(() {
    state.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester, {Size size = const Size(1400, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: state, child: const BddouilleurApp()));
    await tester.pumpAndSettle();
  }

  testWidgets('accueil : nom, slogan, mascotte et les 10 modules', (tester) async {
    await pumpApp(tester);
    expect(find.text('BDDouilleur'), findsOneWidget);
    expect(find.text('Vos bases de données ? Je m\'en débrouille !'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Mascotte BDDouilleur')), findsWidgets);
    for (final name in ['La Fabrique', 'Firebase AutoPilot', 'Le Détective', 'Le Réparateur', 'Le Connecteur',
      'Le Schématiseur', 'Le Coffre-fort', 'Le Gardien', 'Le Professeur', 'AutoPilot']) {
      await tester.scrollUntilVisible(find.text(name), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text(name), findsOneWidget);
    }
  });

  testWidgets('affichage téléphone sans débordement', (tester) async {
    await pumpApp(tester, size: const Size(390, 844));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('parcours complet : projet → base → table → enregistrement', (tester) async {
    await pumpApp(tester);

    // Projet
    await tester.tap(find.text('Créer mon premier projet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nouveau projet'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Nom du projet'), 'Boutique');
    await tester.tap(find.text('Créer'));
    await tester.pumpAndSettle();
    expect(find.text('Boutique'), findsWidgets);
    expect(state.projects.all().single.name, 'Boutique');

    // Base via La Fabrique
    await tester.tap(find.text('Laboratoire'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('La Fabrique'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Nom'), 'Catalogue');
    await tester.tap(find.text('Fabriquer la base'));
    await tester.pumpAndSettle();
    final conn = state.connections.all().single;
    expect(File(conn.location).existsSync(), isTrue);
    expect(find.textContaining('Cette base est vide'), findsOneWidget);

    // Table
    await tester.tap(find.text('Créer une table'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Nom de la table'), 'produits');
    await tester.pumpAndSettle();
    expect(find.textContaining('CREATE TABLE "produits"'), findsOneWidget);
    await tester.tap(find.text('Créer la table'));
    await tester.pumpAndSettle();
    expect(find.text('produits'), findsOneWidget);

    // Enregistrement
    await tester.tap(find.text('produits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajouter le premier'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'nom *'), 'Chapeau de savant');
    await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
    await tester.pumpAndSettle();
    expect(find.text('Chapeau de savant'), findsOneWidget);

    final connector = await state.connectorFor(conn);
    final rows = await connector.readRows('produits');
    expect(rows.rows.single['nom'], 'Chapeau de savant');
    expect(rows.rows.single['id'], 1);
  });
}
