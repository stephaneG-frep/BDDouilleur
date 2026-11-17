
# PROMPT CLAUDE CODE — BDDOUILLEUR
## Agent IA Flutter de création et de gestion des bases de données

**Nom :** BDDouilleur  
**Slogan :** « Vos bases de données ? Je m'en débrouille ! »  
**Plateformes :** Linux Ubuntu/Lubuntu et Android  
**Technologie :** Flutter / Dart  
**Livrables :** APK Android, application Linux .deb, code source ZIP, documentation et tests.

---

# 1. TON RÔLE

Tu es un développeur Flutter senior, architecte logiciel, administrateur de bases de données (DBA), expert Firebase, ingénieur DevOps, spécialiste en cybersécurité et développeur d'agents IA.

Ta mission est de concevoir, développer, tester et livrer une application professionnelle appelée **BDDouilleur**.

BDDouilleur est un agent IA capable de prendre en charge automatiquement la création, la configuration, l'intégration, la maintenance, la sécurisation et la réparation des bases de données.

L'utilisateur doit pouvoir lui expliquer ses besoins en français, sans avoir besoin de maîtriser SQL, Firebase ou l'administration de serveurs.

**Règle fondamentale : toutes les fonctionnalités annoncées comme opérationnelles doivent réellement fonctionner. Aucun bouton fictif, aucune simulation trompeuse, aucun résultat inventé.**

# 2. CONCEPT GÉNÉRAL

L'utilisateur peut demander :

« Voici mon application Flutter. Occupe-toi de toute la partie base de données. »

BDDouilleur doit être capable de :

1. Analyser les fichiers du projet.
2. Identifier les données nécessaires.
3. Détecter les bases de données existantes.
4. Recommander une technologie adaptée.
5. Concevoir le schéma de données.
6. Créer et configurer la base.
7. Générer les modèles et services.
8. Intégrer la connexion au projet.
9. Configurer l'authentification si nécessaire.
10. Tester les opérations CRUD.
11. Vérifier la sécurité.
12. Corriger les problèmes autorisés.
13. Sauvegarder les données.
14. Documenter les opérations.

L'application doit aussi fonctionner comme un gestionnaire classique de bases de données, même sans fournisseur IA connecté.

# 3. DESIGN — LE LABORATOIRE DU BDDOUILLEUR

Créer une interface originale, moderne, ludique et professionnelle.

## Identité graphique

Univers : laboratoire de savant fou, atelier mécanique et technologie futuriste.

Mascotte : un petit savant fou sympathique avec d'énormes lunettes, une blouse de laboratoire, des cheveux ébouriffés et une clé à molette, entouré de cylindres représentant les bases de données.

Palette :

- Bleu nuit : #10172A
- Violet électrique : #8358FF
- Turquoise : #20D6C7
- Orange : #FFAA55
- Rose : #FF648B
- Vert : #44D7A8

Utiliser Material 3, des cartes avec dégradés et transparence, des animations fluides, des coins arrondis et une interface responsive.

Prévoir les thèmes clair et sombre.

Afficher sur l'accueil :

**BDDouilleur**  
*Vos bases de données ? Je m'en débrouille !*

La mascotte doit apparaître sur l'accueil, dans les assistants de configuration et dans les messages pédagogiques.

Ne pas sacrifier la lisibilité à la décoration.

# 4. TABLEAU DE BORD

Créer les modules suivants :

- **La Fabrique** : créer une base de données.
- **Firebase AutoPilot** : créer et configurer Firebase.
- **Le Détective** : analyser un projet ou une BDD.
- **Le Réparateur** : diagnostiquer et corriger les problèmes.
- **Le Connecteur** : relier une BDD à une application.
- **Le Schématiseur** : concevoir les tables et relations.
- **Le Coffre-fort** : sauvegarder et restaurer.
- **Le Gardien** : vérifier la sécurité.
- **Le Professeur** : expliquer SQL, NoSQL et Firebase.
- **AutoPilot** : automatiser les opérations autorisées.

