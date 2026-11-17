import '../../domain/firebase/firebase_target.dart';
import '../google/google_api.dart';
import 'firestore_value_codec.dart';

class FirestoreDocument {
  const FirestoreDocument({required this.path, required this.data, this.createTime, this.updateTime});

  /// Chemin relatif à la racine des documents : `collection/id[/sous/id]`.
  final String path;
  final Map<String, Object?> data;
  final DateTime? createTime;
  final DateTime? updateTime;

  String get id => path.split('/').last;
  String get collectionPath => path.substring(0, path.lastIndexOf('/'));
}

class DocumentPage {
  const DocumentPage(this.documents, this.nextPageToken);
  final List<FirestoreDocument> documents;
  final String? nextPageToken;
}

/// Accès aux données Firestore via l'API REST officielle (v1).
///
/// Fonctionne à l'identique avec un vrai projet (jeton OAuth : accès
/// administrateur IAM, les règles de sécurité ne s'appliquent pas) et avec
/// l'émulateur (en-tête « Bearer owner » : idem ; ou jeton d'un utilisateur
/// de test : les règles s'appliquent).
///
/// Rappel : une collection Firestore n'existe qu'à travers ses documents.
/// Ce client ne propose donc pas de « créer une collection vide ».
class FirestoreClient {
  FirestoreClient(this.target, this.api);
  final FirebaseTarget target;
  final GoogleApiClient api;

  String get _root => target.documentsRoot;

  static String? validateSegment(String s, {String what = 'identifiant'}) {
    if (s.isEmpty) return 'Un $what ne peut pas être vide.';
    if (s == '.' || s == '..') return '« $s » n\'est pas un $what valide.';
    if (s.contains('/')) return 'Un $what ne peut pas contenir « / ».';
    if (RegExp(r'^__.*__$').hasMatch(s)) return 'Les noms __…__ sont réservés par Firestore.';
    if (s.length > 1500) return 'Trop long (1500 octets maximum).';
    return null;
  }

  static List<String> _segments(String path, {required bool document}) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty || (document ? parts.length.isOdd : parts.length.isEven)) {
      throw FormatException(document
          ? 'Chemin de document attendu (collection/id) : « $path »'
          : 'Chemin de collection attendu (collection ou collection/id/sous-collection) : « $path »');
    }
    for (final s in parts) {
      final err = validateSegment(s);
      if (err != null) throw FormatException(err);
    }
    return parts;
  }

  static String _encode(List<String> parts) => parts.map(Uri.encodeComponent).join('/');

  FirestoreDocument _decode(Map<String, dynamic> j) {
    final name = j['name'] as String;
    final marker = '/documents/';
    final rel = name.substring(name.indexOf(marker) + marker.length);
    return FirestoreDocument(
      path: rel,
      data: FirestoreValueCodec.decodeFields(j['fields'] as Map<String, dynamic>?),
      createTime: DateTime.tryParse('${j['createTime']}'),
      updateTime: DateTime.tryParse('${j['updateTime']}'),
    );
  }

  /// Collections de premier niveau, ou sous-collections d'un document.
  Future<List<String>> listCollectionIds({String? documentPath}) async {
    final parent = documentPath == null ? _root : '$_root/${_encode(_segments(documentPath, document: true))}';
    final ids = <String>[];
    String? token;
    do {
      final r = await api.post('$parent:listCollectionIds', body: {'pageSize': 300, 'pageToken': ?token});
      ids.addAll(((r['collectionIds'] as List?) ?? const []).cast<String>());
      token = r['nextPageToken'] as String?;
    } while (token != null && token.isNotEmpty);
    ids.sort();
    return ids;
  }

  Future<DocumentPage> listDocuments(String collectionPath, {int pageSize = 50, String? pageToken}) async {
    final r = await api.get('$_root/${_encode(_segments(collectionPath, document: false))}',
        query: {'pageSize': '$pageSize', 'pageToken': ?pageToken});
    return DocumentPage(
      [for (final d in (r['documents'] as List?) ?? const []) _decode(d as Map<String, dynamic>)],
      (r['nextPageToken'] as String?)?.isEmpty ?? true ? null : r['nextPageToken'] as String,
    );
  }

  Future<FirestoreDocument?> getDocument(String path) async {
    try {
      return _decode(await api.get('$_root/${_encode(_segments(path, document: true))}'));
    } on GoogleApiException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  /// Crée un document (identifiant automatique si [documentId] est nul).
  /// Échoue si le document existe déjà.
  Future<FirestoreDocument> createDocument(String collectionPath, Map<String, Object?> data, {String? documentId}) async {
    if (documentId != null) {
      final err = validateSegment(documentId);
      if (err != null) throw FormatException(err);
    }
    final r = await api.post(
      '$_root/${_encode(_segments(collectionPath, document: false))}',
      query: {'documentId': ?documentId},
      body: {'fields': FirestoreValueCodec.encodeFields(data, databaseRoot: target.databaseRoot)},
    );
    return _decode(r);
  }

  /// Remplace entièrement le contenu d'un document existant.
  /// [mustExist] protège contre la création involontaire.
  Future<FirestoreDocument> replaceDocument(String path, Map<String, Object?> data, {bool mustExist = true}) async {
    final r = await api.patch(
      '$_root/${_encode(_segments(path, document: true))}',
      query: mustExist ? {'currentDocument.exists': 'true'} : null,
      body: {'fields': FirestoreValueCodec.encodeFields(data, databaseRoot: target.databaseRoot)},
    );
    return _decode(r);
  }

  /// Écrit un document (création ou remplacement), sans précondition.
  Future<FirestoreDocument> setDocument(String path, Map<String, Object?> data) =>
      replaceDocument(path, data, mustExist: false);

  Future<void> deleteDocument(String path) async {
    await api.delete('$_root/${_encode(_segments(path, document: true))}');
  }

  /// Requête REST correspondant à la dernière opération (pour le journal).
  String? get lastRequest => api.requestLog.isEmpty ? null : api.requestLog.last;
}
