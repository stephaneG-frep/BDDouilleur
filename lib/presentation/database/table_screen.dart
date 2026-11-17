import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/connectors/sqlite/sqlite_value_codec.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../domain/models/schema.dart';
import '../../state/app_state.dart';

class TableScreen extends StatefulWidget {
  const TableScreen({super.key, required this.connection, required this.table});
  final DbConnection connection;
  final String table;

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends State<TableScreen> {
  static const _pageSize = 50;
  int _offset = 0;
  late Future<(TableInfo, RowPage)> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<(TableInfo, RowPage)> _load() async {
    final c = await context.read<AppState>().connectorFor(widget.connection);
    final info = await c.describeTable(widget.table);
    if (_offset >= info.rowCount && _offset > 0) _offset = ((info.rowCount - 1) ~/ _pageSize) * _pageSize;
    final page = await c.readRows(widget.table, limit: _pageSize, offset: _offset);
    return (info, page);
  }

  void _reload() => setState(() {
        _future = _load();
      });

  Future<void> _edit(TableInfo info, {Map<String, Object?>? row, RowKey? key}) async {
    final values = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _RowEditorDialog(info: info, row: row),
    );
    if (values == null || !mounted) return;
    final state = context.read<AppState>();
    try {
      if (key == null) {
        final r = await state.runLogged(
          connection: widget.connection,
          action: JournalAction.rowInserted,
          summary: 'Enregistrement ajouté dans « ${widget.table} »',
          run: (c) => c.insertRow(widget.table, values),
        );
        if (mounted) showSuccess(context, 'Enregistrement ajouté (rowid ${r.insertedId}).');
      } else {
        await state.runLogged(
          connection: widget.connection,
          action: JournalAction.rowUpdated,
          summary: 'Enregistrement modifié dans « ${widget.table} »',
          run: (c) => c.updateRow(widget.table, key, values),
        );
        if (mounted) showSuccess(context, 'Enregistrement modifié.');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _reload();
  }

  Future<void> _delete(RowKey key) async {
    final ok = await confirm(context,
        title: 'Supprimer cet enregistrement ?',
        message: 'Cette ligne sera définitivement supprimée de « ${widget.table} ».',
        action: 'Supprimer',
        danger: true);
    if (!ok || !mounted) return;
    try {
      await context.read<AppState>().runLogged(
            connection: widget.connection,
            action: JournalAction.rowDeleted,
            summary: 'Enregistrement supprimé dans « ${widget.table} »',
            run: (c) => c.deleteRow(widget.table, key),
          );
      if (mounted) showSuccess(context, 'Enregistrement supprimé.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: FutureBuilder<(TableInfo, RowPage)>(
        future: _future,
        builder: (context, snap) {
          final data = snap.data;
          return Scaffold(
            appBar: AppBar(
              title: Text(widget.table),
              actions: [IconButton(tooltip: 'Actualiser', onPressed: _reload, icon: const Icon(Icons.refresh_rounded))],
              bottom: const TabBar(tabs: [Tab(text: 'Données'), Tab(text: 'Structure')]),
            ),
            floatingActionButton: data == null
                ? null
                : FloatingActionButton.extended(
                    heroTag: 'add_row',
                    onPressed: () => _edit(data.$1),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Ajouter'),
                  ),
            body: snap.hasError
                ? EmptyState(message: 'Erreur : ${snap.error}', action: OutlinedButton(onPressed: _reload, child: const Text('Réessayer')))
                : data == null
                    ? const Center(child: CircularProgressIndicator())
                    : TabBarView(children: [_dataView(data.$1, data.$2), _StructureView(info: data.$1)]),
          );
        },
      ),
    );
  }

  Widget _dataView(TableInfo info, RowPage page) {
    if (page.rows.isEmpty && page.total == 0) {
      return EmptyState(
        message: 'Aucun enregistrement dans « ${info.name} ».',
        action: FilledButton.icon(
            onPressed: () => _edit(info), icon: const Icon(Icons.add_rounded), label: const Text('Ajouter le premier')),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final last = (_offset + page.rows.length);
    return Column(
      children: [
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 88),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(12),
                child: DataTable(
                  headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainer),
                  border: TableBorder.all(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(12)),
                  columns: [
                    const DataColumn(label: Text('')),
                    for (final c in info.columns)
                      DataColumn(
                        label: Row(children: [
                          if (c.isPrimaryKey) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.key_rounded, size: 16, color: BddColors.orange)),
                          Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        ]),
                        tooltip: c.declaredType.isEmpty ? 'Sans type' : c.declaredType,
                        numeric: c.affinity == 'INTEGER' || c.affinity == 'REAL',
                      ),
                  ],
                  rows: [
                    for (var i = 0; i < page.rows.length; i++)
                      DataRow(cells: [
                        DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: 'Modifier',
                            icon: const Icon(Icons.edit_rounded, size: 18),
                            onPressed: () => _edit(info, row: page.rows[i], key: page.keys[i]),
                          ),
                          IconButton(
                            tooltip: 'Supprimer',
                            icon: Icon(Icons.delete_outline_rounded, size: 18, color: scheme.error),
                            onPressed: () => _delete(page.keys[i]),
                          ),
                        ])),
                        for (final c in info.columns)
                          DataCell(ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 280),
                            child: Text(
                              SqliteValueCodec.display(page.rows[i][c.name]),
                              overflow: TextOverflow.ellipsis,
                              style: page.rows[i][c.name] == null
                                  ? TextStyle(color: scheme.outline, fontStyle: FontStyle.italic)
                                  : null,
                            ),
                          )),
                      ]),
                  ],
                ),
              ),
            ),
          ),
        ),
        Material(
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Text('${_offset + 1}–$last sur ${page.total}'),
                IconButton(
                  tooltip: 'Page précédente',
                  onPressed: _offset == 0 ? null : () => setState(() {
                    _offset = (_offset - _pageSize).clamp(0, page.total);
                    _future = _load();
                  }),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                IconButton(
                  tooltip: 'Page suivante',
                  onPressed: last >= page.total ? null : () => setState(() {
                    _offset += _pageSize;
                    _future = _load();
                  }),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
                const Spacer(),
                const SizedBox(width: 150), // place du bouton « Ajouter »
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StructureView extends StatelessWidget {
  const _StructureView({required this.info});
  final TableInfo info;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${info.rowCount} enregistrement(s)${info.withoutRowId ? ' • WITHOUT ROWID' : ''}', style: text.bodySmall),
        const SizedBox(height: 12),
        Text('Colonnes', style: text.titleMedium),
        const SizedBox(height: 8),
        for (final c in info.columns)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              leading: Icon(c.isPrimaryKey ? Icons.key_rounded : Icons.view_column_rounded,
                  color: c.isPrimaryKey ? BddColors.orange : BddColors.turquoise),
              title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([
                c.declaredType.isEmpty ? 'sans type' : c.declaredType,
                'affinité ${c.affinity}',
                if (c.isPrimaryKey) 'clé primaire',
                if (c.notNull) 'obligatoire',
                if (c.defaultValue != null) 'défaut ${c.defaultValue}',
              ].join(' • ')),
            ),
          ),
        if (info.foreignKeys.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Relations (clés étrangères)', style: text.titleMedium),
          const SizedBox(height: 8),
          for (final fk in info.foreignKeys)
            ListTile(
              dense: true,
              leading: const Icon(Icons.link_rounded, color: BddColors.violet),
              title: Text('${fk.from} → ${fk.table}.${fk.to ?? '(clé primaire)'}'),
              subtitle: Text('ON DELETE ${fk.onDelete}'),
            ),
        ],
        if (info.indexes.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Index', style: text.titleMedium),
          const SizedBox(height: 8),
          for (final idx in info.indexes)
            ListTile(
              dense: true,
              leading: const Icon(Icons.bolt_rounded, color: BddColors.vert),
              title: Text(idx.name),
              subtitle: Text('${idx.unique ? 'unique • ' : ''}${idx.columns.join(', ')} • '
                  '${switch (idx.origin) { 'pk' => 'clé primaire', 'u' => 'contrainte UNIQUE', _ => 'CREATE INDEX' }}'),
            ),
        ],
        if (info.createSql != null) ...[
          const SizedBox(height: 12),
          Text('Définition SQL', style: text.titleMedium),
          const SizedBox(height: 8),
          CodeBlock(info.createSql!),
        ],
      ],
    );
  }
}

