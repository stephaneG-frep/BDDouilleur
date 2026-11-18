import 'firebase/firestore_rules.dart';
import 'models/schema.dart';

/// Champ d'une entité proposée.
class FieldProposal {
  const FieldProposal(
      {required this.name, required this.type, this.required = false, this.references, this.unique = false, this.column});
  final String name;

  /// Nom de colonne réel (table existante) ; sinon dérivé du nom.
  final String? column;

  String get columnName => column ?? SchemaProposal.columnName(name);
  final SqlColumnType type;
  final bool required;
  final bool unique;

  /// Entité référencée (clé étrangère), le cas échéant.
  final String? references;

  Map<String, Object?> toJson() => {
        'name': name,
        'type': type.name,
        if (required) 'required': true,
        if (unique) 'unique': true,
        'references': ?references,
        'column': ?column,
      };

  factory FieldProposal.fromJson(Map<String, Object?> j) => FieldProposal(
        name: '${j['name']}',
        type: SqlColumnType.values.where((t) => t.name == '${j['type']}'.toLowerCase()).firstOrNull ??
            SqlColumnType.values.where((t) => t.sql == '${j['type']}'.toUpperCase()).firstOrNull ??
            SqlColumnType.text,
        required: j['required'] == true,
        unique: j['unique'] == true,
        references: (j['references'] as String?)?.trim().isEmpty ?? true ? null : (j['references'] as String).trim(),
        column: j['column'] as String?,
      );
}

class EntityProposal {
  const EntityProposal({required this.name, required this.fields, this.description = '', this.source, this.table});
  final String name;

  /// Nom de table réel (table existante) ; sinon dérivé du nom.
  final String? table;

  String get tableName => table ?? SchemaProposal.tableName(name);
  final List<FieldProposal> fields;
  final String description;

  /// D'où vient l'entité (fichier source du modèle détecté), si connu.
  final String? source;

  Map<String, Object?> toJson() => {
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'fields': [for (final f in fields) f.toJson()],
        'source': ?source,
        'table': ?table,
      };

  factory EntityProposal.fromJson(Map<String, Object?> j) => EntityProposal(
        name: '${j['name']}',
        description: (j['description'] as String?) ?? '',
        fields: [for (final f in (j['fields'] as List?) ?? const []) FieldProposal.fromJson((f as Map).cast())],
        source: j['source'] as String?,
        table: j['table'] as String?,
      );
}

/// Architecture de données proposée (par l'analyse déterministe ou par
/// l'agent IA). Elle n'est appliquée qu'après validation par l'utilisateur.
class SchemaProposal {
  const SchemaProposal({required this.entities, this.summary = ''});
  final List<EntityProposal> entities;
  final String summary;

  Map<String, Object?> toJson() => {'summary': summary, 'entities': [for (final e in entities) e.toJson()]};

  factory SchemaProposal.fromJson(Map<String, Object?> j) => SchemaProposal(
        summary: (j['summary'] as String?) ?? '',
        entities: [for (final e in (j['entities'] as List?) ?? const []) EntityProposal.fromJson((e as Map).cast())],
      );

  static final _ident = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Nom de table SQL dérivé du nom d'entité : « OrderItem » → « order_items ».
  static String tableName(String entity) {
    final snake = entity
        .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (snake.endsWith('s')) return snake;
    if (snake.endsWith('y') && !RegExp(r'[aeiou]y$').hasMatch(snake)) return '${snake.substring(0, snake.length - 1)}ies';
    return '${snake}s';
  }

