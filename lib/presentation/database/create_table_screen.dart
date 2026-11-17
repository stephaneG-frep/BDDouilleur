import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/common.dart';
import '../../data/connectors/sqlite/sqlite_sql_builder.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../domain/models/schema.dart';
import '../../state/app_state.dart';

class _ColumnDraft {
  _ColumnDraft({String name = '', this.type = SqlColumnType.text, this.primaryKey = false, this.autoIncrement = false, this.notNull = false})
      : name = TextEditingController(text: name),
        defaultValue = TextEditingController();

  final TextEditingController name;
  final TextEditingController defaultValue;
  SqlColumnType type;
  bool primaryKey;
  bool autoIncrement;
  bool notNull;
  bool unique = false;
  String? refTable;
  String? refColumn;
  String onDelete = 'NO ACTION';

  ColumnDefinition toDefinition() => ColumnDefinition(
        name: name.text,
        type: type,
        primaryKey: primaryKey,
        autoIncrement: autoIncrement,
        notNull: notNull,
        unique: unique,
        defaultValue: defaultValue.text.trim().isEmpty ? null : defaultValue.text,
        references: (refTable != null && refColumn != null)
            ? ForeignKeyRef(table: refTable!, column: refColumn!, onDelete: onDelete)
            : null,
      );

  void dispose() {
    name.dispose();
    defaultValue.dispose();
  }
}

/// Le Schématiseur (version formulaire) : création d'une table.
class CreateTableScreen extends StatefulWidget {
  const CreateTableScreen({super.key, required this.connection});
  final DbConnection connection;

  @override
  State<CreateTableScreen> createState() => _CreateTableScreenState();
}

class _CreateTableScreenState extends State<CreateTableScreen> {
  final _tableName = TextEditingController();
  final List<_ColumnDraft> _columns = [
    _ColumnDraft(name: 'id', type: SqlColumnType.integer, primaryKey: true, autoIncrement: true),
    _ColumnDraft(name: 'nom', notNull: true),
  ];