Chaque module doit disposer d'une interface fonctionnelle.

# 5. AGENT IA MULTIFOURNISSEUR

Intégrer une architecture permettant d'utiliser :

- OpenAI.
- Anthropic Claude.
- Google Gemini.
- Mistral.
- Ollama en local.

Prévoir :

- Choix du fournisseur.
- Sélection des modèles disponibles.
- Gestion sécurisée des clés API.
- Test de connexion.
- Historique des conversations par projet.
- Explications en français.
- Gestion des erreurs et des limites API.

L'agent doit utiliser des outils réels pour agir sur les fichiers, bases de données et services autorisés.

Ne jamais considérer une réponse textuelle du modèle comme une opération réussie.

Les clés API ne doivent jamais apparaître dans les journaux ni être intégrées dans l'APK distribué.

# 6. FIREBASE AUTOPILOT — CRÉATION AUTOMATIQUE

Cette fonctionnalité est prioritaire.

L'utilisateur doit pouvoir dire :

« Crée-moi un projet Firebase complet pour mon application Flutter. »

BDDouilleur doit automatiser le processus autant que les API officielles le permettent.

## 6.1 Connexion Google

Implémenter une authentification OAuth 2.0 sécurisée, adaptée à une application native.

Utiliser les API officielles Google Cloud et Firebase.

L'utilisateur doit autoriser explicitement l'accès à son compte.

Ne jamais demander directement son mot de passe Google.

## 6.2 Création de projet

L'agent doit pouvoir :

- Vérifier les permissions Google Cloud.
- Vérifier les quotas et prérequis.
- Créer un projet Google Cloud lorsque les droits le permettent.
- Ajouter Firebase au projet.
- Enregistrer une application Android.
- Configurer les identifiants d'application.
- Générer les fichiers de configuration FlutterFire.
- Vérifier que le projet existe réellement.

Si une étape exige une intervention dans la console Google ou une facturation, l'expliquer clairement.

## 6.3 Cloud Firestore

Prévoir :

- Création de la base Firestore.
- Choix de la région.
- Conception des collections.
- Création de documents initiaux.
- Gestion des index.
- Génération des règles de sécurité.
- Tests de lecture et d'écriture.
- Vérification des autorisations.

Les collections Firestore étant créées lors de l'écriture de documents, ne pas simuler une création de collection vide comme s'il s'agissait d'une table SQL.

Ne jamais utiliser de règles ouvertes à tous en production.

## 6.4 Firebase Authentication

Configurer, lorsque les API et autorisations le permettent :

- E-mail et mot de passe.
- Connexion Google.
- Vérification d'e-mail.
- Réinitialisation de mot de passe.
- Gestion des sessions.
- Protection des comptes.

Tester les parcours d'authentification avec des comptes de test.

## 6.5 Firebase Storage

Prévoir :

- Configuration de Storage.
- Vérification des exigences de facturation.
- Génération des règles.
- Téléversement de fichiers.
- Téléchargement.
- Suppression autorisée.
- Intégration Flutter.

## 6.6 Projets Firebase existants

Permettre de connecter un projet déjà créé.

L'agent doit pouvoir analyser sa configuration, ses règles, ses index, les services activés et les erreurs de connexion.

Ne jamais recréer un projet existant sans nécessité.

# 7. FIREBASE RESCUE AI

Créer un outil de diagnostic capable de détecter :

- Mauvaise initialisation Firebase.
- Fichiers de configuration manquants.
- Dépendances FlutterFire incompatibles.
- Erreurs Authentication.
- Permissions Firestore refusées.
- Index manquants.
- Règles trop permissives.
- Erreurs de synchronisation.
- Problèmes de configuration Android.

Pour chaque erreur, afficher :

**Problème — Cause — Solution — Risque — Correction — Vérification.**

L'utilisateur doit pouvoir demander :

« Pourquoi Firebase ne fonctionne pas dans mon application ? »

L'agent analyse les éléments disponibles, explique le diagnostic et applique les corrections autorisées.

# 8. BASES DE DONNÉES COMPATIBLES

