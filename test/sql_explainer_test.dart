import 'package:bddouilleur/domain/sql_explainer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('explique un CREATE TABLE colonne par colonne', () {
    final lines = SqlExplainer.explain('CREATE TABLE "commandes" (\n'
        '  "id" INTEGER PRIMARY KEY AUTOINCREMENT,\n'
        '  "client_id" INTEGER NOT NULL REFERENCES "clients"("id") ON DELETE CASCADE,\n'
        "  \"statut\" TEXT DEFAULT 'en cours, vraiment'\n"
        ');');
    expect(lines.first, contains('« commandes »'));
    expect(lines.length, 4, reason: 'la virgule dans la chaîne ne crée pas de colonne');
    expect(lines[1], allOf(contains('« id »'), contains('clé primaire'), contains('automatiquement')));
    expect(lines[2], allOf(contains('« clients.id »'), contains('CASCADE'), contains('obligatoire')));
    expect(lines[3], contains("'en cours, vraiment'"));
  });

  test('explique les opérations CRUD et la sauvegarde', () {
    expect(SqlExplainer.explain('INSERT INTO "t" ("a") VALUES (?);').join(), contains('injections SQL'));
    expect(SqlExplainer.explain('UPDATE "t" SET "a" = ? WHERE rowid IS ?;').join(), contains('rowid'));
    expect(SqlExplainer.explain('DELETE FROM t').join(), contains('sans WHERE'));
    expect(SqlExplainer.explain("VACUUM INTO '/x.db';").join(), contains('Sauvegarde'));
  });
}
