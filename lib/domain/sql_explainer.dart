/// Explique en français une instruction SQL réellement exécutée.
///
/// Explication déterministe fondée sur l'analyse du texte SQL (aucune IA) :
/// elle décrit uniquement ce qui figure dans l'instruction.
class SqlExplainer {
  static final _ident = r'"((?:[^"]|"")+)"|`([^`]+)`|\[([^\]]+)\]|([A-Za-z_][A-Za-z0-9_]*)';

  static String _name(RegExpMatch m, int start) {
    for (var i = start; i < start + 4; i++) {
      final g = m.group(i);
      if (g != null) return g.replaceAll('""', '"');
    }
    return '?';
  }

  static List<String> explain(String sql) {
    final rest = RestExplainer.explain(sql);
    if (rest != null) return rest;
    final s = sql.trim();
    final upper = s.toUpperCase();
    final out = <String>[];

    if (upper.startsWith('CREATE TABLE')) {
      final m = RegExp('CREATE TABLE\\s+(?:IF NOT EXISTS\\s+)?(?:$_ident)', caseSensitive: false).firstMatch(s);
      out.add('Création de la table « ${m == null ? '?' : _name(m, 1)} » : une structure qui range les '
          'données en lignes (enregistrements) et en colonnes (champs).');
      final body = s.contains('(') ? s.substring(s.indexOf('(') + 1, s.lastIndexOf(')')) : '';
      for (final raw in _splitTopLevel(body)) {
        final line = raw.trim();
        final lu = line.toUpperCase();
        if (lu.startsWith('PRIMARY KEY')) {
          out.add('Clé primaire composée ${line.substring(11).trim()} : la combinaison de ces colonnes identifie chaque ligne de façon unique.');
          continue;
        }
        final cm = RegExp('^(?:$_ident)\\s*([A-Za-z]+)?', caseSensitive: false).firstMatch(line);
        if (cm == null) continue;
        final col = _name(cm, 1);
        final type = (cm.group(5) ?? '').toUpperCase();
        final details = <String>[];
        if (type.isNotEmpty) details.add('type $type (${_typeHelp(type)})');
        if (lu.contains('PRIMARY KEY')) details.add('clé primaire : identifie chaque ligne de façon unique');
        if (lu.contains('AUTOINCREMENT')) details.add('numérotée automatiquement, sans jamais réutiliser un ancien numéro');
        if (lu.contains('NOT NULL')) details.add('obligatoire (NOT NULL)');
        if (lu.contains('UNIQUE')) details.add('deux lignes ne peuvent pas avoir la même valeur (UNIQUE)');
        final def = RegExp(r"DEFAULT\s+('(?:[^']|'')*'|[^\s,]+)", caseSensitive: false).firstMatch(line);
        if (def != null) details.add('valeur par défaut ${def.group(1)} si rien n\'est fourni');
        if (lu.contains('CHECK')) details.add('une règle CHECK refuse les valeurs non conformes');
        final ref = RegExp('REFERENCES\\s+(?:$_ident)\\s*\\(\\s*(?:$_ident)\\s*\\)', caseSensitive: false).firstMatch(line);
        if (ref != null) {
          details.add('clé étrangère vers « ${_name(ref, 1)}.${_name(ref, 5)} » : la valeur doit exister dans cette table');
          if (lu.contains('ON DELETE CASCADE')) details.add('si la ligne liée est supprimée, celle-ci l\'est aussi (CASCADE)');
          if (lu.contains('ON DELETE SET NULL')) details.add('si la ligne liée est supprimée, la valeur devient NULL');
          if (lu.contains('ON DELETE RESTRICT')) details.add('empêche de supprimer la ligne liée tant qu\'elle est utilisée');
        }
        out.add('Colonne « $col » : ${details.isEmpty ? 'sans contrainte particulière' : details.join(' ; ')}.');
      }
    } else if (upper.startsWith('INSERT')) {
      final m = RegExp('INSERT\\s+(?:OR\\s+\\w+\\s+)?INTO\\s+(?:$_ident)', caseSensitive: false).firstMatch(s);
      out.add('Ajout d\'un enregistrement dans « ${m == null ? '?' : _name(m, 1)} » (CRUD : Create).');
      if (s.contains('?')) {
        out.add('Les valeurs sont transmises séparément par des paramètres « ? » : c\'est la protection '
            'standard contre les injections SQL.');
      }
      if (upper.contains('DEFAULT VALUES')) out.add('Toutes les colonnes prennent leur valeur par défaut.');
    } else if (upper.startsWith('UPDATE')) {
      final m = RegExp('UPDATE\\s+(?:$_ident)', caseSensitive: false).firstMatch(s);
      out.add('Modification d\'enregistrements existants dans « ${m == null ? '?' : _name(m, 1)} » (CRUD : Update).');
      out.add(upper.contains('WHERE')
          ? 'La clause WHERE limite la modification aux lignes ciblées${upper.contains('ROWID') ? ' (identifiées par leur rowid, le numéro interne de ligne SQLite)' : ''}.'
          : 'Attention : sans WHERE, toutes les lignes de la table sont modifiées.');
    } else if (upper.startsWith('DELETE')) {
      final m = RegExp('DELETE\\s+FROM\\s+(?:$_ident)', caseSensitive: false).firstMatch(s);
      out.add('Suppression d\'enregistrements dans « ${m == null ? '?' : _name(m, 1)} » (CRUD : Delete).');
      out.add(upper.contains('WHERE')
          ? 'Seules les lignes correspondant à la clause WHERE sont supprimées.'
          : 'Attention : sans WHERE, toutes les lignes sont supprimées.');
    } else if (upper.startsWith('SELECT') || upper.startsWith('WITH')) {
      out.add('Lecture de données (CRUD : Read). Une requête SELECT ne modifie rien.');
    } else if (upper.startsWith('DROP TABLE')) {
      out.add('Suppression définitive d\'une table, de sa structure et de toutes ses données.');
    } else if (upper.startsWith('VACUUM INTO')) {
      out.add('Sauvegarde : SQLite écrit une copie complète, cohérente et compactée de la base dans un nouveau fichier.');
    } else if (upper.startsWith('CREATE INDEX') || upper.startsWith('CREATE UNIQUE INDEX')) {
      out.add('Création d\'un index : accélère les recherches et les tris sur les colonnes indexées.');
    } else if (upper.startsWith('ALTER TABLE')) {
      out.add('Modification de la structure d\'une table existante (migration).');
    } else if (upper.startsWith('PRAGMA')) {
      out.add('Instruction PRAGMA : réglage ou interrogation interne propre à SQLite.');
    } else {
      out.add('Instruction SQL exécutée telle que saisie.');
    }
    return out;
  }

