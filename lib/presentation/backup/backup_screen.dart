import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/backup/sqlite_backup_service.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../state/app_state.dart';

/// Le Coffre-fort : sauvegardes et restauration d'une base SQLite.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.connection});
  final DbConnection connection;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late final SqliteBackupService _service = context.read<AppState>().backupsFor(widget.connection);
  late List<BackupFile> _backups = _service.list();
  bool _busy = false;

  void _refresh() => setState(() => _backups = _service.list());

  Future<void> _create() async {
    setState(() => _busy = true);
    final state = context.read<AppState>();
    try {
      final (b, _) = await state.runLogged<(BackupFile, String)>(
        connection: widget.connection,
        action: JournalAction.backupCreated,
        summary: 'Sauvegarde manuelle de « ${widget.connection.name} »',
        run: (c) => _service.create(c),
        sqlOf: (r) => r.$2,
      );
      if (mounted) showSuccess(context, 'Sauvegarde créée et vérifiée : ${b.name}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  void _verify(BackupFile b) {
    final problems = SqliteBackupService.verify(b.path);
    if (problems.isEmpty) {
      showSuccess(context, '« ${b.name} » est intègre (PRAGMA integrity_check = ok).');
    } else {
      showError(context, '« ${b.name} » est endommagée : ${problems.join(', ')}');
    }
  }

  Future<void> _restore(BackupFile b) async {
    final ok = await confirm(
      context,
      title: 'Restaurer cette sauvegarde ?',
      message: 'La base « ${widget.connection.name} » sera remplacée par l\'état du ${formatDate(b.modified)}.\n\n'
          'Avant de restaurer, je vérifie la sauvegarde et je crée un point de restauration de l\'état actuel.',
      action: 'Restaurer',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final state = context.read<AppState>();
    try {
      final safety = await state.runLogged<BackupFile>(
        connection: widget.connection,
        action: JournalAction.backupRestored,
        summary: 'Restauration de « ${b.name} »',
        run: (c) => _service.restore(c, b),
        sqlOf: (s) => '-- Point de restauration préalable : ${s.name}\n-- Fichier restauré : ${b.name}',
      );
      if (mounted) showSuccess(context, 'Base restaurée. Point de restauration de l\'état précédent : ${safety.name}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Coffre-fort — ${widget.connection.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const MascotTip(
            title: 'Le Coffre-fort',
            message: 'Une sauvegarde SQLite est une copie complète et cohérente du fichier (VACUUM INTO). '
                'Chaque sauvegarde est vérifiée juste après sa création. Les sauvegardes planifiées ne sont pas '
                'encore disponibles dans cette version.',
          ),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: _busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_rounded),
              label: const Text('Sauvegarder maintenant'),
            ),
            Text('${_backups.length} sauvegarde(s)'),
          ]),
          const SizedBox(height: 8),
          SelectableText('Dossier : ${_service.backupsRoot}', style: AppTheme.mono.copyWith(fontSize: 12)),
          const SizedBox(height: 16),
          for (final b in _backups)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  b.name.contains('avant_') ? Icons.restore_rounded : Icons.inventory_2_rounded,
                  color: b.name.contains('avant_') ? BddColors.orange : BddColors.vert,
                ),
                title: Text(b.name, style: AppTheme.mono),
                subtitle: Text('${formatDate(b.modified)} • ${formatBytes(b.size)}'
                    '${b.name.contains('avant_') ? ' • point de restauration automatique' : ''}'),
                trailing: Wrap(children: [
                  IconButton(tooltip: 'Vérifier l\'intégrité', onPressed: () => _verify(b), icon: const Icon(Icons.verified_outlined)),
                  IconButton(
                      tooltip: 'Restaurer',
                      onPressed: _busy ? null : () => _restore(b),
                      icon: const Icon(Icons.settings_backup_restore_rounded)),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}
