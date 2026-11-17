import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/connectors/database_connector.dart';
import '../../data/connectors/sqlite/sqlite_connector.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../domain/models/schema.dart';
import '../../state/app_state.dart';
import '../backup/backup_screen.dart';
import 'create_table_screen.dart';
import 'sql_console.dart';
import 'table_screen.dart';

enum DatabaseTab { tables, sql, health }

class DatabaseScreen extends StatelessWidget {
  const DatabaseScreen({super.key, required this.connection, this.initialTab = DatabaseTab.tables});

  final DbConnection connection;
  final DatabaseTab initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab.index,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(connection.name),
              Text('${connection.engine.label} ${SqliteConnector.libraryVersion} • ${p.basename(connection.location)}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Coffre-fort (sauvegardes)',
              icon: const Icon(Icons.lock_rounded),
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => BackupScreen(connection: connection))),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.table_chart_rounded), text: 'Tables'),
            Tab(icon: Icon(Icons.terminal_rounded), text: 'Console SQL'),
            Tab(icon: Icon(Icons.health_and_safety_rounded), text: 'Santé'),
          ]),
        ),
        body: TabBarView(children: [
          _TablesTab(connection: connection),
          SqlConsole(connection: connection),
          _HealthTab(connection: connection),
        ]),
      ),
    );
  }
}

class _TablesTab extends StatefulWidget {
  const _TablesTab({required this.connection});
  final DbConnection connection;

  @override
  State<_TablesTab> createState() => _TablesTabState();
}

class _TablesTabState extends State<_TablesTab> with AutomaticKeepAliveClientMixin {
  late Future<List<TableInfo>> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<TableInfo>> _load() async {
    final connector = await context.read<AppState>().connectorFor(widget.connection);
    final names = await connector.listTables();
    return [for (final n in names) await connector.describeTable(n)];
  }

  void _reload() => setState(() {
        _future = _load();
      });

  Future<void> _createTable() async {
    final created = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => CreateTableScreen(connection: widget.connection)));
    if (created == true) _reload();
  }

  Future<void> _drop(TableInfo t) async {
    final ok = await confirmByTyping(context,
        title: 'Supprimer la table « ${t.name} » ?',
        message: 'La table et ses ${t.rowCount} enregistrement(s) seront définitivement supprimés. '
            'Un point de restauration sera créé automatiquement avant la suppression.',
        expected: t.name);
    if (!ok || !mounted) return;
    final state = context.read<AppState>();
    try {
      final connector = await state.connectorFor(widget.connection);
      final (backup, sql) = await state.backupsFor(widget.connection).create(connector, label: 'avant_suppression');
      state.journal.log(
        projectId: widget.connection.projectId,
        connectionId: widget.connection.id,
        action: JournalAction.backupCreated,
        summary: 'Point de restauration avant suppression de « ${t.name} » : ${backup.name}',
        sql: sql,
      );
      await state.runLogged(
        connection: widget.connection,
        action: JournalAction.tableDropped,
        summary: 'Table « ${t.name} » supprimée',
        run: (c) => c.dropTable(t.name),
      );
      if (mounted) showSuccess(context, 'Table supprimée. Point de restauration : ${backup.name}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new_table',
        onPressed: _createTable,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nouvelle table'),
      ),
      body: FutureBuilder<List<TableInfo>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return EmptyState(
              message: 'Impossible de lire la base :\n${snap.error}',
              action: OutlinedButton(onPressed: _reload, child: const Text('Réessayer')),
            );
          }
          final tables = snap.data!;
          if (tables.isEmpty) {
            return EmptyState(
              message: 'Cette base est vide. Créez votre première table pour y ranger des données.',
              action: FilledButton.icon(
                  onPressed: _createTable, icon: const Icon(Icons.add_rounded), label: const Text('Créer une table')),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: tables.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final t = tables[i];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.table_chart_rounded, color: BddColors.violet),
                    title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${t.columns.length} colonne(s) • ${t.rowCount} enregistrement(s)'
                        '${t.foreignKeys.isEmpty ? '' : ' • ${t.foreignKeys.length} relation(s)'}'),
                    onTap: () async {
                      await Navigator.push(context,
                          MaterialPageRoute(builder: (_) => TableScreen(connection: widget.connection, table: t.name)));
                      _reload();
                    },
                    trailing: IconButton(
                      tooltip: 'Supprimer la table',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () => _drop(t),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _HealthTab extends StatefulWidget {
  const _HealthTab({required this.connection});
  final DbConnection connection;

  @override
  State<_HealthTab> createState() => _HealthTabState();
}

class _HealthTabState extends State<_HealthTab> {
  IntegrityReport? _report;
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      final report = await context.read<AppState>().runLogged<IntegrityReport>(
            connection: widget.connection,
            action: JournalAction.integrityChecked,
            summary: 'Vérification d\'intégrité',
            run: (c) => c.checkIntegrity(),
            sqlOf: (_) => 'PRAGMA integrity_check;\nPRAGMA foreign_key_check;',
          );
      setState(() => _report = report);
    } on ConnectorException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const MascotTip(
          title: 'Le Réparateur — diagnostic',
          message: 'Je vérifie la structure interne du fichier (pages, index) et je recherche les clés '
              'étrangères qui pointent vers des lignes inexistantes. Ce contrôle ne modifie rien.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _check,
          icon: const Icon(Icons.health_and_safety_rounded),
          label: const Text('Lancer le diagnostic'),
        ),
        const SizedBox(height: 16),
        if (r != null)
          GradientCard(
            colors: r.ok ? const [BddColors.vert, BddColors.turquoise] : const [BddColors.rose, BddColors.orange],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(r.ok ? Icons.verified_rounded : Icons.report_problem_rounded,
                      color: r.ok ? BddColors.vert : BddColors.rose),
                  const SizedBox(width: 8),
                  Text(r.ok ? 'Base en bonne santé' : 'Problèmes détectés',
                      style: Theme.of(context).textTheme.titleMedium),
                ]),
                const SizedBox(height: 8),
                Text('Intégrité : ${r.messages.join(', ')}'),
                Text(r.foreignKeyViolations.isEmpty
                    ? 'Clés étrangères : aucune référence orpheline.'
                    : 'Références orphelines :\n${r.foreignKeyViolations.join('\n')}'),
                if (!r.ok) ...[
                  const SizedBox(height: 8),
                  const Text('Correction : restaurez une sauvegarde saine depuis le Coffre-fort, ou corrigez les '
                      'lignes concernées. Les corrections automatiques arriveront en phase 4.'),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
