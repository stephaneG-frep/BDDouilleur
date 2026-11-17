/// Génération, analyse et cas de test des règles de sécurité Firestore.
library;

/// Mode d'accès d'une collection dans le générateur.
enum CollectionAccess {
  ownerDocument(
    'Document personnel',
    'Le document {uid} et ses sous-collections ne sont accessibles qu\'à l\'utilisateur dont l\'identifiant est {uid} (ex. users/{uid}).',
  ),
  ownerField(
    'Propriétaire par champ',
    'Chaque document porte un champ propriétaire. Seul ce propriétaire peut le lire, le modifier ou le supprimer, et il ne peut pas céder le document.',
  ),
  signedInRead(
    'Lecture connectée',
    'Tout utilisateur connecté peut lire. Personne ne peut écrire depuis l\'application (gestion par l\'administrateur).',
  ),
  publicRead(
    'Lecture publique',
    'Tout le monde peut lire, même sans compte. Personne ne peut écrire depuis l\'application. À réserver aux contenus réellement publics.',
  ),
  locked(
    'Verrouillée',
    'Aucun accès depuis l\'application. Seuls les outils d\'administration (console, BDDouilleur) y accèdent.',
  );

  const CollectionAccess(this.label, this.help);
  final String label;
  final String help;
}

class CollectionRule {
  const CollectionRule(this.collection, this.access, {this.ownerField = 'ownerId'});
  final String collection;
  final CollectionAccess access;
  final String ownerField;

  static String? validateName(String v) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_-]{0,99}$').hasMatch(v.trim())) {
      return 'Lettres, chiffres, « _ » et « - », commence par une lettre.';
    }
    if (RegExp(r'^__.*__$').hasMatch(v.trim())) return 'Noms __…__ réservés.';
    return null;
  }
}

abstract final class RulesGenerator {
  /// Produit des règles « tout est refusé sauf ce qui est explicitement
  /// autorisé ». Jamais de règle ouverte à tous en écriture.
  static String generate(List<CollectionRule> rules, {bool requireVerifiedEmail = false, DateTime? now}) {
    final seen = <String>{};
    for (final r in rules) {
      final err = CollectionRule.validateName(r.collection);
      if (err != null) throw FormatException('Collection « ${r.collection} » : $err');
      if (!seen.add(r.collection)) throw FormatException('Collection « ${r.collection} » en double.');
      if (r.access == CollectionAccess.ownerField && !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(r.ownerField)) {
        throw FormatException('Champ propriétaire invalide : « ${r.ownerField} »');
      }
    }
    final date = (now ?? DateTime.now()).toIso8601String().substring(0, 10);
    final b = StringBuffer()
      ..writeln("rules_version = '2';")
      ..writeln('// Généré par BDDouilleur le $date.')
      ..writeln('// Principe : tout ce qui n\'est pas explicitement autorisé est refusé.')
      ..writeln('service cloud.firestore {')
      ..writeln('  match /databases/{database}/documents {')
      ..writeln('    function signedIn() {')
      ..writeln(requireVerifiedEmail
          ? '      return request.auth != null && request.auth.token.email_verified == true;'
          : '      return request.auth != null;')
      ..writeln('    }')
      ..writeln('    function isUser(uid) {')
      ..writeln('      return signedIn() && request.auth.uid == uid;')
      ..writeln('    }');
    for (final r in rules) {
      final c = r.collection;
      b.writeln();
      b.writeln('    // $c : ${r.access.label}');
      switch (r.access) {
        case CollectionAccess.ownerDocument:
          b
            ..writeln('    match /$c/{uid}/{document=**} {')
            ..writeln('      allow read, write: if isUser(uid);')
            ..writeln('    }');
        case CollectionAccess.ownerField:
          final f = r.ownerField;
          b
            ..writeln('    match /$c/{docId} {')
            ..writeln('      allow read, delete: if isUser(resource.data.$f);')
            ..writeln('      allow create: if isUser(request.resource.data.$f);')
            ..writeln('      allow update: if isUser(resource.data.$f)')
            ..writeln('                    && request.resource.data.$f == resource.data.$f;')
            ..writeln('    }');
        case CollectionAccess.signedInRead:
          b
            ..writeln('    match /$c/{docId} {')
            ..writeln('      allow read: if signedIn();')
            ..writeln('      allow write: if false;')
            ..writeln('    }');
        case CollectionAccess.publicRead:
          b
            ..writeln('    match /$c/{docId} {')
            ..writeln('      allow read: if true;')
            ..writeln('      allow write: if false;')
            ..writeln('    }');
        case CollectionAccess.locked:
          b
            ..writeln('    match /$c/{document=**} {')
            ..writeln('      allow read, write: if false;')
            ..writeln('    }');
      }
    }
    b
      ..writeln('  }')
      ..writeln('}');
    return b.toString();
  }

