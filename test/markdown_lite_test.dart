import 'package:bddouilleur/core/widgets/markdown_lite.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Markdown des réponses : titres, gras, listes, tableau, code', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MarkdownLite('## Les tables\n\nVotre base **#2** contient `essai`.\n\n'
              '- **Client** : nom\n- Facture\n\n| Champ | Type |\n|---|---|\n| `nom` | texte |\n\n```\nClient ──< Facture\n```'),
        ),
      ),
    ));
    expect(find.text('Les tables'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('##'), findsNothing);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Client ──< Facture'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2));
    expect(find.textContaining('|---|'), findsNothing);
  });
}
