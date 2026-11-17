import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/firebase/firestore_client.dart';
import '../../data/firebase/firestore_value_codec.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../state/app_state.dart';

/// Racine des données : collections de premier niveau.
class FirestoreDataView extends StatefulWidget {
  const FirestoreDataView({super.key, required this.connection});
  final DbConnection connection;

  @override
  State<FirestoreDataView> createState() => _FirestoreDataViewState();
}

class _FirestoreDataViewState extends State<FirestoreDataView> {
  late Future<List<String>> _future = _load();

  Future<List<String>> _load() => context.read<AppState>().firestoreFor(widget.connection).listCollectionIds();

  void _reload() => setState(() { _future = _load(); });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'newdoc',
        icon: const Icon(Icons.note_add_rounded),
        label: const Text('Nouveau document'),
        onPressed: () async {
          final doc = await showDialog<FirestoreDocument>(
              context: context, builder: (_) => DocumentEditorDialog(connection: widget.connection));
          if (doc != null && context.mounted) {
            _reload();
            await Navigator.push(context,
                MaterialPageRoute(builder: (_) => DocumentScreen(connection: widget.connection, path: doc.path)));
          }
        },
      ),
      body: FutureBuilder<List<String>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return EmptyState(
                message: 'Lecture impossible :\n${snap.error}',
                action: FilledButton(onPressed: _reload, child: const Text('Réessayer')));
          }
          final cols = snap.data!;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                MascotTip(
                  message: widget.connection.firebase.isEmulator
                      ? 'Données de l\'émulateur : vous pouvez expérimenter sans risque.'
                      : 'Accès administrateur (IAM) : les règles de sécurité ne s\'appliquent pas à BDDouilleur. '
                          'Chaque écriture vous est confirmée et journalisée.',
                ),
                const SizedBox(height: 12),
                if (cols.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Aucune collection. Dans Firestore, une collection apparaît avec son premier '
                        'document : utilisez « Nouveau document ».'),
                  ),
                for (final c in cols)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.folder_rounded, color: BddColors.orange),
                      title: Text(c),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        await Navigator.push(context,
                            MaterialPageRoute(builder: (_) => CollectionScreen(connection: widget.connection, path: c)));
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Documents d'une collection, paginés.
class CollectionScreen extends StatefulWidget {
  const CollectionScreen({super.key, required this.connection, required this.path});
  final DbConnection connection;
  final String path;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final List<FirestoreDocument> _docs = [];
  String? _next;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    setState(() {
      _loading = true;
      if (reset) {
        _docs.clear();
        _next = null;
        _error = null;
      }
    });
    try {
      final page = await context
          .read<AppState>()
          .firestoreFor(widget.connection)
          .listDocuments(widget.path, pageToken: reset ? null : _next);
      if (!mounted) return;
      setState(() {
        _docs.addAll(page.documents);
        _next = page.nextPageToken;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.path),
        actions: [IconButton(tooltip: 'Actualiser', icon: const Icon(Icons.refresh_rounded), onPressed: () => _load(reset: true))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.note_add_rounded),
        label: const Text('Ajouter'),
        onPressed: () async {
          final doc = await showDialog<FirestoreDocument>(
              context: context,
              builder: (_) => DocumentEditorDialog(connection: widget.connection, collectionPath: widget.path));
          if (doc != null) await _load(reset: true);
        },
      ),
      body: _error != null
          ? EmptyState(message: '$_error', action: FilledButton(onPressed: () => _load(reset: true), child: const Text('Réessayer')))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                if (_docs.isEmpty && !_loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Plus aucun document : la collection n\'existe plus que par ce chemin.'),
                  ),
                for (final d in _docs)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.description_rounded),
                      title: Text(d.id, style: AppTheme.mono),
                      subtitle: Text(
                        d.data.entries.take(3).map((e) => '${e.key}: ${_short(e.value)}').join(' • '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        await Navigator.push(context,
                            MaterialPageRoute(builder: (_) => DocumentScreen(connection: widget.connection, path: d.path)));
                        await _load(reset: true);
                      },
                    ),
                  ),
                if (_loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
                if (_next != null && !_loading)
                  Center(child: OutlinedButton(onPressed: _load, child: const Text('Charger la suite'))),
              ],
            ),
    );
  }

  static String _short(Object? v) {
    final s = v is String ? v : FirestoreValueCodec.pretty(v).replaceAll('\n', ' ');
    return s.length > 40 ? '${s.substring(0, 40)}…' : s;
  }
}

