import 'dart:convert';

/// Conversion entre les valeurs typées de l'API REST Firestore et un JSON
/// lisible et modifiable.
///
/// Les types sans équivalent JSON sont représentés par des objets marqueurs,
/// ce qui permet un aller-retour sans perte :
/// - `{"$timestamp": "2026-11-17T10:00:00Z"}`
/// - `{"$ref": "chemin/vers/document"}`
/// - `{"$geo": [48.85, 2.35]}`
/// - `{"$bytes": "base64…"}`
/// - `{"$double": 3}` pour forcer un nombre à virgule (sinon 3 → entier).
abstract final class FirestoreValueCodec {
  static const markers = {r'$timestamp', r'$ref', r'$geo', r'$bytes', r'$double'};

  /// Champs Firestore (`fields`) → JSON modifiable.
  static Map<String, Object?> decodeFields(Map<String, dynamic>? fields, {String? databaseRoot}) => {
        for (final e in (fields ?? const <String, dynamic>{}).entries)
          e.key: decodeValue(e.value as Map<String, dynamic>, databaseRoot: databaseRoot),
      };

  static Object? decodeValue(Map<String, dynamic> v, {String? databaseRoot}) {
    if (v.containsKey('nullValue')) return null;
    if (v.containsKey('booleanValue')) return v['booleanValue'] as bool;
    if (v.containsKey('integerValue')) return int.parse('${v['integerValue']}');
    if (v.containsKey('doubleValue')) {
      final d = (v['doubleValue'] as num).toDouble();
      return d == d.truncateToDouble() && d.isFinite ? {r'$double': d} : d;
    }
    if (v.containsKey('stringValue')) return v['stringValue'] as String;
    if (v.containsKey('timestampValue')) return {r'$timestamp': v['timestampValue'] as String};
    if (v.containsKey('referenceValue')) {
      var ref = v['referenceValue'] as String;
      final marker = '/documents/';
      final i = ref.indexOf(marker);
      if (i >= 0) ref = ref.substring(i + marker.length);
      return {r'$ref': ref};
    }
    if (v.containsKey('geoPointValue')) {
      final g = v['geoPointValue'] as Map<String, dynamic>;
      return {
        r'$geo': [(g['latitude'] as num?)?.toDouble() ?? 0.0, (g['longitude'] as num?)?.toDouble() ?? 0.0]
      };
    }
    if (v.containsKey('bytesValue')) return {r'$bytes': v['bytesValue'] as String};
    if (v.containsKey('arrayValue')) {
      final values = ((v['arrayValue'] as Map?)?['values'] as List?) ?? const [];
      return [for (final x in values) decodeValue(x as Map<String, dynamic>, databaseRoot: databaseRoot)];
    }
    if (v.containsKey('mapValue')) {
      return decodeFields((v['mapValue'] as Map?)?['fields'] as Map<String, dynamic>?, databaseRoot: databaseRoot);
    }
    throw FormatException('Type de valeur Firestore inconnu : ${v.keys.join(', ')}');
  }

  /// JSON → champs Firestore. [databaseRoot] vaut
  /// `projects/{p}/databases/{d}` (pour les références).
  static Map<String, dynamic> encodeFields(Map<String, Object?> data, {required String databaseRoot}) {
    for (final k in data.keys) {
      validateFieldName(k);
    }
    return {for (final e in data.entries) e.key: encodeValue(e.value, databaseRoot: databaseRoot)};
  }

  static void validateFieldName(String k) {
    if (k.isEmpty) throw const FormatException('Nom de champ vide.');
    if (RegExp(r'^__.*__$').hasMatch(k)) {
      throw FormatException('Le nom de champ « $k » est réservé par Firestore (__…__).');
    }
  }

  static Map<String, dynamic> encodeValue(Object? v, {required String databaseRoot}) {
    if (v == null) return {'nullValue': null};
    if (v is bool) return {'booleanValue': v};
    if (v is int) return {'integerValue': '$v'};
    if (v is double) return {'doubleValue': v};
    if (v is String) return {'stringValue': v};
    if (v is List) {
      if (v.any((x) => x is List)) {
        throw const FormatException('Firestore n\'accepte pas un tableau directement dans un tableau.');
      }
      return {
        'arrayValue': {'values': [for (final x in v) encodeValue(x, databaseRoot: databaseRoot)]}
      };
    }
    if (v is Map) {
      final m = v.cast<String, Object?>();
      if (m.length == 1 && markers.contains(m.keys.first)) return _encodeMarker(m.keys.first, m.values.first, databaseRoot);
      return {
        'mapValue': {'fields': encodeFields(m, databaseRoot: databaseRoot)}
      };
    }
    throw FormatException('Valeur non prise en charge : $v');
  }

  static Map<String, dynamic> _encodeMarker(String key, Object? value, String databaseRoot) {
    switch (key) {
      case r'$timestamp':
        final t = value is String ? DateTime.tryParse(value) : null;
        if (t == null) throw FormatException('Date invalide pour \$timestamp : $value (format ISO 8601 attendu).');
        return {'timestampValue': t.toUtc().toIso8601String()};
      case r'$ref':
        if (value is! String || value.isEmpty || value.split('/').length.isOdd) {
          throw FormatException('\$ref doit être un chemin de document (collection/id) : $value');
        }
        return {'referenceValue': '$databaseRoot/documents/$value'};
      case r'$geo':
        if (value is! List || value.length != 2 || value.any((x) => x is! num)) {
          throw const FormatException('\$geo attend [latitude, longitude].');
        }
        final lat = (value[0] as num).toDouble(), lng = (value[1] as num).toDouble();
        if (lat.abs() > 90 || lng.abs() > 180) throw const FormatException('Coordonnées hors limites.');
        return {
          'geoPointValue': {'latitude': lat, 'longitude': lng}
        };
      case r'$bytes':
        if (value is! String) throw const FormatException('\$bytes attend une chaîne base64.');
        try {
          base64Decode(value);
        } catch (_) {
          throw const FormatException('\$bytes : base64 invalide.');
        }
        return {'bytesValue': value};
      case r'$double':
        if (value is! num) throw const FormatException('\$double attend un nombre.');
        return {'doubleValue': value.toDouble()};
    }
    throw FormatException('Marqueur inconnu $key');
  }

  /// Analyse le texte saisi par l'utilisateur (objet JSON).
  static Map<String, Object?> parseJsonObject(String text) {
    final Object? v;
    try {
      v = jsonDecode(text.trim().isEmpty ? '{}' : text);
    } on FormatException catch (e) {
      throw FormatException('JSON invalide : ${e.message}');
    }
    if (v is! Map) throw const FormatException('Un document doit être un objet JSON { … }.');
    return v.cast<String, Object?>();
  }

  static String pretty(Object? v) => const JsonEncoder.withIndent('  ').convert(v);

  /// Libellé court du type d'une valeur décodée.
  static String typeLabel(Object? v) {
    if (v == null) return 'null';
    if (v is bool) return 'booléen';
    if (v is int) return 'entier';
    if (v is double) return 'décimal';
    if (v is String) return 'texte';
    if (v is List) return 'tableau';
    if (v is Map) {
      if (v.length == 1) {
        switch (v.keys.first) {
          case r'$timestamp':
            return 'date';
          case r'$ref':
            return 'référence';
          case r'$geo':
            return 'géopoint';
          case r'$bytes':
            return 'octets';
          case r'$double':
            return 'décimal';
        }
      }
      return 'objet';
    }
    return '?';
  }
}
