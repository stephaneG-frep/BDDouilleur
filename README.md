# BDDouilleur

*Vos bases de données ? Je m'en débrouille !*

BDDouilleur est une application Flutter (Linux et Android) qui crée, gère, sauvegarde et explique des bases de données. À terme, ce sera un agent IA capable de s'occuper de toute la partie base de données d'un projet. La spécification complète se trouve dans [SPEC.md](SPEC.md).

**Version actuelle : 0.2.0, phase 2 (Firebase AutoPilot).**

## Ce qui fonctionne aujourd'hui

| Fonctionnalité | État |
|---|---|
| Interface « Laboratoire du BDDouilleur » : mascotte, thèmes clair et sombre, mise en page adaptée au bureau et au téléphone | ✅ |
| Gestion des projets : création, modification, suppression, projet actif | ✅ |
| La Fabrique : création de bases SQLite réelles, connexion d'un fichier SQLite existant | ✅ |
| Le Schématiseur (formulaire) : tables, types, clés primaires et étrangères, NOT NULL, UNIQUE, valeurs par défaut, aperçu SQL en direct | ✅ |
| CRUD des enregistrements avec pagination | ✅ |
| Console SQL, avec confirmation et point de restauration avant toute instruction destructive | ✅ |
| Le Réparateur (diagnostic) : `integrity_check` et `foreign_key_check` | ✅ partiel |
| Le Coffre-fort : sauvegarde vérifiée, historique, restauration contrôlée | ✅ |
| Journal de toutes les interventions, avec le SQL réellement exécuté | ✅ |
| Le Professeur : 13 leçons, et des explications des opérations réellement exécutées | ✅ |
| Mode d'emploi intégré | ✅ |
| Firebase sur émulateurs : données Firestore, règles (génération, tests réels, déploiement), parcours Authentication | ✅ vérifié (Linux et Android) |
| Firebase sur votre compte Google : OAuth 2.0 (PKCE), création de projet complet, projets existants, index, règles, Authentication, fichiers FlutterFire | ✅ validé sur un vrai compte (Linux et Android) |
| Firebase Rescue : diagnostic d'un projet Flutter, corrections confirmées avec sauvegarde `.bak` | ✅ |
| Agent IA, AutoPilot, PostgreSQL, pilotage Android/Linux, Firebase Storage | Prévus, phases 3 à 6 |

Les modules qui ne sont pas encore disponibles affichent une fiche qui le dit clairement. Aucun bouton ne fait semblant de fonctionner.

## Prérequis

- Flutter 3.47 (stable) et Dart 3.13. Le projet a été développé avec ces versions.
- Linux : clang, cmake, ninja et GTK 3 (`flutter doctor`).
- Android : le SDK Android. L'APK cible ARM64.

SQLite est embarqué via `package:sqlite3` (build hooks). Il n'y a aucune dépendance système à installer.

## Commandes

```bash
flutter pub get
flutter run -d linux                     # lancer sur le PC
flutter test                             # tests unitaires et widgets
flutter analyze                          # analyse statique

# Persistance après un vrai redémarrage (deux processus distincts)
flutter test integration_test/persistence_restart_test.dart -d linux \
  --dart-define=STAGE=write --dart-define=DATA_DIR=/tmp/bdd_itest
flutter test integration_test/persistence_restart_test.dart -d linux \
  --dart-define=STAGE=read  --dart-define=DATA_DIR=/tmp/bdd_itest

# Compilation
flutter build linux --release            # build/linux/x64/release/bundle/
flutter build apk --release --target-platform android-arm64

# Tests Firebase contre la vraie suite d'émulateurs (firebase-tools + Java 11+)
tool/run_emulator_tests.sh               # démarre les émulateurs, teste, arrête
cd tool/firebase_emulator && firebase emulators:exec --only firestore,auth \
  --project demo-bddouilleur "cd ../.. && flutter test integration_test/firebase_emulator_ui_test.dart -d linux"
flutter test integration_test/secret_store_test.dart -d linux   # trousseau réel

# Outils
flutter test tool/generate_icon.dart     # régénère l'icône depuis la mascotte
flutter test tool/screenshots.dart       # captures dans build/screenshots/
```

## Firebase

**Sans compte (émulateurs)** : `npm install -g firebase-tools`, puis
`firebase emulators:start --only firestore,auth --project demo-monprojet`. Ensuite, dans
Firebase AutoPilot, choisissez « Connecter un émulateur ». Sur un téléphone, faites
`adb reverse tcp:8080 tcp:8080` et `adb reverse tcp:9099 tcp:9099`, ou saisissez l'adresse IP
du PC (émulateurs lancés avec `host: 0.0.0.0`).

**Avec votre compte Google** : créez dans la console Google Cloud un client OAuth de type
« Application de bureau », et activez dans son projet les API Cloud Resource Manager,
Firebase Management, Service Usage, Cloud Firestore, Firebase Rules, Identity Toolkit et
Cloud Billing. Saisissez ensuite l'identifiant et le secret dans Firebase AutoPilot :
ils sont rangés dans le trousseau du système, jamais dans l'application ni dans le
journal. BDDouilleur n'active jamais la facturation.

## Où sont les données ?

- Linux : `~/.local/share/fr.bddouilleur.bddouilleur/`
- Android : le stockage privé de l'application.

Contenu de ce dossier :

- `bddouilleur_app.db` : projets, connexions, journal et réglages. Aucun secret n'y est stocké :
  les jetons et identifiants OAuth sont dans le trousseau du système (GNOME Keyring, Android Keystore).
- `databases/projet_<id>/*.db` : les bases créées par La Fabrique.
- `backups/connexion_<id>/*.db` : les sauvegardes du Coffre-fort.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) : architecture technique et choix effectués.
- [docs/BILAN_PHASE_1.md](docs/BILAN_PHASE_1.md) : bilan de la phase 1, tests et limitations.
- [docs/BILAN_PHASE_2.md](docs/BILAN_PHASE_2.md) : bilan de la phase 2 (Firebase), tests et limitations.
- Guide utilisateur : l'onglet « Mode d'emploi » de l'application.
