# Bilan de la phase 1 : fondations fonctionnelles

Date : 16/11/2026. Version : 0.1.0+1.

## Environnement vérifié

| Élément | Version |
|---|---|
| OS | Ubuntu 22.04.5 LTS, x86_64 |
| Flutter / Dart | 3.47.2 stable / 3.13.2 |
| Android SDK | 37, build-tools 37.0.0, JDK 21 (Android Studio), licences acceptées |
| Linux toolchain | clang 14, cmake 3.22, ninja 1.10 |
| SQLite embarqué | 3.54.1 |
| Appareil de test | Android 16 (API 36), ARM64 |

## Livré

- Projet Flutter Linux et Android, organisé en couches (voir ARCHITECTURE.md).
- Identité visuelle : palette de la spécification, mascotte originale dessinée en code et animée (l'animation se coupe si l'accessibilité le demande), thèmes clair, sombre et système, mise en page adaptée (rail latéral à partir de 840 px, barre du bas en dessous).
- Icône de l'application générée à partir de la mascotte (Android et fenêtre Linux).
- Tableau de bord des 10 modules, avec leur statut réel : Opérationnel, Partiel, ou Prévu (avec le numéro de phase).
- Gestion des projets. Le projet actif et le thème sont conservés d'une session à l'autre.
- Connecteur SQLite réel :
  - création de base et connexion d'un fichier existant (vérifié avant d'être ajouté) ;
  - inspection : colonnes, affinités, clés primaires, clés étrangères, index, tables WITHOUT ROWID ;
  - création de tables avec contraintes ;
  - CRUD paginé ;
  - console SQL multi-instructions, y compris les triggers ;
  - diagnostic d'intégrité ;
  - sauvegarde et restauration.
- Journal des interventions avec le SQL exécuté. Les échecs sont journalisés comme tels.
- Le Professeur : 13 leçons, et l'explication automatique (sans IA) du SQL réellement exécuté.
- Mode d'emploi intégré.

## Tests et vérifications

| Vérification | Résultat |
|---|---|
| `flutter analyze` | Aucun problème |
| `flutter test` : 29 tests (générateur SQL, connecteur, sauvegarde et restauration, persistance, explicateur, widgets, parcours UI complet) | 29/29 réussis |
| Persistance après redémarrage réel sous Linux : 2 processus. L'écriture passe par l'UI, la relecture se fait dans un nouveau lancement. | Réussi |
| Contrôle indépendant des fichiers avec le module Python `sqlite3` (schéma, ligne, `integrity_check`, journal) | Conforme |
| Persistance après redémarrage réel sous Android : écriture via l'UI, `am force-stop`, relance, relecture | Réussi |
| `flutter build linux --release` | ELF 64 bits x86-64, avec `libapp.so` et `libsqlite3.so` |
| `flutter build apk --release --target-platform android-arm64` | APK de 21,1 Mo, `libapp.so`, `libflutter.so` et `libsqlite3.so` en arm64-v8a. Paquet `fr.bddouilleur.bddouilleur`, libellé « BDDouilleur », version 0.1.0 |
| Contrôle visuel (captures rendues par le moteur avec Roboto, `tool/screenshots.dart`) | Accueil sombre, clair et téléphone, base, table, création de table |

Les tests ont révélé quatre défauts, tous corrigés :

- un script `CREATE TABLE …; INSERT …` échouait, car toutes les instructions étaient préparées d'avance ;
- `setState` renvoyait un `Future` ;
- les cartes de modules débordaient ;
- l'écran vide débordait quand le clavier virtuel était ouvert sur téléphone.

## Limitations connues

- **Signature de l'APK** : l'APK release est signé avec la clé de debug. Une clé de publication sera nécessaire avant toute distribution.
- **ABI** : l'APK contient aussi `libdartjni.so` pour armeabi-v7a et x86_64 (une dépendance de `path_provider`). L'application ne fonctionne que sur ARM64, car `libflutter.so` n'est fourni que pour cette architecture.
- **Connexion d'un fichier existant** : il faut saisir le chemin à la main. Il n'y a pas encore de sélecteur de fichiers, ce qui est peu pratique sur Android.
- **Noms de tables et de colonnes** : à la création, ils sont limités aux lettres sans accent, aux chiffres et à `_`. C'est un choix de portabilité. Les noms atypiques des bases existantes sont bien lus.
- **Exécution synchrone** : les opérations SQLite s'exécutent sur le thread de l'interface. C'est sans gêne pour des bases courantes. Les très grosses requêtes pourraient figer l'interface.
- **Table d'une base existante** : une table WITHOUT ROWID sans clé primaire ne peut pas être éditée (cas impossible en pratique). Une table ordinaire qui possède une colonne nommée `rowid` est éditée via sa clé primaire.
- **Non livrés en phase 1** (prévus en phase 7) : le paquet `.deb` et l'archive ZIP.
- **Modules prévus** : Firebase AutoPilot (phase 2) ; agent IA, Le Détective (analyse de projets) et Le Connecteur (phase 3) ; AutoPilot et Le Gardien (phase 4) ; PostgreSQL et l'éditeur graphique (phase 5) ; pilotage Android/Linux (phase 6). Pour l'instant, chacun affiche une fiche honnête.

## Prochaine étape proposée

La phase 2, Firebase AutoPilot. Elle a besoin de trois choses de votre part :

- un projet Google Cloud de test ;
- l'autorisation OAuth sur votre compte ;
- une décision sur les ressources facturables. Firebase Storage exige le plan Blaze.
