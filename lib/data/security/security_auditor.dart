import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/firebase/firestore_rules.dart';
import '../firebase/firebase_diagnostic.dart' show DiagnosticFix, FlutterFirebaseDiagnostic;

enum SecuritySeverity {
  critical('Critique'),
  high('Élevée'),
  medium('Moyenne'),
  low('Faible'),
  info('Information');

  const SecuritySeverity(this.label);
  final String label;
}

enum SecurityCategory {
  credentials('Identifiants exposés'),
  injection('Injection SQL'),
  transport('Connexions non chiffrées'),
  permissions('Permissions excessives'),
  rules('Règles de sécurité'),
  admin('Accès administrateur'),
  environments('Séparation des environnements');

  const SecurityCategory(this.label);
  final String label;
}

class SecurityFinding {
  const SecurityFinding({
    required this.severity,
    required this.category,
    required this.title,
    required this.explanation,
    required this.correction,
    this.location,
    this.fix,
  });

  final SecuritySeverity severity;
  final SecurityCategory category;
  final String title;
  final String explanation;
  final String correction;

  /// fichier:ligne (valeurs secrètes toujours masquées).
  final String? location;
  final DiagnosticFix? fix;

  Map<String, Object?> toJson() => {
        'gravite': severity.label,
        'categorie': category.label,
        'titre': title,
        'explication': explanation,
        'correction': correction,
        'emplacement': ?location,
      };
}

/// Le Gardien : audit de sécurité statique d'un dossier de projet (lecture
/// seule). Les secrets trouvés ne sont jamais affichés en clair.
class SecurityAuditor {
  SecurityAuditor(this.root, {this.maxFiles = 6000, this.maxFileBytes = 1024 * 1024});
  final String root;
  final int maxFiles;
  final int maxFileBytes;

  static const _skipDirs = {
    '.git', 'build', 'node_modules', '.dart_tool', '.idea', '.vscode', '.gradle', 'Pods', 'venv', '.venv', '__pycache__',
    'dist', '.next', '.nuxt', 'coverage', 'target', '.angular', 'vendor', '.fvm', 'ephemeral', '.bddouilleur',
  };
  static const _textExt = {
    '.dart', '.js', '.jsx', '.ts', '.tsx', '.vue', '.py', '.java', '.kt', '.kts', '.gradle', '.xml', '.json', '.yaml', '.yml',
    '.properties', '.sql', '.rules', '.plist', '.toml', '.php', '.rb', '.go', '.sh', '.cfg', '.ini', '.conf', '.swift', '.cs',
  };

  /// Masque une valeur secrète : seuls quelques caractères restent visibles.
  static String mask(String v) {
    if (v.length <= 8) return '••••';
    return '${v.substring(0, 4)}…${v.substring(v.length - 2)} (${v.length} caractères)';
  }