Créer une architecture modulaire par connecteurs.

Technologies ciblées :

- SQLite.
- PostgreSQL.
- MySQL.
- MariaDB.
- Firebase Firestore.
- Supabase.
- MongoDB.
- Hive.
- Isar.

Commencer par SQLite, PostgreSQL et Firebase.

Ajouter les autres progressivement.

Chaque connecteur doit annoncer ses capacités réelles : connexion, inspection, CRUD, migration, sauvegarde, restauration et diagnostic.

Ne pas appliquer les concepts SQL directement aux bases NoSQL lorsque cela n'a pas de sens.

# 9. ANALYSE AUTOMATIQUE DES PROJETS

L'utilisateur sélectionne un dossier contenant un projet Flutter, React, Angular, Vue.js, Python, Node.js ou autre technologie reconnue.

L'agent analyse :

- Les fichiers source.
- Les modèles.
- Les services.
- Les dépendances.
- Les systèmes de stockage.
- Les appels API.
- L'authentification.
- Les configurations existantes.
- Les besoins de persistance.

Il doit ensuite proposer une architecture de données.

Exemple :

« Cette application contient des utilisateurs, des commandes et des produits. Je propose trois entités et les relations nécessaires. »

Avant toute modification, afficher un plan détaillé et un aperçu des fichiers concernés.

# 10. LE SCHÉMATISEUR

Créer un éditeur graphique de bases de données.

Fonctionnalités :

- Création de tables.
- Ajout de colonnes.
- Types de données.
- Clés primaires.
- Clés étrangères.
- Contraintes.
- Index.
- Relations graphiques.
- Zoom et déplacement.
- Importation de schémas existants.
- Génération de migrations.

Pour Firestore, afficher les collections, documents et références sous une représentation adaptée.

Permettre de passer d'une description en français à un schéma visuel.

# 11. GÉNÉRATION ET INTÉGRATION DU CODE

BDDouilleur doit générer le code nécessaire pour connecter la base de données à l'application.

Pour Flutter :

- Modèles Dart.
- Repositories.
- Services.
- Configuration Firebase.
- Gestion des erreurs.
- Authentification.
- Tests unitaires.
- Tests d'intégration.

Respecter l'architecture du projet existant.

Ne jamais écraser silencieusement les fichiers.

Créer une sauvegarde ou un point de restauration avant modification.

Afficher les différences de code.

Tester les modifications avant de les considérer comme terminées.

# 12. MODE AUTOPILOT — AUTONOMIE MAXIMALE

Créer trois modes :

**Manuel :** l'utilisateur valide les actions individuellement.

**Assisté :** l'agent automatise les opérations courantes autorisées.

**AutoPilot :** l'agent planifie et exécute les opérations non sensibles dans le périmètre approuvé.

AutoPilot doit :

1. Comprendre l'objectif.
2. Analyser le contexte.
3. Préparer un plan.
4. Vérifier les prérequis.
5. Exécuter les opérations autorisées.
6. Contrôler les résultats.
7. Corriger les erreurs récupérables.
8. Exécuter les tests.
9. Produire un rapport final.

Exiger une confirmation explicite avant toute suppression, migration destructive, modification des permissions, déploiement en production ou création de ressources facturables.

Interdire l'exécution arbitraire de commandes système générées par l'IA.

Utiliser un moteur d'actions typées, validées et journalisées.

# 13. LE RÉPARATEUR

Créer un module de diagnostic des bases de données.

Analyser :

- Connexions défaillantes.
- Requêtes incorrectes.
- Contraintes violées.
- Index absents.
- Migrations échouées.
- Problèmes de performances.
- Configurations dangereuses.
- Erreurs de synchronisation.

Proposer des corrections avec estimation des risques.

Créer un point de restauration avant toute intervention susceptible de modifier les données.

# 14. LE COFFRE-FORT

Créer un système de sauvegarde et de restauration.

Prévoir :

- Sauvegardes manuelles.
- Sauvegardes planifiées lorsque la plateforme le permet.
- Exportation.
- Importation.
- Historique.
- Vérification d'intégrité.
- Restauration contrôlée.

