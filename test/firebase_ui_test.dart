import 'dart:io';

import 'package:bddouilleur/app.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/presentation/firebase/firebase_hub_screen.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

void main() {
  late Directory tmp;
  late AppState state;
  late MemorySecretStore secrets;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bdd_fbui_');
    final paths = AppPaths(tmp.path);
    secrets = MemorySecretStore();
    state = AppState(
      paths: paths,
      appDb: AppDatabase.open(paths.appDatabase),
      secrets: secrets,
      // Aucun émulateur ne tourne : toute requête échoue comme un serveur injoignable.
      httpClient: MockClient((_) async => throw const SocketException('Connexion refusée')),
    );
    state.createProject('Labo', '');
  });

  tearDown(() {
    state.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pumpHub(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: Builder(builder: (_) => const BddouilleurApp()),
    ));
    await tester.pumpAndSettle();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute(builder: (_) => const FirebaseHubScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('sans client OAuth : configuration guidée, actions Google désactivées', (tester) async {
    await pumpHub(tester);
    expect(find.text('Configurer le client OAuth'), findsOneWidget);
    final create = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Créer un projet complet'));
    expect(create.onPressed, isNull, reason: 'pas de bouton actif sans compte Google');

    await tester.tap(find.text('Configurer le client OAuth'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'ID client'), 'pas-un-id');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Format attendu'), findsOneWidget);
    expect(secrets.values, isEmpty);

    await tester.enterText(find.widgetWithText(TextFormField, 'ID client'), '123-abc.apps.googleusercontent.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Code secret du client'), 'GOCSPX-secret');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(secrets.values[SecretKeys.oauthClientId], '123-abc.apps.googleusercontent.com');
    expect(find.text('Se connecter avec Google'), findsOneWidget);
    // Le secret n'apparaît nulle part dans la base interne.
    final dump = state.appDb.db.select("SELECT group_concat(value) AS v FROM settings").first['v'] ?? '';
    expect('$dump', isNot(contains('GOCSPX')));
    expect(state.journal.recent().map((e) => '${e.summary}${e.sql}${e.error}').join(), isNot(contains('GOCSPX')));
  });

  testWidgets('émulateur : identifiant non « demo- » refusé, émulateur absent expliqué', (tester) async {
    await pumpHub(tester);
    await tester.tap(find.text('Connecter un émulateur'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Identifiant du projet de démonstration'), 'mon-vrai-projet');
    await tester.tap(find.text('Vérifier et connecter'));
    await tester.pumpAndSettle();
    expect(find.textContaining('demo-'), findsWidgets);

    await tester.enterText(find.widgetWithText(TextFormField, 'Identifiant du projet de démonstration'), 'demo-labo');
    await tester.tap(find.text('Vérifier et connecter'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Émulateur injoignable'), findsOneWidget);
    expect(find.textContaining('firebase emulators:start'), findsWidgets);
    expect(state.connections.all(), isEmpty, reason: 'aucune connexion enregistrée sans vérification réelle');
  });
}
