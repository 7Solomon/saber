// Saber Fork: tests for "hold to snap" (phase 2a).

import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_circle_stroke.dart';
import 'package:saber/components/canvas/_rectangle_stroke.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/hold_to_snap.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:sbn/has_size.dart';

import 'utils/test_mock_channel_handlers.dart';

const _page = HasSize(EditorPage.defaultSize);

List<Offset> _circle(Offset c, double r, {int n = 64}) => [
  for (var i = 0; i <= n; i++)
    c + Offset(r * cos(2 * pi * i / n), r * sin(2 * pi * i / n)),
];

List<Offset> _polyline(List<Offset> corners, {double spacing = 5}) {
  final result = <Offset>[];
  for (var i = 0; i < corners.length - 1; i++) {
    final a = corners[i], b = corners[i + 1];
    final steps = max(1, ((b - a).distance / spacing).ceil());
    for (var s = 0; s < steps; s++) {
      result.add(Offset.lerp(a, b, s / steps)!);
    }
  }
  result.add(corners.last);
  return result;
}

List<Offset> _rect(Rect r) =>
    _polyline([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft]);

Stroke _stroke(List<Offset> points) => Stroke(
  color: const Color(0xFF000000),
  pressureEnabled: false,
  options: Pen.defaultOptions.copyWith(),
  pageIndex: 0,
  page: _page,
  toolId: .fountainPen,
)..addPoints(points);

