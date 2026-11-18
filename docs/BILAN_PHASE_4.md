# Bilan de la phase 4 : AutoPilot, Le Réparateur, Le Gardien

Date : 18/11/2026. Version : 0.4.0+4.

## En résumé

| Élément de la spec (phase 4) | Livré | Vérification |
|---|---|---|
| Planification | Plan d'actions typées proposé par l'IA, validé à blanc par BDDouilleur | Tests avec modèle simulé, essai réel avec Ollama |
| Exécution contrôlée | Exécutée par BDDouilleur ; chaque effet est contrôlé en réel | Tests sur de vraies bases SQLite |
| Validation | Approbation du plan, puis confirmation des étapes destructives ou sensibles | Tests, parcours UI complet |
| Sauvegardes | Point de restauration vérifié avant la première modification | Tests |
| Retour arrière | Restauration complète des bases, suppression des documents Firestore créés | Tests, parcours UI complet |
| Diagnostics | Le Réparateur (SQLite) et Le Gardien (sécurité) | Tests sur des bases et des projets volontairement défectueux |
| Corrections | Correction automatique des erreurs récupérables (jamais plus risquée) ; corrections du Réparateur avec risque | Tests |
| Rapports | Rapport final détaillé, enregistré et journalisé | Tests, captures |

## Livré

### Modes d'autonomie (§12)

Chaque action a un **niveau de risque** : lecture, courante (ajout de données), structure (table, index, statistiques), destructive (DELETE, DROP, UPDATE, VACUUM, restauration) ou sensible (production, permissions, ressources facturables).

| Mode | Sans confirmation | Toujours confirmé |
|---|---|---|
| **Manuel** | Lecture | Toute modification |
| **Assisté** | Lecture, actions courantes du périmètre | Structure, destructif, sensible, hors périmètre |
| **AutoPilot** | Lecture, actions courantes et structure du périmètre | Destructif, sensible, hors périmètre |

- Le mode se choisit dans chaque conversation (badge en haut à droite).
- La demande d'accord affiche le risque et explique pourquoi la confirmation est requise.
- Les actions exécutées automatiquement sont marquées comme telles.
- Une écriture Firestore sur un **vrai** projet Google est classée « sensible » (production). Sur l'émulateur, elle est « courante ».

### AutoPilot (§12 : les 9 étapes)

1. **Comprendre l'objectif** et 2. **analyser le contexte** : l'IA lit la structure réelle avec les outils de lecture uniquement. Rien n'est modifié pendant la planification.
3. **Préparer un plan** : l'outil `submit_plan` reçoit les étapes, chacune étant un appel d'outil typé. BDDouilleur valide chaque étape **sans l'exécuter** : outil autorisé, arguments vérifiés, périmètre respecté. Un plan invalide est renvoyé au modèle avec le schéma attendu. Si le modèle s'arrête sans plan, il est relancé.
4. **Vérifier les prérequis** : bases accessibles, plan toujours valide.
5. **Exécuter les opérations autorisées** :
   - point de restauration vérifié de chaque base SQLite touchée ;
   - exécution par BDDouilleur, jamais par le modèle ;
   - confirmation individuelle des étapes destructives ou sensibles ;
   - bouton « Arrêter après l'étape en cours ».
6. **Contrôler les résultats** : contrôle réel après chaque étape (table présente, ligne présente, index présent, document présent…).
7. **Corriger les erreurs récupérables** : en cas d'échec, l'IA propose une étape de remplacement, revalidée. Elle est refusée si elle est plus risquée que l'étape approuvée. Au maximum 2 corrections par exécution.
8. **Exécuter les tests** : `integrity_check` et `foreign_key_check` sur chaque base modifiée.
9. **Rapport final** : objectif, résultat, étapes avec leur contrôle réel, corrections, contrôles et possibilité de retour arrière. Il est enregistré (table `autopilot_runs`) et noté dans le journal.

