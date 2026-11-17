import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../data/connectors/sqlite/sqlite_sql_builder.dart';
import '../../data/connectors/sqlite/sqlite_value_codec.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../domain/models/schema.dart';
import '../../state/app_state.dart';

/// Console SQL : exécute le SQL saisi par l'utilisateur (jamais du SQL généré
/// par une IA sans validation). Les instructions destructives exigent une
/// confirmation et déclenchent un point de restauration.
class SqlConsole extends StatefulWidget {
  const SqlConsole({super.key, required this.connection});
  final DbConnection connection;

  @override
  State<SqlConsole> createState() => _SqlConsoleState();
}

class _SqlConsoleState extends State<SqlConsole> with AutomaticKeepAliveClientMixin {
  final _sql = TextEditingController(text: "SELECT name, type FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%';");
  SqlResult? _result;
  String? _error;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _sql.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final sql = _sql.text.trim();
    if (sql.isEmpty) return;
    final state = context.read<AppState>();
    var backupFirst = true;

    if (SqlSafety.isDestructive(sql)) {
      final words = SqlSafety.destructiveKeywords(sql).join(', ');
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('Opération sensible'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cette requête contient : $words.\nElle peut modifier ou supprimer des données.'),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: backupFirst,
                  onChanged: (v) => setLocal(() => backupFirst = v ?? true),
                  title: const Text('Créer un point de restauration avant (recommandé)'),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Exécuter'),
              ),
            ],
          ),
        ),
      );
      if (ok != true || !mounted) return;
    } else {
      backupFirst = false;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (backupFirst) {
        final connector = await state.connectorFor(widget.connection);
        final (b, bsql) = await state.backupsFor(widget.connection).create(connector, label: 'avant_sql');
        state.journal.log(
          projectId: widget.connection.projectId,
          connectionId: widget.connection.id,
          action: JournalAction.backupCreated,
          summary: 'Point de restauration avant SQL : ${b.name}',
          sql: bsql,
        );
      }
      final result = await state.runLogged<SqlResult>(
        connection: widget.connection,
        action: JournalAction.sqlExecuted,
        summary: 'Requête exécutée depuis la console',
        run: (c) => c.executeSql(sql),
        sqlOf: (_) => sql,
      );
      setState(() => _result = result);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _result = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final r = _result;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _sql,
          minLines: 4,
          maxLines: 12,
          style: AppTheme.mono,
          decoration: const InputDecoration(labelText: 'Requête SQL', alignLabelWithHint: true),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: _busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('Exécuter'),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Plusieurs instructions séparées par « ; » sont exécutées dans l\'ordre.',
                  style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(_error!, style: TextStyle(color: scheme.onErrorContainer)),
          ),
        if (r != null && !r.isQuery)
          Text('Instruction(s) exécutée(s). ${r.affectedRows} ligne(s) modifiée(s).',
              style: Theme.of(context).textTheme.titleSmall),
        if (r != null && r.isQuery) ...[
          Text('${r.rows.length} ligne(s)${r.rows.length > 500 ? ' (500 premières affichées)' : ''}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainer),
              columns: [for (final c in r.columns) DataColumn(label: Text(c, style: const TextStyle(fontWeight: FontWeight.w700)))],
              rows: [
                for (final row in r.rows.take(500))
                  DataRow(cells: [for (final v in row) DataCell(Text(SqliteValueCodec.display(v)))]),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
