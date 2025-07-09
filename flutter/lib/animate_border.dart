// Place this in a separate file, e.g., 'lib/animated_border_container.dart'
import 'package:flutter/material.dart';
import 'dart:ui'; // Make sure this import is present for PathMetrics

class AnimatedBorderContainer extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Color borderColor;
  final double borderWidth;
  final double borderRadius;
  final Curve curve; // Exposing curve for more control
  final bool animate; // Key property: Controls if the border animation runs

  const AnimatedBorderContainer({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 150), // Shorter duration for disappearance
    this.borderColor = const Color.fromARGB(255, 255, 255, 255),
    this.borderWidth = 4.0,
    this.borderRadius = 0.0,
    this.curve = Curves.easeInCubic,
    this.animate = false, // Default to not animating (border fully present)
  });

  @override
  _AnimatedBorderContainerState createState() => _AnimatedBorderContainerState();
}

class _AnimatedBorderContainerState extends State<AnimatedBorderContainer> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation; // This will still go from 0.0 to 1.0

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    // The animation value goes from 0.0 to 1.0.
    // 0.0 will mean "full border" and 1.0 will mean "no border".
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: widget.curve,
      ),
    )..addListener(() {
      setState(() {});
    });
    if (widget.animate) {
      _controller.forward(); // Start disappearing if animate is true
    } else {
      _controller.value = 0.0; // Ensure it's at the start (full border) if not animating
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedBorderContainer oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Update duration if it changes
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
      // If the animation was running, it will continue with the new duration
    }

    // Update curve if it changes
    if (oldWidget.curve != widget.curve) {
      _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: _controller,
          curve: widget.curve,
        ),
      );
      // If the animation was running, it will continue with the new curve
    }

    // Crucial: Control animation based on the 'animate' property
    if (widget.animate && !_controller.isAnimating) {
      // If `animate` becomes true and it's not already animating,
      // start the animation forward (which will cause it to un-trace).
      // 'from: 0.0' ensures it starts from the state where the border is fully visible.
      _controller.forward(from: 0.0);
    } else if (!widget.animate && _controller.isAnimating) {
      // If `animate` becomes false and it's currently animating,
      // stop it and reset the animation value to 0.0 (full border).
      _controller.stop();
      _controller.value = 0.0;
    } else if (!widget.animate && _controller.value != 0.0) {
      // If `animate` is false and the animation somehow finished (value is 1.0),
      // or is in an intermediate state, reset it to 0.0 to show the full border.
      _controller.value = 0.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // We always use CustomPaint now, because the border is initially present
    // and only disappears when animated. The _BorderPainter will draw it
    // based on _animation.value (0.0 means full, 1.0 means gone).
    return CustomPaint(
      painter: _BorderPainter(
        animationValue: _animation.value, // This goes from 0.0 (full) to 1.0 (gone)
        borderColor: widget.borderColor,
        borderWidth: widget.borderWidth,
        borderRadius: widget.borderRadius,
      ),
      child: widget.child,
    );
  }
}

class _BorderPainter extends CustomPainter {
  final double animationValue; // This goes from 0.0 (full border) to 1.0 (no border)
  final Color borderColor;
  final double borderWidth;
  final double borderRadius;

  _BorderPainter({
    required this.animationValue,
    required this.borderColor,
    required this.borderWidth,
    this.borderRadius = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // If animationValue is 1.0, the border is fully "un-traced" and should not be drawn.
    if (animationValue >= 1.0) {
      return;
    }

    final rRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(borderRadius),
    );
    final path = Path()..addRRect(rRect);

    final Paint paint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeCap = StrokeCap.round;

    final PathMetrics pathMetrics = path.computeMetrics();
    final PathMetric metric = pathMetrics.first;
    final double totalLength = metric.length;

    // Invert the progress for the "un-tracing" effect
    // When animationValue is 0.0, effectiveProgress should be 1.0 (full path)
    // When animationValue is 1.0, effectiveProgress should be 0.0 (empty path)
    final double effectiveProgress = 1.0 - animationValue; // Goes from 1.0 to 0.0

    // For un-tracing from both ends towards the middle:
    final double halfLength = totalLength / 2;
    final double startSegmentEnd = effectiveProgress * halfLength; // Moves from halfLength to 0
    final double endSegmentStart = totalLength - (effectiveProgress * halfLength); // Moves from halfLength to totalLength

    // Path for the left half, shrinking from the end
    final Path path1 = metric.extractPath(0.0, startSegmentEnd);

    // Path for the right half, shrinking from the start
    final Path path2 = metric.extractPath(endSegmentStart, totalLength);

    // Combine them
    final Path combinedPath = Path()
      ..addPath(path1, Offset.zero)
      ..addPath(path2, Offset.zero);

    canvas.drawPath(combinedPath, paint);
  }

  @override
  bool shouldRepaint(_BorderPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
           oldDelegate.borderColor != borderColor ||
           oldDelegate.borderWidth != borderWidth ||
           oldDelegate.borderRadius != borderRadius;
  }
}