  static String _typeHelp(String type) => switch (type) {
        'INTEGER' => 'nombre entier',
        'REAL' => 'nombre à virgule',
        'TEXT' => 'texte',
        'NUMERIC' => 'valeur numérique',
        'BOOLEAN' => 'vrai/faux stocké en 0/1',
        'DATE' => 'date en texte AAAA-MM-JJ',
        'DATETIME' => 'date et heure en texte ISO 8601',
        'BLOB' => 'données binaires',
        _ => 'type déclaré',
      };

  /// Découpe aux virgules de premier niveau (hors parenthèses et chaînes).
  static List<String> _splitTopLevel(String body) {
    final parts = <String>[];
    var depth = 0;
    var inStr = false;
    final buf = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (ch == "'") inStr = !inStr;
      if (!inStr) {
        if (ch == '(') depth++;
        if (ch == ')') depth--;
        if (ch == ',' && depth == 0) {
          parts.add(buf.toString());
          buf.clear();
          continue;
        }
      }
      buf.write(ch);
    }
    if (buf.toString().trim().isNotEmpty) parts.add(buf.toString());
    return parts;
  }
}

/// Explique une requête REST Google/Firebase journalisée (méthode + URL).
abstract final class RestExplainer {
  static final _line = RegExp(r'^(GET|POST|PATCH|PUT|DELETE) (https?://\S+)$');

