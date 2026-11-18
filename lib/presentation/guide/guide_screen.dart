import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/common.dart';
import '../../data/connectors/sqlite/sqlite_connector.dart';
import '../../state/app_state.dart';

class _Section {
  const _Section(this.title, this.icon, this.steps, {this.available = true});
  final String title;
  final IconData icon;
  final List<String> steps;
  final bool available;
}

const _sections = <_Section>[
  _Section('Premier démarrage', Icons.rocket_launch_rounded, [
    'Ouvrez l\'onglet « Projets » et créez un projet (par exemple le nom de votre application).',
    'Le premier projet créé devient le projet actif : il apparaît sur l\'accueil.',
    'Choisissez le thème clair, sombre ou celui du système avec l\'icône de thème.',
  ]),
  _Section('Créer une base SQLite', Icons.precision_manufacturing_rounded, [
    'Sur l\'accueil, ouvrez « La Fabrique ».',
    'Choisissez le projet, le moteur SQLite, puis donnez un nom à la base.',
    'Cliquez sur « Fabriquer la base » : le fichier .db est créé dans le dossier de données de BDDouilleur.',
    'Pour utiliser un fichier existant, indiquez son chemin complet dans « Connecter un fichier SQLite existant ».',
  ]),
  _Section('Créer une table', Icons.schema_rounded, [
    'Ouvrez une base, onglet « Tables », bouton « Nouvelle table ».',
    'Saisissez le nom de la table (lettres sans accent, chiffres et « _ »).',
    'Ajoutez les colonnes, leur type, et cochez « Clé primaire », « Obligatoire », « Unique » si besoin.',
    'Une clé étrangère relie la colonne à une table existante.',
    'Le SQL généré s\'affiche en direct ; il est enregistré dans le journal à la création.',
  ]),
  _Section('Ajouter, modifier, supprimer des enregistrements', Icons.edit_note_rounded, [
    'Ouvrez une table, onglet « Données », bouton « Ajouter ».',
    'Un champ laissé vide prend sa valeur par défaut (ou un numéro automatique pour un id auto-incrémenté).',
    'Cochez « NULL » pour enregistrer explicitement une absence de valeur.',
    'Les icônes crayon et corbeille de chaque ligne permettent de la modifier ou de la supprimer.',
    'Les données sont écrites immédiatement sur disque et persistent après fermeture de l\'application.',
  ]),
  _Section('Console SQL', Icons.terminal_rounded, [
    'L\'onglet « Console SQL » exécute vos propres requêtes, dans l\'ordre, séparées par « ; ».',
    'Les instructions sensibles (DROP, DELETE, UPDATE, ALTER…) demandent confirmation et proposent un point '
        'de restauration automatique.',
  ]),
  _Section('Sauvegarde et restauration', Icons.lock_rounded, [
    'Ouvrez « Le Coffre-fort » depuis l\'accueil ou l\'icône cadenas d\'une base.',
    '« Sauvegarder maintenant » crée une copie complète, vérifiée par integrity_check.',
    '« Restaurer » vérifie la sauvegarde, crée un point de restauration de l\'état actuel puis remplace la base.',
    'Les sauvegardes planifiées ne sont pas encore disponibles.',
  ]),
  _Section('Résolution des erreurs courantes', Icons.help_center_rounded, [
    '« Valeur déjà existante (contrainte UNIQUE) » : une autre ligne utilise déjà cette valeur.',
    '« Champ obligatoire manquant (NOT NULL) » : remplissez la colonne marquée d\'un astérisque.',
    '« Référence invalide (clé étrangère) » : la ligne liée n\'existe pas, ou elle est encore utilisée.',
    '« Impossible d\'ouvrir la base SQLite » : le fichier n\'existe pas, n\'est pas une base SQLite ou n\'est pas accessible.',
    'L\'onglet « Santé » d\'une base lance un diagnostic d\'intégrité.',
  ]),
  _Section('Connecter une IA', Icons.smart_toy_rounded, [
    'Onglet Agent IA → icône des réglages → choisissez Anthropic Claude, OpenAI, Google Gemini, Mistral ou Ollama (local, gratuit).',
    'Collez votre clé API : elle va dans le trousseau du système, jamais dans la base ni le journal.',
    '« Enregistrer et tester » liste les modèles réellement disponibles ; choisissez-en un.',
    'Pour Ollama : installez-le, lancez « ollama serve » et téléchargez un modèle qui sait utiliser des outils (ex. ollama pull qwen3).',
  ]),
  _Section('Discuter avec l\'agent', Icons.forum_rounded, [
    'Agent IA → « Nouvelle conversation » : choisissez le fournisseur, une base par défaut et, si besoin, un dossier de projet lisible.',
    'L\'agent lit vos bases et vos fichiers avec de vrais outils. Chaque action affichée indique son résultat réel.',
    'Toute modification (création de tables, SQL, écriture Firestore) vous est soumise : « Autoriser » ou « Refuser ».',
    'Les conversations sont conservées par projet ; les actions figurent aussi dans le journal.',
  ]),
  _Section('Tester Firebase sans compte (émulateurs)', Icons.science_rounded, [
    'Installez firebase-tools (npm install -g firebase-tools) et Java 11 ou plus.',
    'Lancez : firebase emulators:start --only firestore,auth --project demo-monprojet',
    'Firebase AutoPilot → « Connecter un émulateur » : le projet demo-… est vérifié puis ajouté au projet actif.',
    'Sur un téléphone : lancez les émulateurs avec « host »: « 0.0.0.0 » dans firebase.json et saisissez l\'IP du PC, '
        'ou utilisez adb reverse tcp:8080 tcp:8080 et adb reverse tcp:9099 tcp:9099.',
  ]),
  _Section('Connecter votre compte Google', Icons.account_circle_rounded, [
    'Dans la console Google Cloud, créez un client OAuth de type « Application de bureau » (procédure détaillée dans la fenêtre de configuration).',
    'Firebase AutoPilot → « Configurer le client OAuth » : l\'identifiant et le secret vont dans le trousseau du système.',
    '« Se connecter avec Google » ouvre votre navigateur : vous autorisez l\'accès, BDDouilleur ne voit jamais votre mot de passe.',
    '« Se déconnecter » efface le jeton et révoque l\'autorisation chez Google.',
  ]),
  _Section('Créer un projet Firebase complet', Icons.local_fire_department_rounded, [
    'Firebase AutoPilot → « Créer un projet complet » : nom, identifiant, paquet Android, région Firestore.',
    'La liste exacte des actions s\'affiche avant confirmation. Rien n\'est facturé (plan Spark).',
    'Chaque étape vérifie l\'existant : relancer AutoPilot sur le même identifiant ne recrée rien.',
    'À la fin, « Écrire les fichiers FlutterFire » place google-services.json et firebase_options.dart dans votre projet Flutter.',
  ]),
  _Section('Données, règles, index et Authentication', Icons.policy_rounded, [
    'Données : parcourez collections et documents ; une collection naît avec son premier document.',
    'Règles : générez des règles fermées par défaut, lancez les tests (plusieurs utilisateurs fictifs), puis déployez. '
        'Les règles ouvertes à tous ne sont jamais publiées sur un vrai projet.',
    'Index : créez ou supprimez les index composites (vrai projet uniquement).',
    'Authentication : activez l\'e-mail / mot de passe et lancez un parcours de test complet.',
  ]),
  _Section('Firebase Rescue', Icons.medical_services_rounded, [
    'Firebase AutoPilot → « Lancer un diagnostic » puis choisissez le dossier de votre projet Flutter.',
    'Chaque constat indique Problème, Cause, Solution, Risque, Correction et Vérification.',
    'Les corrections automatiques montrent les fichiers modifiés, demandent confirmation et gardent une copie .bak.',
  ]),
  _Section('Connexion à PostgreSQL', Icons.dns_rounded, ['Prévu en phase 5.'], available: false),
  _Section('Analyser un projet', Icons.manage_search_rounded, [
    'Le Détective → « Un dossier de projet » : Flutter, React, Angular, Vue, Node, Python…',
    'L\'analyse (sans IA, sans modification) détecte modèles, stockage, authentification, services et appels API.',
    'Une architecture de données est proposée : créez-la dans une base SQLite ou générez le code.',
    '« Demander à l\'agent IA » ouvre une conversation qui approfondit l\'analyse.',
  ]),
  _Section('Générer le code Flutter', Icons.code_rounded, [
    'Le Connecteur → choisissez une base SQLite, ou « Générer le code Flutter » depuis une proposition de schéma.',
    'Choisissez SQLite (sqflite) ou Firestore et le dossier du projet Flutter, puis « Calculer le plan ».',
    'Vérifiez les fichiers et les différences, puis « Intégrer » : les fichiers existants sont sauvegardés.',
    'BDDouilleur lance ensuite l\'analyse et les tests générés. « Annuler » restaure l\'état d\'origine.',
  ]),
  _Section('Utilisation d\'AutoPilot', Icons.auto_mode_rounded, ['Prévu en phase 4.'], available: false),
  _Section('Pilotage depuis Android', Icons.phonelink_rounded, ['Prévu en phase 6.'], available: false),
];

class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Mode d\'emploi')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const MascotTip(
            title: 'Bonjour !',
            message: 'Je suis le BDDouilleur. Voici comment utiliser le laboratoire. Les chapitres grisés '
                'concernent des fonctionnalités prévues dans les prochaines phases.',
          ),
          const SizedBox(height: 16),
          for (final s in _sections)
            Opacity(
              opacity: s.available ? 1 : 0.55,
              child: Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ExpansionTile(
                  shape: const Border(),
                  leading: Icon(s.icon, color: Theme.of(context).colorScheme.primary),
                  title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: s.available ? null : const Text('Pas encore disponible'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    for (var i = 0; i < s.steps.length; i++)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                        title: Text(s.steps[i]),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text('À propos', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SelectableText('BDDouilleur 0.1.0 — phase 1\nSQLite ${SqliteConnector.libraryVersion}\n'
              'Données de l\'application : ${state.paths.root}'),
        ],
      ),
    );
  }
}