  /// Tables existantes et leurs colonnes, pour les clés étrangères.
  Map<String, List<String>> _existing = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    try {
      final c = await context.read<AppState>().connectorFor(widget.connection);
      final map = <String, List<String>>{};
      for (final t in await c.listTables()) {
        map[t] = (await c.describeTable(t)).columns.map((c) => c.name).toList();
      }
      if (mounted) setState(() => _existing = map);
    } catch (_) {
      // Les clés étrangères resteront indisponibles ; la création reste possible.
    }
  }

  @override
  void dispose() {
    _tableName.dispose();
    for (final c in _columns) {
      c.dispose();
    }
    super.dispose();
  }

  TableDefinition get _definition =>
      TableDefinition(name: _tableName.text, columns: _columns.map((c) => c.toDefinition()).toList());

  Future<void> _submit() async {
    final def = _definition;
    final errors = SqliteSqlBuilder.validateTable(def);
    if (errors.isNotEmpty) {
      showError(context, errors.first);
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AppState>().runLogged(
            connection: widget.connection,
            action: JournalAction.tableCreated,
            summary: 'Table « ${def.name.trim()} » créée (${def.columns.length} colonnes)',
            run: (c) => c.createTable(def),
          );
      if (!mounted) return;
      showSuccess(context, 'Table « ${def.name.trim()} » créée.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final def = _definition;
    final errors = SqliteSqlBuilder.validateTable(def);
    String preview;
    try {
      preview = SqliteSqlBuilder.createTable(def);
    } catch (_) {
      preview = '-- Complétez la définition pour voir le SQL généré';
    }
    final wide = MediaQuery.sizeOf(context).width >= 1000;

    final form = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const MascotTip(
          message: 'Une table, c\'est comme un tableau : chaque colonne est un champ (nom, prix…) et chaque '
              'ligne un enregistrement. La clé primaire identifie chaque ligne de façon unique.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _tableName,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Nom de la table',
            hintText: 'Ex. clients',
            errorText: _tableName.text.isEmpty ? null : SqliteSqlBuilder.validateIdentifier(_tableName.text, kind: 'nom de table'),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        Text('Colonnes', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (var i = 0; i < _columns.length; i++) _columnCard(i),
        OutlinedButton.icon(
          onPressed: () => setState(() => _columns.add(_ColumnDraft())),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Ajouter une colonne'),
        ),
        if (!wide) ...[const SizedBox(height: 16), _previewPanel(preview, errors)],
        const SizedBox(height: 80),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle table')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy || errors.isNotEmpty ? null : _submit,
        backgroundColor: errors.isNotEmpty ? Theme.of(context).disabledColor : null,
        icon: const Icon(Icons.check_rounded),
        label: const Text('Créer la table'),
      ),
      body: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: form),
              Expanded(
                flex: 2,
                child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: _previewPanel(preview, errors)),
              ),
            ])
          : form,
    );
  }

  Widget _previewPanel(String preview, List<String> errors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SQL généré (aperçu en direct)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        CodeBlock(preview),
        if (errors.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final e in errors)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.error_outline, size: 18, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 6),
                Expanded(child: Text(e, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              ]),
            ),
        ],
      ],
    );
  }

  Widget _columnCard(int i) {
    final c = _columns[i];
    final refColumns = c.refTable == null ? const <String>[] : (_existing[c.refTable] ?? const <String>[]);
    return Padding(
      key: ObjectKey(c),
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: c.name,
                      decoration: InputDecoration(labelText: 'Nom de la colonne ${i + 1}', isDense: true),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<SqlColumnType>(
                      initialValue: c.type,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Type', isDense: true),
                      items: [
                        for (final t in SqlColumnType.values)
                          DropdownMenuItem(value: t, child: Text(t.sql, overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (t) => setState(() {
                        c.type = t!;
                        if (t != SqlColumnType.integer) c.autoIncrement = false;
                      }),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Retirer la colonne',
                    onPressed: _columns.length <= 1
                        ? null
                        : () => setState(() {
                              _columns.removeAt(i).dispose();
                            }),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(c.type.help, style: Theme.of(context).textTheme.bodySmall),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  FilterChip(
                    label: const Text('Clé primaire'),
                    selected: c.primaryKey,
                    onSelected: (v) => setState(() {
                      c.primaryKey = v;
                      if (!v) c.autoIncrement = false;
                    }),
                  ),
                  FilterChip(
                    label: const Text('Auto-incrément'),
                    selected: c.autoIncrement,
                    onSelected: c.primaryKey && c.type == SqlColumnType.integer
                        ? (v) => setState(() => c.autoIncrement = v)
                        : null,
                  ),
                  FilterChip(
                    label: const Text('Obligatoire'),
                    selected: c.notNull,
                    onSelected: (v) => setState(() => c.notNull = v),
                  ),
                  FilterChip(
                    label: const Text('Unique'),
                    selected: c.unique,
                    onSelected: c.primaryKey ? null : (v) => setState(() => c.unique = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: c.defaultValue,
                decoration: const InputDecoration(
                  labelText: 'Valeur par défaut (facultatif)',
                  hintText: 'Ex. 0, actif, CURRENT_TIMESTAMP',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (_existing.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        initialValue: c.refTable,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Clé étrangère vers…', isDense: true),
                        items: [
                          const DropdownMenuItem(value: null, child: Text('Aucune')),
                          for (final t in _existing.keys) DropdownMenuItem(value: t, child: Text(t)),
                        ],
                        onChanged: (t) => setState(() {
                          c.refTable = t;
                          final cols = t == null ? const <String>[] : _existing[t]!;
                          c.refColumn = cols.contains('id') ? 'id' : (cols.isEmpty ? null : cols.first);
                        }),
                      ),
                    ),
                    if (c.refTable != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('${c.refTable}-$i'),
                          initialValue: c.refColumn,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Colonne', isDense: true),
                          items: [for (final col in refColumns) DropdownMenuItem(value: col, child: Text(col))],
                          onChanged: (v) => setState(() => c.refColumn = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: c.onDelete,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Si supprimée', isDense: true),
                          items: const [
                            DropdownMenuItem(value: 'NO ACTION', child: Text('Bloquer (défaut)')),
                            DropdownMenuItem(value: 'CASCADE', child: Text('Supprimer aussi')),
                            DropdownMenuItem(value: 'SET NULL', child: Text('Mettre à NULL')),
                            DropdownMenuItem(value: 'RESTRICT', child: Text('Interdire immédiatement')),
                          ],
                          onChanged: (v) => setState(() => c.onDelete = v!),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
