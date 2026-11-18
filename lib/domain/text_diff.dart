/// Différence ligne à ligne (plus longue sous-suite commune), pour afficher
/// les modifications de fichiers avant écriture.
enum DiffOp { same, added, removed }

class DiffLine {
  const DiffLine(this.op, this.text);
  final DiffOp op;
  final String text;

  String get prefixed => switch (op) { DiffOp.same => '  $text', DiffOp.added => '+ $text', DiffOp.removed => '- $text' };
}

abstract final class TextDiff {
  /// Au-delà de cette taille, la différence est résumée (coût quadratique).
  static const maxLines = 3000;

  static List<DiffLine> lines(String before, String after) {
    final a = before.isEmpty ? <String>[] : before.split('\n');
    final b = after.isEmpty ? <String>[] : after.split('\n');
    if (a.length > maxLines || b.length > maxLines) {
      return [
        for (final l in a) DiffLine(DiffOp.removed, l),
        for (final l in b) DiffLine(DiffOp.added, l),
      ];
    }
    final n = a.length, m = b.length;
    final lcs = List.generate(n + 1, (_) => List.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
      }
    }
    final out = <DiffLine>[];
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] == b[j]) {
        out.add(DiffLine(DiffOp.same, a[i]));
        i++;
        j++;
      } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
        out.add(DiffLine(DiffOp.removed, a[i++]));
      } else {
        out.add(DiffLine(DiffOp.added, b[j++]));
      }
    }
    while (i < n) {
      out.add(DiffLine(DiffOp.removed, a[i++]));
    }
    while (j < m) {
      out.add(DiffLine(DiffOp.added, b[j++]));
    }
    return out;
  }

  /// Affichage compact : seulement les lignes modifiées et [context] lignes autour.
  static String unified(String before, String after, {int context = 2}) {
    final d = lines(before, after);
    final keep = List.filled(d.length, false);
    for (var k = 0; k < d.length; k++) {
      if (d[k].op != DiffOp.same) {
        for (var c = k - context; c <= k + context; c++) {
          if (c >= 0 && c < d.length) keep[c] = true;
        }
      }
    }
    final b = StringBuffer();
    var skipped = false;
    for (var k = 0; k < d.length; k++) {
      if (keep[k]) {
        b.writeln(d[k].prefixed);
        skipped = false;
      } else if (!skipped) {
        b.writeln('  …');
        skipped = true;
      }
    }
    return b.toString().trimRight();
  }

  static (int added, int removed) stats(String before, String after) {
    final d = lines(before, after);
    return (d.where((l) => l.op == DiffOp.added).length, d.where((l) => l.op == DiffOp.removed).length);
  }
}
