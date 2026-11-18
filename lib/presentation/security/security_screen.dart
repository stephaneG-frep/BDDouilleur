import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/security/security_auditor.dart';
import '../../domain/firebase/firestore_rules.dart';
import '../../domain/models/db_engine.dart';
import '../../domain/models/journal_entry.dart';
import '../../state/app_state.dart';
import '../firebase/firebase_widgets.dart' show FolderField;

Color securityColor(SecuritySeverity s) => switch (s) {
      SecuritySeverity.critical => BddColors.rose,
      SecuritySeverity.high => const Color(0xFFFF7A59),
      SecuritySeverity.medium => BddColors.orange,
      SecuritySeverity.low => BddColors.turquoise,
      SecuritySeverity.info => BddColors.violet,
    };

/// Le Gardien : audit de sécurité d'un projet et des règles Firebase connectées.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _folder = TextEditingController();
  bool _includeFirebase = true;
  bool _busy = false;
  List<SecurityFinding>? _findings;

  AppState get _state => context.read<AppState>();

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final folder = _folder.text.trim();
    final project = _state.activeProject;
    final googleConns = project == null
        ? []
        : _state.connections.forProject(project.id!).where((c) => c.engine == DbEngine.firestore && !c.firebase.isEmulator).toList();
    if (folder.isEmpty && !(_includeFirebase && googleConns.isNotEmpty)) {
      showError(context, 'Choisissez un dossier de projet (ou connectez un projet Firebase).');
      return;
    }
    if (folder.isNotEmpty && !Directory(folder).existsSync()) {
      showError(context, 'Dossier introuvable.');
      return;
    }
    setState(() => _busy = true);
    try {
      final out = <SecurityFinding>[];
      if (folder.isNotEmpty) out.addAll(await SecurityAuditor(folder).run());
      if (_includeFirebase) {
        for (final c in googleConns) {
          try {
            final rules = await _state.rulesFor(c).currentRules();
            if (rules == null) continue;
            for (final r in RulesAnalyzer.analyze(rules)) {
              out.add(SecurityFinding(
                severity: switch (r.severity) {
                  RuleSeverity.critical => SecuritySeverity.critical,
                  RuleSeverity.warning => SecuritySeverity.medium,
                  RuleSeverity.info => SecuritySeverity.low,
                },
                category: SecurityCategory.rules,
                title: 'Règles publiées de « ${c.name} » : ${r.title}',
                explanation: r.explanation,
                correction: 'Firebase AutoPilot → projet → Règles → générer, tester puis déployer des règles fermées.',
                location: 'Firebase ${c.location}${r.line == null ? '' : ', ligne ${r.line}'}',
              ));
            }
          } catch (e) {
            out.add(SecurityFinding(
              severity: SecuritySeverity.info,
              category: SecurityCategory.rules,
              title: 'Règles de « ${c.name} » non lues',
              explanation: '$e',
              correction: 'Vérifiez la connexion Google.',
            ));
          }
        }
      }
      out.sort((a, b) => a.severity.index.compareTo(b.severity.index));
      _state.journal.log(
        projectId: project?.id,
        action: JournalAction.securityAudit,
        summary: 'Le Gardien${folder.isEmpty ? '' : ' sur $folder'} : '
            '${SecuritySeverity.values.map((s) => '${out.where((f) => f.severity == s).length} ${s.label.toLowerCase()}').join(', ')}',
      );
      setState(() => _findings = out);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _findings;
    return Scaffold(
      appBar: AppBar(title: const Text('Le Gardien — sécurité')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const MascotTip(
            message: 'Audit en lecture seule : identifiants exposés, permissions excessives, règles Firestore, RLS Supabase, '
                'injections SQL, connexions non chiffrées, séparation des environnements, accès administrateur. '
                'Les secrets trouvés ne sont jamais affichés en clair.',
          ),
          const SizedBox(height: 12),
          FolderField(controller: _folder, label: 'Dossier du projet à auditer'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _includeFirebase,
            onChanged: (v) => setState(() => _includeFirebase = v),
            title: const Text('Inclure les règles publiées des projets Firebase connectés'),
          ),
          FilledButton.icon(
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.shield_rounded),
            label: const Text('Lancer l\'audit'),
            onPressed: _busy ? null : _run,
          ),
          if (f != null) ...[
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in SecuritySeverity.values)
                if (f.any((x) => x.severity == s))
                  StatusChip(label: '${f.where((x) => x.severity == s).length} ${s.label.toLowerCase()}', color: securityColor(s)),
              if (f.isEmpty) const StatusChip(label: 'Aucun problème détecté', color: BddColors.vert, icon: Icons.verified_rounded),
            ]),
            const SizedBox(height: 12),
            for (final x in f)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ExpansionTile(
                  shape: const Border(),
                  initiallyExpanded: x.severity == SecuritySeverity.critical,
                  leading: Icon(Icons.shield_moon_rounded, color: securityColor(x.severity)),
                  title: Text(x.title),
                  subtitle: Text('${x.severity.label} • ${x.category.label}${x.location == null ? '' : ' • ${x.location}'}',
                      style: TextStyle(color: securityColor(x.severity))),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(x.explanation),
                    const SizedBox(height: 8),
                    const Text('Correction proposée', style: TextStyle(fontWeight: FontWeight.w600)),
                    Text(x.correction),
                    if (x.fix != null) ...[
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        icon: const Icon(Icons.auto_fix_high_rounded),
                        label: Text(x.fix!.label),
                        onPressed: () async {
                          final ok = await confirm(context, title: x.fix!.label, message: x.fix!.preview, action: 'Appliquer');
                          if (!ok || !context.mounted) return;
                          try {
                            final report = await x.fix!.apply();
                            _state.journal.log(
                                projectId: _state.activeProject?.id,
                                action: JournalAction.repairApplied,
                                summary: 'Le Gardien : ${x.fix!.label}\n$report');
                            if (context.mounted) showSuccess(context, report);
                            await _run();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
