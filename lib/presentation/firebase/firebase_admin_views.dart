import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/firebase/auth_service.dart';
import '../../data/firebase/firebase_diagnostic.dart';
import '../../data/firebase/firebase_management.dart';
import '../../data/firebase/firestore_admin.dart';
import '../../domain/firebase/flutterfire_config.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../state/app_state.dart';
import 'firebase_widgets.dart';

// =============================================================== Index

class IndexesView extends StatefulWidget {
  const IndexesView({super.key, required this.connection});
  final DbConnection connection;

  @override
  State<IndexesView> createState() => _IndexesViewState();
}

class _IndexesViewState extends State<IndexesView> {
  late Future<List<FirestoreIndexInfo>> _future = _load();

  Future<List<FirestoreIndexInfo>> _load() => FirestoreAdminService(context.read<AppState>().googleApi())
      .listIndexes(widget.connection.location, databaseId: widget.connection.firebase.databaseId);

  @override
  Widget build(BuildContext context) {
    if (widget.connection.firebase.isEmulator) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: MascotTip(
          message: 'L\'émulateur Firestore n\'exige aucun index composite et n\'expose pas leur gestion. '
              'Sur un vrai projet, une requête qui combine filtres et tris sur plusieurs champs échoue avec '
              'FAILED_PRECONDITION tant que l\'index n\'existe pas : vous pourrez le créer ici.',
        ),
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'newindex',
        icon: const Icon(Icons.add_rounded),
        label: const Text('Index composite'),
        onPressed: () => _create(context),
      ),
      body: FutureBuilder<List<FirestoreIndexInfo>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return EmptyState(message: '${snap.error}');
          final list = snap.data!;
          return RefreshIndicator(
            onRefresh: () async => setState(() { _future = _load(); }),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                const MascotTip(
                    message: 'Les index sur un seul champ sont automatiques. Seuls les index composites sont listés ici.'),
                const SizedBox(height: 12),
                if (list.isEmpty) const Text('Aucun index composite.'),
                for (final i in list)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(i.collectionGroup, style: AppTheme.mono),
                      subtitle: Text('${i.fields.map((f) => f.label).join(', ')}\n'
                          '${i.queryScope == 'COLLECTION_GROUP' ? 'Groupe de collections' : 'Collection'} • ${i.stateLabel}'),
                      isThreeLine: true,
                      trailing: IconButton(
                        tooltip: 'Supprimer',
                        icon: const Icon(Icons.delete_rounded),
                        onPressed: () => _delete(context, i),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final result = await showDialog<(String, List<IndexField>, bool)>(context: context, builder: (_) => const _IndexDialog());
    if (result == null || !context.mounted) return;
    final (cg, fields, groupScope) = result;
    final state = context.read<AppState>();
    final api = state.googleApi();
    try {
      await state.runFirebase(
        api: api,
        connection: widget.connection,
        action: JournalAction.firestoreIndexCreated,
        summary: 'Index composite demandé sur « $cg » : ${fields.map((f) => f.label).join(', ')}',
        run: () => FirestoreAdminService(api).createIndex(widget.connection.location, cg, fields,
            databaseId: widget.connection.firebase.databaseId, collectionGroupScope: groupScope),
      );
      if (context.mounted) showSuccess(context, 'Construction lancée : l\'index passera à « Prêt » d\'ici quelques minutes.');
      setState(() { _future = _load(); });
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _delete(BuildContext context, FirestoreIndexInfo i) async {
    final ok = await confirmByTyping(context,
        title: 'Supprimer l\'index ?',
        message: 'Les requêtes qui en dépendent échoueront (FAILED_PRECONDITION) jusqu\'à sa recréation.',
        expected: i.collectionGroup);
    if (!ok || !context.mounted) return;
    final state = context.read<AppState>();
    final api = state.googleApi();
    try {
      await state.runFirebase(
        api: api,
        connection: widget.connection,
        action: JournalAction.firestoreIndexDeleted,
        summary: 'Index supprimé sur « ${i.collectionGroup} »',
        run: () => FirestoreAdminService(api).deleteIndex(i.name),
      );
      setState(() { _future = _load(); });
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

class _IndexDialog extends StatefulWidget {
  const _IndexDialog();

  @override
  State<_IndexDialog> createState() => _IndexDialogState();
}

class _IndexDialogState extends State<_IndexDialog> {
  final _cg = TextEditingController();
  final List<(TextEditingController, IndexOrder)> _fields = [
    (TextEditingController(), IndexOrder.ascending),
    (TextEditingController(), IndexOrder.descending),
  ];
  bool _group = false;
  String? _error;

  @override
  void dispose() {
    _cg.dispose();
    for (final f in _fields) {
      f.$1.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nouvel index composite'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _cg, decoration: const InputDecoration(labelText: 'Collection (ou groupe)')),
            SwitchListTile(
              value: _group,
              onChanged: (v) => setState(() => _group = v),
              title: const Text('Portée « groupe de collections »'),
              subtitle: const Text('Pour les requêtes collectionGroup() sur toutes les sous-collections de ce nom.'),
            ),
            for (final (i, f) in _fields.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(child: TextField(controller: f.$1, decoration: InputDecoration(labelText: 'Champ ${i + 1}'))),
                  const SizedBox(width: 8),
                  DropdownButton<IndexOrder>(
                    value: f.$2,
                    onChanged: (v) => setState(() => _fields[i] = (f.$1, v!)),
                    items: const [
                      DropdownMenuItem(value: IndexOrder.ascending, child: Text('Croissant')),
                      DropdownMenuItem(value: IndexOrder.descending, child: Text('Décroissant')),
                      DropdownMenuItem(value: IndexOrder.arrayContains, child: Text('Contient')),
                    ],
                  ),
                ]),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text('Champ'),
                onPressed: () => setState(() => _fields.add((TextEditingController(), IndexOrder.ascending))),
              ),
            ),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            final cg = _cg.text.trim();
            final fields = [
              for (final f in _fields)
                if (f.$1.text.trim().isNotEmpty) IndexField(f.$1.text.trim(), f.$2)
            ];
            if (cg.isEmpty || cg.contains('/')) return setState(() => _error = 'Nom de collection simple attendu.');
            if (fields.length < 2) return setState(() => _error = 'Au moins deux champs.');
            if (fields.where((f) => f.order == IndexOrder.arrayContains).length > 1) {
              return setState(() => _error = 'Un seul champ « Contient » par index.');
            }
            Navigator.pop(context, (cg, fields, _group));
          },
          child: const Text('Créer'),
        ),
      ],
    );
  }
}

