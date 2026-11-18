import 'dart:convert';

import 'package:bddouilleur/data/firebase/firebase_autopilot.dart';
import 'package:bddouilleur/data/firebase/firebase_management.dart';
import 'package:bddouilleur/data/google/google_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Faux Google à états : simule les API Resource Manager, Firebase,
/// Service Usage, Firestore Admin et Identity Toolkit pour vérifier
/// l'orchestration (ordre, idempotence, arrêt sur erreur).
class FakeGoogle {
  bool gcpExists = false;
  bool firebaseAdded = false;
  final Set<String> services = {};
  bool firestoreDb = false;
  final List<Map<String, String>> androidApps = [];
  bool authInitialized = true;
  bool emailEnabled = false;
  Set<String> grantedPermissions = {
    'resourcemanager.projects.get',
    'serviceusage.services.enable',
    'firebase.projects.update',
  };
  final List<String> calls = [];

  http.Response _json(Object o, [int code = 200]) => http.Response(jsonEncode(o), code);
  http.Response _err(int code, String status, [String msg = '']) =>
      _json({'error': {'code': code, 'status': status, 'message': msg}}, code);
  Map<String, dynamic> _done(Object response) => {'name': 'operations/x', 'done': true, 'response': response};

  late final client = MockClient((req) async {
    final path = req.url.path;
    calls.add('${req.method} ${req.url.host}$path');
    final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;

    if (req.url.host.startsWith('cloudresourcemanager')) {
      if (req.method == 'GET' && path == '/v1/projects/mon-labo') {
        return gcpExists ? _json({'projectId': 'mon-labo', 'lifecycleState': 'ACTIVE'}) : _err(403, 'PERMISSION_DENIED');
      }
      if (req.method == 'POST' && path == '/v3/projects') {
        expect(body['projectId'], 'mon-labo');
        gcpExists = true;
        return _json({'name': 'operations/cp.1', 'done': false});
      }
      if (req.method == 'GET' && path == '/v3/operations/cp.1') return _json(_done({'projectId': 'mon-labo'}));
      if (path.endsWith(':testIamPermissions')) {
        return _json({'permissions': grantedPermissions.toList()});
      }
    }
    if (req.url.host.startsWith('firebase.')) {
      if (req.method == 'GET' && path == '/v1beta1/projects/mon-labo') {
        return firebaseAdded
            ? _json({'projectId': 'mon-labo', 'displayName': 'Mon labo', 'projectNumber': '42'})
            : _err(404, 'NOT_FOUND');
      }
      if (path.endsWith(':addFirebase')) {
        firebaseAdded = true;
        return _json(_done({}));
      }
      if (req.method == 'GET' && path == '/v1beta1/projects/mon-labo/androidApps') {
        return _json({'apps': androidApps});
      }
      if (req.method == 'POST' && path == '/v1beta1/projects/mon-labo/androidApps') {
        final app = {
          'name': 'projects/mon-labo/androidApps/1:42:android:abc',
          'appId': '1:42:android:abc',
          'packageName': body['packageName'] as String,
        };
        androidApps.add(app);
        return _json(_done(app));
      }
      if (path.endsWith('/config')) {
        final json = jsonEncode({
          'project_info': {'project_number': '42', 'project_id': 'mon-labo', 'storage_bucket': 'mon-labo.appspot.com'},
          'client': [
            {
              'client_info': {
                'mobilesdk_app_id': '1:42:android:abc',
                'android_client_info': {'package_name': 'fr.labo.app'}
              },
              'api_key': [
                {'current_key': 'AIzaFAKE'}
              ]
            }
          ]
        });
        return _json({'configFilename': 'google-services.json', 'configFileContents': base64Encode(utf8.encode(json))});
      }
    }
    if (req.url.host.startsWith('serviceusage')) {
      if (req.method == 'GET') {
        return _json({
          'services': [
            for (final s in services) {'name': 'projects/42/services/$s', 'config': {'name': s}, 'state': 'ENABLED'}
          ]
        });
      }
      final svc = path.split('/services/').last.replaceAll(':enable', '');
      services.add(svc);
      return _json(_done({}));
    }
    if (req.url.host.startsWith('firestore')) {
      if (req.method == 'GET') {
        return _json({
          'databases': [
            if (firestoreDb)
              {'name': 'projects/mon-labo/databases/(default)', 'locationId': 'eur3', 'type': 'FIRESTORE_NATIVE'}
          ]
        });
      }
      expect(req.url.queryParameters['databaseId'], '(default)');
      expect(body['locationId'], 'eur3');
      firestoreDb = true;
      return _json(_done({}));
    }
    if (req.url.host.startsWith('identitytoolkit')) {
      if (!authInitialized) return _err(404, 'NOT_FOUND', 'CONFIGURATION_NOT_FOUND');
      if (req.method == 'PATCH') {
        expect(req.url.queryParameters['updateMask'], contains('signIn.email.enabled'));
        emailEnabled = true;
      }
      return _json({
        'signIn': {
          'email': {'enabled': emailEnabled, 'passwordRequired': true}
        },
        'emailPrivacyConfig': {'enableImprovedEmailPrivacy': emailEnabled},
        'authorizedDomains': ['localhost'],
      });
    }
    return _err(500, 'INTERNAL', 'route non simulée : ${req.method} $path');
  });
}

