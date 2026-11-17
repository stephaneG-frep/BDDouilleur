import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../domain/firebase/firestore_rules.dart';
import '../../domain/models/journal_entry.dart';
import '../../domain/models/project.dart';
import '../../state/app_state.dart';

Color ruleSeverityColor(RuleSeverity s) => switch (s) {
      RuleSeverity.critical => BddColors.rose,
      RuleSeverity.warning => BddColors.orange,
      RuleSeverity.info => BddColors.turquoise,
    };

class RuleFindingTile extends StatelessWidget {
  const RuleFindingTile(this.f, {super.key});
  final RuleFinding f;

  @override
  Widget build(BuildContext context) {
    final c = ruleSeverityColor(f.severity);
    return ListTile(
      dense: true,
      leading: Icon(f.severity == RuleSeverity.info ? Icons.info_rounded : Icons.warning_amber_rounded, color: c),
      title: Text('${f.title}${f.line == null ? '' : ' — ligne ${f.line}'}'),
      subtitle: Text(f.explanation),
    );
  }
}

/// Onglet Règles : règles actives et analyse.
class RulesView extends StatefulWidget {
  const RulesView({super.key, required this.connection});
  final DbConnection connection;

  @override
  State<RulesView> createState() => _RulesViewState();
}

class _RulesViewState extends State<RulesView> {
  late Future<String?> _future = _load();

  DbConnection get _fresh => context.read<AppState>().connections.byId(widget.connection.id!) ?? widget.connection;

  Future<String?> _load() => context.read<AppState>().rulesFor(_fresh).currentRules();

  @override
  Widget build(BuildContext context) {
    final emulator = widget.connection.firebase.isEmulator;
    return FutureBuilder<String?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snap.hasError) return EmptyState(message: 'Lecture des règles impossible :\n${snap.error}');
        final rules = snap.data;
        final findings = rules == null ? const <RuleFinding>[] : RulesAnalyzer.analyze(rules);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Générateur et tests de règles'),
              onPressed: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => RulesEditorScreen(connection: _fresh, initialSource: rules)));
                if (mounted) setState(() { _future = _load(); });
              },
            ),
            const SizedBox(height: 16),
            Text('Règles actives', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (rules == null)
              MascotTip(
                message: emulator
                    ? 'L\'émulateur ne permet pas de relire ses règles. Celles chargées au démarrage (firebase.json) '
                        's\'appliquent tant que vous n\'en déployez pas depuis BDDouilleur.'
                    : 'Aucune règle publiée pour cette base.',
              )
            else ...[
              if (findings.isEmpty)
                const ListTile(
                    leading: Icon(Icons.verified_rounded, color: BddColors.vert),
                    title: Text('Aucune ouverture dangereuse détectée'))
              else
                Card(child: Column(children: [for (final f in findings) RuleFindingTile(f)])),
              const SizedBox(height: 12),
              CodeBlock(rules),
            ],
          ],
        );
      },
    );
  }
}

/// Générateur de règles + édition + tests + déploiement.
class RulesEditorScreen extends StatefulWidget {
  const RulesEditorScreen({super.key, required this.connection, this.initialSource});
  final DbConnection connection;
  final String? initialSource;

  @override
  State<RulesEditorScreen> createState() => _RulesEditorScreenState();
}

class _RulesEditorScreenState extends State<RulesEditorScreen> {
  final List<CollectionRule> _design = [
    const CollectionRule('users', CollectionAccess.ownerDocument),
  ];
  bool _verifiedEmail = false;
  bool _manual = false;
  final _source = TextEditingController();
  List<RuleTestResult>? _results;
  String? _testError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _regenerate();
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  void _regenerate() {
    if (_manual) return;
    try {
      _source.text = RulesGenerator.generate(_design, requireVerifiedEmail: _verifiedEmail);
    } on FormatException catch (e) {
      _source.text = '// ${e.message}';
    }
    _results = null;
  }

