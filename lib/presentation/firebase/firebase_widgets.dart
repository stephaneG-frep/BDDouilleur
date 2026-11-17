import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/firebase/firebase_diagnostic.dart';
import '../../domain/models/journal_entry.dart';
import '../../state/app_state.dart';

Color severityColor(DiagSeverity s) => switch (s) {
      DiagSeverity.error => BddColors.rose,
      DiagSeverity.warning => BddColors.orange,
      DiagSeverity.info => BddColors.turquoise,
      DiagSeverity.ok => BddColors.vert,
    };

IconData severityIcon(DiagSeverity s) => switch (s) {
      DiagSeverity.error => Icons.error_rounded,
      DiagSeverity.warning => Icons.warning_amber_rounded,
      DiagSeverity.info => Icons.info_rounded,
      DiagSeverity.ok => Icons.check_circle_rounded,
    };

/// Constat au format Problème — Cause — Solution — Risque — Correction — Vérification.
class DiagnosticFindingCard extends StatelessWidget {
  const DiagnosticFindingCard({super.key, required this.finding, this.onFixed, this.projectId});
  final DiagnosticFinding finding;

  /// Appelé après l'application d'une correction (pour relancer le diagnostic).
  final VoidCallback? onFixed;
  final int? projectId;

  @override
  Widget build(BuildContext context) {
    final f = finding;
    final color = severityColor(f.severity);
    final rows = <(String, String)>[
      ('Cause', f.cause),
      ('Solution', f.solution),
      ('Risque', f.risk),
      ('Correction', f.correction),
      ('Vérification', f.verification),
    ].where((r) => r.$2.trim().isNotEmpty).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        initiallyExpanded: f.severity == DiagSeverity.error,
        leading: Icon(severityIcon(f.severity), color: color),
        title: Text(f.problem),
        subtitle: Text(f.severity.label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, text) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color)),
                SelectableText(text),
              ]),
            ),
          if (f.fix != null)
            FilledButton.icon(
              icon: const Icon(Icons.auto_fix_high_rounded),
              label: Text(f.fix!.label),
              onPressed: () => _applyFix(context, f),
            ),
        ],
      ),
    );
  }

  Future<void> _applyFix(BuildContext context, DiagnosticFinding f) async {
    final ok = await confirm(context,
        title: f.fix!.label, message: '${f.fix!.preview}\n\nRisque : ${f.risk.isEmpty ? 'non précisé' : f.risk}', action: 'Appliquer');
    if (!ok || !context.mounted) return;
    final state = context.read<AppState>();
    try {
      final report = await f.fix!.apply();
      state.journal.log(
        projectId: projectId,
        action: JournalAction.diagnosticFixApplied,
        summary: '${f.fix!.label} — ${f.problem}\n$report',
      );
      if (context.mounted) showSuccess(context, 'Correction appliquée. Vérification en cours…');
      onFixed?.call();
    } catch (e) {
      state.journal.log(
          projectId: projectId,
          action: JournalAction.diagnosticFixApplied,
          summary: '${f.fix!.label} — ${f.problem}',
          success: false,
          error: '$e');
      if (context.mounted) showError(context, e);
    }
  }
}

/// Résumé coloré du nombre de constats par gravité.
class FindingsSummary extends StatelessWidget {
  const FindingsSummary(this.findings, {super.key});
  final List<DiagnosticFinding> findings;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final s in DiagSeverity.values)
        if (findings.any((f) => f.severity == s))
          StatusChip(
            label: '${findings.where((f) => f.severity == s).length} ${s.label.toLowerCase()}',
            color: severityColor(s),
            icon: severityIcon(s),
          ),
    ]);
  }
}

/// Champ de saisie d'un dossier, avec sélecteur natif sous Linux.
class FolderField extends StatelessWidget {
  const FolderField({super.key, required this.controller, required this.label, this.helper, this.validator});
  final TextEditingController controller;
  final String label;
  final String? helper;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: TextFormField(
          controller: controller,
          decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 3),
          validator: validator,
        ),
      ),
      if (Platform.isLinux) ...[
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: IconButton.filledTonal(
            tooltip: 'Parcourir',
            icon: const Icon(Icons.folder_open_rounded),
            onPressed: () async {
              final dir = await getDirectoryPath(confirmButtonText: 'Choisir');
              if (dir != null) controller.text = dir;
            },
          ),
        ),
      ],
    ]);
  }
}

/// Section titrée dans une carte.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.icon, required this.title, required this.children, this.color});
  final IconData icon;
  final String title;
  final List<Widget> children;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: c),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }
}

/// Bouton qui affiche un indicateur pendant une action asynchrone.
class BusyButton extends StatefulWidget {
  const BusyButton({super.key, required this.label, required this.icon, required this.onPressed, this.tonal = false});
  final String label;
  final IconData icon;
  final Future<void> Function()? onPressed;
  final bool tonal;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final icon = _busy
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(widget.icon);
    final onPressed = widget.onPressed == null || _busy
        ? null
        : () async {
            setState(() => _busy = true);
            try {
              await widget.onPressed!();
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          };
    return widget.tonal
        ? FilledButton.tonalIcon(onPressed: onPressed, icon: icon, label: Text(widget.label))
        : FilledButton.icon(onPressed: onPressed, icon: icon, label: Text(widget.label));
  }
}

/// Vérifie qu'un dossier est la racine d'un projet Flutter.
String? validateFlutterProject(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return 'Chemin obligatoire.';
  if (!Directory(s).existsSync()) return 'Dossier introuvable.';
  if (!File('$s/pubspec.yaml').existsSync()) return 'Pas de pubspec.yaml : ce n\'est pas la racine d\'un projet Flutter.';
  return null;
}
