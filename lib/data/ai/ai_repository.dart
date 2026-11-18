import 'dart:convert';

import '../../domain/ai/ai_models.dart';
import '../../domain/autopilot/autonomy.dart';
import '../persistence/app_database.dart';

class AiConversation {
  const AiConversation({
    required this.id,
    required this.projectId,
    required this.title,
    required this.provider,
    required this.model,
    this.folder,
    this.connectionId,
    required this.updatedAt,
    this.mode = AutonomyMode.manual,
  });

  final int id;
  final int projectId;
  final String title;
  final AiProviderKind provider;
  final String model;

  /// Dossier de projet que l'agent est autorisé à lire.
  final String? folder;

  /// Base de données sur laquelle l'agent travaille par défaut.
  final int? connectionId;
  final DateTime updatedAt;
  final AutonomyMode mode;

  factory AiConversation.fromRow(Map<String, Object?> r) => AiConversation(
        id: r['id'] as int,
        projectId: r['project_id'] as int,
        title: r['title'] as String,
        provider: AiProviderKind.fromName(r['provider'] as String) ?? AiProviderKind.anthropic,
        model: r['model'] as String,
        folder: r['folder'] as String?,
        connectionId: r['connection_id'] as int?,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
        mode: AutonomyMode.fromName(r['mode'] as String?),
      );
}

/// Historique des conversations par projet (base interne). Les messages
/// contiennent le texte échangé et les résultats réels des outils, jamais de clé.
class AiRepository {
  AiRepository(this._app);
  final AppDatabase _app;

  List<AiConversation> forProject(int projectId) => _app.db
      .select('SELECT * FROM ai_conversations WHERE project_id = ? ORDER BY updated_at DESC, id DESC', [projectId])
      .map(AiConversation.fromRow)
      .toList();

  AiConversation? byId(int id) {
    final r = _app.db.select('SELECT * FROM ai_conversations WHERE id = ?', [id]);
    return r.isEmpty ? null : AiConversation.fromRow(r.first);
  }

  AiConversation create({
    required int projectId,
    required String title,
    required AiProviderKind provider,
    required String model,
    String? folder,
    int? connectionId,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _app.db.execute(
      'INSERT INTO ai_conversations(project_id, title, provider, model, folder, connection_id, created_at, updated_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?)',
      [projectId, title.trim().isEmpty ? 'Nouvelle conversation' : title.trim(), provider.name, model, folder, connectionId, now, now],
    );
    return byId(_app.db.lastInsertRowId)!;
  }

  void rename(int id, String title) =>
      _app.db.execute('UPDATE ai_conversations SET title = ? WHERE id = ?', [title.trim(), id]);

  void setModel(int id, AiProviderKind provider, String model) => _app.db.execute(
      'UPDATE ai_conversations SET provider = ?, model = ?, updated_at = ? WHERE id = ?',
      [provider.name, model, DateTime.now().millisecondsSinceEpoch, id]);

  void delete(int id) => _app.db.execute('DELETE FROM ai_conversations WHERE id = ?', [id]);

  void setMode(int id, AutonomyMode mode) => _app.db.execute('UPDATE ai_conversations SET mode = ? WHERE id = ?', [mode.name, id]);

  List<AiMessage> messages(int conversationId) => _app.db
      .select('SELECT content FROM ai_messages WHERE conversation_id = ? ORDER BY id', [conversationId])
      .map((r) => AiMessage.fromJson((jsonDecode(r['content'] as String) as Map).cast()))
      .toList();

  void addMessage(int conversationId, AiMessage m, {int? inputTokens, int? outputTokens}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _app.db.execute(
      'INSERT INTO ai_messages(conversation_id, role, content, input_tokens, output_tokens, created_at) VALUES(?, ?, ?, ?, ?, ?)',
      [conversationId, m.role.name, jsonEncode(m.toJson()), inputTokens, outputTokens, now],
    );
    _app.db.execute('UPDATE ai_conversations SET updated_at = ? WHERE id = ?', [now, conversationId]);
  }

  /// Jetons consommés par la conversation (entrée, sortie).
  (int, int) usage(int conversationId) {
    final r = _app.db.select(
        'SELECT COALESCE(SUM(input_tokens), 0) AS i, COALESCE(SUM(output_tokens), 0) AS o FROM ai_messages WHERE conversation_id = ?',
        [conversationId]).first;
    return (r['i'] as int, r['o'] as int);
  }
}
