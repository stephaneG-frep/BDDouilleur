# Architecture de BDDouilleur

## Arborescence

```
lib/
├── main.dart, app.dart          Démarrage, MaterialApp, thèmes, locale fr_FR
├── core/
│   ├── theme/app_theme.dart     Palette du Laboratoire, Material 3 clair et sombre
│   └── widgets/                 Mascotte (CustomPainter animé), cartes dégradées, dialogues
├── domain/
│   ├── models/                  Project, DbConnection, DbEngine, schéma, journal
│   ├── modules.dart             Catalogue des 10 modules et leur statut réel
│   ├── ai/ai_models.dart        Format neutre des messages, outils, réponses et erreurs IA
│   ├── schema_proposal.dart     Proposition d'architecture (validation, tables SQLite, règles Firestore)
│   ├── text_diff.dart           Différences ligne à ligne (aperçu avant écriture)
│   ├── firebase/                Cible Firebase, règles (générateur, analyseur, cas de test), FlutterFire
│   └── sql_explainer.dart       Explication déterministe du SQL et des requêtes REST (Le Professeur)
├── data/
│   ├── connectors/
│   │   ├── database_connector.dart   Interface abstraite et capacités annoncées
│   │   └── sqlite/                   Connecteur SQLite, générateur SQL sûr, conversion des valeurs
│   ├── persistence/             Base interne (migrations), dépôts, chemins
│   ├── backup/                  Sauvegarde et restauration SQLite
│   ├── secrets/                 Trousseau du système (flutter_secure_storage) ; version mémoire pour les tests
│   ├── google/                  OAuth 2.0 natif (loopback + PKCE), client REST Google, erreurs traduites
│   ├── firebase/                Management, Firestore (données, admin), règles, Auth, AutoPilot, Rescue
│   ├── ai/                      Adaptateurs des 5 fournisseurs, boucle d'agent, réglages, historique
│   ├── analysis/                Analyse déterministe de dossiers de projets
│   └── codegen/                 Générateur Flutter et intégrateur (restauration, vérification)
├── state/app_state.dart         Services, état global, opérations journalisées
├── state/agent_tools.dart       Les 14 outils réels de l'agent (lecture / modification avec accord)
└── presentation/                Écrans (accueil, projets, Fabrique, base, table,
                                 console SQL, Coffre-fort, journal, Professeur, guide)
test/                            Tests unitaires et widgets
test_emulator/                   Tests contre la vraie suite d'émulateurs Firebase
integration_test/                Persistance (deux lancements), parcours Firebase UI, trousseau réel
tool/                            Icône, captures, émulateurs Firebase (firebase.json, script de tests)
```

Les couches présentes sont la présentation, le domaine, les connecteurs, la persistance, le stockage sécurisé des secrets, l'authentification Google et l'intégration Firebase (phase 2), ainsi que les tests. La phase 3 ajoute le moteur IA multifournisseur, l'analyse de projets et la génération de code. Les couches suivantes arriveront avec leur phase : orchestrateur AutoPilot et exécuteur sécurisé (4), service Linux et communication Android (6).

## Principes

