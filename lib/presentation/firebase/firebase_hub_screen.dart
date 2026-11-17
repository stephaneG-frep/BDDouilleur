import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/mascot.dart';
import '../../data/google/google_auth.dart';
import '../../domain/firebase/firebase_target.dart';
import '../../domain/models/db_engine.dart';
import '../../state/app_state.dart';
import 'autopilot_wizard_screen.dart';
import 'firebase_connection_screen.dart';
import 'firebase_projects_screen.dart';
import 'firebase_widgets.dart';
import 'rescue_screen.dart';

/// Accueil du module Firebase AutoPilot.
class FirebaseHubScreen extends StatefulWidget {
  const FirebaseHubScreen({super.key});

  @override
  State<FirebaseHubScreen> createState() => _FirebaseHubScreenState();
}

class _FirebaseHubScreenState extends State<FirebaseHubScreen> {
  OAuthClientConfig? _client;
  bool _signedIn = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final auth = context.read<AppState>().googleAuth;
    try {
      final client = await auth.clientConfig();
      final signedIn = await auth.isSignedIn;
      if (!mounted) return;
      setState(() {
        _client = client;
        _signedIn = signedIn;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Trousseau système indisponible : $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final project = state.activeProject;
    final firebaseConns = project == null
        ? const []
        : state.connections.forProject(project.id!).where((c) => c.engine == DbEngine.firestore).toList();
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Firebase AutoPilot')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GradientCard(
            colors: const [BddColors.orange, BddColors.rose],
            child: Row(children: [
              const Mascot(size: 84, animate: false),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Firebase AutoPilot', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const Text('Créer, connecter, sécuriser et diagnostiquer vos projets Firebase, '
                      'via les API officielles de Google.'),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          if (project == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: MascotTip(
                title: 'Aucun projet actif',
                message: 'Les connexions Firebase sont rangées dans un projet BDDouilleur. '
                    'Créez ou choisissez un projet dans l\'onglet Projets.',
              ),
            ),
          _accountSection(context, state),
          const SizedBox(height: 12),
          SectionCard(
            icon: Icons.science_rounded,
            title: 'Environnement de test (émulateurs)',
            color: BddColors.turquoise,
            children: [
              const Text('La suite d\'émulateurs Firebase fonctionne sur votre machine : aucun compte Google, '
                  'aucune facturation, aucune donnée réelle. Idéal pour apprendre et tester vos règles.'),
              const SizedBox(height: 8),
              const CodeBlock('firebase emulators:start --only firestore,auth --project demo-monprojet'),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.link_rounded),
                label: const Text('Connecter un émulateur'),
                onPressed: project == null ? null : () => _connectEmulator(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            icon: Icons.cloud_rounded,
            title: 'Projets Firebase de votre compte',
            color: BddColors.orange,
            children: [
              const Text('Créez un projet complet ou connectez un projet existant (rien n\'est jamais recréé).'),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  icon: const Icon(Icons.rocket_launch_rounded),
                  label: const Text('Créer un projet complet'),
                  onPressed: _signedIn
                      ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AutoPilotWizardScreen()))
                      : null,
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.list_alt_rounded),
                  label: const Text('Mes projets Firebase'),
                  onPressed: _signedIn
                      ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FirebaseProjectsScreen()))
                      : null,
                ),
              ]),
              if (!_signedIn)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Connectez d\'abord votre compte Google.', style: TextStyle(fontStyle: FontStyle.italic)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            icon: Icons.medical_services_rounded,
            title: 'Firebase Rescue',
            color: BddColors.rose,
            children: [
              const Text('« Pourquoi Firebase ne fonctionne pas dans mon application ? » '
                  'Analyse d\'un projet Flutter : configuration, initialisation, Android, règles.'),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.troubleshoot_rounded),
                label: const Text('Lancer un diagnostic'),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RescueScreen())),
              ),
            ],
          ),
          if (firebaseConns.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Connexions Firebase du projet « ${project!.name} »', style: text.titleMedium),
            const SizedBox(height: 8),
            for (final c in firebaseConns)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(c.firebase.isEmulator ? Icons.science_rounded : Icons.local_fire_department_rounded,
                      color: c.firebase.isEmulator ? BddColors.turquoise : BddColors.orange),
                  title: Text(c.name),
                  subtitle: Text(c.firebase.description),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => FirebaseConnectionScreen(connection: c))),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _accountSection(BuildContext context, AppState state) {
    final children = <Widget>[];
    if (_loading) {
      children.add(const LinearProgressIndicator());
    } else if (_error != null || state.secretsError != null) {
      children.add(MascotTip(
        title: 'Stockage sécurisé indisponible',
        message: '${_error ?? state.secretsError}\n\nSous Linux, BDDouilleur range les jetons dans le trousseau '
            'GNOME (libsecret). Ouvrez une session de bureau avec le trousseau déverrouillé, puis réessayez.',
      ));
      children.add(TextButton(onPressed: _refresh, child: const Text('Réessayer')));
    } else if (_client == null) {
      children.addAll([
        const Text('Pour agir sur votre compte, BDDouilleur utilise VOTRE client OAuth Google (type « Application de bureau »). '
            'Aucun identifiant n\'est intégré à l\'application, et votre mot de passe Google n\'est jamais demandé.'),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.key_rounded),
          label: const Text('Configurer le client OAuth'),
          onPressed: () => _configureClient(context),
        ),
      ]);
    } else if (!_signedIn) {
      children.addAll([
        Text('Client OAuth : ${_client!.clientId.split('-').first}-…', style: AppTheme.mono),
        const SizedBox(height: 8),
        const Text('La connexion s\'ouvre dans votre navigateur. Vous y choisissez votre compte et autorisez '
            'explicitement l\'accès à Google Cloud et Firebase.'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          BusyButton(label: 'Se connecter avec Google', icon: Icons.login_rounded, onPressed: () => _signIn(context)),
          TextButton(onPressed: () => _configureClient(context), child: const Text('Modifier le client')),
        ]),
      ]);
    } else {
      children.addAll([
        Row(children: [
          const Icon(Icons.verified_user_rounded, color: BddColors.vert),
          const SizedBox(width: 8),
          Expanded(child: Text(state.googleEmail ?? 'Compte connecté', style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 8),
        const Text('Jetons rangés dans le trousseau du système, jamais dans le journal.'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Se déconnecter'),
            onPressed: () => _signOut(context),
          ),
          TextButton(onPressed: () => _configureClient(context), child: const Text('Client OAuth')),
        ]),
      ]);
    }
    return SectionCard(icon: Icons.account_circle_rounded, title: 'Compte Google', children: children);
  }

  Future<void> _signIn(BuildContext context) async {
    final state = context.read<AppState>();
    try {
      final email = await state.signInGoogle();
      if (context.mounted) showSuccess(context, 'Connecté : $email');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
    await _refresh();
  }

  Future<void> _signOut(BuildContext context) async {
    final ok = await confirm(context,
        title: 'Se déconnecter ?',
        message: 'Le jeton sera effacé du trousseau et l\'autorisation révoquée auprès de Google.',
        action: 'Se déconnecter');
    if (!ok || !context.mounted) return;
    final revoked = await context.read<AppState>().signOutGoogle();
    if (context.mounted) {
      revoked
          ? showSuccess(context, 'Déconnecté, autorisation révoquée.')
          : showError(context, 'Déconnecté localement, mais la révocation auprès de Google a échoué.');
    }
    await _refresh();
  }

  Future<void> _configureClient(BuildContext context) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => OAuthClientDialog(initial: _client));
    if (saved == true) await _refresh();
  }

  Future<void> _connectEmulator(BuildContext context) async {
    // Pas de message temporaire : l'écran de la connexion s'ouvre directement
    // (un SnackBar masquerait son bouton « Nouveau document »).
    await showDialog<bool>(context: context, builder: (_) => const EmulatorConnectDialog());
  }
}

