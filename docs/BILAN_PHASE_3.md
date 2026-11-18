# Bilan de la phase 3 : agent IA

Date : 18/11/2026. Version : 0.3.0+3.

## En résumé

L'agent IA est livré. Il a 5 fournisseurs, 14 outils réels, un historique par projet et demande l'accord de l'utilisateur avant toute modification. Il s'accompagne de l'analyse de projets, des propositions de schéma et de la génération de code Flutter.

| Élément | Niveau de vérification |
|---|---|
| Boucle d'agent, outils, accord, historique, interface | **Vérifiés** : tests contre un modèle simulé, avec les vrais outils sur de vraies bases SQLite, plus un parcours complet dans l'interface. |
| Adaptateurs Anthropic, OpenAI, Gemini, Mistral, Ollama | **Vérifiés contre des réponses simulées** reproduisant le format de chaque API : en-têtes, appels d'outils, erreurs. **Pas encore exécutés contre un vrai fournisseur** : il faut votre clé API, ou Ollama (son installation a été refusée par le système de permissions). |
| Génération de code Flutter | **Vérifiée de bout en bout dans de vrais projets Flutter** : SQLite 12 fichiers, Firestore 11 fichiers ; `dart analyze --fatal-infos` sans remarque, 6/6 tests générés réussis pour chaque moteur, restauration complète. |
| Analyse de projets | **Vérifiée** sur des projets Flutter, Node/Prisma et Django créés pour les tests. |

## Livré

### Fournisseurs IA (§5)

- **Anthropic Claude** : API Messages en REST direct, car il n'existe pas de SDK officiel pour Dart.
  - Version d'API `2026-10-21`, modèle par défaut `claude-opus-5-5`.
  - Les blocs de réflexion (`thinking`) sont renvoyés tels quels à chaque tour.
  - Le statut `refusal` est traité.
  - Le repli automatique côté serveur (`fallbacks: "default"`) est activé pour les modèles qui le permettent.
