import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Rendu Markdown minimal et sûr (aucun lien ni image chargés) pour les
/// réponses des modèles : titres, listes, blocs de code, tableaux, **gras**,
/// *italique* et `code`.
class MarkdownLite extends StatelessWidget {
  const MarkdownLite(this.text, {super.key});
  final String text;

  static final _inline = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?!\*)');

  static List<InlineSpan> inline(String s, TextStyle base, Color codeBg) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _inline.allMatches(s)) {
      if (m.start > last) spans.add(TextSpan(text: s.substring(last, m.start)));
      if (m.group(1) != null) {
        spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (m.group(2) != null) {
        spans.add(TextSpan(text: m.group(2), style: AppTheme.mono.copyWith(fontSize: (base.fontSize ?? 14) - 1, backgroundColor: codeBg)));
      } else {
        spans.add(TextSpan(text: m.group(3), style: const TextStyle(fontStyle: FontStyle.italic)));
      }
      last = m.end;
    }
    if (last < s.length) spans.add(TextSpan(text: s.substring(last)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium!;
    final codeBg = theme.colorScheme.surfaceContainerHighest;
    final blocks = <Widget>[];
    final lines = text.replaceAll('\r', '').split('\n');
    var i = 0;
    Widget para(String s, {TextStyle? style, EdgeInsets padding = const EdgeInsets.only(bottom: 6)}) => Padding(
          padding: padding,
          child: SelectableText.rich(TextSpan(style: style ?? base, children: inline(s, style ?? base, codeBg))),
        );
    while (i < lines.length) {
      final line = lines[i];
      final t = line.trim();
      if (t.startsWith('```')) {
        final code = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          code.add(lines[i++]);
        }
        i++;
        blocks.add(Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: codeBg, borderRadius: BorderRadius.circular(8)),
          child: SelectableText(code.join('\n'), style: AppTheme.mono.copyWith(color: theme.colorScheme.onSurface)),
        ));
        continue;
      }
      if (t.startsWith('|')) {
        final rows = <List<String>>[];
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          final cells = lines[i].trim().replaceAll(RegExp(r'^\||\|$'), '').split('|').map((c) => c.trim()).toList();
          if (!cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c))) rows.add(cells);
          i++;
        }
        final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(color: theme.colorScheme.outlineVariant),
              children: [
                for (final (ri, r) in rows.indexed)
                  TableRow(children: [
                    for (var c = 0; c < width; c++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Text.rich(TextSpan(
                            style: ri == 0 ? base.copyWith(fontWeight: FontWeight.w700) : base,
                            children: inline(c < r.length ? r[c] : '', base, codeBg))),
                      ),
                  ]),
              ],
            ),
          ),
        ));
        continue;
      }
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(t);
      if (h != null) {
        final level = h.group(1)!.length;
        final style = (level <= 2 ? theme.textTheme.titleMedium : theme.textTheme.titleSmall)!.copyWith(fontWeight: FontWeight.w700);
        blocks.add(para(h.group(2)!, style: style, padding: const EdgeInsets.only(top: 6, bottom: 4)));
        i++;
        continue;
      }
      final bullet = RegExp(r'^(\s*)([-*•]|\d+[.)])\s+(.*)$').firstMatch(line);
      if (bullet != null) {
        final indent = bullet.group(1)!.length ~/ 2;
        final marker = RegExp(r'\d').hasMatch(bullet.group(2)!) ? bullet.group(2)! : '•';
        blocks.add(Padding(
          padding: EdgeInsets.only(left: 8.0 + indent * 16, bottom: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 22, child: Text(marker, style: base)),
            Expanded(child: SelectableText.rich(TextSpan(style: base, children: inline(bullet.group(3)!, base, codeBg)))),
          ]),
        ));
        i++;
        continue;
      }
      if (t.isEmpty) {
        i++;
        continue;
      }
      final buf = <String>[t];
      i++;
      while (i < lines.length) {
        final n = lines[i].trim();
        if (n.isEmpty || n.startsWith('```') || n.startsWith('|') || n.startsWith('#') || RegExp(r'^([-*•]|\d+[.)])\s').hasMatch(n)) break;
        buf.add(n);
        i++;
      }
      blocks.add(para(buf.join('\n')));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks);
  }
}
