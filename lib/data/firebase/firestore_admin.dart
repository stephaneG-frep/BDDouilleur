import '../google/google_api.dart';
import 'firebase_management.dart';

/// Régions Firestore proposées (identifiants officiels).
const firestoreLocations = <String, String>{
  'eur3': 'Europe (multirégion : Belgique et Pays-Bas)',
  'europe-west1': 'Belgique',
  'europe-west9': 'Paris',
  'europe-west3': 'Francfort',
  'nam5': 'États-Unis (multirégion)',
  'us-central1': 'Iowa',
  'northamerica-northeast1': 'Montréal',
  'africa-south1': 'Johannesburg',
  'asia-northeast1': 'Tokyo',
  'southamerica-east1': 'São Paulo',
};

class FirestoreDatabaseInfo {
  const FirestoreDatabaseInfo({required this.id, required this.locationId, required this.type, this.uid});
  final String id;
  final String locationId;
  final String type;
  final String? uid;

  bool get isNative => type == 'FIRESTORE_NATIVE';

  factory FirestoreDatabaseInfo.fromJson(Map<String, dynamic> j) => FirestoreDatabaseInfo(
        id: (j['name'] as String).split('/').last,
        locationId: (j['locationId'] as String?) ?? '?',
        type: (j['type'] as String?) ?? '?',
        uid: j['uid'] as String?,
      );
}

enum IndexOrder { ascending, descending, arrayContains }

class IndexField {
  const IndexField(this.fieldPath, this.order);
  final String fieldPath;
  final IndexOrder order;

  Map<String, Object?> toJson() => {
        'fieldPath': fieldPath,
        if (order == IndexOrder.arrayContains)
          'arrayConfig': 'CONTAINS'
        else
          'order': order == IndexOrder.ascending ? 'ASCENDING' : 'DESCENDING',
      };

  factory IndexField.fromJson(Map<String, dynamic> j) => IndexField(
        j['fieldPath'] as String,
        j['arrayConfig'] != null
            ? IndexOrder.arrayContains
            : (j['order'] == 'DESCENDING' ? IndexOrder.descending : IndexOrder.ascending),
      );

  String get label => '$fieldPath ${switch (order) {
        IndexOrder.ascending => '↑',
        IndexOrder.descending => '↓',
        IndexOrder.arrayContains => '[contient]',
      }}';
}

class FirestoreIndexInfo {
  const FirestoreIndexInfo({
    required this.name,
    required this.collectionGroup,
    required this.queryScope,
    required this.fields,
    required this.state,
  });

  final String name;
  final String collectionGroup;
  final String queryScope;
  final List<IndexField> fields;
  final String state;

  factory FirestoreIndexInfo.fromJson(Map<String, dynamic> j) {
    final name = j['name'] as String;
    final parts = name.split('/');
    final cg = parts.indexOf('collectionGroups');
    return FirestoreIndexInfo(
      name: name,
      collectionGroup: cg >= 0 ? parts[cg + 1] : '?',
      queryScope: (j['queryScope'] as String?) ?? 'COLLECTION',
      // Le champ système __name__ ajouté automatiquement n'est pas affiché.
      fields: [
        for (final f in (j['fields'] as List?) ?? const [])
          if ((f as Map)['fieldPath'] != '__name__') IndexField.fromJson(f.cast<String, dynamic>()),
      ],
      state: (j['state'] as String?) ?? '?',
    );
  }

  String get stateLabel => switch (state) {
        'READY' => 'Prêt',
        'CREATING' => 'En construction',
        'NEEDS_REPAIR' => 'À réparer',
        _ => state,
      };
}

/// Administration Firestore (bases et index) sur un vrai projet Google.
/// L'émulateur n'expose pas ces API : il n'exige d'ailleurs aucun index.
class FirestoreAdminService {
  FirestoreAdminService(this.api);
  final GoogleApiClient api;

  static const _base = '${GoogleEndpoints.firestore}/v1';

  Future<List<FirestoreDatabaseInfo>> listDatabases(String projectId) async {
    final r = await api.get('$_base/projects/$projectId/databases');
    return [for (final d in (r['databases'] as List?) ?? const []) FirestoreDatabaseInfo.fromJson(d as Map<String, dynamic>)];
  }

  Future<FirestoreDatabaseInfo> createDatabase(String projectId, String locationId, {String databaseId = '(default)'}) async {
    final op = await api.post('$_base/projects/$projectId/databases',
        query: {'databaseId': databaseId}, body: {'locationId': locationId, 'type': 'FIRESTORE_NATIVE'});
    await api.waitOperation(_base, op);
    final all = await listDatabases(projectId);
    return all.firstWhere((d) => d.id == databaseId,
        orElse: () => throw GoogleApiException(statusCode: 0, status: 'UNKNOWN', message: 'Base introuvable après création'));
  }

  /// Index composites (les index simples sont automatiques).
  Future<List<FirestoreIndexInfo>> listIndexes(String projectId, {String databaseId = '(default)'}) async {
    final r = await api.get('$_base/projects/$projectId/databases/$databaseId/collectionGroups/-/indexes');
    return [for (final i in (r['indexes'] as List?) ?? const []) FirestoreIndexInfo.fromJson(i as Map<String, dynamic>)];
  }

  /// Lance la création d'un index composite. La construction peut prendre
  /// plusieurs minutes : l'état est ensuite visible via [listIndexes].
  Future<void> createIndex(String projectId, String collectionGroup, List<IndexField> fields,
      {String databaseId = '(default)', bool collectionGroupScope = false}) async {
    if (fields.length < 2) throw ArgumentError('Un index composite comporte au moins deux champs.');
    await api.post(
      '$_base/projects/$projectId/databases/$databaseId/collectionGroups/${Uri.encodeComponent(collectionGroup)}/indexes',
      body: {
        'queryScope': collectionGroupScope ? 'COLLECTION_GROUP' : 'COLLECTION',
        'fields': [for (final f in fields) f.toJson()],
      },
    );
  }

  Future<void> deleteIndex(String indexName) async {
    await api.delete('$_base/$indexName');
  }
}
