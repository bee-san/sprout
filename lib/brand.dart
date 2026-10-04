import 'package:flutter/material.dart';

class SproutMark extends StatelessWidget {
  const SproutMark({super.key, this.size = 48});
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Sprout',
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _SproutPainter()),
    ),
  );
}

class _SproutPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100, size.height / 100);
    final stem = Paint()
      ..color = const Color(0xFF355E49)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(50, 67)
        ..quadraticBezierTo(51, 42, 62, 26),
      stem,
    );
    canvas.drawPath(
      Path()
        ..moveTo(52, 47)
        ..lineTo(34, 34),
      stem,
    );
    canvas.drawPath(
      Path()
        ..moveTo(51, 43)
        ..cubicTo(49, 18, 70, 13, 83, 15)
        ..cubicTo(82, 34, 71, 48, 51, 43),
      Paint()..color = const Color(0xFF74966F),
    );
    canvas.drawPath(
      Path()
        ..moveTo(48, 43)
        ..cubicTo(26, 46, 17, 29, 18, 19)
        ..cubicTo(36, 18, 51, 28, 48, 43),
      Paint()..color = const Color(0xFFA9BC89),
    );
    canvas.drawPath(
      Path()
        ..moveTo(28, 62)
        ..lineTo(72, 62)
        ..lineTo(67, 87)
        ..quadraticBezierTo(50, 95, 33, 87)
        ..close(),
      Paint()..color = const Color(0xFFD6A18A),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(24, 59, 52, 9),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFFC38770),
    );
    final face = Paint()
      ..color = const Color(0xFF4F3D33)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(const Offset(42, 77), 1, face);
    canvas.drawCircle(const Offset(58, 77), 1, face);
    canvas.drawPath(
      Path()
        ..moveTo(46, 80)
        ..quadraticBezierTo(50, 84, 54, 80),
      face,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