/// Handwriting-sized glyphs (a line is ~40 units high on a 1000 unit page).
final Map<String, List<Offset>> _handwriting = {
  'o': _circle(const Offset(100, 100), 12),
  'O (capital)': _circle(const Offset(100, 100), 18),
  '0 (digit)': [
    for (var i = 0; i <= 48; i++)
      Offset(100 + 10 * cos(2 * pi * i / 48), 100 + 18 * sin(2 * pi * i / 48)),
  ],
  'l': _polyline([const Offset(100, 60), const Offset(102, 100)]),
  '1': _polyline([
    const Offset(95, 70),
    const Offset(105, 60),
    const Offset(105, 100),
  ]),
  'check mark': _polyline([
    const Offset(100, 100),
    const Offset(110, 112),
    const Offset(135, 80),
  ]),
  'dash': _polyline([const Offset(100, 100), const Offset(125, 100)]),
  'D': _polyline([
    const Offset(100, 60),
    const Offset(100, 100),
    const Offset(115, 95),
    const Offset(122, 80),
    const Offset(115, 65),
    const Offset(100, 60),
  ]),
  'triangle-like A': _polyline([
    const Offset(100, 100),
    const Offset(112, 60),
    const Offset(124, 100),
    const Offset(100, 100),
  ]),
  'box-like small square': _rect(const Rect.fromLTWH(100, 100, 30, 30)),
  'w': _polyline([
    const Offset(100, 80),
    const Offset(107, 100),
    const Offset(114, 85),
    const Offset(121, 100),
    const Offset(128, 80),
  ]),
  'dot': [for (var i = 0; i < 20; i++) Offset(100 + i * 0.1, 100)],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  setUp(() {
    stows.holdToSnapEnabled.value = true;
    stows.holdToSnapDelay.value = 500;
    HoldToSnap.reset();
    HoldToSnap.configure(scale: 1, onPreviewChanged: null);
  });

  group('HoldToSnap.detect', () {
    test('circle', () {
      final shape = HoldToSnap.detect(
        _stroke(_circle(const Offset(300, 300), 100)),
      );
      expect(shape, isA<SnapCircle>());
      shape as SnapCircle;
      expect(shape.center.dx, closeTo(300, 3));
      expect(shape.center.dy, closeTo(300, 3));
      expect(shape.radius, closeTo(100, 3));
    });

    test('rectangle', () {
      final shape = HoldToSnap.detect(
        _stroke(_rect(const Rect.fromLTWH(100, 100, 300, 150))),
      );
      expect(shape, isA<SnapRect>());
      shape as SnapRect;
      expect(shape.rect.width, closeTo(300, 3));
      expect(shape.rect.height, closeTo(150, 3));
    });

    test('almost square rectangle becomes a square', () {
      final shape = HoldToSnap.detect(
        _stroke(_rect(const Rect.fromLTWH(100, 100, 200, 185))),
      );
      expect(shape, isA<SnapRect>());
      shape as SnapRect;
      expect(shape.rect.width, closeTo(shape.rect.height, 1e-9));
      expect(shape.rect.width, closeTo(192.5, 3));
    });

    test('squarify tolerance is 12%', () {
      final square = HoldToSnap.squarify(const Rect.fromLTWH(0, 0, 100, 89));
      expect(square.width, square.height);
      final notSquare = HoldToSnap.squarify(const Rect.fromLTWH(0, 0, 100, 87));
      expect(notSquare, const Rect.fromLTWH(0, 0, 100, 87));
    });

    test('line (snapped to horizontal)', () {
      final shape = HoldToSnap.detect(
        _stroke(_polyline([const Offset(100, 200), const Offset(400, 205)])),
      );
      expect(shape, isA<SnapLine>());
      shape as SnapLine;
      expect(shape.start.dy, shape.end.dy);
    });

    test('triangle', () {
      final shape = HoldToSnap.detect(
        _stroke(
          _polyline([
            const Offset(200, 100),
            const Offset(300, 280),
            const Offset(100, 280),
            const Offset(200, 100),
          ]),
        ),
      );
      expect(shape, isA<SnapPolygon>());
      expect((shape as SnapPolygon).vertices.length, greaterThanOrEqualTo(3));
    });

    test('resample', () {
      final points = [Offset.zero, const Offset(100, 0)];
      final resampled = HoldToSnap.resample(points, 11);
      expect(resampled.length, 11);
      expect(resampled.first, Offset.zero);
      expect(resampled.last.dx, closeTo(100, 1e-9));
      expect(resampled[5].dx, closeTo(50, 1e-9));
      final many = List.generate(200, (i) => Offset(i.toDouble(), 0));
      expect(HoldToSnap.resample(many, 96), same(many));
    });

    test('quickly drawn line with few points', () {
      final shape = HoldToSnap.detect(
        _stroke(
          _polyline([
            const Offset(100, 200),
            const Offset(400, 260),
          ], spacing: 25),
        ),
      );
      expect(shape, isA<SnapLine>());
    });

    test('exactly closed shapes are never lines', () {
      final shape = HoldToSnap.detect(
        _stroke(_rect(const Rect.fromLTWH(100, 100, 200, 200))),
      );
      expect(shape, isA<SnapRect>());
    });

    test('too few points', () {
      expect(
        HoldToSnap.detect(_stroke([Offset.zero, const Offset(300, 0)])),
        isNull,
      );
    });

    for (final MapEntry(key: name, value: points) in _handwriting.entries) {
      test('handwriting is never converted: $name', () {
        expect(HoldToSnap.detect(_stroke(points)), isNull);
      });
    }
  });

  group('Pen with hold to snap', () {
    final page = EditorPage();

    /// Draws [points]; if [holdFor] is given, the stylus is held still
    /// (with tiny jitter) at the last point for that long.
    Future<Stroke?> draw(
      WidgetTester tester,
      Pen pen,
      List<Offset> points, {
      Duration? holdFor,
      List<Offset> afterHold = const [],
    }) async {
      pen.onDragStart(points.first, page, 0, null);
      for (final p in points.skip(1)) {
        pen.onDragUpdate(p, null);
        await tester.pump(const Duration(milliseconds: 8));
      }
      if (holdFor != null) {
        final end = points.last;
        final steps = holdFor.inMilliseconds ~/ 20;
        for (var i = 0; i < steps; i++) {
          // jitter < hold radius
          pen.onDragUpdate(end + Offset(i.isEven ? 1 : -1, 0), null);
          await tester.pump(const Duration(milliseconds: 20));
        }
      }
      for (final p in afterHold) {
        pen.onDragUpdate(p, null);
        await tester.pump(const Duration(milliseconds: 8));
      }
      return pen.onDragEnd();
    }

    final circle = _circle(const Offset(300, 300), 100);

    testWidgets('without holding nothing changes', (tester) async {
      final pen = Pen.fountainPen();
      final stroke = await draw(tester, pen, circle);
      expect(stroke.runtimeType, Stroke);
      expect(stroke!.length, circle.length);
      expect(HoldToSnap.lastStrokeWasSnapped, isFalse);
    });

    testWidgets('holding shows a preview and snaps on lift', (tester) async {
      var previewChanges = 0;
      HoldToSnap.configure(scale: 1, onPreviewChanged: () => previewChanges++);
      final pen = Pen.fountainPen();
      pen.onDragStart(circle.first, page, 0, null);
      for (final p in circle.skip(1)) pen.onDragUpdate(p, null);
      expect(HoldToSnap.preview, isNull);
      await tester.pump(const Duration(milliseconds: 600));
      expect(HoldToSnap.preview, isA<SnapCircle>());
      expect(previewChanges, 1);

      final stroke = pen.onDragEnd();
      expect(stroke, isA<CircleStroke>());
      expect(HoldToSnap.lastStrokeWasSnapped, isTrue);
      expect(HoldToSnap.preview, isNull);
    });

    testWidgets('holding shorter than the delay does nothing', (tester) async {
      final stroke = await draw(
        tester,
        Pen.fountainPen(),
        circle,
        holdFor: const Duration(milliseconds: 300),
      );
      expect(stroke.runtimeType, Stroke);
    });

    testWidgets('hold delay setting is respected', (tester) async {
      stows.holdToSnapDelay.value = 800;
      final stroke = await draw(
        tester,
        Pen.fountainPen(),
        circle,
        holdFor: const Duration(milliseconds: 600),
      );
      expect(stroke.runtimeType, Stroke);
      final stroke2 = await draw(
        tester,
        Pen.fountainPen(),
        circle,
        holdFor: const Duration(milliseconds: 900),
      );
      expect(stroke2, isA<CircleStroke>());
    });

    testWidgets('continuing to draw discards the preview', (tester) async {
      final stroke = await draw(
        tester,
        Pen.fountainPen(),
        circle,
        holdFor: const Duration(milliseconds: 600),
        afterHold: _polyline([const Offset(400, 300), const Offset(400, 340)]),
      );
      expect(stroke.runtimeType, Stroke);
      expect(HoldToSnap.lastStrokeWasSnapped, isFalse);
    });

    testWidgets('hold radius is zoom independent', (tester) async {
      // At 4x zoom, 1 page unit of jitter = 4 screen pixels: still holding
      HoldToSnap.configure(scale: 4, onPreviewChanged: null);
      final stroke = await draw(
        tester,
        Pen.fountainPen(),
        circle,
        holdFor: const Duration(milliseconds: 600),
      );
      expect(stroke, isA<CircleStroke>());

      // At 8x zoom, 2 page units (jitter -1..+1) = 16 screen pixels: moving
      HoldToSnap.configure(scale: 8, onPreviewChanged: null);
      final stroke2 = await draw(
        tester,
        Pen.fountainPen(),
        circle,
        holdFor: const Duration(milliseconds: 600),
      );
      expect(stroke2.runtimeType, Stroke);
    });

    testWidgets('ballpoint pen and pencil snap', (tester) async {
      expect(
        await draw(
          tester,
          Pen.ballpointPen(),
          circle,
          holdFor: const Duration(milliseconds: 600),
        ),
        isA<CircleStroke>(),
      );
      expect(
        await draw(
          tester,
          Pencil(),
          _rect(const Rect.fromLTWH(100, 100, 300, 150)),
          holdFor: const Duration(milliseconds: 600),
        ),
        isA<RectangleStroke>(),
      );
    });

    testWidgets('highlighter and shape pen never use hold to snap', (
      tester,
    ) async {
      final highlighted = await draw(
        tester,
        Highlighter(),
        circle,
        holdFor: const Duration(milliseconds: 600),
      );
      expect(highlighted.runtimeType, Stroke);
      expect(Highlighter().supportsHoldToSnap, isFalse);
      expect(ShapePen().supportsHoldToSnap, isFalse);
    });

    testWidgets('disabled setting', (tester) async {
      stows.holdToSnapEnabled.value = false;
      final stroke = await draw(
        tester,
        Pen.fountainPen(),
        circle,
        holdFor: const Duration(milliseconds: 600),
      );
      expect(stroke.runtimeType, Stroke);
    });

    testWidgets('small handwriting is not converted even when held', (
      tester,
    ) async {
      final stroke = await draw(
        tester,
        Pen.fountainPen(),
        _handwriting['O (capital)']!,
        holdFor: const Duration(milliseconds: 600),
      );
      expect(stroke.runtimeType, Stroke);
    });
  });

  group('Snapped shapes are stored as upstream stroke types', () {
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      ServicesBinding.rootIsolateToken!,
    );
    setupMockPathProvider();

    setUpAll(() async {
      await FileManager.init();
      StrokeOptionsExtension.setDefaults();
      FileManager.shouldUseRawFilePath = true;
      EditorImage.shouldLoadOutImmediately = true;
    });
    tearDownAll(() {
      FileManager.shouldUseRawFilePath = false;
      EditorImage.shouldLoadOutImmediately = false;
    });

    test('save and load a note with snapped shapes', () async {
      const path = 'test/sbn_examples/v19_pens.sbn2';
      final coreInfo = await EditorCoreInfo.loadFromFileContents(
        bsonBytes: File(path).readAsBytesSync(),
        path: path.substring(0, path.lastIndexOf('.')),
        onlyFirstPage: false,
      );
      final page = coreInfo.pages.first;
      final rawStrokes = {
        'circle': _stroke(_circle(const Offset(300, 300), 100)),
        'rect': _stroke(_rect(const Rect.fromLTWH(100, 500, 300, 150))),
        'square': _stroke(_rect(const Rect.fromLTWH(500, 500, 200, 190))),
        'line': _stroke(
          _polyline([const Offset(100, 800), const Offset(500, 803)]),
        ),
        'triangle': _stroke(
          _polyline([
            const Offset(700, 100),
            const Offset(800, 280),
            const Offset(600, 280),
            const Offset(700, 100),
          ]),
        ),
      };
      final snapped = <Stroke>[];
      for (final MapEntry(key: name, value: raw) in rawStrokes.entries) {
        final shape = HoldToSnap.detect(raw);
        expect(shape, isNotNull, reason: name);
        snapped.add(shape!.toStroke(raw));
      }
      final strokeCountBefore = page.strokes.length;
      for (final s in snapped) {
        page.insertStroke(s);
      }

      final (bson, _) = coreInfo.saveToBinary(currentPageIndex: null);
      final reloaded = await EditorCoreInfo.loadFromFileContents(
        bsonBytes: bson,
        path: 'snapped',
        onlyFirstPage: false,
      );
      expect(reloaded.readOnlyReason, isNull);
      final reloadedPage = reloaded.pages.first;
      expect(reloadedPage.strokes.length, strokeCountBefore + snapped.length);

      // Only stroke types that the unmodified upstream Saber can read
      for (final stroke in reloadedPage.strokes) {
        expect(
          stroke.runtimeType,
          anyOf(Stroke, RectangleStroke, CircleStroke),
        );
        final json = stroke.toJson();
        expect(json['shape'], anyOf(isNull, 'rect', 'circle'));
      }

      // Every snapped stroke is reloaded identically
      final reloadedJson = reloadedPage.strokes.map((s) => s.toJson()).toList();
      for (final s in snapped) {
        expect(reloadedJson, contains(equals(s.toJson())));
      }
      expect(reloadedPage.strokes.whereType<CircleStroke>(), hasLength(1));
      expect(reloadedPage.strokes.whereType<RectangleStroke>(), hasLength(2));

      // The file version is unchanged
      final (json, _) = reloaded.toJson();
      expect(json['v'], 19, reason: 'file version must not change');
    });
  });
}