**Retour arrière** : les bases reviennent exactement à leur état d'avant l'exécution (l'état annulé est lui-même sauvegardé), et les documents Firestore créés sont supprimés.

### Le Réparateur (§13)

| Analyse | Correction proposée | Risque |
|---|---|---|
| Connexion : fichier absent, illisible ou qui n'est pas SQLite ; journal en attente | Explication | — |
| Intégrité (`integrity_check`) | Restaurer une sauvegarde | Destructive |
| Contraintes violées : lignes orphelines | Supprimer les lignes concernées (avec sauvegarde) | Destructive |
| Migration incomplète : clé étrangère vers une table absente, vue cassée | Explication | Structure |
| Index absent sur une clé étrangère | `CREATE INDEX` | Structure |
| Requête lente : parcours complet filtré (`EXPLAIN QUERY PLAN`) | Index sur les colonnes filtrées | Structure |
| Requête incorrecte | Message du compilateur SQLite | — |
| Fragmentation (plus de 25 % d'espace libre) | `VACUUM` (avec sauvegarde) | Destructive |
| Statistiques de l'optimiseur absentes | `ANALYZE` | Structure |

Les corrections sont des **actions typées** partagées par l'interface, l'agent (outils `diagnose_database`, `explain_query`, `create_index`, `analyze_statistics`) et AutoPilot. Après une correction, le diagnostic est relancé pour vérifier qu'elle a fait effet.

### Le Gardien (§15)

Audit statique d'un dossier de projet, plus, en option, les règles publiées des projets Firebase connectés. Le rapport trie les constats par gravité (critique, élevée, moyenne, faible, information), avec une explication et une correction pour chacun.

- **Identifiants exposés** : clés AWS, Anthropic, OpenAI, GitHub, Stripe, Slack, clés privées, secrets OAuth, mots de passe, chaînes de connexion. Les valeurs sont **toujours masquées**.
- **Accès administrateur** :
  - comptes de service Google ;
  - clé Supabase `service_role` (détectée en décodant le JWT) ;
  - SDK Firebase Admin ou connexion directe à une base depuis une application cliente.
- **Injections SQL** : requêtes construites par interpolation ou concaténation, en Dart, JavaScript ou TypeScript, Python, Java ou Kotlin.
- **Connexions non chiffrées** : `http://` hors réseau local, `sslmode=disable`, `usesCleartextTraffic`.
- **Permissions excessives** : permissions Android sensibles.
- **Règles** : Firestore (fichiers et règles publiées), RLS Supabase (tables sans RLS, politiques `using (true)`).
- **Séparation des environnements** : un seul projet Firebase, ou des tests qui visent la production.
- **Fichier `.env`** non exclu de git : correction automatique, avec sauvegarde `.bak`.

## Tests et vérifications

| Vérification | Résultat |
|---|---|
| `flutter analyze` | Aucun problème |
| `flutter test` (98 tests, dont 15 nouveaux) | **98/98**. Politique des modes ; moteur AutoPilot (plan refusé puis corrigé, risques, exécution automatique et confirmée, contrôles, rapport, retour arrière, correction acceptée ou refusée, refus d'une étape, prérequis, relance du planificateur) ; Réparateur sur une base abîmée et sur une base saine, connexion ; Gardien sur un projet piégé (7 catégories, secrets masqués, correction `.gitignore`) et sur un projet propre ; parcours UI AutoPilot complet ; boutons du Réparateur à la taille d'un téléphone |
| Essai réel AutoPilot avec Ollama `qwen3:1.7b` | **Sécurité vérifiée** : 7 plans mal formés soumis, 7 refusés, rien exécuté, base intacte. **Plan non abouti** : ce petit modèle n'a pas su produire des arguments conformes. Les messages de refus incluent désormais le schéma attendu. |
| Captures | 15 rapport AutoPilot, 16 Réparateur |
| Builds | Linux (ELF x86-64) et APK arm64 de 23 Mo, compilés après la dernière modification du code. APK installé sur le Honor : démarrage sans plantage. |

Défauts révélés par les essais réels, tous corrigés :

- le planificateur pouvait s'arrêter sans soumettre de plan : il est maintenant relancé, et les refus incluent le schéma attendu ;
- sur le Honor, les boutons du Réparateur (relance du diagnostic, plan d'exécution) n'affichaient aucun retour visible. Ils affichent maintenant un message, et l'écran défile jusqu'au résultat ;
- les coches ✓/✗ du rapport ne s'affichaient pas avec toutes les polices : ce sont maintenant des mots.

## Limitations connues

- **AutoPilot n'a pas encore été essayé de bout en bout avec Claude.** Le petit modèle local ne suffit pas pour planifier. Un essai avec Claude Opus 5.5 depuis l'interface est la prochaine validation à faire.
- Le Réparateur traite SQLite. Pour Firestore, le diagnostic passe par Firebase Rescue et par l'analyse de projet (phase 2). PostgreSQL arrivera en phase 5.
- Le retour arrière d'AutoPilot restaure la base entière à l'état d'avant l'exécution : les modifications faites entre-temps hors d'AutoPilot sont aussi annulées. L'interface le signale, et l'état annulé est sauvegardé.
- Le Gardien est une analyse statique par motifs : il peut produire des faux positifs (signalés comme tels, à vérifier), et il ne remplace pas un audit humain.
- Le PC et le téléphone ne communiquent pas encore entre eux : c'est la phase 6.
