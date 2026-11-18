# Bilan de la phase 2 : Firebase AutoPilot

Date : 17/11/2026. Version : 0.2.0+2.

## En résumé

Le module Firebase AutoPilot couvre toute la liste de la phase 2. Le niveau de vérification dépend de l'endroit où tourne Firebase :

| Environnement | Niveau de vérification |
|---|---|
| **Émulateurs Firebase** (Firestore et Authentication) | **Vérifié de bout en bout**, avec la vraie suite d'émulateurs, sous Linux **et** sur le téléphone Android 16 : données, règles (génération, tests réels, déploiement) et parcours Authentication complet. |
| **Vrai compte Google** | **Validé en réel sous Linux le 17/11/2026** (voir « Validation sur un vrai compte Google ») : connexion, analyse d'un projet existant, tests de règles, création d'un projet complet, Authentication. Connexion Google validée aussi **sur Android** (Honor, Android 16). Écriture Firestore, déploiement des règles et export FlutterFire validés le 18/11. Le module est désormais marqué « Opérationnel ». |

## Livré

### Connexion Google sécurisée (§6.1)

- OAuth 2.0 pour application native (RFC 8252) :
  - navigateur du système ;
  - redirection *loopback* 127.0.0.1 sur un port aléatoire ;
  - PKCE S256 ;
  - vérification du paramètre `state`.
- BDDouilleur utilise **votre** client OAuth de type « Application de bureau ». Aucun identifiant n'est intégré à l'APK, et le mot de passe Google n'est jamais demandé.
- Les jetons, l'identifiant et le secret client sont rangés dans le **trousseau du système** : libsecret / GNOME Keyring sous Linux, Android Keystore. Ce stockage a été vérifié en réel sur les deux plateformes.
- La déconnexion révoque l'autorisation chez Google.
- Le journal ne contient jamais ni jeton ni clé : le paramètre `key` est retiré des URL journalisées, et cela est vérifié par un test.

### Projets Firebase existants (§6.6)

