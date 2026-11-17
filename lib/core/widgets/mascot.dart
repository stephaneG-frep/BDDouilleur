import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// La mascotte : un petit savant fou sympathique, énormes lunettes, blouse,
/// cheveux ébouriffés, clé à molette, entouré de cylindres de bases de données.
class Mascot extends StatefulWidget {
  const Mascot({super.key, this.size = 160, this.animate = true});

  final double size;
  final bool animate;

  @override
  State<Mascot> createState() => _MascotState();
}

class _MascotState extends State<Mascot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 3));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(Mascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final reduce = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    if (widget.animate && !reduce) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Mascotte BDDouilleur, un petit savant fou avec une clé à molette',
      image: true,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(painter: MascotPainter(t: _c.value)),
          ),
        ),
      ),
    );
  }
}

class MascotPainter extends CustomPainter {
  MascotPainter({this.t = 0});

  /// Phase d'animation 0..1.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 200; // dessin sur une grille de 200 x 200
    canvas.save();
    canvas.scale(s);
    final wave = math.sin(t * 2 * math.pi);

    _cylinder(canvas, const Offset(28, 112), 30, 48, BddColors.turquoise, bob: wave * 3);
    _cylinder(canvas, const Offset(172, 118), 26, 40, BddColors.violet, bob: -wave * 3);
    _cylinder(canvas, const Offset(158, 62), 16, 24, BddColors.vert, bob: wave * 2);

