import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/analysis/project_analyzer.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/schema_proposal.dart';
import '../../state/app_state.dart';
import '../agent/agent_screen.dart';
import '../codegen/schema_proposal_card.dart';
import '../firebase/firebase_widgets.dart';

/// Le Détective : analyse d'un dossier de projet (Flutter, React, Angular,
/// Vue, Python, Node…) et proposition d'architecture de données.
class ProjectAnalysisScreen extends StatefulWidget {
  const ProjectAnalysisScreen({super.key});

  @override
  State<ProjectAnalysisScreen> createState() => _ProjectAnalysisScreenState();
}

class _ProjectAnalysisScreenState extends State<ProjectAnalysisScreen> {
  final _form = GlobalKey<FormState>();
  final _folder = TextEditingController();
  ProjectAnalysis? _analysis;
  SchemaProposal? _proposal;
  bool _busy = false;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (!_form.currentState!.validate()) return;
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final a = await ProjectAnalyzer(_folder.text.trim()).run();
      final proposal = ProjectAnalyzer.proposeSchema(a);
      state.journal.log(
        projectId: state.activeProject?.id,
        action: JournalAction.agentToolExecuted,
        summary: 'Le Détective : analyse de ${a.root} (${a.technology}, ${a.models.length} modèle(s))',
      );
      setState(() {
        _analysis = a;
        _proposal = proposal;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _analysis;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Le Détective — analyse de projet')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const MascotTip(
              message: 'Je lis votre projet (sans rien modifier) : technologie, dépendances, modèles, services, stockage, '
                  'authentification et appels API. Les fichiers de secrets (.env, clés) ne sont jamais ouverts.',
            ),
            const SizedBox(height: 12),
            FolderField(
              controller: _folder,
              label: 'Dossier du projet',
              validator: (v) => (v ?? '').trim().isEmpty
                  ? 'Chemin obligatoire.'
                  : !Directory(v!.trim()).existsSync()
                      ? 'Dossier introuvable.'
                      : null,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.manage_search_rounded),
              label: const Text('Analyser'),
              onPressed: _busy ? null : _run,
            ),
            if (a != null) ...[
              const SizedBox(height: 20),
              Wrap(spacing: 8, runSpacing: 8, children: [
                StatusChip(label: a.technology, color: BddColors.violet, icon: Icons.code_rounded),
                for (final f in a.frameworks) StatusChip(label: f, color: BddColors.turquoise),
                StatusChip(label: '${a.sourceFileCount} fichiers source', color: BddColors.orange),
              ]),
              const SizedBox(height: 12),
              _section('Stockage', Icons.storage_rounded,
                  a.storage.isEmpty ? ['Aucun stockage persistant détecté'] : [for (final e in a.storage.entries) '${e.value} (${e.key})']),
              _section('Authentification', Icons.lock_person_rounded,
                  a.auth.isEmpty ? ['Aucune détectée'] : [for (final e in a.auth.entries) '${e.value} (${e.key})']),
              _section('Modèles de données (${a.models.length})', Icons.data_object_rounded, [
                for (final m in a.models)
                  '${m.name} — ${m.fields.map((f) => '${f.name}: ${f.type}${f.nullable ? '?' : ''}').join(', ')}\n   ${m.file}'
              ]),
              if (a.services.isNotEmpty) _section('Services et dépôts', Icons.miscellaneous_services_rounded, a.services),
              if (a.apiHosts.isNotEmpty)
                _section('Appels API', Icons.public_rounded, [for (final e in a.apiHosts.entries) '${e.key} (${e.value} occurrence(s))']),
              if (a.configs.isNotEmpty) _section('Configurations', Icons.settings_rounded, a.configs),
              if (a.findings.isNotEmpty) _section('Constats', Icons.lightbulb_rounded, a.findings, color: BddColors.orange),
              const SizedBox(height: 12),
              if (_proposal != null && _proposal!.entities.isNotEmpty)
                SchemaProposalCard(proposal: _proposal!, folder: File('${a.root}/pubspec.yaml').existsSync() ? a.root : null)
              else
                const MascotTip(message: 'Aucun modèle exploitable : demandez à l\'agent de proposer un schéma à partir d\'une description.'),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.smart_toy_rounded),
                label: const Text('Demander à l\'agent IA'),
                onPressed: () => startConversation(
                  context,
                  folder: a.root,
                  prompt: 'Analyse ce projet (outil analyze_project), explique-moi son fonctionnement et propose une architecture '
                      'de données adaptée avec propose_schema, en justifiant chaque entité et relation.',
                ),
              ),
              const SizedBox(height: 8),
              Text('Analyse déterministe, sans IA : l\'agent peut l\'approfondir en lisant les fichiers.', style: text.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _section(String title, IconData icon, List<String> lines, {Color? color}) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ExpansionTile(
          shape: const Border(),
          initiallyExpanded: lines.length <= 6,
          leading: Icon(icon, color: color),
          title: Text(title),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 4), child: SelectableText('• $l'))],
        ),
      );
}