  static final _secretPatterns = <(RegExp, String, SecuritySeverity)>[
    (RegExp(r'AKIA[0-9A-Z]{16}'), 'Clé d\'accès AWS', SecuritySeverity.critical),
    (RegExp(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----'), 'Clé privée', SecuritySeverity.critical),
    (RegExp(r'sk-ant-[A-Za-z0-9_\-]{20,}'), 'Clé API Anthropic', SecuritySeverity.critical),
    (RegExp(r'sk-(?:proj-)?[A-Za-z0-9_\-]{32,}'), 'Clé API OpenAI', SecuritySeverity.critical),
    (RegExp(r'gh[pousr]_[A-Za-z0-9]{36}'), 'Jeton GitHub', SecuritySeverity.critical),
    (RegExp(r'sk_live_[0-9a-zA-Z]{24,}'), 'Clé secrète Stripe', SecuritySeverity.critical),
    (RegExp(r'xox[baprs]-[A-Za-z0-9-]{10,}'), 'Jeton Slack', SecuritySeverity.critical),
    (RegExp(r'GOCSPX-[A-Za-z0-9_\-]{20,}'), 'Secret client OAuth Google', SecuritySeverity.high),
  ];

  static final _connString = RegExp(r'''((?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|amqp)://)([^:\s/'"@]+):([^@\s'"]+)@''');
  static final _password = RegExp(r'''(?:password|passwd|pwd|secret|api_?key)\s*[:=]\s*['"]([^'"\s]{6,})['"]''', caseSensitive: false);
  static final _jwt = RegExp(r'eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}');
  static final _placeholder = RegExp(r'^(password|motdepasse|changeme|secret|xxx+|\*+|your[_-]?\w*|example\w*|test\w*|<.*>|\$\{.*\}|\{\{.*\}\})$', caseSensitive: false);

  static final _injection = <(RegExp, String)>[
    (RegExp(r'''(?:rawQuery|rawInsert|rawUpdate|rawDelete|execute|customSelect|customStatement)\(\s*(['"])[^'"]*\$\{?[A-Za-z_]'''), 'Dart'),
    (RegExp(r'''(?:query|execute|raw|\$queryRawUnsafe|\$executeRawUnsafe|exec)\(\s*`[^`]*\b(?:SELECT|INSERT|UPDATE|DELETE|WHERE)\b[^`]*\$\{''', caseSensitive: false), 'JavaScript'),
    (RegExp(r'''(?:execute|executemany|raw|executescript)\(\s*f(['"])''', caseSensitive: false), 'Python'),
    (RegExp(r'''(?:execute|executemany|raw)\(\s*(['"])[^'"]*\b(?:SELECT|INSERT|UPDATE|DELETE)\b[^'"]*\1\s*(?:%|\.format\(|\+)''', caseSensitive: false), 'Python'),
    (RegExp(r'''(?:createQuery|executeQuery|executeUpdate|prepareStatement|rawQuery|execSQL)\(\s*"[^"]*\b(?:SELECT|INSERT|UPDATE|DELETE|WHERE)\b[^"]*"\s*\+''', caseSensitive: false), 'Java/Kotlin'),
    (RegExp(r'''["'](?:SELECT|INSERT INTO|UPDATE|DELETE FROM)\b[^"']*["']\s*\+\s*[A-Za-z_]''', caseSensitive: false), 'concaténation'),
  ];

  static final _cleartextUrl = RegExp(r'''['"`](http://([A-Za-z0-9.\-]+)(?::\d+)?[^'"`\s]*)['"`]''');

  static bool _isLocalHost(String h) =>
      h == 'localhost' ||
      h.startsWith('127.') ||
      h == '0.0.0.0' ||
      h.startsWith('10.') ||
      h.startsWith('192.168.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(h) ||
      h.endsWith('.local') ||
      h.contains('example') ||
      h.contains('schemas.android.com') ||
      h.contains('www.w3.org') ||
      h.contains('xmlpull.org') ||
      h.contains('apache.org');

  static const _dangerousPermissions = {
    'READ_CONTACTS': SecuritySeverity.low,
    'READ_SMS': SecuritySeverity.medium,
    'SEND_SMS': SecuritySeverity.medium,
    'READ_CALL_LOG': SecuritySeverity.medium,
    'ACCESS_FINE_LOCATION': SecuritySeverity.low,
    'ACCESS_BACKGROUND_LOCATION': SecuritySeverity.medium,
    'RECORD_AUDIO': SecuritySeverity.low,
    'CAMERA': SecuritySeverity.low,
    'READ_PHONE_STATE': SecuritySeverity.low,
    'MANAGE_EXTERNAL_STORAGE': SecuritySeverity.medium,
    'REQUEST_INSTALL_PACKAGES': SecuritySeverity.medium,
    'SYSTEM_ALERT_WINDOW': SecuritySeverity.medium,
  };

  Future<List<SecurityFinding>> run() async {
    final dir = Directory(root);
    if (!dir.existsSync()) throw FileSystemException('Dossier introuvable', root);
    final out = <SecurityFinding>[];
    final files = <File>[];
    _walk(dir, files);
    final isClient = File(p.join(root, 'pubspec.yaml')).existsSync() ||
        _packageDeps().any((d) => const {'react', 'vue', '@angular/core', 'react-native', 'next', 'svelte', 'nuxt'}.contains(d));
    final firebaseProjects = <String>{};
    final createdTables = <String, String>{}; // table → emplacement
    final rlsEnabled = <String>{};

    for (final f in files) {
      final rel = p.relative(f.path, from: root);
      final name = p.basename(rel).toLowerCase();
      final ext = p.extension(name);
      final isEnv = name == '.env' || name.startsWith('.env.');
      if (!_textExt.contains(ext) && !isEnv && name != 'dockerfile') continue;
      if (f.lengthSync() > maxFileBytes) continue;
      String text;
      try {
        text = f.readAsStringSync();
      } catch (_) {
        continue;
      }
      final lines = text.split('\n');
      final isTest = rel.split(p.separator).any((s) => s == 'test' || s == 'tests' || s == '__tests__' || s == 'integration_test');

      // --- Compte de service Google (accès administrateur complet).
      if (ext == '.json' && text.contains('"service_account"') && text.contains('"private_key"')) {
        out.add(SecurityFinding(
          severity: SecuritySeverity.critical,
          category: SecurityCategory.admin,
          title: 'Clé de compte de service Google dans le projet',
          explanation: 'Ce fichier donne un accès ADMINISTRATEUR au projet Google Cloud/Firebase. '
              '${isClient ? 'Embarqué dans une application cliente, n\'importe qui peut l\'extraire.' : 'S\'il est versionné, toute personne ayant accès au dépôt l\'a aussi.'}',
          correction: 'Révoquer cette clé dans la console Google Cloud (IAM → Comptes de service → Clés), la sortir du projet et '
              'utiliser un environnement serveur sécurisé pour les opérations administratives.',
          location: rel,
        ));
        continue;
      }

      for (final (i, line) in lines.indexed) {
        final loc = '$rel:${i + 1}';
        if (line.length > 2000) continue;
        for (final (re, label, sev) in _secretPatterns) {
          for (final m in re.allMatches(line)) {
            out.add(SecurityFinding(
              severity: isTest && sev == SecuritySeverity.critical ? SecuritySeverity.high : sev,
              category: SecurityCategory.credentials,
              title: '$label en clair',
              explanation: 'Valeur trouvée : ${mask(m.group(0)!)}. Toute personne ayant accès au code (ou à l\'application compilée) peut l\'utiliser.',
              correction: 'Révoquer la clé chez le fournisseur, puis la ranger dans un stockage sécurisé ou une variable d\'environnement côté serveur.',
              location: loc,
            ));
          }
        }
        for (final m in _connString.allMatches(line)) {
          if (_placeholder.hasMatch(m.group(3)!)) continue;
          out.add(SecurityFinding(
            severity: isClient ? SecuritySeverity.critical : SecuritySeverity.high,
            category: isClient ? SecurityCategory.admin : SecurityCategory.credentials,
            title: 'Chaîne de connexion avec mot de passe',
            explanation: '${m.group(1)}${m.group(2)}:${mask(m.group(3)!)}@… '
                '${isClient ? 'Une application cliente ne doit jamais se connecter directement à une base avec un compte : '
                    'le mot de passe est extractible.' : 'Le mot de passe est écrit dans le code.'}',
            correction: isClient
                ? 'Passer par une API serveur (ou Firebase/Supabase avec règles de sécurité) ; changer ce mot de passe.'
                : 'Lire la chaîne depuis une variable d\'environnement ; changer ce mot de passe.',
            location: loc,
          ));
        }
        if (!isEnv) {
          for (final m in _password.allMatches(line)) {
            final v = m.group(1)!;
            if (_placeholder.hasMatch(v) || v.startsWith('\$') || line.contains('getenv') || line.contains('process.env')) continue;
            out.add(SecurityFinding(
              severity: isTest ? SecuritySeverity.low : SecuritySeverity.medium,
              category: SecurityCategory.credentials,
              title: 'Mot de passe ou secret écrit dans le code',
              explanation: 'Valeur : ${mask(v)}.',
              correction: 'Utiliser une variable d\'environnement ou un stockage sécurisé.',
              location: loc,
            ));
          }
        }
        for (final m in _jwt.allMatches(line)) {
          final role = _jwtRole(m.group(0)!);
          if (role == 'service_role') {
            out.add(SecurityFinding(
              severity: SecuritySeverity.critical,
              category: SecurityCategory.admin,
              title: 'Clé Supabase « service_role » dans le code',
              explanation: 'Cette clé (${mask(m.group(0)!)}) contourne toutes les politiques RLS : accès administrateur total aux données.',
              correction: 'La régénérer dans Supabase (Settings → API) et n\'utiliser côté client que la clé « anon », protégée par RLS.',
              location: loc,
            ));
          }
        }
        for (final (re, lang) in _injection) {
          if (re.hasMatch(line)) {
            out.add(SecurityFinding(
              severity: isTest ? SecuritySeverity.low : SecuritySeverity.high,
              category: SecurityCategory.injection,
              title: 'Requête SQL construite par concaténation ($lang)',
              explanation: 'Une valeur est insérée directement dans le texte SQL : une saisie malveillante peut modifier la requête.\n${line.trim()}',
              correction: 'Utiliser des requêtes paramétrées (placeholders « ? » ou « \$1 ») et passer les valeurs séparément.',
              location: loc,
            ));
            break;
          }
        }
        for (final m in _cleartextUrl.allMatches(line)) {
          final host = m.group(2)!;
          if (_isLocalHost(host)) continue;
          out.add(SecurityFinding(
            severity: SecuritySeverity.medium,
            category: SecurityCategory.transport,
            title: 'Connexion non chiffrée (http://)',
            explanation: 'Les échanges avec $host circulent en clair : interceptables sur un réseau public.',
            correction: 'Utiliser https://.',
            location: loc,
          ));
        }
        if (RegExp(r'sslmode\s*=\s*disable|ssl\s*[=:]\s*false|tls\s*[=:]\s*false', caseSensitive: false).hasMatch(line)) {
          out.add(SecurityFinding(
            severity: SecuritySeverity.high,
            category: SecurityCategory.transport,
            title: 'Chiffrement de la connexion à la base désactivé',
            explanation: line.trim(),
            correction: 'Activer SSL/TLS (ex. sslmode=require) et vérifier le certificat du serveur.',
            location: loc,
          ));
        }
      }

      // --- Fichiers particuliers.
      if (name == 'androidmanifest.xml') {
        if (text.contains('usesCleartextTraffic="true"')) {
          out.add(SecurityFinding(
            severity: SecuritySeverity.medium,
            category: SecurityCategory.transport,
            title: 'Trafic HTTP en clair autorisé (Android)',
            explanation: 'android:usesCleartextTraffic="true" permet à l\'application de communiquer sans chiffrement.',
            correction: 'Le retirer, ou limiter les exceptions à des hôtes précis avec network_security_config.xml.',
            location: rel,
          ));
        }
        for (final e in _dangerousPermissions.entries) {
          if (text.contains('android.permission.${e.key}"')) {
            out.add(SecurityFinding(
              severity: e.value,
              category: SecurityCategory.permissions,
              title: 'Permission sensible : ${e.key}',
              explanation: 'Cette permission donne accès à des données personnelles ou à des fonctions sensibles : elle doit être indispensable et justifiée (Google Play l\'exige).',
              correction: 'La retirer si l\'application n\'en a pas un besoin essentiel.',
              location: rel,
            ));
          }
        }
      }
      if (name == 'firestore.rules' || ext == '.rules') {
        for (final r in RulesAnalyzer.analyze(text)) {
          out.add(SecurityFinding(
            severity: switch (r.severity) {
              RuleSeverity.critical => SecuritySeverity.critical,
              RuleSeverity.warning => SecuritySeverity.medium,
              RuleSeverity.info => SecuritySeverity.low,
            },
            category: SecurityCategory.rules,
            title: 'Règles Firestore : ${r.title}',
            explanation: r.explanation,
            correction: 'Générer et tester des règles fermées par défaut (Firebase AutoPilot → Règles).',
            location: r.line == null ? rel : '$rel:${r.line}',
          ));
        }
      }
      if (ext == '.sql') {
        for (final m in RegExp(r'create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?', caseSensitive: false).allMatches(text)) {
          createdTables.putIfAbsent(m.group(1)!.toLowerCase(), () => '$rel:${'\n'.allMatches(text.substring(0, m.start)).length + 1}');
        }
        for (final m in RegExp(r'alter\s+table\s+(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?\s+enable\s+row\s+level\s+security', caseSensitive: false).allMatches(text)) {
          rlsEnabled.add(m.group(1)!.toLowerCase());
        }
        for (final m in RegExp(r'create\s+policy[\s\S]*?(?:using|with\s+check)\s*\(\s*true\s*\)', caseSensitive: false).allMatches(text)) {
          out.add(SecurityFinding(
            severity: SecuritySeverity.high,
            category: SecurityCategory.rules,
            title: 'Politique RLS ouverte à tous (« true »)',
            explanation: 'Cette politique autorise toutes les lignes à tout le monde : la RLS ne protège plus rien.',
            correction: 'Restreindre la condition, par exemple « auth.uid() = user_id ».',
            location: '$rel:${'\n'.allMatches(text.substring(0, m.start)).length + 1}',
          ));
        }
      }
      if (name == 'firebase_options.dart' || name == 'google-services.json') {
        for (final m in RegExp(r'''(?:projectId:\s*['"]|"project_id":\s*")([a-z0-9\-]+)''').allMatches(text)) {
          firebaseProjects.add(m.group(1)!);
        }
      }
    }

    // --- Supabase : tables sans RLS (si le projet utilise Supabase).
    final usesSupabase = Directory(p.join(root, 'supabase')).existsSync() ||
        _packageDeps().contains('@supabase/supabase-js') ||
        (File(p.join(root, 'pubspec.yaml')).existsSync() && File(p.join(root, 'pubspec.yaml')).readAsStringSync().contains('supabase_flutter'));
    if (usesSupabase) {
      for (final e in createdTables.entries) {
        if (!rlsEnabled.contains(e.key)) {
          out.add(SecurityFinding(
            severity: SecuritySeverity.high,
            category: SecurityCategory.rules,
            title: 'Table Supabase « ${e.key} » sans RLS',
            explanation: 'Sans Row Level Security, la table est lisible et modifiable par quiconque possède la clé « anon » publique.',
            correction: 'ALTER TABLE ${e.key} ENABLE ROW LEVEL SECURITY; puis créer des politiques restrictives.',
            location: e.value,
          ));
        }
      }
    }

    // --- Accès administrateur depuis une application cliente.
    final deps = _packageDeps();
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (isClient && (deps.contains('firebase-admin') || (pubspec.existsSync() && pubspec.readAsStringSync().contains('firebase_admin')))) {
      out.add(const SecurityFinding(
        severity: SecuritySeverity.critical,
        category: SecurityCategory.admin,
        title: 'SDK d\'administration Firebase dans une application cliente',
        explanation: 'Le SDK Admin contourne les règles de sécurité et suppose des identifiants privilégiés, qui seraient extractibles de l\'application.',
        correction: 'Déplacer ces opérations dans un service serveur (Cloud Functions, API) et n\'utiliser côté client que le SDK client.',
        location: 'dépendances',
      ));
    }

    // --- .env et .gitignore.
    final envFiles = files.where((f) {
      final n = p.basename(f.path).toLowerCase();
      return n == '.env' || (n.startsWith('.env.') && !n.contains('example') && !n.contains('sample'));
    }).toList();
    if (envFiles.isNotEmpty) {
      final gitignore = File(p.join(root, '.gitignore'));
      final ignored = gitignore.existsSync() && RegExp(r'^\s*/?\.env(\*|\.\*)?\s*$', multiLine: true).hasMatch(gitignore.readAsStringSync());
      if (!ignored) {
        out.add(SecurityFinding(
          severity: SecuritySeverity.high,
          category: SecurityCategory.credentials,
          title: 'Fichier de secrets non exclu de git',
          explanation: '${envFiles.map((f) => p.relative(f.path, from: root)).join(', ')} n\'est pas listé dans .gitignore : il risque d\'être publié avec le code.',
          correction: 'Ajouter « .env* » à .gitignore. S\'il a déjà été publié, changer les secrets qu\'il contient.',
          location: '.gitignore',
          fix: DiagnosticFix(
            label: 'Ajouter .env* à .gitignore',
            preview: 'Modifie .gitignore (sauvegarde .bak si le fichier existe) :\n+ .env*\n+ !.env.example',
            apply: () async {
              final current = gitignore.existsSync() ? gitignore.readAsStringSync() : '';
              final sep = current.isEmpty || current.endsWith('\n') ? '' : '\n';
              return FlutterFirebaseDiagnostic.writeWithBackup(
                  gitignore.path, '$current$sep\n# Secrets (ajouté par BDDouilleur)\n.env*\n!.env.example\n');
            },
          ),
        ));
      }
    }

    // --- Séparation des environnements.
    if (firebaseProjects.length == 1) {
      final id = firebaseProjects.single;
      final testsUseIt = files.any((f) {
        final rel = p.relative(f.path, from: root);
        return rel.split(p.separator).any((s) => s == 'test' || s == 'integration_test') &&
            f.lengthSync() < maxFileBytes &&
            (() {
              try {
                return f.readAsStringSync().contains(id);
              } catch (_) {
                return false;
              }
            })();
      });
      out.add(SecurityFinding(
        severity: testsUseIt ? SecuritySeverity.medium : SecuritySeverity.low,
        category: SecurityCategory.environments,
        title: 'Un seul environnement Firebase (« $id »)',
        explanation: testsUseIt
            ? 'Les tests utilisent directement ce projet : ils lisent et écrivent dans les données réelles.'
            : 'Développement, tests et production partagent le même projet : une erreur en développement touche les utilisateurs.',
        correction: 'Créer un projet de développement (ou utiliser les émulateurs Firebase) et des flavors Flutter dev/prod.',
      ));
    }

    out.sort((a, b) => a.severity.index.compareTo(b.severity.index));
    return out;
  }

  static String? _jwtRole(String jwt) {
    try {
      final payload = jwt.split('.')[1];
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))));
      return json is Map ? json['role'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  Set<String> _packageDeps() {
    final f = File(p.join(root, 'package.json'));
    if (!f.existsSync()) return const {};
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map;
      return {for (final k in ['dependencies', 'devDependencies']) ...((j[k] as Map?) ?? const {}).keys.cast<String>()};
    } catch (_) {
      return const {};
    }
  }

  void _walk(Directory dir, List<File> out) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final e in entries) {
      if (out.length >= maxFiles) return;
      final name = p.basename(e.path);
      if (e is Directory) {
        if (_skipDirs.contains(name)) continue;
        _walk(e, out);
      } else if (e is File) {
        out.add(e);
      }
    }
  }
}
