import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/common.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/sql_explainer.dart';
import '../../state/app_state.dart';

class Lesson {
  const Lesson(this.title, this.icon, this.body, [this.example]);
  final String title;
  final IconData icon;
  final String body;
  final String? example;
}

const lessons = <Lesson>[
  Lesson(
    'SQL ou NoSQL ?',
    Icons.compare_arrows_rounded,
    'Une base SQL (relationnelle) range les données dans des tables aux colonnes définies à l\'avance : '
        'SQLite, PostgreSQL, MySQL. Une base NoSQL est plus souple : Firestore et MongoDB stockent des '
        'documents (sortes de fiches JSON) regroupés en collections, sans schéma imposé.\n\n'
        'SQL convient aux données très liées entre elles (clients, commandes, factures). NoSQL convient aux '
        'données hiérarchiques, à la synchronisation temps réel et aux applications mobiles connectées.',
  ),
  Lesson(
    'Tables et colonnes',
    Icons.table_chart_rounded,
    'Une table ressemble à un tableau : chaque colonne est un champ typé (texte, nombre, date…) et chaque '
        'ligne est un enregistrement. Choisir le bon type évite les erreurs : un prix en REAL ou NUMERIC, '
        'un nom en TEXT, un compteur en INTEGER.',
    'CREATE TABLE clients (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n  nom TEXT NOT NULL,\n  email TEXT UNIQUE\n);',
  ),
  Lesson(
    'Collections et documents',
    Icons.description_rounded,
    'Dans Firestore, il n\'y a pas de tables : une collection contient des documents, et chaque document '
        'contient des champs. Une collection n\'existe qu\'à partir du moment où un document y est écrit : '
        'on ne « crée » pas une collection vide comme une table SQL.',
    'utilisateurs/ (collection)\n  └─ alice (document)\n       nom: "Alice"\n       commandes/ (sous-collection)',
  ),
  Lesson(
    'Clés primaires et relations',
    Icons.key_rounded,
    'La clé primaire identifie chaque ligne de façon unique (souvent un numéro « id »). Une clé étrangère '
        'relie une ligne à une autre table : une commande référence le client qui l\'a passée. SQLite vérifie '
        'que le client existe, et ON DELETE CASCADE supprime les commandes si le client est supprimé.',
    'client_id INTEGER NOT NULL\n  REFERENCES clients(id) ON DELETE CASCADE',
  ),
  Lesson(
    'Les index',
    Icons.bolt_rounded,
    'Un index est comme l\'index d\'un livre : il permet de retrouver rapidement des lignes sans tout lire. '
        'Il accélère les recherches et les tris, mais ralentit légèrement les écritures. Les contraintes '
        'UNIQUE et PRIMARY KEY créent automatiquement un index.',
    'CREATE INDEX idx_commandes_client ON commandes(client_id);',
  ),
  Lesson(
    'CRUD',
    Icons.sync_alt_rounded,
    'Create, Read, Update, Delete : les quatre opérations de base. INSERT ajoute, SELECT lit, UPDATE modifie, '
        'DELETE supprime. Sans clause WHERE, UPDATE et DELETE touchent TOUTES les lignes : c\'est pourquoi '
        'BDDouilleur demande confirmation et crée un point de restauration.',
    "INSERT INTO clients (nom) VALUES (?);\nSELECT * FROM clients WHERE id = ?;\nUPDATE clients SET nom = ? WHERE id = ?;\nDELETE FROM clients WHERE id = ?;",
  ),
  Lesson(
    'Requêtes paramétrées et injections SQL',
    Icons.security_rounded,
    'Ne jamais coller une saisie utilisateur directement dans du SQL : un texte malveillant pourrait changer '
        'la requête (injection SQL). On utilise des paramètres « ? » : la base reçoit la valeur séparément et '
        'ne l\'interprète jamais comme du code. BDDouilleur procède toujours ainsi.',
  ),
  Lesson(
    'Transactions',
    Icons.account_balance_rounded,
    'Une transaction regroupe plusieurs opérations qui réussissent toutes ou échouent toutes. Exemple : un '
        'virement débite un compte et en crédite un autre ; si la seconde étape échoue, la première est annulée.',
    'BEGIN;\nUPDATE comptes SET solde = solde - 50 WHERE id = 1;\nUPDATE comptes SET solde = solde + 50 WHERE id = 2;\nCOMMIT;',
  ),
  Lesson(
    'Migrations',
    Icons.moving_rounded,
    'Une migration fait évoluer la structure d\'une base existante (ajout de colonne, nouvelle table) sans '
        'perdre les données. Chaque migration est numérotée et appliquée dans l\'ordre. BDDouilleur utilise ce '
        'principe pour sa propre base interne (PRAGMA user_version).',
    'ALTER TABLE clients ADD COLUMN telephone TEXT;',
  ),
  Lesson(
    'Firebase',
    Icons.local_fire_department_rounded,
    'Firebase est la plateforme de Google pour les applications : Firestore (base de documents), '
        'Authentication (comptes utilisateurs), Storage (fichiers). La sécurité repose sur des règles : '
        'des règles ouvertes à tous (« allow read, write: if true ») ne doivent jamais aller en production.',
  ),
  Lesson(
    'PostgreSQL',
    Icons.dns_rounded,
    'PostgreSQL est un serveur de base relationnelle complet : plusieurs utilisateurs simultanés, droits '
        'fins, types avancés (JSON, tableaux), extensions. On s\'y connecte par le réseau avec un hôte, un '
        'port, un utilisateur et un mot de passe — idéalement avec une connexion chiffrée (SSL).',
  ),
  Lesson(
    'Sécurité',
    Icons.shield_rounded,
    'Principes : ne jamais mettre de mot de passe ou de clé dans le code ou un APK ; donner à chaque compte '
        'le minimum de droits ; chiffrer les connexions réseau ; séparer les environnements de test et de '
        'production ; journaliser les opérations sensibles.',
  ),
  Lesson(
    'Sauvegardes',
    Icons.inventory_2_rounded,
    'Une sauvegarde n\'est utile que si elle est complète, vérifiée et restaurable. Pour SQLite, BDDouilleur '
        'utilise VACUUM INTO qui produit une copie cohérente, puis vérifie son intégrité. Avant toute '
        'opération risquée, un point de restauration est créé automatiquement.',
    "VACUUM INTO '/chemin/sauvegarde.db';",
  ),
  Lesson(
    'Règles de sécurité Firestore',
    Icons.policy_rounded,
    'Dans une application Firebase, le téléphone parle directement à la base : ce sont les règles de sécurité, '
        'évaluées par Google à chaque requête, qui décident qui lit et qui écrit. Le bon principe : tout refuser '
        'par défaut, puis autoriser précisément (par exemple : chacun accède à son document users/{uid}). Les '
        'règles « mode test » ou « if true » laissent n\'importe qui lire et modifier vos données. Testez-les '
        'toujours avec plusieurs utilisateurs avant de les publier.',
    'match /users/{uid}/{document=**} {\n  allow read, write: if request.auth != null && request.auth.uid == uid;\n}',
  ),
  Lesson(
    'Émulateurs Firebase',
    Icons.science_rounded,
    'La suite d\'émulateurs (firebase-tools) fait tourner Firestore et Authentication sur votre ordinateur. '
        'Rien n\'est facturé, aucune donnée réelle n\'est touchée, et les e-mails de vérification restent '
        'consultables localement. Les projets « demo-… » garantissent qu\'aucun appel ne part vers Google. '
        'C\'est l\'endroit idéal pour apprendre, tester des règles et des parcours de connexion.',
    'firebase emulators:start --only firestore,auth --project demo-monprojet',
  ),
];

