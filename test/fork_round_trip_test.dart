// Saber Fork: data safety test.
//
// Every example note is loaded, saved and loaded again.
// The content (pages, strokes, points, images, assets) must be identical.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/tools/stroke_properties.dart';

import 'utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  BackgroundIsolateBinaryMessenger.ensureInitialized(
    ServicesBinding.rootIsolateToken!,
  );
  setupMockPathProvider();
  FlavorConfig.setup();

  final noteFiles = [
    for (final dir in ['test/sbn_examples', 'test/demo_notes'])
      ...Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sbn') || f.path.endsWith('.sbn2'))
          .map((f) => f.path.replaceAll(r'\', '/')),
  ]..sort();

  late Directory outDir;

  setUpAll(() async {
    await FileManager.init();
    StrokeOptionsExtension.setDefaults();
    FileManager.shouldUseRawFilePath = true;
    EditorImage.shouldLoadOutImmediately = true;
    outDir = await Directory.systemTemp.createTemp('saber_fork_round_trip');
  });
  tearDownAll(() async {
    FileManager.shouldUseRawFilePath = false;
    EditorImage.shouldLoadOutImmediately = false;
    if (outDir.existsSync()) await outDir.delete(recursive: true);
  });

  test('there are example notes to test', () {
    expect(noteFiles.length, greaterThanOrEqualTo(20));
  });

  for (final path in noteFiles) {
    test('Round trip: $path', () async {
      final isBson = path.endsWith('.sbn2');
      final pathWithoutExtension = path.substring(0, path.lastIndexOf('.'));

      // 1. Load the original file
      final original = await EditorCoreInfo.loadFromFileContents(
        bsonBytes: isBson ? File(path).readAsBytesSync() : null,
        jsonString: isBson ? null : File(path).readAsStringSync(),
        path: pathWithoutExtension,
        onlyFirstPage: false,
      );
      expect(original.readOnlyReason, isNull, reason: 'Failed to load $path');

      // 2. Save it (like the editor does: bson + separate asset files)
      final (bson1, assets1) = original.saveToBinary(currentPageIndex: null);
      final (json1, _) = original.toJson();
      final assetBytes1 = [
        for (var i = 0; i < assets1.length; i++) await assets1.getBytes(i),
      ];

      final savedPath = p
          .join(outDir.path, p.basenameWithoutExtension(path))
          .replaceAll(r'\', '/');
      await File('$savedPath.sbn2').writeAsBytes(bson1);
      for (var i = 0; i < assetBytes1.length; i++) {
        await File('$savedPath.sbn2.$i').writeAsBytes(assetBytes1[i]);
      }

      // 3. Load the saved file again
      final reloaded = await EditorCoreInfo.loadFromFileContents(
        bsonBytes: File('$savedPath.sbn2').readAsBytesSync(),
        path: savedPath,
        onlyFirstPage: false,
      );
      expect(reloaded.readOnlyReason, isNull);

      // 4. Compare
      //
      // Note: Upstream sorts strokes by tool on every load
      // (`EditorPage.sortStrokes`) with Dart's unstable `List.sort`, so the
      // relative order of strokes with the same tool can change between
      // loads. Therefore strokes are compared as a multiset per page and per
      // tool. Everything else (incl. every point of every stroke) must match.
      expect(reloaded.pages.length, original.pages.length, reason: 'pages');
      for (var i = 0; i < original.pages.length; i++) {
        final a = original.pages[i];
        final b = reloaded.pages[i];
        expect(b.size, a.size, reason: 'page $i size');
        expect(b.strokes.length, a.strokes.length, reason: 'page $i strokes');
        expect(
          b.strokes.map((s) => s.toolId).toList(),
          a.strokes.map((s) => s.toolId).toList(),
          reason: 'page $i stroke tool order',
        );
        expect(
          _canonicalStrokes(b.strokes.map((s) => s.toJson())),
          _canonicalStrokes(a.strokes.map((s) => s.toJson())),
          reason: 'page $i strokes (types, points, colors, ...)',
        );
        expect(
          b.strokes.fold<int>(0, (sum, s) => sum + s.points.length),
          a.strokes.fold<int>(0, (sum, s) => sum + s.points.length),
          reason: 'page $i total points',
        );
        expect(b.images.length, a.images.length, reason: 'page $i images');
        expect(
          b.backgroundImage == null,
          a.backgroundImage == null,
          reason: 'page $i background image',
        );
      }

      final (_, assets2) = reloaded.saveToBinary(currentPageIndex: null);
      final (json2, _) = reloaded.toJson();
      expect(
        _normalizeNoteJson(json2),
        _normalizeNoteJson(json1),
        reason: 'Full note content must be identical',
      );
      expect(assets2.length, assets1.length, reason: 'asset count');
      for (var i = 0; i < assets1.length; i++) {
        expect(await assets2.getBytes(i), assetBytes1[i], reason: 'asset $i');
      }

      original.dispose();
      reloaded.dispose();
    });
  }
}

/// Returns the strokes as sorted canonical strings (order-independent).
List<String> _canonicalStrokes(Iterable<Map<String, dynamic>> strokes) =>
    strokes.map(_canonical).toList()..sort();

String _canonical(Object? value) => switch (value) {
  final Map<dynamic, dynamic> map =>
    '{${(map.keys.map((k) => k.toString()).toList()..sort()).map((k) => '$k:${_canonical(map[k])}').join(',')}}',
  final List<dynamic> list => '[${list.map(_canonical).join(',')}]',
  _ => value.toString(),
};

/// Sorts the strokes of every page canonically, see [_canonicalStrokes].
Map<String, dynamic> _normalizeNoteJson(Map<String, dynamic> json) => {
  ...json,
  'z': [
    for (final page in json['z'] as List)
      {
        ...(page as Map<String, dynamic>),
        's': _canonicalStrokes(
          (page['s'] as List? ?? const []).cast<Map<String, dynamic>>(),
        ),
        'i': _canonical(page['i']),
      },
  ],
};