/// Un document : champs typés, sous-collections, modification, suppression.
class DocumentScreen extends StatefulWidget {
  const DocumentScreen({super.key, required this.connection, required this.path});
  final DbConnection connection;
  final String path;

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  late Future<(FirestoreDocument?, List<String>)> _future = _load();

  Future<(FirestoreDocument?, List<String>)> _load() async {
    final client = context.read<AppState>().firestoreFor(widget.connection);
    final doc = await client.getDocument(widget.path);
    final subs = await client.listCollectionIds(documentPath: widget.path);
    return (doc, subs);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.path.split('/').last)),
      body: FutureBuilder<(FirestoreDocument?, List<String>)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return EmptyState(message: '${snap.error}');
          final (doc, subs) = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SelectableText(widget.path, style: AppTheme.mono),
              const SizedBox(height: 8),
              if (doc == null)
                const MascotTip(
                    message: 'Ce document n\'existe pas (ou plus). Ses sous-collections éventuelles restent accessibles ci-dessous.')
              else ...[
                if (doc.updateTime != null)
                  Text('Modifié le ${formatDate(doc.updateTime!.toLocal())}',
                      style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Card(
                  child: Column(children: [
                    if (doc.data.isEmpty) const ListTile(title: Text('Document sans champ')),
                    for (final e in doc.data.entries)
                      ListTile(
                        dense: true,
                        title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: SelectableText(
                            e.value is String ? e.value as String : FirestoreValueCodec.pretty(e.value),
                            style: AppTheme.mono),
                        trailing: Text(FirestoreValueCodec.typeLabel(e.value),
                            style: TextStyle(color: Theme.of(context).colorScheme.secondary)),
                      ),
                  ]),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.edit_rounded),
                    label: const Text('Modifier'),
                    onPressed: () async {
                      final saved = await showDialog<FirestoreDocument>(
                          context: context,
                          builder: (_) => DocumentEditorDialog(connection: widget.connection, existing: doc));
                      if (saved != null) setState(() { _future = _load(); });
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_rounded),
                    label: const Text('Supprimer'),
                    style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                    onPressed: () => _delete(context, doc, subs),
                  ),
                ]),
              ],
              const SizedBox(height: 16),
              Text('Sous-collections', style: Theme.of(context).textTheme.titleMedium),
              if (subs.isEmpty) const Text('Aucune.'),
              for (final s in subs)
                ListTile(
                  leading: const Icon(Icons.folder_rounded, color: BddColors.orange),
                  title: Text(s),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => CollectionScreen(connection: widget.connection, path: '${widget.path}/$s'))),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _delete(BuildContext context, FirestoreDocument doc, List<String> subs) async {
    final emulator = widget.connection.firebase.isEmulator;
    final message = 'Le document « ${doc.path} » sera supprimé${emulator ? ' de l\'émulateur' : ' DÉFINITIVEMENT du projet Firebase'}.'
        '${subs.isEmpty ? '' : '\n\nAttention : ses sous-collections (${subs.join(', ')}) ne sont PAS supprimées par Firestore.'}';
    final ok = emulator
        ? await confirm(context, title: 'Supprimer le document ?', message: message, danger: true, action: 'Supprimer')
        : await confirmByTyping(context, title: 'Supprimer le document ?', message: message, expected: doc.id);
    if (!ok || !context.mounted) return;
    final state = context.read<AppState>();
    final client = state.firestoreFor(widget.connection);
    try {
      await state.runFirebase(
        api: client.api,
        connection: widget.connection,
        action: JournalAction.firestoreDocumentDeleted,
        summary: 'Document « ${doc.path} » supprimé',
        run: () => client.deleteDocument(doc.path),
      );
      if (context.mounted) {
        showSuccess(context, 'Document supprimé.');
        Navigator.pop(context);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

/// Création ou modification d'un document au format JSON typé.
class DocumentEditorDialog extends StatefulWidget {
  const DocumentEditorDialog({super.key, required this.connection, this.collectionPath, this.existing});
  final DbConnection connection;
  final String? collectionPath;
  final FirestoreDocument? existing;

  @override
  State<DocumentEditorDialog> createState() => _DocumentEditorDialogState();
}

class _DocumentEditorDialogState extends State<DocumentEditorDialog> {
  late final _collection = TextEditingController(text: widget.collectionPath ?? widget.existing?.collectionPath ?? '');
  late final _id = TextEditingController(text: widget.existing?.id ?? '');
  late final _json = TextEditingController(
      text: widget.existing == null ? '{\n  "nom": ""\n}' : FirestoreValueCodec.pretty(widget.existing!.data));
  String? _error;
  bool _busy = false;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    _collection.dispose();
    _id.dispose();
    _json.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_editing ? 'Modifier le document' : 'Nouveau document'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!_editing) ...[
              TextField(
                controller: _collection,
                enabled: widget.collectionPath == null,
                decoration: const InputDecoration(
                  labelText: 'Collection',
                  helperText: 'Ex. clients, ou clients/abc/commandes. Créée automatiquement avec ce premier document.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _id,
                decoration: const InputDecoration(
                    labelText: 'Identifiant du document (facultatif)', helperText: 'Vide : identifiant généré par Firestore.'),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _json,
              maxLines: 12,
              minLines: 6,
              style: AppTheme.mono,
              decoration: const InputDecoration(labelText: 'Contenu (JSON)', alignLabelWithHint: true),
            ),
            const SizedBox(height: 8),
            Text(
              'Types spéciaux : {"\$timestamp": "2026-11-17T10:00:00Z"}, {"\$ref": "col/id"}, '
              '{"\$geo": [48.85, 2.35]}, {"\$bytes": "base64"}, {"\$double": 3}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_editing) ...[
              const SizedBox(height: 8),
              Text('Le contenu remplace entièrement le document existant.', style: Theme.of(context).textTheme.bodySmall),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_editing ? 'Enregistrer' : 'Créer')),
      ],
    );
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final client = state.firestoreFor(widget.connection);
    final Map<String, Object?> data;
    try {
      data = FirestoreValueCodec.parseJsonObject(_json.text);
      // Valide l'encodage avant tout envoi.
      FirestoreValueCodec.encodeFields(data, databaseRoot: widget.connection.firebase.databaseRoot);
      if (!_editing) {
        final col = _collection.text.trim();
        if (col.isEmpty || col.split('/').where((s) => s.isNotEmpty).length.isEven) {
          throw const FormatException('Chemin de collection invalide (nombre impair de segments attendu).');
        }
        final id = _id.text.trim();
        if (id.isNotEmpty) {
          final err = FirestoreClient.validateSegment(id);
          if (err != null) throw FormatException(err);
        }
      }
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final FirestoreDocument doc;
      if (_editing) {
        doc = await state.runFirebase(
          api: client.api,
          connection: widget.connection,
          action: JournalAction.firestoreDocumentWritten,
          summary: 'Document « ${widget.existing!.path} » modifié',
          run: () => client.replaceDocument(widget.existing!.path, data),
        );
      } else {
        final col = _collection.text.trim();
        final id = _id.text.trim();
        doc = await state.runFirebase(
          api: client.api,
          connection: widget.connection,
          action: JournalAction.firestoreDocumentWritten,
          summary: 'Document créé dans « $col »${id.isEmpty ? '' : ' (id $id)'}',
          run: () => client.createDocument(col, data, documentId: id.isEmpty ? null : id),
        );
      }
      if (mounted) Navigator.pop(context, doc);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }
}
