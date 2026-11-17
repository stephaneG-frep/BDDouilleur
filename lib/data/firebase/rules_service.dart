import 'dart:convert';

import '../../domain/firebase/firebase_target.dart';
import '../../domain/firebase/firestore_rules.dart';
import '../google/google_api.dart';
import 'firebase_management.dart';
import 'firestore_client.dart';

class RulesCompileException implements Exception {
  RulesCompileException(this.issues);
  final List<String> issues;
  @override
  String toString() => 'Les règles ne compilent pas :\n${issues.join('\n')}';
}

/// Lecture, déploiement et test des règles Firestore.
abstract class RulesService {
  /// Règles actuellement actives (`null` si aucune n'est connue).
  Future<String?> currentRules();

  /// Déploie les règles. Lève [RulesCompileException] si elles sont invalides.
  Future<void> deploy(String source);

  /// Exécute les cas de test contre les règles [source].
  Future<List<RuleTestResult>> runTests(String source, List<RuleTestCase> cases);

  /// Comment les tests sont réalisés (affiché à l'utilisateur).
  String get testMethod;
}

/// Vrai projet : API Firebase Rules (firebaserules.googleapis.com).
/// Les tests passent par `projects.test`, qui évalue les règles sans lire ni
/// écrire aucune donnée.
class GoogleRulesService implements RulesService {
  GoogleRulesService(this.target, this.api);
  final FirebaseTarget target;
  final GoogleApiClient api;

  static const _base = '${GoogleEndpoints.rules}/v1';
  String get _project => 'projects/${target.projectId}';
  String get _releaseId => target.databaseId == '(default)' ? 'cloud.firestore' : 'cloud.firestore/${target.databaseId}';

  @override
  String get testMethod =>
      'API Firebase Rules (projects.test) : les règles sont évaluées par Google sans toucher aux données.';

  Map<String, Object?> _source(String content) => {
        'files': [
          {'name': 'firestore.rules', 'content': content}
        ]
      };

  @override
  Future<String?> currentRules() async {
    try {
      final rel = await api.get('$_base/$_project/releases/$_releaseId');
      final rs = await api.get('$_base/${rel['rulesetName']}');
      final files = ((rs['source'] as Map?)?['files'] as List?) ?? const [];
      return files.isEmpty ? null : (files.first as Map)['content'] as String?;
    } on GoogleApiException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  @override
  Future<void> deploy(String source) async {
    final Map<String, dynamic> ruleset;
    try {
      ruleset = await api.post('$_base/$_project/rulesets', body: {'source': _source(source)});
    } on GoogleApiException catch (e) {
      if (e.status == 'INVALID_ARGUMENT') throw RulesCompileException([e.message]);
      rethrow;
    }
    final release = '$_project/releases/$_releaseId';
    try {
      await api.get('$_base/$release');
      await api.patch('$_base/$release', body: {
        'release': {'name': release, 'rulesetName': ruleset['name']}
      });
    } on GoogleApiException catch (e) {
      if (!e.isNotFound) rethrow;
      await api.post('$_base/$_project/releases', body: {'name': release, 'rulesetName': ruleset['name']});
    }
  }

  @override
  Future<List<RuleTestResult>> runTests(String source, List<RuleTestCase> cases) async {
    final docRoot = '/databases/${target.databaseId}/documents';
    final r = await api.post('$_base/$_project:test', body: {
      'source': _source(source),
      'testSuite': {
        'testCases': [
          for (final c in cases)
            {
              'expectation': c.expectAllow ? 'ALLOW' : 'DENY',
              'request': {
                'auth': c.uid == null ? null : {'uid': c.uid, 'token': {'email_verified': true}},
                'path': '$docRoot/${c.path}',
                'method': c.method.name,
                if (c.request != null) 'resource': {'data': c.request},
              },
              if (c.existing != null) 'resource': {'data': c.existing},
            }
        ]
      }
    });
    final issues = [
      for (final i in (r['issues'] as List?) ?? const [])
        if ((i as Map)['severity'] == 'ERROR')
          'Ligne ${(i['sourcePosition'] as Map?)?['line'] ?? '?'} : ${i['description']}'
    ];
    if (issues.isNotEmpty) throw RulesCompileException(issues);
    final results = (r['testResults'] as List?) ?? const [];
    return [
      for (var i = 0; i < cases.length; i++)
        () {
          final res = i < results.length ? results[i] as Map : const {};
          final success = res['state'] == 'SUCCESS';
          return RuleTestResult(
            cases[i],
            // SUCCESS = résultat conforme à l'attente, donc résultat observé = attente.
            allowed: res.isEmpty ? null : (success ? cases[i].expectAllow : !cases[i].expectAllow),
            error: res.isEmpty ? 'Aucun résultat renvoyé' : null,
            details: [for (final d in (res['debugMessages'] as List?) ?? const []) '$d'],
          );
        }(),
    ];
  }
}

/// Émulateur Firestore : déploiement via l'API d'administration de
/// l'émulateur, tests par de vraies requêtes envoyées sous l'identité
/// d'utilisateurs fictifs (jetons non signés acceptés par l'émulateur,
/// comme le fait la bibliothèque officielle @firebase/rules-unit-testing).
class EmulatorRulesService implements RulesService {
  EmulatorRulesService(this.target, this.ownerApi, {required this.clientFactory, this.onDeployed});
  final FirebaseTarget target;