// ======================================================= Authentication

class AuthView extends StatefulWidget {
  const AuthView({super.key, required this.connection});
  final DbConnection connection;

  @override
  State<AuthView> createState() => _AuthViewState();
}

class _AuthViewState extends State<AuthView> {
  Future<AuthConfigInfo?>? _config;
  List<AuthTestStep>? _steps;
  bool _testing = false;

  bool get _emulator => widget.connection.firebase.isEmulator;

  @override
  void initState() {
    super.initState();
    if (!_emulator) _config = _loadConfig();
  }

  Future<AuthConfigInfo?> _loadConfig() =>
      AuthAdminService(context.read<AppState>().googleApi(), widget.connection.location).getConfig();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!_emulator) ...[
          Text('Configuration', style: text.titleMedium),
          const SizedBox(height: 8),
          FutureBuilder<AuthConfigInfo?>(
            future: _config,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const LinearProgressIndicator();
              if (snap.hasError) return Text('${snap.error}', style: const TextStyle(color: BddColors.rose));
              final c = snap.data;
              if (c == null) {
                return MascotTip(
                  title: 'Authentication pas encore démarré',
                  message: 'Google exige un premier démarrage depuis la console : ouvrez '
                      '${AuthAdminService.consoleUrl(widget.connection.location)} puis cliquez sur « Commencer ». '
                      'Je pourrai ensuite tout configurer d\'ici.',
                );
              }
              return Card(
                child: Column(children: [
                  _flag('E-mail / mot de passe', c.emailEnabled),
                  _flag('Protection contre l\'énumération des e-mails', c.emailEnumerationProtection),
                  _flag('Connexion anonyme', c.anonymousEnabled, goodWhen: false),
                  ListTile(
                    dense: true,
                    title: const Text('Domaines autorisés'),
                    subtitle: Text(c.authorizedDomains.isEmpty ? 'aucun' : c.authorizedDomains.join(', ')),
                  ),
                  if (!c.emailEnabled || !c.emailEnumerationProtection)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: BusyButton(
                        label: 'Activer e-mail / mot de passe + protection',
                        icon: Icons.lock_person_rounded,
                        onPressed: () => _enableEmail(context),
                      ),
                    ),
                ]),
              );
            },
          ),
          const SizedBox(height: 12),
          MascotTip(
            title: 'Connexion avec Google',
            message: 'Ce fournisseur exige un client OAuth Web et l\'écran de consentement du projet : Google ne permet '
                'de l\'activer de bout en bout que depuis la console (Authentication → Méthodes de connexion → Google). '
                'Pour Android, ajoutez aussi l\'empreinte SHA-1 de votre clé de signature à l\'application.',
          ),
          const SizedBox(height: 16),
        ],
        Text('Tester les parcours', style: text.titleMedium),
        const SizedBox(height: 8),
        Text(_emulator
            ? 'Sur l\'émulateur : inscription, mauvais mot de passe refusé, connexion, renouvellement de session, '
                'vérification d\'e-mail et réinitialisation du mot de passe (codes lus dans l\'émulateur), puis suppression du compte.'
            : 'Sur le vrai projet : un compte de test (adresse fictive @bddouilleur.test) est créé, utilisé puis supprimé. '
                'La vérification d\'e-mail et la réinitialisation sont demandées à Firebase, mais leurs liens ne peuvent '
                'pas être suivis sans boîte de réception.'),
        const SizedBox(height: 12),
        BusyButton(label: 'Lancer le parcours de test', icon: Icons.play_arrow_rounded, onPressed: () => _runTests(context)),
        if (_testing) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
        if (_steps != null) ...[
          const SizedBox(height: 12),
          for (final s in _steps!)
            ListTile(
              dense: true,
              leading: Icon(s.ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
                  color: s.ok ? BddColors.vert : BddColors.rose),
              title: Text(s.label),
              subtitle: s.detail == null ? null : Text(s.detail!),
            ),
        ],
      ],
    );
  }

  Widget _flag(String label, bool on, {bool goodWhen = true}) => ListTile(
        dense: true,
        leading: Icon(on ? Icons.toggle_on_rounded : Icons.toggle_off_rounded,
            color: on == goodWhen ? BddColors.vert : BddColors.orange, size: 32),
        title: Text(label),
        trailing: Text(on ? 'activé' : 'désactivé'),
      );

  Future<void> _enableEmail(BuildContext context) async {
    final ok = await confirm(context,
        title: 'Activer la connexion par e-mail ?',
        message: 'Sur le projet « ${widget.connection.location} » :\n• fournisseur e-mail / mot de passe activé ;\n'
            '• protection contre l\'énumération des e-mails activée.\nAucun coût sur le plan Spark.',
        action: 'Activer');
    if (!ok || !context.mounted) return;
    final state = context.read<AppState>();
    final api = state.googleApi();
    try {
      await state.runFirebase(
        api: api,
        connection: widget.connection,
        action: JournalAction.authConfigured,
        summary: 'Authentication : e-mail / mot de passe activé, protection contre l\'énumération active',
        run: () => AuthAdminService(api, widget.connection.location).enableEmailPassword(enumerationProtection: true),
      );
      setState(() { _config = _loadConfig(); });
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _runTests(BuildContext context) async {
    final state = context.read<AppState>();
    String apiKey = 'fake-api-key';
    if (!_emulator) {
      final key = await _pickApiKey(context, state);
      if (key == null || !context.mounted) return;
      final ok = await confirm(context,
          title: 'Créer un compte de test ?',
          message: 'Un compte fictif sera créé sur le projet « ${widget.connection.location} », utilisé, puis supprimé.',
          action: 'Lancer');
      if (!ok || !context.mounted) return;
      apiKey = key;
    }
    setState(() {
      _testing = true;
      _steps = null;
    });
    final steps = await AuthFlowTester(target: widget.connection.firebase, apiKey: apiKey, api: state.anonymousApi()).run();
    final ok = steps.every((s) => s.ok);
    state.journal.log(
      projectId: widget.connection.projectId,
      connectionId: widget.connection.id,
      action: JournalAction.authTested,
      summary: 'Parcours Authentication : ${steps.where((s) => s.ok).length}/${steps.length} étapes réussies',
      success: ok,
      error: ok ? null : steps.where((s) => !s.ok).map((s) => '${s.label} : ${s.detail}').join('\n'),
    );
    if (mounted) {
      setState(() {
        _steps = steps;
        _testing = false;
      });
    }
  }

  /// Clé d'API client lue dans la configuration réelle d'une application Android.
  Future<String?> _pickApiKey(BuildContext context, AppState state) async {
    try {
      final mgmt = FirebaseManagementService(state.googleApi());
      final apps = await mgmt.listAndroidApps(widget.connection.location);
      if (apps.isEmpty) {
        if (context.mounted) {
          showError(context, 'Enregistrez d\'abord une application Android (onglet Configuration) : '
              'sa clé d\'API sert aux tests.');
        }
        return null;
      }
      final cfg = GoogleServicesConfig.parse(await mgmt.androidConfigFile(widget.connection.location, apps.first.appId));
      return cfg.clientFor(apps.first.packageName)?.apiKey;
    } catch (e) {
      if (context.mounted) showError(context, e);
      return null;
    }
  }
}

// ======================================================== Configuration

class ConfigView extends StatefulWidget {
  const ConfigView({super.key, required this.connection});
  final DbConnection connection;

  @override
  State<ConfigView> createState() => _ConfigViewState();
}

class _ConfigViewState extends State<ConfigView> {
  late Future<(List<AndroidAppInfo>, Set<String>, bool?)> _future = _load();

  String get _pid => widget.connection.location;

  Future<(List<AndroidAppInfo>, Set<String>, bool?)> _load() async {
    final mgmt = FirebaseManagementService(context.read<AppState>().googleApi());
    final apps = await mgmt.listAndroidApps(_pid);
    final services = await mgmt.enabledServices(_pid);
    final billing = await mgmt.billingEnabled(_pid);
    return (apps, services, billing);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(List<AndroidAppInfo>, Set<String>, bool?)>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snap.hasError) return EmptyState(message: '${snap.error}');
        final (apps, services, billing) = snap.data!;
        final text = Theme.of(context).textTheme;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Applications Android', style: text.titleMedium),
            const SizedBox(height: 8),
            if (apps.isEmpty) const Text('Aucune application enregistrée.'),
            for (final a in apps)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const Icon(Icons.android_rounded, color: BddColors.vert),
                  title: Text(a.packageName, style: AppTheme.mono),
                  subtitle: Text(a.appId),
                  trailing: FilledButton.tonal(
                    onPressed: () => _export(context, a),
                    child: const Text('Fichiers FlutterFire'),
                  ),
                ),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.add_rounded),
              label: const Text('Enregistrer une application Android'),
              onPressed: () => _register(context),
            ),
            const SizedBox(height: 16),
            Text('Services', style: text.titleMedium),
            for (final s in FirebaseService.values)
              ListTile(
                dense: true,
                leading: Icon(services.contains(s.id) ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                    color: services.contains(s.id) ? BddColors.vert : BddColors.orange),
                title: Text(s.label),
                subtitle: Text(s.id),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.payments_rounded),
              title: Text(billing == null
                  ? 'Facturation : non lisible'
                  : billing
                      ? 'Facturation active (Blaze)'
                      : 'Sans facturation (Spark)'),
              subtitle: const Text('BDDouilleur n\'active jamais la facturation.'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _register(BuildContext context) async {
    final ctrl = TextEditingController();
    final pkg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Application Android'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Nom de paquet (applicationId)', hintText: 'fr.monentreprise.monapp'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Enregistrer')),
        ],
      ),
    );
    ctrl.dispose();
    if (pkg == null || !context.mounted) return;
    final err = FirebaseManagementService.validatePackageName(pkg);
    if (err != null) return showError(context, err);
    final state = context.read<AppState>();
    final api = state.googleApi();
    try {
      await state.runFirebase(
        api: api,
        connection: widget.connection,
        action: JournalAction.firebaseAutopilot,
        summary: 'Application Android « $pkg » enregistrée',
        run: () => FirebaseManagementService(api).createAndroidApp(_pid, pkg, pkg.split('.').last),
      );
      setState(() { _future = _load(); });
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _export(BuildContext context, AndroidAppInfo app) async {
    final state = context.read<AppState>();
    try {
      final json = await FirebaseManagementService(state.googleApi()).androidConfigFile(_pid, app.appId);
      if (!context.mounted) return;
      await showDialog<void>(
          context: context,
          builder: (_) => FlutterFireExportDialog(
              googleServicesJson: json, packageName: app.packageName, journalProjectId: widget.connection.projectId));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

/// Écrit google-services.json et lib/firebase_options.dart dans un projet Flutter.
class FlutterFireExportDialog extends StatefulWidget {
  const FlutterFireExportDialog(
      {super.key, required this.googleServicesJson, required this.packageName, this.journalProjectId});
  final String googleServicesJson;
  final String packageName;
  final int? journalProjectId;

  @override
  State<FlutterFireExportDialog> createState() => _FlutterFireExportDialogState();
}

class _FlutterFireExportDialogState extends State<FlutterFireExportDialog> {
  final _form = GlobalKey<FormState>();
  final _dir = TextEditingController();
  String? _report;

  @override
  void dispose() {
    _dir.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = GoogleServicesConfig.parse(widget.googleServicesJson);
    final options = FlutterFireGenerator.firebaseOptions(cfg, widget.packageName);
    return AlertDialog(
      title: const Text('Fichiers FlutterFire'),
      content: SizedBox(
        width: 620,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Configuration réelle de « ${widget.packageName} » (projet ${cfg.projectId}).'),
              const SizedBox(height: 12),
              FolderField(
                controller: _dir,
                label: 'Dossier du projet Flutter',
                helper: 'Les fichiers existants sont conservés en .bak.',
                validator: validateFlutterProject,
              ),
              const SizedBox(height: 12),
              ExpansionTile(
                title: const Text('lib/firebase_options.dart'),
                tilePadding: EdgeInsets.zero,
                children: [CodeBlock(options)],
              ),
              ExpansionTile(
                title: const Text('android/app/google-services.json'),
                tilePadding: EdgeInsets.zero,
                children: [CodeBlock(const JsonEncoder.withIndent('  ').convert(jsonDecode(widget.googleServicesJson)))],
              ),
              if (_report != null) ...[
                const SizedBox(height: 8),
                Text(_report!, style: const TextStyle(color: BddColors.vert)),
              ],
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer')),
        if (_report == null)
          FilledButton(
            onPressed: () {
              if (!_form.currentState!.validate()) return;
              final dir = _dir.text.trim();
              final state = context.read<AppState>();
              try {
                final lines = [
                  FlutterFirebaseDiagnostic.writeWithBackup(
                      p.join(dir, 'android', 'app', 'google-services.json'), widget.googleServicesJson),
                  FlutterFirebaseDiagnostic.writeWithBackup(p.join(dir, 'lib', 'firebase_options.dart'), options),
                ];
                // Vérification : relecture du fichier écrit.
                final back = File(p.join(dir, 'lib', 'firebase_options.dart')).readAsStringSync();
                if (!FlutterFireGenerator.projectIdsIn(back).contains(cfg.projectId)) {
                  throw StateError('Vérification échouée : firebase_options.dart relu ne contient pas le projet.');
                }
                state.journal.log(
                  projectId: widget.journalProjectId,
                  action: JournalAction.firebaseConfigWritten,
                  summary: 'Configuration FlutterFire de « ${widget.packageName} » écrite\n${lines.join('\n')}',
                );
                setState(() => _report = '${lines.join('\n')}\n\nÉtape suivante : flutter pub add firebase_core, '
                    'puis await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform) dans main().');
              } catch (e) {
                showError(context, e);
              }
            },
            child: const Text('Écrire les fichiers'),
          ),
      ],
    );
  }
}
