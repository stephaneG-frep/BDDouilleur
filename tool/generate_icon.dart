// Génère l'icône de l'application à partir de la mascotte.
// Usage : flutter test tool/generate_icon.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bddouilleur/core/theme/app_theme.dart';
import 'package:bddouilleur/core/widgets/mascot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('icône', (tester) async {
    await tester.runAsync(() async {
      const size = 1024.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final rect = const Rect.fromLTWH(0, 0, size, size);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(220)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [BddColors.nuit, Color(0xFF2B1F66)],
          ).createShader(rect),
      );
      canvas.save();
      canvas.translate(size * 0.06, size * 0.04);
      MascotPainter(t: 0.1).paint(canvas, const Size(size * 0.88, size * 0.88));
      canvas.restore();
      final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('assets/icon/icon_1024.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