Adapter la méthode de sauvegarde au moteur.

Pour Firebase, utiliser les mécanismes officiels compatibles avec le projet et son niveau de facturation.

Ne pas présenter un export JSON partiel comme une sauvegarde complète de Firestore.

# 15. LE GARDIEN — SÉCURITÉ

Créer un module d'audit.

Contrôler :

- Identifiants exposés.
- Permissions excessives.
- Règles Firestore dangereuses.
- Politiques RLS Supabase.
- Risques d'injection SQL.
- Connexions non chiffrées.
- Mauvaise séparation des environnements.
- Accès administrateur inutiles.

Afficher un rapport avec gravité, explication et correction proposée.

Les opérations administratives doivent être réalisées côté Linux ou sur un environnement serveur sécurisé, jamais directement dans l'APK avec des secrets privilégiés.

# 16. LE PROFESSEUR — MODULE PÉDAGOGIQUE

BDDouilleur doit expliquer ses interventions.

Créer un espace d'apprentissage sur :

- SQL et NoSQL.
- Tables et colonnes.
- Collections et documents.
- Relations.
- Index.
- CRUD.
- Transactions.
- Migrations.
- Firebase.
- PostgreSQL.
- Sécurité.
- Sauvegardes.

L'utilisateur doit pouvoir sélectionner une opération et demander :

« Explique-moi ce que tu viens de faire et pourquoi. »

Afficher les exemples de code réellement utilisés dans le projet.

# 17. APPLICATION LINUX ET ANDROID

Développer une application Flutter pour les deux plateformes.

## Linux

La version Linux constitue le moteur principal.

Elle doit permettre :

- Accès aux dossiers autorisés.
- Analyse des projets.
- Exécution contrôlée.
- Administration des BDD.
- Configuration Firebase.
- Génération de code.
- Tests.
- Sauvegardes.
- Service local sécurisé.

## Android

Créer une application compagnon permettant :

- Consultation des projets.
- Discussion avec l'agent.
- Visualisation des bases.
- Lancement d'opérations autorisées.
- Suivi des tâches.
- Consultation des rapports.
- Notifications.
- Validation des actions sensibles.

Prévoir un appairage sécurisé entre le smartphone et le PC Linux.

Utiliser une API locale authentifiée, avec chiffrement des communications, autorisations, révocation des appareils et journalisation.

Ne pas exposer le service d'administration directement sur Internet.

# 18. HISTORIQUE ET GESTION DES PROJETS

Enregistrer localement :

- Projets.
- Configurations non sensibles.
- Connexions.
- Schémas.
- Historique des interventions.
- Rapports.
- Statuts.
- Sauvegardes.
- Conversations IA.

Conserver les secrets séparément dans un stockage sécurisé.

Prévoir l'exportation et l'importation des projets sans divulguer les secrets.

# 19. MODE D'EMPLOI INTÉGRÉ

Créer une documentation accessible depuis l'application.

Inclure :

- Premier démarrage.
- Connexion à une IA.
- Création d'une base SQLite.
- Création automatique Firebase.
- Connexion à PostgreSQL.
- Analyse d'un projet Flutter.
- Utilisation d'AutoPilot.
- Sauvegarde et restauration.
- Pilotage depuis Android.
- Résolution des erreurs courantes.

Utiliser des explications pédagogiques en français.

# 20. ARCHITECTURE TECHNIQUE

Utiliser Flutter stable, Dart, Material 3 et une architecture modulaire.

Séparer :

- Présentation.
- Domaine métier.
- Connecteurs de bases de données.
- Moteur IA.
- Orchestrateur AutoPilot.
- Exécuteur sécurisé.
- Service Linux.
- Communication Android.
- Persistance.
- Sécurité.
- Tests.

Choisir des dépendances maintenues et compatibles avec les plateformes ciblées.

Prévoir des interfaces abstraites pour les connecteurs et les fournisseurs IA.

Ne pas introduire de service payant obligatoire.

