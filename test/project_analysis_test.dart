import 'dart:io';

import 'package:bddouilleur/data/analysis/project_analyzer.dart';
import 'package:bddouilleur/domain/models/schema.dart';
import 'package:bddouilleur/domain/schema_proposal.dart';
import 'package:bddouilleur/domain/text_diff.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('bdd_analyse_'));
  tearDown(() => dir.deleteSync(recursive: true));

  void write(String rel, String content) {
    final f = File(p.join(dir.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  test('projet Flutter : modèles, relations, stockage, API, secrets non lus', () async {
    write('pubspec.yaml', 'name: shop\ndependencies:\n  flutter:\n    sdk: flutter\n  shared_preferences: ^2.0.0\n  http: ^1.0.0\n');
    write('lib/models/user.dart', 'class User {\n  final String id;\n  final String email;\n  final String? displayName;\n}\n');
    write('lib/models/product.dart', 'class Product {\n  final int id;\n  final String name;\n  final double price;\n  final bool available;\n}\n');
    write('lib/models/order.dart', 'class Order {\n  final int id;\n  final String userId;\n  final List<Product> items;\n  final DateTime createdAt;\n  final User? reviewer;\n}\n');
    write('lib/screens/home_screen.dart', 'class HomeScreen extends StatelessWidget {\n  final String title;\n  final int count;\n}\n');
    write('lib/services/api_service.dart', "final r = await http.get(Uri.parse('https://api.boutique.example/products'));");
    write('.env', 'SECRET=ne-doit-pas-sortir');
    write('build/ignored.dart', 'class Ignored {\n  final int a;\n  final int b;\n}');

    final a = await ProjectAnalyzer(dir.path).run();
    expect(a.technology, 'Flutter');
    expect(a.models.map((m) => m.name), containsAll(['User', 'Product', 'Order']));
    expect(a.models.map((m) => m.name), isNot(contains('HomeScreen')));
    expect(a.models.map((m) => m.name), isNot(contains('Ignored')));
    expect(a.storage.keys, ['shared_preferences']);
    expect(a.apiHosts['api.boutique.example'], 1);
    expect(a.services, contains('lib/services/api_service.dart'));
    expect(a.configs, contains('.env (secret : contenu non lu)'));
    expect(a.toText(), isNot(contains('ne-doit-pas-sortir')));
    expect(a.findings.join(), contains('une vraie base serait plus adaptée'));
    expect(a.findings.join(), contains('aucune authentification'));

    final proposal = ProjectAnalyzer.proposeSchema(a);
    expect(proposal.validate(), isEmpty);
    final order = proposal.entities.firstWhere((e) => e.name == 'Order');
    expect(order.fields.firstWhere((f) => f.name == 'userId').references, 'User');
    expect(order.fields.firstWhere((f) => f.name == 'reviewerId').references, 'User');
    expect(order.fields.any((f) => f.name == 'items'), isFalse);
    expect(order.fields.firstWhere((f) => f.name == 'createdAt').type, SqlColumnType.datetime);
    expect(proposal.summary, contains('Je propose 3 entité(s)'));
    final tables = proposal.toTableDefinitions();
    expect(tables.indexWhere((t) => t.name == 'users'), lessThan(tables.indexWhere((t) => t.name == 'orders')));
  });

  test('Node/Prisma et Django', () async {
    write('package.json', '{"dependencies": {"react": "18", "@prisma/client": "5", "next-auth": "4"}}');
    write('prisma/schema.prisma', 'model Author {\n  id Int @id\n  name String\n  bio String?\n}\n');
    write('back/requirements.txt', 'django==5.0\n');
    write('back/blog/models.py',
        'from django.db import models\n\nclass Article(models.Model):\n    title = models.CharField(max_length=200)\n    published = models.BooleanField(default=False)\n    views = models.IntegerField()\n');
    final a = await ProjectAnalyzer(dir.path).run();
    expect(a.technology, 'Node.js');
    expect(a.frameworks, contains('React'));
    expect(a.storage.values, contains('Prisma'));
    expect(a.auth.values, contains('NextAuth'));
    expect(a.models.map((m) => m.name), containsAll(['Author', 'Article']));
    final article = ProjectAnalyzer.proposeSchema(a).entities.firstWhere((e) => e.name == 'Article');
    expect({for (final f in article.fields) f.name: f.type},
        {'title': SqlColumnType.text, 'published': SqlColumnType.boolean, 'views': SqlColumnType.integer});
  });

  test('proposition de schéma : validation, ordre, cycles, règles Firestore, JSON', () {
    const ok = SchemaProposal(entities: [
      EntityProposal(name: 'OrderItem', fields: [
        FieldProposal(name: 'orderId', type: SqlColumnType.integer, references: 'Order', required: true),
        FieldProposal(name: 'quantity', type: SqlColumnType.integer),
      ]),
      EntityProposal(name: 'Order', fields: [FieldProposal(name: 'ownerId', type: SqlColumnType.text)]),
      EntityProposal(name: 'Category', fields: [FieldProposal(name: 'label', type: SqlColumnType.text)]),
    ]);
    final t = ok.toTableDefinitions();
    expect(t.map((x) => x.name).toList(), ['orders', 'categories', 'order_items']);
    final fk = t.last.columns.firstWhere((c) => c.name == 'order_id').references!;
    expect((fk.table, fk.onDelete), ('orders', 'CASCADE'));
    expect(SchemaProposal.fromJson(ok.toJson()).toJson(), ok.toJson());
    final rules = ok.toCollectionRules();
    expect(rules.firstWhere((r) => r.collection == 'orders').ownerField, 'ownerId');
    expect(ok.describe(), contains('OrderItem est relié(e) à Order'));

    expect(const SchemaProposal(entities: [
      EntityProposal(name: 'A', fields: [FieldProposal(name: 'id', type: SqlColumnType.integer)]),
      EntityProposal(name: 'B b', fields: [FieldProposal(name: 'x', type: SqlColumnType.text, references: 'Zzz')]),
    ]).validate(), hasLength(3));
    expect(
        () => const SchemaProposal(entities: [
              EntityProposal(name: 'A', fields: [FieldProposal(name: 'bId', type: SqlColumnType.integer, references: 'B')]),
              EntityProposal(name: 'B', fields: [FieldProposal(name: 'aId', type: SqlColumnType.integer, references: 'A')]),
            ]).toTableDefinitions(),
        throwsFormatException);
    expect(SchemaProposal.tableName('Category'), 'categories');
    expect(SchemaProposal.tableName('Day'), 'days');
  });

  test('différences de texte', () {
    final d = TextDiff.unified('a\nb\nc\nd', 'a\nB\nc\nd\ne', context: 0);
    expect(d, contains('- b'));
    expect(d, contains('+ B'));
    expect(d, contains('+ e'));
    expect(TextDiff.stats('a\nb', 'a\nc\nd'), (2, 1));
  });
}