void main() {
  const plan = FirebaseCreationPlan(
    projectId: 'mon-labo',
    displayName: 'Mon labo',
    packageName: 'fr.labo.app',
    firestoreLocation: 'eur3',
  );

  GoogleApiClient apiFor(FakeGoogle g) =>
      GoogleApiClient(client: g.client, authHeader: () async => 'Bearer test', pollInterval: Duration.zero);

  test('création complète puis relance sans rien recréer', () async {
    final g = FakeGoogle();
    final logs = <String>[];
    final requests = <String?>[];
    final pilot = FirebaseAutoPilot(apiFor(g), onLog: (s, r, {success = true, error}) {
      logs.add(s);
      requests.add(r);
    });
    final r = await pilot.run(plan);
    expect(r.success, isTrue, reason: r.steps.map((s) => '${s.title}: ${s.status} ${s.detail}').join('\n'));
    expect(g.gcpExists && g.firebaseAdded && g.firestoreDb && g.emailEnabled, isTrue);
    expect(g.services, containsAll(['firestore.googleapis.com', 'firebaserules.googleapis.com', 'identitytoolkit.googleapis.com']));
    expect(g.androidApps.single['packageName'], 'fr.labo.app');
    expect(r.googleServicesJson, contains('AIzaFAKE'));
    expect(logs, contains('Projet Google Cloud « mon-labo » créé'));
    expect(requests.first, 'POST https://cloudresourcemanager.googleapis.com/v3/projects');
    expect(requests.every((r) => r != null && !r.startsWith('GET ')), isTrue);

    // Deuxième exécution : uniquement des vérifications.
    g.calls.clear();
    logs.clear();
    final again = await FirebaseAutoPilot(apiFor(g), onLog: (s, r, {success = true, error}) => logs.add(s)).run(plan);
    expect(again.success, isTrue);
    final mutating = g.calls.where((c) => !c.startsWith('GET') && !c.contains('testIamPermissions'));
    expect(mutating, isEmpty, reason: 'aucune création lors de la relance');
    expect(logs, isEmpty);
    expect(again.steps.where((s) => s.status == StepStatus.skipped).length, greaterThanOrEqualTo(5));
  });

  test('permissions insuffisantes : arrêt immédiat, rien d\'autre n\'est tenté', () async {
    final g = FakeGoogle()
      ..gcpExists = true
      ..grantedPermissions = {'resourcemanager.projects.get'};
    final r = await FirebaseAutoPilot(apiFor(g)).run(plan);
    expect(r.success, isFalse);
    final perm = r.steps.firstWhere((s) => s.title.startsWith('Permissions'));
    expect(perm.status, StepStatus.failed);
    expect(perm.detail, contains('firebase.projects.update'));
    expect(g.firebaseAdded, isFalse);
    expect(r.steps.where((s) => s.status == StepStatus.pending).length, greaterThan(3));
  });

  test('Authentication non initialisé : avertissement honnête, pas d\'échec', () async {
    final g = FakeGoogle()..authInitialized = false;
    final r = await FirebaseAutoPilot(apiFor(g)).run(plan);
    final auth = r.steps.firstWhere((s) => s.title.startsWith('Authentication'));
    expect(auth.status, StepStatus.warning);
    expect(auth.detail, contains('console.firebase.google.com'));
    expect(r.success, isTrue);
  });

  test('erreur Google traduite (API désactivée avec lien d\'activation)', () {
    final e = GoogleApiException.fromResponse(
      http.Response(
          jsonEncode({
            'error': {
              'code': 403,
              'status': 'PERMISSION_DENIED',
              'message': 'Firebase Management API has not been used',
              'details': [
                {
                  '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
                  'reason': 'SERVICE_DISABLED',
                  'metadata': {'activationUrl': 'https://console.developers.google.com/apis/api/firebase.googleapis.com'}
                }
              ]
            }
          }),
          403),
      'GET https://firebase.googleapis.com/v1beta1/projects',
    );
    expect(e.isServiceDisabled, isTrue);
    expect(e.explanation, contains('https://console.developers.google.com/apis/api/firebase.googleapis.com'));
  });

  test('le journal des requêtes ne contient jamais la clé d\'API', () async {
    final api = GoogleApiClient(client: MockClient((_) async => http.Response('{}', 200)), authHeader: () async => null);
    await api.post('https://identitytoolkit.googleapis.com/v1/accounts:signUp', query: {'key': 'AIzaSECRET'});
    expect(api.requestLog.single, isNot(contains('AIzaSECRET')));
    expect(api.requestLog.single, 'POST https://identitytoolkit.googleapis.com/v1/accounts:signUp');
  });

  test('portée OAuth insuffisante : message explicite, jamais « projet inexistant »', () async {
    final e = GoogleApiException.fromResponse(
      http.Response(
          jsonEncode({
            'error': {
              'code': 403,
              'status': 'PERMISSION_DENIED',
              'message': 'Request had insufficient authentication scopes.',
              'details': [
                {'@type': 'type.googleapis.com/google.rpc.ErrorInfo', 'reason': 'ACCESS_TOKEN_SCOPE_INSUFFICIENT'}
              ]
            }
          }),
          403),
      'GET https://firebase.googleapis.com/v1beta1/projects',
    );
    expect(e.isScopeInsufficient, isTrue);
    expect(e.explanation, contains('cochez TOUTES les cases'));

    final api = GoogleApiClient(
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'error': {'code': 403, 'status': 'PERMISSION_DENIED', 'message': 'Request had insufficient authentication scopes.'}
            }),
            403)),
        authHeader: () async => 'Bearer x');
    await expectLater(FirebaseManagementService(api).gcpProjectState('mon-labo'), throwsA(isA<GoogleApiException>()));
    await expectLater(FirebaseManagementService(api).getFirebaseProject('mon-labo'), throwsA(isA<GoogleApiException>()));
  });
}