/// Saisie d'un enregistrement. Retourne les valeurs converties.
///
/// En ajout, un champ laissé vide est omis pour que la valeur par défaut (ou
/// l'auto-incrément) s'applique. Cocher « NULL » force la valeur NULL.
class _RowEditorDialog extends StatefulWidget {
  const _RowEditorDialog({required this.info, this.row});
  final TableInfo info;
  final Map<String, Object?>? row;

  @override
  State<_RowEditorDialog> createState() => _RowEditorDialogState();
}

class _RowEditorDialogState extends State<_RowEditorDialog> {
  late final Map<String, TextEditingController> _ctrl;
  late final Map<String, bool> _isNull;
  String? _error;

  bool get _isEdit => widget.row != null;

  @override
  void initState() {
    super.initState();
    _ctrl = {
      for (final c in widget.info.columns)
        c.name: TextEditingController(text: _isEdit && widget.row![c.name] != null ? widget.row![c.name].toString() : ''),
    };
    _isNull = {for (final c in widget.info.columns) c.name: _isEdit && widget.row![c.name] == null};
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final values = <String, Object?>{};
    try {
      for (final c in widget.info.columns) {
        final original = widget.row?[c.name];
        if (_isEdit && !SqliteValueCodec.isEditable(original)) continue; // BLOB conservé tel quel
        if (_isNull[c.name]!) {
          if (!_isEdit || original != null) values[c.name] = null;
          continue;
        }
        final text = _ctrl[c.name]!.text;
        if (!_isEdit && text.trim().isEmpty) continue; // valeur par défaut / auto-incrément
        final parsed = c.affinity == 'TEXT' ? text : SqliteValueCodec.parse(text, c);
        if (!_isEdit || parsed != original) values[c.name] = parsed;
      }
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Modifier l\'enregistrement' : 'Nouvel enregistrement'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_isEdit)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('Laissez un champ vide pour utiliser sa valeur par défaut ou la numérotation automatique.',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              for (final c in widget.info.columns) _field(c),
              if (_error != null)
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: _save, child: Text(_isEdit ? 'Enregistrer' : 'Ajouter')),
      ],
    );
  }

  Widget _field(ColumnInfo c) {
    final original = widget.row?[c.name];
    if (_isEdit && !SqliteValueCodec.isEditable(original)) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(c.name),
        subtitle: Text('${SqliteValueCodec.display(original)} (non modifiable ici)'),
      );
    }
    final isNull = _isNull[c.name]!;
    final numeric = c.affinity == 'INTEGER' || c.affinity == 'REAL' || c.affinity == 'NUMERIC';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl[c.name],
              enabled: !isNull,
              keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true, signed: true) : TextInputType.text,
              style: AppTheme.mono,
              decoration: InputDecoration(
                labelText: '${c.name}${c.notNull ? ' *' : ''}',
                helperText: [
                  c.declaredType.isEmpty ? 'sans type' : c.declaredType,
                  if (c.isPrimaryKey) 'clé primaire',
                  if (c.defaultValue != null) 'défaut : ${c.defaultValue}',
                ].join(' • '),
                isDense: true,
              ),
            ),
          ),
          if (!c.notNull) ...[
            const SizedBox(width: 6),
            Column(children: [
              Checkbox(value: isNull, onChanged: (v) => setState(() => _isNull[c.name] = v ?? false)),
              const Text('NULL', style: TextStyle(fontSize: 11)),
            ]),
          ],
        ],
      ),
    );
  }
}