class ProfesseurScreen extends StatelessWidget {
  const ProfesseurScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Le Professeur'),
          bottom: const TabBar(tabs: [Tab(text: 'Leçons'), Tab(text: 'Mes opérations expliquées')]),
        ),
        body: const TabBarView(children: [_LessonsTab(), _OperationsTab()]),
      ),
    );
  }
}

class _LessonsTab extends StatelessWidget {
  const _LessonsTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const MascotTip(message: 'Bienvenue en cours ! Choisissez une leçon. Rien de compliqué, promis.'),
        const SizedBox(height: 12),
        for (final l in lessons)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              shape: const Border(),
              leading: Icon(l.icon, color: Theme.of(context).colorScheme.primary),
              title: Text(l.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.body),
                if (l.example != null) ...[const SizedBox(height: 10), CodeBlock(l.example!)],
              ],
            ),
          ),
      ],
    );
  }
}

class _OperationsTab extends StatelessWidget {
  const _OperationsTab();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final entries = state.journal
        .recent(projectId: state.activeProject?.id, withSqlOnly: true, limit: 100)
        .where((e) => e.success)
        .toList();
    if (entries.isEmpty) {
      return const EmptyState(
          message: 'Aucune opération à expliquer pour l\'instant. Créez une table ou ajoutez un enregistrement, '
              'puis revenez ici.');
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const MascotTip(
          message: 'Voici le SQL réellement exécuté sur vos bases. Touchez une opération et demandez-moi de '
              'l\'expliquer. (Explication automatique fondée sur le SQL, sans IA.)',
        ),
        const SizedBox(height: 12),
        for (final e in entries)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              title: Text(e.summary),
              subtitle: Text('${e.action.label} • ${formatDate(e.timestamp)}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _explain(context, e),
            ),
          ),
      ],
    );
  }

  void _explain(BuildContext context, JournalEntry e) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text('Explique-moi ce que tu as fait et pourquoi', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            CodeBlock(e.sql!),
            const SizedBox(height: 12),
            MascotTip(message: 'Voici ce que fait cette instruction, point par point :'),
            const SizedBox(height: 8),
            for (final line in SqlExplainer.explain(e.sql!))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(padding: EdgeInsets.only(top: 3), child: Icon(Icons.lightbulb_rounded, size: 18)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(line)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
