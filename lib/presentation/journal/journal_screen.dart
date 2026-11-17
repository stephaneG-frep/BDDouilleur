import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../domain/models/journal_entry.dart';
import '../../state/app_state.dart';

/// Historique des interventions (réelles) avec le SQL ou la requête REST exécutés.
class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key});

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  bool _onlyActive = true;
  bool _onlyErrors = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final active = state.activeProject;
    var entries = state.journal.recent(projectId: _onlyActive ? active?.id : null, limit: 500);
    if (_onlyErrors) entries = entries.where((e) => !e.success).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Journal des interventions')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              if (active != null)
                FilterChip(
                  label: Text('Projet « ${active.name} » uniquement'),
                  selected: _onlyActive,
                  onSelected: (v) => setState(() => _onlyActive = v),
                ),
              FilterChip(label: const Text('Échecs uniquement'), selected: _onlyErrors, onSelected: (v) => setState(() => _onlyErrors = v)),
            ]),
          ),
          Expanded(
            child: entries.isEmpty
                ? const EmptyState(message: 'Rien dans le journal pour l\'instant. Chaque opération réalisée y sera notée.')
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: entries.length,
                    itemBuilder: (context, i) => JournalTile(entry: entries[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class JournalTile extends StatelessWidget {
  const JournalTile({super.key, required this.entry, this.trailing});
  final JournalEntry entry;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final color = e.success ? BddColors.vert : BddColors.rose;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        leading: Icon(e.success ? Icons.check_circle_rounded : Icons.error_rounded, color: color),
        title: Text(e.summary),
        subtitle: Text('${e.action.label} • ${formatDate(e.timestamp)}${e.success ? '' : ' • ÉCHEC'}'),
        trailing: trailing,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (e.error != null) ...[
            Text('Erreur : ${e.error}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
          ],
          if (e.sql != null) CodeBlock(e.sql!) else const Text('Aucune requête associée à cette opération.'),
        ],
      ),
    );
  }
}
