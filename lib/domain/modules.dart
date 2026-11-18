import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Disponibilité réelle d'un module dans la version courante.
enum ModuleStatus {
  available('Opérationnel'),
  partial('Partiel'),
  planned('Prévu');

  const ModuleStatus(this.label);
  final String label;
}

enum ModuleId { fabrique, firebase, detective, reparateur, connecteur, schematiseur, coffreFort, gardien, professeur, autopilot }

class ModuleInfo {
  const ModuleInfo({
    required this.id,
    required this.name,
    required this.tagline,
    required this.icon,
    required this.colors,
    required this.status,
    required this.phase,
    required this.availableNow,
    required this.comingLater,
  });

  final ModuleId id;
  final String name;
  final String tagline;
  final IconData icon;
  final List<Color> colors;
  final ModuleStatus status;

  /// Phase du plan où le module sera complet.
  final int phase;

  /// Ce qui fonctionne réellement aujourd'hui.
  final List<String> availableNow;
  final List<String> comingLater;
}

const modules = <ModuleInfo>[
  ModuleInfo(
    id: ModuleId.fabrique,
    name: 'La Fabrique',
    tagline: 'Créer une base de données',
    icon: Icons.precision_manufacturing_rounded,
    colors: [BddColors.violet, BddColors.turquoise],
    status: ModuleStatus.available,
    phase: 1,
    availableNow: ['Création de bases SQLite réelles', 'Connexion d\'un fichier SQLite existant', 'Firestore via Firebase AutoPilot'],
    comingLater: ['PostgreSQL, MySQL, MariaDB, Supabase, MongoDB (phase 5)'],
  ),
  ModuleInfo(
    id: ModuleId.firebase,
    name: 'Firebase AutoPilot',
    tagline: 'Créer et configurer Firebase',
    icon: Icons.local_fire_department_rounded,
    colors: [BddColors.orange, BddColors.rose],
    status: ModuleStatus.available,
    phase: 2,
    availableNow: [
      'Émulateurs : données Firestore, règles (génération, tests réels, déploiement), parcours Authentication',
      'Connexion Google OAuth 2.0 (PKCE, navigateur du système, jetons dans le trousseau)',
      'Création de projet complet, projets existants, index, règles, Authentication, fichiers FlutterFire',
      'Firebase Rescue : diagnostic d\'un projet Flutter avec corrections confirmées',
    ],
    comingLater: [
      'Firebase Storage (exige le plan Blaze, facturable)',
      'Activation automatique du fournisseur Google Sign-In (console uniquement aujourd\'hui)',
    ],
  ),
  ModuleInfo(
    id: ModuleId.detective,
    name: 'Le Détective',
    tagline: 'Analyser un projet ou une BDD',
    icon: Icons.manage_search_rounded,
    colors: [BddColors.turquoise, BddColors.vert],
    status: ModuleStatus.available,
    phase: 3,
    availableNow: [
      'Analyse de dossiers Flutter, React, Angular, Vue, Node, Python : modèles, stockage, authentification, API',
      'Proposition d\'architecture de données applicable',
      'Inspection d\'une base SQLite : tables, colonnes, clés, index',
    ],
    comingLater: ['Analyse approfondie par l\'agent IA (disponible depuis l\'analyse)'],
  ),
  ModuleInfo(
    id: ModuleId.reparateur,
    name: 'Le Réparateur',
    tagline: 'Diagnostiquer et corriger',
    icon: Icons.build_circle_rounded,
    colors: [BddColors.rose, BddColors.orange],
    status: ModuleStatus.partial,
    phase: 4,
    availableNow: ['Vérification d\'intégrité SQLite (integrity_check)', 'Détection des clés étrangères orphelines'],
    comingLater: ['Diagnostic des performances, index, migrations', 'Corrections avec estimation des risques (phase 4)'],
  ),
  ModuleInfo(
    id: ModuleId.connecteur,
    name: 'Le Connecteur',
    tagline: 'Relier une BDD à une application',
    icon: Icons.cable_rounded,
    colors: [BddColors.violet, BddColors.rose],
    status: ModuleStatus.available,
    phase: 3,
    availableNow: [
      'Génération Flutter : modèles, dépôts sqflite ou Firestore, services, tests unitaires et d\'intégration',
      'Plan, différences et point de restauration avant écriture',
      'Vérification réelle (analyse statique et tests) sur PC',
    ],
    comingLater: ['Autres frameworks (React, Python) en phase ultérieure'],
  ),
  ModuleInfo(
    id: ModuleId.schematiseur,
    name: 'Le Schématiseur',
    tagline: 'Concevoir tables et relations',
    icon: Icons.schema_rounded,
    colors: [BddColors.turquoise, BddColors.violet],
    status: ModuleStatus.partial,
    phase: 5,
    availableNow: [
      'Création de tables : types, clés primaires et étrangères, contraintes, valeurs par défaut',
      'Aperçu du SQL en direct',
      'Schéma depuis une description en français (agent IA)',
    ],
    comingLater: ['Éditeur graphique avec relations, zoom et migrations (phase 5)'],
  ),
  ModuleInfo(
    id: ModuleId.coffreFort,
    name: 'Le Coffre-fort',
    tagline: 'Sauvegarder et restaurer',
    icon: Icons.lock_rounded,
    colors: [BddColors.vert, BddColors.turquoise],
    status: ModuleStatus.available,
    phase: 1,
    availableNow: [
      'Sauvegardes SQLite complètes et vérifiées',
      'Historique des sauvegardes',
      'Restauration contrôlée avec point de restauration automatique',
    ],
    comingLater: ['Sauvegardes planifiées', 'Autres moteurs'],
  ),
  ModuleInfo(
    id: ModuleId.gardien,
    name: 'Le Gardien',
    tagline: 'Vérifier la sécurité',
    icon: Icons.shield_rounded,
    colors: [BddColors.vert, BddColors.violet],
    status: ModuleStatus.planned,
    phase: 4,
    availableNow: [],
    comingLater: ['Audit des identifiants exposés, règles Firestore, RLS Supabase, injections SQL'],
  ),
  ModuleInfo(
    id: ModuleId.professeur,
    name: 'Le Professeur',
    tagline: 'Comprendre SQL, NoSQL et Firebase',
    icon: Icons.school_rounded,
    colors: [BddColors.orange, BddColors.violet],
    status: ModuleStatus.available,
    phase: 1,
    availableNow: ['Leçons en français', 'Explication des opérations réellement exécutées sur vos bases'],
    comingLater: ['Leçons interactives avec l\'agent IA'],
  ),
  ModuleInfo(
    id: ModuleId.autopilot,
    name: 'AutoPilot',
    tagline: 'Automatiser les opérations autorisées',
    icon: Icons.smart_toy_rounded,
    colors: [BddColors.violet, BddColors.orange],
    status: ModuleStatus.planned,
    phase: 4,
    availableNow: [],
    comingLater: ['Modes Manuel, Assisté et AutoPilot', 'Moteur d\'actions typées, validées et journalisées'],
  ),
];
