import 'dart:typed_data';

import '../../../domain/models/schema.dart';

/// Conversion entre la saisie utilisateur (texte) et les valeurs SQLite,
/// selon l'affinité de la colonne.
class SqliteValueCodec {
  /// Convertit un texte saisi. `null` en entrée (case « NULL » cochée) donne NULL.
  /// Lève [FormatException] avec un message en français si la saisie est invalide.
  static Object? parse(String? input, ColumnInfo column) {
    if (input == null) return null;
    final v = input.trim();
    final declared = column.declaredType.toUpperCase();
    switch (column.affinity) {
      case 'INTEGER':
        if (v.isEmpty) return column.notNull ? throw FormatException('« ${column.name} » est obligatoire.') : null;
        if (declared.contains('BOOL')) {
          final lower = v.toLowerCase();
          if (const {'1', 'true', 'vrai', 'oui'}.contains(lower)) return 1;
          if (const {'0', 'false', 'faux', 'non'}.contains(lower)) return 0;
        }
        return int.tryParse(v) ?? (throw FormatException('« ${column.name} » attend un nombre entier.'));
      case 'REAL':
        if (v.isEmpty) return column.notNull ? throw FormatException('« ${column.name} » est obligatoire.') : null;
        return double.tryParse(v.replaceAll(',', '.')) ??
            (throw FormatException('« ${column.name} » attend un nombre décimal.'));
      case 'NUMERIC':
        if (v.isEmpty) return column.notNull ? throw FormatException('« ${column.name} » est obligatoire.') : null;
        if (declared.contains('BOOL')) {
          final lower = v.toLowerCase();
          if (const {'1', 'true', 'vrai', 'oui'}.contains(lower)) return 1;
          if (const {'0', 'false', 'faux', 'non'}.contains(lower)) return 0;
          throw FormatException('« ${column.name} » attend vrai/faux (1 ou 0).');
        }
        if (declared.contains('DATE')) return v; // stockée en texte ISO 8601
        final asInt = int.tryParse(v);
        if (asInt != null) return asInt;
        final asDouble = double.tryParse(v.replaceAll(',', '.'));
        if (asDouble != null) return asDouble;
        throw FormatException('« ${column.name} » attend une valeur numérique.');
      case 'BLOB':
        if (v.isEmpty) return null;
        return v; // colonne sans type déclaré : on stocke le texte tel quel
      default:
        return v;
    }
  }

  /// Représentation textuelle pour l'affichage et l'édition.
  static String display(Object? value) {
    if (value == null) return 'NULL';
    if (value is Uint8List) return '<BLOB ${value.length} octets>';
    return value.toString();
  }

  static bool isEditable(Object? value) => value is! Uint8List;
}