  static List<String>? explain(String text) {
    final lines = text.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty || !lines.every((l) => _line.hasMatch(l.trim()))) return null;
    if (lines.length > 1) {
      return [
        'Opération composée de ${lines.length} requêtes successives :',
        for (final (i, l) in lines.indexed) ...explainOne(l).skip(1).map((e) => '${i + 1}. $e'),
      ];
    }
    return explainOne(lines.single);
  }

  static List<String> explainOne(String text) {
    final m = _line.firstMatch(text.trim())!;
    final method = m.group(1)!;
    final uri = Uri.parse(m.group(2)!);
    final path = Uri.decodeComponent(uri.path);
    final out = <String>[];
    final emulator = uri.host == '127.0.0.1' || uri.host == 'localhost';
    out.add(emulator
        ? 'Requête envoyée à l\'émulateur local (${uri.host}:${uri.port}) : aucune donnée réelle n\'est touchée.'
        : 'Requête envoyée à l\'API officielle ${uri.host}, avec le jeton OAuth de votre compte (jamais écrit dans le journal).');
    final docs = RegExp(r'/documents/?(.*)$').firstMatch(path);
    if (path.contains(':securityRules')) {
      out.add('Remplacement des règles de sécurité de l\'émulateur par celles que vous avez validées.');
    } else if (docs != null && !path.contains(':listCollectionIds')) {
      final target = docs.group(1)!;
      final isDoc = target.isNotEmpty && target.split('/').length.isEven;
      out.add(switch (method) {
        'GET' => isDoc ? 'Lecture du document « $target ».' : 'Lecture des documents de la collection « $target ».',
        'POST' => 'Création d\'un document dans la collection « $target »'
            '${uri.queryParameters['documentId'] == null ? ' (identifiant généré par Firestore)' : ' avec l\'identifiant « ${uri.queryParameters['documentId']} »'}. '
            'Si la collection n\'existait pas, elle apparaît avec ce premier document : Firestore ne crée jamais de collection vide.',
        'PATCH' => uri.queryParameters['currentDocument.exists'] == 'true'
            ? 'Remplacement du contenu du document « $target » (refusé s\'il n\'existe pas).'
            : 'Écriture du document « $target » (créé s\'il n\'existe pas).',
        'DELETE' => 'Suppression du document « $target ». Ses sous-collections éventuelles ne sont pas supprimées.',
        _ => 'Opération $method sur « $target ».',
      });
    } else if (path.contains('/rulesets')) {
      out.add('Envoi d\'un nouveau jeu de règles : Google le compile et refuse les règles invalides.');
    } else if (path.contains('/releases')) {
      out.add('Publication du jeu de règles : il devient actif pour toutes les applications clientes.');
    } else if (path.endsWith(':test')) {
      out.add('Test des règles par Google, sans lire ni écrire aucune donnée.');
    } else if (path.contains('/indexes')) {
      out.add(method == 'DELETE'
          ? 'Suppression d\'un index composite : les requêtes qui en dépendaient échoueront.'
          : 'Création d\'un index composite : il permet les requêtes combinant filtres et tris sur plusieurs champs.');
    } else if (path.contains(':addFirebase')) {
      out.add('Ajout de Firebase à un projet Google Cloud existant (plan Spark, gratuit).');
    } else if (path.contains('/androidApps')) {
      out.add('Enregistrement d\'une application Android dans Firebase, identifiée par son nom de paquet.');
    } else if (path.contains(':enable')) {
      out.add('Activation d\'une API Google sur le projet.');
    } else if (path.contains('/databases') && method == 'POST') {
      out.add('Création de la base Firestore, dans une région qui ne pourra plus être modifiée.');
    } else if (uri.host.startsWith('cloudresourcemanager') && method == 'POST') {
      out.add('Création d\'un projet Google Cloud.');
    } else if (path.contains('/config')) {
      out.add('Modification de la configuration de Firebase Authentication (fournisseurs de connexion, protections).');
    } else {
      out.add('Opération $method sur $path.');
    }
    return out;
  }
}
