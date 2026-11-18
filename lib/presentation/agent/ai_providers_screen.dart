import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../domain/ai/ai_models.dart';
import '../../state/app_state.dart';

/// Réglages des fournisseurs d'IA : clé (trousseau), adresse, test réel,
/// choix du modèle.
class AiProvidersScreen extends StatelessWidget {
  const AiProvidersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fournisseurs d\'IA')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const MascotTip(
            message: 'Vous pouvez configurer plusieurs fournisseurs : chaque conversation en utilise un seul, '
                'affiché en haut de la conversation et au-dessus de chaque réponse. Choisissez un ou plusieurs fournisseurs. Les clés API sont rangées dans le trousseau du système : '
                'jamais dans la base, le journal ou l\'application distribuée. Ollama fonctionne en local, sans clé ni coût.',
          ),
          const SizedBox(height: 12),
          for (final k in AiProviderKind.values) _ProviderCard(kind: k),
        ],
      ),
    );
  }
}

class _ProviderCard extends StatefulWidget {
  const _ProviderCard({required this.kind});
  final AiProviderKind kind;

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  final _key = TextEditingController();
  late final _url = TextEditingController();
  bool _hasKey = false;
  bool _obscure = true;
  bool _busy = false;
  List<AiModelInfo>? _models;
  String? _error;
  String? _model;

  AiProviderKind get k => widget.kind;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>().ai;
    _url.text = s.baseUrl(k);
    _model = s.model(k);
    s.hasKey(k).then((v) {
      if (mounted) setState(() => _hasKey = v && k.needsKey);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = 'Trousseau indisponible : $e');
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isDefault = state.ai.defaultProvider == k;
    final configured = !k.needsKey || _hasKey;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        leading: Icon(configured ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
            color: configured ? BddColors.vert : null),
        title: Text(k.label),
        subtitle: Text([
          configured ? 'Configuré' : 'Non configuré',
          if (isDefault) 'proposé par défaut pour les nouvelles conversations',
          if (_model != null) 'Modèle : $_model',
        ].join(' • ')),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (k.needsKey) ...[
            TextField(
              controller: _key,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: _hasKey ? 'Nouvelle clé API (une clé est enregistrée)' : 'Clé API',
                helperText: 'Obtenir une clé : ${k.keyHelpUrl}',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _url,
            decoration: InputDecoration(
              labelText: 'Adresse de l\'API',
              helperText: k == AiProviderKind.ollama
                  ? 'Ollama local : http://127.0.0.1:11434 (sur téléphone : IP du PC, ollama lancé avec OLLAMA_HOST=0.0.0.0)'
                  : 'Laissez la valeur par défaut sauf passerelle d\'entreprise.',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering_rounded),
              label: const Text('Enregistrer et tester'),
              onPressed: _busy ? null : _saveAndTest,
            ),
            if (_hasKey)
              TextButton(
                onPressed: () async {
                  final ok = await confirm(context,
                      title: 'Effacer la clé ?', message: 'La clé ${k.label} sera retirée du trousseau.', danger: true, action: 'Effacer');
                  if (!ok || !context.mounted) return;
                  await context.read<AppState>().ai.setApiKey(k, null);
                  setState(() => _hasKey = false);
                },
                child: const Text('Effacer la clé'),
              ),
            if (configured && !isDefault)
              OutlinedButton(
                onPressed: () {
                  state.ai.defaultProvider = k;
                  state.refresh();
                },
                child: const Text('Définir par défaut'),
              ),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: BddColors.rose))),
          if (_models != null) ...[
            const SizedBox(height: 12),
            Text('Connexion réussie : ${_models!.length} modèle(s) disponible(s).', style: const TextStyle(color: BddColors.vert)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _models!.any((m) => m.id == _model) ? _model : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Modèle utilisé'),
              items: [for (final m in _models!) DropdownMenuItem(value: m.id, child: Text(m.label, overflow: TextOverflow.ellipsis))],
              onChanged: (v) {
                state.ai.setModel(k, v);
                setState(() => _model = v);
                state.refresh();
              },
            ),
            if (k == AiProviderKind.ollama)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Choisissez un modèle qui sait appeler des outils (ex. qwen3, llama3.1, mistral-nemo).'),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _saveAndTest() async {
    final state = context.read<AppState>();
    setState(() {
      _busy = true;
      _error = null;
      _models = null;
    });
    try {
      if (_key.text.trim().isNotEmpty) {
        await state.ai.setApiKey(k, _key.text.trim());
        _key.clear();
        _hasKey = true;
      }
      state.ai.setBaseUrl(k, _url.text);
      if (k.needsKey && !_hasKey) throw StateError('Saisissez d\'abord une clé API.');
      final models = await (await state.providerFor(k)).testConnection();
      final current = state.ai.model(k);
      if (current == null || !models.any((m) => m.id == current)) {
        final pick = models.any((m) => m.id == k.suggestedModel) ? k.suggestedModel : models.first.id;
        state.ai.setModel(k, pick);
        _model = pick;
      }
      state.ai.defaultProvider ??= k;
      setState(() => _models = models);
      state.refresh();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