- **OpenAI** (chat completions) et **Mistral** (format compatible, avec le nom de l'outil dans les résultats).
- **Google Gemini** : la clé passe dans l'en-tête `x-goog-api-key`, jamais dans l'URL. Les signatures de pensée sont conservées, et le schéma des outils est adapté au sous-ensemble OpenAPI que Gemini accepte.
- **Ollama en local** : `/api/chat`, sans clé ni coût.

Pour chaque fournisseur :

- choix du fournisseur et liste des modèles réellement disponibles ;
- test de connexion réel ;
- clé dans le trousseau du système, jamais dans la base, le journal ou l'APK.

Les erreurs sont traduites en français : clé refusée, limite de débit (avec le délai `retry-after`), quota ou facturation, surcharge (529), conversation trop longue, réseau. Il y a de nouvelles tentatives automatiques sur surcharge ou limite de débit.

### Agent et conversations

- La boucle d'agent ne considère jamais une réponse textuelle comme une opération réussie : seuls les résultats d'outils font foi.
- Sécurités de la boucle : arrêt après 12 étapes d'outils, bouton « Arrêter », et appels d'outils interrompus signalés au modèle.
- **14 outils réels**, et aucune commande système :
  - **en lecture** (exécutés directement) :
    - liste et description des bases ;
    - requête SQLite en lecture seule (une seule instruction ; écritures et `PRAGMA` d'affectation refusés) ;
    - documents Firestore ;
    - analyse du projet ;
    - liste et lecture de fichiers, dans le seul dossier choisi par l'utilisateur (sortie du dossier refusée, `.env` et clés jamais lus) ;
    - analyse de règles Firestore ;
    - proposition de schéma ;
    - plan de code Flutter (le plan est calculé, rien n'est écrit) ;
  - **modifiants** (**accord explicite** à chaque appel, avec la description de l'action et ses paramètres exacts) :
    - création de tables ;
    - ajout d'un enregistrement ;
    - SQL (point de restauration automatique avant toute instruction destructive) ;
    - écriture d'un document Firestore.
- Historique des conversations par projet (base interne v3), avec le décompte des jetons consommés.
- Chaque action réelle est notée dans le journal.

### Analyse automatique des projets (§9)

Le Détective, en mode « Un dossier de projet », fait une analyse déterministe et sans modification :

- technologie : Flutter, Dart, Node.js, React, Next.js, Angular, Vue, Nuxt, Express, NestJS, Python (Django, Flask, FastAPI), Go, Java, PHP ;
- dépendances de stockage et d'authentification ;
- modèles : classes Dart, interfaces TypeScript, modèles Django ou Pydantic, schéma Prisma ;
- services et dépôts ;
- appels API (hôtes) ;
- configurations ;
- constats, par exemple « des modèles mais aucun stockage persistant ».

Il en déduit une proposition d'architecture : une entité par modèle, avec des relations déduites des champs `xxxId` et des types référencés. Le bouton « Demander à l'agent IA » approfondit l'analyse.

### Recommandations de schémas

Une proposition de schéma peut venir de l'analyse ou de l'agent, par exemple à partir d'une description en français. Elle est :

- **validée** : noms, doublons, références inconnues, `id` réservé, références circulaires ;
- **créable dans une base SQLite**, après confirmation : clés étrangères, tables créées dans le bon ordre, tables existantes non modifiées ;
- ou **transformée en code Flutter**.

### Génération et intégration du code (§11)

Le Connecteur génère le code à partir d'une base SQLite existante ou d'une proposition :

- modèles Dart (`fromMap`, `toMap`, `copyWith`, égalité) ;
- dépôts **sqflite** ou **Cloud Firestore**, avec gestion d'erreurs (`RepositoryException`, messages en français) ;
- services avec validation ;
- tests unitaires du modèle ;
- tests d'intégration du dépôt : vraie base SQLite en mémoire via `sqflite_common_ffi`, ou `fake_cloud_firestore`.

Garanties :

- **L'architecture existante est respectée** : dossiers de modèles, de dépôts et de services détectés.
- **Rien n'est écrasé sans le dire** : un plan s'affiche d'abord, avec la différence ligne à ligne de chaque fichier.
- **Point de restauration** dans `.bddouilleur/restore/` : fichiers modifiés, `pubspec.yaml` et `pubspec.lock`. Le bouton « Annuler » restaure tout.
- Les dépendances manquantes sont ajoutées par `flutter pub add`, une commande fixe qui n'est jamais construite par l'IA.
- **Tests avant de déclarer le travail terminé** : `dart analyze --fatal-infos`, puis `flutter test` sur les tests générés. Sur Android, ces outils n'existent pas : le code est alors signalé « non vérifié ».

### Intégration au reste de l'application

- Nouvel onglet **Agent IA**. « Mode d'emploi » devient « Guide », pour que les 5 onglets tiennent sur un téléphone.
- Modules :
  - Le Détective et Le Connecteur passent « Opérationnel » ;
  - Le Schématiseur gagne le schéma depuis une description en français ;
  - AutoPilot et Le Gardien restent prévus en phase 4.
- Le Professeur explique les opérations de l'agent depuis le journal.
- 4 nouvelles sections dans le mode d'emploi.

## Tests et vérifications

| Vérification | Résultat |
|---|---|
| `flutter analyze` | Aucun problème |
| `flutter test`, 82 tests, dont 26 nouveaux | **82/82**. Fournisseurs : format de chaque API, erreurs, nouvelles tentatives, clé absente des URL. Agent : refus, accord, lecture seule, SQL destructif avec sauvegarde, enfermement dans le dossier, arrêt de sécurité, historique sans clé. Analyse : Flutter, Node/Prisma, Django. Schémas, différences de texte, migration v1 → v3, parcours UI complet de l'agent. |
| `tool/codegen_e2e_test.dart` : vrais projets `flutter create` | **SQLite et Firestore réussis**. Intégration, ajout des dépendances, `dart analyze --fatal-infos` propre, 6/6 tests générés, restauration vérifiée. |
| Captures (`tool/screenshots.dart`) | 10 conversations, 11 conversation avec proposition de schéma, 12 fournisseurs, 13 plan du Connecteur, 14 téléphone |
| `flutter build linux --release` | ELF x86-64, compilé après la dernière modification du code |
| `flutter build apk --release` (arm64) | 22,7 Mo, version 0.3.0 (3). Installé sur le Honor par-dessus la 0.2.0 : démarrage sans plantage, base interne migrée. |

Défaut révélé par le test de bout en bout de la génération, puis corrigé : en Firestore, les octets (`Uint8List`) étaient écrits comme une liste de nombres, et la relecture plantait. Le code écrit maintenant des `Blob` et relit les deux formes.

## Limitations connues

- **Aucun appel à un vrai fournisseur d'IA pour l'instant.** Il faut une clé (Anthropic, OpenAI, Gemini ou Mistral) ou Ollama installé. C'est la prochaine validation à faire avec vous.
- Pour Ollama, le modèle doit savoir appeler des outils (qwen3, llama3.1, mistral-nemo…). Les très petits modèles se trompent souvent d'outil.
- Pas d'affichage progressif (streaming) des réponses : le message s'affiche à la fin de chaque étape.
- La génération de code vise Flutter uniquement (sqflite et Firestore). Les autres frameworks viendront dans une phase ultérieure.
- L'analyse de projet repose sur des motifs : des modèles écrits de façon inhabituelle peuvent échapper à la détection (l'agent peut alors lire les fichiers).
- Sur Android, le code généré ne peut pas être vérifié (pas d'outils Flutter), et l'accès aux dossiers de projet est limité par le stockage Android.
- L'APK est toujours signé avec la clé de debug. Le `.deb` et le ZIP sont prévus en phase 7.