1. **Connecteurs abstraits.** `DatabaseConnector` définit l'interface commune. Chaque connecteur n'annonce, via `capabilities`, que ce qu'il sait réellement faire. Le connecteur SQLite n'annonce pas `migration`. Les connecteurs NoSQL (Firestore, MongoDB) n'implémenteront pas les notions de table quand elles n'ont pas de sens.
2. **Aucune concaténation de valeurs dans le SQL.** Les valeurs sont toujours liées par paramètres `?`. Les identifiants sont validés à la création (`[A-Za-z_][A-Za-z0-9_]*`, mots réservés et préfixe `sqlite_` refusés), puis échappés entre guillemets doubles.
3. **Journal systématique.** Toute opération qui modifie une base passe par `AppState.runLogged`. Celui-ci enregistre le SQL réellement exécuté, et l'échec éventuel est enregistré comme un échec. Ce journal alimente Le Professeur. Il servira aussi de base au moteur d'actions typées d'AutoPilot.
4. **Protection des données.** Un point de restauration est créé automatiquement avant la suppression d'une table et avant une instruction SQL destructive (option cochée par défaut). Les suppressions de tables, de fichiers et de projets demandent de taper le nom pour confirmer.
5. **Sauvegardes réelles.** `VACUUM INTO` produit une copie cohérente, vérifiée ensuite par `PRAGMA integrity_check`. Une restauration suit quatre étapes : vérifier la sauvegarde, créer un point de restauration, remplacer le fichier de façon atomique (copie puis renommage), puis revérifier.
6. **Aucun secret dans la base interne.** Les jetons OAuth et l'identifiant client sont dans le trousseau du système (`SecretStore`). Le journal enregistre les requêtes REST (méthode et URL), jamais d'en-tête ni de paramètre `key`.
7. **Firebase : vérifier avant d'agir.** Chaque étape d'AutoPilot lit l'état réel avant d'écrire, ce qui la rend idempotente. Une connexion n'est enregistrée qu'après une requête réussie. Firestore n'a pas de « table » : aucune collection vide n'est simulée.
8. **Règles fermées par défaut.** Le générateur part de « tout refuser ». L'analyseur bloque le déploiement de règles ouvertes à tous sur un vrai projet. Les tests utilisent de vraies requêtes sur l'émulateur, et `projects.test` sur Google.
9. **Pas de clé intégrée.** BDDouilleur utilise le client OAuth « Application de bureau » de l'utilisateur, qui le saisit à l'exécution.
10. **L'IA n'agit que par des outils.** Le modèle ne dispose d'aucune commande système. Les outils en lecture s'exécutent directement. Les outils modifiants exigent un accord explicite, et leurs effets passent par les mêmes chemins journalisés que l'interface (`runLogged`, `runFirebase`). Seuls les résultats d'outils font foi, jamais le texte du modèle.
11. **Code généré par modèles déterministes.** L'IA choisit le schéma ; le code vient de modèles de code testés. Le plan est affiché avec les différences, puis intégré avec un point de restauration, puis vérifié (`dart analyze`, `flutter test`).

## Choix techniques

| Besoin | Choix | Raison |
|---|---|---|
| SQLite | `sqlite3` 3.9 (FFI, SQLite 3.54 embarqué) | Maintenu, fonctionne sur Linux et Android sans bibliothèque système, et donne accès aux PRAGMA et à `VACUUM INTO`. |
| Base interne | La même bibliothèque, avec des migrations via `PRAGMA user_version` | Pas de dépendance supplémentaire. Les migrations sont contrôlées. |
| État | `provider` + `ChangeNotifier` | Simple et suffisant pour la phase 1. Pourra évoluer si la complexité augmente. |
| Chemins | `path_provider` | Emplacements standards (XDG sous Linux, stockage privé sous Android). |
| Localisation | `flutter_localizations`, `fr_FR` | Interface et dialogues système en français. |
| API Google | `http` + clients REST écrits à la main | Peu de dépendances. Les requêtes journalisées sont lisibles. Le même client Firestore sert pour l'émulateur et pour Google (seules l'URL de base et l'authentification changent). Les tests utilisent des faux serveurs. |
| OAuth | Loopback 127.0.0.1 + PKCE (RFC 8252), `url_launcher` | Méthode recommandée par Google pour les clients « bureau ». Le mot de passe n'est jamais vu par l'application. |
| Secrets | `flutter_secure_storage` | libsecret sous Linux, Keystore sous Android. |
| Fournisseurs IA | REST direct (`http`) | Pas de SDK officiel Dart. Un format neutre, et un adaptateur par API. Testés contre des réponses simulées. |
| Sélecteur de dossier | `file_selector` (Linux) | Choisir un projet Flutter pour Rescue et l'export FlutterFire. |

Le connecteur SQLite est synchrone derrière une API `Future`. C'est sans conséquence pour des bases de taille courante. Les lectures sont paginées (50 lignes) et la console limite l'affichage à 500 lignes. Si de très grosses bases deviennent un besoin, l'exécution sera déplacée dans un isolate.

## Base interne (schéma v3)

- `projects(id, name, description, created_at, updated_at)`
- `connections(id, project_id → projects ON DELETE CASCADE, name, engine, location, created_at, last_opened_at, config)`. Pour Firestore, `location` contient l'identifiant du projet, et `config` un JSON non sensible : mode émulateur ou Google, base, hôtes de l'émulateur, dernières règles déployées sur l'émulateur. La colonne `config` est ajoutée par la migration v2.
- `journal(id, project_id, connection_id, action, summary, sql, success, error, timestamp)`
- `settings(key, value)` : thème, projet actif, fournisseur et modèle d'IA (jamais de clé).
- `ai_conversations(id, project_id, title, provider, model, folder, connection_id, …)` et `ai_messages(id, conversation_id, role, content JSON, jetons, …)`, ajoutées par la migration v3.
