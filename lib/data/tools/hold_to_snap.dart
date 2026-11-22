import 'dart:async';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:one_dollar_unistroke_recognizer/one_dollar_unistroke_recognizer.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_circle_stroke.dart';
import 'package:saber/components/canvas/_rectangle_stroke.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';

/// Saber Fork: "hold to snap" shape recognition for the normal pens.
///
/// While drawing with a fountain pen, ballpoint pen or pencil, the user can
/// keep the stylus still at the end of a stroke. After [holdDuration] a shape
/// is recognized and shown as a preview ([preview]). When the stylus is
/// lifted, the stroke is replaced by the shape. Moving the stylus again
/// discards the preview.
///
/// Shapes are only stored as existing stroke types
/// ([Stroke], [RectangleStroke], [CircleStroke]), so the file format is
/// unchanged and notes stay readable in the original Saber.
abstract class HoldToSnap {
  static final log = Logger('HoldToSnap');

  /// How far (in logical screen pixels) the stylus may move while holding.
  static const holdRadiusScreenPixels = 4.0;

  /// Minimum number of points of a stroke (excluding hold jitter).
  static const minPoints = 10;

  /// Minimum size (longest side of the bounding box, in page units) of a
  /// stroke to be converted. A page is 1000 units wide, so this is ~6% of the
  /// page width, i.e. bigger than normal handwriting.
  static const minSize = 60.0;

  /// Minimum score of the $1 recognizer.
  static const minScore = 0.75;

  /// Rectangles whose sides differ by at most this fraction become squares.
  static const squareTolerance = 0.12;

  /// The currently previewed shape, or null.
  static SnapShape? get preview => _preview;
  static SnapShape? _preview;

  /// Whether the last stroke returned by [Pen.onDragEnd] was snapped.
  static var lastStrokeWasSnapped = false;

  static Timer? _timer;
  static Offset? _anchor;
  static double _scale = 1;
  static VoidCallback? _onPreviewChanged;

  static bool get isEnabled => stows.holdToSnapEnabled.value;

  static Duration get holdDuration {
    final ms = stows.holdToSnapDelay.value;
    return Duration(milliseconds: ms.clamp(100, 5000));
  }

  /// Sets the current zoom [scale] (so the hold radius is independent of the
  /// zoom level) and a callback to repaint when the preview changes.
  static void configure({
    required double scale,
    required VoidCallback? onPreviewChanged,
  }) {
    _scale = scale > 0 && scale.isFinite ? scale : 1;
    _onPreviewChanged = onPreviewChanged;
  }

  /// Called when a new stroke starts.
  static void reset() {
    _timer?.cancel();
    _timer = null;
    _anchor = null;
    _preview = null;
  }

  /// Called for every new point of [stroke].
  static void onPoint(Stroke stroke, Offset position) {
    if (!isEnabled) return;

    final radius = holdRadiusScreenPixels / _scale;
    final anchor = _anchor;
    if (anchor != null && (position - anchor).distance <= radius) {
      // Still holding: let the timer run.
      return;
    }

    // Moved: restart the hold timer and discard any preview.
    _anchor = position;
    _timer?.cancel();
    if (_preview != null) {
      _preview = null;
      _onPreviewChanged?.call();
    }
    _timer = Timer(holdDuration, () {
      _timer = null;
      if (!identical(Pen.currentStroke, stroke)) return;
      _preview = detect(stroke);
      if (_preview != null) {
        log.info('Hold detected ${_preview.runtimeType}');
        _onPreviewChanged?.call();
      }
    });
  }

  /// Called when the stroke ends. Returns the previewed shape (if any)
  /// and resets the state.
  static SnapShape? finish() {
    final shape = _preview;
    reset();
    return shape;
  }

  /// Recognizes a shape in [stroke], or returns null if the stroke is
  /// too small, too short or not a supported shape.
  @visibleForTesting
  static SnapShape? detect(Stroke stroke) {
    final points = stroke.pointsView;
    if (points.length < minPoints) return null;

    final bounds = _boundingBox(points);
    if (max(bounds.width, bounds.height) < minSize) return null;

    final RecognizedUnistroke? recognized;
    try {
      recognized = stroke.detectShape();
    } catch (e) {
      log.warning('Shape recognition failed: $e');
      return null;
    }
    if (recognized == null || recognized.score < minScore) return null;

    switch (recognized.name) {
      case DefaultUnistrokeNames.line:
        final (a, b) = Stroke.snapLine(points.first, points.last);
        if ((b - a).distance < minSize) return null;
        return SnapLine(a, b);
      case DefaultUnistrokeNames.rectangle:
        return SnapRect(squarify(recognized.convertToRect()));
      case DefaultUnistrokeNames.circle:
        final (center, radius) = recognized.convertToCircle();
        return SnapCircle(center, radius);
      case DefaultUnistrokeNames.triangle:
        final polygon = recognized.convertToCanonicalPolygon();
        if (polygon.length < 3) return null;
        return SnapPolygon(polygon);
      case DefaultUnistrokeNames.star:
      case null:
        return null;
    }
  }