  /// Cas de test cohérents avec les règles générées (utilisateurs fictifs
  /// « alice » et « bob », plus un visiteur anonyme).
  static List<RuleTestCase> testsFor(List<CollectionRule> rules) {
    final out = <RuleTestCase>[];
    for (final r in rules) {
      final c = r.collection;
      switch (r.access) {
        case CollectionAccess.ownerDocument:
          final p = '$c/alice';
          final data = {'nom': 'Alice'};
          out
            ..add(RuleTestCase('alice lit son document $p', 'alice', RuleMethod.get, p, true, existing: data))
            ..add(RuleTestCase('alice crée son document $p', 'alice', RuleMethod.create, p, true, request: data))
            ..add(RuleTestCase('bob lit le document d\'alice', 'bob', RuleMethod.get, p, false, existing: data))
            ..add(RuleTestCase('bob modifie le document d\'alice', 'bob', RuleMethod.update, p, false,
                existing: data, request: {'nom': 'Pirate'}))
            ..add(RuleTestCase('anonyme lit $p', null, RuleMethod.get, p, false, existing: data));
        case CollectionAccess.ownerField:
          final f = r.ownerField;
          final p = '$c/bdd_test_doc';
          final mine = {f: 'alice', 'titre': 'Test'};
          out
            ..add(RuleTestCase('alice lit son document', 'alice', RuleMethod.get, p, true, existing: mine))
            ..add(RuleTestCase('bob lit le document d\'alice', 'bob', RuleMethod.get, p, false, existing: mine))
            ..add(RuleTestCase('anonyme lit un document', null, RuleMethod.get, p, false, existing: mine))
            ..add(RuleTestCase('alice crée un document à son nom', 'alice', RuleMethod.create, p, true, request: mine))
            ..add(RuleTestCase('alice crée un document au nom de bob', 'alice', RuleMethod.create, p, false,
                request: {f: 'bob', 'titre': 'Usurpation'}))
            ..add(RuleTestCase('alice cède son document à bob', 'alice', RuleMethod.update, p, false,
                existing: mine, request: {f: 'bob', 'titre': 'Test'}))
            ..add(RuleTestCase('bob supprime le document d\'alice', 'bob', RuleMethod.delete, p, false, existing: mine));
        case CollectionAccess.signedInRead:
          final p = '$c/bdd_test_doc';
          final data = {'titre': 'Test'};
          out
            ..add(RuleTestCase('alice (connectée) lit $c', 'alice', RuleMethod.get, p, true, existing: data))
            ..add(RuleTestCase('anonyme lit $c', null, RuleMethod.get, p, false, existing: data))
            ..add(RuleTestCase('alice écrit dans $c', 'alice', RuleMethod.create, p, false, request: data));
        case CollectionAccess.publicRead:
          final p = '$c/bdd_test_doc';
          final data = {'titre': 'Test'};
          out
            ..add(RuleTestCase('anonyme lit $c', null, RuleMethod.get, p, true, existing: data))
            ..add(RuleTestCase('alice écrit dans $c', 'alice', RuleMethod.create, p, false, request: data))
            ..add(RuleTestCase('anonyme écrit dans $c', null, RuleMethod.create, p, false, request: data));
        case CollectionAccess.locked:
          final p = '$c/bdd_test_doc';
          final data = {'titre': 'Test'};
          out
            ..add(RuleTestCase('alice lit $c', 'alice', RuleMethod.get, p, false, existing: data))
            ..add(RuleTestCase('alice écrit dans $c', 'alice', RuleMethod.create, p, false, request: data));
      }
    }
    const other = 'bdd_collection_non_declaree/doc';
    out
      ..add(RuleTestCase('alice lit une collection non déclarée', 'alice', RuleMethod.get, other, false,
          existing: const {'x': 1}))
      ..add(RuleTestCase('alice écrit dans une collection non déclarée', 'alice', RuleMethod.create, other, false,
          request: const {'x': 1}));
    return out;
  }
}

enum RuleMethod { get, create, update, delete }

class RuleTestCase {
  const RuleTestCase(this.label, this.uid, this.method, this.path, this.expectAllow, {this.existing, this.request});

  final String label;

  /// Identifiant de l'utilisateur, `null` pour un visiteur anonyme.
  final String? uid;
  final RuleMethod method;

  /// Chemin du document, relatif à la racine des documents.
  final String path;
  final bool expectAllow;

  /// Document déjà présent avant la requête (resource.data).
  final Map<String, Object?>? existing;

  /// Contenu envoyé (request.resource.data), pour create et update.
  final Map<String, Object?>? request;
}

class RuleTestResult {
  const RuleTestResult(this.testCase, {required this.allowed, this.error, this.details = const []});
  final RuleTestCase testCase;

  /// Résultat observé : `null` si le test n'a pas pu s'exécuter.
  final bool? allowed;
  final String? error;
  final List<String> details;

  bool get passed => allowed != null && allowed == testCase.expectAllow;
}

enum RuleSeverity { critical, warning, info }