- Liste des projets du compte, et connexion au projet BDDouilleur actif. La connexion est d'abord vérifiée réellement avant d'être enregistrée.
- Analyse en lecture seule de la configuration :
  - facturation ;
  - API activées ;
  - base Firestore et son mode ;
  - règles publiées (analysées) ;
  - index composites ;
  - Authentication (fournisseurs, protection contre l'énumération des comptes, connexion anonyme) ;
  - applications Android.
- Une API inaccessible donne un constat avec la cause et, le cas échéant, le lien d'activation.

### Création automatique (§6.2)

« Créer un projet complet » enchaîne les étapes suivantes. Chaque étape **vérifie l'existant avant d'agir**, et une relance ne recrée rien (test : zéro requête de création à la deuxième exécution).

1. Projet Google Cloud.
2. Vérification des permissions IAM.
3. Ajout de Firebase.
4. Activation des API Firestore, Rules et Identity Toolkit.
5. Base Firestore, dans la région choisie.
6. Application Android.
7. Récupération de google-services.json.
8. Authentication par e-mail.
9. Vérification finale de l'existence réelle de chaque ressource.

Autres garanties :

- La liste exacte des actions est montrée avant confirmation.
- Aucune facturation n'est activée : tout reste sur le plan Spark.
- En cas d'échec, l'exécution s'arrête net sur l'étape en cause et l'explique (permissions manquantes, identifiant déjà pris, etc.).
- Authentication non initialisé : Google exige alors un premier clic « Commencer » dans la console. L'étape le dit, avec le lien direct, au lieu de faire semblant.

### Configuration FlutterFire

- `lib/firebase_options.dart` est généré au format `flutterfire configure` (Android), à partir de la configuration réelle de l'application.
- Les fichiers sont écrits dans le projet Flutter choisi. Les anciens sont gardés en `.bak`, et le fichier écrit est relu pour vérification.

### Cloud Firestore (§6.3)

- Navigateur de données :
  - collections, documents et sous-collections ;
  - pagination ;
  - création, modification et suppression.
- Tous les types Firestore sont pris en charge, y compris date, référence, géopoint, octets et décimal entier.
- Aucune « collection vide » n'est simulée : une collection naît avec son premier document, et l'interface l'explique.
- Sur un vrai projet, supprimer un document demande de taper son identifiant. L'interface prévient que les sous-collections ne sont pas supprimées.
- Index composites (vrai projet) : liste, création et suppression.

### Règles de sécurité

- Générateur fermé par défaut. Cinq modes par collection :
  - document personnel `users/{uid}` ;
  - propriétaire par champ (sans possibilité de céder le document) ;
  - lecture connectée ;
  - lecture publique ;
  - verrouillée.
- Option « e-mail vérifié obligatoire ».
- Analyseur sans IA qui détecte :
  - le mode test ;
  - `if true` en écriture ;
  - l'écriture accordée à tout utilisateur connecté ;
  - la lecture publique de toute la base.
- Tests :
  - sur l'émulateur, par de **vraies requêtes** sous l'identité d'utilisateurs fictifs (alice, bob, anonyme). Les données touchées sont sauvegardées puis restaurées ;
  - sur Google, via l'API `projects.test`, qui ne touche aucune donnée.
- **Déploiement bloqué** sur un vrai projet si les règles ouvrent l'accès à tous.

### Authentication (§6.4)

- Vrai projet : activation de l'e-mail / mot de passe et de la protection contre l'énumération des comptes.
- Le fournisseur Google Sign-In exige un client OAuth Web, que seule la console sait créer de bout en bout. L'interface l'explique honnêtement.
- Parcours de test réel :
  1. inscription ;
  2. refus d'un mauvais mot de passe ;
  3. connexion ;
  4. renouvellement de session ;
  5. e-mail de vérification, puis validation de l'adresse avec le code lu dans l'émulateur ;
  6. réinitialisation du mot de passe, puis connexion avec le nouveau mot de passe ;
  7. suppression du compte de test.
- Sur un vrai projet, le compte fictif est supprimé à la fin.

### Firebase Rescue (§7)

- Diagnostic d'un projet Flutter au format **Problème — Cause — Solution — Risque — Correction — Vérification**. Il contrôle :
  - firebase_core manquant ;
  - versions non contraintes ;
  - `pubspec.lock` absent ou périmé ;
  - firebase_options absent ou d'un autre projet ;
  - initialisation absente, non attendue ou sans `ensureInitialized` ;
  - google-services.json absent, d'un autre projet ou d'un autre paquet ;
  - plugin Gradle absent ;
  - minSdk trop bas ;
  - **permission INTERNET absente en release** ;
  - firestore.rules trop permissives.
- Corrections automatiques : permission INTERNET, et génération des fichiers FlutterFire depuis le projet connecté. Chacune montre les fichiers touchés, demande confirmation, garde un `.bak`, puis relance le diagnostic pour vérifier.

### Intégration au reste de l'application

- La Fabrique oriente vers Firebase pour le moteur Firestore.
- La fiche du projet ouvre la bonne vue selon le moteur.
- Les modules propres à SQLite (Coffre-fort, Schématiseur, Réparateur) ne proposent que des bases SQLite.
- Le Professeur explique aussi les requêtes REST journalisées, et propose 2 nouvelles leçons : règles Firestore et émulateurs.
- Le mode d'emploi compte 5 nouvelles sections.
- Base interne : migration v1 → v2, avec une colonne `config` non sensible. La migration est testée sur une vraie base v1.

## Tests et vérifications

| Vérification | Résultat |
|---|---|
| `flutter analyze` | Aucun problème |
| `flutter test`, 55 tests : les 29 de la phase 1, plus OAuth (faux serveur et navigateur simulé), AutoPilot (faux Google à états), codec Firestore, générateur et analyseur de règles, FlutterFire, Rescue sur de vrais projets temporaires, migration v1 → v2, Professeur REST, écrans Firebase | **55/55** |
| `tool/run_emulator_tests.sh` : 3 tests contre la **vraie** suite d'émulateurs (CRUD Firestore tous types, règles générées 5 collections × tests réels avec restauration des données, parcours Authentication en 9 étapes) | **3/3** |
| Parcours UI réel sous **Linux** avec émulateurs : module → connexion → document créé (contrôle indépendant par HTTP) → règles 7/7 conformes → déploiement → Authentication 9/9 → journal | **Réussi** |
| Même parcours UI sur le **téléphone Android 16** (émulateurs du PC joints via `adb reverse`) | **Réussi** |
| Trousseau réel : écriture, lecture et effacement (Linux GNOME Keyring, Android Keystore) | **Réussi** sur les deux |
| `flutter build linux --release` | ELF 64 bits x86-64, compilé après la dernière modification du code. Démarrage vérifié dans un dossier de données isolé (base interne en schéma v2). |
| `flutter build apk --release --target-platform android-arm64` | APK de 22,2 Mo. arm64-v8a : `libapp.so`, `libflutter.so` et `libsqlite3.so`. Version 0.2.0 (2), permission INTERNET présente, aucun secret OAuth dans l'archive. |
| Captures rendues (`tool/screenshots.dart`) | 07 Firebase AutoPilot, 08 générateur de règles, 09 téléphone |

Défauts trouvés et corrigés pendant la phase :

- révélés par les tests d'interface :
  - un message temporaire masquait le bouton « Nouveau document » juste après la connexion d'un émulateur ;
  - `setState` recevait un `Future` dans les vues Firebase (même défaut qu'en phase 1, corrigé partout) ;
- trouvé à la relecture : la permission INTERNET manquait dans le manifeste release de BDDouilleur lui-même. Elle était indispensable pour les API Google.

## Validation sur un vrai compte Google (17/11/2026, Linux)

Essai mené avec le client OAuth « Application de bureau » de l'utilisateur, sur un projet existant (cousinade-2, en lecture seule) puis sur un projet jetable créé pour l'occasion (test-bddouilleur-1711).

| Parcours | Résultat réel |
|---|---|
| Connexion OAuth (navigateur, loopback, PKCE), lecture de l'adresse, jetons dans le trousseau, déconnexion avec révocation | ✓ |
| Analyse de cousinade-2 : Management, Billing, Service Usage, Firestore Admin, Rules, index, Identity Toolkit, applications Android | ✓ 0 bloquant |
| Connexion du projet existant à BDDouilleur | ✓ |
| Tests de règles par l'API Google `projects.test`, sans aucune donnée touchée | ✓ 7/7 |
| AutoPilot, création complète : projet Google Cloud → Firebase → API → Firestore (europe-west9) → application Android → google-services.json → vérification | ✓ en 2 minutes environ |
| Authentication non démarré : arrêt honnête avec lien vers la console, puis relance après le clic « Commencer » | ✓ toutes les étapes reconnues comme déjà faites, seule l'activation de l'e-mail / mot de passe et de la protection a agi |
| Parcours Authentication sur le vrai projet : inscription, mauvais mot de passe refusé, connexion, renouvellement de session, vérification d'e-mail, réinitialisation, suppression du compte | ✓ 7/7 |
| Connexion OAuth **sur Android** (Honor, Android 16) : navigateur du téléphone, retour sur 127.0.0.1 dans l'application | ✓ (l'erreur 401 initiale venait d'un identifiant mal saisi) |
| Création d'un document sur le vrai projet (`POST …/documents/essai?documentId=premier`) | ✓ |
| Règles : 10/10 tests conformes puis déploiement en production sur le projet jetable. Aucune publication n'existait encore, donc le chemin « création de la publication » a été emprunté. | ✓ |
| Export FlutterFire vers un projet Flutter de test : google-services.json et firebase_options.dart corrects (projet, appId, expéditeur, bucket), et **le projet compile** avec `firebase_core` et `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)` (`flutter analyze` : aucun problème) | ✓ |
| Connexion Android après correction du défaut « réseau coupé en arrière-plan » (voir ci-dessous) | ✓ |

Défauts révélés par ce test réel, corrigés (2 tests ajoutés, 57/57) :

- **Consentement granulaire de Google.** Sur l'écran d'autorisation, l'utilisateur peut décocher l'accès « Google Cloud ». BDDouilleur acceptait alors la connexion, puis chaque API répondait « insufficient authentication scopes », affiché à tort comme un manque de droits sur le projet. Désormais :
  - les accès accordés sont vérifiés à la connexion et à chaque rafraîchissement ;
  - une autorisation incomplète est refusée et révoquée, avec un message qui dit quelles cases cocher ;
  - surtout, cette erreur n'est plus prise pour « projet inexistant ». AutoPilot aurait sinon pu tenter de recréer un projet existant.
- **Réseau coupé en arrière-plan (Honor).** Le code d'autorisation arrive pendant que le navigateur est encore au premier plan. L'échange contre les jetons partait alors que BDDouilleur était en arrière-plan, et le gestionnaire d'énergie du téléphone coupe le réseau des applications en arrière-plan (« Failed host lookup »). Désormais, BDDouilleur attend le retour au premier plan (`AppLifecycleListener`) et réessaie en cas d'erreur réseau. Le message d'erreur est en français, avec le réglage de batterie à vérifier. Au passage, le texte des messages d'erreur était illisible (rouge foncé sur fond rouge) : c'est corrigé partout. 2 tests ajoutés, **59/59**.
- **Journal d'AutoPilot.** Les entrées ne contenaient pas leur requête REST : la dernière requête notée était un GET de suivi d'opération, filtré ensuite. C'est maintenant la dernière requête modifiante qui est notée.

## Limitations connues

- **Pas encore essayé sur un vrai compte Google** : la création et la suppression d'index composites. La construction d'un index prend plusieurs minutes chez Google.
- **Trousseau Linux** : une version de test de BDDouilleur ne retrouve pas les entrées rangées par la version release. La bibliothèque `flutter_secure_storage_linux` fixe le nom de schéma libsecret d'une façon fragile. À étudier avant la livraison : une mise à jour pourrait obliger à saisir à nouveau le client OAuth et à se reconnecter.
- Storage n'est pas traité : il exige le plan Blaze, qui est facturable, et il ne fait pas partie de la liste de la phase 2.
- Le fournisseur Google Sign-In reste à activer dans la console : Google n'offre pas d'API de bout en bout.
- L'émulateur ne permet pas de relire ses règles. BDDouilleur affiche les dernières règles qu'il y a déployées.
- La gestion des index n'est disponible que sur un vrai projet. L'émulateur n'en exige aucun.
- Sur un vrai projet, BDDouilleur accède aux données avec les droits IAM du compte, donc les règles ne s'appliquent pas à lui. L'écran le signale.
- Le navigateur de données ne propose pas encore de requêtes filtrées.
- `usesCleartextTraffic` est activé dans le manifeste Android. C'est nécessaire pour joindre un émulateur sur le réseau local en HTTP. Les API Google restent en HTTPS.
- Les messages temporaires (SnackBar) de l'écran principal peuvent recouvrir quelques secondes le bouton flottant d'un onglet.
- Les émulateurs ont été testés avec firebase-tools 15.36, installé localement dans `~/.local/share/bdd-tools` pour ne rien installer globalement.
- Le reste est hérité de la phase 1 : APK signé avec la clé de debug, `.deb` et ZIP prévus en phase 7.

## Prochaine étape proposée

D'abord, valider le parcours Google avec votre compte, par exemple sur un projet de test jetable. Ensuite, la phase 3 : l'agent IA multifournisseur.
