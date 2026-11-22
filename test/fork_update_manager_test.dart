import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saber/components/settings/fork_update_dialog.dart';
import 'package:saber/components/settings/fork_update_manager.dart';
import 'package:saber/components/settings/update_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/fork_config.dart';

void main() {
  late final String forkApiResponse;
  setUpAll(() async {
    FlavorConfig.setup();
    forkApiResponse = await File('test/samples/github_fork_release_api.json')
        .readAsString();
  });

  group('ForkVersion.tryParseTag', () {
    test('parses a valid tag', () {
      final v = ForkVersion.tryParseTag('v1.38.0-fork.1')!;
      expect(v.major, 1);
      expect(v.minor, 38);
      expect(v.patch, 0);
      expect(v.fork, 1);
      expect(v.upstreamBuildNumber, 138000);
      expect(v.buildNumber, 13800001);
      expect(v.buildName, '1.38.0-fork.1');
    });

    test('upstream build number matches version.dart formula', () {
      expect(ForkVersion.tryParseTag('v1.38.12-fork.3')!.buildNumber, 13812003);
      expect(ForkVersion.tryParseTag('v2.0.0-fork.99')!.buildNumber, 20000099);
    });

    test('rejects invalid tags', () {
      for (final tag in [
        '',
        'v1.38.0',
        '1.38.0-fork.1',
        'v1.38-fork.1',
        'v1.38.0-fork.0',
        'v1.38.0-fork.100',
        'v1.38.0-fork.',
        'v1.38.0-fork.1a',
        'v1.38.0-beta.1',
        'v100.0.0-fork.1',
      ]) {
        expect(ForkVersion.tryParseTag(tag), isNull, reason: tag);
      }
    });

    test('build numbers are strictly increasing', () {
      final ordered = [
        'v1.37.9-fork.99',
        'v1.38.0-fork.1',
        'v1.38.0-fork.2',
        'v1.38.0-fork.10',
        'v1.38.1-fork.1',
        'v1.39.0-fork.1',
        'v2.0.0-fork.1',
      ].map((t) => ForkVersion.tryParseTag(t)!.buildNumber).toList();
      for (var i = 1; i < ordered.length; i++) {
        expect(ordered[i], greaterThan(ordered[i - 1]));
      }
    });
  });

  group('ForkUpdateManager.parseLatestRelease', () {
    test('update available', () {
      final result = ForkUpdateManager.parseLatestRelease(
        forkApiResponse,
        currentBuildNumber: 13800001,
      );
      expect(result, isA<ForkUpdateAvailable>());
      final release = (result as ForkUpdateAvailable).release;
      expect(release.version.buildNumber, 13800002);
      expect(release.apkName, 'SaberFork_v1.38.0-fork.2.apk');
      expect(release.apkUrl, endsWith('/SaberFork_v1.38.0-fork.2.apk'));
      expect(
        release.sha256Url,
        endsWith('/SaberFork_v1.38.0-fork.2.apk.sha256'),
      );
      expect(release.body, 'Test release notes');
    });

    test('same version is up to date', () {
      final result = ForkUpdateManager.parseLatestRelease(
        forkApiResponse,
        currentBuildNumber: 13800002,
      );
      expect(result, isA<ForkUpToDate>());
    });

    test('older release is not offered', () {
      final result = ForkUpdateManager.parseLatestRelease(
        forkApiResponse,
        currentBuildNumber: 13900001,
      );
      expect(result, isA<ForkUpToDate>());
    });

    test('missing APK', () {
      final json = jsonDecode(forkApiResponse) as Map<String, dynamic>;
      (json['assets'] as List).removeWhere(
        (a) => (a['name'] as String).endsWith('.apk'),
      );
      final result = ForkUpdateManager.parseLatestRelease(
        jsonEncode(json),
        currentBuildNumber: 0,
      );
      expect(result, isA<ForkUpdateError>());
      expect(
        (result as ForkUpdateError).reason,
        ForkUpdateErrorReason.missingAssets,
      );
    });

    test('missing .sha256', () {
      final json = jsonDecode(forkApiResponse) as Map<String, dynamic>;
      (json['assets'] as List).removeWhere(
        (a) => (a['name'] as String).endsWith('.sha256'),
      );
      final result = ForkUpdateManager.parseLatestRelease(
        jsonEncode(json),
        currentBuildNumber: 0,
      );
      expect(result, isA<ForkUpdateError>());
      expect(
        (result as ForkUpdateError).reason,
        ForkUpdateErrorReason.missingAssets,
      );
    });

    test('upstream release (no fork tag) is rejected', () async {
      final upstream = await File('test/samples/github_releases_api.json')
          .readAsString();
      final result = ForkUpdateManager.parseLatestRelease(
        upstream,
        currentBuildNumber: 0,
      );
      expect(result, isA<ForkUpdateError>());
      expect(
        (result as ForkUpdateError).reason,
        ForkUpdateErrorReason.invalidRelease,
      );
    });

    test('invalid JSON', () {
      final result = ForkUpdateManager.parseLatestRelease(
        '<html>',
        currentBuildNumber: 0,
      );
      expect(result, isA<ForkUpdateError>());
      expect(
        (result as ForkUpdateError).reason,
        ForkUpdateErrorReason.invalidRelease,
      );
    });
  });

  group('ForkUpdateManager.checkForUpdate', () {
    test('uses the fork repository', () {
      expect(
        ForkUpdateManager.latestReleaseUrl.toString(),
        'https://api.github.com/repos/7Solomon/saber/releases/latest',
      );
      expect(UpdateManager.apiUrl, ForkUpdateManager.latestReleaseUrl);
    });

    test('update available', () async {
      final result = await ForkUpdateManager.checkForUpdate(
        currentBuildNumber: 13800001,
        client: MockClient((_) async => http.Response(forkApiResponse, 200)),
      );
      expect(result, isA<ForkUpdateAvailable>());
    });

    test('no release yet (404)', () async {
      final result = await ForkUpdateManager.checkForUpdate(
        currentBuildNumber: 13800001,
        client: MockClient((_) async => http.Response('Not Found', 404)),
      );
      expect(result, isA<ForkUpToDate>());
      expect((result as ForkUpToDate).latest, isNull);
    });

    test('HTTP error (e.g. rate limit)', () async {
      final result = await ForkUpdateManager.checkForUpdate(
        currentBuildNumber: 13800001,
        client: MockClient((_) async => http.Response('limit', 403)),
      );
      expect(result, isA<ForkUpdateError>());
      expect(
        (result as ForkUpdateError).reason,
        ForkUpdateErrorReason.httpStatus,
      );
    });

    test('network error does not throw', () async {
      final result = await ForkUpdateManager.checkForUpdate(
        currentBuildNumber: 13800001,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      expect(result, isA<ForkUpdateError>());
      expect((result as ForkUpdateError).reason, ForkUpdateErrorReason.network);
    });
  });

  group('Checksums', () {
    test('parseSha256File', () {
      final hash = 'a' * 64;
      expect(ForkUpdateManager.parseSha256File('$hash  file.apk\n'), hash);
      expect(ForkUpdateManager.parseSha256File(hash), hash);
      expect(ForkUpdateManager.parseSha256File('${'A' * 64} *file.apk'), hash);
      expect(ForkUpdateManager.parseSha256File(''), isNull);
      expect(ForkUpdateManager.parseSha256File('a' * 63), isNull);
      expect(ForkUpdateManager.parseSha256File('${'a' * 65}  f'), isNull);
      expect(ForkUpdateManager.parseSha256File('<html>Not Found'), isNull);
    });

    late Directory tempDir;
    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fork_update_test');
    });
    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('matching checksum keeps the file', () async {
      final bytes = utf8.encode('fake apk contents');
      final file = File('${tempDir.path}/SaberFork_test.apk')
        ..writeAsBytesSync(bytes);
      final expected = sha256.convert(bytes).toString();

      await ForkUpdateManager.verifyOrDelete(file, expected.toUpperCase());
      expect(file.existsSync(), isTrue);
    });

    test('checksum mismatch deletes the file and throws', () async {
      final file = File('${tempDir.path}/SaberFork_test.apk')
        ..writeAsStringSync('tampered apk contents');
      final expected = sha256.convert(utf8.encode('original')).toString();

      await expectLater(
        ForkUpdateManager.verifyOrDelete(file, expected),
        throwsA(
          isA<ForkUpdateDownloadException>().having(
            (e) => e.reason,
            'reason',
            ForkUpdateDownloadError.checksumMismatch,
          ),
        ),
      );
      expect(file.existsSync(), isFalse);
    });
  });

  group('UpdateManager.getLatestDownloadUrl (fork)', () {
    test('finds the fork APK on Android', () async {
      final url = await UpdateManager.getLatestDownloadUrl(
        forkApiResponse,
        .android,
      );
      expect(url, endsWith('/SaberFork_v1.38.0-fork.2.apk'));
    });
  });

  group('ForkConfig', () {
    test('is not a fork release in tests', () {
      expect(ForkConfig.buildNumber, 0);
      expect(ForkConfig.isForkRelease, isFalse);
    });
  });

  group('ForkUpdateDialog', () {
    Future<void> pumpDialog(
      WidgetTester tester,
      ForkUpdateCheckResult result,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: ForkUpdateDialog(checkForUpdate: () async => result)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('up to date', (tester) async {
      await pumpDialog(tester, const ForkUpToDate(null));
      expect(find.text('Du hast die neueste Version.'), findsOneWidget);
    });

    testWidgets('network error', (tester) async {
      await pumpDialog(tester, const ForkUpdateError(.network));
      expect(find.textContaining('Keine Verbindung'), findsOneWidget);
      expect(find.text('Erneut versuchen'), findsOneWidget);
    });

    testWidgets('update available', (tester) async {
      final result = ForkUpdateManager.parseLatestRelease(
        forkApiResponse,
        currentBuildNumber: 13800001,
      );
      await pumpDialog(tester, result);
      expect(find.textContaining('1.38.0-fork.2'), findsWidgets);
      expect(find.text('Test release notes'), findsOneWidget);
      expect(find.text('Herunterladen und installieren'), findsOneWidget);
    });
  });
}