class RuleFinding {
  const RuleFinding(this.severity, this.matchPath, this.title, this.explanation, {this.line});
  final RuleSeverity severity;
  final String matchPath;
  final String title;
  final String explanation;
  final int? line;
}

/// Analyse statique (sans IA) des règles Firestore pour repérer les
/// configurations dangereuses.
abstract final class RulesAnalyzer {
  static final _token = RegExp(
    r'match\s+(\S+)\s*\{|allow\s+([a-z,\s]+?)\s*(?::\s*if\s+([^;]*))?;|\{|\}',
    multiLine: true,
  );

  static String _stripComments(String src) => src
      .replaceAllMapped(RegExp(r'/\*[\s\S]*?\*/'), (m) => m[0]!.replaceAll(RegExp(r'[^\n]'), ' '))
      .replaceAllMapped(RegExp(r'//[^\n]*'), (m) => ' ' * m[0]!.length);

  static List<RuleFinding> analyze(String source) {
    final src = _stripComments(source);
    final findings = <RuleFinding>[];
    if (!src.contains('service cloud.firestore')) {
      findings.add(const RuleFinding(RuleSeverity.warning, '', 'Pas de bloc « service cloud.firestore »',
          'Ces règles ne s\'appliquent pas à Firestore.'));
    }
    if (!RegExp(r'''rules_version\s*=\s*['"]2['"]''').hasMatch(src)) {
      findings.add(const RuleFinding(RuleSeverity.info, '', 'rules_version 2 absent',
          'Sans rules_version = \'2\', les jokers récursifs {x=**} ne se comportent pas comme attendu.'));
    }
    final stack = <String?>[];
    for (final m in _token.allMatches(src)) {
      final text = m[0]!;
      if (m[1] != null) {
        stack.add(m[1]);
      } else if (text == '{') {
        stack.add(null);
      } else if (text == '}') {
        if (stack.isNotEmpty) stack.removeLast();
      } else if (m[2] != null) {
        final methods = m[2]!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
        final cond = (m[3] ?? 'true').replaceAll(RegExp(r'\s+'), ' ').trim();
        final path = stack.whereType<String>().join('');
        final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        findings.addAll(_judge(path, methods, cond, line));
      }
    }
    return findings;
  }

  static const _writeMethods = {'write', 'create', 'update', 'delete'};
  static const _readMethods = {'read', 'get', 'list'};

  static List<RuleFinding> _judge(String path, Set<String> methods, String cond, int line) {
    final out = <RuleFinding>[];
    final writes = methods.intersection(_writeMethods);
    final reads = methods.intersection(_readMethods);
    final display = path.replaceFirst('/databases/{database}/documents', '').isEmpty
        ? '/'
        : path.replaceFirst('/databases/{database}/documents', '');
    final rootWildcard = RegExp(r'documents/\{[A-Za-z_]+=\*\*\}$').hasMatch(path);
    final alwaysTrue = cond == 'true';
    final testMode = RegExp(r'request\.time\s*<\s*timestamp\.date\(').hasMatch(cond);
    final authOnly = RegExp(r'^request\.auth\s*!=\s*null$').hasMatch(cond);

    if (testMode) {
      out.add(RuleFinding(RuleSeverity.critical, display, 'Règles en « mode test »',
          'L\'accès ($methods) est ouvert à tous jusqu\'à une date limite. Toute personne connaissant l\'identifiant du projet peut lire et modifier les données.',
          line: line));
      return out;
    }
    if (alwaysTrue && writes.isNotEmpty) {
      out.add(RuleFinding(RuleSeverity.critical, display, 'Écriture ouverte à tous',
          'N\'importe qui, même sans compte, peut ${writes.join('/')} sur $display.',
          line: line));
    }
    if (alwaysTrue && reads.isNotEmpty) {
      out.add(RuleFinding(
          rootWildcard ? RuleSeverity.critical : RuleSeverity.info,
          display,
          rootWildcard ? 'Toute la base est lisible publiquement' : 'Lecture publique',
          rootWildcard
              ? 'Tous les documents de toutes les collections sont lisibles sans compte.'
              : 'Les documents de $display sont lisibles sans compte. Vérifiez qu\'ils sont réellement publics.',
          line: line));
    }
    if (authOnly && writes.isNotEmpty) {
      out.add(RuleFinding(rootWildcard ? RuleSeverity.critical : RuleSeverity.warning, display,
          'Écriture accordée à tout utilisateur connecté',
          'N\'importe quel compte (création libre) peut modifier les données de $display, y compris celles des autres utilisateurs.',
          line: line));
    }
    if (authOnly && reads.isNotEmpty && rootWildcard) {
      out.add(RuleFinding(RuleSeverity.warning, display, 'Toute la base lisible par tout compte',
          'Tout utilisateur connecté peut lire toutes les collections.',
          line: line));
    }
    return out;
  }

  static bool hasCritical(List<RuleFinding> f) => f.any((x) => x.severity == RuleSeverity.critical);
}