  static String columnName(String field) =>
      field.replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}').toLowerCase();

  /// Problèmes bloquants (noms invalides, références inconnues, doublons).
  List<String> validate() {
    final problems = <String>[];
    final names = <String>{};
    if (entities.isEmpty) problems.add('Aucune entité.');
    for (final e in entities) {
      if (!_ident.hasMatch(e.name)) problems.add('Nom d\'entité invalide : « ${e.name} »');
      if (!names.add(e.name.toLowerCase())) problems.add('Entité en double : « ${e.name} »');
      final fieldNames = <String>{};
      for (final f in e.fields) {
        if (!_ident.hasMatch(f.name)) problems.add('${e.name} : nom de champ invalide « ${f.name} »');
        if (!fieldNames.add(f.columnName)) problems.add('${e.name} : champ en double « ${f.name} »');
        if (f.columnName == 'id') problems.add('${e.name} : « id » est ajouté automatiquement, ne le déclarez pas.');
      }
    }
    for (final e in entities) {
      for (final f in e.fields) {
        if (f.references != null && !entities.any((x) => x.name.toLowerCase() == f.references!.toLowerCase())) {
          problems.add('${e.name}.${f.name} référence une entité inconnue « ${f.references} »');
        }
      }
    }
    return problems;
  }

  /// Relations (entité, champ, entité référencée).
  List<(String, String, String)> get relations => [
        for (final e in entities)
          for (final f in e.fields)
            if (f.references != null) (e.name, f.name, f.references!),
      ];

  /// Tables SQLite, ordonnées pour que les tables référencées soient créées
  /// d'abord. Chaque table reçoit une clé primaire « id » auto-incrémentée.
  List<TableDefinition> toTableDefinitions() {
    final problems = validate();
    if (problems.isNotEmpty) throw FormatException(problems.join('\n'));
    final ordered = <EntityProposal>[];
    final pending = [...entities];
    while (pending.isNotEmpty) {
      final next = pending.where((e) => e.fields.every((f) =>
          f.references == null ||
          f.references!.toLowerCase() == e.name.toLowerCase() ||
          ordered.any((o) => o.name.toLowerCase() == f.references!.toLowerCase()))).toList();
      if (next.isEmpty) {
        throw const FormatException('Références circulaires entre entités : créez-les en deux temps.');
      }
      ordered.addAll(next);
      pending.removeWhere(next.contains);
    }
    String tableOf(String entity) => entities.firstWhere((e) => e.name.toLowerCase() == entity.toLowerCase()).tableName;
    return [
      for (final e in ordered)
        TableDefinition(name: e.tableName, columns: [
          ColumnDefinition(name: 'id', type: SqlColumnType.integer, primaryKey: true, autoIncrement: true),
          for (final f in e.fields)
            ColumnDefinition(
              name: f.columnName,
              type: f.references != null ? SqlColumnType.integer : f.type,
              notNull: f.required,
              unique: f.unique,
              references: f.references == null
                  ? null
                  : ForeignKeyRef(
                      table: tableOf(f.references!), column: 'id', onDelete: f.required ? 'CASCADE' : 'SET NULL'),
            ),
        ]),
    ];
  }

  /// Conception de règles Firestore cohérente : propriétaire par champ si
  /// l'entité porte un identifiant d'utilisateur, sinon lecture connectée.
  List<CollectionRule> toCollectionRules() => [
        for (final e in entities)
          () {
            final owner = e.fields
                .where((f) => RegExp(r'^(owner|user|author|created_?by)(_?id|Id|Uid|_uid)?$').hasMatch(f.name))
                .firstOrNull;
            final collection = SchemaProposal.columnName(e.name).replaceAll('_', '');
            return owner != null
                ? CollectionRule('${collection}s', CollectionAccess.ownerField, ownerField: owner.name)
                : CollectionRule('${collection}s', CollectionAccess.signedInRead);
          }(),
      ];

  /// Résumé en français des entités et relations.
  String describe() {
    final b = StringBuffer();
    if (summary.isNotEmpty) b.writeln(summary);
    b.writeln('${entities.length} entité(s) : ${entities.map((e) => e.name).join(', ')}.');
    for (final (from, field, to) in relations) {
      b.writeln('• $from est relié(e) à $to par « $field ».');
    }
    return b.toString().trim();
  }
}