    // Bulles du laboratoire.
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1;
      canvas.drawCircle(Offset(30 + i * 6.0, 84 - phase * 40), 2.5 + i.toDouble(),
          Paint()..color = BddColors.turquoise.withValues(alpha: 0.6 * (1 - phase)));
    }

    canvas.save();
    canvas.translate(0, wave * 1.5);
    _body(canvas);
    _head(canvas, wave);
    _wrench(canvas, wave);
    canvas.restore();
    canvas.restore();
  }

  void _cylinder(Canvas c, Offset center, double w, double h, Color color, {double bob = 0}) {
    final cx = center.dx, top = center.dy - h / 2 + bob;
    final rx = w / 2, ry = w / 6;
    final side = Paint()
      ..shader = LinearGradient(colors: [color, Color.lerp(color, BddColors.nuit, 0.45)!])
          .createShader(Rect.fromLTWH(cx - rx, top, w, h));
    final path = Path()
      ..moveTo(cx - rx, top)
      ..lineTo(cx - rx, top + h)
      ..arcTo(Rect.fromCenter(center: Offset(cx, top + h), width: w, height: ry * 2), math.pi, -math.pi, false)
      ..lineTo(cx + rx, top)
      ..close();
    c.drawPath(path, side);
    final ring = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final f in [0.36, 0.68]) {
      c.drawArc(Rect.fromCenter(center: Offset(cx, top + h * f), width: w, height: ry * 2), 0, math.pi, false, ring);
    }
    c.drawOval(Rect.fromCenter(center: Offset(cx, top), width: w, height: ry * 2),
        Paint()..color = Color.lerp(color, Colors.white, 0.35)!);
  }

  void _body(Canvas c) {
    // Blouse de laboratoire.
    final coat = Path()
      ..moveTo(70, 122)
      ..quadraticBezierTo(100, 112, 130, 122)
      ..lineTo(146, 192)
      ..quadraticBezierTo(100, 200, 54, 192)
      ..close();
    c.drawPath(coat, Paint()..color = const Color(0xFFF7F7FB));
    c.drawPath(
        coat,
        Paint()
          ..color = const Color(0xFFB9BCD6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    // Chemise violette et revers.
    final shirt = Path()
      ..moveTo(88, 119)
      ..lineTo(100, 150)
      ..lineTo(112, 119)
      ..close();
    c.drawPath(shirt, Paint()..color = BddColors.violet);
    final lapel = Paint()
      ..color = const Color(0xFFB9BCD6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    c.drawLine(const Offset(88, 119), const Offset(100, 165), lapel);
    c.drawLine(const Offset(112, 119), const Offset(100, 165), lapel);
    // Poche avec stylos.
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(112, 160, 18, 14), const Radius.circular(3)), lapel);
    c.drawLine(const Offset(117, 160), const Offset(117, 153), Paint()..color = BddColors.rose..strokeWidth = 3);
    c.drawLine(const Offset(123, 160), const Offset(123, 155), Paint()..color = BddColors.turquoise..strokeWidth = 3);
  }

  void _head(Canvas c, double wave) {
    const skin = Color(0xFFFFD7B5);
    // Cheveux ébouriffés (derrière la tête).
    final hair = Path();
    const cx = 100.0, cy = 78.0;
    const spikes = 14;
    for (var i = 0; i <= spikes; i++) {
      final a = math.pi + (i / spikes) * math.pi * 1.25 - math.pi * 0.12;
      final r = (i.isEven ? 50.0 : 38.0) + (i % 3 == 0 ? wave * 2 : 0);
      final p = Offset(cx + math.cos(a) * r, cy + math.sin(a) * r * 0.9);
      i == 0 ? hair.moveTo(p.dx, p.dy) : hair.lineTo(p.dx, p.dy);
    }
    hair.close();
    c.drawPath(hair, Paint()..color = const Color(0xFFE9ECF5));
    c.drawPath(
        hair,
        Paint()
          ..color = const Color(0xFFC3C8DA)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);

    // Oreilles et visage.
    c.drawCircle(const Offset(66, 84), 8, Paint()..color = skin);
    c.drawCircle(const Offset(134, 84), 8, Paint()..color = skin);
    c.drawOval(Rect.fromCenter(center: const Offset(cx, 86), width: 68, height: 70), Paint()..color = skin);

    // Sourire et joues.
    c.drawArc(Rect.fromCenter(center: const Offset(cx, 100), width: 26, height: 16), 0.2, math.pi - 0.4, false,
        Paint()
          ..color = const Color(0xFF7A3B2E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
    final cheek = Paint()..color = BddColors.rose.withValues(alpha: 0.35);
    c.drawCircle(const Offset(76, 100), 6, cheek);
    c.drawCircle(const Offset(124, 100), 6, cheek);

    // Énormes lunettes de laboratoire.
    final strap = Paint()
      ..color = BddColors.nuit
      ..strokeWidth = 5;
    c.drawLine(const Offset(62, 76), const Offset(138, 76), strap);
    for (final x in [83.0, 117.0]) {
      final center = Offset(x, 76);
      c.drawCircle(center, 19, Paint()..color = BddColors.orange);
      c.drawCircle(center, 15, Paint()..color = BddColors.nuit);
      c.drawCircle(
          center,
          12.5,
          Paint()
            ..shader = RadialGradient(colors: [
              BddColors.turquoise.withValues(alpha: 0.95),
              const Color(0xFF0E6C87),
            ]).createShader(Rect.fromCircle(center: center, radius: 12.5)));
      // Pupilles agrandies.
      c.drawCircle(center.translate(1, 1), 5, Paint()..color = BddColors.nuit);
      c.drawCircle(center.translate(-1.5, -1.5), 1.8, Paint()..color = Colors.white);
      // Reflet animé.
      final shine = Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      final start = -math.pi * 0.9 + t * 0.6;
      c.drawArc(Rect.fromCircle(center: center, radius: 9), start, 0.9, false, shine);
    }
    c.drawLine(const Offset(98, 76), const Offset(102, 76), Paint()
      ..color = BddColors.orange
      ..strokeWidth = 5);
  }

  void _wrench(Canvas c, double wave) {
    c.save();
    c.translate(150, 150);
    c.rotate(0.35 + wave * 0.12);
    final metal = Paint()
      ..shader = const LinearGradient(colors: [Color(0xFFDDE1EC), Color(0xFF8C93AD)])
          .createShader(const Rect.fromLTWH(-6, -46, 12, 60));
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-5, -40, 10, 52), const Radius.circular(4)), metal);
    c.drawPath(Path.combine(PathOperation.difference, Path()..addOval(Rect.fromCircle(center: const Offset(0, -46), radius: 13)),
        Path()..addRect(const Rect.fromLTWH(-4.5, -62, 9, 16))), metal);
    c.restore();
    // Main.
    c.drawCircle(const Offset(146, 156), 9, Paint()..color = const Color(0xFFFFD7B5));
    c.drawCircle(const Offset(146, 156), 9, Paint()
      ..color = const Color(0xFFE5B48F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(MascotPainter oldDelegate) => oldDelegate.t != t;
}
