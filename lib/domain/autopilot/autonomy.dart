/// Modes d'autonomie de l'agent et politique de confirmation des actions.
library;

enum AutonomyMode {
  manual('Manuel', 'Vous validez chaque action qui modifie quelque chose.'),
  assisted('Assisté', 'Les opérations courantes (ajout de données) sont automatiques dans le périmètre ; les changements de structure vous sont soumis.'),
  autopilot('AutoPilot', 'L\'agent planifie et exécute les opérations non sensibles du périmètre approuvé, y compris la structure.');

  const AutonomyMode(this.label, this.help);
  final String label;
  final String help;

  static AutonomyMode fromName(String? n) => AutonomyMode.values.where((m) => m.name == n).firstOrNull ?? AutonomyMode.manual;
}

/// Niveau de risque d'une action typée.
enum ActionRisk {
  read('Lecture', 'Ne modifie rien.'),
  routine('Courante', 'Ajoute des données sans en supprimer (enregistrement, document).'),
  schema('Structure', 'Modifie la structure sans perte de données (table, index, statistiques).'),
  destructive('Destructive', 'Peut supprimer ou écraser des données (DELETE, DROP, UPDATE, VACUUM, restauration).'),
  sensitive('Sensible', 'Permissions, déploiement en production ou ressource facturable.');

  const ActionRisk(this.label, this.help);
  final String label;
  final String help;

  bool operator >(ActionRisk other) => index > other.index;
  bool operator <=(ActionRisk other) => index <= other.index;
}

abstract final class ActionPolicy {
  /// Une action doit-elle être confirmée explicitement par l'utilisateur ?
  ///
  /// Suppressions, migrations destructives, permissions, production et
  /// ressources facturables sont TOUJOURS soumises à confirmation, quel que
  /// soit le mode. Une action hors du périmètre approuvé aussi.
  static bool requiresConfirmation(AutonomyMode mode, ActionRisk risk, {bool inScope = true}) {
    if (risk == ActionRisk.read) return false;
    if (!inScope) return true;
    return switch (risk) {
      ActionRisk.read => false,
      ActionRisk.routine => mode == AutonomyMode.manual,
      ActionRisk.schema => mode != AutonomyMode.autopilot,
      ActionRisk.destructive || ActionRisk.sensitive => true,
    };
  }

  static String explain(AutonomyMode mode, ActionRisk risk, {bool inScope = true}) {
    if (!requiresConfirmation(mode, risk, inScope: inScope)) {
      return risk == ActionRisk.read ? 'Lecture : exécutée directement.' : 'Exécutée automatiquement (mode ${mode.label}, action ${risk.label.toLowerCase()}).';
    }
    if (!inScope) return 'Hors du périmètre approuvé : confirmation requise.';
    if (risk == ActionRisk.destructive || risk == ActionRisk.sensitive) {
      return 'Action ${risk.label.toLowerCase()} : confirmation toujours requise.';
    }
    return 'Confirmation requise en mode ${mode.label}.';
  }
}