  /// Turns [rect] into a square if its sides differ by at most
  /// [squareTolerance].
  @visibleForTesting
  static Rect squarify(Rect rect) {
    final longer = max(rect.width, rect.height);
    final shorter = min(rect.width, rect.height);
    if (longer <= 0) return rect;
    if ((longer - shorter) / longer > squareTolerance) return rect;
    final side = (rect.width + rect.height) / 2;
    return Rect.fromCenter(center: rect.center, width: side, height: side);
  }

  static Rect _boundingBox(List<Offset> points) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in points) {
      minX = min(minX, p.dx);
      minY = min(minY, p.dy);
      maxX = max(maxX, p.dx);
      maxY = max(maxY, p.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Options for polygon strokes: no smoothing/tapering so corners stay sharp.
  static StrokeOptions _polygonOptions(Stroke raw) =>
      Pen.shapePenOptions.copyWith(size: raw.options.size, isComplete: true);
}

/// A recognized shape, see [HoldToSnap].
sealed class SnapShape {
  const new();

  /// Converts the freehand [raw] stroke into the snapped stroke.
  Stroke toStroke(Stroke raw);

  /// Draws the preview.
  void paint(Canvas canvas, Paint paint);
}

class SnapLine extends SnapShape {
  const new(this.start, this.end);
  final PointVector start, end;

  @override
  Stroke toStroke(Stroke raw) {
    // Same as the existing "auto straighten lines" conversion:
    // a normal stroke with the same tool, color and options.
    return raw..convertToLine();
  }

  @override
  void paint(Canvas canvas, Paint paint) => canvas.drawLine(start, end, paint);
}

class SnapRect extends SnapShape {
  const new(this.rect);
  final Rect rect;

  @override
  Stroke toStroke(Stroke raw) => RectangleStroke(
    color: raw.color,
    pressureEnabled: false,
    options: HoldToSnap._polygonOptions(raw),
    pageIndex: raw.pageIndex,
    page: raw.page,
    // RectangleStroke doesn't store its tool, it is always loaded as a
    // shape pen stroke. Use that here too, so it looks the same after
    // reopening the note.
    toolId: .shapePen,
    rect: rect,
  );

  @override
  void paint(Canvas canvas, Paint paint) => canvas.drawRect(rect, paint);
}

class SnapCircle extends SnapShape {
  const new(this.center, this.radius);
  final Offset center;
  final double radius;

  @override
  Stroke toStroke(Stroke raw) => CircleStroke(
    color: raw.color,
    pressureEnabled: false,
    options: HoldToSnap._polygonOptions(raw),
    pageIndex: raw.pageIndex,
    page: raw.page,
    // See [SnapRect.toStroke].
    toolId: .shapePen,
    center: center,
    radius: radius,
  );

  @override
  void paint(Canvas canvas, Paint paint) =>
      canvas.drawCircle(center, radius, paint);
}

class SnapPolygon extends SnapShape {
  new(List<Offset> vertices) : vertices = List.unmodifiable(vertices);
  final List<Offset> vertices;

  /// Distance between sampled points along the edges, in page units.
  static const sampleSpacing = 4.0;

  /// The closed outline, densely sampled along each edge.
  List<Offset> get sampledOutline {
    final result = <Offset>[];
    for (var i = 0; i < vertices.length; i++) {
      final a = vertices[i];
      final b = vertices[(i + 1) % vertices.length];
      final steps = max(1, ((b - a).distance / sampleSpacing).ceil());
      for (var s = 0; s < steps; s++) {
        result.add(Offset.lerp(a, b, s / steps)!);
      }
    }
    result.add(vertices.first);
    return result;
  }

  @override
  Stroke toStroke(Stroke raw) => Stroke(
    color: raw.color,
    pressureEnabled: false,
    options: HoldToSnap._polygonOptions(raw),
    pageIndex: raw.pageIndex,
    page: raw.page,
    toolId: raw.toolId,
  )..addPoints(sampledOutline);

  @override
  void paint(Canvas canvas, Paint paint) =>
      canvas.drawPath(Path()..addPolygon(vertices, true), paint);
}