# 21. PLAN DE DÉVELOPPEMENT

## Phase 1 — Fondations fonctionnelles

- Création du projet Flutter.
- Design BDDouilleur.
- Mascotte et slogan.
- Navigation.
- Tableau de bord.
- Gestion des projets.
- Stockage local.
- Premier connecteur SQLite.
- CRUD SQLite.
- Tests.

Livrer une première application utilisable.

## Phase 2 — Firebase AutoPilot

- Connexion Google sécurisée.
- Gestion des projets Firebase existants.
- Création automatique de projets.
- Configuration FlutterFire.
- Firestore.
- Authentication.
- Règles de sécurité.
- Tests sur émulateurs et environnement de test.
- Diagnostic Firebase.

## Phase 3 — Agent IA

- Fournisseurs IA.
- Conversations.
- Analyse de projets.
- Recommandations de schémas.
- Génération de code.
- Historique des actions.

## Phase 4 — AutoPilot

- Planification.
- Exécution contrôlée.
- Validation.
- Sauvegardes.
- Retour arrière.
- Diagnostics.
- Corrections.
- Rapports.

## Phase 5 — Connecteurs avancés

- PostgreSQL.
- Supabase.
- MySQL.
- MariaDB.
- MongoDB.
- Autres moteurs compatibles.
- Éditeur graphique avancé.

## Phase 6 — Pilotage Android/Linux

- Service sécurisé Linux.
- Appairage Android.
- Communication.
- Supervision.
- Notifications.
- Validation distante.

## Phase 7 — Finalisation et livraison

- Audit général.
- Tests automatisés.
- Tests d'intégration.
- Corrections.
- Optimisations.
- Documentation.
- Compilation APK.
- Compilation Linux.
- Création du .deb.
- Archive ZIP.
- Rapport final.

# 22. EXIGENCES DE LIVRAISON

Fournir :

- Projet Flutter complet.
- Code source ZIP.
- APK Android ARM64.
- Application Linux.
- Paquet .deb.
- README.
- Guide utilisateur.
- Documentation technique.
- Résultats des tests.
- Liste des fonctionnalités opérationnelles.
- Liste des éventuelles limitations.

Vérifier que les binaires correspondent au projet courant.

Contrôler l'architecture des exécutables.

Ne jamais réutiliser un ancien APK provenant d'un autre projet.

Ne pas annoncer une compilation réussie sans avoir produit et vérifié le fichier correspondant.

Si l'environnement ne permet pas une compilation, indiquer précisément la raison.

# 23. CONSIGNES DE TRAVAIL

Travaille de façon autonome pour les tâches techniques courantes.

Ne m'interromps pas pour des décisions mineures.

Choisis des solutions raisonnables et documente tes choix.

N'effectue jamais d'action destructive ou facturable sans confirmation explicite.

À chaque phase :

1. Implémente les fonctionnalités prévues.
2. Exécute l'analyse statique.
3. Exécute les tests.
4. Corrige les erreurs.
5. Vérifie les parcours utilisateur.
6. Mets à jour la documentation.
7. Présente un bilan clair.

Ne passe pas à la phase suivante tant que les fonctionnalités essentielles de la phase courante ne sont pas opérationnelles.

# 24. PREMIÈRE MISSION

Commence immédiatement par :

1. Vérifier l'environnement Linux, Flutter, Dart et Android.
2. Concevoir l'architecture de BDDouilleur.
3. Créer l'arborescence.
4. Développer l'interface avec son identité visuelle.
5. Implémenter la gestion des projets.
6. Implémenter un connecteur SQLite réel.
7. Permettre de créer une base, une table et des enregistrements.
8. Vérifier que les données persistent après fermeture et redémarrage.
9. Exécuter les tests.
10. Livrer la phase 1 avec un bilan.

**Arrête-toi après la phase 1 pour validation.**

Le résultat attendu n'est pas une maquette : c'est le premier socle fonctionnel d'un agent IA professionnel.

**BDDouilleur — Vos bases de données ? Je m'en débrouille !**
