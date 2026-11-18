import '../../domain/ai/ai_models.dart';
import '../persistence/app_database.dart';
import '../secrets/secret_store.dart';
import 'ai_providers.dart';

/// Réglages des fournisseurs : clés dans le trousseau, adresse et modèle
/// (non sensibles) dans la base interne.
class AiSettings {
  AiSettings(this._app, this._secrets);
  final AppDatabase _app;
  final SecretStore _secrets;

  static String _keyName(AiProviderKind k) => 'ai.${k.name}.api_key';

  Future<String?> apiKey(AiProviderKind k) => _secrets.read(_keyName(k));

  Future<bool> hasKey(AiProviderKind k) async => !k.needsKey || (await apiKey(k))?.isNotEmpty == true;

  Future<void> setApiKey(AiProviderKind k, String? key) async {
    if (key == null || key.trim().isEmpty) {
      await _secrets.delete(_keyName(k));
    } else {
      await _secrets.write(_keyName(k), key.trim());
    }
  }

  String baseUrl(AiProviderKind k) => _app.getSetting('ai.${k.name}.base_url') ?? k.defaultBaseUrl;
  void setBaseUrl(AiProviderKind k, String? url) =>
      _app.setSetting('ai.${k.name}.base_url', url == null || url.trim().isEmpty || url.trim() == k.defaultBaseUrl ? null : url.trim());

  String? model(AiProviderKind k) => _app.getSetting('ai.${k.name}.model') ?? (k.suggestedModel.isEmpty ? null : k.suggestedModel);
  void setModel(AiProviderKind k, String? model) => _app.setSetting('ai.${k.name}.model', model);

  AiProviderKind? get defaultProvider => AiProviderKind.fromName(_app.getSetting('ai.provider'));
  set defaultProvider(AiProviderKind? k) => _app.setSetting('ai.provider', k?.name);

  Future<AiProviderConfig> config(AiProviderKind k) async =>
      AiProviderConfig(kind: k, apiKey: await apiKey(k), baseUrl: baseUrl(k));
}
