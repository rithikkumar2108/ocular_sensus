import 'package:flutter/material.dart';
import 'dart:ui'; // Make sure this import is present for PathMetrics


class AnimatedBorderContainer extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Color borderColor;
  final double borderWidth;
  final double borderRadius; // New property for border radius

  const AnimatedBorderContainer({
    super.key,
    required this.child,
    this.duration = const Duration(seconds: 2),
    this.borderColor = Colors.blue,
    this.borderWidth = 9.0,
    this.borderRadius = 5.0, // Default to no radius
  });

  @override
  _AnimatedBorderContainerState createState() => _AnimatedBorderContainerState();
}

class _AnimatedBorderContainerState extends State<AnimatedBorderContainer> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        // *** CHANGE HERE: Starts slow, speeds up in the middle ***
        curve: Curves.linear, // Or Curves.easeOutCubic, Curves.easeOutExpo, etc.
      ),
    )..addListener(() {
        setState(() {});
      });

    _controller.repeat(reverse: false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BorderPainter(
        animationValue: _animation.value,
        borderColor: widget.borderColor,
        borderWidth: widget.borderWidth,
        borderRadius: widget.borderRadius, // Pass the new radius
      ),
      child: widget.child,
    );
  }
}

class _BorderPainter extends CustomPainter {
  final double animationValue; // 0.0 to 1.0
  final Color borderColor;
  final double borderWidth;
  final double borderRadius; // New property for border radius

  _BorderPainter({
    required this.animationValue,
    required this.borderColor,
    required this.borderWidth,
    this.borderRadius = 0.0, // Default to 0 if not provided
  });

  @override
  void paint(Canvas canvas, Size size) {
    // *** CHANGE HERE: Use RRect for rounded rectangle path ***
    final rRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(borderRadius),
    );
    final path = Path()..addRRect(rRect);

    final Paint paint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeCap = StrokeCap.round; // StrokeCap.round gives nice rounded ends to the tracing line

    final PathMetrics pathMetrics = path.computeMetrics();
    final PathMetric metric = pathMetrics.first;
    final double totalLength = metric.length;

    Path? drawnPath;

    if (animationValue <= 0.5) {
      // Drawing phase (0.0 to 0.5)
      final double progress = animationValue * 2; // Normalize to 0.0 - 1.0 for drawing
      drawnPath = metric.extractPath(0.0, totalLength * progress);
    } else {
      // Erase phase (0.5 to 1.0)
      final double progress = (animationValue - 0.5) * 2; // Normalize to 0.0 - 1.0 for erasing
      drawnPath = metric.extractPath(totalLength * progress, totalLength);
    }

    canvas.drawPath(drawnPath, paint);
    }

  @override
  bool shouldRepaint(_BorderPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
           oldDelegate.borderColor != borderColor || // Repaint if color changes
           oldDelegate.borderWidth != borderWidth || // Repaint if width changes
           oldDelegate.borderRadius != borderRadius; // Repaint if radius changes
  }
}