  @override
  Widget build(BuildContext context) {
    final findings = RulesAnalyzer.analyze(_source.text);
    final critical = RulesAnalyzer.hasCritical(findings);
    final emulator = widget.connection.firebase.isEmulator;
    final text = Theme.of(context).textTheme;
    final passed = _results?.where((r) => r.passed).length ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Règles de sécurité')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const MascotTip(
            message: 'Principe : tout est refusé, sauf ce que vous autorisez collection par collection. '
                'Testez avant de déployer : je vérifie que vos utilisateurs accèdent à leurs données et pas à celles des autres.',
          ),
          const SizedBox(height: 16),
          Text('1. Collections et accès', style: text.titleMedium),
          const SizedBox(height: 8),
          for (final (i, r) in _design.indexed)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(r.collection, style: AppTheme.mono),
                subtitle: Text('${r.access.label}${r.access == CollectionAccess.ownerField ? ' (champ ${r.ownerField})' : ''}\n${r.access.help}'),
                isThreeLine: true,
                trailing: IconButton(
                  tooltip: 'Retirer',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _manual
                      ? null
                      : () => setState(() {
                            _design.removeAt(i);
                            _regenerate();
                          }),
                ),
                onTap: _manual ? null : () => _editRule(context, i),
              ),
            ),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.add_rounded),
              label: const Text('Ajouter une collection'),
              onPressed: _manual ? null : () => _editRule(context, null),
            ),
            FilterChip(
              label: const Text('Exiger un e-mail vérifié'),
              selected: _verifiedEmail,
              onSelected: _manual
                  ? null
                  : (v) => setState(() {
                        _verifiedEmail = v;
                        _regenerate();
                      }),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text('2. Règles', style: text.titleMedium)),
            if (widget.initialSource != null)
              TextButton(
                onPressed: () => setState(() {
                  _manual = true;
                  _source.text = widget.initialSource!;
                  _results = null;
                }),
                child: const Text('Partir des règles actives'),
              ),
            Switch(
              value: _manual,
              onChanged: (v) => setState(() {
                _manual = v;
                _regenerate();
              }),
            ),
            const Text('Édition manuelle'),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _source,
            readOnly: !_manual,
            maxLines: null,
            minLines: 10,
            style: AppTheme.mono,
            onChanged: (_) => setState(() => _results = null),
            decoration: const InputDecoration(alignLabelWithHint: true),
          ),
          const SizedBox(height: 8),
          if (findings.isNotEmpty) Card(child: Column(children: [for (final f in findings) RuleFindingTile(f)])),
          const SizedBox(height: 16),
          Text('3. Tests', style: text.titleMedium),
          const SizedBox(height: 4),
          Text(context.read<AppState>().rulesFor(widget.connection).testMethod, style: text.bodySmall),
          if (_manual)
            Text('Les tests sont ceux de la conception (étape 1) : adaptez-la à vos règles manuelles.', style: text.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.fact_check_rounded),
              label: Text('Lancer ${RulesGenerator.testsFor(_design).length} tests'),
              onPressed: _busy ? null : () => _test(context),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.cloud_upload_rounded),
              label: const Text('Déployer'),
              onPressed: _busy || (critical && !emulator) ? null : () => _deploy(context, critical),
            ),
          ]),
          if (critical && !emulator)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Déploiement bloqué : ces règles ouvrent l\'accès à tous. BDDouilleur ne publie jamais de telles '
                  'règles sur un vrai projet.', style: TextStyle(color: BddColors.rose)),
            ),
          if (_testError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_testError!, style: const TextStyle(color: BddColors.rose))),
          if (_results != null) ...[
            const SizedBox(height: 12),
            StatusChip(
              label: '$passed / ${_results!.length} tests conformes',
              color: passed == _results!.length ? BddColors.vert : BddColors.rose,
              icon: passed == _results!.length ? Icons.check_rounded : Icons.close_rounded,
            ),
            const SizedBox(height: 8),
            for (final r in _results!)
              ListTile(
                dense: true,
                leading: Icon(r.passed ? Icons.check_circle_rounded : Icons.cancel_rounded,
                    color: r.passed ? BddColors.vert : BddColors.rose),
                title: Text(r.testCase.label),
                subtitle: Text('Attendu : ${r.testCase.expectAllow ? 'autorisé' : 'refusé'} • '
                    'Observé : ${r.allowed == null ? 'erreur' : r.allowed! ? 'autorisé' : 'refusé'}'
                    '${r.error == null ? '' : '\n${r.error}'}'),
              ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _editRule(BuildContext context, int? index) async {
    final rule = await showDialog<CollectionRule>(
        context: context, builder: (_) => _CollectionRuleDialog(initial: index == null ? null : _design[index]));
    if (rule == null) return;
    setState(() {
      if (index == null) {
        _design.add(rule);
      } else {
        _design[index] = rule;
      }
      _regenerate();
    });
  }

  Future<void> _test(BuildContext context) async {
    final state = context.read<AppState>();
    final service = state.rulesFor(state.connections.byId(widget.connection.id!) ?? widget.connection);
    final cases = RulesGenerator.testsFor(_design);
    setState(() {
      _busy = true;
      _testError = null;
    });
    try {
      final results = await service.runTests(_source.text, cases);
      final ok = results.where((r) => r.passed).length;
      state.journal.log(
        projectId: widget.connection.projectId,
        connectionId: widget.connection.id,
        action: JournalAction.rulesTested,
        summary: 'Règles testées : $ok / ${results.length} conformes',
        success: ok == results.length,
      );
      setState(() => _results = results);
    } catch (e) {
      state.journal.log(
          projectId: widget.connection.projectId,
          connectionId: widget.connection.id,
          action: JournalAction.rulesTested,
          summary: 'Test des règles',
          success: false,
          error: '$e');
      setState(() => _testError = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deploy(BuildContext context, bool critical) async {
    final emulator = widget.connection.firebase.isEmulator;
    final allPassed = _results != null && _results!.every((r) => r.passed);
    final ok = await confirm(
      context,
      title: emulator ? 'Déployer sur l\'émulateur ?' : 'Publier ces règles en production ?',
      message: [
        if (!emulator) 'Les règles s\'appliqueront immédiatement à toutes les applications du projet « ${widget.connection.location} ».',
        if (_results == null) 'Vous n\'avez pas lancé les tests.' else if (!allPassed) 'Attention : des tests échouent.',
        if (critical) 'Ces règles contiennent une ouverture critique (accepté uniquement sur l\'émulateur).',
      ].join('\n\n'),
      action: emulator ? 'Déployer' : 'Publier',
      danger: !allPassed || critical,
    );
    if (!ok || !context.mounted) return;
    final state = context.read<AppState>();
    final conn = state.connections.byId(widget.connection.id!) ?? widget.connection;
    final api = state.apiFor(conn.firebase);
    final deployer = state.rulesFor(conn, api: api);
    setState(() => _busy = true);
    try {
      await state.runFirebase(
        api: api,
        connection: widget.connection,
        action: JournalAction.rulesDeployed,
        summary: 'Règles déployées${emulator ? ' sur l\'émulateur' : ' en production'}'
            '${_results == null ? ' (sans test)' : ' (${_results!.where((r) => r.passed).length}/${_results!.length} tests conformes)'}',
        run: () => deployer.deploy(_source.text),
      );
      if (context.mounted) {
        showSuccess(context, 'Règles déployées.');
        Navigator.pop(context);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _CollectionRuleDialog extends StatefulWidget {
  const _CollectionRuleDialog({this.initial});
  final CollectionRule? initial;

  @override
  State<_CollectionRuleDialog> createState() => _CollectionRuleDialogState();
}

class _CollectionRuleDialogState extends State<_CollectionRuleDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.collection ?? '');
  late final _owner = TextEditingController(text: widget.initial?.ownerField ?? 'ownerId');
  late CollectionAccess _access = widget.initial?.access ?? CollectionAccess.ownerField;

  @override
  void dispose() {
    _name.dispose();
    _owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Collection'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nom de la collection'),
                validator: (v) => CollectionRule.validateName(v ?? ''),
              ),
              const SizedBox(height: 12),
              RadioGroup<CollectionAccess>(
                groupValue: _access,
                onChanged: (v) => setState(() => _access = v!),
                child: Column(children: [
                  for (final a in CollectionAccess.values)
                    RadioListTile<CollectionAccess>(
                      value: a,
                      title: Text(a.label),
                      subtitle: Text(a.help),
                      dense: true,
                    ),
                ]),
              ),
              if (_access == CollectionAccess.ownerField)
                TextFormField(
                  controller: _owner,
                  decoration: const InputDecoration(labelText: 'Champ contenant l\'uid du propriétaire'),
                  validator: (v) =>
                      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch((v ?? '').trim()) ? null : 'Nom de champ simple attendu.',
                ),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, CollectionRule(_name.text.trim(), _access, ownerField: _owner.text.trim()));
          },
          child: const Text('Valider'),
        ),
      ],
    );
  }
}