  /// Client « Bearer owner » (contourne les règles) pour préparer et
  /// restaurer les données de test.
  final GoogleApiClient ownerApi;

  /// Crée un client avec l'en-tête d'autorisation donné.
  final GoogleApiClient Function(String? authHeader) clientFactory;
  final void Function(String source)? onDeployed;

  @override
  String get testMethod => 'Requêtes réelles sur l\'émulateur, sous l\'identité d\'utilisateurs de test. '
      'Les documents touchés sont sauvegardés avant chaque test puis restaurés.';

  @override
  Future<String?> currentRules() async => target.lastRules;

  @override
  Future<void> deploy(String source) async {
    try {
      await ownerApi.put('http://${target.firestoreHost}/emulator/v1/projects/${target.projectId}:securityRules',
          body: {
            'rules': {
              'files': [
                {'name': 'firestore.rules', 'content': source}
              ]
            }
          });
    } on GoogleApiException catch (e) {
      if (e.statusCode == 400) throw RulesCompileException([e.message]);
      rethrow;
    }
    onDeployed?.call(source);
  }

  /// Jeton non signé (alg « none ») accepté uniquement par les émulateurs.
  static String mockIdToken(String projectId, String uid) {
    String enc(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return '${enc({'alg': 'none', 'kid': 'fakekid', 'typ': 'JWT'})}.${enc({
          'iss': 'https://securetoken.google.com/$projectId',
          'aud': projectId,
          'iat': now,
          'exp': now + 3600,
          'auth_time': now,
          'sub': uid,
          'user_id': uid,
          'email': '$uid@bddouilleur.test',
          'email_verified': true,
          'firebase': {'sign_in_provider': 'password', 'identities': {}},
        })}.';
  }

  @override
  Future<List<RuleTestResult>> runTests(String source, List<RuleTestCase> cases) async {
    final previous = target.lastRules;
    await deploy(source);
    final owner = FirestoreClient(target, ownerApi);
    final results = <RuleTestResult>[];
    try {
      for (final c in cases) {
        results.add(await _runOne(owner, c));
      }
    } finally {
      // Les règles testées restent actives seulement si elles étaient déjà déployées.
      if (previous != null && previous != source) {
        await deploy(previous);
      }
    }
    return results;
  }

  Future<RuleTestResult> _runOne(FirestoreClient owner, RuleTestCase c) async {
    final snapshot = await owner.getDocument(c.path);
    try {
      if (c.method == RuleMethod.create) {
        if (snapshot != null) await owner.deleteDocument(c.path);
      } else if (c.existing != null) {
        await owner.setDocument(c.path, c.existing!);
      }
      final api = clientFactory(c.uid == null ? null : 'Bearer ${mockIdToken(target.projectId, c.uid!)}');
      final client = FirestoreClient(target, api);
      final collection = c.path.substring(0, c.path.lastIndexOf('/'));
      final id = c.path.split('/').last;
      try {
        switch (c.method) {
          case RuleMethod.get:
            await client.getDocument(c.path);
          case RuleMethod.create:
            await client.createDocument(collection, c.request ?? const {}, documentId: id);
          case RuleMethod.update:
            await client.replaceDocument(c.path, c.request ?? const {});
          case RuleMethod.delete:
            await client.deleteDocument(c.path);
        }
        return RuleTestResult(c, allowed: true);
      } on GoogleApiException catch (e) {
        if (e.isPermissionDenied) return RuleTestResult(c, allowed: false, details: [e.message]);
        return RuleTestResult(c, allowed: null, error: e.toString());
      }
    } finally {
      if (snapshot != null) {
        await owner.setDocument(c.path, snapshot.data);
      } else {
        await owner.deleteDocument(c.path);
      }
    }
  }
}
