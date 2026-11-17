// Captures d'écran rendues par le moteur Flutter, avec les vraies polices.
// Usage : flutter test tool/screenshots.dart  (sortie : build/screenshots/)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bddouilleur/data/secrets/secret_store.dart';
import 'package:bddouilleur/domain/firebase/firebase_target.dart';
import 'package:bddouilleur/domain/models/db_engine.dart';
import 'package:bddouilleur/presentation/firebase/firebase_hub_screen.dart';
import 'package:bddouilleur/presentation/firebase/rules_view.dart';
import 'package:bddouilleur/app.dart';
import 'package:bddouilleur/data/persistence/app_database.dart';
import 'package:bddouilleur/data/persistence/app_paths.dart';
import 'package:bddouilleur/domain/models/journal_entry.dart';
import 'package:bddouilleur/domain/models/schema.dart';
import 'package:bddouilleur/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<void> loadFonts() async {
  final cache = '${Platform.environment['HOME']}/snap/flutter/common/flutter/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final f in ['Roboto-Regular', 'Roboto-Medium', 'Roboto-Bold', 'Roboto-Italic', 'Roboto-Black']) {
    roboto.addFont(Future.value(File('$cache/$f.ttf').readAsBytesSync().buffer.asByteData()));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(File('$cache/MaterialIcons-Regular.otf').readAsBytesSync().buffer.asByteData()));
  await icons.load();
  final mono = FontLoader('monospace')
    ..addFont(Future.value(File('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf').readAsBytesSync().buffer.asByteData()));
  await mono.load();
}

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('build/screenshots').createSync(recursive: true);
    File('build/screenshots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('captures', (tester) async {
    await tester.runAsync(loadFonts);
    final tmp = Directory.systemTemp.createTempSync('bdd_shots_');
    final paths = AppPaths(tmp.path);
    final state = AppState(paths: paths, appDb: AppDatabase.open(paths.appDatabase), secrets: MemorySecretStore());
    final project = state.createProject('Boutique en ligne', 'Application Flutter de vente');
    final conn = await state.createSqliteDatabase(project, 'Catalogue');
    await state.runLogged(
      connection: conn,
      action: JournalAction.tableCreated,
      summary: 'Table « produits » créée',
      run: (c) => c.createTable(TableDefinition(name: 'produits', columns: [
        ColumnDefinition(name: 'id', type: SqlColumnType.integer, primaryKey: true, autoIncrement: true),
        ColumnDefinition(name: 'libelle', type: SqlColumnType.text, notNull: true),
        ColumnDefinition(name: 'prix', type: SqlColumnType.real, defaultValue: '0'),
        ColumnDefinition(name: 'en_stock', type: SqlColumnType.boolean, defaultValue: '1'),
      ])),
    );
    for (final (n, p) in [('Chapeau de savant', 24.9), ('Lunettes de labo', 12.5), ('Clé à molette', 8.0)]) {
      await state.runLogged(
          connection: conn,
          action: JournalAction.rowInserted,
          summary: 'Ajout « $n »',
          run: (c) => c.insertRow('produits', {'libelle': n, 'prix': p}));
    }

    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    Future<void> pump(Size size, ThemeMode mode) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      state.setThemeMode(mode);
      await tester.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: ChangeNotifierProvider<AppState>.value(value: state, child: const BddouilleurApp()),
      ));
      await tester.pumpAndSettle();
    }

    await pump(const Size(1280, 860), ThemeMode.dark);
    await shot(tester, '01_accueil_sombre');
    await pump(const Size(1280, 860), ThemeMode.light);
    await shot(tester, '02_accueil_clair');
    await pump(const Size(400, 860), ThemeMode.dark);
    await shot(tester, '03_accueil_telephone');

    await pump(const Size(1280, 860), ThemeMode.dark);
    await tester.tap(find.text('Projets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Boutique en ligne').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Catalogue'));
    await tester.pumpAndSettle();
    await shot(tester, '04_base_tables');
    await tester.tap(find.text('produits'));
    await tester.pumpAndSettle();
    await shot(tester, '05_table_donnees');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nouvelle table'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Nom de la table'), 'clients');
    await tester.pumpAndSettle();
    await shot(tester, '06_nouvelle_table');

    // --- Firebase AutoPilot (sans réseau : écrans et générateur de règles).
    final fb = state.connections.create(
      projectId: project.id!,
      name: 'demo-boutique (émulateur)',
      engine: DbEngine.firestore,
      location: 'demo-boutique',
      config: const FirebaseTarget(mode: FirebaseMode.emulator, projectId: 'demo-boutique').toJson()..remove('projectId'),
    );
    Future<void> open(Widget screen, Size size) async {
      await pump(size, ThemeMode.dark);
      tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute(builder: (_) => screen));
      await tester.pumpAndSettle();
    }

    await open(const FirebaseHubScreen(), const Size(1280, 1100));
    await shot(tester, '07_firebase_autopilot');
    await open(RulesEditorScreen(connection: fb), const Size(1280, 1300));
    await shot(tester, '08_regles_generateur');
    await open(const FirebaseHubScreen(), const Size(400, 860));
    await shot(tester, '09_firebase_telephone');

    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    tester.view.reset();
    state.dispose();
    tmp.deleteSync(recursive: true);
  });
}