/// Saisie de l'identifiant client OAuth (rangé dans le trousseau).
class OAuthClientDialog extends StatefulWidget {
  const OAuthClientDialog({super.key, this.initial});
  final OAuthClientConfig? initial;

  @override
  State<OAuthClientDialog> createState() => _OAuthClientDialogState();
}

class _OAuthClientDialogState extends State<OAuthClientDialog> {
  final _form = GlobalKey<FormState>();
  late final _id = TextEditingController(text: widget.initial?.clientId);
  late final _secret = TextEditingController(text: widget.initial?.clientSecret);
  bool _obscure = true;

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Client OAuth Google'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Une seule fois, dans console.cloud.google.com :'),
              const SizedBox(height: 6),
              const Text('1. Choisissez (ou créez) un projet Google Cloud qui hébergera ce client.\n'
                  '2. « API et services » → « Écran de consentement OAuth » : type Externe, ajoutez votre adresse '
                  'comme utilisateur test.\n'
                  '3. Activez dans ce projet : Cloud Resource Manager, Firebase Management, Service Usage, '
                  'Cloud Firestore, Firebase Rules, Identity Toolkit, Cloud Billing.\n'
                  '4. « Identifiants » → « Créer » → « ID client OAuth » → type « Application de bureau ».\n'
                  '5. Copiez l\'ID client et le code secret ci-dessous.'),
              const SizedBox(height: 12),
              TextFormField(
                controller: _id,
                decoration: const InputDecoration(labelText: 'ID client'),
                validator: (v) => OAuthClientConfig.validateClientId(v ?? ''),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _secret,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Code secret du client',
                  helperText: 'Rangé dans le trousseau du système, jamais dans la base ni le journal.',
                  helperMaxLines: 2,
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Code secret obligatoire.' : null,
              ),
            ]),
          ),
        ),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            onPressed: () async {
              final ok = await confirm(context,
                  title: 'Oublier le client OAuth ?',
                  message: 'Le client et la session Google seront effacés du trousseau.',
                  danger: true,
                  action: 'Oublier');
              if (!ok || !context.mounted) return;
              await context.read<AppState>().deleteOAuthClient();
              if (context.mounted) Navigator.pop(context, true);
            },
            child: const Text('Oublier'),
          ),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
        FilledButton(
          onPressed: () async {
            if (!_form.currentState!.validate()) return;
            try {
              await context
                  .read<AppState>()
                  .saveOAuthClient(OAuthClientConfig(clientId: _id.text.trim(), clientSecret: _secret.text.trim()));
              if (context.mounted) Navigator.pop(context, true);
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

/// Connexion d'un émulateur Firestore local au projet actif.
class EmulatorConnectDialog extends StatefulWidget {
  const EmulatorConnectDialog({super.key});

  @override
  State<EmulatorConnectDialog> createState() => _EmulatorConnectDialogState();
}

class _EmulatorConnectDialogState extends State<EmulatorConnectDialog> {
  final _form = GlobalKey<FormState>();
  final _project = TextEditingController(text: 'demo-bddouilleur');
  final _firestore = TextEditingController(text: '127.0.0.1:8080');
  final _auth = TextEditingController(text: '127.0.0.1:9099');
  bool _busy = false;

  @override
  void dispose() {
    _project.dispose();
    _firestore.dispose();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connecter un émulateur'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: _project,
                decoration: const InputDecoration(
                    labelText: 'Identifiant du projet de démonstration',
                    helperText: 'Le préfixe demo- garantit qu\'aucun appel ne part vers Google.',
                    helperMaxLines: 2),
                validator: (v) => FirebaseTarget.validateEmulatorProjectId(v ?? ''),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _firestore,
                decoration: const InputDecoration(labelText: 'Émulateur Firestore (hôte:port)'),
                validator: (v) => FirebaseTarget.validateHost(v ?? ''),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _auth,
                decoration: const InputDecoration(
                    labelText: 'Émulateur Authentication (hôte:port)',
                    helperText: 'Sur un téléphone, utilisez l\'adresse IP du PC et lancez les émulateurs avec host 0.0.0.0.',
                    helperMaxLines: 3),
                validator: (v) => FirebaseTarget.validateHost(v ?? ''),
              ),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Annuler')),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Vérifier et connecter'),
        ),
      ],
    );
  }

  Future<void> _connect() async {
    if (!_form.currentState!.validate()) return;
    final state = context.read<AppState>();
    final project = state.activeProject;
    if (project == null) return;
    setState(() => _busy = true);
    try {
      final conn = await state.connectFirebase(
        project,
        FirebaseTarget(
          mode: FirebaseMode.emulator,
          projectId: _project.text.trim(),
          firestoreHost: _firestore.text.trim(),
          authHost: _auth.text.trim(),
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
      await Navigator.push(context, MaterialPageRoute(builder: (_) => FirebaseConnectionScreen(connection: conn)));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }
}
